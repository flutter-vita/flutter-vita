// The smallest user module that exports something, plus the shader compiler.
//
// This exists to answer two questions before any vitaGL work starts.
//
// 1. Can this toolchain build a .suprx that an ordinary UNSAFE application
//    loads from ux0 and calls through a stub library? Answered yes on
//    hardware, 2026-09-09.
//
// 2. Does the runtime shader compiler operate from inside a module? vitaGL
//    compiles every shader through vitashark, which calls SceShaccCgExt, which
//    patches SceShaccCg in this process with taiHEN user hooks. Those hooks
//    have only ever run from an eboot. If they refuse to run from a module,
//    vitaGL cannot become one, and the LGPL shared-library route is closed.
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

// The module needs newlib, because vitashark and libshacccg allocate. An
// application gets newlib set up by crt0, which a module does not run: its
// entry point is module_start, not _start. So the module calls the two halves
// of crt0 that matter by hand.
//
// This is also why crt0.o is on the link line although the module has no main.
// crt0.o is one object file and it defines _init_vita_newlib and
// _free_vita_newlib beside _start, and libc's _exit refers to the second of
// them. Take crt0.o and you take _start's reference to main with it, hence the
// stub below. _start is never entered.
void _init_vita_newlib(void);
void _free_vita_newlib(void);
void __libc_init_array(void);
void __libc_fini_array(void);

// crti.o and crtn.o hold the prologue and the epilogue of _init and _fini, and
// -nostartfiles drops both. __libc_init_array calls _init before it walks
// .init_array, so the symbol has to exist. Empty is correct here: everything
// with a constructor lands in .init_array, which is walked either way.
void _init(void) {}
void _fini(void) {}

int main(void) { return 0; }

int module_start(SceSize argc, const void* args) {
  (void)argc;
  (void)args;
  _init_vita_newlib();
  __libc_init_array();
  return SCE_KERNEL_START_SUCCESS;
}

int module_stop(SceSize argc, const void* args) {
  (void)argc;
  (void)args;
  __libc_fini_array();
  _free_vita_newlib();
  return SCE_KERNEL_STOP_SUCCESS;
}
