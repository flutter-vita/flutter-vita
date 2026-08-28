# vitaGL patches

Against the checkout in `third_party/vitaGL` at `73dd57a`, built with

```bash
make HAVE_SHADER_CACHE=1 TEXTURES_SPEEDHACK=1 NO_SPLASHSCREEN=1 -j8
```

**All three flags matter and none is the default.** Without `HAVE_SHADER_CACHE`
— which is how the VitaSDK package is built — every shader recompiles on every
launch at 200–400 ms apiece. `TEXTURES_SPEEDHACK` is the subject of its own
section below.

`NO_SPLASHSCREEN` defines `SKIP_SPLASHSCREEN`, which stops `vglInit` calling
`invoke_splashscreen()`. Without it every launch of every app on the GPU path
spends about two seconds showing vitaGL's rotating logo, and it is not a
cosmetic two seconds: the swap that ends it signals the splash thread and then
waits on a semaphore with a **NULL timeout**, so the calling thread blocks
until the animation finishes. The thread exits only when its fade-out alpha
reaches zero — `SPLASH_FADE_SEC` (1.0 s) of fade-in, which ignores the stop
request, then a second of fade-out at 1.0 alpha per second.

It became visible on every app rather than only on opt-in GL runs when the
renderer default flipped on 2026-08-24. The only other thing the define changes
is `vglGetCaveBuffer`, which returns NULL and a size of 0 with the splash
compiled out; nothing in this port calls it.

Same working agreement as the other series: **never edit the vendored tree
without producing a patch file.** `third_party/` is gitignored and disposable;
these patches are the artifact.

| # | Patch | What it does |
|---|---|---|
| 0001 | [what-a-failed-allocation-costs](0001-what-a-failed-allocation-costs.patch) | A texture upload that memcpy'd into NULL, and a collector wait that slept a flat second |

## Applying

`../../tools/apply-patches.sh --apply` handles this series with the rest.
`libvitaGL.a` is **not** rebuilt by the app build, so after applying:

```bash
cd third_party/vitaGL && make HAVE_SHADER_CACHE=1 -j8
```

---

## `TEXTURES_SPEEDHACK=1`, and why it is not optional here

Upstream describes it as making `glTexSubImage2D` "non fully OpenGL compliant
but … slightly faster". On this port it is the difference between running and
running out of memory.

Without it, `_glTexSubImage2D` clones any texture the GPU touched in the last
`FRAME_PURGE_FREQ` (4) frames before modifying it, and the old copy is freed by
the collector rather than immediately. Skia's glyph atlas is 2048×2048 A8 —
4 MB — and Skia sub-uploads into it whenever text changes. Each of those
uploads therefore allocated 4 MB and left 4 MB pending collection.

That is what exhausted the pools on 2026-08-24. With the flag, the same
benchmark run reports **zero** dropped uploads.

The compliance being traded away is writing into a buffer the GPU may still be
reading from the previous frame: a tear on one frame of one texture. It is the
same trade patch 0001 makes when an allocation fails, made unconditionally.

Note the flag changes `struct texture`, so **`make clean` first** — an
incremental build links objects that disagree about the layout.

---

## 0001 — what a failed allocation costs

`_glTexSubImage2D` clones a texture before modifying it, if the GPU used that
texture within the last `FRAME_PURGE_FREQ` frames:

```c
void *texture_data = gpu_alloc_mapped_for_gpu(size);
vgl_fast_memcpy(texture_data, tex->data, size);   /* <- no check */
```

`gpu_alloc_mapped_for_gpu` can and does return NULL: it tries VRAM, RAM,
PHYCONT and BUDGET in turn, then runs the garbage collector up to
`FRAME_PURGE_FREQ` times, and then gives up. When it gives up, that `memcpy`
writes to address zero.

**On this console that is not an app crash.** A data abort runs no user code,
so nothing releases the GXM context: the PS button stops responding and only
the power button recovers the machine ([ADR-0014](../../docs/adr/0014-gpu-backend-via-vitagl.md)).
It happened on 2026-08-24 during a benchmark run, with `size` = 0x3FFFC0 —
4 MB, a 2048×2048 A8 glyph atlas, which is exactly what Skia hands to
`glTexSubImage2D` as text comes and goes.

The patch skips the clone instead. The cost is writing into a buffer the GPU
may still be reading this frame: a tear on one frame of one texture, against a
power cycle. Three sibling paths in `gpu_utils.c` — the paletted allocator and
two mipmap reallocation fallbacks — had the same shape and are guarded the same
way, though Skia does not appear to reach them.

A dropped upload is invisible otherwise, and invisible is how a benchmark ends
up measuring a picture of a frame rather than a frame. vitaGL's own `vgl_log`
is `sceClibPrintf`, readable only with a kernel plugin this port deliberately
does not use, so the patch adds `unsigned int vgl_oom_count` and the embedder
prints it alongside its periodic loop statistics.

### The second half: a flat second of sleep

Reaching that NULL was not free either. `gpu_alloc_mapped_aligned_unsafe_for_*`
asks the collector to run and then waits for it like this:

```c
sceKernelSignalSema(gc_mutex[0], 1);
sceKernelDelayThread(1000000);          /* one second */
```

It retries itself up to `FRAME_PURGE_FREQ` times, so a single contended
allocation froze the raster thread for four seconds — the log showed an 8 s
frame, two such calls back to back — while the collector's actual work is
freeing a pointer list and destroying a few render targets.

The collector already signals `gc_mutex[1]` at the end of every cycle, which is
the event the caller wants. The patch waits on it with a 50 ms ceiling and
hands the slot straight back, leaving the credit accounting unchanged. Worst
observed frame gap across a full benchmark run went from **8145 ms to 66 ms**,
and `route_bare` — an empty page pushed onto the navigator — went from stalling
to holding 60 fps outright.
