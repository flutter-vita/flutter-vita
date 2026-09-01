// The loader's C layer: the port, the commands, and the state the screen reads.
//
// ADR-0016. The loader is an ordinary Flutter-Vita application built from
// templates/vita-app, and this is the one translation unit that makes it a
// loader rather than an app. It registers itself from a constructor, which
// runs before main() and therefore before the embedder's StartDevServer(),
// so by the time the engine begins its ~3 second startup the socket is
// already listening. If Flutter never comes up, the loader still works and
// only the screen is lost -- decision 3, and what makes decision 1 affordable.
//
// The Dart side never calls into any of this. It polls a small text file this
// layer writes, which costs a rewrite per state change and buys not adding a
// platform channel to the one component with the strongest reliability
// requirement. dart:io reads it: apps/conformance measured that File and
// Directory work against ux0:data.

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

// Overridable so a loader under test can be installed beside the working one.
// Replacing FVTA00001 in place with something unproven costs the only deploy
// path there is.
#ifndef LOADER_PORT
#define LOADER_PORT 1341
#endif
// Which slot this loader occupies. Used only to refuse to delete itself; the
// loader cannot write its own directory anyway, but the promoter can, and
// `delete` goes through the promoter.
#ifndef LOADER_SELF_TITLEID
#define LOADER_SELF_TITLEID "FVTA00001"
#endif
#ifndef LOADER_TARGET_TITLEID
#define LOADER_TARGET_TITLEID "FVTA00002"
#endif

#define DATA_DIR "ux0:data/flutter-vita"
#define STAGED DATA_DIR "/staged-eboot.bin"
#define STATE_PATH DATA_DIR "/loader-state.txt"
// The panel reads this one and removes it; see readPanelRequest in device.dart.
#define PANEL_REQUEST_PATH DATA_DIR "/panel-request.txt"
// What the DEPLOY console reads. Survives the launch that ends this process.
#define DEPLOY_LOG DATA_DIR "/deploy.log"
#define STATE_TMP DATA_DIR "/loader-state.tmp"

// The engine's debug HUD -- frame rate, damage, blit cost, free memory -- is
// drawn over the top-right corner of every frame from a weak symbol, and a
// strong definition here wins. Off for the loader, and not because it is
// noisy: this screen is the product (ADR-0016 decision 1), and a showcase
// with a diagnostic overlay bolted to its corner is a worse advertisement
// than no showcase. It can still be turned back on for a frame-rate question
// by deleting this line and rebuilding.
int flutter_vita_debug_overlay = 0;

// The GPU, like every other app.
//
// ADR-0016 decision 7 said software, and the reason was sound at the time: a
// hard crash under GL can wedge the console, and the loader was the only thing
// that could recover from a crash -- so it was the last component permitted to
// cause an unrecoverable one. That premise expired when FVTA00009 shipped. The
// updater is 50 KB of debugScreen with no engine and no GPU, it can rewrite
// ux0:app/FVTA00001 from the memory card, and it restores the previous eboot
// on L. Recovery no longer runs through this binary.
//
// Two things this switch drags with it, both handled below rather than
// discovered later. sceGxm has to be released before handing over to another
// title, or the console locks up hard enough to need the power button (see
// flutter_vita_gpu_shutdown, and release_gpu here). And the engine picks its
// log path off this very flag, so the loader lands on app.log with everything
// else and would truncate the log of the app that just crashed -- which is
// what rotate_app_log in the constructor is for.
//
// Back to 1 on 2026-08-31, hours after the 0 that replaced it, and the reason
// is not the crash risk ADR-0016 decision 7 named. It is that the panel is not
// legible under GL on the blessed engine.
//
// Seen on the console: the status pill and every Btn render as a filled
// rectangle with no text in them, while the rail labels and body text next to
// them are fine. What the blank ones have in common is a translucent
// container underneath -- withValues(alpha: 0.16) plus a border. A green '0'
// also lands on top of the Flutter logo, and a grey band across the bottom of
// the log panel, both of which read as an atlas being sampled wrong rather
// than a layout that moved.
//
// Not necessarily a bug in the GL path as it stands today. The loader links
// the *blessed* engine (decision 2), b1f20d13d621, which is deliberately older
// than the tree -- so this may already be fixed in the engine apps use, and
// the way to find out is to reproduce it in an app rather than to keep
// re-blessing under a loader nobody can read.
//
// Apps are unaffected and stay on the GPU: ux0:data/flutter-vita/software.on
// is 0 on this console, and the gallery came up "GL up -- OpenGL ES 2.0
// VitaGL / SGX543MP4+" on the current engine.
int flutter_vita_force_software = 1;

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

