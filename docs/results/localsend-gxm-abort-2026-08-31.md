# The SceGxm data abort, twice, to the register

On 2026-08-31 at 21:44:59 localsend died on the console. The user had been
tapping received files in the history list, so the tap was the first suspect.
It is not the cause. This is what the dump says instead.

Dump: `out/dumps/localsend-gxm-1788205499.psp2dmp`, complete, not a `.tmp`.
ELF: `out/dumps/elf/localsend-20260831-2130.elf`, the binary that produced it.

## The tap does not crash anything

Fresh boot, same build, one PNG received, receive history open, seventeen taps
on file rows over sixteen `tap` calls from the host:

    $ printf 'log\n' | nc -w 25 192.168.0.32 1339 | grep -c "libc.so.6"
    17
    heap=17M/18M free user=21504K
    heap=17M/18M free user=21504K

Seventeen throws, no fault, and memory flat across all of them. Blocker 1 in
[the release list](localsend-release-blockers-2026-08-31.md) stands as written:
the tap throws and does nothing. It does not take the app down.

## What did

    pthread <0x40010197>
        Stop reason: 0x30004 (Data abort exception)
        Status: 0x1 (Running)
        PC: 0xe00aa728 (SceGxm@1 + 0x1e638)
        R0: 0x70100254   R2: 0xbf800000   R3: 0x4
        R11: 0x70100250  LR: 0x1

Thread `0x40010197` is the eighth thread created, and the creation order in the
log is vglInit's two threads and then `io.flutter.ui`, `io.flutter.raster`,
`io.flutter.io`, `io.worker.1`, `io.worker.2`. It is **io.flutter.raster** --
the thread that owns the GL context and is entitled to be in GXM. Every other
thread is waiting, including vitaGL's garbage collector.

The registers are identical to `psp2core-1788119930` from 2026-08-30: same PC,
same `R0` 0x70100254, same `R11` 0x70100250, same `LR` of 1. Two faults a day
apart landing on the same instruction with the same operands is one bug, not
two. [The stall write-up](localsend-stall-2026-08-31.md) asked for something to
link them; this links them.

## Where in vitaGL

The 08-30 dump could not be symbolicated -- its ELF was gone. This one has its
ELF, and the return addresses under SP resolve:

| stack slot | address | source |
|---|---|---|
| SP+0x0c | `flutter_vita_app@1 + 0x1311f75` | `glViewport` — `misc.c:342` |
| SP+0x34 | `flutter_vita_app@1 + 0x13143eb` | `update_scissor_test` — `tests.c:334` |

Segment 1 loads at 0x8104b000 at runtime against an ELF vaddr of 0x81000000, so
those offsets are `arm-vita-eabi-addr2line 0x82311f74` and `0x823143ea`.

`misc.c:342` is the statement after `vglSetViewport(gxm_context, ...)`, and it
is the slot nearest SP, so that is the live frame: the raster thread called
`glViewport`, vitaGL called into GXM, and GXM faulted. `R2` is `0xbf800000`,
which is -1.0f, and vitaGL computes `y_scale = -(height >> 1)` -- a viewport two
pixels high produces exactly that.

`tests.c:334` is `sceGxmSetUniformDataF(vertex_buffer, clear_depth, ...)` in
`update_scissor_test`, two lines after a
`sceGxmReserveVertexDefaultUniformBuffer` **whose return value vitaGL never
checks** -- not at `tests.c:297`, not at `tests.c:332`, not at `misc.c:673`.
Whether that frame is live or stale, an unchecked reserve in the same call path
as the fault is worth closing on its own terms.

## What it is not

**Not a texture pool exhaustion.** `vgl_oom_count` is printed by the embedder
whenever it changes ([patch 0001](../../patches/vitagl/0001-what-a-failed-allocation-costs.patch))
and never appeared in the log.

**Not suspend or resume.** The last `FRAMES` report before the fault reads
`idle gaps 0 | max 64 ms`, so the app was rendering continuously up to the
moment it died.

**Not the exception handler.** A Dart throw does not enter GXM.

## What it happened alongside

The process had been up 2 h 14 min. Free user memory over that session:

