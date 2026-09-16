# The receiver's FILES tab: browse, play, install; and two things it found

**Question:** the receiver gets a file manager (images, audio, vpk install),
the gallery's strip becomes a package with a hotkey, and both go on the
console. What works, and what broke on the way?

**Builds:** gallery 62 to 64 and six scratch-receiver builds (`FVTA00004`)
of 2026-09-16, the real receiver updated twice through the updater. Logs
`ux0:data/flutter-vita/logs/0196` (LocalSend, the START finding) and `0210`
(the scratch receiver, the thread leak); commits `2d7dd63` to `872f032`.

## The strip as a package

`packages/vita_debug_strip`: `VitaStrip` draws the frame strip the gallery
had in `hud.dart`, `VitaDebugOverlay` wraps any app in it, `VitaPad` reads
the pad through a `vita/pad` channel (`pad.c`, `waitChord` answers on the
rising edge of a button mask). The gallery shows the strip by default and
L+R+SELECT toggles it; the person pressed it and it toggled (gallery 63).

## FILES in the receiver

A browser on the left (mounts, directories, files; `vita_file_browser`'s
path rules) and a preview on the right. Rows are 40 px `GestureDetector`s,
no ink: the 30 px `InkWell` version in the gallery looked wrong on the
console, and the receiver has no Material anyway.

What each kind does, measured on the scratch receiver:

| Kind | Route | Result |
|---|---|---|
| PNG, JPEG | `Image.file` | `sample.png` draws |
| WAV | `audioplayers_vita`, MAIN port | plays |
| AAC (`.m4a`) | `audioplayers_vita`, sceAvPlayer, BGM port | `tone.m4a` plays; duration 3000 ms from the file's `mvhd`, since `sceAvPlayerGetStreamInfo` answers 0 right after activation |
| MP3 | `audioplayers_vita`, sceAudiodec, BGM port | `tone660.mp3` (4 s, 155 frames): plays to completed, no decode error |
| vpk | the receiver's own installer | LocalSend into `FVTA00002`: 23 MB unpacked in 30 s, `promoterif` result 0, art copied |
| text | first 64 KB | reads |
| video | sound only | no picture: the embedder has no external-texture route yet |

### The installer

`receiver/src/vpk.c` is the zip (stored and deflated, CRC checked, names
that would leave the root refused), the sfo's `TITLE_ID`, and `head.bin`
signed with the keyless digest of `tools/make-head-bin.py`. The template
is the receiver's own `app0:sce_sys/package/head.bin`: the promoter wrote
it, so it has the format the promoter reads. `tools/test-vpk.sh` builds the
file on the host and holds it against `unzip` and the Python: three vpks,
byte-identical, `head.bin` identical.

The install thread does what `install-vpk.sh` does: clear `ux0:data/pkg`,
unpack without the LiveArea art and the supervisor pair, read the title id,
write the header, `scePromoterUtilityPromotePkgWithRif`, copy the art into
`ux0:app/<id>`. Progress goes to `install-progress.txt`, one line the tab
polls; the DEPLOY log gets the outcome. `installvpk <path>` on the socket
and `install <path>` in the request file start it.

## Finding 1: START closed the dev server's port

After RUN, LocalSend answered `pong`, then its port refused connections
while the app kept drawing for eleven minutes. Its log (`0196`, line 251):

```
[dev] START pressed, shutting down
```

The dev server's accept loop closed its socket on a plain START press, the
m1 experiment's exit gesture, kept by accident in every app since. In a
Flutter app START is an ordinary button. With the supervisor abandoned
(ADR-0011) there was no other door: the console needed a hand.

Now START alone does nothing to the port, and **L+R+START held for one
second** hands the console to the receiver from any app, without a
network. The receiver refuses the chord for itself (a launch of the running
title drops to LiveArea; `0203` has the refusal line). The receiver's
engine is re-pinned so it runs the same loop.

## Finding 2: every plugin call leaked a thread

The scratch receiver went down in the middle of a self-update. Its log
(`0210`):

```
plugin: vita/audioplayers poll: sceKernelCreateThread 0x8002450D
os_thread.cc: 344: error: Could not start thread DartWorker: 11 (No more processes)
```

`plugin.c` runs each call on a job thread with a watchdog thread beside
it. The watchdog deleted the job thread and returned; nothing deleted the
watchdog, and on the Vita an ended thread stays allocated until someone
does. The audio view polls `poll` four times a second for as long as a
player exists, so the leak reached the kernel's limit in about two
minutes, and then the Dart VM could not start a worker either and aborted.

The watchdog ends with `sceKernelExitDeleteThread` now, as do the
receiver's delete and install threads. Four minutes with a live player on
the fixed build: no failure. The gallery's strip leaked the same way
through `waitChord`, two threads every 14 s; gallery 64 has the fix.

Rule for every thread in this tree: whoever creates it deletes it, or it
deletes itself on the way out.

## The engine's debug strip

Later the same day the strip moved into the engine, so every debug build
has it with no code of its own (`3e68221`, `094abf8`). Under GL the
embedder could not draw: Skia caches the context's state, and the frame is
not on the CPU. `gles2/` gained `fvgl_set_frame_hook`, a function its
display thread runs with each frame the GPU has finished, before the flip;
the embedder composes the strip into ordinary memory every twenty frames
(RobotoMono rasterised by `tools/gen-hud-font.py`) and the hook copies 34
rows into the frame. On the gallery at 60 fps the composition costs 73 to
78 µs a frame amortised (`hud` on the FRAMES line, log of build 70); the
copy runs on the display thread and is not in that figure.

Two things the first builds got wrong. An idle screen presents nothing,
so `overlay on` on the receiver drew nothing until some frame came: the
main loop now recomposes once a second when no frames flow and asks the
engine for one, and the receiver shows `fps 0.0` with live memory a second
after the toggle. And the columns moved as digits came and went; each is
now as wide as its widest value. The green 5x7 box is gone from both
paths.

## The Vita's Music app, measured and not used

Two facts, for the record: `sceMusicExportFromFile` takes our files
(`tone.m4a` → `music0:/ib/tone.m4a`, an MP3 → `music0:/kc/tone660.mp3`,
both result 0, working memory 8 MB), and
`sceAppMgrLaunchAppByUri(0xFFFFF, "psgm:play?titleid=NPXS10009")` returns
0 with the receiver still answering afterwards. The person does not want
the console's Music app in the loop, so neither is in the tree; MP3 goes
through sceAudiodec instead.

## Tools that lied

`selfupdate-receiver.sh --port 1342` waited for the new receiver on 1342
and reported "never came back" while it was up on 1341; the manifest went
to the same dead port. Both talk to the new receiver's port now.
