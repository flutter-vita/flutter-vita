# ADR-0003: Software raster first, vitaGL/GLES2 second

**Status:** Accepted
**Date:** 2026-08-06 (back-filled from `Flutter Vita Plan.md` §1)

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

## Revisit trigger

If the M3 baseline measurement shows the software path cannot reach the
"laggy but working" bar on a counter app, GLES2 stops being an optimisation and
becomes a Phase 3 blocker. That reordering should be an explicit new ADR.

## Related

[ADR-0002](0002-skia-not-impeller.md)
