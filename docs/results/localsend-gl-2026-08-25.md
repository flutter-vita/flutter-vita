# localsend on the GPU: raster falls 48x and the frame rate does not move

2026-08-25. Device: PCH-2000, 192.168.0.32. Pin `fd8140b6` (v1.15.4).
Same app, same **Receive** screen as
[ADR-0014](../adr/0014-gpu-backend-via-vitagl.md) measured on software —
sidebar on Receive, the rotating dashed ring, "Pretty Potato #32", verified by
framebuffer capture before any number was read.

| | software, 2026-08-19 | GL, 2026-08-25 |
|---|---|---|
| fps | 4.87 | **5.00** |
| raster | 199,559 us (97% of frame) | **~4,000 us (1–2%)** |
| raster thread idle | — | **~191,000 us** |
| frame period | 205 ms | 200 ms |

**The GPU did everything that was asked of it and it changed nothing.** Raster
fell by about 48x. The frame rate moved by 3%.

## Because raster was never the limit — it was hiding the limit

`gl wait` in the FRAMES line is `g_win_gl_idle_us`: the gap between the end of
one present and the raster thread being handed the next frame. It is **the
raster thread sitting idle waiting for the UI thread**, and on this screen it
is 191 ms of a 200 ms frame.

So localsend's Receive screen takes ~200 ms per frame on the UI thread, and it
did so on the software path too — where 200 ms of raster ran alongside it and
got the blame. ADR-0014's reading that this screen is raster-bound was correct
about the software build and wrong about the app.

That is the general shape of this port after the renderer flip, and localsend
is the clearest case of it yet: **the GPU does not make anything faster that
was not waiting on raster. It makes the UI thread visible.**

## What the UI thread is doing: 38 paragraphs at 6.9 ms each

```
PARAGRAPHS 38 | ctor 4435 us | build 4776 us | layout 254551 us | 6941 us each
```

Layout is 96% of it. Thirty-eight paragraphs at 6.9 ms is 262 ms, against a
measured frame of 200 — near enough, on a counter that spans window boundaries,
to say that **this screen is a text-layout screen and nothing else matters.**

## The number that does not fit

**6.9 ms per paragraph, against the gallery's 0.26 ms.** Twenty-six times, for
what looks like ordinary text: a heading, a subtitle, three sidebar labels.

Nothing here explains it. The gallery's paragraphs are short single-line
strings; localsend's include a large heading, so some of the gap is real
content. Twenty-six times is not that. Candidates, none tested:

- font fallback — localsend names families the port may not have, and a miss
  walks the fallback chain per paragraph
- the heading's size, if cost scales with glyph area somewhere it should not
- something in the `ColorFiltered` + `Transform.rotate` ancestry
  ([ADR-0014](../adr/0014-gpu-backend-via-vitagl.md) found that widget already)
  perturbing layout rather than only paint

This is a fourth question for
[the profiler](../the-profiler-we-do-not-have.md), and the best one yet,
because unlike the other three it is a **26x** discrepancy on a real app rather
than a fraction on a synthetic one.

## What this does not say

It does not say the GPU flip was wrong. Every scene in the benchmark is faster
on GL, several by 17-20x, and this screen's raster is 48x faster. It says
localsend specifically was never going to be fixed by a renderer, and that
anyone reading "4.87 fps, raster 97%" in ADR-0014 should now read it as
"raster was 97% of a frame the UI thread had already lost".
