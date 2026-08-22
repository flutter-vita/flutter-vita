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
// Replacing FVTA00003 in place with something unproven costs the only deploy
// path there is.
#ifndef LOADER_PORT
#define LOADER_PORT 1341
#endif
#ifndef LOADER_TARGET_TITLEID
#define LOADER_TARGET_TITLEID "FVTA00002"
#endif

#define DATA_DIR "ux0:data/flutter-vita"
#define STAGED DATA_DIR "/staged-eboot.bin"
#define STATE_PATH DATA_DIR "/loader-state.txt"
#define STATE_TMP DATA_DIR "/loader-state.tmp"

// The engine's debug HUD -- frame rate, damage, blit cost, free memory -- is
// drawn over the top-right corner of every frame from a weak symbol, and a
// strong definition here wins. Off for the loader, and not because it is
// noisy: this screen is the product (ADR-0016 decision 1), and a showcase
// with a diagnostic overlay bolted to its corner is a worse advertisement
// than no showcase. It can still be turned back on for a frame-rate question
// by deleting this line and rebuilding.
int flutter_vita_debug_overlay = 0;

#define LOG_LINES 12
#define LOG_WIDTH 96

// ---------------------------------------------------------------- the state
//
// One writer -- everything below runs on the dev server's thread or on the
// single watcher thread -- so this is guarded by nothing more than that fact
// and the atomic rename at the end of publish().

static char g_status[24] = "Starting";
static char g_detail[80] = "";
static char g_ip[24] = "";
static char g_target[16] = LOADER_TARGET_TITLEID;

static char g_lines[LOG_LINES][LOG_WIDTH];
static int g_line_count = 0;  // total ever, not the ring size
static unsigned g_seq = 0;

static void publish(void) {
  g_seq++;
  char buf[LOG_LINES * LOG_WIDTH + 512];
  int n = snprintf(buf, sizeof buf,
                   "seq %u\nip %s\nport %d\ntarget %s\nstatus %s\ndetail %s\n",
                   g_seq, g_ip[0] ? g_ip : "-", LOADER_PORT, g_target,
                   g_status, g_detail);
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
static void note(const char* fmt, ...) {
  char line[LOG_WIDTH];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);

  snprintf(g_lines[g_line_count % LOG_LINES], LOG_WIDTH, "%s", line);
  g_line_count++;

  char with_newline[LOG_WIDTH + 4];
  snprintf(with_newline, sizeof with_newline, "  %s\n", line);
  dev_server_log(with_newline);
  publish();
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
static int receive_to(int sock, const char* dest, int size, const char* what) {
  mkdirs();
  char tmp[288];
  snprintf(tmp, sizeof tmp, "%s.part", dest);
  sceIoRemove(tmp);
  const SceUID fd =
      sceIoOpen(tmp, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) {
    note("%s: cannot open (0x%08X)", what, (unsigned)fd);
    set_status("Waiting", NULL);
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
      note("%s: short by %d of %d", what, remaining, size);
      set_status("Waiting", NULL);
      dev_server_send(sock, "ERR short\n");
      return -1;
    }
    if (sceIoWrite(fd, buf, got) != got) {
      sceIoClose(fd);
      sceIoRemove(tmp);
      note("%s: write failed", what);
      set_status("Waiting", NULL);
      dev_server_send(sock, "ERR write\n");
      return -1;
    }
    remaining -= got;
    since_report += got;
    // Every half megabyte, not every chunk: each report rewrites the state
    // file, and 12 MB in 32 KB chunks is 384 rewrites of a file on a memory
    // card in the middle of a transfer.
    if (since_report >= 512 * 1024) {
      since_report = 0;
      set_status("Receiving", "%d of %d KB", (size - remaining) / 1024,
                 size / 1024);
    }
  }
  sceIoClose(fd);
  sceIoRemove(dest);  // sceIoRename will not overwrite
  const int rr = sceIoRename(tmp, dest);
  if (rr < 0) {
    note("%s: rename failed 0x%08X", what, (unsigned)rr);
    set_status("Waiting", NULL);
    dev_server_send(sock, "ERR rename\n");
    return -1;
  }
  note_size(what, size);
  set_status("Waiting", NULL);
  dev_server_send(sock, "OK\n");
  return 0;
}

