# ADR-0005: How the Dart AOT snapshot gets into the process

**Status:** **Superseded — Option A.** Option B was accepted on hardware evidence,
then defeated by a requirement nobody had tested. See the reversal below.
**Date:** 2026-08-06, decided 2026-08-07, reversed 2026-08-07

## Reversal: Option B cannot work, take Option A

M1 run 9 faulted with a data abort, and the crash dump named it exactly:

```
PC: dart::BSS::Initialize(Thread*, uword* bss_start, bool vm)
faulting instruction:  strex ip, r3, [r1]        <- a store
called from: dart::FullSnapshotReader::ReadVMSnapshot()
```

`Image::bss()` places the BSS at a fixed offset **inside the instructions
image**, and Dart writes to it during startup. Its own comment states the
assumption:

> *"Returning a non-const uword\* is safe because we're translating from the
> start of the instructions (read-only) to the start of the BSS (read-write)."*

Every other platform's ELF receiver satisfies that by mapping `.text` as `R-X` and
`.bss` as `RW-` — different protections within one image. **The Vita's VM domain
is all-or-nothing:** `Open` is writable, `Close` is executable, and there is no
state where instructions execute while the BSS inside them stays writable.

The three hardware results together make the picture complete, and each was
necessary:

| tested | result |
|---|---|
| Track A: does VM-domain memory execute? | yes |
| M1 run 9: is it readable after `Close`? | yes |
| M1 run 9 crash dump: is it **writable** after `Close`? | **no — and Dart needs it to be** |

Nobody thought to test writability, because the mechanism is described as W^X
and "executable" sounded like the whole requirement. The snapshot format quietly
needs both at once.

**So the decision reverses to Option A.** The remaining alternative — patching
`Image::bss()` to redirect the BSS into a separate RW allocation — keeps Option
B alive but means diverging from an assumption baked into the snapshot format
itself. Not worth it to reach M1; revisit if M4's relink cost ever justifies it.

The VM-domain mechanism is *not* discredited: allocation, W^X flipping, cache
sync and execution all work on hardware. It is defeated by one specific
requirement, and that is worth recording precisely rather than as "Option B
failed".

## Superseded: Option B, load the snapshot at runtime

Track A run 3 on a physical Vita:

```
sceKernelOpenVMDomain      0x00000000
wrote code with domain open   ok
sceKernelCloseVMDomain     0x00000000
sceKernelSyncVMDomain      0x00000000
call ARM   code -> 42 (expected 42) PASS
call Thumb code -> 37 (expected 37) PASS
```

**Executable memory works from ordinary homebrew, in both ARM and Thumb state,
with no kernel plugin.** Dart's AOT backend emits ARM, so the ARM result is the
one that matters; Thumb passing as well means embedder-side generated thunks
would work too.

Consequences, now settled:

- The AOT snapshot ships as a **data file in `app0:`**, loaded into a VM-domain
  block at startup. The engine binary is app-independent.
- **Third parties never relink the engine.** We ship a runtime, not a build
  system. Milestone M4 gets dramatically cheaper.
- `flutter_vita_tool build` becomes: `flutter build bundle` → `gen_snapshot` →
  package. No engine link in the inner loop.

### Operational constraints the measurement imposes

- **VM blocks have a 1 MiB minimum.** 4 KiB, 16 KiB, 64 KiB, 256 KiB and 512 KiB
  are all rejected with `SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK_SIZE`. Documented
  nowhere. Round the snapshot allocation up to a 1 MiB boundary.
- **The 16 MiB ceiling is not reliably available.** Run 1 measured the largest
  obtainable block at exactly 16.00 MiB on a clean process. Run 3, after two
  1 MiB allocate/free cycles earlier in the same process, could only get
  **8.00 MiB** — an exact halving that looks like the VM region fragmenting
  without coalescing.
  **Therefore: allocate the snapshot block once, early, before anything else
  touches the VM domain.** Treat 8 MiB as the dependable budget and 16 MiB as a
  best case. A counter app needs 2.11 MiB, so this is comfortable today, but the
  build tool should warn well below 16 MiB rather than at it.
- The `Open`/`Close` semantics are **W^X and inverted from the header comment** —
  see [ADR-0001](0001-aot-only-no-jit.md). Open to write, Close to execute.

## Context

The plan says Phase 3 initialises the engine with "`FlutterProjectArgs` pointing
at `app0:/assets` and the AOT snapshot symbols", without deciding *how* the
snapshot arrives. There are only two shapes, and they produce very different
projects.

A Dart AOT snapshot has four parts: `vm_snapshot_data`,
`vm_snapshot_instructions`, `isolate_snapshot_data`, `isolate_snapshot_instructions`.
The two `_data` parts are ordinary read-only bytes. The two `_instructions` parts
are **machine code and must live in executable memory.**

### What the 16 MiB cap does and does not limit

