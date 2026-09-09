// Load the spike module from ux0, call into it, and write down what happened.
//
// The report goes to a file rather than the screen, because the screen is not
// readable from the host and this experiment is run from the host. The last
// act is a launch of the receiver, so the console never stops on the LiveArea
// with nothing answering a port.
#include <psp2/appmgr.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/modulemgr.h>
#include <psp2/kernel/processmgr.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define REPORT "ux0:data/flutter-vita/spike-module.txt"
#define MODULE "ux0:data/flutter-vita/spike.suprx"
#define RECEIVER "FVTA00001"

// Declared here rather than in a header: the point is that the host knows only
// the signature, and the linker resolves it through the stub library.
int spike_add(int a, int b);

static SceUID g_fd = -1;

static void say(const char* fmt, ...) {
  char line[256];
  va_list ap;
  va_start(ap, fmt);
  const int n = vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  if (g_fd >= 0 && n > 0) sceIoWrite(g_fd, line, (SceSize)n);
}

int main(void) {
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  sceIoRemove(REPORT);
  g_fd = sceIoOpen(REPORT, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);

  say("spike: user module load\n");

  // A stub-linked call before the module is loaded would fault, so the load
  // comes first and its result decides whether the call happens at all.
  int status = 0;
  const SceUID mod =
      sceKernelLoadStartModule(MODULE, 0, NULL, 0, NULL, &status);
  say("load     %s\n", MODULE);
  say("  uid    0x%08X\n", (unsigned)mod);
  say("  status 0x%08X\n", (unsigned)status);

  if (mod >= 0) {
    const int sum = spike_add(2, 3);
    say("  call   spike_add(2,3) = %d %s\n", sum, sum == 5 ? "OK" : "WRONG");
    int stop = 0;
    const int r = sceKernelStopUnloadModule(mod, 0, NULL, 0, NULL, &stop);
    say("  unload 0x%08X (stop 0x%08X)\n", (unsigned)r, (unsigned)stop);
  } else {
    say("  the module did not load; nothing was called\n");
  }

  say("done\n");
  if (g_fd >= 0) sceIoClose(g_fd);

  char uri[64];
  snprintf(uri, sizeof uri, "psgm:play?titleid=%s", RECEIVER);
  sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  sceKernelExitProcess(0);
  return 0;
}