static void set_target(const char* arg) {
  snprintf(g_target, sizeof g_target, "%s",
           (arg != NULL && arg[0] != '\0') ? arg : LOADER_TARGET_TITLEID);
}

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
static void cmd_launch(int sock) {
  note("launching %s", g_target);
  set_status("Launching", "%s", g_target);

  char msg[64];
  snprintf(msg, sizeof msg, "OK launching %s\n", g_target);
  dev_server_send(sock, msg);
  sceNetSocketClose(sock);
  sceKernelDelayThread(200 * 1000);  // let the reply drain

  // Under GL this is where the console would be lost without a teardown --
  // see flutter_vita_gpu_shutdown. The loader runs software (decision 7), so
  // there is nothing to release, and the symbol may not even be linked.
  char uri[64];
  snprintf(uri, sizeof uri, "psgm:play?titleid=%s", g_target);
  sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  // Exit at once rather than lingering: the "close the current application?"
  // prompt appears only because the outgoing app is still alive.
  sceKernelExitProcess(0);
  for (;;) sceKernelDelayThread(1000 * 1000);
}

// Install a whole extracted .vpk through the system promoter.
//
// The one command here that is not part of deploying an app: it is how the
// loader replaces *itself*, which matters more now than it did, because a
// Flutter loader is ~20 MB rather than 91 KB and there is no other route for
// it. The promoter is a system service and is not bound by this sandbox.
static void cmd_promote(int sock, const char* dir) {
  char m[256];
  set_status("Installing", "promoting %s", dir);
  // scePromoterUtil is an internal sysmodule and is not resident by default.
  // Calling into it without loading it first jumps through an unresolved stub
  // and takes the process down.
  // scePromoterUtil is an internal sysmodule and is not resident by default.
  // A failed load is fatal here and must stay fatal: an import stub for a
  // module that is not resident is not a stub that returns an error, it is
  // address zero, so "continue and let Init decide" is `blx 0`. That was
  // tried, on 2026-08-22, and the dump is a prefetch abort with PC 0 inside
  // this function.
  int r = sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
  if (r < 0) {
    // Second spelling, because the first has been observed returning
    // SCE_KERNEL_ERROR_MODULEMGR_NO_LIB (0x8002D003) on this console for both
    // this loader and the C one it replaces. VitaShell and VHBB use the
    // WithArg form.
    //
    // `option` is not optional despite the name: passing NULL returns
    // SCE_KERNEL_ERROR_INVALID_MEMORY_ACCESS (0x80022005), which is the module
    // manager reporting the null pointer rather than anything about the
    // module. The struct wants somewhere to put the module's own result.
    int inner = 0;
    SceSysmoduleOpt opt;
    memset(&opt, 0, sizeof opt);
    opt.result = &inner;
    const int r2 = sceSysmoduleLoadModuleInternalWithArg(
        SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL, 0, NULL, &opt);
    if (r2 < 0) {
      snprintf(m, sizeof m,
               "ERR loadmodule 0x%08X / witharg 0x%08X (inner 0x%08X)\n",
               (unsigned)r, (unsigned)r2, (unsigned)inner);
      note("promote: load 0x%08X witharg 0x%08X inner 0x%08X", (unsigned)r,
           (unsigned)r2, (unsigned)inner);
      set_status("Waiting", NULL);
      dev_server_send(sock, m);
      return;
    }
    note("promote: loadmodule 0x%08X, witharg ok", (unsigned)r);
    r = r2;
  }
  r = scePromoterUtilityInit();
  if (r < 0) {
    snprintf(m, sizeof m, "ERR init 0x%08X\n", (unsigned)r);
    note("promote: init 0x%08X", (unsigned)r);
    set_status("Waiting", NULL);
    dev_server_send(sock, m);
    sceSysmoduleUnloadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
    return;
  }
  note("promoting %s", dir);
  r = scePromoterUtilityPromotePkg(dir, 1);
  int state = -1, res = -1;
  if (r >= 0) {
    // sync=1 should block, but poll anyway rather than trust it.
    for (int i = 0; i < 600; i++) {
      if (scePromoterUtilityGetState(&state) < 0) break;
      if (state == 0) break;
      sceKernelDelayThread(100 * 1000);
    }
    scePromoterUtilityGetResult(&res);
  }
  scePromoterUtilityExit();
  sceSysmoduleUnloadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
  const int ok = (r >= 0 && res == 0);
  snprintf(m, sizeof m, "%s promote=0x%08X state=%d result=0x%08X\n",
           ok ? "OK" : "ERR", (unsigned)r, state, (unsigned)res);
  note("promote %s (result 0x%08X)", ok ? "ok" : "failed", (unsigned)res);
  set_status("Waiting", NULL);
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

// ------------------------------------------------------------- the dispatch

static int handle(int sock, const char* line, int* stop) {
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
    cmd_launch(sock);
    *stop = 1;  // not reached; the process is gone
    return 1;
  }
  if (strncmp(line, "promote ", 8) == 0) {
    cmd_promote(sock, line + 8);
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

static int watcher(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  char last[24] = "";
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
  publish();
}
