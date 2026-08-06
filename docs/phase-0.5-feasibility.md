# Phase 0.5 — Paper Feasibility Gate

**Purpose:** answer, in days rather than months, the questions that could kill or
reshape this project — *before* committing 2–4 months to the Dart runtime port.

Inserted between Phase 0 and Phase 1. Nothing in Phase 1 starts until every item
below has an answer written down here. "The answer is bad news" is a successful
outcome for this phase.

---

## Sequencing

The six exit criteria below are not equally urgent and do not all need a Vita.
They split into two tracks that run in parallel.

### Step 0 — make the repo real (30 minutes)

`git init`. Commit `Flutter Vita Plan.md`, `VERSIONS.md`, and `docs/`. Right now
none of this is under version control, and the ADR series is worthless without
history.

### Track A — needs real hardware

**A1. Make your hello-world *be* the VM domain spike.**

Phase 0 already calls for "a plain C hello world `.vpk`" to establish the
FTP-deploy and network-logging loop. Do not write that, prove the loop, and then
throw it away. **Write the [VM domain spike](adr/0005-aot-snapshot-delivery.md)
as the hello world.** It is the same C harness, the same deploy path, the same
log capture — and it returns the single highest-value answer in the project
instead of the word "hello".

Deliverables from that one program:

- the build → deploy → log loop exists (Phase 0 exit criterion)
- VM domain executable memory works, or does not (unblocks ADR-0005)
- the real largest allocatable VM block, and the real largest contiguous
  `sceKernelAllocMemBlock` by type (exit criteria 1 and 4)

*Then, and only then, is Track A's information worth acting on.*

### Track B — host only, needs no Vita, start today

**B1. Fetch ardera's `arm/gen_snapshot_linux_x64_release` and produce an armv7
AOT snapshot of a pure-Dart hello world.** No Vita, no VitaSDK, no engine build.
This proves the entire host half of M1 in an afternoon and gives you a real
artifact to size and to link against later.

**B2. Record `isolate_snapshot_instructions` size** for that hello world, for a
counter app, and for something mid-complexity. Compare against 16 MiB
(exit criterion 3).

**B3. Build the engine for `linux-arm` and measure it** — replaces the
provisional 11 MB with a real number, and is a dry run for the far harder
VitaSDK toolchain work (exit criterion 3).

**B4. Raster throughput number** on any armv7 board (exit criterion 2).

**B5. Float ABI check** (exit criterion 5) — can be reasoned about from the
Dart build flags plus VitaSDK's defaults before anything is compiled.

### Why this order

Track B needs no hardware, so nothing blocks on shipping, borrowing, or setting
up a Vita. Track A is short but its answer reshapes Phases 3 and 4, so it should
not wait behind toolchain work. Exit criterion 6 (thread budget) is deliberately
last: it is the hardest to answer in the abstract and becomes much easier once
B1 and B3 exist.

---

## Provisional memory arithmetic

Researched figures, to be replaced by measured ones. **Every number here is
provisional; the whole point of this phase is to confirm or refute them.**

### The budget

The Vita has 512 MB LPDDR2 plus 128 MB VRAM. Applications receive a *memory
budget* allocated at boot by `SceProcessmgr`; budgets vary by firmware and boot
flags. Titles can request enlarged memory mode, documented as adding
**+29 MiB, +77 MiB, or +109 MiB**. The plan's "~330–400 MB available" is
consistent with a base user budget plus the largest enlargement, but **I could
not verify the exact figures** — the HENkaku wiki's Memory budget page is behind
a bot wall. *Open item: confirm the exact base and enlarged budgets, and confirm
that a homebrew title launched from the LiveArea actually receives the enlarged
budget it requests in `param.sfo`.*

### The spend

| Item | Provisional size | Basis |
|---|---|---|
| Engine code (Skia + Dart runtime + libtxt + HarfBuzz + platform) | **~11 MB** | `libflutter.so` armv7 release measured at 11.1 MB on Flutter 3.29.3. Static link with dead-code elimination should be the same order. |
| `icudtl.dat` (full) | **~10.3 MB** | The file shipped in `ardera/flutter-engine-binaries-for-arm`. Reducible — upstream has an open thread on exactly this. |
| AOT snapshot, counter app | a few MB | Unmeasured. Must be measured; see [ADR-0005](adr/0005-aot-snapshot-delivery.md). |
| AOT snapshot, mid-complexity app | ~10 MB order | Unmeasured, and constrained by the 16 MiB VM-block cap under Option B. |
| Framebuffers | **~6.3 MB** | 960×544×4 B = 2.09 MB, triple-buffered; less if double. |
| Skia raster surface + layer surfaces | tens of MB | Workload dependent. |
| Dart heap | tens of MB | Tunable via isolate heap caps. |
| Skia resource cache, glyph atlas, image decode | tens of MB | Tunable; the plan already calls for caps. |
| Thread stacks | small but pre-committed | Depends on thread count — see below. |

