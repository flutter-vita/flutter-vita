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

// Backs hello.dart's @Native<Void Function(Handle)>(symbol: 'vita_dart_print').
// Taking a Handle rather than a Pointer means no malloc and no manual UTF-8
// conversion on the Dart side.
static void vita_dart_print(Dart_Handle line) {
  const char* s = NULL;
  Dart_Handle r = Dart_StringToCString(line, &s);
  if (Dart_IsError(r) || s == NULL) {
    lg("[dart print] <unprintable>\n");
    return;
  }
  lg("[dart] %s\n", s);
}

// AOT cannot use Dart_SetNativeResolver -- that resolver runs inside
// gen_snapshot, and we use a stock one. Dart_SetFfiNativeResolver is a runtime
// call and is the supported path for @Native in AOT.
static void* vita_ffi_resolver(const char* name, uintptr_t args_n) {
  (void)args_n;
  if (name != NULL && strcmp(name, "vita_dart_print") == 0) {
    return (void*)vita_dart_print;
  }
  return NULL;
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
  //
  // --precompilation is not optional and nothing in the VM sets it for us --
  // every AOT embedder in the tree passes it explicitly (runtime/bin/
  // main_impl.cc:1313). It selects bare_instructions_frame_layout. Without it
  // the runtime keeps default_frame_layout, whose saved_caller_pp_from_fp names
  // a real slot, while AOT frames have no saved PP slot at all. The runtime
  // then reads a pool pointer out of a slot holding something else, gets null,
  // and faults in Object::HandleImpl on an ObjectPtr of 1 -- null | kHeapObjectTag.
  const char* vm_flags[] = {"--precompilation"};
  lg("  [checkpoint] Dart_SetVMFlags (--precompilation)\n");
  char* err = Dart_SetVMFlags(1, vm_flags);
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
  // Bracket point: the trace lines from thread.cc appear in dart.log before
  // this, so anything after it is the "post-snapshot, pre-invoke" window.
  lg("  --- snapshot read complete, entering invoke sequence ---\n");

  Dart_EnterScope();

  // The VM ships no microtask scheduler; the embedder installs one, and until
  // it does dart:async throws "Microtasks are not supported" on the first
  // await. runtime/bin does this in DartUtils::PrepareAsyncLibrary
  // (dartutils.cc:524) -- pure Dart API, no natives, so it ports unchanged.
  // Timers are a separate and much heavier hook: VMLibraryHooks.timerFactory
  // wants timer_impl.dart, which needs the dart:io event handler. Not done.
  lg("  [checkpoint] installing microtask scheduler\n");
  Dart_Handle isolate_lib =
      Dart_LookupLibrary(Dart_NewStringFromCString("dart:isolate"));
  Dart_Handle async_lib =
      Dart_LookupLibrary(Dart_NewStringFromCString("dart:async"));
  if (Dart_IsError(isolate_lib) || Dart_IsError(async_lib)) {
    lg("  FAIL looking up async libraries: %s\n",
       Dart_GetError(Dart_IsError(isolate_lib) ? isolate_lib : async_lib));
    wait_and_exit(1);
  }
  Dart_Handle sched_closure = Dart_Invoke(
      isolate_lib, Dart_NewStringFromCString("_getIsolateScheduleImmediateClosure"),
      0, NULL);
  if (Dart_IsError(sched_closure)) {
    lg("  FAIL _getIsolateScheduleImmediateClosure: %s\n",
       Dart_GetError(sched_closure));
    wait_and_exit(1);
  }
  Dart_Handle sched_args[1] = {sched_closure};
  Dart_Handle sched_set = Dart_Invoke(
      async_lib, Dart_NewStringFromCString("_setScheduleImmediateClosure"), 1,
      sched_args);
  if (Dart_IsError(sched_set)) {
    lg("  FAIL _setScheduleImmediateClosure: %s\n", Dart_GetError(sched_set));
    wait_and_exit(1);
  }
  lg("  microtask scheduler installed\n");

  lg("  [checkpoint] invoking main()\n");

  // One checkpoint per API call. The previous run faulted somewhere in this
  // sequence -- Object::HandleImpl on a garbage ObjectPtr -- and three calls
  // between two log lines is not enough to say which.
  lg("  [checkpoint] Dart_RootLibrary\n");
  Dart_Handle root = Dart_RootLibrary();
  if (Dart_IsError(root)) {
    lg("  FAIL Dart_RootLibrary: %s\n", Dart_GetError(root));
    wait_and_exit(1);
  }
  lg("  root library handle ok, null=%d\n", Dart_IsNull(root) ? 1 : 0);

  // print() throws until _printClosure is set. runtime/bin sets it from
  // dart:_builtin's _getPrintClosure (PrepareBuiltinLibrary, dartutils.cc:461);
  // dart:_builtin is dart:io scaffolding this port excludes, so the closure
  // comes from our own shim in the root library instead.
  lg("  [checkpoint] installing print closure\n");
  Dart_Handle ffi_res = Dart_SetFfiNativeResolver(root, vita_ffi_resolver);
  if (Dart_IsError(ffi_res)) {
    lg("  FAIL Dart_SetFfiNativeResolver: %s\n", Dart_GetError(ffi_res));
    wait_and_exit(1);
  }
  Dart_Handle print_closure =
      Dart_Invoke(root, Dart_NewStringFromCString("getPrintClosure"), 0, NULL);
  if (Dart_IsError(print_closure)) {
    lg("  FAIL getPrintClosure: %s\n", Dart_GetError(print_closure));
    wait_and_exit(1);
  }
  Dart_Handle internal_lib =
      Dart_LookupLibrary(Dart_NewStringFromCString("dart:_internal"));
  if (Dart_IsError(internal_lib)) {
    lg("  FAIL looking up dart:_internal: %s\n", Dart_GetError(internal_lib));
    wait_and_exit(1);
  }
  Dart_Handle print_set = Dart_SetField(
      internal_lib, Dart_NewStringFromCString("_printClosure"), print_closure);
  if (Dart_IsError(print_set)) {
    lg("  FAIL setting _printClosure: %s\n", Dart_GetError(print_set));
    wait_and_exit(1);
  }
  lg("  print closure installed\n");

  lg("  [checkpoint] Dart_NewStringFromCString\n");
  Dart_Handle name = Dart_NewStringFromCString("main");
  if (Dart_IsError(name)) {
    lg("  FAIL Dart_NewStringFromCString: %s\n", Dart_GetError(name));
    wait_and_exit(1);
  }
  lg("  name handle ok\n");

  lg("  [checkpoint] Dart_Invoke\n");
  Dart_Handle result = Dart_Invoke(root, name, 0, NULL);
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

  // Dart_RunLoop alone does not drain microtasks, which is why the first run
  // that got this far reported asyncMarker()==0. The VM drains the queue after
  // handling a *message*, and runtime/bin gets one for free: main_impl.cc:1095
  // does not invoke main directly, it calls _startMainIsolate, which schedules
  // main into the message queue. This harness invokes main directly so it can
  // read the return value, so no message turn ever happens.
  //
  // _runPendingImmediateCallback is the same entry point the VM itself uses
  // from DartLibraryCalls::DrainMicrotaskQueue, so calling it here is the
  // documented drain, not a workaround around one.
  lg("  [checkpoint] draining microtasks\n");
  Dart_Handle drain = Dart_Invoke(
      isolate_lib, Dart_NewStringFromCString("_runPendingImmediateCallback"), 0,
      NULL);
  if (Dart_IsError(drain)) {
    lg("  FAIL draining microtasks: %s\n", Dart_GetError(drain));
  }

  // Still worth running: it starts the message handler on the isolate group's
  // thread pool and waits on a Monitor, which is the os_thread_vita.cc condvar
  // path -- the part of the port most likely to be subtly wrong.
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
