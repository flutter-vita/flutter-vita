# ADR-0014: The raster pass is the bottleneck, so the GPU becomes the target

**Status:** Accepted — direction settled by measurement; engine work gated on a
spike with the exit criteria below
**Date:** 2026-08-21

## Context

[ADR-0003](0003-software-rendering-first.md) shipped software rasterisation and
parked GLES2 as "a Phase 5 optimisation, measured against the software baseline
per workload rather than adopted wholesale". Its revisit trigger asked for
exactly this document:

> If the M3 baseline measurement shows the software path cannot reach the
> "laggy but working" bar on a counter app, GLES2 stops being an optimisation
> and becomes a Phase 3 blocker. **That reordering should be an explicit new
> ADR.**

Until 2026-08-21 the trigger could not be evaluated, because nothing separated
raster cost from everything else in a frame. The engine now times the raster
pass — `AcquireFrame` to the end of the encode callback — independently of the
present. That closes the question.

## The measurement

```
localsend, Receive screen:
FRAMES active 60 @ 205034 us = 4.87 fps (raster 199559 us = 97%, blit 1278 us = 0%, dmg 13%)
```

An active frame is raster + present + everything else, where "everything else"
is the UI thread: Dart building and laying out. The split is **97% / 0.6% /
~3%**.

| App / screen | dmg | raster | blit |
|---|---|---|---|
| manga_reader, idle | 0% | 704 us | 2 us |
| manga_reader, library | **5%** | **13,933 us** | 553 us |
| manga_reader, scrolling | **89%** | **13,965 us** | 9,713 us |
| localsend, Receive | 13% | **199,559 us** | 1,278 us |

Read the middle two rows together: **5% damage and 89% damage cost the same
raster.** Eighteen times the area, identical cost. The blit tracks area
faithfully — 553 us against 9,713 us — because a memcpy is honest about how
many bytes it moves. Raster is not, because **area is not work**.

What is inside localsend's 13% is one widget:

```dart
Transform.rotate(               // 30 fps tick
  child: ColorFiltered(         // forces a saveLayer
    colorFilter: ColorFilter.mode(primary, BlendMode.srcATop),
    child: Assets.img.logo512.image(width: 200, height: 200),  // 512 -> 200
  ),
)
```

Removing only the `ColorFiltered` and rebuilding took raster from ~199,000 us
to ~110,000 us. So the colour filter is roughly half, and the rotated downscale
is the other half. **Both are single-pass operations on any GPU**, and both are
worst-case for a CPU rasteriser: an offscreen allocation, a filter over every
pixel of it, and bilinear resampling through a matrix that changes every frame
so nothing caches.

## The two cheaper alternatives are now measured, and both fail

ADR-0003 named both. Neither survives the numbers.

**A NEON blit — ADR-0003's "cheapest large win in the embedder" — is now worth
nothing.** That recommendation was made when the blit was 8.06 ms of a
full-screen frame. [ADR-0007](0007-enable-partial-repaint-in-software-path.md)
then made the blit proportional to damage, and it is now **0.6%** of
localsend's frame and 2% of manga_reader's quiet one. Optimising it perfectly
buys under 1%. This is a good outcome recorded plainly: one ADR obsoleted
another's headline recommendation, and only measurement noticed.

**Reduced-resolution rendering is insufficient on its own.** 720×408 is 1.78×
fewer destination pixels. Even assuming raster scaled linearly with them — and
the 5%-equals-89% result says it does not scale with *area* at all — localsend
goes from 200 ms to ~112 ms, which is 8.9 fps. Reaching 30 fps needs raster
under ~30 ms, a 6.7× reduction. Resolution offers 1.78×. It remains genuinely
useful for manga_reader, where ~14 ms would become ~8 ms and 60 fps comes into
reach, so this is a **per-workload** tool, not a solution.

Neither is a path to a general fix, and that is the point: both scale the
existing cost down by a constant, while the problem is that certain *operations*
cost hundreds of times what they should.

## Feasibility, checked rather than assumed

ADR-0003's own GN comment still says the opposite of what is true:

> Software rasterisation only, per ADR-0003. The Vita's GPU is reachable
> **solely through libgxm — there is no GL, GLES, Vulkan or Metal driver on the
> device** […]
> — `flutter/tools/gn`, the `target_os == 'vita'` branch

That premise is stale. Checked on this machine:

| Question | Answer |
|---|---|
| Is there a GLES driver? | **Yes.** `libvitaGL.a`, `vitaGL.h` and a `GLES2/` include tree are already installed in VitaSDK |
| Does it conflict with [ADR-0004](0004-static-single-binary.md)? | **No.** vitaGL ships as a **static archive**. No `dlopen`, no shared object |
| Is Ganesh even compiled? | **Yes, already.** The vita GN branch sets `skia_enable_ganesh = True` with every backend off, because the engine assumes `GrDirectContext` as a *type* far more widely than it assumes a GPU |
| Do Ganesh GPU objects link for this target? | **Yes.** `gpu.LatticeOp.o` is in the shipped static archive today |
| Then what was the `dangerous relocation` link failure? | **Incidental.** `ninja -t query` names its consumers as `geometry_benchmarks` and **`libtessellator.so`** — a benchmark and a *shared library*. BFD aborted inside `elf32_arm_add_dynreloc`, emitting **dynamic** relocations for a link mode ADR-0004 means this port never performs. Neither target is ever built here |
| Is partial repaint lost on GL? | **No.** `FlutterOpenGLRendererConfig` carries `present_with_info` and `populate_existing_damage` precisely for dirty-region management |

