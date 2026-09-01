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
| 0003 | [a-shader-that-failed-is-not-a-shader](0003-a-shader-that-failed-is-not-a-shader.patch) | Three more null-pointer paths behind a shader that did not compile, plus a shader cache that trusted a zero-byte file and a writer that created one |

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

## 0003, the shader cache and everything downstream of a failed compile

Found by scrolling a list fast. Four separate faults, all the same shape:
vitaGL has no path for "this shader does not exist" and walks the null.

**The cache writer creates the corruption.** `compile_shader` opened the
destination with `SCE_O_TRUNC` *before* serializing, so a process that died in
between left a **zero-byte `.gxp`** on the card. flutter-vita made one by
crashing four times in an afternoon; a console that loses power mid-write makes
the same file. Now: serialize first, write to `<name>.tmp`, and rename only
after a complete write.

**The cache reader trusted it.** `unserialize_shader` reads a count out of the
file and advances a pointer by it, with no reference to the file's length. On a
zero-byte entry that is a read from a zero-byte allocation followed by a copy
through whatever came back — the `sceClibMemcpy` data abort of 2026-09-01. Now
every advance is checked against the end of the buffer, a refused entry is
deleted so the next launch does not trip over it again, and the caller
recompiles. The three read sites also stopped freeing `s->source` before they
knew the load had worked, which had left nothing to compile from.

**The writer cached failures.** The cache write sat outside `if (s->prog)`, so a
compile libshacccg refused was followed by `serialize_shader` doing
`vgl_fast_memcpy(buf, s->prog, s->size)` — ten kilobytes read from address zero,
observed with `R1 = 0` and `R2 = 0x2a51`.

**And the linker used them.** `glLinkProgram` opens its analysis with
`sceGxmProgramGetParameterCount(p->fshader->prog)`. With a null program that is
a data abort inside GXM, observed with `R0 = 0`. GL has a word for this and it
is a failed link: the program is left `PROG_UNLINKED`, which is exactly what
`glGetProgramiv(GL_LINK_STATUS)` already reports.

### What it exposed

With the crashes gone, the underlying problem is visible and counted:

    flutter-vita: libshacccg refused 1 shader compiles (62 total)
                  -- those draws will not appear
    flutter-vita: vitaGL refused 1 program links (62 total)

Sixty-two in one session of scrolling. The compiler's own message is
`link failed but did not provide an info log`, on shaders combining a
rounded-rect clip with a colour-space transform and a texture sampler — Skia's
image-thumbnail program. On screen that is one blank icon where a JPEG
thumbnail belongs. **That is now the open bug**, and it is a legible one
instead of a crash.
