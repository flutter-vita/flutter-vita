# The embedder startup path

Written 2026-08-08, after M1 passed. Every failure between "isolate created" and
"M1 PASS" was a step `runtime/bin` performs that the M1 harness did not — three
of them, found one deploy cycle at a time. This document is the result of
reading that path end to end instead, so Phase 2 does not repeat it.

The reference is `DartUtils::SetupCoreLibraries`
([dartutils.cc:571](../third_party/sdk/runtime/bin/dartutils.cc)) plus
`main_impl.cc`. Note that `runtime/bin` is a *`dart:io`* embedder — much of what
it does exists to support `dart:io`, and Flutter does not want it. The value is
in knowing which steps are `dart:io` scaffolding and which are load-bearing for
any embedder.

## What runtime/bin does, and what M1 does

| Step | Reference | M1 | Notes |
|---|---|---|---|
| `--precompilation` VM flag | `main_impl.cc:1313` | **done** | Not optional. Selects `bare_instructions_frame_layout`; see below. |
| `Dart_Initialize` + isolate group | `main_impl.cc` | done | |
| Native resolvers for `dart:_builtin`, `dart:cli` | `Builtin::TrySetNativeResolver` | skipped | `dart:io` scaffolding. Not needed. |
| `SetupDartIoLibrary` | `dartutils.cc` | skipped | `dart:io`. Not needed. |
| `Dart_FinalizeLoading(false)` | `dartutils.cc` | skipped | Kernel-loading concern; AOT snapshots arrive finalised. Harmless so far — **verify** before assuming. |
| `_printClosure` ← `dart:_builtin _getPrintClosure` | `PrepareBuiltinLibrary` | **done** | Sourced from our own shim rather than `dart:_builtin`. |
| `_setScheduleImmediateClosure` ← `dart:isolate` | `PrepareAsyncLibrary` | **done** | Pure Dart API. Without it: *"Microtasks are not supported"*. |
| `Uri.base` ← `dart:io _getUriBaseClosure` | `PrepareCoreLibrary` | skipped | `dart:io`. Not needed. |
| `dart:isolate _setupHooks` | `PrepareIsolateLibrary` | **done** | The timer hook. Verified on hardware. |
| `dart:cli _setupHooks` | `PrepareCLILibrary` | skipped | Returns null; a no-op even upstream. |
| Run `main` via `_startMainIsolate` | `main_impl.cc:1095` | deliberately not | Schedules `main` into the message queue. M1 invokes `main` directly to read its return value, and so must drain microtasks by hand. |

## Why `--precompilation` is load-bearing

Nothing in the VM sets `FLAG_precompiled_mode`; every AOT embedder passes it
explicitly. Without it the runtime keeps `default_frame_layout`, whose
`saved_caller_pp_from_fp` names a real slot — but bare-instruction AOT frames
have **no saved PP slot**
([stack_frame.cc:66](../third_party/sdk/runtime/vm/stack_frame.cc)). Any stack
walk then reads a pool pointer out of a slot holding something else, gets zero,
and hands `nullptr | kHeapObjectTag` to `ObjectPool::Handle`. It presents as a
data abort deep inside `Object::HandleImpl`, which is nowhere near the cause.

## Timers: smaller than it looked — and now working

HANDOFF previously said timers "mean `timer_impl.dart`, which wants the
`dart:io` event handler — a genuine piece of work". That overstated it.
`timer_impl.dart` is `part "timer_impl.dart"` of
[isolate_patch.dart:14](../third_party/sdk/sdk/lib/_internal/vm/lib/isolate_patch.dart)
— it is **already part of `dart:isolate`, already in our snapshot**. The timer
heap, the receive port, the wakeup bookkeeping and the callback dispatch all
exist and are compiled in.

What is missing is three hook installations, of very different cost:

1. **`VMLibraryHooks.timerFactory`** — set by `dart:isolate`'s own `_setupHooks`
   ([timer_impl.dart:514](../third_party/sdk/sdk/lib/_internal/vm/lib/timer_impl.dart)).
   One `Dart_Invoke(isolate_lib, "_setupHooks")`. Essentially free.

