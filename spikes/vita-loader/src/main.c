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
#include <psp2/ctrl.h>
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

// Copy staged -> target. Via a .tmp beside the target so a failure part-way
// leaves the installed eboot.bin intact; the only alternative is reinstalling
// the vpk by hand.
static int cmd_install(int sock) {
  SceUID in = sceIoOpen(STAGED, SCE_O_RDONLY, 0777);
  if (in < 0) {
    send_str(sock, "ERR nothing staged\n");
    return -1;
  }
  const char* tmp = TARGET_EBOOT ".tmp";
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

  sceIoRemove(TARGET_EBOOT);  // sceIoRename will not overwrite
  const int rr = sceIoRename(tmp, TARGET_EBOOT);
  if (rr < 0) {
    lg("  install: rename failed 0x%08X\n", (unsigned)rr);
    send_str(sock, "ERR rename\n");
    return -1;
  }
  lg("  installed %d bytes into %s\n", total, TARGET_EBOOT);
  send_str(sock, "OK\n");
  return 0;
}

static void cmd_launch(int sock) {
  send_str(sock, "OK launching " TARGET_TITLEID "\n");
  sceNetSocketClose(sock);
  lg("  launching %s\n", TARGET_TITLEID);
  sceKernelDelayThread(200 * 1000);  // let the reply drain
  // Launching another title replaces us, which is exactly what we want: the
  // target's directory must be unlocked, and it cannot be while we hold it.
  sceAppMgrLaunchAppByUri(0xFFFFF, "psgm:play?titleid=" TARGET_TITLEID);
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

    if (strcmp(line, "ping") == 0) {
      send_str(sock, "loader\n");
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
      if (size < 0 || size > 64 * 1024 * 1024) { send_str(sock, "ERR size\n"); return 0; }
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
    } else if (strcmp(line, "install") == 0) {
      cmd_install(sock);
    } else if (strcmp(line, "launch") == 0) {
      cmd_launch(sock);
      return 1;
    } else if (strcmp(line, "deploy") == 0) {
      if (cmd_install(sock) == 0) {
        cmd_launch(sock);
        return 1;
      }
    } else if (strcmp(line, "exit") == 0) {
      send_str(sock, "OK\n");
      return 1;
    } else {
      send_str(sock, "ERR (ping|probe|stage <n>|install|launch|deploy|exit)\n");
    }
  }
}


// Keep the screen on for as long as this app is running.
//
// SCE_KERNEL_POWER_TICK_DEFAULT resets every idle timer at once -- auto-suspend,
// OLED off and OLED dimming -- so one periodic tick covers all three. A
// dedicated thread rather than a call in the main loop, because the main loop
// blocks for seconds at a time during a Dart run or a 2.4 MB upload, and that
// is exactly when the screen would otherwise dim.
//
// This is scoped to our own process on purpose: it stops when the app exits, so
// it cannot leave the console awake by accident.
static int power_tick_thread(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  for (;;) {
    sceKernelPowerTick(SCE_KERNEL_POWER_TICK_DEFAULT);
    sceKernelDelayThread(10 * 1000 * 1000);  // idle timers are minutes, not seconds
  }
  return 0;
}

static void start_power_tick(void) {
  const SceUID t = sceKernelCreateThread("fvita_powertick", power_tick_thread,
                                         0x10000100, 0x1000, 0, 0, NULL);
  if (t >= 0) sceKernelStartThread(t, 0, NULL);
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

  for (;;) {
    // There is no user-mode API to join a given access point -- sceNetCtl
    // exposes state and callbacks only -- so the best available behaviour is to
    // notice the drop, tear the socket down, and rebuild it the moment the
    // system reconnects. No tap required either way.
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
      if (c >= 0) {
        int zero = 0;
        sceNetSetsockopt(c, SCE_NET_SOL_SOCKET, SCE_NET_SO_NBIO, &zero,
                         sizeof zero);
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
