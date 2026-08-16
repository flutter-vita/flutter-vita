// Flutter Vita Loader — the other half of the deploy loop.
//
// Why this exists: a running app can never replace its own eboot.bin. Measured,
// not assumed (spikes/vita-tooling/README.md) —
//
//   * from inside FVTA00002, ux0:app/FVTA00002/ is ENOENT, because an app's own
//     directory is not in its sandbox; the same content is mounted read-only as
//     app0:
//   * while FVTA00002 runs, that directory is locked against every *other*
//     process too — even BGFTP gets 550 on it
//
// So the write has to come from a different process, at a moment when the
// target app is not running. This is that process.
//
//   loader running  ->  stage a new eboot into ux0:data (writable)
//                   ->  install it into ux0:app/FVTA00002 (we are not it, and
//                       it is not running, so both objections are gone)
//                   ->  launch FVTA00002, which replaces us
//   M1 finishes     ->  handoff: launches us back, and exits
//
// Each app launches the other, so neither has to survive the switch. After the
// very first tap on the LiveArea there is nothing left to press.
//
// This binary should change as rarely as possible: it is the thing that can
// recover the loop, and nothing can redeploy *it* except BGFTP plus a manual
// tap. Keep it boring.

#include <psp2/appmgr.h>
#include <psp2/bgapputil.h>
#include <psp2/ctrl.h>
#include <psp2/io/dirent.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/power.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>
#include <psp2/net/netctl.h>
#include <psp2/promoterutil.h>
#include <psp2/sysmodule.h>
#include <taihen.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "debugScreen.h"

#define LOADER_PORT 1341
#define TARGET_TITLEID "FVTA00002"
#define TARGET_EBOOT "ux0:app/" TARGET_TITLEID "/eboot.bin"
#define STAGED "ux0:data/flutter-vita/staged-eboot.bin"

static SceUID g_log = -1;
static char g_net_pool[16 * 1024];

static void lg(const char* fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  psvDebugScreenPuts(buf);
  if (g_log >= 0) {
    sceIoWrite(g_log, buf, strlen(buf));
    sceIoSyncByFd(g_log, 0);
  }
}

static int recv_line(int sock, char* out, int max) {
  int n = 0;
  while (n < max - 1) {
    char c;
    const int r = sceNetRecv(sock, &c, 1, 0);
    if (r == 0) return 0;
    if (r < 0) return r;
    if (c == '\n') break;
    out[n++] = c;
  }
  if (n > 0 && out[n - 1] == '\r') n--;
  out[n] = '\0';
  return n;
}

// Screen power.
//
// scePowerRequestDisplayOff is NOT used here, and must not be reintroduced. It
// does turn the panel off, but nothing this app can do brings it back --
// scePowerRequestDisplayOn had no effect, and the only ways out were exiting
// the app or minimising it. On someone's only console that is an unacceptable
// way to lose the display.
//
// What protects the OLED instead is blanking: the panel stays powered, but the
// framebuffer is cleared to black, and a black pixel on an OLED draws
// essentially no current. Burn-in comes from static *text* sitting there for
// hours, and blanking removes exactly that. Recovery is guaranteed because we
// own the framebuffer -- any button redraws.
#define SCREEN_IDLE_US (60 * 1000 * 1000)

static volatile int g_blanked = 0;
static volatile int g_stay_awake = 0;
static volatile uint64_t g_last_activity = 0;

static void screen_activity(void) { g_last_activity = sceKernelGetProcessTimeWide(); }

