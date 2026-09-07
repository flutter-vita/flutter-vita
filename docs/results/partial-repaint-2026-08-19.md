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

## keklist, which is the app that actually matters

The gallery is a control. keklist is a real app with a scrolling list, and it is
the one that was described as "everything is lagging". Before this change it sat
at about 12 fps whatever it was doing.

```
FRAMES active 58 @ 18053 us = 55.39 fps (blit  236 us = 1%, dmg  2%)
FRAMES active 52 @ 23542 us = 42.47 fps (blit 1094 us = 4%, dmg 13%)
FRAMES active 44 @ 28221 us = 35.43 fps (blit 3163 us = 11%, dmg 31%)
FRAMES active 60 @ 37524 us = 26.64 fps (blit 6048 us = 16%, dmg 64%)
```

**Frame rate now tracks damage, which is the whole point.** Read down the
column: 2% damage buys 55 fps, 64% damage buys 27. Even the worst window in the
run is more than twice the old flat 12 fps, because even a scrolling list rarely
changes every pixel — the app bar, the bottom navigation and the page margins
stay put.

Correctness was checked the same way as on the gallery, across a relaunch and
four tabs. The analytics screen -- bar chart, filter chips, two panels -- comes
out complete and unblemished. Screenshots taken *during* a scroll do show rows
from two different scroll offsets, but that is the capture racing the blit on a
single-buffered display, not stale pixels: it predates this change, and the same
screen is clean the moment scrolling stops.

## What it does not fix

**A screen where everything changes still costs what it always did.** A page
transition or a full-screen animation damages every pixel, Skia paints all of
them, the blit copies all of them, and the frame rate returns to about 13.6 fps.
Partial repaint did not make painting faster; it made *not painting* possible.
keklist's 26.6 fps at 64% damage is the shape of that curve, and extrapolating
it to 100% lands back where this started.

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

## The HUD

Every number above was read out of a log pulled over the network after the
fact. That is fine for a measurement and useless while somebody is holding the
console — the moment you want to know *which* screen is slow, the answer has to
be on the panel next to the thing you are touching. So the same window is now
drawn in the top-right corner of every frame:

```
36.2 FPS  27 MS
DMG 11%  BLIT 1.1 MS
MEM 53M  MAX 51 MS
```

It lives in the embedder, not in Dart: it costs the app nothing, needs no
widget, and works identically in every app in the test apps without a line of
source. It is drawn after the blit and straight into the display buffer, which
is also what makes it survive partial repaint — the blit restores app pixels
underneath and the HUD goes back on top in the same call.

**Its first version cost 2.4 ms a frame, which is more than the blit it was
there to measure.** Two mistakes, both from reading the framebuffer instead of
only writing it:

- The backing box halved each channel so the app showed through. Those 16,000
  reads land in CDRAM, where reads are far slower than writes.
- Nothing restores those pixels on a frame that damages elsewhere, so it
  darkened *its own previous output* sixty times a second and faded to black
  within a second regardless.

A solid box, plus repainting only when the text changes or the blit overwrote
it, takes it to **19 µs** — 127x cheaper, and now reported as its own `hud`
field in the FRAMES line so it can never be confused with the blit.

`overlay off` on the dev server hides it for a clean screenshot; a shipping
build drops it by defining `int flutter_vita_debug_overlay = 0;` beside the dev
server stub, the same way `devserver.c` and `bailout.c` are dropped.