// When a host last sent this loader a command, in process time. Negative
// means never.
//
// The badge said "Waiting" through every unreachable stretch of 2026-09-01 and
// it was telling the truth: the console had an address and the socket was
// listening. What it could not say was that nothing had reached it for twenty
// minutes, which is the difference between idle and lost.
static SceInt64 g_last_cmd = -1;

static char g_status[24] = "Starting";
static char g_detail[80] = "";
static char g_ip[24] = "";
static char g_target[16] = LOADER_TARGET_TITLEID;

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
                   g_seq, g_ip[0] ? g_ip : "-", LOADER_PORT, g_target,
                   g_status, g_detail, LOADER_SELF_TITLEID, g_recv_done,
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

// A line for the panel and a line for the log file, from one call. The two
// audiences want the same thing and keeping them in step by hand did not last.
// MM-DD HH:MM:SS, fifteen characters including the trailing space.
//
// Fixed width on purpose: the panel finds the "+ " and "- " markers by
// stepping over this, and the two halves of that arrangement are a hundred
// lines apart in two languages. Change the width here and _Console goes wrong
// quietly.
//
// The clock is whatever the console was last set to. Nothing sorts by it --
// the log archive is numbered for exactly that reason -- but a wrong wall
// clock still answers "was that this deploy or the one before lunch", which
// is the question a wall of `put 1 KB` cannot.
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

// Keep the deploy log from growing without end.
//
// Truncated at boot rather than trimmed line by line: this file is read by a
// panel that shows its last few dozen lines, so the cost of losing the older
// half once every few hundred deploys is nothing, and a rewrite-on-every-note
// scheme would put a read-modify-write of 64 KB in the path of every log line.
#define DEPLOY_LOG_MAX (64 * 1024)

static void trim_deploy_log(void) {
  SceIoStat st;
  if (sceIoGetstat(DEPLOY_LOG, &st) < 0) return;
  if (st.st_size < DEPLOY_LOG_MAX) return;
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
// This is `put` and `stage` both, and it deliberately shadows the dev
// server's own `put`: the built-in cannot report progress, and "Receiving,
// 4.2 of 11.8 MB" is most of what the status line is for. A 12 MB eboot over
// this console's Wi-Fi takes long enough to look like a hang.
//
// A NULL `what` receives silently: no log line, no status, no progress. That
// is for the panel's command file, which is nine bytes and arrives whenever
// someone is driving the screen from the host.
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
           (arg != NULL && arg[0] != '\0') ? arg : LOADER_TARGET_TITLEID);
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

// Hand the console to the target and end this process.
//
// Terminal by construction, and ADR-0016's status model says so: there is no
// state after Launching because there is no loader after it. Launching
// another title is what unlocks the target's directory, which cannot happen
// while this process holds it.
// Keep the log the app that just ran wrote, instead of letting the next one
// truncate it.
//
// The engine opens ux0:data/flutter-vita/app.log with O_TRUNC before anything
// else runs, so an app's log survives exactly until the next launch. That is
// the wrong lifetime for the thing you go looking for after a crash, and it
// cannot be fixed in the app: the truncate is inside the engine archive.
//
// It can be fixed here. The loader is what launches apps, so it is the one
// process that knows a log is about to be destroyed and can move it first.
// Numbered rather than timestamped because this console's clock is whatever
// the user last set it to, and a wrong date sorts wrong; the index only has to
// increase.
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
  note("kept log %04d-%s.log", seq, prev);

  seq++;
  snprintf(idx, sizeof idx, "%d", seq);
  write_small(LOG_DIR "/next", idx);

  // Bounded, because a memory card is not infinite and nobody reads the
  // twenty-first-oldest log. Only this loader's own naming is removed, so a
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

