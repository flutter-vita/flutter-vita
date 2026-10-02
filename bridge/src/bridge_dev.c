// The bridge's C layer: the port, the commands, and the state the screen reads.
//
// ADR-0016. The bridge is an ordinary Flutter-Vita application built from
// templates/vita-app, and this is the translation unit that makes it a bridge
// rather than an app. It registers from a constructor, which runs before main()
// and therefore before the embedder's StartDevServer(), so the socket is
// listening before the engine's ~3 second startup. If Flutter never comes up,
// only the screen is lost -- decision 3, which is what makes decision 1
// affordable.
//
// The Dart side never calls into any of this. It polls a small text file this
// layer writes, which costs a rewrite per state change and buys not adding a
// platform channel to the component with the strongest reliability requirement.

#include <psp2/appmgr.h>
#include <psp2/io/dirent.h>
#include <psp2/io/fcntl.h>
#include <psp2/rtc.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>
#include <psp2/net/netctl.h>
#include <psp2/promoterutil.h>
#include <psp2/sysmodule.h>

#include <stdarg.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "devserver.h"
#include "fvita_plugin.h"
#include "vpk.h"

// Overridable so a bridge under test can be installed beside the working one.
// Replacing FVTA00001 in place with something unproven costs the only deploy
// path there is.
#ifndef BRIDGE_PORT
#define BRIDGE_PORT 1341
#endif
// Which slot this bridge occupies.
//
// A running title cannot write its own directory: ux0:app/<self> is the
// read-only app0: mount, and that covers the whole slot, not just eboot.bin --
// `put 6 ux0:app/FVTA00001/wtest.txt` answers ERR open. So the bridge is the
// one thing the bridge cannot install, and FVTA00009 exists to do it. See
// tools/selfupdate-bridge.sh.
//
// The id here is what refuses to delete ourselves and refuses to hand over to
// ourselves. See cmd_delete and hand_over.
#ifndef SELF_TITLEID
#define SELF_TITLEID "FVTA00001"
#endif

#ifndef TARGET_TITLEID
#define TARGET_TITLEID "FVTA00002"
#endif

#define DATA_DIR "ux0:data/flutter-vita"
#define STAGED DATA_DIR "/staged-eboot.bin"
#define STATE_PATH DATA_DIR "/bridge-state.txt"
// The panel reads this one and removes it; see readPanelRequest in device.dart.
#define PANEL_REQUEST_PATH DATA_DIR "/panel-request.txt"
// What the DEPLOY console reads. Survives the launch that ends this process.
#define DEPLOY_LOG DATA_DIR "/deploy.log"
#define STATE_TMP DATA_DIR "/bridge-state.tmp"

// The engine's debug HUD is drawn over every frame from a weak symbol, and a
// strong definition here wins. Hidden for the bridge: this screen is the
// product (ADR-0016 decision 1), and a showcase with a diagnostic overlay
// bolted to its corner is a worse advertisement than no showcase. 2 rather
// than 0, so L + R + SELECT can still bring it up when the bridge itself
// is the thing being measured.
int flutter_vita_debug_overlay = 2;

// The GPU, like every other app.
// Defined by the embedder only on the GL path, hence weak -- the same
// declaration devserver.c and bailout.c carry.
int flutter_vita_force_software = 0;

// Defined by the embedder when it is running the GL path, absent otherwise --
// hence weak, the same declaration devserver.c and bailout.c carry. Every exit
// from this file launches another application and then calls
// sceKernelExitProcess, and under GL that leaves a live GXM context and queued
// flips pointing at memory the kernel is about to reclaim.
extern void flutter_vita_gpu_shutdown(void) __attribute__((weak));

static void release_gpu(void) {
  if (flutter_vita_gpu_shutdown != NULL) flutter_vita_gpu_shutdown();
}

#define LOG_LINES 12
#define LOG_WIDTH 96

// ---------------------------------------------------------------- the state
//
// One writer -- everything below runs on the dev server's thread or on the
// single watcher thread -- so this is guarded by nothing more than that fact
// and the atomic rename at the end of publish().

// When a host last sent this bridge a command, in process time. Negative
// means never.
//
// The badge said "Waiting" through every unreachable stretch of 2026-09-01, and
// it was true: the console had an address and the socket was listening. What it
// could not say was that nothing had reached it for twenty minutes.
static SceInt64 g_last_cmd = -1;

static char g_status[24] = "Starting";
static char g_detail[80] = "";
static char g_ip[24] = "";
static char g_target[16] = TARGET_TITLEID;

// Bytes of the transfer in flight, for the panel's progress bar. The `detail`
// string already carries the same numbers as prose, and prose is the wrong
// shape for a bar: the panel would have to parse English to draw a rectangle.
static int g_recv_done = 0;
static int g_recv_total = 0;

static char g_lines[LOG_LINES][LOG_WIDTH];
static int g_line_count = 0;  // total ever, not the ring size
static unsigned g_seq = 0;

// Seconds since a host last spoke, or -1 if none ever has.
static int last_cmd_age(void) {
  if (g_last_cmd < 0) return -1;
  const SceInt64 now = (SceInt64)sceKernelGetProcessTimeWide();
  return (int)((now - g_last_cmd) / 1000000);
}

static void publish(void) {
  g_seq++;
  char buf[LOG_LINES * LOG_WIDTH + 512];
  int n = snprintf(buf, sizeof buf,
                   "seq %u\nip %s\nport %d\ntarget %s\nstatus %s\ndetail %s\n"
                   "self %s\nrecv %d %d\nlastcmd %d\n",
                   g_seq, g_ip[0] ? g_ip : "-", BRIDGE_PORT, g_target,
                   g_status, g_detail, SELF_TITLEID, g_recv_done,
                   g_recv_total, last_cmd_age());
  // Oldest first, so the Dart side can append without reversing.
  const int have = g_line_count < LOG_LINES ? g_line_count : LOG_LINES;
  const int start = g_line_count - have;
  for (int i = 0; i < have && n < (int)sizeof buf - LOG_WIDTH - 8; i++) {
    n += snprintf(buf + n, sizeof buf - n, "log %s\n",
                  g_lines[(start + i) % LOG_LINES]);
  }

  // Written to a sibling and renamed, because the reader polls: a partial
  // rewrite caught mid-write would show the panel a truncated state, and the
  // reader has no way to tell that from the real thing.
  sceIoRemove(STATE_TMP);
  const SceUID fd =
      sceIoOpen(STATE_TMP, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) return;
  sceIoWrite(fd, buf, n);
  sceIoClose(fd);
  sceIoRemove(STATE_PATH);
  sceIoRename(STATE_TMP, STATE_PATH);
}

static void set_status(const char* status, const char* fmt, ...) {
  snprintf(g_status, sizeof g_status, "%s", status);
  if (fmt == NULL) {
    g_detail[0] = '\0';
  } else {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_detail, sizeof g_detail, fmt, ap);
    va_end(ap);
  }
  publish();
}

// A line for the panel and a line for the log file, from one call.
// MM-DD HH:MM:SS, fifteen characters including the trailing space.
//
// Fixed width on purpose: the panel finds the "+ " and "- " markers by stepping
// over this, and the two halves of that arrangement are a hundred lines apart
// in two languages. Change the width here and _Console goes wrong quietly.
//
// The clock is whatever the console was last set to. Nothing sorts by it -- the
// log archive is numbered for that reason -- but a wrong wall clock still
// answers "was that this deploy or the one before lunch".
#define STAMP_LEN 15

static void stamp(char* out, int cap) {
  SceDateTime t;
  memset(&t, 0, sizeof t);
  if (sceRtcGetCurrentClockLocalTime(&t) < 0) {
    snprintf(out, cap, "----- --:--:-- ");
    return;
  }
  snprintf(out, cap, "%02d-%02d %02d:%02d:%02d ", t.month, t.day, t.hour,
           t.minute, t.second);
}

static void note(const char* fmt, ...) {
  char body[LOG_WIDTH - STAMP_LEN];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(body, sizeof body, fmt, ap);
  va_end(ap);

  char ts[STAMP_LEN + 1];
  stamp(ts, sizeof ts);

  char line[LOG_WIDTH];
  snprintf(line, sizeof line, "%s%s", ts, body);

  snprintf(g_lines[g_line_count % LOG_LINES], LOG_WIDTH, "%s", line);
  g_line_count++;

  char with_newline[LOG_WIDTH + 4];
  snprintf(with_newline, sizeof with_newline, "  %s\n", line);
  dev_server_log(with_newline);

  // Appended as well as ringed. `launch` ends this process, so the ring is
  // empty at every boot and the DEPLOY console showed nothing about the deploy
  // that just happened -- which is the deploy you go looking for. The file
  // outlives the process; the ring is what the state file can carry cheaply.
  const SceUID fd =
      sceIoOpen(DEPLOY_LOG, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_APPEND, 0777);
  if (fd >= 0) {
    sceIoWrite(fd, with_newline + 2, strlen(with_newline) - 2);
    sceIoClose(fd);
  }
  publish();
}

