// Flutter Vita Supervisor — packaged as eboot2.bin, run as a background app.
//
// The problem it exists to solve: when the app under test crashes, both it and
// the receiver are gone, and nothing left on the device can start anything.
// Recovery needs a physical tap. That is tolerable once; it is not tolerable as
// the routine outcome of every crash, and the crash under investigation
// produces one every twenty seconds.
//
// sceBgAppUtilStartBgApp(0) starts eboot2.bin from the same app directory as a
// *background* application. A background process is not the foreground app, so
// it survives the foreground app crashing. This binary therefore stays alive
// across the app dying and can launch the receiver again on request.
//
// It ships with the *app*, not with the receiver, and that is forced rather than
// chosen. Only one directory on this device is writable by anything we control
// -- ux0:app/FVTA00002, which the receiver installs into. An app cannot write its
// own directory (`touch ux0:app/FVTA00001/x` is 0x8001000D, EACCES, even for an
// UNSAFE self), and ScePromoterUtil, which could, refuses to load for us with
// MODULEMGR_NO_LIB. So the receiver cannot update itself and cannot gain an
// eboot2.bin; the app slot is redeployed every cycle and can.
//
// Started from dev_server_run, which makes it dev-loop infrastructure that
// leaves with the dev server: an app that links a devserver stub for shipping
// gets no supervisor, which is right.
//
// Deliberately trivial: sockets and one launch call. No Dart, no filesystem
// writes beyond a log, nothing that can fault. The whole value is that it does
// not crash, so it must stay boring.
//
// There is no display in the background: psvDebugScreen is NOT used here. All
// output goes to ux0:data/flutter-vita/supervisor.log.

#include <psp2/appmgr.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>
#include <psp2/net/netctl.h>
#include <psp2/sysmodule.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define SUPERVISOR_PORT 1342

static SceUID g_log = -1;
static char g_net_pool[16 * 1024];

static void lg(const char* fmt, ...) {
  char buf[256];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
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

static void serve(int sock) {
  char line[128];
  for (;;) {
    const int n = recv_line(sock, line, sizeof line);
    if (n <= 0) return;

    if (strcmp(line, "ping") == 0) {
      send_str(sock, "supervisor\n");
    } else if (strncmp(line, "launch ", 7) == 0) {
      // The whole point. Note we do NOT exit afterwards, unlike the receiver:
      // staying alive is the entire reason this process exists.
      char uri[96];
      snprintf(uri, sizeof uri, "psgm:play?titleid=%s", line + 7);
      const int r = sceAppMgrLaunchAppByUri(0xFFFFF, uri);
      char m[160];
      snprintf(m, sizeof m, "%s launch %s rc=0x%08X\n", r >= 0 ? "OK" : "ERR",
               line + 7, (unsigned)r);
      lg("  %s", m);
      send_str(sock, m);
      return;
    } else {
      send_str(sock, "ERR (ping|launch <titleid>)\n");
    }
  }
}

int main(void) {
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  sceIoRemove("ux0:data/flutter-vita/supervisor.log");
  g_log = sceIoOpen("ux0:data/flutter-vita/supervisor.log",
                    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  lg("supervisor starting (background app)\n");

  if (sceSysmoduleLoadModule(SCE_SYSMODULE_NET) < 0) {
    lg("FATAL net module\n");
    sceKernelExitProcess(1);
  }
  SceNetInitParam np;
  np.memory = g_net_pool;
  np.size = sizeof g_net_pool;
  np.flags = 0;
  const int ni = sceNetInit(&np);
  if (ni < 0 && ni != (int)0x80410103) {
    lg("FATAL sceNetInit 0x%08X\n", (unsigned)ni);
    sceKernelExitProcess(1);
  }
  sceNetCtlInit();

  int srv = -1;
  for (;;) {
    if (srv < 0) {
      srv = sceNetSocket("fvita-sup", SCE_NET_AF_INET, SCE_NET_SOCK_STREAM, 0);
      if (srv >= 0) {
        int one = 1;
        sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_REUSEADDR, &one,
                         sizeof one);
        SceNetSockaddrIn addr;
        memset(&addr, 0, sizeof addr);
        addr.sin_family = SCE_NET_AF_INET;
        addr.sin_addr.s_addr = sceNetHtonl(SCE_NET_INADDR_ANY);
        addr.sin_port = sceNetHtons(SUPERVISOR_PORT);
        if (sceNetBind(srv, (SceNetSockaddr*)&addr, sizeof addr) < 0 ||
            sceNetListen(srv, 2) < 0) {
          sceNetSocketClose(srv);
          srv = -1;
        } else {
          lg("listening on :%d\n", SUPERVISOR_PORT);
        }
      }
      if (srv < 0) {
        // Wifi is not up yet, or went away. Keep retrying forever rather than
        // exiting: an exited supervisor is exactly the situation this avoids.
        sceKernelDelayThread(3 * 1000 * 1000);
        continue;
      }
    }

    const int c = sceNetAccept(srv, NULL, NULL);
    if (c < 0) {
      // Blocking accept, so a negative result means the socket is broken --
      // usually a wifi drop. Rebuild it on the next pass.
      sceNetSocketClose(srv);
      srv = -1;
      lg("accept failed; rebuilding the listener\n");
      sceKernelDelayThread(2 * 1000 * 1000);
      continue;
    }
    serve(c);
    sceNetSocketClose(c);
  }
  return 0;
}
