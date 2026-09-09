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
#define SHACCCG "ur0:/data/libshacccg.suprx"
#define RECEIVER "FVTA00001"

// Declared here rather than in a header: the point is that the host knows only
// the signature, and the linker resolves them through the stub library.
int spike_add(int a, int b);
int spike_shader_probe(void (*log)(const char*));

// The same probe, compiled into this binary rather than into the module.
int local_shader_probe(void (*log)(const char*));

static SceUID g_fd = -1;

static void say(const char* fmt, ...) {
  char line[512];
  va_list ap;
  va_start(ap, fmt);
  const int n = vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  if (g_fd >= 0 && n > 0) {
    sceIoWrite(g_fd, line, (SceSize)n);
    // Sync every line. The interesting runs are the ones that end in a fault,
    // and an unsynced tail is exactly the part worth reading.
    sceIoSyncByFd(g_fd, 1);
  }
}

// Handed to the module so it can write while it still can.
static void module_log(const char* line) { say("%s", line); }

static SceUID load_module(void) {
  int status = 0;
  const SceUID mod =
      sceKernelLoadStartModule(MODULE, 0, NULL, 0, NULL, &status);
  say("  uid    0x%08X  status 0x%08X\n", (unsigned)mod, (unsigned)status);
  return mod;
}

int main(void) {
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  sceIoRemove(REPORT);
  g_fd = sceIoOpen(REPORT, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);

  say("spike: a user module that carries the shader compiler\n\n");

  // The control runs first, and from the eboot. If libshacccg faults here too
  // then the module is innocent and the fault is somewhere else in this spike.
  say("shader compiler, from the application\n");
  const int lr = local_shader_probe(module_log);
  say("  local probe returned %d %s\n\n", lr, lr == 0 ? "WORKS" : "no");

  // Nothing has loaded libshacccg yet, and that is deliberate: vitashark loads
  // it inside shark_init and refuses with MODULEMGR_OLD_LIB if somebody got
  // there first. The module's SceShaccCg imports are weak so that this order
  // is allowed. The fallback below stays because it is the diagnostic: if the
  // module needs libshacccg present, the compiler cannot then start.
  say("load the module before libshacccg\n");
  SceUID mod = load_module();
  int order = 1;

  if (mod < 0) {
    say("\nload libshacccg first, then the module\n");
    int st = 0;
    const SceUID sh =
        sceKernelLoadStartModule(SHACCCG, 0, NULL, 0, NULL, &st);
    say("  shacccg 0x%08X  status 0x%08X\n", (unsigned)sh, (unsigned)st);
    mod = load_module();
    order = 2;
  }

  if (mod < 0) {
    say("\nthe module did not load in either order. nothing was called.\n");
  } else {
    say("\nmodule loaded, order %d\n", order);
    const int sum = spike_add(2, 3);
    say("  spike_add(2,3) = %d %s\n", sum, sum == 5 ? "OK" : "WRONG");

    say("\nshader compiler, from inside the module\n");
    const int r = spike_shader_probe(module_log);
    say("  probe returned %d %s\n", r,
        r == 0 ? "COMPILER WORKS IN A MODULE" : "no");

    int stop = 0;
    const int u = sceKernelStopUnloadModule(mod, 0, NULL, 0, NULL, &stop);
    say("\n  unload 0x%08X (stop 0x%08X)\n", (unsigned)u, (unsigned)stop);
  }

  say("done\n");
  if (g_fd >= 0) sceIoClose(g_fd);

  char uri[64];
  snprintf(uri, sizeof uri, "psgm:play?titleid=%s", RECEIVER);
  sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  sceKernelExitProcess(0);
  return 0;
}
