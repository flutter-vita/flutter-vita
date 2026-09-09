// The smallest user module that exports something.
//
// This exists to answer one question before any vitaGL work starts: can this
// toolchain build a .suprx that an ordinary UNSAFE application loads from ux0
// and calls through a stub library? If it cannot, the LGPL shared-library
// route is closed and nothing else in this experiment matters.
#include <psp2/kernel/modulemgr.h>
#include <psp2/kernel/processmgr.h>

// The call into sceKernelGetProcessTimeWide is not decoration. A module that
// imports nothing from the system has no .vitalink section, and vita-elf-create
// refuses it with "probably not a Vita binary". Any real library imports
// something; this one has to import something on purpose.
int spike_add(int a, int b) {
  const SceUInt64 t = sceKernelGetProcessTimeWide();
  return (t == 0) ? -1 : a + b;
}

int module_start(SceSize argc, const void* args) {
  (void)argc;
  (void)args;
  return SCE_KERNEL_START_SUCCESS;
}

int module_stop(SceSize argc, const void* args) {
  (void)argc;
  (void)args;
  return SCE_KERNEL_STOP_SUCCESS;
}
