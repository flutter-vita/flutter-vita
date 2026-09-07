// M1 — run Dart AOT on the PlayStation Vita.
//
// ADR-0005 Option A: the snapshot is assembled by gen_snapshot into snapshot.S
// and linked straight into eboot.bin, so the four images are ordinary symbols
// and the Vita's receiver places each section with the right protection.
//
// That is the whole reason this file no longer allocates a VM domain block.
// Option B loaded the snapshot at runtime and worked right up until Dart wrote
// to the BSS: Image::bss() puts it at a fixed offset *inside* the instructions
// image, and the VM domain is all-or-nothing -- Open is writable, Close is
// executable, never both. The crash dump named it exactly: BSS::Initialize, a
// strex, data abort. Linking sidesteps it, because .text lands read-execute and
// .bss read-write, as on every other platform.
//
// Success is a number as well as a message: hello.dart returns 6830, and it
// also prints, because this harness installs _printClosure from dart:vita --
// the SDK library holding the Dart-side shim, since runtime/bin's dart:_builtin
// is excluded from this port. The checksum stays: it is the more precise
// signal, and it survives anything going wrong with output.
//
// Every step logs a checkpoint and flushes before doing anything risky. Track A
// run 2 faulted mid-test and the log survived only by luck; here it is design.

#include <psp2/ctrl.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/power.h>
#include <psp2/kernel/threadmgr.h>

#include <stdarg.h>
#include <stdint.h>
typedef uintptr_t uword;
#include <stdio.h>
#include <pthread.h>
#include <string.h>

#include "dart_api.h"
#include "dart_native_api.h"  // Dart_CObject / Dart_PostCObject, for the timer
#include "debugScreen.h"
#include "devserver.h"

unsigned int _newlib_heap_size_user = 192 * 1024 * 1024;

// Vita's default main-thread stack is small, and Dart derives its stack limit
// from whatever GetCurrentStackBounds reports for the thread it runs on. The
// first GC-heavy test threw StackOverflowError from code that barely recurses,
// which points at the limit rather than at real recursion.
unsigned int sceUserMainThreadStackSize = 1 * 1024 * 1024;

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

// Backs dart:vita's @Native<Void Function(Handle)>(symbol: 'vita_dart_print').
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

// ---------------------------------------------------------------- timers ---
//
// dart:isolate already contains the timer scheduler; it is missing only two
// platform primitives. These are them. The contract, from timer_impl.dart:
//
//   timerMillisecondClock()                -> monotonic ms, any epoch
//   eventHandlerSendData(_, port, wakeup)  -> post null to `port` at `wakeup`,
//                                             or cancel when wakeup is -1
//
// The null message is _TIMEOUT_EVENT. Zero-duration timers never arrive here:
// dart:isolate posts _ZERO_EVENT to its own port without asking the platform.

#define VITA_NO_TIMER (-1)

// 32-bit deliberately. A 64-bit store is not atomic on ARMv7, and these are
// written by the Dart thread and read by the timer thread; 32-bit ms wraps
// after ~24 days of uptime, which no experiment run will reach. A real embedder
// should take a lock rather than rely on that.
static volatile int32_t g_wakeup_ms = 0;  // 0 = nothing scheduled
static volatile Dart_Port g_timer_port = ILLEGAL_PORT;
static volatile int g_timer_run = 1;

// The timer thread sleeps on this rather than polling, so an idle app costs
// nothing. Signalled whenever the schedule changes or on shutdown; the thread
// re-reads g_wakeup_ms each time it wakes.
static SceUID g_timer_ef = -1;
#define TIMER_EF_WAKE 1u

static int64_t vita_monotonic_ms(void) {
  return (int64_t)(sceKernelGetProcessTimeWide() / 1000ULL);
}

