// M1 — run Dart AOT on the PlayStation Vita.
//
// ADR-0005 Option A: the snapshot is assembled by gen_snapshot into snapshot.S
// and linked straight into eboot.bin, so the four images are ordinary symbols
// and the Vita's loader places each section with the right protection.
//
// That is the whole reason this file no longer allocates a VM domain block.
// Option B loaded the snapshot at runtime and worked right up until Dart wrote
// to the BSS: Image::bss() puts it at a fixed offset *inside* the instructions
// image, and the VM domain is all-or-nothing -- Open is writable, Close is
// executable, never both. The crash dump named it exactly: BSS::Initialize, a
// strex, data abort. Linking sidesteps it, because .text lands read-execute and
// .bss read-write, as on every other platform.
//
// Success is a number, not a message: hello.dart returns 6830 rather than
// printing, because print() throws until an embedder installs _printClosure and
// runtime/bin -- which normally does that -- is excluded from this port.
//
// Every step logs a checkpoint and flushes before doing anything risky. Track A
// run 2 faulted mid-test and the log survived only by luck; here it is design.

#include <psp2/ctrl.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "dart_api.h"
#include "debugScreen.h"

unsigned int _newlib_heap_size_user = 192 * 1024 * 1024;

#define EXPECTED_CHECKSUM 6830
#define EXPECTED_ASYNC 99

// Defined by snapshot.S, which gen_snapshot emits and CMake assembles into the
// binary. The linker decides where each lands; we only take addresses.
extern const uint8_t _kDartVmSnapshotData[];
extern const uint8_t _kDartVmSnapshotInstructions[];
extern const uint8_t _kDartIsolateSnapshotData[];
extern const uint8_t _kDartIsolateSnapshotInstructions[];

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
  // Not marked noreturn, and on Vita3K it returned -- carrying execution past
  // an already-reported failure and producing a misleading second error.
  for (;;) {
    sceKernelDelayThread(1000 * 1000);
  }
}

int main(void) {
  psvDebugScreenInit();
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  // SCE_O_TRUNC does not truncate on Vita3K; a stale tail is worse than no log.
  sceIoRemove("ux0:data/flutter-vita/m1.log");
  g_log = sceIoOpen("ux0:data/flutter-vita/m1.log",
                    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);

  lg("flutter-vita M1: Dart AOT on Vita\n");
  lg("=================================\n");
  lg("ADR-0005 option A: snapshot linked into eboot.bin\n\n");

  lg("== snapshot symbols ==\n");
  lg("  vm   data %p  instr %p\n", (const void*)_kDartVmSnapshotData,
     (const void*)_kDartVmSnapshotInstructions);
  lg("  iso  data %p  instr %p\n", (const void*)_kDartIsolateSnapshotData,
     (const void*)_kDartIsolateSnapshotInstructions);

  lg("\n== starting the Dart VM ==\n");

  // Must precede Dart_Initialize: the flag table is initialised by this call,
  // not by Dart_Initialize.
  lg("  [checkpoint] Dart_SetVMFlags\n");
  char* err = Dart_SetVMFlags(0, NULL);
  if (err != NULL) {
    lg("  FAIL Dart_SetVMFlags: %s\n", err);
    wait_and_exit(1);
  }

  lg("  [checkpoint] Dart_Initialize\n");
  Dart_InitializeParams params;
  memset(&params, 0, sizeof(params));
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  params.vm_snapshot_data = _kDartVmSnapshotData;
  params.vm_snapshot_instructions = _kDartVmSnapshotInstructions;

  err = Dart_Initialize(&params);
  if (err != NULL) {
    lg("  FAIL Dart_Initialize: %s\n", err);
    wait_and_exit(1);
  }
  lg("  Dart_Initialize ok\n");

  lg("  [checkpoint] Dart_CreateIsolateGroup\n");
  err = NULL;
  Dart_Isolate iso = Dart_CreateIsolateGroup(
      "vita:hello", "main", _kDartIsolateSnapshotData,
      _kDartIsolateSnapshotInstructions,
      /*flags=*/NULL, /*isolate_group_data=*/NULL, /*isolate_data=*/NULL, &err);
  if (iso == NULL) {
    lg("  FAIL Dart_CreateIsolateGroup: %s\n", err ? err : "(no message)");
    wait_and_exit(1);
  }
  lg("  isolate created\n");

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

  // Drains the event loop, where the Future scheduled by main() completes.
  // Exercises the condvars and timers in os_thread_vita.cc -- the part of the
  // port most likely to be subtly wrong.
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
    }
  }

  Dart_ExitScope();
  Dart_ShutdownIsolate();
  err = Dart_Cleanup();
  lg("  Dart_Cleanup: %s\n", err ? err : "ok");

  lg("\n=> %s\n", checksum == EXPECTED_CHECKSUM
                      ? "M1 PASS: Dart AOT ran on the Vita"
                      : "M1 FAIL");
  wait_and_exit(checksum == EXPECTED_CHECKSUM ? 0 : 1);
  return 0;
}
