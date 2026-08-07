// M1 — run Dart AOT on the PlayStation Vita.
//
// Loads the four snapshot blobs from app0:, puts the two instruction blobs in a
// VM domain block (ADR-0005 Option B, proven by the Track A probe), starts the
// Dart VM, calls main(), and checks the answer.
//
// Success is a number, not a message: hello.dart returns 6830 rather than
// printing, because print() throws until an embedder installs _printClosure and
// runtime/bin -- which normally does that -- is excluded from this port. See
// spikes/b1-aot-snapshot/hello.dart.
//
// Every step logs a checkpoint and flushes before doing anything risky. Track A
// run 2 faulted mid-test and the log survived only by luck; here it is design.

#include <psp2/ctrl.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/sysmem.h>
#include <psp2/kernel/threadmgr.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dart_api.h"
#include "debugScreen.h"

unsigned int _newlib_heap_size_user = 192 * 1024 * 1024;

#define EXPECTED_CHECKSUM 6830
#define EXPECTED_ASYNC 99

// One VM block holds both instruction blobs. 1 MiB is the measured minimum
// granularity (Track A run 3); the blobs total ~362 KB, so one block is plenty.
#define VM_BLOCK_SIZE (1 * 1024 * 1024)
#define INSTR_ALIGN 4096

static SceUID g_log = -1;

static void lg(const char* fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  psvDebugScreenPuts(buf);
  if (g_log >= 0) {
    sceIoWrite(g_log, buf, strlen(buf));
    sceIoSyncByFd(g_log, 0);  // a fault must not cost us the trail
  }
}

static void wait_and_exit(int code) {
  lg("\npress START to exit.\n");
  if (g_log >= 0) sceIoClose(g_log);
  SceCtrlData pad;
  sceCtrlSetSamplingMode(SCE_CTRL_MODE_ANALOG);
  for (;;) {
    sceCtrlPeekBufferPositive(0, &pad, 1);
    if (pad.buttons & SCE_CTRL_START) break;
    sceKernelDelayThread(50 * 1000);
  }
  sceKernelExitProcess(code);
}

// Reads a whole file from app0:. Returns NULL on failure.
static void* read_blob(const char* name, size_t* out_size) {
  char path[256];
  snprintf(path, sizeof path, "app0:/%s", name);
  SceUID fd = sceIoOpen(path, SCE_O_RDONLY, 0);
  if (fd < 0) {
    lg("  FAIL open %s -> 0x%08X\n", path, fd);
    return NULL;
  }
  const SceOff size = sceIoLseek(fd, 0, SCE_SEEK_END);
  sceIoLseek(fd, 0, SCE_SEEK_SET);
  void* buf = malloc((size_t)size);
  if (buf == NULL) {
    lg("  FAIL malloc %lld for %s\n", (long long)size, name);
    sceIoClose(fd);
    return NULL;
  }
  const int got = sceIoRead(fd, buf, (SceSize)size);
  sceIoClose(fd);
  if (got != (int)size) {
    lg("  FAIL read %s: %d of %lld\n", name, got, (long long)size);
    free(buf);
    return NULL;
  }
  *out_size = (size_t)size;
  lg("  %-34s %8u B\n", name, (unsigned)size);
  return buf;
}

static size_t align_up(size_t v, size_t a) {
  return (v + a - 1) & ~(a - 1);
}