// Which title ids this loader has installed.
//
// The panel lists these and offers to remove them or clear their data, and it
// deliberately lists nothing else. ux0:app holds the console's own titles and
// whatever else is on the card, and a delete button beside one of those, on a
// device with no undo, is a footgun rather than a feature.
//
// One id per line, appended, deduplicated on read rather than on write -- the
// write happens on the install path where an extra sceIo round trip is a cost
// and correctness here is worth nothing.
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
// install path, but the loader now records itself on every boot -- and a file
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
// Split out of cmd_launch because the APPS tab's RUN button arrives on the
// watcher thread with no socket to answer on, and the steps below are the part
// that must not differ between the two callers.
//
// The existence check is not belt and braces. sceAppMgrLaunchAppByUri on a
// title that is not installed fails quietly, and by then this process has
// already exited -- so the console lands on the LiveArea home screen, which
// answers no port and cannot be driven from the network. That happened twice
// on 2026-08-31, both times through the APPS tab offering RUN on a title id
// that was still in installed.txt after the title itself had been deleted.
static int hand_over(const char* titleid) {
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
  // loader ran software until 2026-08-31 and this was a comment saying so;
  // it now runs GL like everything else, and the call is real.
  release_gpu();

  char uri[64];
  snprintf(uri, sizeof uri, "psgm:play?titleid=%s", titleid);
  sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  // Exit at once rather than lingering: the "close the current application?"
  // prompt appears only because the outgoing app is still alive.
  sceKernelExitProcess(0);
  for (;;) sceKernelDelayThread(1000 * 1000);
  return 0;
}

