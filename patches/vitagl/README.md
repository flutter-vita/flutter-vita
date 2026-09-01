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
| 0002 | [the-reservation-vitagl-never-checked](0002-the-reservation-vitagl-never-checked.patch) | `sceGxmReserveVertexDefaultUniformBuffer` can refuse, and vitaGL wrote through the null it left. Four data aborts. Also clamps an empty scissor and a zero-size viewport |

## 0002, the one that took the console down

`update_scissor_test` and `glClear` reserve a slice of GXM's default uniform
buffer and then write into it:

```c
void *vertex_buffer;
sceGxmReserveVertexDefaultUniformBuffer(gxm_context, &vertex_buffer);
sceGxmSetUniformDataF(vertex_buffer, clear_position, 0, 4, &clear_vertices->x);
```

The reservation can be refused — the scene's pool is finite, and it is refused
outright outside a scene. On refusal `vertex_buffer` is never written, so
`sceGxmSetUniformDataF` gets whatever was on the stack, and GXM writes through
it. vitaGL does not check the return value in any of the three places it calls
these functions.

flutter-vita took that data abort four times between 2026-08-30 and
2026-09-01: `SceGxm@1 + 0x1e638`, always on the raster thread, always
`R4 = 0`, always `R11 = 0x70100250` — which the core dump shows holds
`{-1.0, 1.0, 1.0, -1.0}`, these very clear vertices, in GXM-mapped memory.

**It reproduces in one tap**: open an overflow menu in a Flutter app on the GL
path. With the guard, the same tap survives twenty cycles and the log reads
`GXM refused 12 uniform-buffer reservations`. The same tap used to freeze the
app inside twenty-two seconds when it did not kill it outright; two minutes
with the menu open is now quiet.

Skipping the draw costs the scissor stencil for one frame, so a clip lands one
frame late. The alternative is the console going down.

The patch also clamps an empty or negative scissor before it reaches
`sceGxmSetRegionClip` — whose bounds are **unsigned**, so a zero width puts
xMax one below xMin — and a zero-size viewport before `sceGxmSetViewport` gets
a scale of zero. Those are real defects found while chasing this one. They were
**not** the cause: the fault reproduced with them in and the counter at zero.
They stay because an inverted region clip is not something to leave in.

Full account in
[docs/results/localsend-gxm-abort-2026-08-31.md](../../docs/results/localsend-gxm-abort-2026-08-31.md).