| | at start | at the fault |
|---|---|---|
| free user | 45,056 K | 16,384 K |
| Dart heap | 0M / 2M | 20M / 21M |

The same monotonic slide as the stall, ending 12 MB lower. Opening the receive
history page is a large single step in it and reproduces on a fresh boot: the
heap goes 7M/8M to a 27M/27M peak and settles at 17M/18M, and free user memory
drops 27,648 K to 21,504 K, for a list of eight rows with no thumbnails.

## The three-dots menu, not the row

Corrected by the user after the first pass: the tap that preceded the fault was
on a row's overflow menu and then **Show in folder**, not on the row itself.
That changes the suspect list, because a `PopupMenuButton` is not a tap that
throws -- it is a route that opens, and it opens by animating a clip from
nothing to full size.

Every frame of that animation calls `glScissor` with a rectangle that is
briefly degenerate, and `update_scissor_test` does not defend against one:

    region.x = region.gl_x < 0 ? 0 : region.gl_x;
    region.w = region.gl_w;
    ...
    if (region.x + region.w > active_w) region.w = active_w - region.x;

Nothing clamps `region.w` or `region.h` at zero from below. A scissor that is
fully off-screen makes `region.w` negative, and the width and height then reach
GXM through

    sceGxmSetRegionClip(gxm_context, SCE_GXM_REGION_CLIP_OUTSIDE,
                        region.x, region.y,
                        region.x + region.w - 1, region.y + region.h - 1);

whose parameters are **unsigned**. A zero-width scissor alone is enough:
`x + 0 - 1` is `x - 1`, so xMax lands below xMin and GXM is handed an inverted
region to compute tile ranges from.

That fits the symptom better than uptime does. It puts the fault in the same
two functions the stack names, it explains why the crash follows an
interaction rather than arriving at random, and `R2 = -1.0f` is what
`y_scale = -(height >> 1)` produces for a two-pixel-high viewport -- the sort
of size a menu passes through on its way open.

### Reproduced, 2026-09-01, in one tap

Open the receive history, tap the overflow menu on a row. That is the whole
recipe. It does not need a transfer, it does not need hours of uptime, and it
does not need the menu to be tapped a second time -- the 08-31 fault came after
**Show in folder**, but the one on 09-01 arrived with the menu merely open.

Two runs, two outcomes from the same tap:

| run | outcome |
|---|---|
| 09-01 08:4x | the app **stalled**: no present for 70 s, raster parked at `ran +0`, a tap injected into the freeze produced no frame |
| 09-01 08:50 | the app **faulted**: `psp2core-1788245394`, `SceGxm@1 + 0x1e638`, `R0 0x70100254`, `R11 0x70100250`, `LR 1` |

The fault is the third with those registers, and the first with a stack that
could be resolved on the spot: `glViewport` at `misc.c:342` and
`update_scissor_test` at `tests.c:334`, the same two frames at the same offsets
as 08-31. The crashing thread is `0x4001019B`, which the watchdog's own table
had already named `io.flutter.raster` -- previously that was an inference from
thread creation order.

### The clamp did not fix it

[patches/vitagl/0002](../../patches/vitagl/0002-an-empty-scissor-is-not-an-inverted-one.patch)
clamps `region.w`/`region.h` at zero, skips the tile clipper for an empty
region, and clamps a zero-size viewport to 1x1. Built into `libvitaGL.a`,
linked (`nm` confirms `vgl_degenerate_scissor` in the shipped ELF), deployed.

**Same tap, same death.** So the inverted region clip is a real defect and not
this one. The patch stays, described as what it is.

What that rules out matters as much: the fault is not the *arguments* vitaGL
computes for the clip. It is in `sceGxmSetViewport` or in the state the context
is in when it gets there.

## Where to look next

1. **Open the overflow menu.** The hypothesis above is one tap to test and one
   clamp to fix, and it is the only account of the fault that does not need
   hours of uptime to arrive.
2. **Check the reserve.** `sceGxmReserveVertexDefaultUniformBuffer` is unchecked
   in three places, and vitaGL is a vendored tree with an existing patch series
   for exactly this class of omission.
3. **Find who sets a two-pixel viewport**, if `R2` means what it looks like.
