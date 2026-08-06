# ADR-0007: Patch the engine to enable partial repaint in the software path

**Status:** Proposed — needs a hardware raster measurement to size the payoff
**Date:** 2026-08-06

## Context

Phase 0.5 / B4 went looking for the cost of a frame and found something more
important than a timing number: **the Flutter software rendering path
re-rasterises the entire screen on every frame.**

Evidence from the pinned engine:

- `flow/surface_frame.h` — `bool supports_partial_repaint = false;` is the
  default for `SurfaceFrame::FramebufferInfo`.
- `shell/gpu/gpu_surface_software.cc` — constructs its `FramebufferInfo` and sets
  **only** `supports_readback = true`. It never sets `supports_partial_repaint`,
  so the software path takes the `false` default.
- `shell/platform/embedder/embedder_surface_software.cc` — by contrast,
  `AcquireBackingStore` **does** retain `sk_surface_` between frames when the
  size is unchanged. The persistent surface that partial repaint would need
  already exists.
- `embedder.h` — `FlutterSoftwareRendererConfig` has exactly one callback,
  `surface_present_callback`, documented as presenting "a fully populated
  buffer". The damage API (`FlutterDamage`, `frame_damage`, `buffer_damage`,
  `populate_existing_damage`) is built around an **FBO ID**, i.e. it is the
  OpenGL path's facility. Software has no equivalent.

So the software backend leaves partial repaint on the table twice: it redraws
every pixel, and it presents every pixel.

### Why this matters more on Vita than anywhere else

960×544 is 522,240 pixels, 2.09 MB at 32bpp. The Vita's main memory is
2×256 MB LPDDR2 at 400 MHz, **3.2 GB/s theoretical**. The unavoidable per-frame
traffic for full-screen software rendering:

| | per frame | at 60 Hz | at 30 Hz |
|---|---|---|---|
| Skia rasterises the surface (write) | 2.09 MB | 125 MB/s | 63 MB/s |
| Present blit (read + write) | 4.18 MB | 251 MB/s | 125 MB/s |
| **Minimum total** | **6.27 MB** | **376 MB/s** | **188 MB/s** |

376 MB/s is ~12% of theoretical bandwidth, but Cortex-A9 class systems
realistically achieve well under half of theoretical — so this is plausibly
30–40% of the real memory system **before Skia blends, fills, or draws a single
glyph**. At 30 Hz it is comfortable.

The conclusion from bandwidth alone: **compute, not bandwidth, will be the
limit** — but full-screen-every-frame spends a meaningful fraction of the
machine on pixels that did not change.

### The assumption this invalidates

The Definition of Done's "counter app: 60 fps" implicitly assumed a near-static
UI is nearly free. It is not, under the current software path. A counter app at
*rest* costs nothing, because Flutter produces no frames when nothing changes.
But every Material tap animation — ink splash, ~200–300 ms — is 12–18 **full
screen** rasters for a change confined to a small region.

## Decision (proposed)

Add a patch to `patches/engine/` that sets `supports_partial_repaint = true` for
the software surface, and plumb a damage rectangle through to the embedder so
the present callback can blit only the changed region.

This is likely the single highest-value engine patch this project will make. The
retained `sk_surface_` means the hard prerequisite is already satisfied; the work
is reporting existing damage and clipping the raster.

## Why this is Proposed and not Accepted

The size of the payoff depends on the per-pixel raster cost, which is unmeasured.
If a full-screen raster turns out to cost 15 ms on hardware, this patch is a
nice-to-have. If it costs 200 ms, it is the difference between a usable project
and a dead one. **Measure first** — consistent with
[ADR-0006](0006-performance-bar-set-from-measurement.md).

Note also that upstream chose `false` deliberately for software; there may be a
correctness reason (e.g. embedders that do not preserve buffer contents between
presents). Our embedder controls the framebuffer entirely, so we can guarantee
preservation — but the patch must not be written as if upstream simply forgot.

## Related

[ADR-0003](0003-software-rendering-first.md),
[ADR-0006](0006-performance-bar-set-from-measurement.md)