static void vita_schedule_wakeup(Dart_Handle send_port, int64_t wakeup_ms) {
  Dart_Port port_id = ILLEGAL_PORT;
  Dart_Handle r = Dart_SendPortGetId(send_port, &port_id);
  if (Dart_IsError(r)) {
    lg("  [timer] FAIL Dart_SendPortGetId: %s\n", Dart_GetError(r));
    return;
  }
  g_timer_port = port_id;
  g_wakeup_ms = (wakeup_ms == VITA_NO_TIMER) ? 0 : (int32_t)wakeup_ms;
  sceKernelSetEventFlag(g_timer_ef, TIMER_EF_WAKE);
}

// Waits rather than polls: with no timer scheduled it blocks indefinitely, and
// with one it blocks exactly until the wakeup. An earlier version polled at
// 1 ms, which worked but burned a wakeup every millisecond on a 444 MHz CPU.
static int vita_timer_thread(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  while (g_timer_run) {
    const int32_t target = g_wakeup_ms;
    SceUInt timeout_us = 0;
    SceUInt* timeout = NULL;  // NULL means wait forever

    if (target != 0) {
      // Signed subtraction, so this stays correct across the 32-bit wrap.
      const int32_t delta_ms = target - (int32_t)vita_monotonic_ms();
      if (delta_ms <= 0) {
        g_wakeup_ms = 0;
        Dart_CObject msg;
        msg.type = Dart_CObject_kNull;
        Dart_PostCObject(g_timer_port, &msg);  // _TIMEOUT_EVENT
        continue;
      }
      timeout_us = (SceUInt)delta_ms * 1000u;
      timeout = &timeout_us;
    }

    unsigned int out_bits = 0;
    // Either the deadline passes or someone reschedules; both just re-run the
    // loop, which re-reads the schedule. Spurious wakeups are harmless.
    sceKernelWaitEventFlag(g_timer_ef, TIMER_EF_WAKE,
                           SCE_EVENT_WAITOR | SCE_EVENT_WAITCLEAR, &out_bits,
                           timeout);
  }
  return 0;
}

// AOT cannot use Dart_SetNativeResolver -- that resolver runs inside
// gen_snapshot, and we use a stock one. Dart_SetFfiNativeResolver is a runtime
// call and is the supported path for @Native in AOT.
static void* vita_ffi_resolver(const char* name, uintptr_t args_n) {
  (void)args_n;
  if (name == NULL) return NULL;
  if (strcmp(name, "vita_dart_print") == 0) return (void*)vita_dart_print;
  if (strcmp(name, "vita_monotonic_ms") == 0) return (void*)vita_monotonic_ms;
  if (strcmp(name, "vita_schedule_wakeup") == 0) {
    return (void*)vita_schedule_wakeup;
  }
  return NULL;
}

// devserver takes a plain (const char*) sink rather than a printf-style one,
// so it cannot accidentally format attacker-controlled bytes from the socket.

// Screen power.
//
// scePowerRequestDisplayOff is NOT used here, and must not be reintroduced. It
// does turn the panel off, but nothing this app can do brings it back --
// scePowerRequestDisplayOn had no effect, and the only ways out were exiting
// the app or minimising it. On someone's only console that is an unacceptable
// way to lose the display.
//
// What protects the OLED instead is blanking: the panel stays powered, but the
// framebuffer is cleared to black, and a black pixel on an OLED draws
// essentially no current. Burn-in comes from static *text* sitting there for
// hours, and blanking removes exactly that. Recovery is guaranteed because we
// own the framebuffer -- any button redraws.
#define SCREEN_IDLE_US (60 * 1000 * 1000)

static volatile int g_blanked = 0;
static volatile int g_stay_awake = 0;
static volatile uint64_t g_last_activity = 0;

static void screen_activity(void) { g_last_activity = sceKernelGetProcessTimeWide(); }