**Provisional conclusion: total memory is probably _not_ the binding
constraint.** The fixed costs land near 30 MB against a budget in the hundreds.
This is the single most reassuring finding so far, and it demotes the plan's
memory anxiety relative to its CPU anxiety.

**The two real constraints look like:**

1. **CPU throughput** for software rasterisation — see [ADR-0006](adr/0006-performance-bar-set-from-measurement.md).
2. **The 16 MiB `sceKernelAllocMemBlockForVM` cap**, which under Option B is a
   ceiling on Dart code size per app — see [ADR-0005](adr/0005-aot-snapshot-delivery.md).

---

## Exit criteria

Each item names the artefact that proves it.

### 1. VM domain spike — *blocks [ADR-0005](adr/0005-aot-snapshot-delivery.md), reshapes Phases 3 and 4*

A plain C `.vpk`, no Dart, on **real hardware**, that:

- [ ] writes a trivial armv7 function into a `sceKernelAllocMemBlockForVM` block,
      calls `sceKernelOpenVMDomain` + `sceKernelSyncVMDomain`, executes it, prints the result
- [ ] reports the largest single VM block obtainable under enlarged memory mode
- [ ] confirms a running thread survives an `Open`/`CloseVMDomain` cycle

*Estimated: 1–2 days. Highest information-per-hour item in the project.*

> **This one cannot be done on Vita3K.** `sceKernelOpenVMDomain` and
> `sceKernelCloseVMDomain` are `UNIMPLEMENTED()` there and return success, and
> the 16 MiB cap is not enforced — so the spike passes on the emulator while
> proving nothing. See [Vita3K as a target](vita3k-as-a-target.md).

### 2. Raster throughput number — *blocks [ADR-0006](adr/0006-performance-bar-set-from-measurement.md)*

- [ ] Skia CPU raster timings for representative scenes at 960×544 on an armv7
      Cortex-A7/A9 board, normalised to 333 MHz and 500 MHz
- [ ] a stated answer to: is a full-screen repaint ~5 ms, ~50 ms, or ~500 ms?
- [ ] confirmation that the software path honours damage regions rather than
      repainting full-screen every frame

### 3. Real size numbers

- [ ] Build the engine for `linux-arm` with the intended flags; read `size` off
      the archive. Replaces the 11 MB estimate with a measured figure.
- [ ] Determine how small `icudtl.dat` can get while keeping line breaking and
      word segmentation correct for Latin + the scripts v1 claims to support.
- [ ] `gen_snapshot` a counter app and a mid-complexity app for armv7; record
      `isolate_snapshot_instructions` size for both. Compare against 16 MiB.

### 4. Memory budget confirmation

- [ ] Exact base and enlarged user budgets for the target firmware
- [ ] Whether a homebrew title actually receives the enlarged budget it requests
- [ ] Largest single contiguous `sceKernelAllocMemBlock` obtainable, by type
      (`USER_RW`, CDRAM, PHYCONT) — Dart's heap wants large aligned regions, and
      if the largest block is smaller than the heap we need, `virtual_memory_vita.cc`
      becomes a multi-block allocator and a much harder file than the plan implies

### 5. Float ABI confirmation — *cheap to check, catastrophic to get wrong*

- [ ] Confirm Dart's armv7 codegen emits calling conventions matching VitaSDK's
      hard-float NEON/VFPv3 default. A softfp/hardfp mismatch links cleanly and
      silently passes garbage doubles across the Dart↔C boundary. Debugging that
      inside M1 would cost weeks.

### 6. Thread budget

- [ ] Count OS threads at steady state: Dart mutator, GC helpers, concurrent
      marker/sweeper, plus engine platform/UI/raster/IO runners
- [ ] Confirm the Vita's thread count limit and per-thread stack commitment
- [ ] Decide which task runners are merged, and whether the threading substrate
      is raw `sceKernel*`, VitaSDK's pthread shim, or unavoidably both
      (engine C++ `std::thread`/`std::mutex` will pull in the shim regardless)
- [ ] Determine how many of the 4 cores homebrew actually gets — the OS reserves
      some — and what `thread_local` compiles to under VitaSDK, since Dart uses
      TLS on hot paths

---

## Sources

- https://docs.vitasdk.org/group__SceSysmemUser.html
- https://docs.vitasdk.org/kernel_2sysmem_8h_source.html
- https://github.com/ardera/flutter-engine-binaries-for-arm/issues/2
- https://wiki.henkaku.xyz/vita/Memory_budget (bot-walled at time of writing)
- https://www.industrialflutter.com/blogs/building-the-flutter-engine-for-embedded-hardware/