static void cmd_launch(int sock) {
  // Checked before the reply, not after: the caller is a deploy script that
  // reads OK as "the console is on its way", and a script that believes that
  // wrongly waits out its whole timeout against a loader still sitting here.
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

// Install a whole extracted .vpk through the system promoter.
//
// The one command here that is not part of deploying an app: it is how the
// loader replaces *itself*, which matters more now than it did, because a
// Flutter loader is ~20 MB rather than 91 KB and there is no other route for
// it. The promoter is a system service and is not bound by this sandbox.
// PAF, loaded the way VitaShell loads it.
//
// ScePromoterUtil imports from PAF. Until PAF is resident in this process the
// promoter's library cannot be linked and the load is refused with
// SCE_KERNEL_ERROR_MODULEMGR_NO_LIB -- which is what this loader, and the C one
// before it, and three ADRs, all read as "the promoter is unavailable on this
// console". It is not. The error was naming its own cause. See
// spikes/promoter, which walks every route and shows the promoter loading and
// initialising the moment PAF goes first.
//
// The argument block is not optional. The plain
// sceSysmoduleLoadModuleInternal(PAF) faults the process; the spike did it
// twice. These values are VitaShell's verbatim -- 0x180000 is the heap PAF is
// being given -- and note that buf[0] is a *size*, not flags, which is why
// zeroing a SceSysmoduleOpt and filling in only `result` was never the same
// call.
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
// promoted, and then unwound all of it. That is the right shape for a feature
// and the wrong shape for an investigation, because every run tested five
// things at once and the console went down about ten seconds after each.
//
// What the dumps say (spikes/promoter): PAF starts a thread of its own, called
// `ScePaf EntryCall`, and *that* thread takes a data abort six bytes into the
// PAF module while our threads sit idle. Every run that died had unmapped PAF
// first, by unloading it or by exiting. No run has yet kept it resident and
// survived, so that is the cell to fill in, and filling it in needs the load
// and the unload to be separate commands.
//
// It is driven from here rather than from the spike for a second reason. The
// spike draws with debugScreen, which writes the framebuffer directly and
// initialises no display subsystem; VitaShell, which does all of this safely,
// is a vita2d app with a live GXM context. The loader is the only thing here
// with VitaShell's shape -- a real context, a dev server, and no exit of its
// own -- and it is also where the feature has to end up.
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

// Load PAF if it is not up, then the promoter, then Init.
//
// A failed load stays fatal and must: an import stub for a module that is not
// resident is not a stub that returns an error, it is address zero, so
// "continue and let Init decide" is `blx 0`. That was tried on 2026-08-22 and
// the dump is a prefetch abort with PC 0.
// `sock` may be -1. The watcher thread calls this on behalf of the panel, which
// has no socket, and dev_server_send on a fd that was never opened is not a
// no-op -- it is a write to whatever -1 means to sceNetSend.
static void reply(int sock, const char* msg) {
  if (sock >= 0) dev_server_send(sock, msg);
}

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
  note("promoter up");
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
// sync=1 is documented to block, and is not trusted: GetState is polled anyway,
// and GetResult is read separately because a call can return >= 0 and still
// fail -- the return value says the request was accepted, the result says what
// happened.
static void promoter_finish(int sock, const char* what, int r,
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
}

// The three ways in, kept as three commands because they want different things
// of the directory and nothing here knows which of them this console accepts.
//
//   promote      PromotePkg. What the loader has always called.
//   promoterif   PromotePkgWithRif. What VitaShell calls, and it builds a
//                sce_sys/package/head.bin with three HMAC-SHA1 signatures
//                before doing so.
//   import       PromoteImport, documented as installing Content Manager
//                import content "without checking license files", and the only
//                one of the three that is handed the title id rather than
//                reading it out of the package. If it works it removes the
//                signing work entirely.
//
// None of them unloads anything afterwards. See cmd_paf.
// `<dir> [titleid]`. The id is optional and is only ever used to record what
// was installed for the panel's apps list -- the promoter reads the package's
// own param.sfo and does not take our word for it. Splitting here rather than
// reading the sfo in C: the caller already parsed it to name the head.bin.
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
// reads whatever is in there, so a file left by a previous install of something
// else becomes part of the next package. Clearing it needed a command and there
// was not one.
//
// The prefix check is not decoration. This is a recursive delete on an
// unauthenticated socket that anything on the network can open, and the loader
// runs as an UNSAFE self, so `rmtree ux0:app` would be honoured. Confined to
// ux0:data, the worst it can do is cost a redeploy.
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
  int removed = 0;
  const int r = rmtree(path, 0, &removed);
  sceIoRmdir(path);
  // A path that was not there is the ordinary case for a caller clearing a
  // staging directory before using it, so it is not an error.
  snprintf(m, sizeof m, "OK rmtree %s (%d files, dopen 0x%08X)\n", path,
           removed, (unsigned)r);
  note("rmtree %s: %d files", path, removed);
  dev_server_send(sock, m);
}

// Restart the loader, immediately, after a delete.
//
// Not a workaround dressed up as a feature: a delete takes this process down a
// few seconds later and I cannot yet say why. What is known is that the
// promoter leaves PAF resident, that PAF runs a thread of its own, and that no
// core dump is written -- so nothing here is faulting, which is why there is
// nothing to read. See the note above cmd_paf.
//
// What that cost, twice on 2026-09-01, was the console sitting on the LiveArea
// home screen: no port answers there, so the machine cannot be driven back
// without someone picking it up. An unexplained death and a deliberate restart
// end in the same place five seconds apart, and only one of them leaves the
// loader running.
//
// So this is honest about being a mitigation. When the cause is found this
// should go, and a delete should simply not do it.
static void restart_after_delete(void) {
  note("restarting after a delete");
  set_status("Restarting", "after a delete");
  // Long enough for the reply to leave and for one publish-and-poll, so the
  // last frame on screen says what is happening.
  sceKernelDelayThread(600 * 1000);
  hand_over(LOADER_SELF_TITLEID);
  // Only reached if the launch was refused, which for our own title id means
  // ux0:app/<self> has gone -- there is nothing to hand to, so stay up.
  note("could not relaunch; staying here");
  set_status("Waiting", NULL);
}

