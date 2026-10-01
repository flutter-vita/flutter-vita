# What the console said about culling and two-sided stencil

**2026-09-24.** The depth and stencil work of 2026-09-23 ran on hardware for
the first time. The surfaces, the renderbuffers and the clears were correct on
the first run. Culling was not, for three reasons, and all three are now
closed. `engine/gles2/test` M6 passes 58 of 58 on both targets.

## The three findings

**`SCE_GXM_CULL_CW` names the winding the hardware keeps.** The SDK header
says "clockwise hardware culling", and the first version of `cull_mode_of`
read that as "clockwise faces are removed". It is the other way round: the
enum names the front face. With `glFrontFace(GL_CCW)` and `glCullFace(GL_BACK)`
the counter-clockwise quad disappeared and the clockwise one stayed.

**`glFrontFace` did not mark the raster state stale.** It decides the cull
mode now, and it was written before there was one. The second pair of quads
kept the first pair's cull mode and passed by luck. `glPolygonOffset` had the
same gap.

**Two-sided stencil is off until `sceGxmSetTwoSidedEnable` turns it on.** Off
means every triangle takes the front state, whatever its winding. Turning it
on showed a second fault behind the first: the side mapping assumed
`glFrontFace(GL_CCW)`. Which of the hardware's two sides carries GL's front
now follows `glFrontFace` as well as the target.

## How the test found them

M6 draws the same picture twice: on the display, which is drawn bottom-up, and
on a 256x256 texture with a depth and stencil renderbuffer, which is not. The
rasteriser disagrees with GL about which winding is front on one of the two
and agrees on the other.

That is what made the first failure readable. **Both targets failed alike.**
If the per-target flip had been wrong, one would have failed and one would
have passed. Failing together says the fault is the global sense, and the
global sense is one line.

The second failure read the same way, in the other direction. The front-facing
and the back-facing box came out **alike on each target and opposite between
them**: no two-sided mode anywhere, and the front state going to opposite
sides on the two targets.

| what failed | what it meant |
|---|---|
| both targets, the same way | the global sense, not the per-target flip |
| both targets, opposite ways | the per-target mapping |
| one target only | that target's flip |

## What was right first time

The packed 24-bit depth with 8-bit stencil surface, tiled, in whole 32x32
tiles. The display's lazy allocation. Renderbuffer objects, their reported
size and bit counts, `glCheckFramebufferStatus`, and `GL_DEPTH_BITS` and
`GL_STENCIL_BITS` answering for the bound framebuffer. `glClear` of all three
buffers, including a scissored clear of the depth buffer alone that let a far
quad through in one corner and nowhere else. All of it on both targets.

## The bench, and a baseline that is not comparable

The layer is in the path of every draw, so the gallery ran the 36-scene bench
after the fixes. The report named six regressions against the baseline of
2026-09-23, three of them raster.

**None of them are the layer's.** The gallery was built again with
`gles2` at `3299ab5`, the state before any of this work, and benched on
the same console in the same sitting. It regresses on the same scenes at the
same sizes, and on two more that the new layer did not touch:

| scene | metric | new layer, run 1 | new layer, run 2 | layer at `3299ab5` |
|---|---|---|---|---|
| `route_text_uniq` | raster | 1.9 -> 9.6 ms | not flagged | 1.9 -> **9.5 ms** |
| `route_grid_bare` | raster | 2.1 -> 6.5 ms | 2.1 -> 5.7 ms | 2.1 -> **6.9 ms** |
| `route_tx_fade_fwd` | raster | 4.9 -> 9.4 ms | not flagged | 4.9 -> **8.2 ms** |
| `save_layer_tint` | raster | not flagged | not flagged | 2.2 -> **7.3 ms** |
| `spinner` | worst | not flagged | not flagged | 50.0 -> **83.3 ms** |

Three runs, one of them without the change, and the scene set moves between
them. The console is slower today than it was on 2026-09-23, for both layers.

The header fields agreed on all four counts: same engine `ff08f75c81`, same
clocks `arm 444 MHz, gpu 222 MHz`, same method `b34de93c`, same 36 scenes. So
the gate passed the run as comparable and it was not. **A baseline from
another day is not comparable to one from today even when every recorded
field agrees.** The console was run flat and recharged between the two dates,
and nothing in the report records that.

This is the second time a number was almost read as a regression that was not
one. The first was `list_churn` on 2026-09-23. Both times the answer was to
measure the spread before believing one run.

The day-to-day difference is not going to be chased. The answer is a stable
suite, not an explanation of one afternoon: a measurement that moves this much
between two runs of the same code cannot gate anything, whatever the cause.
That work is on the list and this document does not block on it.

## The gallery on the new layer

Built, deployed and running: 60 fps on the PANEL tab, text fields, switch,
slider and spinner all drawn correctly. The layer is in the path of every draw
in that frame.

## What is left

The benchmark needs tests that hold still. Until it has them, the A/B above is
the method: build the previous revision of the changed code, run it on the
same console in the same sitting, and compare the two runs against each other
rather than against a stored file. No new baseline was taken.

`glGenerateMipmap` is still the one recording stub in the layer. A mip chain
needs a layout other than `LINEAR_STRIDED`, and the packing rule for the
levels of a Vita texture is not in the SDK headers, so it has to be measured
on a console first. Nothing calls it.