Worth stating plainly, because it is easy to misread as an app-wide memory
limit. From `psp2/kernel/sysmem.h`:

```c
/**
 * Allocates a new memory block for Virtual Machine domain.
 * @note - size can't be higher than 16 * 1024 * 1024.
*/
SceUID sceKernelAllocMemBlockForVM(const char *name, SceSize size);
```

- **It caps only executable-capable memory.** The VM domain is the sole
  mechanism a normal homebrew app has for memory it can execute from.
- **Ordinary memory is unaffected.** Plain `sceKernelAllocMemBlock` has no such
  cap — that is where the Dart heap, Skia caches, framebuffers, and the
  snapshot's `.rodata` all live. None of it needs to be executable.
- **Multiple VM blocks do not help.** `Open`/`CloseVMDomain` act on all VM
  blocks at once so several may exist, but Dart needs one contiguous mapping for
  its instructions, so blocks cannot be stitched together past 16 MiB.
- **Under Option A the cap is irrelevant** — instructions land in `.text` of the
  main ELF and the OS receiver maps them executable, with no VM domain involved.

Informed speculation on the origin, not verified: the VM domain looks like
Sony's provision for **PlayStation Mobile**, which ran C#/Mono with a JIT on
retail Vitas. If so, 16 MiB is a product decision rather than a hardware one,
which would make it a fixed number rather than something varying with firmware
or memory pressure. The A1 experiment measures the real obtainable maximum anyway.

### Option A — bake in (`gen_snapshot --snapshot-kind=app-aot-assembly`)

Assemble the snapshot with the VitaSDK assembler and statically link it into
`eboot.bin`. Instructions land in `.text`, which the receiver maps executable. No
runtime executable-memory question at all.

Cost: **the Dart app is part of the engine binary.** Every app build is a full
static link of Skia + ICU + Dart + engine. A third-party developer's edit-to-run
loop includes that link. This makes M4 ("a third party goes from `git clone` to
a running `.vpk` of their own app") substantially worse, and it means we ship a
toolchain, not a runtime.

### Option B — load at runtime (VM domain)

Ship the snapshot as a data file in `app0:`. At startup:

1. `sceKernelAllocMemBlockForVM` a block sized to the instructions section
2. with the VM domain closed (writable), read the instructions into it
3. `sceKernelOpenVMDomain()` → the block becomes executable
4. `sceKernelSyncVMDomain(uid, base, size)` → flush I-cache
5. hand the pointers to `FlutterProjectArgs`

This is a **load-once, flip-once** pattern, which is exactly the case the VM
domain API suits — unlike JIT, which needs to flip constantly
([ADR-0001](0001-aot-only-no-jit.md)). The engine binary becomes app-independent:
one prebuilt `libflutter_engine`/`eboot.bin` that any app's assets drop into.

Cost and risk:

- ~~**16 MiB hard cap per VM block**~~ — **measured 2026-08-06 and largely
  resolved.** A stock Flutter counter app's armv7 AOT instructions are
  **2.11 MiB**, i.e. 13.2% of the cap, leaving 13.89 MiB of headroom. The
  framework is a fixed ~1.8 MiB and dominates; app code is the only variable
  above that. A mid-complexity app should land around 4–6 MiB. The cap is a real
  ceiling but not a near-term constraint. See
  [Phase 0.5 B2](../phase-0.5-feasibility.md).
- Whether multiple VM blocks can back one logically contiguous instructions
  region — almost certainly not, since Dart expects one mapping. Now moot in
  practice given the measured sizes, but it is why the cap is a genuine app-size
  limit rather than an allocation detail.
- Whether `sceKernelOpenVMDomain` has side effects on the rest of the process.
- Whether Vita3K emulates this path faithfully (assume not; hardware is ground truth).

## Decision

**Not yet made.** Option B is strongly preferred if the experiment clears, because it
is the difference between shipping a runtime and shipping a build system.

## Phase 0.5 experiment (blocks this ADR)

A standalone C `.vpk`, no Dart involved, that:

1. allocates a VM block, writes a trivial armv7 function into it, opens the
   domain, syncs, calls it, and prints the result — on **real hardware**;
2. reports the largest single VM block that can actually be allocated under
   enlarged memory mode;
3. confirms whether an already-running thread survives an
   `Open`/`CloseVMDomain` cycle.

Estimated cost: one to two days. It determines the shape of Phases 3 and 4.

## Consequences either way

- Under Option A, `flutter_vita_tool build` owns a full engine link and must
  cache aggressively; measure and publish the wall-clock number, because it is
  the headline DX figure.
- Under Option B, the app-size ceiling must be checked by the tool at build time
  with a clear error, not discovered as a crash on device.

## Related

[ADR-0001](0001-aot-only-no-jit.md), [ADR-0004](0004-static-single-binary.md)

## Sources

- https://docs.vitasdk.org/group__SceSysmemUser.html
- https://docs.vitasdk.org/kernel_2sysmem_8h_source.html
