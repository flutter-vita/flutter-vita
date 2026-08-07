# ADR-0006: The v1 performance bar is set from measurement, not asserted up front

**Status:** Accepted
**Date:** 2026-08-06

## Context

The plan contains two incompatible performance claims:

- Goal statement: *"laggy but working is acceptable"*
- Definition of Done item 2: *"Counter app: 60 fps"*
- §5 targets: *"simple UIs 60 fps; complex scrolling ≥ 20 fps software / ≥ 30 fps GL"*

The justification offered for feasibility is a comparison to flutter-pi on
"Pi Zero class hardware". That comparison does not support the claim:

- The stated raster cost, "~2 MP", is wrong. 960×544 is **0.52 MP**. The figure
  4× too large looks like a bytes-per-pixel multiplication left in.
- **flutter-pi renders through GLES2 on the VideoCore GPU.** It is not a
  software-rasterisation data point, and this project's Phase 3 is software
  rasterisation ([ADR-0003](0003-software-rendering-first.md)).
- Pi Zero is a 1 GHz ARM11; the Vita is 4× Cortex-A9 at 333–500 MHz, a
  user-adjustable range rather than a single number.

So the headline feasibility argument for the decision shaping all of Phase 3
rests on a mis-stated figure and a non-comparable system. Setting a numeric
target on that basis would be inventing a requirement.

## Decision

**Do not commit to an fps figure until Phase 0.5 produces a measured raster
throughput number.** Remove "60 fps" from the Definition of Done and replace it
with a placeholder that Phase 0.5 fills in.

Until then the honest v1 bar is the goal statement's: *runs, is usable, is
laggy.* That is a falsifiable bar — "a user can operate the counter app without
input feeling dropped" — and it does not pretend to precision we have not earned.

## The measurement arrived — 2026-08-07

Track A run 1, real hardware, 960×544 at 444 MHz: present blit 8.04 ms
(bandwidth-bound), naive full-screen alpha blend 15.20 ms (compute-bound).

**The bar this sets:**

| target | verdict |
|---|---|
| 60 fps, full-screen repaint | **impossible** — the 8 ms blit is half the 16.7 ms budget before Skia runs |
| 30 fps, full-screen repaint | **plausible** — 8 ms blit leaves ~25 ms for raster |
| 60 fps with damage-limited repaint | **plausible** for small damage — the counter-app case |

So the honest v1 bar is: **30 fps floor for full-screen work; 60 fps only where
damage is small.** That is falsifiable, it is derived from hardware rather than
asserted, and it makes [ADR-0007](0007-enable-partial-repaint-in-software-path.md)
load-bearing rather than optional.

The Definition of Done's "counter app: 60 fps" is reachable **only** with
partial repaint. Without it the same app is a 30 fps proposition.

Two further findings worth carrying into Phase 3:

- Overclocking helps rasterisation and does essentially nothing for the blit,
  so PSVshell is not a general answer to slowness.
- The blit achieves ~460–500 MB/s against 3.2 GB/s theoretical (~15%). A
  NEON-optimised blit is worth real effort — possibly the cheapest large win
  available in the embedder.

## How the number gets set (Phase 0.5)

Measure Skia CPU raster throughput for representative Flutter scenes at
960×544, on armv7 at a clock comparable to the Vita's. Any cheap Cortex-A7/A9
board works; the absolute number is scaled by clock, and what matters is the
order of magnitude — is a full-screen repaint 5 ms, 50 ms, or 500 ms?

That single number decides:

- whether 60 fps is available for near-static UIs (likely — a counter app
  repaints almost nothing, and Flutter only re-rasterises dirty regions);
- whether scrolling is viable at all in software;
- whether the 720×408-and-upscale fallback moves from contingency to baseline;
- whether GLES2 must move from Phase 5 into Phase 3
  ([ADR-0003](0003-software-rendering-first.md) revisit trigger).

## Consequences

- The Definition of Done is temporarily incomplete. That is correct: it was
  previously complete and wrong.
- Any performance claim in a README or VitaDB listing must cite the hardware and
  the scene it was measured on. No unqualified "60 fps" ever.
- Partial repaint behaviour matters far more here than on GPU platforms. Whether
  the software path preserves damage regions rather than repainting full-screen
  each frame is worth verifying early — it is plausibly the difference between
  usable and not.

## Related

[ADR-0003](0003-software-rendering-first.md)