int main(void) {
  psvDebugScreenInit();
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  g_log = sceIoOpen("ux0:data/flutter-vita/m1.log",
                    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);

  lg("flutter-vita M1: Dart AOT on Vita\n");
  lg("=================================\n");
  lg("log -> ux0:data/flutter-vita/m1.log\n\n");

  // ---------------------------------------------------------------- blobs
  lg("== reading snapshot blobs ==\n");
  size_t vm_data_size, iso_data_size, vm_instr_size, iso_instr_size;
  void* vm_data = read_blob("vm_snapshot_data.bin", &vm_data_size);
  void* iso_data = read_blob("isolate_snapshot_data.bin", &iso_data_size);
  void* vm_instr_src = read_blob("vm_snapshot_instructions.bin", &vm_instr_size);
  void* iso_instr_src = read_blob("isolate_snapshot_instructions.bin", &iso_instr_size);
  if (!vm_data || !iso_data || !vm_instr_src || !iso_instr_src) {
    lg("\nFAIL: could not read all four blobs\n");
    wait_and_exit(1);
  }

  // ------------------------------------------------------------ VM domain
  lg("\n== VM domain (ADR-0005 option B) ==\n");
  const size_t vm_off = 0;
  const size_t iso_off = align_up(vm_instr_size, INSTR_ALIGN);
  const size_t needed = iso_off + iso_instr_size;
  lg("  need %u B of %u B block\n", (unsigned)needed, (unsigned)VM_BLOCK_SIZE);
  if (needed > VM_BLOCK_SIZE) {
    lg("  FAIL: instructions exceed the block\n");
    wait_and_exit(1);
  }

  const SceUID vm_uid = sceKernelAllocMemBlockForVM("dart_instr", VM_BLOCK_SIZE);
  if (vm_uid < 0) {
    lg("  FAIL sceKernelAllocMemBlockForVM -> 0x%08X\n", vm_uid);
    wait_and_exit(1);
  }
  void* vm_base = NULL;
  if (sceKernelGetMemBlockBase(vm_uid, &vm_base) < 0 || vm_base == NULL) {
    lg("  FAIL sceKernelGetMemBlockBase\n");
    wait_and_exit(1);
  }
  lg("  block base %p\n", vm_base);

  // Open puts the domain in the WRITABLE state, Close in the EXECUTABLE state.
  // Inverted from the VitaSDK header's one-line summary; established by Track A
  // run 2, which faulted writing with the domain closed. See ADR-0001.
  lg("  [checkpoint] opening domain for write\n");
  int r = sceKernelOpenVMDomain();
  lg("  sceKernelOpenVMDomain   0x%08X\n", r);

  uint8_t* const base = (uint8_t*)vm_base;
  memcpy(base + vm_off, vm_instr_src, vm_instr_size);
  memcpy(base + iso_off, iso_instr_src, iso_instr_size);
  lg("  copied %u + %u B of instructions\n", (unsigned)vm_instr_size,
     (unsigned)iso_instr_size);

  lg("  [checkpoint] closing domain for execute\n");
  r = sceKernelCloseVMDomain();
  lg("  sceKernelCloseVMDomain  0x%08X\n", r);

  r = sceKernelSyncVMDomain(vm_uid, vm_base, VM_BLOCK_SIZE);
  lg("  sceKernelSyncVMDomain   0x%08X\n", r);

  free(vm_instr_src);
  free(iso_instr_src);

  const uint8_t* vm_instr = base + vm_off;
  const uint8_t* iso_instr = base + iso_off;

  // ------------------------------------------------------------ Dart_Initialize
  lg("\n== starting the Dart VM ==\n");

  // Must precede Dart_Initialize -- without it the VM reports
  // "VM initialization failed-VM Flags not initialized." Passing no flags is
  // fine; the call itself is what initialises the flag table.
  lg("  [checkpoint] Dart_SetVMFlags\n");
  char* flag_err = Dart_SetVMFlags(0, NULL);
  if (flag_err != NULL) {
    lg("  FAIL Dart_SetVMFlags: %s\n", flag_err);
    wait_and_exit(1);
  }
  lg("  Dart_SetVMFlags ok\n");

  lg("  [checkpoint] Dart_Initialize\n");

  Dart_InitializeParams params;
  memset(&params, 0, sizeof(params));
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  params.vm_snapshot_data = (const uint8_t*)vm_data;
  params.vm_snapshot_instructions = vm_instr;

  char* err = Dart_Initialize(&params);
  if (err != NULL) {
    lg("  FAIL Dart_Initialize: %s\n", err);
    wait_and_exit(1);
  }
  lg("  Dart_Initialize ok\n");

  // ------------------------------------------------------------ isolate
  lg("  [checkpoint] Dart_CreateIsolateGroup\n");
  err = NULL;
  Dart_Isolate iso = Dart_CreateIsolateGroup(
      "vita:hello", "main", (const uint8_t*)iso_data, iso_instr,
      /*flags=*/NULL, /*isolate_group_data=*/NULL, /*isolate_data=*/NULL, &err);
  if (iso == NULL) {
    lg("  FAIL Dart_CreateIsolateGroup: %s\n", err ? err : "(no message)");
    wait_and_exit(1);
  }
  lg("  isolate created\n");

  // ------------------------------------------------------------ run main()
  Dart_EnterScope();
  lg("  [checkpoint] invoking main()\n");

  Dart_Handle root = Dart_RootLibrary();
  if (Dart_IsError(root)) {
    lg("  FAIL Dart_RootLibrary: %s\n", Dart_GetError(root));
    wait_and_exit(1);
  }

  Dart_Handle result =
      Dart_Invoke(root, Dart_NewStringFromCString("main"), 0, NULL);
  if (Dart_IsError(result)) {
    lg("  FAIL main(): %s\n", Dart_GetError(result));
    wait_and_exit(1);
  }

  int64_t checksum = 0;
  Dart_Handle conv = Dart_IntegerToInt64(result, &checksum);
  if (Dart_IsError(conv)) {
    lg("  FAIL reading return value: %s\n", Dart_GetError(conv));
    wait_and_exit(1);
  }
  lg("\n  main() returned %lld (expected %d) %s\n", (long long)checksum,
     EXPECTED_CHECKSUM,
     checksum == EXPECTED_CHECKSUM ? "PASS" : "MISMATCH");

  // ------------------------------------------------------------ microtasks
  // Drains the event loop, which is where the Future scheduled by main()
  // completes. This exercises the condvars and timers in os_thread_vita.cc --
  // the part of the port most likely to be subtly wrong.
  lg("  [checkpoint] Dart_RunLoop\n");
  Dart_Handle loop = Dart_RunLoop();
  if (Dart_IsError(loop)) {
    lg("  FAIL Dart_RunLoop: %s\n", Dart_GetError(loop));
  } else {
    Dart_Handle marker =
        Dart_Invoke(root, Dart_NewStringFromCString("asyncMarker"), 0, NULL);
    int64_t async_value = 0;
    if (!Dart_IsError(marker) &&
        !Dart_IsError(Dart_IntegerToInt64(marker, &async_value))) {
      lg("  asyncMarker() = %lld (expected %d) %s\n", (long long)async_value,
         EXPECTED_ASYNC,
         async_value == EXPECTED_ASYNC ? "PASS -- microtasks drained"
                                       : "FAIL -- event loop did not run");
    } else {
      lg("  FAIL reading asyncMarker()\n");
    }
  }

  Dart_ExitScope();
  Dart_ShutdownIsolate();
  lg("  [checkpoint] Dart_Cleanup\n");
  err = Dart_Cleanup();
  lg("  Dart_Cleanup: %s\n", err ? err : "ok");

  lg("\n=> %s\n", checksum == EXPECTED_CHECKSUM
                      ? "M1 PASS: Dart AOT ran on the Vita"
                      : "M1 FAIL");
  wait_and_exit(checksum == EXPECTED_CHECKSUM ? 0 : 1);
  return 0;
}