static int power_tick_thread(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  SceCtrlData pad;
  unsigned int prev = 0;
  screen_activity();
  for (;;) {
    // Keep the console awake in both senses: no suspend (it would kill the
    // network and the deploy loop with it) and no system-driven display off
    // (whose wake path we do not control).
    sceKernelPowerTick(SCE_KERNEL_POWER_TICK_DEFAULT);

    if (sceCtrlPeekBufferPositive(0, &pad, 1) >= 0) {
      if (pad.buttons != 0 && pad.buttons != prev) {
        if ((pad.buttons & SCE_CTRL_SELECT) && !(prev & SCE_CTRL_SELECT)) {
          g_stay_awake = !g_stay_awake;
        }
        screen_activity();
      }
      prev = pad.buttons;
    }

    const uint64_t idle = sceKernelGetProcessTimeWide() - g_last_activity;
    const int want_blank = !g_stay_awake && idle >= SCREEN_IDLE_US;

    if (want_blank && !g_blanked) {
      psvDebugScreenPuts("\033[2J");  // black, but the panel stays on
      g_blanked = 1;
    } else if (!want_blank && g_blanked) {
      psvDebugScreenPuts("\033[2Jflutter-vita: awake. SELECT = stay awake.\n");
      g_blanked = 0;
    }
    sceKernelDelayThread(200 * 1000);
  }
  return 0;
}

static void start_power_tick(void) {
  const SceUID t = sceKernelCreateThread("fvita_powertick", power_tick_thread,
                                         0x10000100, 0x1000, 0, 0, NULL);
  if (t >= 0) sceKernelStartThread(t, 0, NULL);
}

// Proof that thread_local is genuinely per-thread. Before the emutls
// replacement this printed 222 and 333 -- a worker's writes visible on main.
static __thread int g_tls_probe = 0;

static void* tls_pthread_worker(void* arg) {
  (void)arg;
  g_tls_probe = 222;
  return NULL;
}

static int tls_vita_worker(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  g_tls_probe = 333;
  return 0;
}

static void tls_probe_test(void) {
  g_tls_probe = 111;
  pthread_t th;
  if (pthread_create(&th, NULL, tls_pthread_worker, NULL) == 0) {
    pthread_join(th, NULL);
  }
  const int after_pthread = g_tls_probe;
  const SceUID vt = sceKernelCreateThread("tls_probe", tls_vita_worker,
                                          0x10000100, 0x1000, 0, 0, NULL);
  if (vt >= 0) {
    sceKernelStartThread(vt, 0, NULL);
    sceKernelWaitThreadEnd(vt, NULL, NULL);
  }
  const int after_vita = g_tls_probe;
  lg("thread_local probe (main set 111):\n");
  lg("  pthread worker set 222 -> main reads %d  %s\n", after_pthread,
     after_pthread == 111 ? "PER-THREAD OK" : "SHARED GLOBAL -- BROKEN");
  lg("  vita thread set 333    -> main reads %d  %s\n", after_vita,
     after_vita == 111 ? "PER-THREAD OK" : "SHARED GLOBAL -- BROKEN");
}

// Isolate.spawn needs the embedder to say how a new isolate comes into being.
// Without these, Dart_Initialize has no way to build one and spawn is refused
// outright -- isoMarker came back -1 for exactly that reason.
//
// Two callbacks, for two different cases:
//   create_group        a whole new isolate group (Isolate.spawnUri)
//   initialize_isolate  a new isolate inside the existing group, which is what
//                       Isolate.spawn does
//
// Deliberately minimal for now. The child isolate gets no print closure, no
// microtask scheduler and no timer hooks -- those are per-isolate state and
// would each need installing here. The test only sends an integer back down a
// port, so if it needs more we will see a specific error rather than a guess.
static Dart_Isolate vita_create_group(const char* script_uri,
                                      const char* main_name,
                                      const char* package_root,
                                      const char* package_config,
                                      Dart_IsolateFlags* flags,
                                      void* isolate_data,
                                      char** error) {
  (void)package_root;
  (void)package_config;
  (void)isolate_data;
  lg("  [isolate] create_group for %s\n", script_uri ? script_uri : "(null)");
  return Dart_CreateIsolateGroup(script_uri, main_name,
                                 _kDartIsolateSnapshotData,
                                 _kDartIsolateSnapshotInstructions, flags, NULL,
                                 NULL, error);
}

