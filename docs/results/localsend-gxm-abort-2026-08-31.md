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

## Where to look next

1. **Reproduce it deliberately.** Both faults came after hours of uptime and a
   long memory slide. A soak that drives `glViewport` and the scissor path hard
   is a cheaper reproduction than waiting for the console to do it again.
2. **Check the reserve.** `sceGxmReserveVertexDefaultUniformBuffer` is unchecked
   in three places, and vitaGL is a vendored tree with an existing patch series
   for exactly this class of omission.
3. **Find who sets a two-pixel viewport**, if `R2` means what it looks like.
