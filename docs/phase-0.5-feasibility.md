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

**A2. Fold a raster micro-benchmark into the same program** (exit criterion 2).

B4 established that bandwidth is not the limit and *compute* is, but the
per-pixel cost cannot be measured without a real Cortex-A9. You have a Vita, and
A1 is already a C program running on it — so measure it there rather than buying
a Raspberry Pi to approximate a machine you own.

Measure at 960×544, at both 333 MHz and 500 MHz:

- [ ] `memcpy` of a 2.09 MB framebuffer — the floor for the present blit, and
      the sanity check on the 3.2 GB/s theoretical figure
- [ ] solid-colour fill of the same buffer
- [ ] a naive per-pixel alpha blend over the whole buffer — a crude stand-in for
      what Skia does when compositing layers
- [ ] the same three at 720×408, to price the downscale-and-upscale fallback

This does not give a Skia number, but it brackets one: if a plain `memcpy` of
the framebuffer already costs 10 ms, full-screen 60 fps is arithmetically dead
and [ADR-0007](adr/0007-enable-partial-repaint-in-software-path.md) is promoted
from Proposed to required. Cheap to write, and it turns
[ADR-0006](adr/0006-performance-bar-set-from-measurement.md) from a placeholder
into a real bar.

*Then, and only then, is Track A's information worth acting on.*

### Track B — host only, needs no Vita, start today

**B1. Fetch ardera's `arm/gen_snapshot_linux_x64_release` and produce an armv7
AOT snapshot of a pure-Dart hello world.** No Vita, no VitaSDK, no engine build.
This proves the entire host half of M1 in an afternoon and gives you a real
artifact to size and to link against later.

**B2. Record `isolate_snapshot_instructions` size** for that hello world, for a
counter app, and for something mid-complexity. Compare against 16 MiB
(exit criterion 3).

**B3. Build the engine for `linux-arm` and measure it** (exit criterion 3).

*Vita does not run Linux, and B3 produces nothing that ships on a Vita.* It is a
**measurement and a baseline**, not an artifact. Three reasons it earns its time:

1. **It gives a real armv7 size number.** How large Skia + Dart + libtxt +
   HarfBuzz compile to for armv7 barely depends on which OS they call into — the
   platform layer is a rounding error against the total. So `linux-arm` answers
   "how big is the engine on 32-bit ARM" without any VitaSDK work.
2. **It is a supported GN configuration that builds *today*.** No toolchain
   authoring, no newlib patches. That isolates variables: if `linux-arm` fails,
   the problem is your checkout or your host setup. On the Vita target,
   everything fails at once and you cannot tell which failure is which.
3. **It is the bisection baseline for Phase 2.** The Vita build differs from
   `linux-arm` in exactly two dimensions: the C library (glibc → newlib) and the
   OS API layer. With a known-good `linux-arm` build in hand, every Vita build
   failure can be diffed against a working configuration. Without one, Phase 2
   starts with no reference point at all.

**Why `linux-arm` and not `android-arm`,** which is also armv7 and also
supported: the `linux-arm` embedder configuration produces
`libflutter_engine.so` — the `embedder.h` API library — which is precisely the
class of artifact the Vita build must eventually produce. `android-arm` builds
the Android platform shell instead, which we will never use. flutter-pi is a
`linux-arm` embedder, so this is also the configuration with the most prior art
and a prebuilt binary to compare against.

> **The same discipline as [Vita3K](vita3k-as-a-target.md) applies here.** A
> green `linux-arm` build does **not** mean "the engine builds fine". It will
> not surface a single newlib gap, `sceKernel` threading problem, or memory-budget
> issue — those are the actual hard parts of Phase 2, and they are all in the two
> dimensions `linux-arm` holds constant. Use B3 for a number and a baseline.
> Never quote it as evidence that the Vita build will work.

**B4. Raster throughput number** (exit criterion 2). *Partially done — the
source-level half is complete and produced [ADR-0007](adr/0007-enable-partial-repaint-in-software-path.md);
see B4 results below. The remaining half is a per-pixel cost measurement, which
needs a real Cortex-A9 and has therefore moved into Track A.*

**B5. Float ABI check** (exit criterion 5) — can be reasoned about from the
Dart build flags plus VitaSDK's defaults before anything is compiled.

### ✅ B1 result — done 2026-08-06

**The host half of M1 works.** Reproducible via
[`spikes/b1-aot-snapshot/build.sh`](../spikes/b1-aot-snapshot/build.sh).

```
out/hello-armv7.elf: ELF 32-bit LSB shared object, ARM, EABI5 version 1 (SYSV)
```

| Section | Size | Meaning |
|---|---|---|
| `.text` | **352.1 KiB** (360,592 B) | AOT machine code — the part needing executable memory |
| `.rodata` | **261.9 KiB** (268,208 B) | Snapshot heap image — ordinary read-only data |
| total ELF | 825,688 B | unstripped, with debug info |

Findings:

- **Real armv7 code, generated on an Apple Silicon Mac.** ardera's
  `gen_snapshot_macos_x64_release` is an x86_64 Mach-O running under Rosetta;
  host architecture is irrelevant to the output, as expected of a cross compiler.
- **The pinned version is confirmed correct.** FVM's 3.44.8 reports revision
  `0cd610717b`, matching [VERSIONS.md](../VERSIONS.md) exactly, and ardera's
  `gen_snapshot` reports Dart 3.12.2 — the same Dart the SDK ships. The kernel
  format matched on the first attempt, so the version-pin reasoning holds.