2. **`VMLibraryHooks.timerMillisecondClock`** — a nullary closure returning a
   monotonic clock in milliseconds. Trivial logic.

3. **`VMLibraryHooks.eventHandlerSendData(Object?, SendPort, int wakeupTime)`** —
   the real work. `_Timer._scheduleWakeup` calls it to ask the platform to wake
   the isolate at `wakeupTime` (or `_NO_TIMER` to cancel). On Vita that is a
   thread that sleeps and then `Dart_PostCObject`s to the port — which is
   thread-safe, and lands as a message, which is exactly what makes
   `Dart_RunLoop` drain microtasks afterwards.

Both 2 and 3 are declared `late` and non-nullable
([internal_patch.dart:90](../third_party/sdk/sdk/lib/_internal/vm/lib/internal_patch.dart)),
so touching them before they are set throws `LateInitializationError` rather
than dereferencing null — a clear error, not a crash.

**The catch:** 2 and 3 must be *Dart closures*, and an embedder cannot
synthesize a closure from C. `runtime/bin` gets them from `dart:io`'s
`_EventHandler`. Rather than pull in `dart:io`, the shape that fits this port is
a small Dart shim compiled into the snapshot with `@pragma('vm:entry-point')`,
which the embedder invokes once at startup and which calls out to C.

All three are installed and verified on hardware: a 50 ms `Future.delayed`
fires and its callback runs. Not `Duration.zero` — `dart:isolate` short-circuits
zero-duration timers by posting `_ZERO_EVENT` to its own port, so they never
reach the platform hook and would prove nothing.

The C side is a 1 ms polling thread. Crude but obviously correct, and easy to
replace with an event-flag wait once frame pacing matters.

## Print, while we are here

`print()` throws until `_printClosure` is set in `dart:_internal`;
`PrepareBuiltinLibrary` sets it from `dart:_builtin`, which is `dart:io`
scaffolding we exclude. The same Dart shim that carries the timer closures can
carry a print closure routed to the debug screen and `m1.log`. **Done**, via an
FFI native — `@Native<Void Function(Handle)>`, resolved at runtime with
`Dart_SetFfiNativeResolver` because `Dart_SetNativeResolver` runs inside
gen_snapshot and we use a stock one. Passing a `Handle` avoids malloc and manual
UTF-8 work; the SDK uses the same shape in `concurrent_patch.dart`.

That FFI channel matters beyond print: it is how `dart:ui` reaches its embedder,
so Phase 2 now has a proven Dart-to-C path rather than an assumed one.

## The lesson

The port was essentially correct long before M1 passed. Three consecutive
failures were embedder omissions, and each was hunted inside the Dart runtime
first. Phase 2 has a far larger embedder surface than M1 did, so the default
assumption on any new failure should be *"what does the reference embedder do
here that we don't?"* before *"what did we get wrong in the port?"*

## Addendum: reaching `VMLibraryHooks` from C

Installing the two timer primitives means writing static fields on
`VMLibraryHooks` in `dart:_internal`. `Dart_SetField` does reach statics when
handed a type handle, and it ignores leading-underscore visibility — but getting
the type handle fails in product AOT:

```
FAIL locating VMLibraryHooks: Class 'VMLibraryHooks' not found in library 'dart._internal'.
```

The precompiler drops library dictionary entries for classes nothing marks as an
entry point, and nothing does: `dart:io`'s `_setupHooks` is the only thing in the
SDK that writes these fields, and it reaches them as ordinary Dart code from
inside the SDK. An embedder without `dart:io` has no route in.

The fix is patch 0007 — `@pragma("vm:entry-point")` on the class and on the
three fields. **This is a platform-dill change, not a runtime change**, so it
only takes effect if the kernel is compiled against a platform dill built from
this tree:

```bash
python3 tools/generate_package_config.py          # gclient sync does not create this
ninja -C third_party/sdk/out/host vm_platform_product.dill
```

`spikes/b1-aot-snapshot/build.sh` now points `--platform` at that file instead of
FVM's copy. That is worth doing on its own merits: the runtime is built from
`third_party/sdk`, so the SDK sources compiled into the snapshot should come
from there too, rather than from a separate checkout that merely happens to be
the same revision.
