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
| `Dart_FinalizeLoading(false)` | `dartutils.cc` | **done** | **Not optional in AOT**, despite the name. See below. |
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

## `Dart_FinalizeLoading` is not a loading-only concern

This was listed here as an AOT no-op worth verifying, and verifying it showed
the note was wrong. The class-finalisation half genuinely is a no-op --
`ClassFinalizer::ProcessPendingClasses` asserts and returns true under
`DART_PRECOMPILED_RUNTIME`
([class_finalizer.cc:43](../third_party/sdk/runtime/vm/class_finalizer.cc)).

But the same function also calls
`heap()->old_space()->EvaluateAfterLoading()`, which recomputes the old-space
growth threshold from actual post-load heap usage
([pages.cc:1743](../third_party/sdk/runtime/vm/heap/pages.cc)). Skip it and the
GC keeps its pre-load growth policy for the life of the process. Invisible in a
smoke test; not something to carry into an engine with a real heap on a 188 MiB
budget.

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
`_EventHandler`. Rather than pull in `dart:io`, this port has its own SDK
library — see below.

All three are installed and verified on hardware: a 50 ms `Future.delayed`
fires and its callback runs. Not `Duration.zero` — `dart:isolate` short-circuits
zero-duration timers by posting `_ZERO_EVENT` to its own port, so they never
reach the platform hook and would prove nothing.

The C side sleeps on a Vita event flag: it blocks indefinitely with nothing
scheduled, blocks exactly to the deadline with something scheduled, and is
signalled on every reschedule and on shutdown. The deadline delta is computed
with signed subtraction so it survives the 32-bit millisecond wrap. (It began as
a 1 ms polling loop, which worked but burned a wakeup every millisecond.)

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

## `platformScript`, and the shape of all of these

`Isolate.spawn` threw `Unsupported operation: Isolate.spawn`, and the throw is in
Dart, not the embedder:

```dart
var script = VMLibraryHooks.platformScript;
if (script == null) throw UnsupportedError("Isolate.spawn");
```

`runtime/bin` fills that from `dart:io`'s `Platform._nativeScript`. This port has
no `dart:io`, so it was never set. `dart:vita` now assigns it directly — being a
real SDK library, it may import `dart:_internal`, which is far simpler than
reaching `VMLibraryHooks` through `Dart_SetField` from C.

Spawning **also** needs `Dart_InitializeParams.initialize_isolate` (and
`create_group` for `spawnUri`). Both are required: the callback alone is never
reached, because Dart refuses first; the hook alone leaves the VM with no way to
build an isolate.

**That is now four hooks of identical shape:**

| Hook | Symptom when unset |
|---|---|
| `_printClosure` | `print()` throws |
| `_setScheduleImmediateClosure` | "Microtasks are not supported" |
| `timerFactory` and friends | "Timer interface not supported" |
| `platformScript` | "Unsupported operation: Isolate.spawn" |

Each is something `runtime/bin` supplies from `dart:io` or `dart:_builtin`, and
each presents as a mysterious runtime failure rather than "you did not install
X". **When Dart says "unsupported", ask which hook is null before suspecting the
port.** Worth auditing every `VMLibraryHooks` field before Phase 2 — `dart:ui`
will lean on more of them.

## VMLibraryHooks audit

Done before Phase 2, since `dart:ui` will lean on more of these. All eight
fields:

| Field | State | If unset |
|---|---|---|
| `timerFactory` | set — `dart:isolate`'s `_setupHooks` | timers throw |
| `eventHandlerSendData` | set — `dart:vita` | timers throw |
| `timerMillisecondClock` | set — `dart:vita` | timers throw |
| `platformScript` | set — `dart:vita` | `Isolate.spawn` throws |
| `packageConfigString` | **unset** | harmless — `spawn` reads it and tolerates null |
| `packageRootString` | **unset** | harmless — nothing in `sdk/lib` reads it |
| `packageConfigUriSync` | **unset** | `Isolate.packageConfig` throws `UnsupportedError` |
| `resolvePackageUriSync` | **unset** | `Isolate.resolvePackageUriSync` throws `UnsupportedError` |

The four unset ones are all package resolution, and they are **not silent**:
each throws an `UnsupportedError` naming itself, and only if application code
calls those APIs directly. In AOT the package URIs are resolved at compile time
and baked into the snapshot, so Flutter has no reason to reach for them.

Left unset deliberately. Implementing them would mean inventing a package
config for a snapshot that has none, and the failure mode if that assumption is
ever wrong is a clearly named exception rather than a crash.

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

`experiments/b1-aot-snapshot/build.sh` now points `--platform` at that file instead of
FVM's copy. That is worth doing on its own merits: the runtime is built from
`third_party/sdk`, so the SDK sources compiled into the snapshot should come
from there too, rather than from a separate checkout that merely happens to be
the same revision.


## `dart:vita`, the Dart-side shim

Several hooks are Dart closures and C cannot synthesize one. `runtime/bin` gets
its closures from `dart:_builtin` and `dart:io`; Flutter gets its from
`dart:ui`. This port has `dart:vita` (patch 0008), holding the print closure and
the two timer primitives, reached by the embedder with
`Dart_LookupLibrary("dart:vita")`.

It began life in the application's root library, which worked but tied the
embedder to wherever the app source sat on the build machine — the snapshot
bakes absolute host paths into application libraries. A real SDK library has a
stable name.

**Adding an SDK library takes three edits, and the third fails silently:**

1. the library itself, `sdk/lib/vita/vita.dart`
2. `sdk/lib/libraries.json` — declares it
3. `pkg/vm/lib/modular/target/vm.dart`, `extraRequiredLibraries` — declares that
   the VM platform requires it

With only 1 and 2, `compile_platform` emits a **byte-identical dill**, no error
and no warning, and the library simply does not exist. The only signal is the
unchanged output size. Worth remembering when `dart:ui` gets added in Phase 2 —
it is the same operation.

Two things this confirmed that Phase 2 depends on:

- **AOT retains a custom SDK library by name.** `Dart_LookupLibrary("dart:vita")`
  resolves in a product AOT snapshot. Its entry points carry
  `@pragma('vm:entry-point')`; the library itself needed no extra marking.
- **`Dart_SetFfiNativeResolver` works in AOT**, which is how `dart:ui` reaches
  its embedder too.
