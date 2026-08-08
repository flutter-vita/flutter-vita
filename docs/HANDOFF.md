# Handoff — state of play

Written 2026-08-07 at the end of a long session. Everything needed to pick this
up cold. Read [docs/README.md](README.md) for the project shape;
this file is specifically *where we stopped and why*.

---

## One-paragraph summary

Flutter-for-Vita is at **milestone M1**: pure-Dart AOT running on the device, no
Flutter yet. The Dart runtime **compiles and links for `arm-vita-eabi`**, a
**vita-targeting `gen_snapshot`** exists, and a `.vpk` runs on real hardware and
gets as far as **creating a Dart isolate**. It then faults calling `main()`.
Phase 0.5 (feasibility) is complete and the verdict was go.

## The machine

| | |
|---|---|
| VitaSDK | `~/vitasdk` (GCC 15.2.0, `arm-vita-eabi`) — no sudo, installed via vdpm |
| depot_tools | `~/depot_tools` — provides `gclient`; `gn`/`ninja` come from the Dart checkout |
| Dart SDK | `third_party/sdk` — **gclient-owned**, pinned `d684a576`, ~7.8 GB, gitignored |
| Flutter | FVM 3.44.8, pinned in committed `.fvmrc` |
| Vita | `192.168.0.40`, FTP on 1337 — always on, served by **BGFTP** |
| Title ID | `FVTA00002` (M1), `FVTA00001` (Track A probe) |

**Never `rsync` into `third_party/sdk`.** gclient records DEPS sub-repos with
gitlinks that a file copy corrupts; the failures surface later as
*"not a git repository"* on a different directory each sync. The tree is
disposable — [`patches/dart-sdk/`](../patches/dart-sdk/README.md) is the real
artifact and restores the whole port with one `git apply`. That has been proven
twice, once after a careless `reset --hard` destroyed the working tree.

## Build pipeline, in order

