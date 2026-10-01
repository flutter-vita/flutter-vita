// Flutter Vita Supervisor -- packaged as eboot2.bin, run as a background app.
//
// When the app under test crashes, both it and the bridge are gone and
// nothing left on the device can start anything, so recovery needs a physical
// tap.
//
// sceBgAppUtilStartBgApp(0) starts eboot2.bin from the same app directory as a
// background application, which is not the foreground app and so survives it
// crashing. This binary stays alive and can launch the bridge again.
//
// It ships with the app rather than the bridge, and that is forced: only the
// app slot is writable by anything we control. An app cannot write its own
// directory (0x8001000D even for an UNSAFE self), and ScePromoterUtil refuses
// to load for us, so the bridge cannot gain an eboot2.bin.
//
// Started from dev_server_run, so it leaves with the dev server: an app that
// links a devserver stub for shipping gets no supervisor.
//
// Deliberately trivial: sockets and one launch call. Its whole value is that
// it does not crash.
//
// There is no display in the background, so psvDebugScreen is NOT used here.
// Output goes to ux0:data/flutter-vita/supervisor.log.

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
      // The whole point. Note we do NOT exit afterwards, unlike the bridge:
      // staying alive is the entire reason this process exists.
      // Six attempts, three seconds apart, because one is not enough.
      //
      // Opening a title on this console fails on the first try and works on the
      // second often enough to be the normal case, and the caller here is
      // recovering a console that has nothing else listening. Staying alive
      // through the retries is the one thing this process can do that a
      // launcher which exits cannot.
      char uri[96];
      snprintf(uri, sizeof uri, "psgm:play?titleid=%s", line + 7);
      int r = -1;
      for (int attempt = 1; attempt <= 6 && r < 0; attempt++) {
        r = sceAppMgrLaunchAppByUri(0xFFFFF, uri);
        if (r < 0) {
          lg("  launch %s attempt %d: 0x%08X\n", line + 7, attempt,
             (unsigned)r);
          sceKernelDelayThread(3 * 1000 * 1000);
        }
      }
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
