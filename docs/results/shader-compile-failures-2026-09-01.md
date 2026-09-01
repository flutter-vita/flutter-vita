# The shader libshacccg will not compile

One row in localsend's receive history holds a JPEG. Scrolling to it takes the
app from 29 fps to 5, and until 2026-09-01 it took it down entirely. The
thumbnail on that row is blank.

Reported by the user, who named the row before any of this was measured:
*"I think because IMG_4777.jpeg preview."* That is exactly what it is.

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
closed in [patches/vitagl/0003](../../patches/vitagl/0003-a-shader-that-failed-is-not-a-shader.patch),
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

## Where to look next

1. **Reduce the shader to the construct that fails.** vitaGL's translated Cg is
   available at the point of failure; compiling variants of it offline against
   libshacccg is the direct route, and nothing about it needs the console.
2. **Ask Skia for less.** The colour-space transform is there because the image
   has an embedded profile. Whether this port should be asking Skia for
   colour-managed image draws at all is a real question — the panel is not
   wide-gamut.
3. **Stop the per-frame retry** even when the compile cannot be fixed. Skia has
   no way to know the program is unbuildable; vitaGL refusing the link tells it
   nothing it remembers.
