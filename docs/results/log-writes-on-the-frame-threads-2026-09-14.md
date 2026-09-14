# Log writes on the frame threads

**Question:** the M5 record left bench runs 25 to 27 with stall sums 4 s
above runs 23 and 24 on the same engine, the excess in a different scene
each time and in bursts of three to five slow frames. Random spread, or a
cause with a name?

**Builds:** gallery builds 27 to 29 of 2026-09-14, all on `fvita_gles2`.
Build 27 adds counters, 28 adds timers, 29 is the fix. Bench results
`out/bench/gl-gles2-run{27,28,29,30}-2026-09-14.json`; logs pulled over
`log` after each run.

## What the runs said

Run 27 repeated the high sum (stall 11933 ms) and its slow frames had the
same shape as before: `raster_ms` 100 to 190 ms on three to five consecutive
frames with a normal build time, in a scene that draws nothing unusual
(`transform_rotate` frame 3, `shader_mask` frame 2, `modal_dialog` frames 114
to 118). The layer's own counters for those seconds were quiet: garbage
collection and memblock time in single milliseconds, `sub 0`, `var 33/33/0`.

Build 28 timed two things that were not measured before: every log write,
and every `glLinkProgram` with the part of it that reads the program cache
on the card. Run 28 came in low (stall 7683 ms) and answered anyway:

| what | per second, median | 90th percentile | worst single |
|---|---|---|---|
| card time inside `sceIoWrite` for the log | 33 ms | 72 ms | 187 ms |
| `glLinkProgram`, all 70 of the run | 184 ms total, 2.6 ms each | | 10.8 ms (card 4.2 ms) |

Every log line was a synchronous `sceIoWrite` from the thread that logged
it, by design: the first log implementation lost its last lines to stdio
buffering and the comment above `OpenLog` said to revisit "once the boot is
quiet enough that logging volume matters". The threads that log during a
bench are the raster thread (`JANK`, `FRAMES`; 468 `JANK` lines in run 28),
the UI thread (`PARAGRAPHS`), and the platform thread (`LOOP`, channels).
A 100 ms write on the raster or UI thread is a dropped frame the bench counts
as a stall, and a `JANK` line written by the raster thread can be the reason
for the next `JANK`: the burst.

The link timing says the first frame of a scene that needs seven new
programs spends about 70 ms linking on the raster thread, cache hits
included. That is the other recurring `raster max` in the 70 to 100 ms
range, it is paid once per program, and it is not what changed between
runs.

## The change

`VLog` writes into a 256 KB ring; one thread, `fvita-log`, wakes on every
line and drains the ring to the card. What arrives during a slow write
waits in the ring instead of on the frame. The `FRAMES` line's
`log N us max M dropped D` now reports the writer thread's card time and how
many lines found the ring full (0 in both runs; the ring never held more than
one slow write's worth).

The last lines still reach the card on every exit this process takes on
purpose: `flutter_vita_log_flush` runs in the dev server before a handoff or
relaunch (`release_gpu`), in the bail-out before it launches the receiver,
in the watchdog before it copies the log and relaunches, and before the
VitaShell handoff. A hardware fault loses what arrived during the write in
flight, and nothing on this platform catches those anyway (ADR-0011).

`FML_LOG` still goes through unbuffered stdio: a handful of lines per run,
none on a frame thread.

## After

Two runs of build 29, against the four before it:

| run | build | worst ms | stall ms | stall frames | UI build ms | raster ms |
|---|---|---|---|---|---|---|
| 24 | 24 | 2850 | 7533 | 94 | 247.2 | 222.1 |
| 27 | 27 | 4067 | 11933 | 130 | 242.3 | 226.3 |
| 28 | 28 | 2850 | 7683 | 97 | 241.6 | 226.4 |
| 29 | 29, the ring | 2167 | 6233 | 79 | 229.3 | 198.4 |
| 30 | 29, relaunch | 2433 | 6217 | 76 | 223.1 | 198.2 |

Both runs are below every earlier run on this layer in every column. The
raster sum fell in 14 scenes of 36 and rose by more than 0.3 ms in 3;
`list_churn`, the scene that logs most, went from 13.2 to 6.1 ms per frame,
`route_wrap` from 10.2 to 3.8, `alpha_probe` from 6.3 to 1.0. The writer
thread spent 9.7 s of the six-minute run inside the card driver (median 32 ms
per second, one write of 197 ms), none of it on a frame.

## Two more things the counters settled

- **`sub 0`.** Over 9360 frames Skia never wrote with `glBufferSubData` into
  a buffer a draw of the same frame had read. The copy path the buffers row
  of `docs/gles2-progress.md` kept open is not needed for Skia.
- **`var 33/33/0`.** 33 patched vertex and 33 patched fragment programs
  alive at the end of the run, one layout and one blend state per program,
  and no draw found a variant table full. Eviction from the 32-entry tables
  can wait for an app that needs it.

## Depth and stencil are unreachable

While sizing the next piece of layer work: Flutter's
`shell/common/context_options.cc` sets `fAvoidStencilBuffers` on every GL
context, so Ganesh never attaches a stencil buffer, clips paths through
coverage masks instead, and binds no depth buffer at all. The 13 stencil and
renderbuffer entry points stay recording stubs with 0 calls in every run
since 2026-09-09, and building them would serve no Flutter app. The progress
table says so now; its `done` numbers for those rows are unchanged.

## Also in these builds

- The `ARWE` probe in `fml/synchronization/waitable_event.cc` (patch 0002)
  printed three lines per `AutoResetWaitableEvent::Wait` to chase a crash in
  `pte_cond_wait_cleanup`. That code is gone since the template's
  `pthread_cond.c`; the probe is out and the file is pristine.
- `experiments/gl-usage` wraps `fvgl_get_proc_address` instead of
  `vglGetProcAddress`. A gallery built with it (three options, in the file's
  header) ran the bench on the layer; its counts are in `gles2/surface.txt`.
