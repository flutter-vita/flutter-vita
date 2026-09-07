# The transition this port picks by default is the one that exhausts the heap

> **Superseded in part, 2026-09-01 evening.** The leak described here is not
> Zoom's and has no ten-cycle threshold. It follows *position*: the second
> route scene in a process leaks about 12 MB a sample whichever scene it is,
> and the first never does. See
> [the-second-route-scene-2026-09-01.md](the-second-route-scene-2026-09-01.md).
> The timing figures below stand; the memory attribution does not.

The port reports `TargetPlatform.linux` (ADR-0008). Material's default page
transition for Linux is `ZoomPageTransitionsBuilder`, so every `MaterialPageRoute`
in every app on this console is a Zoom transition that nobody chose, and every
route number this project has published is a Zoom number.

Measured on 2026-09-01 with the gallery's new transition scenes: **the same
page**, the shape of `route_boxes`, pushed and popped nine times through six
different transitions, each run on a fresh launch so nothing inherits the
previous scene's memory.

## What was measured

| transition | worst | stall | raster | native heap across the scene |
|---|---|---|---|---|
| none (`route_tx_none`) | 83.3–233.3 | — | — | flat |
| **Zoom** (the default) | 50.0 / **133.3** | 0.0 / **217–250** | **1.3–1.9** | flat, **or** 6M → 46M — see below |
| Zoom, `allowSnapshotting: false` | 50.0 | 116.7 | **14.2** | 8M → 55–62M, churning, arena to 82M |
| FadeForwards | 100.0 | 83.3 | 6.9 | flat 14–18M |
| FadeUpwards | 100.0 | 183.3 | 4.8 | flat |
| Cupertino | 83.3 | 66.7–83.3 | 5.7–6.0 | flat |

Zoom was measured five times. **Its raster cost is the reliable part** — 1.3 to
1.9 ms every time, three to four times cheaper than anything else here, because
it composites two images instead of redrawing. Its frame timing is bimodal:
50.0 ms worst with no stall on two runs, 133.3 ms with 217–250 ms of stall on
three. An earlier version of this document reported the good mode as if it were
the only one, on the strength of a single run. It is not.

`heap` is `mallinfo().uordblks` from the embedder's own present log — the native
C heap, where Skia's caches and FreeType live. Not the Dart heap, so this is not
collection lag.

`route_tx_none` produced 14 frames in 466 ms and the report refuses to grade it.
That is correct and expected: with no transition there is nothing to sample. Its
83.3 ms is the frame that builds the incoming page, which is the number the
other five should be read against.

## The leak starts at the tenth Zoom cycle

The first nine Zoom push-and-pop cycles a process performs are free. Every cycle
after that costs about **4 to 6 MB of native heap that is never given back.**

This is why the leak looked like it belonged to a particular scene and does not.
Five runs, same build, same page, differing only in what ran before the measured
Zoom scene:

| Zoom cycles already performed | Zoom scene's heap |
|---|---|
| 0 (`route_tx_none` first, runs D and E) | flat 6M |
| 9 (`route_bare` first, runs B and B2) | 6M → 46M |
| 9, with nine non-Zoom cycles in between (run F) | 8M → 46M |

Deterministic in both directions, and run F settles the shape of it: the
threshold counts **cumulative Zoom cycles**, not consecutive ones. Nine
no-transition pushes in the middle change nothing.

That answers what an earlier version of this document listed as an open
question — why `route_bare` pushes through the same Zoom and stays flat.
`route_bare` *is* the first nine cycles. It is not immune; it is early.

A full 34-scene suite run
earlier the same day did not survive that: `route_wrap` and `route_spans`, both
ordinary `MaterialPageRoute` scenes and both in the baseline since 2026-08-25,
took the heap from 8 MB to the **159 MB ceiling in twelve seconds**, and every
scene after them ran on a full heap. Four minutes later the UI thread was here
and had produced no frame since:

    sk_realloc_throw
    ft_mem_qrealloc -> ft_mem_realloc -> FT_GlyphReceiver_CheckPoints
    cf2_builder_lineTo -> cf2_glyphpath_hintPoint -> cf2_builder_moveTo

Blocked asking FreeType for memory that was not there. Raster idle, all four
cores above 90% idle, `reserve_fail=0`, `vgl_oom=0`. No GL fault of any kind.

## `allowSnapshotting: false` is not the fix

It stops the monotonic growth and replaces it with churn — used memory
oscillating 51–62 MB while the arena climbs to 82 MB — and it costs 9x on the
raster thread (1.5 ms to 14.2) and 117 ms of stall where there was none. It
trades a leak for slow frames and still uses more memory than any other option.

## What is not yet known

**Why the tenth cycle is different.** The framework is not the obvious suspect:
`_RenderSnapshotWidget` disposes `_childRaster` on all nine paths that can
invalidate it, including `dispose()`. Below that, Skia's resource cache is
capped by the shell at `width * height * 12 * 4` — 25 MB on this panel — and the
growth sails past that to 46 MB in one scene and 158 MB in a full run, so a
budgeted cache is not holding it either.

A threshold around nine or ten is the shape of a cache with an access counter
rather than a byte budget. Flutter's own `RasterCache` promotes a layer after it
has been seen three times. Neither has been instrumented; this is where to look
next, not what was found.

**Whether it is confined to transitions.** If what fails is releasing rasterised
images in general, page transitions are where it was noticed rather than where
it lives.

**`route_bare`'s own worst frame is unstable across runs** — 16.7 ms when the
run began with a deploy, 133.3 ms when it began with a relaunch, first scene in
both. Unexplained, and the same shape as the bimodality
[apps/gallery/bench/README.md](../../apps/gallery/bench/README.md) records for
`route_wrap`.

## Zoom's timing is bimodal too

Two runs at 50.0 ms worst with no stall, three at 133.3 ms with 217–250 ms of
stall, same binary and same scene. The split is not explained by the heap: run B
had the good timing *and* the leak, run D had the good timing and no leak, runs
B2, E and F had the bad timing with and without it. Whatever produces it is not
what produces the growth.

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

1. **Leave Zoom and fix the retention.** The only option that keeps a 1.3 ms
   raster cost. Cost unknown until the tenth-cycle threshold is explained, and
   an app that pushes ten routes in a session hits it today.
2. **Default to Cupertino.** The steadiest of the bounded three: 83.3 ms worst
   and 66–83 ms stall on both runs, flat memory, 5.7–6.0 ms raster. Slides
   rather than zooms, which is a different look.
3. **Default to FadeForwards.** Material's own newer transition, flat memory,
   83.3 ms of stall, 6.9 ms raster.

Zoom's raster advantage is real and large. Its frame timing is not reliably
better than Cupertino's, and it is the only one of the four that cannot be left
running.

Nothing here recommends `allowSnapshotting: false`.
