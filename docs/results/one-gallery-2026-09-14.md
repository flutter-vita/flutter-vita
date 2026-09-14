# One gallery: the panel, the scenes, the probes and the hardware on one screen

**Question:** the three measuring apps (gallery, benchmark, conformance)
become one, with the hardware checks added and a strip of live numbers
above every tab. What does the console do when they share a process, and
what does the strip cost a scene?

**Builds:** gallery builds 30 to 44 of 2026-09-14, all on `fvita_gles2`.
Build 30 is the first combined app; 31 to 34 fix what its first run broke;
35 moves the layer's teardown to the raster thread; 36 to 38 measure the
strip; 39 runs each hardware check on a thread of its own; 40 to 44 rework
the strip and close the third teardown crash. Bench results
`out/bench/gl-gles2-run{35,36-hudoff,37,38}-2026-09-14.json`; the crash
dumps `psp2core-1789374460` (build 29), `psp2core-1789384814` (build 33,
truncated) and `psp2core-1789387924` (build 38) from `ux0:data/`.

## The first run, and what it took down

The person ran the Hardware tab, typed into its keyboard field, then ran
the Scenes tab. Every animated scene threw at once:

```
Null check operator used on a null value
#0 State.context (framework.dart:959)
#1 TickerProviderStateMixin._updateTickerModeNotifier
#3 new AnimationController
#4 BenchRunner.runAnimated (runner.dart:297)
```

The Shell drew a scene by replacing the whole tab tree with it, which
unmounted the Scenes tab, whose State was the runner's `TickerProvider`.
The driven scenes (no controller) ran on; the run ended with `abort()`
and this in `bailout.txt`:

```
abort()
  heap 162414K used of 163740K arena, free user 35840K cdram 0K phycont 0K
```

160 MB of arena and all of CDRAM gone, from `heap=14M/16M ... cdram=88064K`
a few frames earlier in the log, with no log line in between: the ring's
last lines were not on the card. The bail-out path records the reason and
the memory and then tears the GPU down; nothing after those two lines was
written. Build 31 adds a record line before each step of the exit, the
thread's name and the caller's address (`bailout.c`), so the next abort
names itself. The cause of this one is not known; it did not recur in the
eight runs since.

## Two crashes in the teardown

The deploy of build 30 and the relaunch of build 33 both ended in the
console's crash dialog rather than the receiver. `gles2-shutdown.txt`
stopped at `framebuffers and textures` both times. The first dump reads,
against build 29's ELF:

```
thread "pthread" CRASHED (Data abort exception)
  _free_r (mallocr.c:2655)         str r6,[r4,#12] with r4 = 0xffffffff
  glDeleteTextures (textures.c:387)  free(t)
```

Skia frees textures it has not used for a while, on the raster thread,
between frames. The teardown ran on the dev server's thread, freed every
texture struct in a loop, and the raster thread's `glDeleteTextures` freed
one of them a second time. Two fixes, in layers:

- `fvgl_shutdown` clears `up` first, waits 20 ms, and the object entry
  points (gen, bind, delete, upload, link, draw, flush, finish, getError)
  return at once while the layer is down (build 34).
- `flutter_vita_gpu_shutdown` posts the teardown to the raster thread with
  `FlutterEnginePostRenderThreadTask` and waits up to two seconds for it;
  the one thread that calls GL cannot race itself. A raster thread that
  does not take the task in two seconds is stuck, and a stuck thread is not
  calling GL: the teardown then runs from the caller as before (build 35).

Runs 34 to 38 relaunched and handed off five times without a fault. The
second dump was truncated by the receiver's launch and could not be read.

The third came from the relaunch that was to start build 38's hardware
suite, four seconds into the teardown, on the main thread:

```
thread "FVTA00002" CRASHED (Data abort exception)
  fvgl_gpu_completed_frame    ldr r2,[r2] with r2 = 0x70026420
  fvgl_stats
```