static int power_tick_thread(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  SceCtrlData pad;
  unsigned int prev = 0;
  screen_activity();
  for (;;) {
    // Keep the console awake in both senses: no suspend (it would kill the
    // network and the deploy loop with it) and no system-driven display off
    // (whose wake path we do not control).
    sceKernelPowerTick(SCE_KERNEL_POWER_TICK_DEFAULT);

    if (sceCtrlPeekBufferPositive(0, &pad, 1) >= 0) {
      if (pad.buttons != 0 && pad.buttons != prev) {
        if ((pad.buttons & SCE_CTRL_SELECT) && !(prev & SCE_CTRL_SELECT)) {
          g_stay_awake = !g_stay_awake;
        }
        screen_activity();
      }
      prev = pad.buttons;
    }

    const uint64_t idle = sceKernelGetProcessTimeWide() - g_last_activity;
    const int want_blank = !g_stay_awake && idle >= SCREEN_IDLE_US;

    if (want_blank && !g_blanked) {
      psvDebugScreenPuts("\033[2J");  // black, but the panel stays on
      g_blanked = 1;
    } else if (!want_blank && g_blanked) {
      psvDebugScreenPuts("\033[2Jflutter-vita: awake. SELECT = stay awake.\n");
      g_blanked = 0;
    }
    sceKernelDelayThread(200 * 1000);
  }
  return 0;
}

static void start_power_tick(void) {
  const SceUID t = sceKernelCreateThread("fvita_powertick", power_tick_thread,
                                         0x10000100, 0x1000, 0, 0, NULL);
  if (t >= 0) sceKernelStartThread(t, 0, NULL);
}

// mkdir -p. Promote wants a directory tree (eboot.bin plus sce_sys/...), and
// the client should not have to order its uploads to build it.
static void mkdirs(const char* path) {
  char tmp[256];
  snprintf(tmp, sizeof tmp, "%s", path);
  for (char* p = strchr(tmp, '/'); p != NULL; p = strchr(p + 1, '/')) {
    *p = '\0';
    sceIoMkdir(tmp, 0777);
    *p = '/';
  }
}

static void send_str(int sock, const char* s) {
  sceNetSend(sock, s, strlen(s), 0);
}

// Straight to ux0:data, which the probe showed is writable. Nothing clever:
// the risky write is `install`, and keeping it separate means a dropped
// transfer -- routine on this wifi -- cannot touch the installed app at all.
static int cmd_stage(int sock, int size) {
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  sceIoRemove(STAGED);
  SceUID fd = sceIoOpen(STAGED, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) {
    lg("  stage: open failed 0x%08X\n", (unsigned)fd);
    send_str(sock, "ERR open\n");
    return -1;
  }
  static char buf[32 * 1024];
  int remaining = size;
  while (remaining > 0) {
    const int want = remaining < (int)sizeof buf ? remaining : (int)sizeof buf;
    const int got = sceNetRecv(sock, buf, want, 0);
    if (got <= 0) {
      sceIoClose(fd);
      sceIoRemove(STAGED);
      lg("  stage: short by %d of %d\n", remaining, size);
      send_str(sock, "ERR short\n");
      return -1;
    }
    if (sceIoWrite(fd, buf, got) != got) {
      sceIoClose(fd);
      sceIoRemove(STAGED);
      send_str(sock, "ERR write\n");
      return -1;
    }
    remaining -= got;
  }
  sceIoClose(fd);
  lg("  staged %d bytes\n", size);
  send_str(sock, "OK\n");
  return 0;
}

// Which slot install/launch act on.
//
// One title id was hard-coded here because there was one app. There are now
// several -- a conformance suite that self-reports pass/fail and a gallery
// judged by eye answer different questions and want different bubbles -- and
// each needs its own slot. The bare `install` and `launch` still mean
// FVTA00002, so every existing script and habit keeps working.
//
// A slot must already be **registered** with the shell before either command
// can reach it: ScePromoterUtil will not load for us (MODULEMGR_NO_LIB), so a
// new title id needs one VitaShell install of its .vpk. After that this loop
// owns it.
static char g_target[16] = TARGET_TITLEID;

static void set_target(const char* arg) {
  if (arg == NULL || arg[0] == '\0') {
    snprintf(g_target, sizeof g_target, "%s", TARGET_TITLEID);
    return;
  }
  snprintf(g_target, sizeof g_target, "%s", arg);
}