```bash
# 1. Dart runtime for Vita (494 objects, ~3 MiB stripped)
ninja -C third_party/sdk/out/vita obj/runtime/libdart_aotruntime_product.a

# 2. Host gen_snapshot that targets Vita
ninja -C third_party/sdk/out/host gen_snapshot_product_vita_arm

# 3. hello.dart -> kernel
./spikes/b1-aot-snapshot/build.sh

# 4. kernel -> snapshot.S  (app-aot-assembly; ADR-0005 option A)
third_party/sdk/out/host/gen_snapshot_product_vita_arm \
  --snapshot_kind=app-aot-assembly \
  --assembly=spikes/m1-snapshot/out/snapshot.S \
  spikes/b1-aot-snapshot/out/hello.dill

# 5. link everything into a vpk
./spikes/m1-vpk/build.sh
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

[`spikes/m1-vpk/deploy.sh`](../spikes/m1-vpk/deploy.sh) scripts this with
`USE_COMPANION=0`.

**Do not suggest taiHEN plugins.** vitacompanion destabilised the device (it
loads into SceShell) and others would not load at all. BGFTP is installed and
working; that is the whole deployment story. Launching is manual, from the
LiveArea, and that is fine.

## Where it stops — narrowed by run 11

```
Dart_Initialize ok
isolate created
[checkpoint] Dart_RootLibrary
root library handle ok, null=0      <- object store is correct
[checkpoint] Dart_NewStringFromCString
name handle ok                      <- heap allocation and object creation work
[checkpoint] Dart_Invoke
<data abort>
```

**The snapshot loads correctly and the Dart heap works. The fault is specifically
in calling AOT-generated code.** Everything before `Dart_Invoke` succeeds,
including creating a Dart String, which exercises allocation and the object
model.

### ROOT CAUSE FOUND: `global_object_pool()` is null

Traced 2026-08-07 by instrumenting `HandleImpl` (patch 0007) to log its return
address when handed `ObjectPtr == 1`:

```
[vita] HandleImpl: ObjectPtr==1 from ra=0x8116779d cid=23
```

`cid=23` is `kObjectPoolCid`, and the return address resolves to
`dart::ObjectPool::Handle(Zone*, ObjectPoolPtr)` called from
**`instructions_arm.cc:289`**:

```cpp
BareSwitchableCallPattern::BareSwitchableCallPattern(uword pc)
    : SwitchableCallPatternBase(ObjectPool::Handle(
          IsolateGroup::Current()->object_store()->global_object_pool())) {
```

**`object_store()->global_object_pool()` returns null.** `ObjectPool::Handle`
tags it, producing `nullptr | kHeapObjectTag` = 1, and the header read faults.

`Dart_Invoke("main")` goes through a switchable call site, which starts
unlinked and gets patched on first invocation. That patching needs the global
object pool, and in bare-instructions AOT that pool comes from the isolate
snapshot into the object store.

**This also explains Vita3K.** Its failure was `instructions_arm.cc:414`
(`TypeTestingStubCallPattern`); hardware fails at line 289
(`BareSwitchableCallPattern`). Same file, same class of operation — patching a
call site using the object pool. The emulator was pointing at the real bug, and
dismissing it as an artifact cost two rounds.

**Important caveat for anyone reading a crash address: the binary is not loaded
at its linked address.** There is a load slide, currently 0x42000 but it varies
per run. Compute it by comparing a snapshot symbol address logged in `m1.log`
against `arm-vita-eabi-nm` on `build/flutter_vita_m1`, then subtract before
running `addr2line`. Skipping this resolved the address to
`StringToDoubleConverter::StringToIeee`, which is obvious nonsense — but a less
obviously wrong answer would have sent the investigation somewhere useless.

### Two things the static analysis established

**Generated ARM code is executing.** `BareSwitchableCallPattern` is only
constructed when the runtime is asked to patch a *switchable call site*, which
happens when Dart code hits an unlinked call and traps back into the runtime.
Reaching that point means compiled Dart ran and the trap path worked. **The
ARM/Thumb interworking hypothesis is dead** — delete it from consideration.

**The pool is probably non-null after deserialisation and null later.**
`RW(ObjectPool, global_object_pool)` (`object_store.h:209`) is auto-serialised
with the object store, needing no special handling. And
`app_snapshot.cc:7486` *dereferences* it while deserialising
(`pool->untag()->length_`), which would itself have crashed had it been null
then. So the interesting window is between "isolate snapshot read" and
"Dart_Invoke".

**Where to look next:**

1. **Bracket the window.** `VitaTrace` the value of
   `object_store()->global_object_pool()` at three points: end of
   `Dart_CreateIsolateGroup`, entry to `Dart_Invoke`, and inside
   `BareSwitchableCallPattern`. Null at the first means it never came out of the
   snapshot; non-null then null later means something clears or replaces it.
   This is one build and one run, and it splits the problem in half.
2. **Check `IsolateGroup::Current()` is the right group.** The pool is read via
   `IsolateGroup::Current()->object_store()`. If the trap path lands with a
   different current group — or none — the store would be a different object.
   Worth logging the group pointer alongside the pool.
3. **`thread.cc:1656`** caches the pool into `Thread::global_object_pool_` on
   isolate entry. We rely on `Dart_CreateIsolateGroup` entering implicitly and
   never call `Dart_EnterIsolate`; confirm that is sufficient.
4. Compare against a `linux-arm` build of the same `hello.dill` under QEMU.

### Superseded: the ObjectPtr == 1 symptom

From run 11's dump (`analyse-crash.sh` on the newest `psp2core-*`):

```
Stop reason: Data abort exception
PC: dart::Object::HandleImpl(Zone*, ObjectPtr, int)
faulting instruction:  ldr.w r3, [r1, #-1]      <- untag and read the header
R1: 0x1
```

**The `ObjectPtr` is literally `1`.** Dart's `kHeapObjectTag` is 1, so the low
bit set means "heap object"; untagging gives `0x0` and the header read
dereferences null. An `ObjectPtr` of exactly 1 is `nullptr | kHeapObjectTag` —
**something read a zero and tagged it**, rather than a corrupted or stale
pointer.

That is a much more specific lead than "garbage pointer". Somewhere a slot that
should hold a real object holds zero.

**The BSS offset is ruled out.** It was the leading suspect and it is correct.
gen_snapshot emits it as a link-time expression, not a baked-in constant:

```asm
.long _kDartVmSnapshotBss - (.) - -72
```

The field sits at image start + 72, so that reduces to `bss - image_start` and
the linker resolves it from the real symbol addresses — it cannot disagree with
the layout. Verified against the linked binary anyway:

```
_kDartVmSnapshotInstructions  0x81005680
_kDartVmSnapshotBss           0x813b0f9c
actual distance               0x003ab91c
recorded bss_offset_          0x003ab91c   MATCH
```

So `Image::bss()` finds the right place, and whatever is zero is not zero
because `BSS::Initialize` wrote to the wrong address.

### Weaker hypothesis: ARM/Thumb interworking

**The run 11 dump argues against this**, and it was recorded here more
confidently than the evidence supported. The disassembly around the crash is
Thumb-2 (`23b0`, `bd00`, `f853 3022`) and Dart's C++ runtime is executing
correctly; nothing suggests a state mismatch. The fault is a bad *value*, not a
bad instruction stream.

Keeping the note because it is still unverified and cheap to rule out — build
the C/C++ side `-marm` and see if anything changes — but it should not be the
first thing tried.

This was flagged in [the Phase 1 work plan](phase-1-workplan.md) and never
verified:

> VitaSDK defaults to `--with-mode=thumb` while Dart's backend emits ARM (A32).
> Interworking is standard under EABI v5, but verify at M1.

This *is* M1, and the symptom fits precisely. Every C/C++ object in the build is
Thumb (`-mthumb` appears in the compile flags), while the snapshot's `.text` is
A32. Calling from Thumb into ARM requires the low bit of the target address to
be **clear**, and `BLX`/`BX` switch state from it. If Dart computes an entry
point that keeps a Thumb bit set — or the runtime assumes the same instruction
set as the code it calls — execution lands mid-instruction and faults.

Supporting evidence: Vita3K failed at this same stage with
`instructions_arm.cc: 414: expected: pattern.IsValid()`, where the runtime
decodes a call site and expects the A32 encoding `blx r9` (`0xe12fff39`). That
was dismissed as an emulator artifact when hardware failed earlier; it now looks
like the same bug seen sooner.

**Things to try, cheapest first:**

1. **Find who passes the 1.** `HandleImpl` is called from everywhere and the
   dump gives only PC and LR, both inside it. Patch `HandleImpl` to `VitaTrace`
   a return address when `ptr == 1` — that names the caller in one run.
2. **Check `Object::null_` and the other VM-wide statics.** If a slot that
   should hold a real object is zero, tagging it produces exactly 1. These are
   set during `Dart::Init` from the VM snapshot.
3. **Compare against a working target.** Build the same `hello.dill` for
   `linux-arm`, run it under QEMU, and see whether the same call path produces a
   valid pointer. This is the strongest available signal and needs no Vita —
   see `runtime/docs/qemu.md`.
4. ~~Verify the BSS offset~~ — **done, it is correct.** See above.
5. Rule out interworking by building `-marm`. Cheap, but the dump makes it
   unlikely.

## Earlier failures, for context

Last hardware run:

```
Dart_Initialize ok
isolate created
[checkpoint] invoking main()
<data abort>
```

Crash dump says `dart::Object::HandleImpl`, faulting on `ldr.w r3, [r1, #-1]` —
Dart untagging a heap pointer to read its object header, i.e. **a garbage
`ObjectPtr`**. Suspicion is `Dart_RootLibrary()` returning junk from the object
store, but unconfirmed.

**Run 11 is built and deployed but never launched.** It adds one checkpoint per
API call (`Dart_RootLibrary` / `Dart_NewStringFromCString` / `Dart_Invoke`) and
logs whether the root library handle is null. **Launch it first** — it identifies
which call faults, which is the immediate unknown.

Note Vita3K died at this same stage with `instructions_arm.cc: pattern.IsValid()`.
I dismissed that as an emulator artifact when hardware failed earlier; that was
premature and they may be the same bug.

## Debugging, since there is none of the usual kind

No DevTools, no profiler, no timeline, no on-device debugger — all disabled or
impossible. What exists instead:

- **Crash dumps.** The Vita writes `psp2core-*.psp2dmp` to `ux0:data/` on every
  fault. [`spikes/m1-vpk/analyse-crash.sh`](../spikes/m1-vpk/analyse-crash.sh)
  symbolicates one against `build/flutter_vita_m1` (the ELF, **not** eboot.bin).
  This has been the single most effective tool — it found the BSS problem in one
  run after four rounds of trace-point bisection got nowhere. Needs
  `pyelftools==0.29` in a venv and a py3 patch to `util.py`, both already done
  under `spikes/m1-vpk/out/`.
- **`VitaTrace`** in `syslog_vita.cc` — writes straight to `sceIo` and syncs
  every line, works before the VM can log anything.
- **Checkpoints** in the harness, flushed before every risky call.

## Gotchas that cost real time

- `print()` in Dart **throws** until an embedder installs `_printClosure`;
  `runtime/bin` normally does that and is excluded here. hello.dart returns a
  checksum (**6830**) instead. `asyncMarker()` returns 99 only if the microtask
  queue drains.
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

## Still open

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