The strip's once-a-second `vita/stats` read runs on the main thread and
ends in `fvgl_stats`, which reads the `frame_done` notification region;
`sceGxmTerminate` had unmapped it. The object entry points were guarded
by `up` since build 34; the stats read was not. It now answers the last
full snapshot while the layer is down, and the pointer is dropped before
terminate (build 40). The suite itself never ran: the log of the four
seconds was overwritten by the next launch, and the wait read as the
suite hanging.

## The hardware checks, first answers

Build 30's Hardware tab, run by the person (`hardware-result.json`):

| check | state | detail | what it meant |
|---|---|---|---|
| console | pass | Vita, firmware 3.73 | |
| battery and clocks | pass | 99% 29.9°C 4.14 V; arm 444 bus 222 gpu 222 MHz | |
| storage | pass | ux0: 7.0 of 7.4 GB free | |
| clock | pass | network time known | |
| wi-fi | pass | signal 46% | |
| http over tls | pass | generate_204 in 330 ms | |
| buttons and sticks | pass | buttons 0x60, sticks moved | |
| touch panels | pass | back panel: 6 contact samples | |
| gyro and accelerometer | fail | accel 0 0 0, orientation 0 1 0 | `sceMotionGetState` gives orientation and zero acceleration a minute after sampling started; build 31 reads `sceMotionGetSensorState` |
| speaker: a tone | eye | 50 grains at 48 kHz in 999 ms | |
| speaker: an mp3 | fail | sceAvPlayerInit: 0x82DF5B60 | a good handle: user addresses are above 0x81000000 and negative as an int; build 31 tests for 0x80xxxxxx |
| microphone | fail | muted | the console's own switch (PS button menu); build 31 says so and calls it `eye` |
| front camera, back camera | fail | sceCameraStart: 0x80024003 | `SCE_KERNEL_ERROR_VARANGE_IS_NOT_PHYSICAL_CONTINUOUS`: the frame buffer must be a PHYCONT memblock; build 31 allocates one |
| keyboard | eye | nothing typed | the IME opened (`IME open (client 1 ...)`) and drew nothing: the layer did not run `sceCommonDialogUpdate`. Build 31's layer does, in swap, while the embedder's dialog flag is up |

Build 38's host run of the automatic group never started (the teardown
crash above). Build 39 runs every check on a thread of its own with a
15 s deadline, since `sceCameraRead` with `mode 1` waits for a frame, and
leaves breadcrumbs in the log at each camera step. Build 42's automatic
group, launched by the deploy with `hardware.on` still armed:

| check | state | detail |
|---|---|---|
| console | pass | Vita, firmware 3.73 |
| battery and clocks | pass | 98% 30.3°C 4.13 V; arm 444 bus 222 gpu 222 MHz |
| storage | pass | ux0: 7.0 of 7.4 GB free |
| clock | pass | network time known, up 2 s |
| wi-fi | pass | signal 48% |
| http over tls | pass | generate_204 in 366 ms |
| gyro and accelerometer | pass | accel 0.12 -0.08 -1.00 (1.02 g), gyro 0 0 0.01 |
| front camera | eye | frame 4, 320x240 in 78 ms, mean 10.3 sd 1.7 (flat: covered, or dark) |
| back camera | eye | frame 1, 320x240 in 24 ms, mean 8.5 sd 1.2 (flat: covered, or dark) |

Seven pass, two by eye, none failed, none timed out. The camera frames
were black, and the console lay face up: the front camera had the
ceiling in front of it. Build 42 took frame 4, 78 ms after
`sceCameraStart`; a `sceCameraRead` with `mode 1` returns the frame there
is and does not wait for a new one, and the sensor's exposure starts at
black. Build 45 reads until thirty new frames have come, and logs the
brightness on the way:

```
camera 0: frame 1 at 63 ms, mean 8.7 sd 1.5
camera 0: frame 10 at 148 ms, mean 11.1 sd 2.6
camera 0: frame 16 at 345 ms, mean 50.4 sd 24.0
camera 0: frame 21 at 645 ms, mean 82.2 sd 39.6
camera 0: stopped after 739 ms, 68 reads, 30 new frames
camera 1: frame 30 at 969 ms, mean 52.6 sd 10.3
```

