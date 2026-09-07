# The second route scene leaks 12 MB a sample, and the first never does

2026-09-01. Gallery, GL, engine `058e0af2c2` built 16:16:16Z.

## What happens

A full sweep from the receiver's TESTS tab was killed by the kernel at 158 MB of
native heap. The log attributes it exactly:

```
scroll_fling     8M
route_bare       8M
route_wrap      20 → 32 → 44 → 56 → 68 → 80 → 84M
route_spans     96 → 108 → 120 → 132 → 144 → 156M
route_text_uniq 158M    plateau: nothing left to take
route_grid_bare 158M    process dies
```

Twenty-three scenes hold flat at 3 MB. Then the heap climbs in steps of a
constant 12 MB until the process is killed. A constant step is one allocation
repeated, not diffuse growth.

`heap=` is `mallinfo().uordblks` / `.arena` -- the native C heap, printed on
every `present` line, which is every sixty frames. So 12 MB a sample is about
200 KB a frame, allocated continuously and never returned.

## The repro is two scenes and two minutes

```
./tools/bench.sh --only gl --relaunch --scenes route_bare,route_wrap
```

```
route_bare   6M → 8M
route_wrap  18 → 30 → 42 → 54 → 66 → 78 → 82M
```

## It is positional, not a property of any scene

| run | result |
|---|---|
| `route_wrap` alone | 6M → 10M, bounded |
| `route_bare,route_wrap` | 8M → 82M, +12M a sample |
| `route_bare,route_boxes` | 8M → 82M, +12M a sample |

`route_wrap` on its own does not leak. `route_boxes` -- a GridView, structurally
unlike the Wrap -- leaks identically when it runs second. Whatever the first
route scene leaves behind makes every route push after it retain memory.

Ordering could not be tested directly: `--scenes` filters, it does not reorder.
The runner walks its own declared list and skips what was not asked for, so the
file's order is ignored. That is worth knowing before designing another
experiment around it.

## It is not any Skia cache

All five candidates are now eliminated by measurement, on the run that reached
158 MB:

| cache | at 158 MB |
|---|---|
| GrDirectContext resources | 6 entries, 4270K of 24480K, flat |
| Flutter RasterCache (layer) | 0 |
| Flutter RasterCache (picture) | 0 |
| Skia glyph cache | 220 entries, 562K of 2048K, flat |
| Skia unref queue | `q=0 d=0`, never used |
| SkGraphics resource cache | `skres=0K/32768K` -- never held a byte |

`skres` was instrumented two sessions ago and read for the first time today.
It is empty for the entire run. Nothing Skia accounts for is growing while the
process takes 150 MB.

## Refuted: page snapshotting

The platform default transition is Zoom, which rasterises each page into an
image, and vitaGL is built `TEXTURES_SPEEDHACK=1`, which keeps texture data in
RAM. That predicted GPU-shaped allocations landing on the native heap, outside
every Skia cache, which is exactly the shape of the symptom.

It is wrong:

```
route_tx_zoom          6M flat over 6 samples    snapshotting ON
route_tx_zoom_nosnap   22, 28, 17, 22, 17, 13M   snapshotting OFF
```

Zoom with snapshotting did not leak. Turning it off made the heap higher and
jumpier, and it was reclaimed. Two scenes never reach the leak at all, which is
its own datum.

## Corrections to what was published earlier today

`docs/results/page-transitions-2026-09-01.md` says Zoom leaks 4-6 MB a cycle
past a cumulative tenth cycle. Both halves are now known to be narrow readings
of this:

- The rate is 12 MB a sample, not 4-6 MB a cycle. The earlier number came from
  a three-scene repro that mixed transition scenes.
- There is no cumulative threshold at ten cycles. One prior route scene is
  enough, and the second scene starts leaking immediately.
- It is not about Zoom. `route_bare` and `route_boxes` use the same default
  transition as everything else, and the leak follows position, not transition.

## Open

Where the 200 KB a frame goes. It is native heap, it is not Skia-accounted, and
it starts only after one route scene has been torn down. The next thing to look
at is what `RouteScene`'s teardown leaves behind -- the runner pops to the root
between scenes -- and whether the growth continues in a scene that pushes no
routes at all once a route scene has run.
