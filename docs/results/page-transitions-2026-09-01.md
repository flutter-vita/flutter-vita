# The transition this port picks by default is the one that exhausts the heap

The port reports `TargetPlatform.linux` (ADR-0008). Material's default page
transition for Linux is `ZoomPageTransitionsBuilder`, so every `MaterialPageRoute`
in every app on this console is a Zoom transition that nobody chose, and every
route number this project has published is a Zoom number.

Measured on 2026-09-01 with the gallery's new transition scenes: **the same
page**, the shape of `route_boxes`, pushed and popped nine times through six
different transitions, each run on a fresh launch so nothing inherits the
previous scene's memory.

## What was measured

| transition | worst | stall | ui / raster | native heap across the scene |
|---|---|---|---|---|
| none (`route_tx_none`) | 83.3 | — | — | flat |
| **Zoom** (the default) | **50.0** | **0.0** | 0.7 / **1.5** | **6M → 46M, never reclaimed** |
| Zoom, `allowSnapshotting: false` | 50.0 | 116.7 | 1.4 / **14.2** | 8M → 55–62M, churning, arena to 82M |
| FadeForwards | 100.0 | 83.3 | 1.4 / 6.9 | flat 14–18M |
| FadeUpwards | 100.0 | 183.3 | 0.8 / 4.8 | flat |
| Cupertino | 83.3 | 66.7 | 1.6 / 6.0 | flat |

`heap` is `mallinfo().uordblks` from the embedder's own present log — the native
C heap, where Skia's caches and FreeType live. Not the Dart heap, so this is not
collection lag.

`route_tx_none` produced 14 frames in 466 ms and the report refuses to grade it.
That is correct and expected: with no transition there is nothing to sample. Its
83.3 ms is the frame that builds the incoming page, which is the number the
other five should be read against.

## Zoom is the fastest and it is the one that kills the console

This is a trade, not a mistake anyone made carelessly. Zoom rasterises the
entering and exiting routes into offscreen images and animates those, so its
raster thread does 1.5 ms of compositing where Cupertino does 6.0 and re-drawing
the live tree does 14.2. It is the only transition measured that stalls for
zero milliseconds.

It also grows the native heap by about **4.4 MB per push-and-pop cycle and never
gives it back.**

Nine cycles of it took the heap from 6 MB to 46 MB. A full 34-scene suite run
earlier the same day did not survive that: `route_wrap` and `route_spans`, both
ordinary `MaterialPageRoute` scenes and both in the baseline since 2026-08-25,
took the heap from 8 MB to the **159 MB ceiling in twelve seconds**, and every
scene after them ran on a full heap. Four minutes later the UI thread was here
and had produced no frame since:

    sk_realloc_throw
    ft_mem_qrealloc -> ft_mem_realloc -> FT_GlyphLoader_CheckPoints
    cf2_builder_lineTo -> cf2_glyphpath_hintPoint -> cf2_builder_moveTo

Blocked asking FreeType for memory that was not there. Raster idle, all four
cores above 90% idle, `reserve_fail=0`, `vgl_oom=0`. No GL fault of any kind.

## `allowSnapshotting: false` is not the fix

It stops the monotonic growth and replaces it with churn — used memory
oscillating 51–62 MB while the arena climbs to 82 MB — and it costs 9x on the
raster thread (1.5 ms to 14.2) and 117 ms of stall where there was none. It
trades a leak for slow frames and still uses more memory than any other option.

## What is not yet known

**Why the snapshots are never freed.** 4.4 MB a cycle is close to two
full-screen 960x544 RGBA buffers (2.09 MB each), which is what Zoom snapshots
per push. Whether Skia's resource cache is failing to purge them or the
`ui.Image`s are never disposed has not been established, and the mechanism
matters: if it is a general failure to release rasterised images, it is not
confined to page transitions.

**Why `route_bare` does not leak.** Its page is an AppBar and a `ColoredBox`,
pushed through the same Zoom, and its heap is flat at 6M across six samples. A
snapshot of a trivial page is the same 960x544 as any other.

**`route_bare`'s own worst frame is unstable across runs** — 16.7 ms when the
run began with a deploy, 133.3 ms when it began with a relaunch, first scene in
both. Unexplained, and the same shape as the bimodality
[apps/gallery/bench/README.md](../../apps/gallery/bench/README.md) records for
`route_wrap`.

## What this changes

The bimodality note in the bench README attributes `route_wrap`'s split
distribution — three pushes at 27 ms, five at 14.5 — to "Dart GC landing on a
build frame", flagged there as a hypothesis nothing had measured. It is now more
likely that those runs were measuring a heap filling up underneath them.
`route_wrap` was scene 12 of 18 in the old order, so the ceiling would have been
reached around `route_text_uniq` with several scenes still to run.

**The 2026-08-25 GL baseline was taken with this happening**, which is reason to
treat its later route scenes as worth less than they look, and reason not to
re-baseline until the leak is understood.

## The decision this leaves

Changing the port's default away from Zoom is a visible product change to every
app, not a bug fix, and it is not free: the alternatives all stall where Zoom
does not. The options are

1. **Leave Zoom and fix the retention.** Correct, and the only one that keeps
   the smooth transition. Cost unknown until the mechanism is found.
2. **Default to Cupertino.** Best of the bounded three: 83.3 ms worst, 66.7 ms
   stall, flat memory. Slides rather than zooms, which is a different look.
3. **Default to FadeForwards.** Material's own newer transition, flat memory,
   83.3 ms of stall.

Nothing here recommends `allowSnapshotting: false`.