The front camera's frame shows the ceiling lamp, the back camera's the
desk. Nine pass on build 45. The six checks that need a person are not
run by the deploy.

## What the strip costs a scene

The strip reads `vita/stats` and rebuilds two lines of text once a second.
Four runs of the 36 scenes, same engine, same console:

| run | strip during scenes | worst sum | stall sum | UI sum | raster sum | scenes with a stall |
|---|---|---|---|---|---|---|
| 30 (before the combined app) | none | 2433 ms | 6217 ms | 223.1 ms | 198.2 ms | 13 |
| 35 | live | 3500 ms | 7933 ms | 242.8 ms | 191.5 ms | 23 |
| 36 | frozen (`hud.off`) | 2633 ms | 5633 ms | 248.0 ms | 199.8 ms | 16 |
| 37 | live, tick timed | 3483 ms | 8000 ms | | | 25 |
| 38 | on screen, paused during a scene | 2833 ms | 6267 ms | 251.2 ms | 183.7 ms | 19 |

Run 37 timed the tick's own frame: 180 ticks, 50 with a build over 15 ms,
mean 13.5 ms, one of 181 ms; the channel round trip 6 to 20 ms of
platform-thread latency. The frame the tick lands in is the slow one, not
the frames around it. The UI-side cost of two `Text` widgets does not
account for it (the PARAGRAPHS line prices a paragraph at 0.7 to 0.9 ms);
finding the rest is open. `mallinfo` was the first suspect and is not it:
sampled at 9 to 390 us.

Build 38 held the strip still through a scene; the person's word on it
was "static values". Since build 42 the strip ticks twice a second and
stays live through the scenes, and `tools/bench.sh` sets `hud.off` for
its scenes runs so the host's stall counts compare with the runs before
the strip. A run from the console's own TESTS tab pays the tick.

The strip itself is a two-row monospace table at 12 px since build 40,
captions over values: `fps`, `ui thread`, `raster`, `gpu busy`, `cpu
cores %`, `ram MB`, `cdram MB`, `heap MB`, `battery`. The memory cells
read used / total. The totals were to come from `sceAppMgrGetBudgetInfo`;
on 3.73 the SceAppMgrUser wrapper and the syscall under it both answer
0x8080201C to this process (builds 41 and 42, launched from the receiver
and from the home screen), so the embedder reports the standard
application budget (256 MiB main, 112 MiB CDRAM, 26 MiB phycont) and says
so in the reply. The 26 is what `sceKernelGetFreeMemorySize` reports
before anything is allocated; the other two agree with the first sample.
The heap's total is the arena cap the app sets, 160 MiB, which mallinfo's
`arena` (what malloc has taken so far) does not say. Two paragraphs, not
one per cell: this console lays out a paragraph in 0.7 to 1 ms, and the
tick already lands in a slow frame. At 2 Hz on the panel, 4 of 60 ticks
had a frame over 12 ms, three of them in the first two seconds.

## The route scenes and the app's Navigator

Run 34 pushed route scenes on the app's own Navigator, under the strip.
Every push rebuilt the route underneath (the rail and five tabs depend on
`ModalRoute.of`) and snapshotted it for the Zoom transition: 15 ms of build
and a 133 ms first frame on every push that run 30 did not have
(`route_boxes` build 10.8 to 27 ms, `route_wrap` 1.4 to 16.3 ms). Since
build 35 the route scenes push on a Navigator of their own on the stage,
over one empty `Material` and the Hero the `route_hero` scene flies from.

## Also found

- `IndexedStack` keeps hidden tabs' animations running
  (`Visibility.maintain`): the panel's spinner drew 60 frames a second
  behind the Scenes tab. `TickerMode` on each tab stops it.
- The layer's display-queue latency reads a full frame period whenever the
  pipeline is full (126% over a still panel). The layer now has a meter
  thread on the `frame_done` notification; the strip reads 27 to 30% on the
  panel, 4.6 ms a frame.
- The layer's object tables never reuse a name: 58152 texture names after
  26 minutes, four bytes each. Harmless at this rate; noted.
