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
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>
#include <psp2/net/netctl.h>
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

int main(void) {
  psvDebugScreenInit();
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
  } else {
    SceNetInitParam np;
    np.memory = g_net_pool;
    np.size = sizeof g_net_pool;
    np.flags = 0;
    const int ni = sceNetInit(&np);
    if (ni < 0 && ni != (int)0x80410103) {
      lg("FATAL: sceNetInit 0x%08X\n", (unsigned)ni);
    } else {
      sceNetCtlInit();
      SceNetCtlInfo info;
      if (sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_IP_ADDRESS, &info) >= 0) {
        lg("listening on %s:%d\n", info.ip_address, LOADER_PORT);
      } else {
        lg("listening on :%d (no IP yet)\n", LOADER_PORT);
      }

      const int srv =
          sceNetSocket("fvita-loader", SCE_NET_AF_INET, SCE_NET_SOCK_STREAM, 0);
      int one = 1;
      sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_REUSEADDR, &one,
                       sizeof one);
      SceNetSockaddrIn addr;
      memset(&addr, 0, sizeof addr);
      addr.sin_family = SCE_NET_AF_INET;
      addr.sin_addr.s_addr = sceNetHtonl(SCE_NET_INADDR_ANY);
      addr.sin_port = sceNetHtons(LOADER_PORT);
      if (srv < 0 || sceNetBind(srv, (SceNetSockaddr*)&addr, sizeof addr) < 0 ||
          sceNetListen(srv, 2) < 0) {
        lg("FATAL: bind/listen on %d failed\n", LOADER_PORT);
      } else {
        sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_NBIO, &one,
                         sizeof one);
        lg("\nwaiting for commands. START exits.\n");

        SceCtrlData pad;
        sceCtrlSetSamplingMode(SCE_CTRL_MODE_ANALOG);
        for (;;) {
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
          // Non-blocking accept so START still works with the network down --
          // which on this device is a regular occurrence, and would otherwise
          // strand the user in an app with no way out.
          sceCtrlPeekBufferPositive(0, &pad, 1);
          if (pad.buttons & SCE_CTRL_START) {
            lg("START pressed\n");
            break;
          }
          sceKernelDelayThread(30 * 1000);
        }
        sceNetSocketClose(srv);
      }
    }
  }

  if (g_log >= 0) sceIoClose(g_log);
  sceKernelExitProcess(0);
  for (;;) sceKernelDelayThread(1000 * 1000);
  return 0;
}
