# Handoff — state of play

Written 2026-08-07, updated 2026-08-08 when M1 passed. Everything needed to
pick this up cold. Read [docs/README.md](README.md) for the project shape;
this file is specifically *where we stopped and why*.

---

> **The status below is from 2026-08-08 and is superseded.** It predates the
> engine port, the GPU backend and the receiver becoming a Flutter app. Flutter
> runs on hardware now; see "Where the project stands" in
> [README.md](README.md). Two details in *The machine* are also stale: the
> console is reached as `fluttervita.local` rather than by address, and BGFTP
> was deliberately removed from the loop. The build pipeline and the gotchas
> below still hold.

## One-paragraph summary

**Milestone M1 is met.** Pure-Dart AOT runs on real hardware: the Dart runtime
compiles and links for `arm-vita-eabi`, a vita-targeting `gen_snapshot` exists,
and a `.vpk` on a PSVita-1000 initialises the VM, creates an isolate, executes
compiled Dart, returns a value to C, and drains the microtask queue. No Flutter
yet. Phase 0.5 (feasibility) is complete and the verdict was go.

## The machine

| | |
|---|---|
| VitaSDK | `~/vitasdk` (GCC 15.2.0, `arm-vita-eabi`) — no sudo, installed via vdpm |
| depot_tools | `~/depot_tools` — provides `gclient`; `gn`/`ninja` come from the Dart checkout |
| Dart SDK | `third_party/sdk` — **gclient-owned**, pinned `d684a576`, ~7.8 GB, gitignored |
| Flutter | 3.44.8, downloaded by `tools/flutter-sdk.sh` to `~/.flutter-vita/flutter/3.44.8` |
| Vita | `192.168.0.40`, FTP on 1337 — always on, served by **BGFTP** |
| Title ID | `FVTA00002` (M1), `FVTA00001` (Track A probe) |

