# Partial repaint: 13.6 fps to 60 fps, and what it does not fix

Measured on hardware with `apps/gallery`, 2026-08-19, immediately after the
160 MB newlib heap change so the only variable is the repaint path.

## Before and after

Same app, same screen, same idle-with-a-spinner state:

| | Before | After |
|---|---|---|
| Active frame rate | 13.42 / 13.56 / 13.62 fps | **59.9 – 60.1 fps** |
| Active frame time | ~73.5 ms | **16.7 ms** |
| Present blit | 10.6 ms (14%) | **0.08 ms (0%)** |
| Damaged screen area | 100% (never measured; always all of it) | **under 1%** |

```
flutter-vita: FRAMES active 60 @ 16645 us = 60.07 fps (blit 79 us = 0%, dmg 0%) | idle gaps 0 | max 25 ms
flutter-vita: FRAMES active 60 @ 16670 us = 59.98 fps (blit 84 us = 0%, dmg 0%) | idle gaps 0 | max 26 ms
flutter-vita: FRAMES active 60 @ 16684 us = 59.93 fps (blit 83 us = 0%, dmg 0%) | idle gaps 0 | max 20 ms
```

60 fps is a ceiling, not a measurement: the engine paces at 60 Hz, and this
screen now finishes a frame well inside the 16.7 ms budget with time to spare.
The gallery screen holds a `CircularProgressIndicator` — one small spinner that
animates every frame. Before this change that spinner repainted and re-blitted
all 522,240 pixels, sixty times a second, for the sake of a few hundred.

**The blit fell by 130x, not by the area ratio alone**, because a 0.08 ms copy
also stops evicting the whole framebuffer from cache every frame.

## Correctness

Verified by screenshot rather than by argument. After tapping the counter, the
segmented control and the slider, every one of them shows its new state and
nothing anywhere else on the screen is stale or torn — including regions that
have not been written since the app started.

That holds because of one property: `EmbedderSurfaceSoftware` allocates its
`SkSurface` once and hands the same one back every frame. The previous frame is
still in it, so painting only the damaged rectangle leaves valid pixels
everywhere else. Upstream never enabled partial repaint here — the GL and Metal
embedders cannot make that promise, since they present by swapping buffers, and
the software path was simply never revisited.

## What it does not fix

**A screen where everything changes still costs what it always did.** Scrolling
a list, a page transition, a full-screen animation — the damage rect is the
whole screen, Skia paints all of it, the blit copies all of it, and the frame
rate returns to about 13.6 fps. Partial repaint did not make painting faster; it
made *not painting* possible.

So the fps question splits in two, and the new `dmg%` field in the frame log is
what separates them:

- **`dmg` small** — solved. 60 fps, and the remaining budget is spare.
- **`dmg` near 100%** — untouched. ~13.6 fps, and the 86% that is Dart, layout
  and Skia raster is still unattributed inside that.

The GPU question is now precisely scoped: it is worth its cost only for the
second case. See [frame-cost-2026-08-18.md](frame-cost-2026-08-18.md) for why
the blit was never the interesting half.

## The instrument

`FRAMES` gained `dmg %`, the mean share of the screen reported damaged over the
window. It is the number that says whether an app is in the first case or the
second, and it is the number to quote before anyone spends a week on a GPU
backend.