// Unregister a title. The other half of promote, and the only way to take a
// title id back once it has been handed out.
//
// Through promoter_finish like every other promoter call, and it was not until
// 2026-09-01. It fired DeletePkg and answered on the spot, so `OK delete
// FVTA00009 0x00000000` meant the request had been accepted and nothing more.
// The loader then went back to serving the panel -- which lists ux0:app on
// every poll -- while the promoter's worker was still removing a title from
// underneath that enumeration. Twice that evening the loader went down inside
// a second of a delete and left the console on the LiveArea home screen, which
// is the one place it must never leave it: nothing there answers a socket.
//
// The wait is the fix, and reading the result is the other half of it. A call
// can be accepted and still fail, and reporting the accept as success is how
// a title that is still there gets called gone.
static void cmd_delete(int sock, const char* titleid) {
  if (strcmp(titleid, LOADER_SELF_TITLEID) == 0) {
    dev_server_send(sock, "ERR refusing to delete the loader\n");
    return;
  }
  if (!promoter_up(sock)) return;
  set_status("Deleting", "removing %s", titleid);
  note("delete %s", titleid);
  // NULL: promoter_finish records a title id as *installed* on success, which
  // is the opposite of what happened here.
  promoter_finish(sock, "delete", scePromoterUtilityDeletePkg(titleid), NULL);
  forget_installed(titleid);
  restart_after_delete();
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

// ------------------------------------------------------------- the dispatch

static int handle(int sock, const char* line, int* stop) {
  g_last_cmd = (SceInt64)sceKernelGetProcessTimeWide();
  // Shadows the dev server's own `pong`, so that a reply identifies what
  // answered. tools/update-loader.sh greps for it, and the alternative --
  // a bare "pong" from whatever happens to hold the port -- is how you
  // promote a loader over an app.
  if (strcmp(line, "ping") == 0) {
    char m[64];
    snprintf(m, sizeof m, "pong loader %s %d\n", LOADER_TARGET_TITLEID,
             LOADER_PORT);
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
    // The destination's parent is not always there -- update-loader.sh streams
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
    // No `*stop = 1` here. It used to sit on the next line with the comment
    // "not reached; the process is gone", which was true for as long as
    // cmd_launch could not fail. It can now -- it refuses a title that is not
    // installed -- and `stop` closes the listening socket and ends the dev
    // server thread, so the first refused launch left the loader on screen and
    // unreachable, recoverable only by picking the console up. The launch that
    // succeeds exits the process from inside cmd_launch and never comes back
    // here, so there was never anything for this flag to do.
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
  return 0;
}

// --------------------------------------------------------------- the watcher
//
// The address is the reason this screen exists. Nothing else notices it
// change: the dev server learns the IP once at startup and the command
// handler only runs when a client is already connected -- which is exactly
// the case that cannot happen when the address is wrong.
//
// Started from the dev server's ready handler and never from the constructor.
// A Vita import stub for a module that is not resident is address zero, not a
// function that returns an error, so calling sceNetCtlInetGetInfo before
// SCE_SYSMODULE_NET is loaded is `blx 0` -- a prefetch abort with PC 0 and no
// frame to name. That is what the first version of this file did, and the
// dump for it is the reason dev_server_set_ready_handler exists.

// What the panel asks the C layer to do, and why it is a file.
//
// The panel can clear a log or delete an app's data directory by itself --
// dart:io writes ux0:data as happily as this does. What it cannot do is delete
// a *title*, because that goes through the promoter, and the promoter lives on
// this side.
//
// ADR-0016 decision 3 keeps the reliability-critical half free of a platform
// channel, and the panel already learns everything by polling a file this side
// writes. A file the panel writes and this side polls is the same arrangement
// pointed the other way: no channel, no engine dependency, and a request that
// arrives while Flutter is dead simply never arrives.
//
// One line, `delete <titleid>`, removed before it is acted on so a crash in
// the middle cannot replay it on the next boot.
#define REQUEST_PATH DATA_DIR "/loader-request.txt"

static void serve_request(void) {
  const SceUID fd = sceIoOpen(REQUEST_PATH, SCE_O_RDONLY, 0777);
  if (fd < 0) return;
  char buf[96] = {0};
  const int n = sceIoRead(fd, buf, sizeof buf - 1);
  sceIoClose(fd);
  sceIoRemove(REQUEST_PATH);
  if (n <= 0) return;
  for (int i = 0; i < n; i++) {
    if (buf[i] == '\n' || buf[i] == '\r') { buf[i] = '\0'; break; }
  }

  if (strncmp(buf, "delete ", 7) == 0) {
    const char* titleid = buf + 7;
    if (strcmp(titleid, LOADER_SELF_TITLEID) == 0) {
      note("panel asked to delete the loader; refused");
      return;
    }
    if (!promoter_up(-1)) {
      note("delete %s: promoter would not start", titleid);
      return;
    }
    promoter_finish(-1, "delete", scePromoterUtilityDeletePkg(titleid), NULL);
    forget_installed(titleid);
    restart_after_delete();
  } else if (strncmp(buf, "launch ", 7) == 0) {
    const char* titleid = buf + 7;
    if (strcmp(titleid, LOADER_SELF_TITLEID) == 0) {
      note("panel asked to launch the loader; already here");
      return;
    }
    note("panel launch %s", titleid);
    set_status("Launching", "%s", titleid);
    // Long enough for one publish and one poll, so the screen says Launching
    // before it goes. Without it the panel's last frame is whatever it drew
    // half a second ago, which reads as a freeze.
    sceKernelDelayThread(600 * 1000);
    hand_over(titleid);
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
        note("network up: %s:%d", g_ip, LOADER_PORT);
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
      set_status("No network", "check Wi-Fi on the console");
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
  const SceUID th = sceKernelCreateThread("fvita_loader_watch", watcher,
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

__attribute__((constructor)) static void loader_register(void) {
  dev_server_set_port(LOADER_PORT);
  dev_server_set_command_handler(handle);
  dev_server_set_ready_handler(on_network_ready);
  dev_server_set_minimal(1);

  // Safe from here: sceIo is available to a constructor, and this is the only
  // state the screen can show before the network exists.
  mkdirs();
  // Before main(), and that is the whole point.
  //
  // The engine opens its log with O_TRUNC as the first line of main(), and now
  // that the loader runs GL it shares app.log with every app -- so without
  // this, opening the loader after a crash destroys the log of the crash. That
  // exact regression was measured on 2026-08-28 chasing keklist's emoji grid.
  // A constructor runs before main, so the file is moved into the archive
  // while it still holds the last thing the app said.
  // Read before the rotation, which overwrites it. logs/last names whatever
  // ran before this boot, so it is how the loader knows an app has ended --
  // there is no notification, only the fact of being alive again.
  char prev[24] = {0};
  read_small(LOG_DIR "/last", prev, sizeof prev);

  rotate_app_log("loader");
  trim_deploy_log();
  note("---- loader %s up ----", LOADER_SELF_TITLEID);
  if (prev[0] != '\0' && strcmp(prev, "loader") != 0) {
    note("- left %s", prev);
  }
  publish();
}