**Never `rsync` into `third_party/sdk`.** gclient records DEPS sub-repos with
gitlinks that a file copy corrupts; the failures surface later as
*"not a git repository"* on a different directory each sync. The tree is
disposable — [`patches/dart-sdk/`](https://github.com/flutter-vita/dart-sdk/commits/vita-3.44.8) is the real
artifact and restores the whole port with one `git apply`. That has been proven
twice, once after a careless `reset --hard` destroyed the working tree.

## Build pipeline, in order

```bash
# 1. Dart runtime for Vita (494 objects, ~3 MiB stripped)
ninja -C third_party/sdk/out/vita obj/runtime/libdart_aotruntime_product.a

# 2. Host gen_snapshot that targets Vita
ninja -C third_party/sdk/out/host gen_snapshot_product_vita_arm

# 3. Platform dill from THIS tree, so patches 0007 and 0008 are in it (the
#    VMLibraryHooks pragmas and dart:vita). One-time setup:
#      python3 third_party/sdk/tools/generate_package_config.py
ninja -C third_party/sdk/out/host vm_platform_product.dill

# 4. hello.dart -> kernel (build.sh points --platform at the dill from step 3)
./experiments/b1-aot-snapshot/build.sh

# 5. kernel -> snapshot.S  (app-aot-assembly; ADR-0005 option A)
third_party/sdk/out/host/gen_snapshot_product_vita_arm \
  --snapshot_kind=app-aot-assembly \
  --assembly=experiments/m1-snapshot/out/snapshot.S \
  experiments/b1-aot-snapshot/out/hello.dill

# 6. link everything into a vpk
./experiments/m1-vpk/build.sh
```

**Steps 1 and 2 must be rebuilt together.** Dart hashes its VM sources into the
snapshot version; patching a file shared by the runtime and the precompiler and
rebuilding only one produces *"Wrong full snapshot version"* at startup.

### gn args used

```
target_os="vita" target_cpu="arm" is_debug=false is_release=false
is_product=true dart_runtime_mode="release"
```

`dart_runtime_mode="release"` matters beyond product mode: it disables perfetto
and the timeline, which otherwise fail to build for an unknown OS.

## Deploying

The app is already installed, so **do not reinstall the vpk** — overwrite in
place:

```bash
unzip -o -q build/flutter_vita_m1.vpk eboot.bin -d out/staging
curl -T out/staging/eboot.bin "ftp://192.168.0.40:1337/ux0:/app/FVTA00002/eboot.bin"
```

Then launch **Flutter Vita M1** from the LiveArea. Logs:

```
ux0:data/flutter-vita/m1.log     harness checkpoints
ux0:data/flutter-vita/dart.log   VitaTrace + Dart's Syslog
```

[`experiments/m1-vpk/deploy.sh`](../experiments/m1-vpk/deploy.sh) scripts this with
`USE_COMPANION=0`.

**Do not suggest taiHEN plugins.** vitacompanion destabilised the device (it
loads into SceShell) and others would not load at all. BGFTP is installed and
working; that is the whole deployment story. Launching is manual, from the
LiveArea, and that is fine.

## M1 is met

Verified on hardware 2026-08-08, and re-verified after the debug scaffolding was
removed — same result from a build carrying no instrumentation:

```
[checkpoint] Dart_SetVMFlags (--precompilation)
Dart_Initialize ok
isolate created
microtask scheduler installed
[checkpoint] Dart_Invoke

  main() returned 6830 (expected 6830) PASS
  [checkpoint] draining microtasks
  [checkpoint] Dart_RunLoop
  asyncMarker() = 99 (expected 99) PASS -- microtasks drained
  Dart_Cleanup: ok
```

6830 means `fib(20)` recursed ~13k calls, a list and a map allocated and grew,
strings hashed, and the value returned through `Dart_IntegerToInt64`. Generated
ARM code, the GC, the handle machinery and the microtask queue all work on the
device.

The threading substrate is exercised too, not merely compiled. `dart.log` from
the clean run ends with

```
[vita] pthread_create 'DartWorker' stack=524288
[vita]   -> 0
```

so `Dart_RunLoop` really did start the message handler on the isolate group's
thread pool, and `Dart_Cleanup` returned ok afterwards, meaning the worker
joined. That is the `os_thread_vita.cc` condvar and thread-creation path
running end to end — the piece the ADR index still lists as never grilled.

### What was wrong: three embedder gaps, none of them the port

Every remaining failure was something `runtime/bin` does that this harness did
not. None required a change to the Dart runtime.

**1. `--precompilation` was never passed.** This was the data abort. Nothing in
the VM sets `FLAG_precompiled_mode`; every AOT embedder in the tree passes the
flag explicitly (`runtime/bin/main_impl.cc:1313`, `gen_snapshot.cc:890`,
`dartdev.cc:1078`). Without it the runtime keeps `default_frame_layout`, whose
`saved_caller_pp_from_fp` names a real slot — but bare-instruction AOT frames
have **no saved PP slot** (`stack_frame.cc:66`). Walking the stack therefore
read a pool pointer out of a slot holding something else, got zero, and passed
`nullptr | kHeapObjectTag` to `ObjectPool::Handle`.

**2. No microtask scheduler.** `DartUtils::PrepareAsyncLibrary`
(`dartutils.cc:524`) hands `dart:isolate`'s
`_getIsolateScheduleImmediateClosure` to `dart:async`'s
`_setScheduleImmediateClosure`. Pure Dart API, no natives, ports unchanged.
Without it `dart:async` throws *"Microtasks are not supported"*.

**3. `Dart_RunLoop` does not drain microtasks.** The VM drains after handling a
*message*, and `runtime/bin` gets one for free: `main_impl.cc:1095` does not
invoke `main` directly, it calls `_startMainIsolate`, which schedules `main`
into the message queue. This harness invokes `main` directly so it can read the
return value, so no message turn ever happens. It now calls
`_runPendingImmediateCallback` — the same entry point
`DartLibraryCalls::DrainMicrotaskQueue` uses.

**Timers are still unimplemented and Flutter will need them.**
`Future.delayed`, `Timer`, and `Future(...)` all go through
`VMLibraryHooks.timerFactory`, which nothing sets. hello.dart uses
`Future.microtask` to stay clear of it. This is **smaller than it first looked**
— `timer_impl.dart` is part of `dart:isolate` and already in the snapshot, so
what is missing is three hook installations rather than a timer implementation.
See [embedder-startup.md](embedder-startup.md).

### Method note: reading a crash address

**The binary is not loaded at its linked address.** The slide has been observed
between 0x40000 and 0x64000 and **varies per run**. Compute it by comparing a
snapshot symbol address logged in `m1.log` against `arm-vita-eabi-nm` on
`build/flutter_vita_m1`, then subtract before running `addr2line`. Skipping this
resolved an address to `StringToDoubleConverter::StringToIeee`, which is obvious
nonsense — but a less obviously wrong answer would have sent the investigation
somewhere useless.

**One return address is not a call site.** Instrumenting `HandleImpl` with
`__builtin_return_address(0)` produced an address inside `ObjectPool::Handle`,
a thin wrapper with many callers, and that was misread as naming a specific
caller. GCC on ARM rejects `__builtin_return_address(n)` for n > 0, so the fix
was to scan `HandleImpl`'s own frame for words that look like Thumb return
addresses in the text range. That produced the real chain in one run:

```
0x8118986d  ObjectPool::Handle(Zone*, ObjectPoolPtr)   object.h:5873
0x81192ffd  StackFrame::IsStubFrame()                  stack_frame.cc:150
0x8119064b  DRT_TypeCheck -> DRT_HelperTypeCheck       runtime_entry.cc:1886
```

A stack walk reading a null pool — which points straight at frame layout.

### Corrections to earlier conclusions

Three claims previously recorded in this file were wrong:

- **`BareSwitchableCallPattern` was never the caller.** Its trace never fired.
  The attribution came from the single-frame return address described above.
- **ARM/Thumb interworking is dead** as a hypothesis, and was always weakly
  supported. Compiled Dart was executing the whole time.
- **Vita3K's `instructions_arm.cc:414` failure** was dismissed as an emulator
  artifact, which was premature — but whether it shares this root cause is
  still unverified. Do not record it as confirmed either way.

## Debugging, since there is none of the usual kind

No DevTools, no profiler, no timeline, no on-device debugger — all disabled or
impossible. What exists instead:

- **Crash dumps.** The Vita writes `psp2core-*.psp2dmp` to `ux0:data/` on every
  fault. [`experiments/m1-vpk/analyse-crash.sh`](../experiments/m1-vpk/analyse-crash.sh)
  symbolicates one against `build/flutter_vita_m1` (the ELF, **not** eboot.bin).
  This has been the single most effective tool — it found the BSS problem in one
  run after four rounds of trace-point bisection got nowhere. Needs
  `pyelftools==0.29` in a venv and a py3 patch to `util.py`, both already done
  under `experiments/m1-vpk/out/`.
- **`VitaTrace`** in `syslog_vita.cc` — writes straight to `sceIo` and syncs
  every line, works before the VM can log anything.
- **Checkpoints** in the harness, flushed before every risky call.

## Gotchas that cost real time

- **Read `runtime/bin/main_impl.cc` and `dartutils.cc` before writing embedder
  code.** Every one of M1's last three failures was a step those files perform
  and this harness did not: `--precompilation`, the microtask closure, and
  running `main` through the message queue. Building the harness from
  `embedder.h` and the API headers instead cost three deploy cycles. Phase 2
  should start by reading that startup path end to end.
- `print()` in Dart **throws** until an embedder installs `_printClosure`;
  `runtime/bin` normally does that and is excluded here. hello.dart returns a
  checksum (**6830**) instead. `asyncMarker()` returns 99 only if the microtask
  queue drains.
- **BGFTP frequently resets the first connection.** `curl` reports
  *"Recv failure: Connection reset by peer"* and the retry succeeds; uploads
  have taken up to 32 attempts. Loop rather than treating one failure as down.
- `SCE_O_TRUNC` does not truncate on Vita3K — stale log tails read as current
  errors. Both logs are `sceIoRemove`d before opening.
- `sceKernelExitProcess` is not `noreturn` and **returned** on Vita3K, carrying
  execution past a reported failure.
- `ninja | grep | tail` reports **tail's** exit code. A build that died at
  80/1151 looked like success.
- The `vita_create_vpk` macro renumbers output (`_2`, `_3`…) on reconfigure. A
  clean `rm -rf build` restores the predictable name.
- ICU is built **with** exceptions while Dart is `-fno-exceptions`, so the target
  must link as C++ (`LINKER_LANGUAGE CXX`) or `__gxx_personality_v0` is undefined.
- Dart's runtime is **not** one archive — GN emits `source_set`s whose objects
  link directly. CMake globs all ~500 `.o` files. An 8.66 MiB
  `libdart_aotruntime_product.a` once looked complete while containing **no**
  platform code at all, because creating an archive never resolves symbols.

## Decisions worth not relitigating

Read [`docs/adr/`](adr/README.md), but the load-bearing ones:

- **[ADR-0005](adr/0005-aot-snapshot-delivery.md) reversed to Option A.** The
  snapshot is assembled and linked into `eboot.bin`. Option B (runtime loading
  into a VM-domain block) works for allocation, W^X flipping, I-cache sync and
  execution — all proven on hardware — but `Image::bss()` puts a **writable**
  BSS inside the instructions image, and the VM domain is all-or-nothing. Cost:
  every app relinks the engine, which hurts M4. Revivable by patching
  `Image::bss()`, not worth it to reach M1.
- **[ADR-0006](adr/0006-performance-bar-set-from-measurement.md)**: measured on
  hardware. 60 fps at native 960×544 is impossible (the 8.06 ms present blit
  alone is 48% of the frame budget); 30 fps is marginal; **720×408 upscaled
  reaches 68 fps**, so the reduced-resolution fallback is the likely default.
- **[ADR-0007](adr/0007-enable-partial-repaint-in-software-path.md)**: Flutter's
  software path repaints the whole screen every frame. Accepted as required.

## Phase 1 exit criteria, finally run

Both were listed as never executed. They are now, and both found something.

**Multi-isolate: refused, as designed.** `Isolate.spawn` returns
`isoMarker = -1` — the harness passes no `create_group` callback to
`Dart_Initialize`, so the VM cannot build a second isolate group. Expected, but
worth having measured: **Flutter spawns isolates**, so this is a Phase 2
prerequisite, not a curiosity.

**GC stress: FIXED.** `gcStress() = 1999000` on hardware — 2000 iterations, ~8 MB of churn, where it previously died at ~200 every time. `gcStress()` allocates ~8 MB in a tight loop
and dies with a data abort in `DRT_AllocateArray`, sometimes preceded by a
spurious-looking `StackOverflowError`. **Currently disabled** behind `#if 0` in
`experiments/m1-vpk/src/main.c` because it takes down the app that hosts the dev
server, costing a manual relaunch every cycle.

`OSThread::GetCurrentStackBounds` was the leading suspect and has been
**cleared**. The theory was that `SceKernelThreadInfo.stack` is the stack top,
making the reported bounds inverted. Measured directly instead — logging
`ti.stack` next to the address of a local:

```
ti.stack=0x81501000  size=1024 KiB  &local=0x81600ec0
-> ti.stack is the base (local is above it)
```

The local sits near the top of `[ti.stack, ti.stack+size]`, so the bounds are
right and the implementation is correct. The crash is something else, and the
crash-dump SP that looked out of range came from a different run with a
different load address — not comparable.

### What the crash dump actually says

Two dumps, different binaries, **byte-identical registers** — a deterministic
failure at a fixed call depth. The faulting instruction:

```asm
81140a46:  ldr.w r1, [lr, #40]      <- LR = 0x00000000
```
```c
// raw_object.h, UntaggedObject::CheckArrayPointerStore
uword overlap = (source_tags >> kBarrierOverlapShift) & target_tags &
                thread->write_barrier_mask();
```

The compiler allocated `Thread*` into `LR` (legal, it is r14) and **`thread` is
null**. So `DRT_AllocateArray` reaches the generational write barrier with a
null thread. That also explains why only allocation-heavy code trips it: the
barrier only runs once objects begin getting promoted, which needs a GC first.

It dies at **i≈200–300 with only ~80 KB retained** — nowhere near any memory
limit, so this is not a heap-size threshold.

### CONFIRMED: `thread_local` returns null on this platform

```
__emutls symbols in the binary : 15
ELF TLS segment                : none
```

VitaSDK has no real ELF TLS; `thread_local` compiles to `__emutls_get_address`,
and that function **calls `malloc`** to create a thread's TLS block on first
access. `Thread::Current()` is a `thread_local`
([os_thread.h:329](../third_party/sdk/runtime/vm/os_thread.h)), so *reading it
can allocate* — and Dart reads it from inside allocation slow paths, GC, and
no-safepoint scopes, which are exactly the places where allocating is illegal
or can fail.

`DRT_AllocateArray` was instrumented to log both the thread it is handed and
`Thread::Current()`. On hardware:

```
[vita] AllocateArray ok        arg=0x817127c8  tls=0x817127c8
[vita] AllocateArray MISMATCH  arg=0x817127c8  tls=0x0
```

**The runtime entry's `thread` argument is valid throughout. `Thread::Current()`
returns null.** Same thread, same moment: the argument is right and the TLS read
is wrong. Generated code and the THR register are exonerated; this is purely
`thread_local` failing.

`SetTypeArguments` uses the no-thread `StorePointer` overload, which resolves
the thread through `Thread::Current()`, so the barrier dereferences null and
takes the process down.

### The one-line fix does not work, and here is why

`-u pthread_cancel` forces the symbol in, `__gthread_active_p()` becomes true,
and emutls switches from its shared-global path to real `pthread_getspecific`.
Tested on hardware: **M1 crashes at startup.**

```asm
8121a098 <pthread_mutex_unlock>:
    ldr r3, [r0, #0]     ; the mutex's internal pointer
    ldr r1, [r3, #12]    ; <- data abort, r3 is garbage
```

emutls guards its table with a **statically initialised** mutex
(`__GTHREAD_MUTEX_INIT`). VitaSDK's pthread does not support static mutex
initialisers — a mutex must go through `pthread_mutex_init()`. While threads
were "inactive" that mutex was never touched; making them active means emutls
uses it, and it faults on the first unlock.

**Both states are therefore broken:**

| | |
|---|---|
| without the flag | every `thread_local` is one shared global |
| with the flag | uninitialised mutex, crash at startup |

`-u pthread_cancel` has been removed from `experiments/m1-vpk/CMakeLists.txt`, with
this reasoning recorded there so it is not restored on its own.

**The fix: patch 0009, written and verified on hardware.** `Thread::Current()` must not depend
on emulated TLS. It is read from allocation slow paths, GC and no-safepoint
scopes, and `__emutls_get_address` mallocs a thread's block on first access —
allocating on a path that must never allocate.

**Provide our own `__emutls_get_address` and stop using libgcc's.** It is a
plain ABI function, so defining it in our own binary overrides the library one,
and it fixes every `thread_local` in the runtime at once rather than patching
Dart:

```c
struct __emutls_object { size_t size; size_t align; void *loc; void *templ; };
void *__emutls_get_address(struct __emutls_object *obj);
```

Key it on `sceKernelGetThreadId()` with a small fixed table — Dart uses few
threads — and use a Vita mutex (`sceKernelCreateMutex`), which needs no static
initialiser. That sidesteps both failures: no shared global, and no
pthread mutex that was never initialised.

This is preferable to editing `os_thread.h`, which would fix only
`Thread::Current()` and leave every other `thread_local` in the runtime
silently sharing state.

**Result on hardware**, with the file living in
`runtime/platform/emutls_vita.cc` and listed in `platform_sources.gni`:

```
thread_local probe (main set 111):
  pthread worker set 222 -> main reads 111  PER-THREAD OK
  vita thread set 333    -> main reads 111  PER-THREAD OK

main() 6830 PASS | gcStress() 1999000 PASS | asyncMarker 99 PASS
delayedMarker 42 PASS
```

Note it must be guarded with `#if defined(DART_HOST_OS_VITA)`, with the psp2
include *inside* the guard: `platform_sources.gni` is shared, so the host build
of gen_snapshot compiles this file too and has no psp2 headers. When that guard
was missing, gen_snapshot failed to build and the snapshot step still reported
success, because the previous gen_snapshot binary was still on disk and ran.
**Check exit codes on every build step.**

**This is a platform-layer defect affecting every `thread_local` in the
runtime**, not just this one call site. Anything else reading TLS on an
allocation path has the same latent bug — which is a strong argument for fixing
it before the engine lands on top.

Note the threads created with `sceKernelCreateThread` (timer, power tick) are
not pthreads, which is a second way emulated TLS can misbehave.

This is the most valuable open item. It is a platform-layer defect, it is
deterministic, and it will be far worse to debug under a Flutter heap.

## Still open

- ~~Timers~~ **done** — `Future.delayed` fires on hardware, and the timer
  thread sleeps on an event flag rather than polling. See
  [embedder-startup.md](embedder-startup.md).
- **Threading substrate and iteration cost** were never grilled. Both are logged
  in [the ADR index](adr/README.md).
- `Flutter Vita Plan.md` contradicts the docs in seven places (pin version, the
  "~2 MP" arithmetic, JIT needing kernel plugins, 60 fps, pthread absence). Left
  as the historical record; either reconcile it or mark it superseded.
- `runtime/docs/qemu.md` — a `linux-arm` build under QEMU would allow a real
  debugger for Dart-runtime bugs. Parked since Phase 0.5 and increasingly the
  thing that would pay for itself.
- Phase 2 (the Flutter engine itself) has not been started. Only the Dart
  runtime is ported.
