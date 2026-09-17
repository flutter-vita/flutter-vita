# localsend does not crash on receive. It stops drawing.

The open bug read "SceGxm data abort on the raster thread after a localsend
receive, one in three". Eight transfers today, one failure, and the failure was
not a data abort and not one in three.

## What the failure actually looks like

Nine 5 MB transfers over two runs. The eighth ended the app, and the log ends
like this:

    flutter-vita: JANK frame #1777 gap 54447 us (raster 19396 us, wait 31827 us)
    flutter-vita: LOOP 300 iterations @ 16627 us mean | 0 tasks (1872 us total)
    flutter-vita: LOOP 300 iterations @ 16627 us mean | 0 tasks (1874 us total)
    ... 46 more ...
    flutter-vita: touch down 108.6,262.7
    flutter-vita: touch up 108.6,262.7
    flutter-vita: LOOP 300 iterations @ 16627 us mean | 0 tasks (1962 us total)

48 `LOOP` lines at 300 iterations each is **239 seconds of platform thread
running at exactly the panel's vblank with nothing queued, and not one frame
presented**. Six touch events land during it, so input is still being polled and
delivered. The process is alive the whole time. It ends only because a human
opens the receiver.

So the app does not fault. It stops producing frames and keeps running.

Three things say so independently:

- **No core dump.** The console writes `psp2core-*.psp2dmp` on every fault. It
  wrote none for this one, and the newest dump on the card is from the previous
  hour.
- **No bailout entry.** `bailout.c` overrides `abort()` and `__assert_func()`
  and appends to `ux0:data/flutter-vita/bailout.txt` before exiting. Nothing was
  appended, so nothing aborted and nothing asserted.
- **The platform loop keeps its cadence.** 16,627 us is the vblank to the
  microsecond, and `0 tasks` means nothing is queued behind it.

`LOOP` running clean while frames stop puts the failure upstream of the platform
thread: either the UI thread stopped asking for frames, or it asked and never
finished one.

## It is the end of a slide, not an event

The frame rate over that run, sampled every four reports:

    38.6  28.6  28.8  28.8  29.0  30.5  23.5  17.4  -> 0

and alongside it, across the nine transfers:

| | first | last |
|---|---|---|
| throughput | 648 KB/s | 503 KB/s |
| free user memory | 45,056 K | 28,672 K |

Nothing recovers between transfers. The app gets slower, holds less memory, and
then stops. That is the shape of something accumulating, not of a race that
either fires or does not -- and it fits "one in three" as an artefact of how
many transfers a session happened to run before the slide bottomed out.

The last healthy report has raster at 9,629 us and `gl wait` at 45,749 us of a
57,415 us frame. `gl wait` is the raster thread idle waiting to be handed work
([ADR-0014](../adr/0014-gpu-backend-via-vitagl.md)), so the GPU is not the
constraint here any more than it was on the Receive screen in
[the 08-25 results](localsend-gl-2026-08-25.md). The UI thread is.

Not memory exhaustion: 28 MB free at the stall, and vitaGL's `vgl_oom_count`
never printed a non-zero value.

## The other failure is real and separate

`psp2core-1788119930` from 2026-08-30 is a genuine fault, and a different one:

    pthread <0x40010195>
        Stop reason: 0x30004 (Data abort exception)
        PC: 0xe0081c68 (SceGxm@1 + 0x1e638)
        R0: 0x70100254   R11: 0x70100250   LR: 0x1

with `vitaGL Garbage Collector` and `SceGxmDisplayQueue` both alive and waiting.
An `LR` of 1 is not a return address, and R0 and R11 point into a region that is
not ordinary user memory.

It cannot be symbolicated. localsend's ELF from that run no longer exists, and
every build relocates, so a rebuilt binary would resolve those addresses to
confident nonsense. `tools/analyse-crash.sh` now says so in its header, and the
ELF for the current build is kept at `out/dumps/elf/`.

Treat these as two bugs until something links them.

**Linked, 2026-08-31 evening.** It happened again, and the second dump has its
ELF: same PC, same `R0`, same `R11`, same `LR` of 1, and the stack under it
resolves to vitaGL's `glViewport` and `update_scissor_test`. See
[localsend-gxm-abort-2026-08-31.md](localsend-gxm-abort-2026-08-31.md).

**Same bug, 2026-09-01.** Not two after all. vitaGL wrote through a null
uniform buffer GXM had refused to give it; depending on what sat at address
zero that either faulted or wedged the pipeline, and the wedge is this
document. That is why nothing was ever wrong with the threads. One tap on an
overflow menu reproduced both outcomes, and
[patches/vitagl/0002](../../engine/patches/vitagl/0002-the-reservation-vitagl-never-checked.patch)
ends them. **The memory slide across nine transfers below is not explained by
this and stays open.**

## Dump discipline, which cost the diagnosis twice

53 dumps on the card. **22 are `.tmp`** -- the console renames only when the
write completes, so those are all truncated, and truncated means the notes
segment is missing, and the notes segment is the thread list. A truncated dump
parses to an exception, not to a partial answer.

Something interrupts the write about 40% of the time. The crash supervisor is
switched off (`supervisor.on` is `0`), so it is not that. The remaining
candidate is a human opening the receiver while the console is still writing,
which is the standing habit after every crash and exactly the wrong moment.

**After a fault, leave the console alone for two minutes before opening
anything.** It costs two minutes and it is the difference between a thread list
and nothing.

## Where to look next

The UI thread stops and everything downstream of it idles correctly, so:

1. **Find out whether the UI thread is blocked or merely not scheduling.** The
   platform loop reporting `0 tasks` says nothing was posted to it; the question
   is whether `FlutterEngineOnVsync` is still being answered. Instrumenting the
   vsync handshake is cheap and does not need a crash to read.
2. **Chase the accumulation rather than the stall.** Throughput and frame rate
   both decay monotonically across transfers with 16 MB of memory going missing.
   Whatever is accumulating is easier to catch at transfer three than at the
   moment everything stops.
3. ~~Only then the SceGxm abort, with an ELF kept alongside the dump.~~ Done:
   the ELF was kept, the abort recurred, and it is now blocker 3 in
   [the release list](localsend-release-blockers-2026-08-31.md).
