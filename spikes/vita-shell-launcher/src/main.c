// fvita_launcher — a SceShell module whose only job is to launch an app.
//
// Why it exists: when the foreground app crashes, both M1 and the receiver are
// gone, and nothing left on the device can start anything. Recovery needs a
// physical tap, once per crash, and Phase 2 will produce many. SceShell keeps
// running through all of it, so a module living inside SceShell can relaunch
// us with no human involved.
//
// This is deliberately NOT vitacompanion, which hangs SceShell on this console.
// The differences are the whole point:
//
//   * no FTP server — vitacompanion binds 1337, which was already taken here
//   * no hooks — it hooks sceTouchPeek and friends, and hooking shell functions
//     is where instability usually comes from
//   * no kernel module
//   * module_start returns immediately; everything that can block runs on a
//     worker thread, so shell startup is never delayed
//
// It is also NOT placed in ur0:tai/config.txt and does NOT load at boot. It is
// injected at runtime with taiLoadStartModuleForPidForUser. The failure mode is
// therefore "hung shell, reboot, comes up clean" — never a console that will not
// boot, which is what happened the last two times.
//
// Built -nostdlib, so there is no libc here: the helpers below exist so that a
// C library does not have to be dragged into the shell process.

#include <psp2/appmgr.h>
#include <psp2/kernel/modulemgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>
#include <psp2/net/netctl.h>

#define LAUNCHER_PORT 1343

static char g_net_pool[8 * 1024];

static unsigned int s_len(const char* s) {
  unsigned int n = 0;
  while (s[n] != '\0') n++;
  return n;
}

static int s_eq(const char* a, const char* b, unsigned int n) {
  for (unsigned int i = 0; i < n; i++) {
    if (a[i] != b[i]) return 0;
  }
  return 1;
}

static void s_zero(void* p, unsigned int n) {
  unsigned char* c = (unsigned char*)p;
  for (unsigned int i = 0; i < n; i++) c[i] = 0;
}

static void send_str(int sock, const char* s) {
  sceNetSend(sock, s, s_len(s), 0);
}

// "launch FVTA00003" -> psgm:play?titleid=FVTA00003
static void do_launch(int sock, const char* titleid) {
  static const char prefix[] = "psgm:play?titleid=";
  char uri[64];
  unsigned int i = 0;
  for (; prefix[i] != '\0'; i++) uri[i] = prefix[i];
  unsigned int j = 0;
  while (titleid[j] != '\0' && i < sizeof uri - 1) uri[i++] = titleid[j++];
  uri[i] = '\0';

  const int r = sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  send_str(sock, r >= 0 ? "OK\n" : "ERR\n");
}

static int launcher_thread(SceSize args, void* argp) {
  (void)args;
  (void)argp;

  SceNetInitParam np;
  np.memory = g_net_pool;
  np.size = sizeof g_net_pool;
  np.flags = 0;
  // The shell has almost certainly initialised the net stack already; an
  // already-initialised error here is expected and harmless.
  sceNetInit(&np);

  int srv = -1;
  for (;;) {
    if (srv < 0) {
      srv = sceNetSocket("fvita-launch", SCE_NET_AF_INET, SCE_NET_SOCK_STREAM, 0);
      if (srv >= 0) {
        int one = 1;
        sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_REUSEADDR, &one,
                         sizeof one);
        SceNetSockaddrIn addr;
        s_zero(&addr, sizeof addr);
        addr.sin_family = SCE_NET_AF_INET;
        addr.sin_addr.s_addr = sceNetHtonl(SCE_NET_INADDR_ANY);
        addr.sin_port = sceNetHtons(LAUNCHER_PORT);
        if (sceNetBind(srv, (SceNetSockaddr*)&addr, sizeof addr) < 0 ||
            sceNetListen(srv, 2) < 0) {
          sceNetSocketClose(srv);
          srv = -1;
        }
      }
      if (srv < 0) {
        // Retry forever rather than giving up: at shell startup the network is
        // not up yet, and a plugin that gives up is useless later. This never
        // blocks the shell, because it is on our own thread.
        sceKernelDelayThread(5 * 1000 * 1000);
        continue;
      }
    }

    const int c = sceNetAccept(srv, 0, 0);
    if (c < 0) {
      sceNetSocketClose(srv);
      srv = -1;  // wifi drop; rebuild on the next pass
      sceKernelDelayThread(2 * 1000 * 1000);
      continue;
    }

    char line[64];
    unsigned int n = 0;
    while (n < sizeof line - 1) {
      char ch;
      if (sceNetRecv(c, &ch, 1, 0) <= 0) break;
      if (ch == '\n') break;
      if (ch != '\r') line[n++] = ch;
    }
    line[n] = '\0';

    if (n >= 4 && s_eq(line, "ping", 4)) {
      send_str(c, "launcher\n");
    } else if (n > 7 && s_eq(line, "launch ", 7)) {
      do_launch(c, line + 7);
    } else {
      send_str(c, "ERR (ping|launch <titleid>)\n");
    }
    sceNetSocketClose(c);
  }
  return 0;
}

int module_start(SceSize argc, const void* args) {
  (void)argc;
  (void)args;
  // Return immediately. Everything slow happens on the thread; blocking here
  // would delay SceShell's startup, which is the classic way to hang the shell.
  const SceUID t = sceKernelCreateThread("fvita_launcher", launcher_thread,
                                         0x10000100, 0x2000, 0, 0, 0);
  if (t >= 0) sceKernelStartThread(t, 0, 0);
  return SCE_KERNEL_START_SUCCESS;
}

int module_stop(SceSize argc, const void* args) {
  (void)argc;
  (void)args;
  return SCE_KERNEL_STOP_SUCCESS;
}

int _start(SceSize argc, const void* args)
    __attribute__((weak, alias("module_start")));
