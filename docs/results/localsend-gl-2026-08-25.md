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

## What the UI thread is doing: nothing

The first reading of this was wrong and is corrected here.

```
PARAGRAPHS 38 | ctor 4435 us | build 4776 us | layout 254551 us | 6941 us each
```

That counter spans a **300-iteration window, about five seconds** -- not one
frame. 38 paragraphs at 6.9 ms is 262 ms of layout across ~5000 ms of wall
clock: **5.1% of the time, not 96% of a frame.** Text is not what this screen
is spending its two hundred milliseconds on.

What the rest of the instrumentation says is that nothing is spending them.
Raster is 4 ms. The raster thread is idle 191 ms waiting for the UI thread. The
platform loop reports `0 tasks`. The frame period is 200.001, 200.005, 200.277
ms -- three windows, a third of a millisecond of spread. That is not a machine
under load. That is a machine waiting for an alarm clock.

## The alarm clock rings five times a second

localsend's spinner is not an `AnimationController`. It is
`rotating_widget.dart`, and it is a loop:

```dart
static const _fps = 30;
static const _tickDuration = 1000 ~/ _fps;  // 33 ms
while (true) {
  await sleepAsync(_tickDuration);          // Future.delayed(33 ms)
  if (!widget.spinning) continue;
  setState(() { _angle = ... });
}
```

So it asks for a frame every 33 ms. Measured on this port, from the gallery's
`timer_probe.dart`:

```
timers/idle                    1ms->199.4  8ms->200.0  16ms->200.0  33ms->200.0  100ms->200.0
timers/pumped (frame 16.7ms)   1ms->200.0  8ms->200.0  16ms->200.0  33ms->200.0  100ms->200.0
```

**Every Dart timer fires on a 200 ms grid, whatever it asks for.** 1000/200 =
5.00 fps, which is the number at the top of this page, to three significant
figures.

The second row is the part that says where the bug is not. It runs the same
probe while frames are pumped continuously, and the control confirms the pump
worked: 16.7 ms a frame, so the UI thread's `fml` message loop is being woken
sixty times a second throughout. The timers still land on the grid. Whatever is
late, it is not `message_loop_vita.cc` and it is not vsync -- it is the thread
that decides a deadline has arrived, which is dart:io's event handler
(`eventhandler_vita.cc`, `poll()` over `sceNetEpoll`).

## This is a port bug, not a localsend bug — and it is fixed

Any Flutter app that animates or polls with `Timer` or `Future.delayed` was
capped at 5 fps on this console. `AnimationController` is not affected --
it rides vsync -- which is why the gallery holds 60 fps on scenes that look far
heavier than a rotating ring.

The same subsystem failed harder when asked for real sockets. A loopback TCP
round-trip probe got through bind, connect and accept and then stopped: the
first byte never came back, and the 30 s timeout wrapped around the probe never
fired either, because that timeout is a timer and the thread that would deliver
it was the one that was stuck. See `apps/gallery/lib/bench/socket_probe.dart`;
whether the fix below also fixes that is untested.

### The cause

[experiments/t1-timers](https://github.com/flutter-vita/flutter-vita/blob/c91294a/experiments/t1-timers/README.md) measured the primitives
directly. Every timeout on this console is exact -- `sceKernelDelayThread`,
`poll()` with and without a socket in the array, and `sceNetEpollWait` all
honour 33 ms to within a tenth of a millisecond, and the epoll instance
`poll()` builds and tears down on every call costs nothing measurable.

What is late is **readiness**. A byte written to a socketpair reaches a waiting
reader ~197 ms after the wait began, wherever in that window the write lands,
and it is the same number whether the reader is in `poll()`, in a blocking
`recv()`, in `sceNetRecv()` on a raw sceNet socket, or in `sceNetEpollWait()`.
It is the loopback interface, serviced on a ~200 ms tick; WiFi sockets are
prompt, which is why this project's own dev server always felt fine.

dart:io's event handler learned "arm a timer at T" by reading a **loopback
socketpair**. Every timer registration therefore paid one tick, the loop
self-synchronised to it, and `Future.delayed(33 ms)` became 200 ms.

### The fix

`eventhandler_vita.cc` now keeps a mutex-guarded queue of interrupt messages and
signals an event flag -- measured at 0.03 ms cross-thread, the same primitive
`message_loop_vita.cc` already wakes the UI thread on sixty times a second. With
no socket registered the handler waits on that flag with the exact deadline;
`poll()` owns the wait only when there are real sockets, sliced at 8 ms so the
queue is still noticed promptly.

| | before | after |
|---|---|---|
| `Future.delayed(1 ms)` | 199.4 ms | 2.4 ms |
| `Future.delayed(33 ms)` | 200.0 ms | **34.2 ms** |
| localsend Receive | 5.00 fps | **~30 fps** |

The residual ~1.2 ms is the round trip through the Dart port and the UI message
loop.

## The number that still does not fit

**6.9 ms per paragraph, against the gallery's 0.26 ms.** Twenty-six times, for
what looks like ordinary text: a heading, a subtitle, three sidebar labels.

It is no longer the explanation for this screen -- 5.1% of the time cannot be --
but it is still a real per-paragraph cost and nothing here accounts for it.
Candidates, none tested:

- font fallback -- localsend names families the port may not have, and a miss
  walks the fallback chain per paragraph
- the heading's size, if cost scales with glyph area somewhere it should not
- something in the `ColorFiltered` + `Transform.rotate` ancestry
  ([ADR-0014](../adr/0014-gpu-backend-via-vitagl.md) found that widget already)
  perturbing layout rather than only paint

This is a question for [the profiler](../the-profiler-we-do-not-have.md).

## What this does not say

It does not say the GPU flip was wrong. Every scene in the benchmark is faster
on GL, several by 17-20x, and this screen's raster is 48x faster. It says
localsend specifically was never going to be fixed by a renderer, and that
anyone reading "4.87 fps, raster 97%" in ADR-0014 should now read it as
"raster was 97% of a frame that was 191 ms of waiting".

It also does not say the timer grid was the only thing wrong with this screen.
It says the timer grid set the frame rate, exactly, and that nothing else could
be measured on this app until it was fixed -- a 5 Hz ceiling hides every cost
below 200 ms. At 30 fps the screen is worth measuring again, and the 6.9 ms
paragraph is the first thing to look at.