// A new deploy log on every start, with the last session kept as deploy.log.1.
//
// Until 2026-10-01 the log was only cut back once it reached 64 KB, so the
// panel opened on days of old deploys: a self-update leaves a dozen lines per
// cycle, and the screen filled with cycles nobody was looking at. The bridge
// exits whenever it launches an app, so a session is one deploy, and the one
// before it is still on the card for a host to `get`. Rotating at boot also
// keeps the file small without a read-modify-write in the path of every note.
static void start_deploy_log(void) {
  SceIoStat st;
  if (sceIoGetstat(DEPLOY_LOG, &st) < 0) return;
  sceIoRemove(DEPLOY_LOG ".1");
  sceIoRename(DEPLOY_LOG, DEPLOY_LOG ".1");
}

// Bytes below a kilobyte, kilobytes below a megabyte, then megabytes to one
// decimal. "put 0 KB" for an 82-byte manifest is the sort of thing that reads
// as a bug on a screen whose whole job is to be read.
static const char* human_size(int bytes) {
  static char out[24];
  if (bytes < 1024) {
    snprintf(out, sizeof out, "%d B", bytes);
  } else if (bytes < 1024 * 1024) {
    snprintf(out, sizeof out, "%d KB", bytes / 1024);
  } else {
    snprintf(out, sizeof out, "%d.%d MB", bytes / (1024 * 1024),
             (int)(((bytes % (1024 * 1024)) * 10) / (1024 * 1024)));
  }
  return out;
}

static void note_size(const char* what, int bytes) {
  note("%s %s", what, human_size(bytes));
}

// ------------------------------------------------------------ the commands

static void mkdirs(void) {
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir(DATA_DIR, 0777);
}

// Receive `size` bytes from the socket into `dest`, reporting progress.
//
// This is `put` and `stage` both, and it deliberately shadows the dev server's
// own `put`: the built-in cannot report progress, and "Receiving, 4.2 of
// 11.8 MB" is most of what the status line is for.
//
// A NULL `what` receives silently: no log line, no status, no progress. That is
// for the panel's command file, nine bytes arriving whenever someone is driving
// the screen from the host.
static int receive_to(int sock, const char* dest, int size, const char* what) {
  mkdirs();
  char tmp[288];
  snprintf(tmp, sizeof tmp, "%s.part", dest);
  sceIoRemove(tmp);
  const SceUID fd =
      sceIoOpen(tmp, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) {
    if (what != NULL) {
      note("%s: cannot open (0x%08X)", what, (unsigned)fd);
      set_status("Waiting", NULL);
    }
    dev_server_send(sock, "ERR open\n");
    return -1;
  }

  static char buf[32 * 1024];
  int remaining = size, since_report = 0;
  while (remaining > 0) {
    const int want = remaining < (int)sizeof buf ? remaining : (int)sizeof buf;
    const int got = sceNetRecv(sock, buf, want, 0);
    if (got <= 0) {
      sceIoClose(fd);
      sceIoRemove(tmp);
      if (what != NULL) note("%s: short by %d of %d", what, remaining, size);
      set_status("Waiting", NULL);
      dev_server_send(sock, "ERR short\n");
      return -1;
    }
    if (sceIoWrite(fd, buf, got) != got) {
      sceIoClose(fd);
      sceIoRemove(tmp);
      if (what != NULL) note("%s: write failed", what);
      set_status("Waiting", NULL);
      dev_server_send(sock, "ERR write\n");
      return -1;
    }
    remaining -= got;
    since_report += got;
    // Every half megabyte, not every chunk: each report rewrites the state
    // file, and 12 MB in 32 KB chunks is 384 rewrites of a file on a memory
    // card in the middle of a transfer.
    if (what != NULL && since_report >= 512 * 1024) {
      since_report = 0;
      g_recv_done = size - remaining;
      g_recv_total = size;
      set_status("Receiving", "%d of %d KB", g_recv_done / 1024, size / 1024);
    }
  }
  sceIoClose(fd);
  sceIoRemove(dest);  // sceIoRename will not overwrite
  const int rr = sceIoRename(tmp, dest);
  if (rr < 0) {
    if (what != NULL) note("%s: rename failed 0x%08X", what, (unsigned)rr);
    set_status("Waiting", NULL);
    dev_server_send(sock, "ERR rename\n");
    return -1;
  }
  if (what != NULL) note_size(what, size);
  g_recv_done = 0;
  g_recv_total = 0;
  if (what != NULL) set_status("Waiting", NULL);
  dev_server_send(sock, "OK\n");
  return 0;
}

static void set_target(const char* arg) {
  snprintf(g_target, sizeof g_target, "%s",
           (arg != NULL && arg[0] != '\0') ? arg : TARGET_TITLEID);
}

// Defined with the log rotation, which is the other thing that only makes sense
// in the process that launches apps.
static void record_installed(const char* titleid);
static void forget_installed(const char* titleid);

