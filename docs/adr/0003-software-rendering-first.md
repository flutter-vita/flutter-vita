# ADR-0003: Software raster first, vitaGL/GLES2 second

**Status:** Accepted
**Date:** 2026-08-06 (back-filled from `docs/plan.md` §1)

## Context

Two paths exist to get Skia output onto the Vita's display:

1. `FlutterSoftwareRendererConfig` — Skia rasterises into a CPU pixel buffer,
   the embedder blits that buffer into a GXM-managed framebuffer.
2. `FlutterOpenGLRendererConfig` — Skia's Ganesh GL backend on top of vitaGL,
   which translates GLES2 calls into GXM.

Path 1 has a far smaller unknown surface: no GL context management, no Skia GPU
backend build configuration, no vitaGL conformance questions. Path 2 is almost
certainly faster once working, but adds two large dependencies to the critical
path.

## Decision

Ship the software renderer first and treat GLES2 as a Phase 5 optimisation,
measured against the software baseline per workload rather than adopted
wholesale.

## Consequences

- Phase 2 can build Skia with GPU backends disabled, which cuts build
  complexity and binary size substantially.
- The frame budget is entirely CPU-bound: rasterisation, blit, and the Dart/UI
  work all contend for the same 4× Cortex-A9 cores.
- Performance targets in the plan (60 fps simple UI) are an unverified
  assumption under this decision, not a consequence of it. See grilling round 1:
  the flutter-pi comparison used to justify feasibility is not like-for-like,
  because flutter-pi renders through GLES2.
- The fallback of rasterising at reduced resolution (e.g. 720×408) and upscaling
  via GXM is available and cheap, because the blit path already exists.

## Update 2026-08-07: the reduced-resolution fallback is now the likely default

The plan listed "render at 720×408 and scale via GXM" as a contingency. Hardware
measurement makes it the front-runner. At 444 MHz, blit plus one full-screen
blend costs **33.83 ms (29.6 fps) at 960×544** but only **14.59 ms (68.5 fps) at
720×408**.

That is a 2.3× improvement for 1.78× fewer pixels — superlinear, and not fully
explained; likely DRAM page or TLB locality. Whatever the cause, it is the
difference between "marginal at 30 fps" and "comfortable at 60 fps", and the
GXM upscale is free because the blit path exists regardless.

Also measured: the blit is **bandwidth-bound** (8.83 ms at 333 MHz vs 8.06 ms at
444 MHz — a 33% clock increase buys 8%) while rasterisation is **compute-bound**
(blend 30.77 → 25.77 ms, near-linear). Two consequences: overclocking via
PSVshell helps rasterisation and does almost nothing for the blit, and at
~495 MB/s against 3.2 GB/s theoretical the blit is achieving ~15% of the memory
system — **a NEON-optimised blit may be the cheapest large win in the embedder.**

## Revisit trigger

If the M3 baseline measurement shows the software path cannot reach the
"laggy but working" bar on a counter app, GLES2 stops being an optimisation and
becomes a Phase 3 blocker. That reordering should be an explicit new ADR.

> **Triggered 2026-08-21, and the ADR exists: [ADR-0014](0014-gpu-backend-via-vitagl.md).**
> Timing the raster pass separately from the present put localsend's Receive
> screen at **raster 97% of the frame**, against a 0.6% blit. This ADR is not
> superseded — shipping software first was right, and is why there was
> something to measure — but the ordering it deferred has now flipped.
>
> Two things above are obsoleted by that measurement and should not be acted
> on. **The NEON blit is no longer "the cheapest large win in the embedder":**
> [ADR-0007](0007-enable-partial-repaint-in-software-path.md) made the blit
> proportional to damage, so it is now under 1% of a frame and optimising it
> perfectly buys nothing. **The 720×408 fallback is not sufficient on its own
> either** — 1.78× fewer pixels against the ~6.7× reduction localsend needs —
> though it remains useful per workload, and would plausibly take
> flutter_manga_reader to 60 fps.

## Related

[ADR-0002](0002-skia-not-impeller.md)