static bool vita_initialize_isolate(void** child_isolate_data, char** error) {
  (void)child_isolate_data;
  (void)error;
  lg("  [isolate] initialize_isolate\n");
  return true;
}

static void lg_line(const char* msg) {
  lg("%s", msg);
}

static void wait_and_exit(int code) {
  // Hand off to the on-device dev server rather than idling. It closes the
  // build loop without taiHEN: upload a new eboot.bin and relaunch over the
  // network, no button presses and no BGFTP. If it cannot start -- no network,
  // usually -- fall through to the original wait-for-START behaviour, since
  // without a network there is no other way out.
  lg("\n== dev server ==\n");
  if (g_log >= 0) sceIoClose(g_log);  // release the log so `log` can read it
  g_log = -1;

  if (dev_server_run(lg_line, "ux0:data/flutter-vita/m1.log",
                     "ux0:app/FVTA00002/eboot.bin") == 0) {
    sceKernelExitProcess(code);
    for (;;) {
      sceKernelDelayThread(1000 * 1000);
    }
  }

  psvDebugScreenPuts("\ndev server unavailable. press START to exit.\n");
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
  start_power_tick();
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  // SCE_O_TRUNC does not truncate on Vita3K; a stale tail is worse than no log.
  sceIoRemove("ux0:data/flutter-vita/m1.log");
  g_log = sceIoOpen("ux0:data/flutter-vita/m1.log",
                    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);

  {
    // Report what Dart will see, since that is what sets the stack limit.
    SceKernelThreadInfo ti;
    memset(&ti, 0, sizeof ti);
    ti.size = sizeof ti;
    if (sceKernelGetThreadInfo(sceKernelGetThreadId(), &ti) == 0) {
      // Is ti.stack the low end or the high end? A local lives near the current
      // stack pointer, so comparing decides it -- and the answer determines
      // whether OSThread::GetCurrentStackBounds has been inverted all along.
      int probe = 0;
      const uword sp = (uword)&probe;
      const uword base = (uword)ti.stack;
      lg("main thread stack: ti.stack=%p size=%d KiB  &local=%p\n", ti.stack,
         (int)(ti.stackSize / 1024), (void*)sp);
      lg("  -> ti.stack is the %s (local is %s it)\n",
         (sp < base) ? "TOP  [bounds are INVERTED]" : "base [bounds are fine]",
         (sp < base) ? "below" : "above");
    } else {
      lg("main thread stack: sceKernelGetThreadInfo failed\n");
    }
  }
  tls_probe_test();
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
  params.create_group = vita_create_group;
  params.initialize_isolate = vita_initialize_isolate;

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

  // Not the no-op it looks like in AOT. The class-finalisation half is --
  // ClassFinalizer::ProcessPendingClasses just asserts and returns true under
  // DART_PRECOMPILED_RUNTIME. But Dart_FinalizeLoading also calls
  // heap()->old_space()->EvaluateAfterLoading(), which recomputes the old-space
  // growth threshold from real post-load usage (pages.cc:1743). Skip it and the
  // GC keeps its pre-load growth policy for the life of the process.
  lg("  [checkpoint] Dart_FinalizeLoading\n");
  Dart_Handle finalized = Dart_FinalizeLoading(false);
  if (Dart_IsError(finalized)) {
    lg("  FAIL Dart_FinalizeLoading: %s\n", Dart_GetError(finalized));
    wait_and_exit(1);
  }

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
  // comes from dart:vita, our own SDK library. Naming it outright is the point:
  // the shim used to live in the app's root library, which tied the embedder to
  // wherever the app's source happened to sit on the build machine.
  lg("  [checkpoint] looking up dart:vita\n");
  Dart_Handle vita_lib =
      Dart_LookupLibrary(Dart_NewStringFromCString("dart:vita"));
  if (Dart_IsError(vita_lib)) {
    lg("  FAIL looking up dart:vita: %s\n", Dart_GetError(vita_lib));
    wait_and_exit(1);
  }

  lg("  [checkpoint] installing print closure\n");
  Dart_Handle ffi_res = Dart_SetFfiNativeResolver(vita_lib, vita_ffi_resolver);
  if (Dart_IsError(ffi_res)) {
    lg("  FAIL Dart_SetFfiNativeResolver: %s\n", Dart_GetError(ffi_res));
    wait_and_exit(1);
  }
  Dart_Handle print_closure =
      Dart_Invoke(vita_lib, Dart_NewStringFromCString("getPrintClosure"), 0, NULL);
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

  // Timers. Three hooks, none of which implement a timer -- the scheduler is
  // already in dart:isolate. See docs/embedder-startup.md.
  lg("  [checkpoint] installing timer hooks\n");

  // 1. timerFactory, set by dart:isolate's own _setupHooks. This is the call
  //    PrepareIsolateLibrary makes (dartutils.cc:533).
  Dart_Handle iso_hooks =
      Dart_Invoke(isolate_lib, Dart_NewStringFromCString("_setupHooks"), 0, NULL);
  if (Dart_IsError(iso_hooks)) {
    lg("  FAIL dart:isolate _setupHooks: %s\n", Dart_GetError(iso_hooks));
    wait_and_exit(1);
  }

  // 2 and 3. The platform primitives, as static fields on VMLibraryHooks.
  //    Dart_SetField on a type handle reaches statics and ignores the
  //    leading-underscore visibility rules.
  Dart_Handle hooks_cls =
      Dart_GetClass(internal_lib, Dart_NewStringFromCString("VMLibraryHooks"));
  if (Dart_IsError(hooks_cls)) {
    lg("  FAIL locating VMLibraryHooks: %s\n", Dart_GetError(hooks_cls));
    wait_and_exit(1);
  }
  Dart_Handle clock =
      Dart_Invoke(vita_lib, Dart_NewStringFromCString("getTimerClock"), 0, NULL);
  Dart_Handle send_data = Dart_Invoke(
      vita_lib, Dart_NewStringFromCString("getEventHandlerSendData"), 0, NULL);
  if (Dart_IsError(clock) || Dart_IsError(send_data)) {
    lg("  FAIL building timer closures: %s\n",
       Dart_GetError(Dart_IsError(clock) ? clock : send_data));
    wait_and_exit(1);
  }
  Dart_Handle r1 = Dart_SetField(
      hooks_cls, Dart_NewStringFromCString("timerMillisecondClock"), clock);
  Dart_Handle r2 = Dart_SetField(
      hooks_cls, Dart_NewStringFromCString("eventHandlerSendData"), send_data);
  if (Dart_IsError(r1) || Dart_IsError(r2)) {
    lg("  FAIL setting timer hooks: %s\n",
       Dart_GetError(Dart_IsError(r1) ? r1 : r2));
    wait_and_exit(1);
  }

  g_timer_ef = sceKernelCreateEventFlag("vita_timer_ef", 0, 0, NULL);
  if (g_timer_ef < 0) {
    lg("  FAIL creating timer event flag: 0x%08X\n", (unsigned)g_timer_ef);
    wait_and_exit(1);
  }
  SceUID timer_thread = sceKernelCreateThread(
      "vita_timer", vita_timer_thread, 0x10000100, 0x4000, 0, 0, NULL);
  if (timer_thread < 0) {
    lg("  FAIL creating timer thread: 0x%08X\n", (unsigned)timer_thread);
    wait_and_exit(1);
  }
  sceKernelStartThread(timer_thread, 0, NULL);
  lg("  timer hooks installed, timer thread started\n");

  // Isolate.spawn refuses in Dart when VMLibraryHooks.platformScript is null,
  // long before any embedder callback runs -- runtime/bin fills it from
  // dart:io's Platform._nativeScript, which this port excludes. dart:vita sets
  // it directly, since an SDK library may import dart:_internal.
  lg("  [checkpoint] installing platformScript\n");
  Dart_Handle ps = Dart_Invoke(
      vita_lib, Dart_NewStringFromCString("installPlatformScript"), 0, NULL);
  if (Dart_IsError(ps)) {
    lg("  FAIL installPlatformScript: %s\n", Dart_GetError(ps));
  } else {
    lg("  platformScript installed\n");
  }

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
  // Phase 1 exit criteria, never previously run. Both are cheap and both are
  // far cheaper to debug here than under a Flutter heap.
  // gcStress is DISABLED. It allocates ~8 MB in a tight loop and takes the
  // process down with a data abort in DRT_AllocateArray -- which is the bug
  // being investigated, not a test failure. Re-enable once
  // OSThread::GetCurrentStackBounds is fixed; leaving it on just crashes the
  // app that hosts the dev server, which costs a manual relaunch every cycle.
// gcStress DISABLED. It has already told us what it can: a data abort in
// DRT_AllocateArray with a null Thread*, from Thread::Current() returning null.
// Leaving it on only crashes the app that hosts the dev server, costing a
// manual relaunch per cycle. Re-enable after the TLS fix, as the regression
// test for it.
  lg("  [checkpoint] gcStress\n");
  Dart_Handle gc = Dart_Invoke(root, Dart_NewStringFromCString("gcStress"), 0, NULL);
  int64_t gc_value = -1;
  if (Dart_IsError(gc)) {
    lg("  FAIL gcStress: %s\n", Dart_GetError(gc));
  } else if (!Dart_IsError(Dart_IntegerToInt64(gc, &gc_value))) {
    lg("  gcStress() = %lld (expected 1999000) %s\n", (long long)gc_value,
       gc_value == 1999000 ? "PASS -- GC survived ~8 MB of churn" : "FAIL");
  }



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

  Dart_Handle iso_marker =
      Dart_Invoke(root, Dart_NewStringFromCString("isoMarker"), 0, NULL);
  int64_t iso_value = 0;
  if (!Dart_IsError(iso_marker) &&
      !Dart_IsError(Dart_IntegerToInt64(iso_marker, &iso_value))) {
    lg("  isoMarker() = %lld  %s\n", (long long)iso_value,
       iso_value == 7777  ? "PASS -- second isolate ran"
       : iso_value == -1  ? "spawn threw -- see the printed error above"
       : iso_value == -2  ? "spawn silent -- nothing came back in 3s"
                          : "not run");
  }

  // Only becomes 42 if the whole round trip worked: timerFactory -> _Timer ->
  // eventHandlerSendData -> the timer thread -> Dart_PostCObject -> the message
  // loop. If Dart_RunLoop above hung instead, this line never printed and the
  // log ends at the RunLoop checkpoint -- which is itself the diagnosis.
  Dart_Handle delayed =
      Dart_Invoke(root, Dart_NewStringFromCString("delayedMarker"), 0, NULL);
  int64_t delayed_value = -1;
  if (!Dart_IsError(delayed) &&
      !Dart_IsError(Dart_IntegerToInt64(delayed, &delayed_value))) {
    lg("  delayedMarker() = %lld (expected 42) %s\n", (long long)delayed_value,
       delayed_value == 42 ? "PASS -- real timer fired" : "FAIL");
  } else {
    lg("  FAIL reading delayedMarker\n");
  }

  // Signal as well as clear the flag: the thread is blocked in
  // sceKernelWaitEventFlag and would otherwise sit there until its next
  // deadline, or forever if none is scheduled.
  g_timer_run = 0;
  sceKernelSetEventFlag(g_timer_ef, TIMER_EF_WAKE);

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