That last row corrects a fear worth naming, because the software surface's own
comment invites it: *"the GL and Metal embedders cannot make that promise, since
they present by swapping buffers"*. That is about
`BackingStoreRetainsPreviousFrame` — handing back one surface forever — not
about damage support. The GL path tracks existing damage **per back buffer**
instead, which is more work in the embedder but is the supported, upstream way.

## Decision

**The GPU is now the primary performance target, and Skia Ganesh over vitaGL is
the route.** GLES2 is reordered from "Phase 5 optimisation" to the next major
engine work item, which is the reordering ADR-0003 asked to be made explicit.

**Engine work is gated on a spike**, because the feasibility table above
establishes that nothing *forbids* this and says nothing about whether vitaGL
serves what Ganesh asks for. The spike is not the port; it is the smallest
program that answers that. Exit criteria, all on real hardware:

1. A vitaGL GLES2 context initialises, and `libshacccg.suprx` compiles a
   trivial shader at runtime. (The module is user-installed; the community
   already relies on it, so this is not a reason to stop — but it is a
   dependency to state.)
2. Skia builds with `skia_use_gl = true` and `skia_gl_standard = "gles"` for
   `target_os = vita`, and a `GrDirectContext` is successfully created on a
   vitaGL context.
3. Skia draws the three operations that dominate the measurement above —
   `saveLayer`, a colour filter, and a rotated downscale of a 512×512 image —
   and the output is correct.
4. The same three are timed against the software path. **The bar is 10×**, not
   "faster": below that, the binary-size and complexity cost is not obviously
   worth it and the per-workload tools above deserve another look.

If the spike passes, the engine work is: a `FlutterOpenGLRendererConfig` path in
`vita_embedder.cc`, `populate_existing_damage` against GXM's buffering, and the
GN branch above rewritten with its stale premise removed.

## Consequences

- **[ADR-0003](0003-software-rendering-first.md) is not superseded.** Its
  decision — ship software first — was correct and is why there is a working
  port to measure. What changes is the ordering it deferred, exactly through
  the mechanism it specified.
- **The software path stays.** It is the fallback when `libshacccg.suprx` is
  absent, and `shell_enable_software` remains true regardless. Two paths is
  more embedder surface, and that cost is accepted.
- **`libshacccg.suprx` becomes a runtime dependency for the fast path.** An app
  must still start and render without it.
- Binary size grows by Skia's GL backend. Memory is not the binding constraint
  — 188 MiB largest contiguous, and the engine is ~14.5 MiB resident — so this
  is a download-size concern, not a device one.
- The Vita's GPU is a **tile-based deferred renderer**. Skia's GL backend
  assumes immediate-mode in places, and readbacks are disproportionately
  expensive on TBDR. Expect this to be where the spike actually gets hard.
- [ADR-0002](0002-skia-not-impeller.md) is untouched: this is Ganesh, Skia's
  GPU backend, not Impeller. Impeller has a GLES backend and is where upstream
  is investing, which is a real argument to revisit — but not one to take on
  the same day as reordering the renderer.

## The bound on this conclusion, stated honestly

localsend's headline number is dominated by **one pathological widget**. A GPU
fixes it; so would deleting one `ColorFiltered`. Anyone reading "97%" as "Flutter
is slow on Vita" has read too much into it.

The claim this ADR actually rests on is narrower and better supported:
**the software rasteriser's cost is driven by what is drawn, not how much**, and
the operations that hurt it — saveLayer, filters, resampling under a changing
transform — are the ones hardware performs for free. manga_reader's
5%-costs-as-much-as-89% pair is the cleaner evidence, because nothing
pathological is involved in it.

## Revisit trigger

- **The spike fails criterion 4.** If vitaGL plus Ganesh is under 10× on those
  three operations, this ADR is wrong and the answer is per-workload work:
  reduced resolution for fill-bound screens, and a `psvita` lint or widget set
  that steers apps away from the operations that hurt.
- **`libshacccg.suprx` becomes unavailable or unacceptable.** Then Ganesh has
  no runtime shader compiler and the route is a precompiled shader cache, which
  is a materially different project.
- **Upstream removes the Ganesh GL backend.** Skia is investing in Graphite and
  Flutter in Impeller. [flutter-upgrade-cost.md](../flutter-upgrade-cost.md)
  shows Impeller took 336 files and +13,110 lines in one release window while
  the Skia software path took 5 insertions. If GL goes, the question reopens as
  Impeller-GLES versus staying on CPU.

## Related

- [ADR-0002](0002-skia-not-impeller.md) — Skia, not Impeller; unchanged here
- [ADR-0003](0003-software-rendering-first.md) — the decision this reorders, through its own trigger
- [ADR-0004](0004-static-single-binary.md) — why vitaGL being a static archive matters
- [ADR-0006](0006-performance-bar-set-from-measurement.md) — the bar this is measured against
- [ADR-0007](0007-enable-partial-repaint-in-software-path.md) — made the blit small, and thereby obsoleted the NEON-blit recommendation
- [corpus-localsend-2026-08-19.md](../results/corpus-localsend-2026-08-19.md) — the raster attribution in full
