# Where a frame actually goes

Measured on hardware with keklist, 2026-08-18, to settle whether the GPU is the
answer to the frame rate. **It is not the first answer, and the reason is one
number.**

## The number

```
FRAMES 60 in 39956 ms = 1.50 fps | mean 665948 us (blit 10650 us, 1%) | max 35087251 us
```

Read carefully, because the headline figure is wrong and the instrument was at
fault. **One gap in that window was 35 of the 40 seconds.** Flutter produces a
frame only when something needs repainting, so a screen sitting still presents
nothing at all — that gap is a person not touching the console.

Subtract it: 4869 ms across the other 59 frames.

| | |
|---|---|
| Active frame time | **82.5 ms** |
| Active frame rate | **12.1 fps** |
| Present blit (`memcpy`) | **10.65 ms** |
| **Blit share of an active frame** | **13%** |
| Everything else — Dart, layout, Skia raster | **~72 ms, 87%** |

12.1 fps matches the ~11.6 fps measured independently during Phase 8, which is
the cross-check that makes the rest of this trustworthy.

## What it means for the GPU question

Rendering on the GPU removes the blit **and** Skia's rasterisation. The blit
half is quantified: 10.65 ms of 82.5, so deleting it alone takes 12.1 fps to
about 13.9. The raster half is inside the unattributed 72 ms and is **not**
measured yet — it could be most of that or a fraction, with Dart build and
layout taking the rest.

So the honest position: a GPU backend is the largest available ceiling-raiser
and **nobody here can currently say by how much**, because the 87% has never
been broken down. Committing to it on this evidence would be buying the biggest
item on the strength of the smallest number.

It also carries a dependency the project has rejected in another form:
vitaGL's own README requires `libshacccg.suprx` "extracted and decrypted on your
console" — Sony's shader compiler, not redistributable, and a manual step for
every user of every app built with this toolchain. That is the same class of
imposition [ADR-0001](../adr/0001-aot-only-no-jit.md) refused taiHEN for, and it
lands on the *toolchain user* persona rather than the maintainer.

## What to do instead, in order

1. **Break down the 72 ms.** Dart, layout and raster are one blob today. Until
   they are three numbers, every optimisation choice is a guess.
2. **[ADR-0007](../adr/0007-enable-partial-repaint-in-software-path.md), partial
   repaint** — accepted 2026-08-07, still unimplemented. It scales *both* the
   blit and the raster with the damaged area, needs no GPU and no Sony module,
   and its own measurement puts a 5%-damage frame at 0.4 ms of blit instead of
   8. On a UI where one row changes, that is the whole frame.
3. **Free wins:** the present is a per-row `memcpy` loop that could be a single
   call when `row_bytes == pitch`; RGB565 would halve blit bandwidth at a
   quality cost. Note overclocking does **not** help — ADR-0007 measured the
   blit as bandwidth-bound and clock-insensitive.
4. **vitaGL last**, and only once step 1 says raster dominates.

## Two corrections this produced

**The first instrument was wrong.** It printed `now - g_last_present_us` every
sixtieth frame while updating that variable every frame, so it reported one
arbitrary frame's duration and read like a frame rate. On a screen with
occasional stalls it printed 797 ms and looked like 1.25 fps sustained. One slow
frame in sixty and sixty slow frames are indistinguishable to that instrument,
and they are opposite problems. It now accumulates over a window.

**Idle and slow were being averaged together.** Fixed by counting gaps over
250 ms separately: the active mean describes rendering, the idle count explains
the wall clock.

## Still open

keklist **aborts** after a few dozen frames — `ux0:data/flutter-vita/bailout.txt`
reads `abort()`, and it happened on both builds either side of this change, so
it is not the instrumentation. The log ends mid-render with no exception. No
core dump reached `ux0:data`. That is its own investigation and it is why the
improved instrument has not yet produced a reading of its own: the app does not
survive 60 frames reliably.