static int cmd_install(int sock) {
  set_status("Installing", "%s", g_target);
  const SceUID in = sceIoOpen(STAGED, SCE_O_RDONLY, 0777);
  if (in < 0) {
    note("install: nothing staged");
    set_status("Waiting", NULL);
    dev_server_send(sock, "ERR nothing staged\n");
    return -1;
  }
  char target[64], tmp[72];
  snprintf(target, sizeof target, "ux0:app/%s/eboot.bin", g_target);
  snprintf(tmp, sizeof tmp, "%s.tmp", target);
  sceIoRemove(tmp);
  const SceUID out =
      sceIoOpen(tmp, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (out < 0) {
    sceIoClose(in);
    note("install: cannot write %s (0x%08X)", target, (unsigned)out);
    set_status("Waiting", NULL);
    dev_server_send(sock, "ERR cannot write target\n");
    return -1;
  }
  static char buf[32 * 1024];
  int n, total = 0;
  while ((n = sceIoRead(in, buf, sizeof buf)) > 0) {
    if (sceIoWrite(out, buf, n) != n) {
      sceIoClose(in);
      sceIoClose(out);
      sceIoRemove(tmp);
      note("install: write failed at %d", total);
      set_status("Waiting", NULL);
      dev_server_send(sock, "ERR write\n");
      return -1;
    }
    total += n;
  }
  sceIoClose(in);
  sceIoClose(out);
  sceIoRemove(target);
  const int rr = sceIoRename(tmp, target);
  if (rr < 0) {
    note("install: rename failed 0x%08X", (unsigned)rr);
    set_status("Waiting", NULL);
    dev_server_send(sock, "ERR rename\n");
    return -1;
  }
  note("installed %s into %s", human_size(total), g_target);
  record_installed(g_target);
  set_status("Waiting", NULL);
  dev_server_send(sock, "OK\n");
  return 0;
}

// Keep the log the app that just ran wrote, instead of letting the next one
// truncate it.
//
// The engine opens ux0:data/flutter-vita/app.log with O_TRUNC before anything
// else runs, so an app's log survives exactly until the next launch. That is
// the wrong lifetime for the thing you go looking for after a crash, and it
// cannot be fixed in the app: the truncate is inside the engine archive.
//
// The bridge is what launches apps, so it is the one process that knows a log
// is about to be destroyed and can move it first. Numbered rather than
// timestamped because this console's clock is whatever the user last set it to.
#define LOG_DIR DATA_DIR "/logs"
#define LOG_KEEP 20

// Read a whole small file into buf. Returns the byte count, or 0.
static int read_small(const char* path, char* buf, int cap) {
  const SceUID fd = sceIoOpen(path, SCE_O_RDONLY, 0777);
  if (fd < 0) return 0;
  const int n = sceIoRead(fd, buf, cap - 1);
  sceIoClose(fd);
  if (n <= 0) return 0;
  buf[n] = '\0';
  for (int i = 0; i < n; i++) {
    if (buf[i] == '\n' || buf[i] == '\r') { buf[i] = '\0'; return i; }
  }
  return n;
}

static void write_small(const char* path, const char* text) {
  const SceUID fd =
      sceIoOpen(path, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) return;
  sceIoWrite(fd, text, strlen(text));
  sceIoClose(fd);
}

// `next_titleid` is the app about to run, not the one whose log is being
// archived. The log sitting in app.log belongs to the *previous* launch, so
// naming it after the incoming title would label every archive with the wrong
// app the moment two different ids are deployed in a row. The previous id is
// kept in LOG_DIR/last for exactly this.
static void rotate_app_log(const char* next_titleid) {
  sceIoMkdir(LOG_DIR, 0777);

  char prev[24] = {0};
  if (read_small(LOG_DIR "/last", prev, sizeof prev) <= 0) {
    snprintf(prev, sizeof prev, "unknown");
  }
  write_small(LOG_DIR "/last", next_titleid);

  SceIoStat st;
  if (sceIoGetstat(DATA_DIR "/app.log", &st) < 0 || st.st_size == 0) return;

  // The next index, read from a file rather than by scanning: the directory
  // listing would have to be parsed and the answer is one integer.
  int seq = 0;
  char idx[16] = {0};
  if (read_small(LOG_DIR "/next", idx, sizeof idx) > 0) seq = atoi(idx);

  char dest[192];
  snprintf(dest, sizeof dest, LOG_DIR "/%04d-%s.log", seq, prev);
  sceIoRemove(dest);
  if (sceIoRename(DATA_DIR "/app.log", dest) < 0) return;

  seq++;
  snprintf(idx, sizeof idx, "%d", seq);
  write_small(LOG_DIR "/next", idx);

  // Bounded, because a memory card is not infinite and nobody reads the
  // twenty-first-oldest log. Only this bridge's own naming is removed, so a
  // file dropped in here by hand survives.
  const int oldest = seq - LOG_KEEP;
  for (int i = oldest - 8; i < oldest; i++) {
    if (i < 0) continue;
    const SceUID d = sceIoDopen(LOG_DIR);
    if (d < 0) return;
    SceIoDirent e;
    memset(&e, 0, sizeof e);
    while (sceIoDread(d, &e) > 0) {
      char prefix[8];
      snprintf(prefix, sizeof prefix, "%04d-", i);
      if (strncmp(e.d_name, prefix, strlen(prefix)) == 0) {
        char victim[192];
        snprintf(victim, sizeof victim, LOG_DIR "/%s", e.d_name);
        sceIoRemove(victim);
      }
      memset(&e, 0, sizeof e);
    }
    sceIoDclose(d);
  }
}

// Which title ids this bridge has installed.
//
// The panel lists these and offers to remove them or clear their data, and it
// deliberately lists nothing else. ux0:app holds the console's own titles, and
// a delete button beside one of those, on a device with no undo, is a footgun.
//
// One id per line, appended, deduplicated on read rather than on write: the
// write happens on the install path where an extra sceIo round trip costs.
#define INSTALLED_PATH DATA_DIR "/installed.txt"

// Rewritten rather than edited in place: the file is a handful of nine-byte
// lines and a rewrite cannot leave it half-consistent the way a seek and a
// blank-out can.
static void forget_installed(const char* titleid) {
  SceUID fd = sceIoOpen(INSTALLED_PATH, SCE_O_RDONLY, 0777);
  if (fd < 0) return;
  char buf[1024] = {0};
  const int n = sceIoRead(fd, buf, sizeof buf - 1);
  sceIoClose(fd);
  if (n <= 0) return;

  char out[1024];
  int len = 0;
  const char* p = buf;
  while (*p != '\0') {
    const char* nl = strchr(p, '\n');
    const int line_len = nl != NULL ? (int)(nl - p) : (int)strlen(p);
    if (line_len > 0 &&
        !(line_len == (int)strlen(titleid) &&
          strncmp(p, titleid, (size_t)line_len) == 0) &&
        len + line_len + 1 < (int)sizeof out) {
      memcpy(out + len, p, (size_t)line_len);
      len += line_len;
      out[len++] = '\n';
    }
    if (nl == NULL) break;
    p = nl + 1;
  }
  fd = sceIoOpen(INSTALLED_PATH, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) return;
  if (len > 0) sceIoWrite(fd, out, len);
  sceIoClose(fd);
}

static int installed_has(const char* titleid) {
  const SceUID fd = sceIoOpen(INSTALLED_PATH, SCE_O_RDONLY, 0777);
  if (fd < 0) return 0;
  char buf[1024] = {0};
  const int n = sceIoRead(fd, buf, sizeof buf - 1);
  sceIoClose(fd);
  if (n <= 0) return 0;
  const char* p = buf;
  while (*p != '\0') {
    const char* nl = strchr(p, '\n');
    const int line_len = nl != NULL ? (int)(nl - p) : (int)strlen(p);
    if (line_len == (int)strlen(titleid) &&
        strncmp(p, titleid, (size_t)line_len) == 0) {
      return 1;
    }
    if (nl == NULL) break;
    p = nl + 1;
  }
  return 0;
}

// Deduplicated on write after all. It was on read, which is cheaper on the
// install path, but the bridge now records itself on every boot -- and a file
// that grows by a line each time the console is switched on is a file that
// eventually outgrows the 1 KB the readers allocate for it.
static void record_installed(const char* titleid) {
  mkdirs();
  if (installed_has(titleid)) return;
  const SceUID fd =
      sceIoOpen(INSTALLED_PATH, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_APPEND, 0777);
  if (fd < 0) return;
  char line[16];
  const int n = snprintf(line, sizeof line, "%s\n", titleid);
  sceIoWrite(fd, line, n);
  sceIoClose(fd);
}

static int title_installed(const char* titleid) {
  char dir[64];
  snprintf(dir, sizeof dir, "ux0:app/%s", titleid);
  SceIoStat st;
  return sceIoGetstat(dir, &st) >= 0;
}

// Hand the console over and end this process. Returns only if it could not.
//
// Terminal by construction, and ADR-0016's status model says so: there is no
// state after Launching, because there is no bridge after it. Launching
// another title is what unlocks the target's directory, which cannot happen
// while this process holds it.
//
// Split out of cmd_launch because the APPS tab's RUN button arrives on the
// watcher thread with no socket to answer on.
//
// The existence check is not belt and braces. sceAppMgrLaunchAppByUri on a
// title that is not installed fails quietly, and by then this process has
// exited -- so the console lands on LiveArea, which answers no port. That
// happened twice on 2026-08-31, through the APPS tab offering RUN on a title id
// still in installed.txt after the title had been deleted.
static int hand_over(const char* titleid) {
  // Never to ourselves. Launching the title that is still running and then
  // exiting is a race the shell loses: it drops to LiveArea, which answers no
  // port, and the console needs a tap to come back. Measured 2026-09-08, when
  // `selfupdate-bridge.sh --remove-updater` deleted FVTA00009 and the restart
  // that followed handed over to FVTA00001. The log ends `+ opened FVTA00001`
  // and the console was found on the home screen.
  //
  // Staying up is always the better answer, because this process is the only
  // thing on the console that answers TCP.
  if (strcmp(titleid, SELF_TITLEID) == 0) {
    note("asked to hand over to myself; staying here");
    set_status("Waiting", NULL);
    return -1;
  }
  if (!title_installed(titleid)) {
    note("%s is not installed; staying here", titleid);
    set_status("Waiting", NULL);
    return -1;
  }
  // Marked so the panel can colour it. "+ " is green and "- " is red, and that
  // is the entire convention -- the file is read as often by `get` as by the
  // screen, so the marker has to survive being plain text.
  note("+ opened %s", titleid);

  // Before the launch, not after: the engine truncates app.log on startup and
  // the launch is the last thing that happens here.
  rotate_app_log(titleid);

  // Under GL this is where the console would be lost without a teardown. The
  // bridge ran software until 2026-08-31 and this was a comment saying so;
  // it now runs GL like everything else, and the call is real.
  release_gpu();

  // Four attempts, not one, and read what each one returns.
  //
  // Opening the bridge from the LiveArea fails on the first tap and succeeds
  // on the second, often enough to be the normal case. A single launch is
  // therefore not reliable here, and every exit path in this project fired
  // exactly one and then exited. None of them read the return value either --
  // the "+ opened" line above is written before anything has been asked for,
  // so three consoles left on the home screen on 2026-09-08 are all recorded
  // as successful handovers.
  //
  // The likely reason a first attempt fails is that this process has not
  // released its memory budget yet, and the bridge asks for a 160 MB arena
  // on top of the engine's blocks. That is a guess; the error code logged here
  // is what will settle it.
  char uri[64];
  snprintf(uri, sizeof uri, "psgm:play?titleid=%s", titleid);
  int rc = -1;
  for (int attempt = 1; attempt <= 4 && rc < 0; attempt++) {
    rc = sceAppMgrLaunchAppByUri(0xFFFFF, uri);
    if (rc < 0) {
      note("launch %s attempt %d: 0x%08X", titleid, attempt, (unsigned)rc);
      sceKernelDelayThread(1500 * 1000);
    }
  }
  if (rc < 0) note("!! %s refused every launch; the console is on its own", titleid);
  // Exit at once rather than lingering: the "close the current application?"
  // prompt appears only because the outgoing app is still alive.
  sceKernelExitProcess(0);
  for (;;) sceKernelDelayThread(1000 * 1000);
  return 0;
}

static void cmd_launch(int sock) {
  // Checked before the reply, not after: the caller is a deploy script that
  // reads OK as "the console is on its way", and a script that believes that
  // wrongly waits out its whole timeout against a bridge still sitting here.
  if (!title_installed(g_target)) {
    char msg[80];
    snprintf(msg, sizeof msg, "ERR %s is not installed\n", g_target);
    note("launch %s: not installed", g_target);
    dev_server_send(sock, msg);
    return;
  }

  note("launching %s", g_target);
  set_status("Launching", "%s", g_target);

  char msg[64];
  snprintf(msg, sizeof msg, "OK launching %s\n", g_target);
  dev_server_send(sock, msg);
  sceNetSocketClose(sock);
  sceKernelDelayThread(200 * 1000);  // let the reply drain

  hand_over(g_target);
}

// --- the promoter -------------------------------------------------------
//
// How the bridge replaces *itself*, which matters more now that a Flutter
// bridge is ~20 MB rather than 91 KB. The promoter is a system service and is
// not bound by this sandbox.

// PAF, loaded the way VitaShell loads it.
//
// ScePromoterUtil imports from PAF. Until PAF is resident the promoter's library
// cannot be linked and the load is refused with MODULEMGR_NO_LIB -- which this
// bridge, the C one before it, and three ADRs all read as "the promoter is
// unavailable on this console". It is not; the error was naming its own cause.
// See experiments/promoter, in git history at c91294a.
//
// The argument block is not optional: plain sceSysmoduleLoadModuleInternal(PAF)
// faults the process. These values are VitaShell's verbatim -- 0x180000 is the
// heap PAF is given -- and buf[0] is a *size*, not flags, which is why zeroing
// a SceSysmoduleOpt and filling in only `result` was never the same call.
static int load_sce_paf(void) {
  static uint32_t argp[] = {0x180000, (uint32_t)-1, (uint32_t)-1, 1,
                            (uint32_t)-1, (uint32_t)-1};
  int result = -1;
  uint32_t buf[4];
  buf[0] = sizeof buf;
  buf[1] = (uint32_t)&result;
  buf[2] = (uint32_t)-1;
  buf[3] = (uint32_t)-1;
  return sceSysmoduleLoadModuleInternalWithArg(
      SCE_SYSMODULE_INTERNAL_PAF, sizeof argp, argp,
      (const SceSysmoduleOpt*)buf);
}

// Leaving PAF resident and then exiting rebooted the console once, which is the
// only difference from VitaShell left after the load itself started working.
// Every path out of cmd_promote goes through this.
static int unload_sce_paf(void) {
  uint32_t buf = 0;
  return sceSysmoduleUnloadModuleInternalWithArg(
      SCE_SYSMODULE_INTERNAL_PAF, 0, NULL, (const SceSysmoduleOpt*)&buf);
}

// Whether this process currently has each module resident.
//
// Tracked rather than queried, because the question these answer is not "is it
// loaded" but "did *we* load it", and the unload has to be exactly balanced.
static int g_paf_up = 0;
static int g_pu_up = 0;

// The promoter is driven in steps, and that is the point of it.
//
// It used to be one command that loaded PAF, loaded the promoter, initialised,
// promoted, and unwound all of it. That is the right shape for a feature and
// the wrong shape for an investigation: every run tested five things at once
// and the console went down about ten seconds after each.
//
// What the dumps say (experiments/promoter, c91294a): PAF starts a thread of its own,
// `ScePaf EntryCall`, and that thread takes a data abort six bytes into the PAF
// module while our threads sit idle. Every run that died had unmapped PAF
// first. Filling in the cell that is still blank -- kept resident and survived
// -- needs the load and the unload to be separate commands.
//
// Driven from here rather than from the experiment for a second reason: the
// experiment draws with debugScreen and initialises no display subsystem, while
// VitaShell, which does all of this safely, is a vita2d app with a live GXM
// context. The bridge is the only thing here with VitaShell's shape.
static void cmd_paf(int sock, const char* arg) {
  char m[192];
  if (strcmp(arg, "on") == 0) {
    if (g_paf_up) { dev_server_send(sock, "OK paf already up\n"); return; }
    const int r = load_sce_paf();
    if (r >= 0) g_paf_up = 1;
    snprintf(m, sizeof m, "%s paf load 0x%08X\n", r >= 0 ? "OK" : "ERR",
             (unsigned)r);
    note("paf on 0x%08X", (unsigned)r);
  } else if (strcmp(arg, "off") == 0) {
    const int r = unload_sce_paf();
    if (r >= 0) g_paf_up = 0;
    snprintf(m, sizeof m, "%s paf unload 0x%08X\n", r >= 0 ? "OK" : "ERR",
             (unsigned)r);
    note("paf off 0x%08X", (unsigned)r);
  } else if (strcmp(arg, "state") == 0) {
    snprintf(m, sizeof m, "OK paf=%d promoter=%d\n", g_paf_up, g_pu_up);
  } else {
    snprintf(m, sizeof m, "ERR paf on|off|state\n");
  }
  dev_server_send(sock, m);
}

// `sock` may be -1. The watcher thread calls this on behalf of the panel, which
// has no socket, and dev_server_send on a fd that was never opened is not a
// no-op -- it is a write to whatever -1 means to sceNetSend.
static void reply(int sock, const char* msg) {
  if (sock >= 0) dev_server_send(sock, msg);
}

// Load PAF if it is not up, then the promoter, then Init.
//
// A failed load stays fatal and must: an import stub for a module that is not
// resident is address zero rather than a stub returning an error, so
// "continue and let Init decide" is `blx 0`. Tried on 2026-08-22; the dump is
// a prefetch abort with PC 0.
static int promoter_up(int sock) {
  char m[192];
  if (g_pu_up) return 1;
  if (!g_paf_up) {
    const int paf = load_sce_paf();
    if (paf < 0) {
      snprintf(m, sizeof m, "ERR paf 0x%08X\n", (unsigned)paf);
      note("promoter: paf 0x%08X", (unsigned)paf);
      reply(sock, m);
      return 0;
    }
    g_paf_up = 1;
  }
  int r = sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
  if (r < 0) {
    snprintf(m, sizeof m, "ERR loadmodule 0x%08X (paf was ok)\n", (unsigned)r);
    note("promoter: load 0x%08X", (unsigned)r);
    reply(sock, m);
    return 0;
  }
  r = scePromoterUtilityInit();
  if (r < 0) {
    snprintf(m, sizeof m, "ERR init 0x%08X\n", (unsigned)r);
    note("promoter: init 0x%08X", (unsigned)r);
    reply(sock, m);
    sceSysmoduleUnloadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
    return 0;
  }
  g_pu_up = 1;
  return 1;
}

static void cmd_promoter(int sock, const char* arg) {
  char m[192];
  if (strcmp(arg, "on") == 0) {
    if (promoter_up(sock)) dev_server_send(sock, "OK promoter up\n");
    return;
  }
  if (strcmp(arg, "off") == 0) {
    // Deliberately does not touch PAF. Unloading the two together is what
    // every fatal run did, and separating them is the whole experiment.
    int r = -1;
    if (g_pu_up) {
      scePromoterUtilityExit();
      r = sceSysmoduleUnloadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
      g_pu_up = 0;
    }
    snprintf(m, sizeof m, "OK promoter off 0x%08X (paf still %d)\n",
             (unsigned)r, g_paf_up);
    dev_server_send(sock, m);
    return;
  }
  snprintf(m, sizeof m, "ERR promoter on|off\n");
  dev_server_send(sock, m);
}

// Wait out an operation and report both halves of its answer.
//
// sync=1 is documented to block and is not trusted, so GetState is polled.
// GetResult is read separately because a call can be accepted and still fail:
// the return value says accepted, the result says what happened.
//
// Returns 0 when the call was accepted and its result is 0, else the result
// (or the call's own error when it was not accepted), for the callers that
// go on to do something with the outcome rather than just report it.
static int promoter_finish(int sock, const char* what, int r,
                           const char* titleid) {
  char m[224];
  int state = -1, res = -1;
  if (r >= 0) {
    for (int i = 0; i < 600; i++) {
      if (scePromoterUtilityGetState(&state) < 0) break;
      if (state == 0) break;
      sceKernelDelayThread(100 * 1000);
    }
    scePromoterUtilityGetResult(&res);
  }
  const int ok = (r >= 0 && res == 0);
  if (ok && titleid != NULL && titleid[0] != '\0') record_installed(titleid);
  snprintf(m, sizeof m, "%s %s call=0x%08X state=%d result=0x%08X\n",
           ok ? "OK" : "ERR", what, (unsigned)r, state, (unsigned)res);
  note("%s %s (result 0x%08X)", what, ok ? "ok" : "failed", (unsigned)res);
  set_status("Waiting", NULL);
  // reply, not dev_server_send: the panel's delete arrives on the watcher
  // thread with sock = -1 and nothing to answer on.
  reply(sock, m);
  return ok ? 0 : (r < 0 ? r : res);
}

// The three ways in, kept as three commands because they want different things
// of the directory and nothing here knows which this console accepts.
//
//   promote      PromotePkg. What the bridge has always called.
//   promoterif   PromotePkgWithRif. What VitaShell calls, and it builds a
//                sce_sys/package/head.bin with three HMAC-SHA1 signatures first.
//   import       PromoteImport, documented as installing Content Manager import
//                content "without checking license files", and the only one
//                handed the title id rather than reading it out of the package.
//
// None of them unloads anything afterwards. See cmd_paf.

// `<dir> [titleid]`. The id is optional and only ever records what was
// installed for the panel's apps list -- the promoter reads the package's own
// param.sfo. Split here rather than reading the sfo in C: the caller already
// parsed it to name the head.bin.
static const char* split_titleid(char* arg) {
  char* sp = strrchr(arg, ' ');
  if (sp == NULL) return NULL;
  *sp = '\0';
  return sp + 1;
}

static void cmd_promote(int sock, char* arg) {
  const char* titleid = split_titleid(arg);
  set_status("Installing", "promoting %s", arg);
  if (!promoter_up(sock)) { set_status("Waiting", NULL); return; }
  note("promote %s", arg);
  promoter_finish(sock, "promote", scePromoterUtilityPromotePkg(arg, 1),
                  titleid);
}

static void cmd_promote_rif(int sock, char* arg) {
  const char* titleid = split_titleid(arg);
  set_status("Installing", "promoting %s with rif", arg);
  if (!promoter_up(sock)) { set_status("Waiting", NULL); return; }
  note("promoterif %s", arg);
  promoter_finish(sock, "promoterif",
                  scePromoterUtilityPromotePkgWithRif(arg, 1), titleid);
}

// `import <dir> <titleid>`
static void cmd_import(int sock, const char* args) {
  char m[192];
  const char* sp = strchr(args, ' ');
  if (sp == NULL) {
    dev_server_send(sock, "ERR import <dir> <titleid>\n");
    return;
  }
  ScePromoterUtilityImportParams p;
  memset(&p, 0, sizeof p);
  const size_t dirlen = (size_t)(sp - args);
  if (dirlen >= sizeof p.path) {
    dev_server_send(sock, "ERR path too long\n");
    return;
  }
  memcpy(p.path, args, dirlen);
  snprintf(p.titleid, sizeof p.titleid, "%s", sp + 1);
  p.type = SCE_PKG_TYPE_VITA;
  // 0x00 on Vita content, 0x01 on PSM, per the header's own note.
  p.attribute = 0;
  set_status("Installing", "importing %s as %s", p.path, p.titleid);
  if (!promoter_up(sock)) { set_status("Waiting", NULL); return; }
  note("import %s as %s", p.path, p.titleid);
  snprintf(m, sizeof m, "  path=%s titleid=%s\n", p.path, p.titleid);
  dev_server_send(sock, m);
  promoter_finish(sock, "import", scePromoterUtilityPromoteImport(&p),
                  p.titleid);
}

static void cmd_exist(int sock, const char* titleid) {
  char m[192];
  if (!promoter_up(sock)) return;
  int res = -1;
  const int r = scePromoterUtilityCheckExist(titleid, &res);
  snprintf(m, sizeof m, "OK exist %s call=0x%08X res=%d\n", titleid,
           (unsigned)r, res);
  dev_server_send(sock, m);
}

// Recursively empty a directory, and only ever under ux0:data.
//
// install-vpk.sh stages an extracted package into ux0:data/pkg and the promoter
// reads whatever is in there, so a file left by a previous install becomes part
// of the next package.
//
// The prefix check is not decoration. This is a recursive delete on an
// unauthenticated socket, and the bridge runs as an UNSAFE self, so
// `rmtree ux0:app` would be honoured. Confined to ux0:data, the worst it can do
// is cost a redeploy.
#define RMTREE_ROOT "ux0:data/"

static int rmtree(const char* path, int depth, int* removed) {
  // Depth is bounded rather than trusted. A directory loop is not supposed to
  // be possible on this filesystem, and an unbounded recursion here would take
  // the stack out rather than return an error.
  if (depth > 8) return -1;
  const SceUID d = sceIoDopen(path);
  if (d < 0) return d;
  SceIoDirent e;
  memset(&e, 0, sizeof e);
  while (sceIoDread(d, &e) > 0) {
    if (strcmp(e.d_name, ".") == 0 || strcmp(e.d_name, "..") == 0) {
      memset(&e, 0, sizeof e);
      continue;
    }
    char child[256];
    snprintf(child, sizeof child, "%s/%s", path, e.d_name);
    if (SCE_S_ISDIR(e.d_stat.st_mode)) {
      rmtree(child, depth + 1, removed);
      sceIoRmdir(child);
    } else if (sceIoRemove(child) >= 0) {
      (*removed)++;
    }
    memset(&e, 0, sizeof e);
  }
  sceIoDclose(d);
  return 0;
}

static void cmd_rmtree(int sock, const char* path) {
  char m[256];
  if (strncmp(path, RMTREE_ROOT, sizeof RMTREE_ROOT - 1) != 0) {
    snprintf(m, sizeof m, "ERR rmtree is confined to %s\n", RMTREE_ROOT);
    dev_server_send(sock, m);
    return;
  }
  // Rejected rather than treated as the root: `rmtree ux0:data/` with a
  // trailing slash and nothing after it passes the prefix test above.
  if (path[sizeof RMTREE_ROOT - 1] == '\0') {
    dev_server_send(sock, "ERR rmtree needs a directory under " RMTREE_ROOT "\n");
    return;
  }
  // What the path is, before doing anything to it. This used to go straight to
  // rmtree() and report OK whatever came back, so `rmtree` on a plain file
  // answered "OK rmtree <path> (0 files, dopen 0x80010014)" -- the dopen had
  // failed with ENOTDIR, nothing had been removed, and the caller was told the
  // directory was clear. An OK that means "I did nothing" is worse than an
  // error, because it is believed.
  SceIoStat st;
  memset(&st, 0, sizeof st);
  if (sceIoGetstat(path, &st) < 0) {
    // A path that was not there is the ordinary case for a caller clearing a
    // staging directory before using it, so it is not an error.
    snprintf(m, sizeof m, "OK rmtree %s (nothing there)\n", path);
    dev_server_send(sock, m);
    return;
  }
  if (!SCE_S_ISDIR(st.st_mode)) {
    snprintf(m, sizeof m, "ERR rmtree %s is a file; use `rm`\n", path);
    dev_server_send(sock, m);
    return;
  }
  int removed = 0;
  const int r = rmtree(path, 0, &removed);
  const int rd = sceIoRmdir(path);
  if (r < 0) {
    snprintf(m, sizeof m, "ERR rmtree %s dopen 0x%08X (%d files removed)\n",
             path, (unsigned)r, removed);
    note("rmtree %s failed 0x%08X after %d files", path, (unsigned)r, removed);
    dev_server_send(sock, m);
    return;
  }
  snprintf(m, sizeof m, "OK rmtree %s (%d files, rmdir 0x%08X)\n", path,
           removed, (unsigned)rd);
  note("rmtree %s: %d files", path, removed);
  dev_server_send(sock, m);
}

// Remove one file, anywhere.
//
// Not confined the way rmtree is, and the reason is that the confinement would
// buy nothing: `put` already writes any path on this unauthenticated socket, so
// anything `rm` could destroy could already be overwritten with a byte. What is
// worth confining is recursion, and this has none -- it removes the single path
// it was given and refuses a directory.
//
// It exists for tools/deploy.sh. The deploy pushes the files the build has and
// used to say nothing about the ones it no longer has, so a file dropped from a
// package stayed in ux0:app/<titleid> for the life of the install. On
// 2026-09-09 that was assets/fonts/NotoEmoji-Regular.ttf: removed from the repo
// and the package, redeployed clean, and still 1,982,596 bytes on the console
// and still a candidate for every codepoint the font stack was asked for.
static void cmd_rm(int sock, const char* path) {
  char m[320];
  SceIoStat st;
  memset(&st, 0, sizeof st);
  if (sceIoGetstat(path, &st) < 0) {
    // Already gone is the outcome the caller wanted, and a deploy that removes
    // the same stale file twice should not read as a failure. It still says so.
    snprintf(m, sizeof m, "OK rm %s (not there)\n", path);
    dev_server_send(sock, m);
    return;
  }
  if (SCE_S_ISDIR(st.st_mode)) {
    snprintf(m, sizeof m, "ERR rm %s is a directory; use `rmtree`\n", path);
    dev_server_send(sock, m);
    return;
  }
  const int r = sceIoRemove(path);
  if (r < 0) {
    // ux0:app/<self> is the read-only app0: mount and answers here; see the
    // note on SELF_TITLEID.
    snprintf(m, sizeof m, "ERR rm %s 0x%08X\n", path, (unsigned)r);
    dev_server_send(sock, m);
    return;
  }
  snprintf(m, sizeof m, "OK rm %s (%lld bytes)\n", path,
           (long long)st.st_size);
  note("rm %s", path);
  dev_server_send(sock, m);
}

// After a delete, stay up.
//
// This used to relaunch the bridge. The reasoning was that a delete takes
// this process down a few seconds later for reasons nobody has found, so it
// restarted first and got ahead of the death.
//
// The restart was the worse failure. It handed over to this bridge's own
// slot, and on 2026-09-08 that left the console on LiveArea with nothing
// answering a port, which is the exact outcome the restart existed to avoid.
// The delete itself had already succeeded.
//
// hand_over refuses its own title id now, so this only records what happened.
// If the unexplained death is real it shows up as a gap in the log, and the
// answer to it is something outside this process that can start it again --
// the supervisor on port 1342 -- not an exit taken on purpose.
static void after_delete(void) {
  note("delete done; staying up");
  set_status("Waiting", NULL);
}

// Unregister a title. The other half of promote, and the only way to take a
// title id back once it has been handed out.
//
// Through promoter_finish like every other promoter call, and it was not until
// 2026-09-01. It fired DeletePkg and answered on the spot, so `OK delete
// FVTA00009 0x00000000` meant the request had been accepted and nothing more.
// The bridge then went back to serving the panel -- which lists ux0:app on
// every poll -- while the promoter's worker was still removing a title from
// under that enumeration. Twice that evening the bridge went down within a
// second of a delete and left the console on LiveArea.
//
// The wait is the fix, and reading the result is the other half: a call can be
// accepted and still fail, and reporting the accept as success is how a title
// that is still there gets called gone.
// The delete runs on a thread of its own, and the caller is answered at once.
//
// scePromoterUtilityDeletePkg does not return promptly. On 2026-09-08 one call
// held the dev server thread from 23:15 to 00:44 by the console's clock, while
// the UI stalled in fifteen consecutive gaps of almost exactly ten seconds --
// a fixed timeout being retried, not work being done. Nothing answered port
// 1341 for the whole of it, so every host tool reported a dead console and the
// obvious reading was that the bridge had crashed. It had not: it presented
// 318 frames during the same window.
//
// Answering immediately costs a synchronous result and buys a bridge that
// stays reachable while the promoter grinds. The outcome goes to the log and
// the status line, which the panel shows and `log` returns.
static char g_deleting[16];

static void delete_run(void) {
  set_status("Deleting", "removing %s", g_deleting);
  note("delete %s", g_deleting);
  // -1: there is no socket to answer on from here. promoter_finish reports
  // through reply(), which tolerates that. NULL because promoter_finish
  // records a title id as *installed* on success, the opposite of this.
  promoter_finish(-1, "delete", scePromoterUtilityDeletePkg(g_deleting), NULL);
  forget_installed(g_deleting);
  after_delete();
}

// Ends by deleting itself, the kernel object and newlib's record both: an
// ended thread stays allocated until someone deletes it, and nothing here
// keeps the id (see fvita_plugin.h).
static int delete_thread(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  delete_run();
  fvita_thread_exit_delete();
}

// Returns 0 if the thread could not be started.
static int start_delete(const char* titleid) {
  snprintf(g_deleting, sizeof g_deleting, "%s", titleid);
  const SceUID th = sceKernelCreateThread("fvita_delete", delete_thread,
                                          0x10000100, 32 * 1024, 0, 0, NULL);
  if (th < 0) {
    note("delete thread failed 0x%08X", (unsigned)th);
    return 0;
  }
  sceKernelStartThread(th, 0, NULL);
  return 1;
}

static void cmd_delete(int sock, const char* titleid) {
  if (strcmp(titleid, SELF_TITLEID) == 0) {
    dev_server_send(sock, "ERR refusing to delete the bridge\n");
    return;
  }
  if (!promoter_up(sock)) return;
  if (!start_delete(titleid)) {
    dev_server_send(sock, "ERR could not start the delete\n");
    return;
  }
  dev_server_send(sock, "OK delete started; it reports to the log\n");
}

// `ls` reports names and no sizes, so verifying a `put` landed whole needed a
// 14 MB `get` back. This is the same answer in twelve bytes.
static void cmd_stat(int sock, const char* path) {
  char m[96];
  SceIoStat st;
  memset(&st, 0, sizeof st);
  const int r = sceIoGetstat(path, &st);
  if (r < 0) {
    snprintf(m, sizeof m, "ERR stat 0x%08X\n", (unsigned)r);
  } else {
    snprintf(m, sizeof m, "%lld %s\n", (long long)st.st_size,
             SCE_S_ISDIR(st.st_mode) ? "dir" : "file");
  }
  dev_server_send(sock, m);
}

// Kept when almost everything else was dropped, because it has repeatedly
// answered "is this path writable" without a rebuild -- twice in the session
// that produced ADR-0016 alone.
static void cmd_ls(int sock, const char* path) {
  char m[320];
  const SceUID d = sceIoDopen(path);
  if (d < 0) {
    snprintf(m, sizeof m, "ERR dopen 0x%08X\n", (unsigned)d);
    dev_server_send(sock, m);
    return;
  }
  SceIoDirent e;
  int count = 0;
  memset(&e, 0, sizeof e);
  while (sceIoDread(d, &e) > 0 && count < 200) {
    snprintf(m, sizeof m, "%s %s\n",
             SCE_S_ISDIR(e.d_stat.st_mode) ? "d" : "-", e.d_name);
    dev_server_send(sock, m);
    memset(&e, 0, sizeof e);
    count++;
  }
  sceIoDclose(d);
  snprintf(m, sizeof m, "(%d entries)\n", count);
  dev_server_send(sock, m);
}

// ------------------------------------------------------ installing a vpk
//
// The FILES tab's INSTALL button, and `installvpk <path>` on the socket.
// What tools/install-vpk.sh does from the host, done here from a vpk that is
// already on the card (LocalSend puts them in ux0:downloads): unpack into
// ux0:data/pkg without the LiveArea art and the supervisor pair, read the
// title id out of sce_sys/param.sfo, write sce_sys/package/head.bin for it,
// promote, then copy the art into ux0:app/<id>. vpk.c does the bytes; this
// does the order, the promoter and the reporting.
//
// The header template is this bridge's own app0:sce_sys/package/head.bin:
// the promoter wrote it, so it has the format the promoter reads, and every
// bridge has one. Nothing is embedded.
//
// On a thread, like delete, for the same reason: the promoter takes its
// time, and the dev server and the panel stay answerable meanwhile. Progress
// goes to a file the FILES tab polls -- one line, `<phase> <done> <total>
// <name>` -- and to the status line, and the outcome to the log.
#define STAGE_DIR "ux0:data/pkg"
#define INSTALL_PROGRESS_PATH DATA_DIR "/install-progress.txt"

static char g_install_vpk[256];
static volatile int g_install_busy;

static void install_progress(const char* phase, const char* name,
                             uint64_t done, uint64_t total) {
  char line[320];
  const int n = snprintf(line, sizeof line, "%s %llu %llu %s\n", phase,
                         (unsigned long long)done, (unsigned long long)total,
                         name);
  const SceUID fd = sceIoOpen(INSTALL_PROGRESS_PATH,
                              SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) return;
  sceIoWrite(fd, line, n);
  sceIoClose(fd);
}

static void on_unpack(void* ctx, const char* name, uint64_t done,
                      uint64_t total) {
  install_progress((const char*)ctx, name, done, total);
}

static void install_failed(const char* fmt, ...) {
  char why[200];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(why, sizeof why, fmt, ap);
  va_end(ap);
  note("install failed: %s", why);
  set_status("Waiting", NULL);
  install_progress("failed", why, 0, 0);
}

static void install_run(void) {
  char err[160] = "";
  char titleid[16] = "";
  const char* vpk = g_install_vpk;
  const char* slash = strrchr(vpk, '/');
  const char* base = slash != NULL ? slash + 1 : vpk;

  note("install %s", vpk);
  set_status("Installing", "unpacking %s", base);
  install_progress("unpacking", base, 0, 0);
  // Cleared first, as install-vpk.sh does: the promoter reads the whole
  // staging directory, so a file left by a previous install of something
  // else becomes part of this package.
  int removed = 0;
  rmtree(STAGE_DIR, 0, &removed);
  sceIoMkdir(STAGE_DIR, 0777);
  if (vpk_extract(vpk, STAGE_DIR, VPK_STAGE, on_unpack, "unpacking", err,
                  sizeof err) < 0) {
    install_failed("%s", err);
    g_install_busy = 0;
    return;
  }
  if (vpk_title_id(STAGE_DIR "/sce_sys/param.sfo", titleid, sizeof titleid) < 0) {
    install_failed("no title id in sce_sys/param.sfo");
    g_install_busy = 0;
    return;
  }
  // A vpk carrying the bridge's own id would replace the process that is
  // installing it; that route is tools/selfupdate-bridge.sh, from the host,
  // through the scratch bridge.
  if (strcmp(titleid, SELF_TITLEID) == 0) {
    install_failed("%s is this bridge; update it from the host", titleid);
    g_install_busy = 0;
    return;
  }
  set_status("Installing", "promoting %s", titleid);
  install_progress("header", titleid, 0, 0);
  if (vpk_write_head("app0:sce_sys/package/head.bin",
                     STAGE_DIR "/sce_sys/package/head.bin", titleid, err,
                     sizeof err) < 0) {
    install_failed("%s", err);
    g_install_busy = 0;
    return;
  }
  install_progress("promoting", titleid, 0, 0);
  if (!promoter_up(-1)) {
    install_failed("the promoter would not start");
    g_install_busy = 0;
    return;
  }
  note("promoterif %s %s", STAGE_DIR, titleid);
  const int res = promoter_finish(
      -1, "promoterif", scePromoterUtilityPromotePkgWithRif(STAGE_DIR, 1),
      titleid);
  if (res != 0) {
    // 0x8010111C no header, 0x80871004 bad digest, 0x80870005 another
    // title's header, 0x8010113D art that is not 8-bit indexed.
    install_failed("promote %s: 0x%08X", titleid, (unsigned)res);
    g_install_busy = 0;
    return;
  }
  // The shell reads the art out of ux0:app/<id>/sce_sys, not out of the
  // package, so it goes in after. A failure here leaves a working title
  // with a blank bubble, which is worth a note and not a failure.
  char appdir[64];
  snprintf(appdir, sizeof appdir, "ux0:app/%s", titleid);
  set_status("Installing", "art for %s", titleid);
  if (vpk_extract(vpk, appdir, VPK_ART, on_unpack, "art", err, sizeof err) < 0) {
    note("livearea art: %s", err);
  }
  note("installed %s from %s", titleid, base);
  set_status("Waiting", NULL);
  install_progress("done", titleid, 1, 1);
  g_install_busy = 0;
}

static int install_thread(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  install_run();
  fvita_thread_exit_delete();
}

// Returns 0 with `why` set when it could not start.
static int start_install(const char* vpk, char* why, size_t cap) {
  if (g_install_busy) {
    snprintf(why, cap, "an install is already running");
    return 0;
  }
  if (strncmp(vpk, "ux0:", 4) != 0 && strncmp(vpk, "uma0:", 5) != 0 &&
      strncmp(vpk, "app0:", 5) != 0) {
    snprintf(why, cap, "not a path on the console: %s", vpk);
    return 0;
  }
  g_install_busy = 1;
  snprintf(g_install_vpk, sizeof g_install_vpk, "%s", vpk);
  // 64 KB: zlib keeps its window on the heap and vpk.c its buffers too, but
  // the thread stacks a few path-sized arrays.
  const SceUID th = sceKernelCreateThread("fvita_install", install_thread,
                                          0x10000100, 64 * 1024, 0, 0, NULL);
  if (th < 0) {
    g_install_busy = 0;
    snprintf(why, cap, "install thread failed 0x%08X", (unsigned)th);
    return 0;
  }
  sceKernelStartThread(th, 0, NULL);
  return 1;
}

static void cmd_installvpk(int sock, const char* vpk) {
  char why[200];
  if (!start_install(vpk, why, sizeof why)) {
    char m[224];
    snprintf(m, sizeof m, "ERR %s\n", why);
    dev_server_send(sock, m);
    return;
  }
  dev_server_send(sock,
                  "OK install started; it reports to the log and to " INSTALL_PROGRESS_PATH "\n");
}

// ------------------------------------------------------------- the dispatch

static int handle(int sock, const char* line, int* stop) {
  g_last_cmd = (SceInt64)sceKernelGetProcessTimeWide();
  // Shadows the dev server's own `pong`, so that a reply identifies what
  // answered. tools/update-bridge.sh greps for it, and the alternative --
  // a bare "pong" from whatever happens to hold the port -- is how you
  // promote a bridge over an app.
  //
  // The fourth field is this bridge's own slot. A scratch bridge on 1342
  // is the same program in a different title, and "which one am I talking to"
  // has cost a deploy before. Appended rather than inserted, so the parsers
  // that read three fields still read three fields.
  if (strcmp(line, "ping") == 0) {
    char m[80];
    snprintf(m, sizeof m, "pong bridge %s %d %s\n", TARGET_TITLEID,
             BRIDGE_PORT, SELF_TITLEID);
    dev_server_send(sock, m);
    return 1;
  }
  if (strncmp(line, "stage ", 6) == 0) {
    const int size = atoi(line + 6);
    if (size <= 0 || size > 64 * 1024 * 1024) {
      dev_server_send(sock, "ERR size\n");
      return 1;
    }
    receive_to(sock, STAGED, size, "staged");
    return 1;
  }
  if (strncmp(line, "put ", 4) == 0) {
    // `put <size> <path>`
    const char* rest = line + 4;
    const char* space = strchr(rest, ' ');
    if (space == NULL) {
      dev_server_send(sock, "ERR usage: put <size> <path>\n");
      return 1;
    }
    const int size = atoi(rest);
    if (size <= 0 || size > 64 * 1024 * 1024) {
      dev_server_send(sock, "ERR size\n");
      return 1;
    }
    char dest[256];
    snprintf(dest, sizeof dest, "%s", space + 1);
    // The destination's parent is not always there -- update-bridge.sh streams
    // a whole extracted vpk into a staging tree it has never created.
    for (char* p = strchr(dest, '/'); p != NULL; p = strchr(p + 1, '/')) {
      *p = '\0';
      sceIoMkdir(dest, 0777);
      *p = '/';
    }
    // The panel's own command file is written by tools/panel.sh several times
    // a minute and is nine bytes. Logging it turns the DEPLOY console into a
    // list of `put 9 B`, which is the one thing that screen is for.
    if (strcmp(dest, PANEL_REQUEST_PATH) == 0) {
      receive_to(sock, dest, size, NULL);
      return 1;
    }
    set_status("Receiving", "%s", space + 1);
    receive_to(sock, dest, size, "put");
    return 1;
  }
  if (strncmp(line, "install", 7) == 0 &&
      (line[7] == '\0' || line[7] == ' ')) {
    set_target(line[7] == ' ' ? line + 8 : NULL);
    cmd_install(sock);
    return 1;
  }
  if (strncmp(line, "launch", 6) == 0 && (line[6] == '\0' || line[6] == ' ')) {
    set_target(line[6] == ' ' ? line + 7 : NULL);
    // No `*stop = 1` here. It used to sit on the next line, which was correct
    // for as long as cmd_launch could not fail. It can now -- it refuses a title
    // that is not installed -- and `stop` closes the listening socket and ends
    // the dev server thread, so the first refused launch left the bridge on
    // screen and unreachable. A launch that succeeds never returns here.
    cmd_launch(sock);
    return 1;
  }
  if (strncmp(line, "promote ", 8) == 0) {
    cmd_promote(sock, (char*)line + 8);
    return 1;
  }
  if (strncmp(line, "promoterif ", 11) == 0) {
    cmd_promote_rif(sock, (char*)line + 11);
    return 1;
  }
  if (strncmp(line, "installvpk ", 11) == 0) {
    cmd_installvpk(sock, line + 11);
    return 1;
  }
  if (strncmp(line, "import ", 7) == 0) {
    cmd_import(sock, line + 7);
    return 1;
  }
  if (strncmp(line, "exist ", 6) == 0) {
    cmd_exist(sock, line + 6);
    return 1;
  }
  if (strncmp(line, "rmtree ", 7) == 0) {
    cmd_rmtree(sock, line + 7);
    return 1;
  }
  // Before `rmtree` would be wrong -- "rmtree " does not start with "rm " --
  // but keep them adjacent so neither is read without the other.
  if (strncmp(line, "rm ", 3) == 0) {
    cmd_rm(sock, line + 3);
    return 1;
  }
  if (strncmp(line, "delete ", 7) == 0) {
    cmd_delete(sock, line + 7);
    return 1;
  }
  if (strncmp(line, "paf ", 4) == 0) {
    cmd_paf(sock, line + 4);
    return 1;
  }
  if (strncmp(line, "promoter ", 9) == 0) {
    cmd_promoter(sock, line + 9);
    return 1;
  }
  if (strncmp(line, "ls ", 3) == 0) {
    cmd_ls(sock, line + 3);
    return 1;
  }
  if (strncmp(line, "stat ", 5) == 0) {
    cmd_stat(sock, line + 5);
    return 1;
  }
  return 0;
}

// --------------------------------------------------------------- the watcher
//
// The address is the reason this screen exists. Nothing else notices it change:
// the dev server learns the IP once at startup, and the command handler runs
// only when a client is already connected, which is exactly the case that
// cannot happen when the address is wrong.
//
// Started from the dev server's ready handler and never from the constructor.
// A Vita import stub for a non-resident module is address zero, so calling
// sceNetCtlInetGetInfo before SCE_SYSMODULE_NET is loaded is `blx 0`. That is
// what the first version of this file did, and why
// dev_server_set_ready_handler exists.

// What the panel asks the C layer to do, and why it is a file.
//
// The panel can clear a log or delete an app's data directory by itself. What
// it cannot do is delete a *title*, because that goes through the promoter, and
// the promoter lives on this side.
//
// ADR-0016 decision 3 keeps the reliability-critical half free of a platform
// channel, and the panel already learns everything by polling a file this side
// writes. A file the panel writes and this side polls is the same arrangement
// pointed the other way, and a request that arrives while Flutter is dead
// simply never arrives.
//
// One line -- `delete <titleid>`, `launch <titleid>`, `install <vpk path>`,
// `wifi` -- removed before it is acted on so a crash in the middle cannot replay it on
// the next boot.
#define REQUEST_PATH DATA_DIR "/bridge-request.txt"

// The panel's WI-FI button, shown while there is no network.
//
// Fixed URIs only, never text from the request file: anything can `put` that
// file, and settings_dlg: has a page that formats the memory card
// (settings_dlg:reset::format_mc_for_promote).
//
// settings_dlg:wifi is a guess from the pages that are known
// (settings_dlg:wifi::wps, settings_dlg:wifi::manual), so a refusal falls back
// to the top of Settings. 0x20000 opens Settings over this process, the way
// vita-uriCaller calls these URIs; the bridge stays alive behind it and comes
// back with the PS button.
static void open_wifi_settings(void) {
  int rc = sceAppMgrLaunchAppByUri(0x20000, "settings_dlg:wifi");
  if (rc < 0) {
    const int first = rc;
    rc = sceAppMgrLaunchAppByUri(0x20000, "settings_dlg:");
    if (rc < 0) {
      note("Settings did not open: 0x%08X, then 0x%08X", (unsigned)first,
           (unsigned)rc);
    }
  }
}

static void serve_request(void) {
  const SceUID fd = sceIoOpen(REQUEST_PATH, SCE_O_RDONLY, 0777);
  if (fd < 0) return;
  char buf[320] = {0};
  const int n = sceIoRead(fd, buf, sizeof buf - 1);
  sceIoClose(fd);
  sceIoRemove(REQUEST_PATH);
  if (n <= 0) return;
  for (int i = 0; i < n; i++) {
    if (buf[i] == '\n' || buf[i] == '\r') { buf[i] = '\0'; break; }
  }

  if (strncmp(buf, "delete ", 7) == 0) {
    const char* titleid = buf + 7;
    if (strcmp(titleid, SELF_TITLEID) == 0) {
      note("panel asked to delete the bridge; refused");
      return;
    }
    if (!promoter_up(-1)) {
      note("delete %s: promoter would not start", titleid);
      return;
    }
    start_delete(titleid);
  } else if (strncmp(buf, "launch ", 7) == 0) {
    const char* titleid = buf + 7;
    if (strcmp(titleid, SELF_TITLEID) == 0) {
      note("panel asked to launch the bridge; already here");
      return;
    }
    note("panel launch %s", titleid);
    set_status("Launching", "%s", titleid);
    // Long enough for one publish and one poll, so the screen says Launching
    // before it goes. Without it the panel's last frame is whatever it drew
    // half a second ago, which reads as a freeze.
    sceKernelDelayThread(600 * 1000);
    hand_over(titleid);
  } else if (strncmp(buf, "install ", 8) == 0) {
    char why[200];
    if (!start_install(buf + 8, why, sizeof why)) {
      note("install refused: %s", why);
      install_progress("failed", why, 0, 0);
    }
  } else if (strcmp(buf, "wifi") == 0) {
    open_wifi_settings();
  } else {
    note("unknown panel request: %s", buf);
  }
}

static int watcher(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  char last[24] = "";
  unsigned ticks = 0;
  for (;;) {
    SceNetCtlInfo info;
    const int r =
        sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_IP_ADDRESS, &info);
    const int up = (r >= 0 && info.ip_address[0] != '\0' &&
                    strcmp(info.ip_address, "0.0.0.0") != 0);
    if (up) {
      if (strcmp(last, info.ip_address) != 0) {
        snprintf(last, sizeof last, "%s", info.ip_address);
        snprintf(g_ip, sizeof g_ip, "%s", info.ip_address);
        // No DEPLOY line: the header shows the address, and the status
        // below says when the network goes.
        // Only from a state the address invalidates. A transfer in flight is
        // still in flight; saying "Waiting" over it would be a lie the panel
        // has no way to take back.
        if (strcmp(g_status, "Waiting") != 0 &&
            strcmp(g_status, "Starting") != 0 &&
            strcmp(g_status, "No network") != 0) {
          publish();
        } else {
          set_status("Waiting", NULL);
        }
      }
    } else if (last[0] != '\0' || g_status[0] == 'S' /* Starting */) {
      last[0] = '\0';
      g_ip[0] = '\0';
      set_status("No network", "tap WI-FI to open the Wi-Fi settings");
    }
    serve_request();

    // Republish on a slow tick so "last heard from a host" ages on screen
    // instead of freezing at whatever it said when something last happened.
    // Every fifth pass, not every one: this is a write to the memory card and
    // the number it refreshes is measured in minutes.
    if (++ticks % 5 == 0) publish();
    sceKernelDelayThread(2 * 1000 * 1000);
  }
  return 0;  // not reached; sceKernelCreateThread wants the signature
}