- **A pure-Dart floor uses 2.15% of the 16 MiB VM-block cap.** Pure Dart is
  nowhere near the ceiling. This says nothing yet about Flutter, which pulls in
  the whole framework — that is B2.
- **We did not have to build the Dart SDK.** Phase 1 can begin against a real
  armv7 snapshot instead of a hypothetical one, exactly as
  [VERSIONS.md](../VERSIONS.md) predicted.

Note: the ELF form was used here only because it is the easiest to inspect.
Which form ships on Vita is still [ADR-0005](adr/0005-aot-snapshot-delivery.md).

### ✅ B2 result — done 2026-08-06

**The 16 MiB cap is not a problem.** A stock Flutter counter app, compiled to
armv7 AOT with `--target=flutter --aot --tfa` against the Flutter patched
product SDK. Reproducible via
[`spikes/b2-flutter-snapshot/build.sh`](../spikes/b2-flutter-snapshot/build.sh).

| | `.text` (instructions) | `.rodata` (heap image) |
|---|---|---|
| Pure-Dart hello world (B1) | 352 KiB | 262 KiB |
| **Flutter counter app (B2)** | **2.11 MiB** | **1.40 MiB** |
| *The Flutter framework tax* | *~1.8 MiB* | *~1.1 MiB* |

**13.2% of the 16 MiB VM block cap. 13.89 MiB of headroom.**

Findings:

- **The framework is a fixed cost of roughly 1.8 MiB of instructions**, and it
  dominates the counter app. App code is the only variable above that floor, so
  a mid-complexity app should land somewhere around 4–6 MiB — comfortably inside
  the cap. The counter app is effectively the floor for *any* Flutter app, which
  is why this single measurement resolves most of the question.
- **[ADR-0005](adr/0005-aot-snapshot-delivery.md) Option B is no longer
  size-constrained.** The only remaining blocker on it is whether VM-domain
  executable memory actually works on hardware — which is Track A, and which
  Vita3K cannot answer.
- Combined with B1's total, the entire Dart side of a Flutter app costs about
  **3.5 MiB** against a memory budget in the hundreds of MB. As with the engine
  binary, memory is not the binding constraint. **CPU throughput is** — see
  [ADR-0006](adr/0006-performance-bar-set-from-measurement.md), still unmeasured.

Caveat: these are unstripped snapshots, but `.text` and `.rodata` are the real
code and data sections — DWARF lives in separate `.debug_*` sections and is not
counted above. Shipping builds would additionally pass `--strip`.

### 🟡 B4 result (partial) — done 2026-08-06

Went looking for a timing number, found a structural problem worth more than one.

**The Flutter software path re-rasterises the whole screen every frame.**
`gpu_surface_software.cc` sets only `supports_readback = true` on its
`FramebufferInfo`, and `supports_partial_repaint` defaults to `false` in
`flow/surface_frame.h`. Meanwhile `embedder_surface_software.cc` *does* retain
`sk_surface_` between frames — so the prerequisite for partial repaint exists
and is simply unused. The `embedder.h` damage API
(`FlutterDamage`, `populate_existing_damage`) is built around an FBO ID and is
the OpenGL path's facility; software has no equivalent.

This invalidates the DoD's implicit assumption that a near-static UI is nearly
free. At rest a counter app costs nothing, because Flutter emits no frames when
nothing changes — but a single Material ink-splash tap is 12–18 **full-screen**
rasters for a change confined to a small region.
→ [ADR-0007](adr/0007-enable-partial-repaint-in-software-path.md).

**Bandwidth arithmetic says compute, not bandwidth, is the limit.** Vita main
memory is 2×256 MB LPDDR2 @ 400 MHz, 3.2 GB/s theoretical:

| | per frame | at 60 Hz | at 30 Hz |
|---|---|---|---|
| Skia rasterises the surface (write) | 2.09 MB | 125 MB/s | 63 MB/s |
| Present blit (read + write) | 4.18 MB | 251 MB/s | 125 MB/s |
| **Minimum total** | **6.27 MB** | **376 MB/s** | **188 MB/s** |

~12% of theoretical at 60 Hz, but realistically 30–40% of what a Cortex-A9 class
memory system actually achieves — and that is *before* Skia blends, fills, or
draws a glyph. At 30 Hz it is comfortable.

**Still open:** the per-pixel raster cost. It needs a real Cortex-A9, so it has
moved to Track A2 rather than being approximated on hardware you do not have.

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
| Engine code (Skia + Dart runtime + libtxt + HarfBuzz + platform) | **~11 MB** | `libflutter.so` armv7 release measured at 11.1 MB on Flutter 3.29.3. Static link with dead-code elimination should be the same order. ardera's arm `libflutter_engine.so.release` for 3.44.8 is 18 MB unstripped. |
| `icudtl.dat` (full) | **10 MB** | The file shipped in `ardera/flutter-engine-binaries-for-arm`. Reducible — upstream has an open thread on exactly this. |
| AOT snapshot, **pure-Dart hello world** | **352 KiB instructions + 262 KiB data** | ✅ **Measured** — see B1 results below. |
| AOT snapshot, **Flutter counter app** | **2.11 MiB instructions + 1.40 MiB data** | ✅ **Measured** — see B2 results below. |
| AOT snapshot, mid-complexity app | ~4–6 MiB instructions, extrapolated | The framework costs a fixed ~1.8 MiB; app code is the only variable. Still unmeasured, but the shape is now known. |
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
