// Vita NTP — set the console clock from a network time server.
//
// Why this exists: the Vita's own "Set Automatically" no longer works on this
// console (the Set Now button does nothing), and there is no NTP homebrew for
// the Vita at all. Setting the clock is kernel-only -- psp2/rtc.h has no
// setter, only psp2kern does -- so a small kernel module is unavoidable.
//
// What is avoidable is putting that module in ur0:tai/config.txt. It is loaded
// on demand with taiLoadStartKernelModuleForUser, used, and unloaded, so it
// never runs at boot and cannot bootloop the console. A fault costs a power
// cycle. Nothing in the system partition is touched.

#include <psp2/ctrl.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>
#include <psp2/net/netctl.h>
#include <psp2/rtc.h>
#include <psp2/sysmodule.h>
#include <taihen.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "debugScreen.h"

// Exported by the kernel module; the stub comes from vita_create_stubs.
extern int vitaNtpKernelGetApiVersion(void);
extern int vitaNtpKernelSetUnixTime(unsigned int unix_seconds);
extern int vitaNtpKernelGetUnixTime(unsigned int *out);

#define KMOD_PATH "ux0:data/flutter-vita/vitantp_kernel.skprx"
#define NTP_PORT 123
// 1900-01-01 to 1970-01-01, which is what NTP counts from.
#define NTP_UNIX_DELTA 2208988800u

static char g_net_pool[16 * 1024];
static SceUID g_log = -1;

static void lg(const char* fmt, ...) {
  char buf[256];
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

// Returns Unix seconds, or 0 on failure.
static unsigned int ntp_query(const char* host) {
  SceNetInAddr addr;
  memset(&addr, 0, sizeof addr);

  const int rid = sceNetResolverCreate("vitantp", NULL, 0);
  if (rid < 0) {
    lg("  resolver create failed 0x%08X\n", (unsigned)rid);
    return 0;
  }
  const int rr = sceNetResolverStartNtoa(rid, host, &addr, 5 * 1000 * 1000, 3, 0);
  sceNetResolverDestroy(rid);
  if (rr < 0) {
    lg("  cannot resolve %s (0x%08X)\n", host, (unsigned)rr);
    return 0;
  }

  const int s = sceNetSocket("vitantp", SCE_NET_AF_INET, SCE_NET_SOCK_DGRAM, 0);
  if (s < 0) {
    lg("  socket failed 0x%08X\n", (unsigned)s);
    return 0;
  }
  SceNetSockaddrIn sa;
  memset(&sa, 0, sizeof sa);
  sa.sin_family = SCE_NET_AF_INET;
  sa.sin_addr = addr;
  sa.sin_port = sceNetHtons(NTP_PORT);

  // Bare SNTP client request: LI=0, VN=3, Mode=3.
  unsigned char pkt[48];
  memset(pkt, 0, sizeof pkt);
  pkt[0] = 0x1B;

  unsigned int result = 0;
  if (sceNetSendto(s, pkt, sizeof pkt, 0, (SceNetSockaddr*)&sa, sizeof sa) >= 0) {
    // Bounded wait, so a silent server cannot hang the app.
    SceNetSockaddrIn from;
    unsigned int fromlen = sizeof from;
    int timeout = 5 * 1000 * 1000;
    sceNetSetsockopt(s, SCE_NET_SOL_SOCKET, SCE_NET_SO_RCVTIMEO, &timeout,
                     sizeof timeout);
    const int n = sceNetRecvfrom(s, pkt, sizeof pkt, 0,
                                 (SceNetSockaddr*)&from, &fromlen);
    if (n >= 48) {
      // Transmit timestamp, seconds part, at byte 40. Big-endian on the wire.
      const unsigned int ntp_secs = ((unsigned int)pkt[40] << 24) |
                                    ((unsigned int)pkt[41] << 16) |
                                    ((unsigned int)pkt[42] << 8) |
                                    ((unsigned int)pkt[43]);
      if (ntp_secs > NTP_UNIX_DELTA) result = ntp_secs - NTP_UNIX_DELTA;
    } else {
      lg("  no reply from %s\n", host);
    }
  }
  sceNetSocketClose(s);
  return result;
}

static void show_time(const char* label) {
  SceDateTime dt;
  memset(&dt, 0, sizeof dt);
  if (sceRtcGetCurrentClockLocalTime(&dt) >= 0) {
    lg("  %s %04d-%02d-%02d %02d:%02d:%02d\n", label, dt.year, dt.month,
       dt.day, dt.hour, dt.minute, dt.second);
  }
}

int main(void) {
  psvDebugScreenInit();
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  sceIoRemove("ux0:data/flutter-vita/ntp.log");
  g_log = sceIoOpen("ux0:data/flutter-vita/ntp.log",
                    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);

  lg("Vita NTP\n========\n\n");
  show_time("clock before:");

  if (sceSysmoduleLoadModule(SCE_SYSMODULE_NET) < 0) {
    lg("FATAL: net module\n");
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

      lg("\nquerying time servers...\n");
      // Several, because a single pool entry being unreachable should not be
      // the end of it.
      static const char* const hosts[] = {
          "pool.ntp.org", "time.google.com", "time.cloudflare.com", NULL};
      unsigned int now = 0;
      for (int i = 0; hosts[i] != NULL && now == 0; i++) {
        lg("  trying %s\n", hosts[i]);
        now = ntp_query(hosts[i]);
      }

      if (now == 0) {
        lg("\nno time server answered. is wifi up?\n");
      } else {
        lg("  got unix time %u\n", now);

        // Load the kernel module only now, and only for as long as the one
        // call takes.
        lg("\nloading kernel module...\n");
        const SceUID mod = taiLoadStartKernelModule(KMOD_PATH, 0, NULL, 0);
        if (mod < 0) {
          lg("  load failed 0x%08X\n", (unsigned)mod);
          lg("  (expected at %s)\n", KMOD_PATH);
        } else {
          const int api = vitaNtpKernelGetApiVersion();
          lg("  loaded, api=%d\n", api);
          const int sr = vitaNtpKernelSetUnixTime(now);
          if (sr < 0) {
            lg("  set failed 0x%08X\n", (unsigned)sr);
          } else {
            lg("  clock set\n");
          }
          int res = 0;
          taiStopUnloadKernelModule(mod, 0, NULL, 0, NULL, &res);
          lg("  kernel module unloaded\n");
        }
        show_time("clock after: ");
      }
    }
  }

  lg("\npress START to exit.\n");
  if (g_log >= 0) sceIoClose(g_log);
  SceCtrlData pad;
  sceCtrlSetSamplingMode(SCE_CTRL_MODE_ANALOG);
  for (;;) {
    sceCtrlPeekBufferPositive(0, &pad, 1);
    if (pad.buttons & SCE_CTRL_START) break;
    sceKernelDelayThread(50 * 1000);
  }
  sceKernelExitProcess(0);
  for (;;) sceKernelDelayThread(1000 * 1000);
  return 0;
}