// Registered before main(), which is the whole point: the embedder calls
// StartDevServer() as its first act, and the port has to be ours by then.
static void on_network_ready(void) {
  const SceUID th = sceKernelCreateThread("fvita_bridge_watch", watcher,
                                          0x10000100, 16 * 1024, 0, 0, NULL);
  if (th < 0) {
    // Not fatal, and worth saying so on the panel rather than in a log nobody
    // pulls: without the watcher the address never appears, which looks
    // exactly like the Wi-Fi being down.
    note("watcher thread failed 0x%08X", (unsigned)th);
    return;
  }
  sceKernelStartThread(th, 0, NULL);
}

__attribute__((constructor)) static void bridge_register(void) {
  dev_server_set_port(BRIDGE_PORT);
  dev_server_set_command_handler(handle);
  dev_server_set_ready_handler(on_network_ready);
  dev_server_set_minimal(1);

  // Safe from here: sceIo is available to a constructor, and this is the only
  // state the screen can show before the network exists.
  mkdirs();
  // Before main(), and that is the whole point.
  //
  // The engine opens its log with O_TRUNC as the first line of main(), and now
  // that the bridge runs GL it shares app.log with every app -- so without
  // this, opening the bridge after a crash destroys the log of the crash.
  // Measured on 2026-08-28 chasing keklist's emoji grid.

  rotate_app_log("bridge");
  // The DEPLOY tab starts empty: no line for the bridge starting, none for
  // the app it came back from, none for the log it archived. Until 2026-10-01
  // it opened with four such lines, and none of them was a thing that was done.
  start_deploy_log();
  publish();
}