// Copy staged -> target. Via a .tmp beside the target so a failure part-way
// leaves the installed eboot.bin intact; the only alternative is reinstalling
// the vpk by hand.
static int cmd_install(int sock) {
  SceUID in = sceIoOpen(STAGED, SCE_O_RDONLY, 0777);
  if (in < 0) {
    send_str(sock, "ERR nothing staged\n");
    return -1;
  }
  char target[64], tmpbuf[72];
  snprintf(target, sizeof target, "ux0:app/%s/eboot.bin", g_target);
  snprintf(tmpbuf, sizeof tmpbuf, "%s.tmp", target);
  const char* tmp = tmpbuf;
  sceIoRemove(tmp);
  SceUID out = sceIoOpen(tmp, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (out < 0) {
    sceIoClose(in);
    lg("  install: cannot write %s (0x%08X)\n", tmp, (unsigned)out);
    send_str(sock, "ERR cannot write target\n");
    return -1;
  }
  static char buf[32 * 1024];
  int n, total = 0;
  while ((n = sceIoRead(in, buf, sizeof buf)) > 0) {
    if (sceIoWrite(out, buf, n) != n) {
      sceIoClose(in);
      sceIoClose(out);
      sceIoRemove(tmp);
      send_str(sock, "ERR write\n");
      return -1;
    }
    total += n;
  }
  sceIoClose(in);
  sceIoClose(out);

  sceIoRemove(target);  // sceIoRename will not overwrite
  const int rr = sceIoRename(tmp, target);
  if (rr < 0) {
    lg("  install: rename failed 0x%08X\n", (unsigned)rr);
    send_str(sock, "ERR rename\n");
    return -1;
  }
  lg("  installed %d bytes into %s\n", total, target);
  send_str(sock, "OK\n");
  return 0;
}

static void cmd_launch(int sock) {
  char msg[64];
  snprintf(msg, sizeof msg, "OK launching %s\n", g_target);
  send_str(sock, msg);
  sceNetSocketClose(sock);
  lg("  launching %s\n", g_target);
  sceKernelDelayThread(200 * 1000);  // let the reply drain
  // Launching another title replaces us, which is exactly what we want: the
  // target's directory must be unlocked, and it cannot be while we hold it.
  {
    char uri[64];
    snprintf(uri, sizeof uri, "psgm:play?titleid=%s", g_target);
    sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  }
  // Exit at once rather than lingering. The "close the current application?"
  // prompt appears only because the outgoing app is still alive; launchers that
  // switch silently exit straight after issuing the launch.
  if (g_log >= 0) sceIoClose(g_log);
  sceKernelExitProcess(0);
  for (;;) sceKernelDelayThread(1000 * 1000);
}

// Returns 1 to stop serving.
static int serve(int sock) {
  char line[256];
  for (;;) {
    const int n = recv_line(sock, line, sizeof line);
    if (n <= 0) return 0;

    if (strcmp(line, "screen") == 0) {
      char m[224];
      const uint64_t idle =
          (sceKernelGetProcessTimeWide() - g_last_activity) / 1000000ULL;
      snprintf(m, sizeof m,
               "blanked=%d stay_awake=%d idle=%llus\n",
               g_blanked, g_stay_awake, (unsigned long long)idle);
      send_str(sock, m);
    } else if (strcmp(line, "ping") == 0) {
      send_str(sock, "loader\n");
    } else if (strncmp(line, "kload ", 6) == 0) {
      // Load a kernel module at runtime. Nothing goes in config.txt and nothing
      // loads at boot, so a bad module costs a power cycle, not a console that
      // will not boot. Unlike `inject`, this does not touch SceShell at all --
      // that route is closed after our own module took the shell down.
      const SceUID mid = taiLoadStartKernelModule(line + 6, 0, NULL, 0);
      char m[224];
      snprintf(m, sizeof m, "%s kload %s modid=0x%08X\n",
               mid >= 0 ? "OK" : "ERR", line + 6, (unsigned)mid);
      lg("  %s", m);
      send_str(sock, m);
    } else if (strncmp(line, "inject", 6) == 0) {
      // Inject the launcher module into SceShell. SceShell survives our apps
      // crashing, so a module inside it can relaunch us with no human involved
      // -- which is the entire point.
      //
      // Runtime injection, deliberately: nothing goes into ur0:tai/config.txt
      // and nothing loads at boot, so the worst case is a hung shell that a
      // reboot clears completely. The two failures earlier today were
      // config.txt entries that stopped the console booting at all.
      // sceAppMgrGetIdByName("SceShell") returns 0x80802012 here -- it does
      // not resolve the shell. SceShell's pid is conventionally a fixed value
      // on this platform, so allow it to be given explicitly:
      //   inject           -> try the name, then fall back to 0x10005
      //   inject 10005     -> use that pid (hex)
      // Passing it in means candidate pids can be tried without a rebuild and
      // redeploy for each one.
      SceUID shell_pid = 0;
      char m[224];
      if (line[6] == ' ' && line[7] != '\0') {
        shell_pid = (SceUID)strtoul(line + 7, NULL, 16);
        lg("  using given pid 0x%08X\n", (unsigned)shell_pid);
      } else {
        const int r = sceAppMgrGetIdByName(&shell_pid, "SceShell");
        if (r < 0) {
          shell_pid = 0x10005;  // the conventional SceShell pid
          lg("  getIdByName 0x%08X, falling back to 0x%08X\n", (unsigned)r,
             (unsigned)shell_pid);
        }
      }
      lg("  SceShell pid = 0x%08X\n", (unsigned)shell_pid);
      tai_module_args_t targs;
      memset(&targs, 0, sizeof targs);
      targs.size = sizeof targs;
      targs.pid = shell_pid;
      targs.args = 0;
      targs.argp = NULL;
      targs.flags = 0;
      const SceUID mid = taiLoadStartModuleForPidForUser(
          "ux0:data/flutter-vita/fvita_launcher.suprx", &targs);
      snprintf(m, sizeof m, "%s inject pid=0x%08X modid=0x%08X\n",
               mid >= 0 ? "OK" : "ERR", (unsigned)shell_pid, (unsigned)mid);
      lg("  %s", m);
      send_str(sock, m);
    } else if (strcmp(line, "probe") == 0) {
      // Can we write into the target's directory at all? This is the one
      // assumption the whole design rests on, so it is measurable on demand
      // rather than taken on faith.
      const char* p = "ux0:app/" TARGET_TITLEID "/.loader_probe";
      SceUID fd = sceIoOpen(p, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
      char msg[160];
      if (fd >= 0) {
        sceIoClose(fd);
        sceIoRemove(p);
        snprintf(msg, sizeof msg, "WRITABLE %s\n", TARGET_EBOOT);
      } else {
        snprintf(msg, sizeof msg, "no (0x%08X) %s\n", (unsigned)fd,
                 TARGET_EBOOT);
      }
      send_str(sock, msg);
    } else if (strncmp(line, "get ", 4) == 0) {
      // Stream a file back and close. This is what lets crash dumps and logs be
      // pulled without an FTP server: BGFTP is deliberately not part of this
      // loop, so the loop must be able to diagnose itself.
      SceUID gf = sceIoOpen(line + 4, SCE_O_RDONLY, 0777);
      if (gf < 0) {
        char m[192];
        snprintf(m, sizeof m, "ERR open 0x%08X %s\n", (unsigned)gf, line + 4);
        send_str(sock, m);
        return 0;
      }
      static char gbuf[32 * 1024];
      int gn;
      while ((gn = sceIoRead(gf, gbuf, sizeof gbuf)) > 0) {
        int off = 0;
        while (off < gn) {
          const int w = sceNetSend(sock, gbuf + off, gn - off, 0);
          if (w <= 0) break;
          off += w;
        }
      }
      sceIoClose(gf);
      return 0;  // close so the reader sees EOF
    } else if (strncmp(line, "ls ", 3) == 0) {
      // A remote filesystem-permission explorer. Cheaper than rebuilding and
      // reinstalling this app once per hypothesis -- which is what testing
      // "can we write X" one path at a time would otherwise cost.
      SceUID d = sceIoDopen(line + 3);
      if (d < 0) {
        char m[128];
        snprintf(m, sizeof m, "ERR dopen 0x%08X\n", (unsigned)d);
        send_str(sock, m);
      } else {
        SceIoDirent e;
        char m[320];
        int count = 0;
        memset(&e, 0, sizeof e);
        while (sceIoDread(d, &e) > 0 && count < 200) {
          snprintf(m, sizeof m, "%s %s\n",
                   SCE_S_ISDIR(e.d_stat.st_mode) ? "d" : "-", e.d_name);
          send_str(sock, m);
          memset(&e, 0, sizeof e);
          count++;
        }
        sceIoDclose(d);
        snprintf(m, sizeof m, "(%d entries)\n", count);
        send_str(sock, m);
      }
    } else if (strncmp(line, "touch ", 6) == 0) {
      SceUID fd = sceIoOpen(line + 6, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC,
                            0777);
      char m[160];
      if (fd >= 0) {
        sceIoWrite(fd, "x", 1);
        sceIoClose(fd);
        sceIoRemove(line + 6);
        snprintf(m, sizeof m, "WRITABLE %s\n", line + 6);
      } else {
        snprintf(m, sizeof m, "no (0x%08X) %s\n", (unsigned)fd, line + 6);
      }
      send_str(sock, m);
    } else if (strncmp(line, "rm ", 3) == 0) {
      // Crash dumps accumulate and nothing removed them. ux0:data held 52
      // psp2core files from every homebrew title this console has ever run,
      // and on 2026-08-14 one of them -- a month old, from an unrelated app --
      // was pulled as "the newest dump" and cost half an hour.
      //
      // Deliberately no glob and no recursion. This deletes on a device with
      // one homebrew slot and a lifeline app living in it; a pattern expander
      // here is a way to lose the loader.
      const int r = sceIoRemove(line + 3);
      char m[192];
      snprintf(m, sizeof m, "%s (0x%08X) %s\n", r >= 0 ? "OK removed" : "ERR",
               (unsigned)r, line + 3);
      send_str(sock, m);
    } else if (strncmp(line, "mkdir ", 6) == 0) {
      const int r = sceIoMkdir(line + 6, 0777);
      char m[160];
      snprintf(m, sizeof m, "%s (0x%08X) %s\n", r >= 0 ? "MADE" : "no",
               (unsigned)r, line + 6);
      send_str(sock, m);
    } else if (strncmp(line, "cp ", 3) == 0) {
      // cp <src> <dst> -- copy the staged binary anywhere, so a candidate
      // install path can be tried for real rather than only touch-tested.
      char* sp = strchr(line + 3, ' ');
      if (sp == NULL) { send_str(sock, "ERR cp <src> <dst>\n"); continue; }
      *sp = '\0';
      const char* src = line + 3;
      const char* dst = sp + 1;
      SceUID in = sceIoOpen(src, SCE_O_RDONLY, 0777);
      if (in < 0) { send_str(sock, "ERR src\n"); continue; }
      SceUID out = sceIoOpen(dst, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
      if (out < 0) {
        char m[160];
        snprintf(m, sizeof m, "ERR dst 0x%08X\n", (unsigned)out);
        sceIoClose(in);
        send_str(sock, m);
        continue;
      }
      static char cbuf[32 * 1024];
      int n, tot = 0;
      while ((n = sceIoRead(in, cbuf, sizeof cbuf)) > 0) { sceIoWrite(out, cbuf, n); tot += n; }
      sceIoClose(in); sceIoClose(out);
      char m[160];
      snprintf(m, sizeof m, "OK copied %d bytes\n", tot);
      send_str(sock, m);
    } else if (strncmp(line, "put ", 4) == 0) {
      // put <size> <path> -- receive a file anywhere we can write. This is the
      // whole reason BGFTP can be dropped: we no longer need to write ux0:app
      // ourselves, only ux0:data, and then let the promoter do the install.
      char* sp = strchr(line + 4, ' ');
      if (sp == NULL) { send_str(sock, "ERR put <size> <path>\n"); return 0; }
      *sp = '\0';
      const int size = atoi(line + 4);
      const char* path = sp + 1;
      // Zero is rejected, not accepted as "an empty file". `put` truncates
      // before it writes, so a caller whose size expression came out blank --
      // `wc -c` on a path that does not exist, say -- would otherwise delete
      // the file it meant to replace and report OK. That is how eboot2.bin
      // became 0 bytes on 2026-08-15. Nothing here has ever wanted to write an
      // empty file; `touch` exists for that.
      if (size <= 0 || size > 64 * 1024 * 1024) { send_str(sock, "ERR size\n"); return 0; }
      mkdirs(path);
      sceIoRemove(path);
      SceUID fd = sceIoOpen(path, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
      if (fd < 0) {
        char m[192];
        snprintf(m, sizeof m, "ERR open 0x%08X %s\n", (unsigned)fd, path);
        send_str(sock, m);
        return 0;  // payload still in flight; drop rather than parse it
      }
      static char pbuf[32 * 1024];
      int left = size;
      while (left > 0) {
        const int want = left < (int)sizeof pbuf ? left : (int)sizeof pbuf;
        const int got = sceNetRecv(sock, pbuf, want, 0);
        if (got <= 0) { sceIoClose(fd); sceIoRemove(path); send_str(sock, "ERR short\n"); return 0; }
        sceIoWrite(fd, pbuf, got);
        left -= got;
      }
      sceIoClose(fd);
      { char m[192]; snprintf(m, sizeof m, "OK %d -> %s\n", size, path); send_str(sock, m); }
    } else if (strncmp(line, "promote ", 8) == 0) {
      // The promoter runs as a system service, so it is not bound by our
      // sandbox -- it installs into ux0:app the same way VHBB and PKGj do.
      // This is what removes BGFTP from the loop entirely.
      const char* dir = line + 8;
      char m[256];
      // scePromoterUtil is an *internal* sysmodule and is not resident by
      // default. Calling scePromoterUtilityInit without loading it first jumps
      // through an unresolved stub and takes the process down -- which is
      // exactly what happened the first time, with the log stopping before the
      // next line could be written.
      int r = sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
      if (r < 0) {
        snprintf(m, sizeof m, "ERR loadmodule 0x%08X\n", (unsigned)r);
        send_str(sock, m);
        continue;
      }
      lg("  promoter module loaded\n");
      r = scePromoterUtilityInit();
      if (r < 0) {
        snprintf(m, sizeof m, "ERR init 0x%08X\n", (unsigned)r);
        send_str(sock, m);
        sceSysmoduleUnloadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
        continue;
      }
      lg("  promoting %s\n", dir);
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
      snprintf(m, sizeof m, "%s promote=0x%08X state=%d result=0x%08X\n",
               (r >= 0 && res == 0) ? "OK" : "ERR", (unsigned)r, state,
               (unsigned)res);
      lg("  %s", m);
      send_str(sock, m);
    } else if (strncmp(line, "stage ", 6) == 0) {
      const int size = atoi(line + 6);
      if (size <= 0 || size > 64 * 1024 * 1024) {
        send_str(sock, "ERR size\n");
        return 0;
      }
      if (cmd_stage(sock, size) < 0) return 0;  // payload still in flight
    } else if (strncmp(line, "install", 7) == 0) {
      set_target(line[7] == ' ' ? line + 8 : NULL);
      cmd_install(sock);
    } else if (strncmp(line, "launch", 6) == 0) {
      set_target(line[6] == ' ' ? line + 7 : NULL);
      cmd_launch(sock);
      return 1;
    } else if (strncmp(line, "deploy", 6) == 0) {
      set_target(line[6] == ' ' ? line + 7 : NULL);
      if (cmd_install(sock) == 0) {
        cmd_launch(sock);
        return 1;
      }
    } else if (strcmp(line, "exit") == 0) {
      send_str(sock, "OK\n");
      return 1;
    } else {
      send_str(sock,
               "ERR (ping|probe|ls|get|put|rm|mkdir|cp|touch|promote|"
               "stage <n>|install|launch|deploy|exit)\n");
    }
  }
}


static int net_state(void) {
  int st = -1;
  if (sceNetCtlInetGetState(&st) < 0) return -1;
  return st;
}

// Returns a listening socket, or negative. Separated from main so it can be
// redone from scratch after the wifi drops -- which on this device is routine,
// and used to strand the loader with a dead socket until someone tapped it.
static int start_listener(void) {
  const int srv =
      sceNetSocket("fvita-loader", SCE_NET_AF_INET, SCE_NET_SOCK_STREAM, 0);
  if (srv < 0) return srv;
  int one = 1;
  sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_REUSEADDR, &one,
                   sizeof one);
  SceNetSockaddrIn addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = SCE_NET_AF_INET;
  addr.sin_addr.s_addr = sceNetHtonl(SCE_NET_INADDR_ANY);
  addr.sin_port = sceNetHtons(LOADER_PORT);
  if (sceNetBind(srv, (SceNetSockaddr*)&addr, sizeof addr) < 0 ||
      sceNetListen(srv, 2) < 0) {
    sceNetSocketClose(srv);
    return -1;
  }
  sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_NBIO, &one, sizeof one);
  SceNetCtlInfo info;
  if (sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_IP_ADDRESS, &info) >= 0) {
    lg("listening on %s:%d\n", info.ip_address, LOADER_PORT);
  } else {
    lg("listening on :%d\n", LOADER_PORT);
  }
  return srv;
}

int main(void) {
  psvDebugScreenInit();
  start_power_tick();
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  sceIoRemove("ux0:data/flutter-vita/loader.log");
  g_log = sceIoOpen("ux0:data/flutter-vita/loader.log",
                    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);

  // Start the background supervisor before anything else. It is what makes a
  // crash recoverable without a tap: it is a separate process, so it outlives
  // the foreground app dying. Failure here is not fatal -- the loop still works,
  // it just needs a tap after each crash, as before.
  //
  // The mode argument is 0, and VitaSDK's header is wrong about it. That header
  // says "must be 1" and defines SCE_BGAPP_UTIL_ERROR_INVALID_ARG as 0x80106502;
  // Sony's own header says mode 0 and INVALID_ARG 0x80106501. Both constants are
  // off by one, and 0x80106501 is exactly what this call returned on every boot
  // between 2026-08-10 and 2026-08-15 -- an invalid argument, not a permission
  // problem, which is what the undocumented code was read as at the time.
  {
    const int bg = sceSysmoduleLoadModule(SCE_SYSMODULE_BG_APP_UTIL);
    const int st = (bg >= 0) ? sceBgAppUtilStartBgApp(0) : bg;
    lg("supervisor start: sysmodule=0x%08X start=0x%08X\n", (unsigned)bg,
       (unsigned)st);
  }
  lg("Flutter Vita Loader\n");
  lg("===================\n");
  lg("target: %s\n\n", TARGET_EBOOT);

  if (sceSysmoduleLoadModule(SCE_SYSMODULE_NET) < 0) {
    lg("FATAL: net module failed\n");
    goto done;
  }
  {
    SceNetInitParam np;
    np.memory = g_net_pool;
    np.size = sizeof g_net_pool;
    np.flags = 0;
    const int ni = sceNetInit(&np);
    if (ni < 0 && ni != (int)0x80410103) {
      lg("FATAL: sceNetInit 0x%08X\n", (unsigned)ni);
      goto done;
    }
  }
  sceNetCtlInit();

  SceCtrlData pad;
  sceCtrlSetSamplingMode(SCE_CTRL_MODE_ANALOG);

  int srv = -1;
  int last_state = -2;
  int ticks = 0;
  int accept_errs = 0;
  // Belt and braces: even with no visible error, rebuild the listener
  // periodically if nothing has connected. A silently wedged socket is
  // indistinguishable from an idle one from in here, and rebuilding an idle
  // listener costs nothing.
  int idle_ticks = 0;

  for (;;) {
    // There is no user-mode API to join a given access point -- sceNetCtl
    // exposes state and callbacks only -- so the best available behaviour is to
    // notice the drop, tear the socket down, and rebuild it the moment the
    // system reconnects. No tap required either way.
    // ~5 minutes with no connection at all: assume wedged and rebuild.
    if (srv >= 0 && ++idle_ticks > 5 * 60 * 30) {
      idle_ticks = 0;
      lg("no connections for 5 min; rebuilding the listener as a precaution\n");
      sceNetSocketClose(srv);
      srv = -1;
      continue;
    }
    if (++ticks >= 30) {  // roughly once a second
      ticks = 0;
      const int st = net_state();
      if (st != last_state) {
        lg("net state -> %s\n",
           st == SCE_NETCTL_STATE_CONNECTED      ? "connected"
           : st == SCE_NETCTL_STATE_CONNECTING   ? "connecting"
           : st == SCE_NETCTL_STATE_DISCONNECTED ? "disconnected"
                                                 : "unknown");
        last_state = st;
      }
      if (st != SCE_NETCTL_STATE_CONNECTED && srv >= 0) {
        lg("wifi gone, dropping the listener\n");
        sceNetSocketClose(srv);
        srv = -1;
      } else if (st == SCE_NETCTL_STATE_CONNECTED && srv < 0) {
        srv = start_listener();
        if (srv < 0) lg("relisten failed, will retry\n");
      }
    }

    if (srv >= 0) {
      const int c = sceNetAccept(srv, NULL, NULL);
      if (c < 0) {
        // A non-blocking accept returns EWOULDBLOCK constantly and that is
        // normal. Anything else means the listener is broken -- which is what
        // a brief wifi blip does, while sceNetCtlInetGetState still reports
        // CONNECTED. The old code only rebuilt on a state *transition*, so a
        // socket that died without a state change was never rebuilt and the
        // app sat there visible on screen, unreachable, holding its directory
        // lock. That cost several manual recoveries.
        if (c != (int)0x80410104 /* EWOULDBLOCK */ &&
            c != (int)0x80410116 /* EAGAIN-ish */) {
          if (++accept_errs > 20) {
            lg("listener is wedged (last 0x%08X); rebuilding\n", (unsigned)c);
            sceNetSocketClose(srv);
            srv = -1;
            accept_errs = 0;
            continue;
          }
        }
      }
      if (c >= 0) {
        accept_errs = 0;
        int zero = 0;
        sceNetSetsockopt(c, SCE_NET_SOL_SOCKET, SCE_NET_SO_NBIO, &zero,
                         sizeof zero);
        idle_ticks = 0;
        const int stop = serve(c);
        sceNetSocketClose(c);
        if (stop) break;
        continue;
      }
    }

    sceCtrlPeekBufferPositive(0, &pad, 1);
    if (pad.buttons & SCE_CTRL_START) {
      lg("START pressed\n");
      break;
    }
    sceKernelDelayThread(30 * 1000);
  }
  if (srv >= 0) sceNetSocketClose(srv);

done:
  if (g_log >= 0) sceIoClose(g_log);
  sceKernelExitProcess(0);
  for (;;) sceKernelDelayThread(1000 * 1000);
  return 0;
}
