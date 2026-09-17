# The shader libshacccg would not compile — FIXED 2026-09-01

One row in localsend's receive history holds a JPEG. Scrolling to it took the
app from 29 fps to 5, and before that day it took it down entirely.

Reported by the user, who named the row before any of this was measured:
*"I think because IMG_4777.jpeg preview."* That is exactly what it was.

**The cause was vitaGL's own translation header, not Skia and not libshacccg.**
`#define s x` renamed every variable called `s` in every shader. Fixed in
[patches/vitagl/0004](../../engine/patches/vitagl/0004-the-define-that-renamed-every-s.patch);
the row now holds 29 fps with the raster thread at 8%. Read on for how it was
found — the bisection is the useful part, because the compiler never said a
word about what it objected to.

## Measured

Same list, same gesture, two positions:

| scroll position | program links refused, 4 scrolls | frame rate |
|---|---|---|
| top (no image rows on screen) | **0** | 29 fps steady |
| bottom (IMG_4777.jpeg on screen) | **34** | 5.4 fps, raster max 1.77 s |

## What fails

`libshacccg` refuses to build the program, and says only:

    Errors:
    link failed but did not provide an info log

The shader is Skia's image draw with a rounded-rect clip and a colour-space
transform:

    uniform float uSrcTF_S0[7];
    uniform float3x3 uColorXform_S0;
    uniform float uDstTF_S0[7];
    uniform float4 uinnerRect_S1;
    uniform half2 uradiusPlusHalf_S1;
    sampler2D uTextureSampler_0_S0;
    ...
    x = (x < D) ? (C * x) + F : pow(A * x + B, G) + E;
    ...
    mediump float _6_alpha = clamp(uradiusPlusHalf_S1.x - length(_5_dxy), 0.0, 1.0);
    gl_FragColor = outputColor_S0 * output_S1;

Transfer functions as seven-element float arrays, a 3x3 matrix, `pow`, and a
mix of `half`/`float`/`mediump`/`highp` in one program. Which of those the
compiler objects to is not yet known — it does not say, and the message comes
from the link stage, after vitaGL's GLSL-to-Cg translation.

## What was fixed, and what that leaves

The failure used to be fatal. Four separate null-pointer paths behind it are
closed in [patches/vitagl/0003](../../engine/patches/vitagl/0003-a-shader-that-failed-is-not-a-shader.patch),
and a fifth thing it did was retry forever:

**A failed compile caches nothing**, so the same program was recompiled on the
next frame, and the next. Each attempt costs libshacccg 330 ms to 1090 ms.
Seven consecutive frames of it measured `0.00 fps` with a raster max of 1.1
seconds. vitaGL now remembers a refusal for the run and does not attempt it
twice: **99 compile attempts in a session became 2.**

That is most of the 2 fps and none of the cause. What remains is that Skia asks
for the program again every frame the row is visible, is refused, and falls back
to something expensive — the raster thread samples inside FreeType's scan
converter (`gray_render_line`, `gray_conic_to`) during those frames. 708 refused
links in one session, 34 in four scrolls with the row on screen, 0 with it off.

The refusal is remembered per *shader*, not per *program*, and deliberately not
persisted to the memory card: a compile can fail for a transient reason, and a
marker file would turn one bad afternoon into a draw that never appears again.

## The cause: `#define s x`

libshacccg has no host build, so the shader was bisected on the console. The
app picks a GLSL pair out of `ux0:data/flutter-vita/shadertest` on its next
present, compiles it, and writes the verdict back; `tools/shader-probe.sh`
drives that from here. Thirty-odd variants later:

| probe | fragment shader | verdict |
|---|---|---|
| f10 | `float s = 1.0; return s * x;` **inside a function taking `x`** | LINK FAILED |
| f11 | same function, no local | LINK OK |
| f14 | the same local, in `main()` | LINK OK |
| g1 | local named `q` instead of `s` | LINK OK |
| g2, g3, g4 | local named `s` | LINK FAILED |
| h1, h2 | local named `s`, parameter renamed `x` → `y0` | LINK OK |

All five `SHARK_OPT` levels failed identically, so it was never register
allocation. The one thing every failure had in common was a variable called `s`
in a function whose parameter was called `x`.

`source/shaders/glsl_translator_hdr.h` carried six lines:

```c
#define s x
#define t y
#define st xy
#define ts yx
#define ss xx
#define tt yy
```

They are there because GLSL spells texture-coordinate swizzles `.s`/`.t` and Cg
only knows `.x`/`.y`. Cg's preprocessor has no notion of scope, so they renamed
every identifier called `s` or `t` anywhere in the shader. Skia's colour
transfer function is:

```glsl
highp float src_tf_S0_ff(highp float x) {
  highp float s = sign(x);
  x = abs(x);
  x = x < D ? C * x + F : pow(A * x + B, G) + E;
  return s * x;
}
```

which reached libshacccg as `highp float x = sign(x);` — a redeclaration of the
parameter. The compiler rejected it and gave no info log, which is why reading
the error got nobody anywhere for two days.

Every Skia program with a colour-space transform contains that function. This
was never about the JPEG; the JPEG is just the only file in that list with an
embedded profile.

## The fix

Patch 0004 deletes the six defines and rewrites the swizzles in
`glsl_translator_process` instead, on the shader body only, where a leading `.`
with an identifier, `)` or `]` to its left can be required:

```c
static void glsl_rewrite_st_swizzles(char *src);
```

`v.st` still becomes `v.xy`; `float s` is left alone. Runs are one to four
characters of `[st]` and must not be followed by an identifier character, so
`.ststs` and `foo.s_bar` are not swizzles and are not touched. Lengths match, so
the rewrite is in place and cannot fail.

Confirmed on the console with a probe carrying both halves at once — a local
named `s` in a function taking `x`, plus `.st`, `.s` and `.t` swizzles. It links,
and the Cg it produced reads:

```c
highp float src_tf_S0_ff(highp float x){
highp float s=sign(x);
...
vec4 c=texture2D(uTex,vUV.xy);
gl_FragColor=vec4(src_tf_S0_ff(c.x),src_tf_S0_ff(c.y),c.b,c.a);
```

## After

Same row, same gesture, on the build of 2026-09-01:

| | before | after |
|---|---|---|
| frame rate with the JPEG row on screen | 5.4 fps | **29.0 fps** |
| raster thread | max 1.77 s | max 3.7 ms, 8% of frame |
| refused links, 4 scrolls | 34 | **0** |

29 fps is this port's ceiling on every screen (`gl wait` is 31 of the 34 ms) and
has its own entry in the blockers list. The shader is no longer part of it.

## Still open

**The thumbnail is still blank**, and it is no longer a shader problem: no
refused link appears in the log and no decode error either. `SmartFileThumbnail`
uses `Image.file(File(path), cacheWidth: 64)`, whose `errorBuilder` would draw
the file-type icon — the HEIC row beside it does exactly that. An empty tile
with neither picture nor icon is what `Image` draws while a decode is still
pending, so the scaled JPEG decode is finishing neither way. Separate bug,
separate hunt.
