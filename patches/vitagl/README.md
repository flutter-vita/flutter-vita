# vitaGL patches

Against the checkout in `third_party/vitaGL` at `73dd57a`, built with
`make HAVE_SHADER_CACHE=1` — the VitaSDK package is built without it and
recompiles every shader on every launch, at 200–400 ms apiece.

Same working agreement as the other series: **never edit the vendored tree
without producing a patch file.** `third_party/` is gitignored and disposable;
these patches are the artifact.

| # | Patch | What it does |
|---|---|---|
| 0001 | [no-memcpy-into-a-failed-allocation](0001-no-memcpy-into-a-failed-allocation.patch) | Four texture paths checked their allocation and one did not. The one that did not is the one Skia uses |

## Applying

`../../tools/apply-patches.sh --apply` handles this series with the rest.
`libvitaGL.a` is **not** rebuilt by the app build, so after applying:

```bash
cd third_party/vitaGL && make HAVE_SHADER_CACHE=1 -j8
```

---

## 0001 — no memcpy into a failed allocation

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
