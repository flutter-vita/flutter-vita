# ADR-0014: The raster pass is the bottleneck, so the GPU becomes the target

**Status:** Accepted — direction settled by measurement; the gating spike
passed all four exit criteria on hardware on 2026-08-22
**Date:** 2026-08-21

## Context

[ADR-0003](0003-software-rendering-first.md) shipped software rasterisation and
parked GLES2 as "a Phase 5 optimisation, measured against the software baseline
per workload rather than adopted wholesale". Its revisit trigger asked for
exactly this document:

> If the M3 baseline measurement shows the software path cannot reach the
> "laggy but working" bar on a counter app, GLES2 stops being an optimisation
> and becomes a Phase 3 blocker. **That reordering should be an explicit new
> ADR.**

Until 2026-08-21 the trigger could not be evaluated, because nothing separated
raster cost from everything else in a frame. The engine now times the raster
pass — `AcquireFrame` to the end of the encode callback — independently of the
present. That closes the question.

## The measurement

```
localsend, Receive screen:
FRAMES active 60 @ 205034 us = 4.87 fps (raster 199559 us = 97%, blit 1278 us = 0%, dmg 13%)
```

An active frame is raster + present + everything else, where "everything else"
is the UI thread: Dart building and laying out. The split is **97% / 0.6% /
~3%**.

| App / screen | dmg | raster | blit |
|---|---|---|---|
| manga_reader, idle | 0% | 704 us | 2 us |
| manga_reader, library | **5%** | **13,933 us** | 553 us |
| manga_reader, scrolling | **89%** | **13,965 us** | 9,713 us |
| localsend, Receive | 13% | **199,559 us** | 1,278 us |

Read the middle two rows together: **5% damage and 89% damage cost the same
raster.** Eighteen times the area, identical cost. The blit tracks area
faithfully — 553 us against 9,713 us — because a memcpy is honest about how
many bytes it moves. Raster is not, because **area is not work**.

What is inside localsend's 13% is one widget:

```dart
Transform.rotate(               // 30 fps tick
  child: ColorFiltered(         // forces a saveLayer
    colorFilter: ColorFilter.mode(primary, BlendMode.srcATop),
    child: Assets.img.logo512.image(width: 200, height: 200),  // 512 -> 200
  ),
)
```

Removing only the `ColorFiltered` and rebuilding took raster from ~199,000 us
to ~110,000 us. So the colour filter is roughly half, and the rotated downscale
is the other half. **Both are single-pass operations on any GPU**, and both are
worst-case for a CPU rasteriser: an offscreen allocation, a filter over every
pixel of it, and bilinear resampling through a matrix that changes every frame
so nothing caches.

## The two cheaper alternatives are now measured, and both fail

ADR-0003 named both. Neither survives the numbers.

**A NEON blit — ADR-0003's "cheapest large win in the embedder" — is now worth
nothing.** That recommendation was made when the blit was 8.06 ms of a
full-screen frame. [ADR-0007](0007-enable-partial-repaint-in-software-path.md)
then made the blit proportional to damage, and it is now **0.6%** of
localsend's frame and 2% of manga_reader's quiet one. Optimising it perfectly
buys under 1%. This is a good outcome recorded plainly: one ADR obsoleted
another's headline recommendation, and only measurement noticed.

**Reduced-resolution rendering is insufficient on its own.** 720×408 is 1.78×
fewer destination pixels. Even assuming raster scaled linearly with them — and
the 5%-equals-89% result says it does not scale with *area* at all — localsend
goes from 200 ms to ~112 ms, which is 8.9 fps. Reaching 30 fps needs raster
under ~30 ms, a 6.7× reduction. Resolution offers 1.78×. It remains genuinely
useful for manga_reader, where ~14 ms would become ~8 ms and 60 fps comes into
reach, so this is a **per-workload** tool, not a solution.

Neither is a path to a general fix, and that is the point: both scale the
existing cost down by a constant, while the problem is that certain *operations*
cost hundreds of times what they should.

## Feasibility, checked rather than assumed

ADR-0003's own GN comment still says the opposite of what is true:

> Software rasterisation only, per ADR-0003. The Vita's GPU is reachable
> **solely through libgxm — there is no GL, GLES, Vulkan or Metal driver on the
> device** […]
> — `flutter/tools/gn`, the `target_os == 'vita'` branch

That premise is stale. Checked on this machine:

| Question | Answer |
|---|---|
| Is there a GLES driver? | **Yes.** `libvitaGL.a`, `vitaGL.h` and a `GLES2/` include tree are already installed in VitaSDK |
| Does it conflict with [ADR-0004](0004-static-single-binary.md)? | **No.** vitaGL ships as a **static archive**. No `dlopen`, no shared object |
| Is Ganesh even compiled? | **Yes, already.** The vita GN branch sets `skia_enable_ganesh = True` with every backend off, because the engine assumes `GrDirectContext` as a *type* far more widely than it assumes a GPU |
| Do Ganesh GPU objects link for this target? | **Yes.** `gpu.LatticeOp.o` is in the shipped static archive today |
| Then what was the `dangerous relocation` link failure? | **Incidental.** `ninja -t query` names its consumers as `geometry_benchmarks` and **`libtessellator.so`** — a benchmark and a *shared library*. BFD aborted inside `elf32_arm_add_dynreloc`, emitting **dynamic** relocations for a link mode ADR-0004 means this port never performs. Neither target is ever built here |
| Is partial repaint lost on GL? | **No.** `FlutterOpenGLRendererConfig` carries `present_with_info` and `populate_existing_damage` precisely for dirty-region management |

That last row corrects a fear worth naming, because the software surface's own
comment invites it: *"the GL and Metal embedders cannot make that promise, since
they present by swapping buffers"*. That is about
`BackingStoreRetainsPreviousFrame` — handing back one surface forever — not
about damage support. The GL path tracks existing damage **per back buffer**
instead, which is more work in the embedder but is the supported, upstream way.

## Criterion 1: passed on hardware, 2026-08-21

`spikes/g1-vitagl` runs on the console and reports:

```
GL_VENDOR                   Rinnegatamante
GL_RENDERER                 SGX543MP4+
GL_VERSION                  OpenGL ES 2.0 VitaGL
GL_SHADING_LANGUAGE_VERSION 1.00 ES

compile fragment shader            PASS
compile vertex shader              PASS
link program                       PASS
FBO with texture attachment        PASS  status 0x8CD5
draw into FBO and read back        PASS  centre pixel rgba 0,255,0,255
```

The readback is the load-bearing line: green is what the fragment shader
writes, so it proves runtime GLSL compilation, program linkage, render-to-
texture and a real draw, rather than merely the absence of reported errors.
Render-to-texture passing matters most, because every `saveLayer` is one — and
`saveLayer` is what costs half of localsend's 199 ms frame.

### Limits, for criterion 3

| Limit | Value | Note |
|---|---|---|
| `GL_MAX_TEXTURE_SIZE` | 4096 | Comfortable |
| `GL_MAX_RENDERBUFFER_SIZE` | 4096 | Comfortable |
| `GL_MAX_VERTEX_ATTRIBS` | 16 | Comfortable |
| `GL_MAX_TEXTURE_IMAGE_UNITS` | 16 | Comfortable |
| `GL_MAX_VERTEX_UNIFORM_VECTORS` | 128 | Comfortable |
| `GL_MAX_VARYING_VECTORS` | 8 | The GLES2 floor; Ganesh targets it |
| `GL_MAX_FRAGMENT_UNIFORM_VECTORS` | **16** | **64 floats. Worth watching** |

Free pools after a context: VRAM 76 MiB, RAM 124 MiB, phycont 26 MiB.

Sixteen fragment uniform vectors is the one number that is not obviously
enough. It is the GLES2 minimum, and Skia's generated fragment shaders for
gradients, complex clips and colour filters can exceed it — which would surface
in criterion 3 as a link failure on a *specific* paint rather than as anything
systemic. Flagged here so it is not read as a surprise later.

## Criterion 0, added 2026-08-21: what a shader costs at run time

This was not in the exit criteria and should have been. The criteria gate on
whether the API works and say nothing about what using it costs, and shader
compilation is the one cost that could make a working GPU backend *worse* than
software for a UI toolkit -- a slow steady state is usable, a freeze every time
a new widget first paints is not.

Measured on hardware. `glCompileShader` is 10 us, because vitaGL only records
the source; all of the cost is `glLinkProgram`, where libshacccg runs:

| Shader | Cold | Cached, fresh process |
|---|---|---|
| trivial (89 chars) | 205,450 us | **2,916 us** |
| medium (150 chars) | 318,446 us | **3,290 us** |
| heavy (229 chars) | 404,640 us | **3,132 us** |

It is real compilation -- the cold time tracks complexity across an order of
magnitude of arithmetic -- with a floor of ~200 ms that even a one-line shader
pays. A frame at 30 fps is 33,333 us, so an uncached shader costs six frames at
minimum, and Ganesh generates one per paint configuration.

**The cache is what makes this survivable, and it is off in the VitaSDK
package.** That build has `HAVE_SHADER_CACHE=0`: `vglSetShaderCachePath` is a
two-byte `bx lr` and the archive imports only `sceIoMkdir`, no `sceIoOpen` or
`sceIoWrite`, so it cannot write a `.gxp` whatever path it is handed. The
documented setter silently does nothing. This was diagnosed by symbol size --
`vglSetTextureCacheFrequency` and `vglSetupScratchMemory` are also two bytes,
and the header documents both as requiring a `HAVE_*` flag, while every real
`vglSet*` is 0xc to 0x26 bytes.

Rebuilt from source with `make HAVE_SHADER_CACHE=1`, the same shaders load in
about 3 ms **regardless of complexity**, and the cache survives a process
restart. So the cost is once per shader per device, not once per launch.

### Consequences for the GPU direction

- **vitaGL must be built from source.** The packaged archive cannot be used as
  shipped. That is a new build dependency, and a small one next to what it buys.
- **First run still pays.** N distinct shaders cost N x ~250 ms the first time
  each is seen. For a hundred shaders that is ~25 seconds spread over first use.
- **A pre-warmed cache looks shippable.** The cache is plain `.gxp` files keyed
  by a hash of the source, and every Vita has the same SGX543MP4+, so a cache
  built on one console should be valid on all of them. Shipping one inside the
  `.vpk` would remove the first-run cost entirely. Unverified, and the obvious
  next question.

## Criterion 2: passed on hardware, 2026-08-21, and the cause was not the GPU

```
GrDirectContext created            PASS
backend                     0 (kOpenGL)
maxTextureSize              4096
maxRenderTargetSize         4096
GPU render target surface          PASS
draw and submit                    PASS
```

Three things had to be supplied before `GrDirectContexts::MakeGL` returned a
context, and none of them is the interesting one:

- **Six shims** for entry points vitaGL declares in `GLES2/gl2.h` and does not
  implement. `GrGLInterface::validate()` rejects an interface with any of the
  92 unconditionally required functions missing, and reports which branch fired
  to nobody in a release build. Two of the six are not honest implementations:
  `glBlendColor` discards its argument because vitaGL has no constant blend
  colour, and `glGetRenderbufferParameteriv` returns zeroes.
- **A suffix-stripping loader.** Skia's assembler asks for extension entry
  points by their suffixed names — `GET_PROC_SUFFIX(PopGroupMarker, EXT)`
  requests `glPopGroupMarkerEXT` — and vitaGL exports the core spelling with no
  alias. A function that is present fails to resolve on its name alone, which is
  why an offline symbol-table diff said the debug-marker block was satisfied and
  the console disagreed.
- **`GL_NUM_PROGRAM_BINARY_FORMATS` forced to zero.** vitaGL answers 1 and
  advertises `GL_OES_get_program_binary` without providing its entry points,
  which is the same trick that broke `validate()` one layer up.

**What actually blocked it was libstdc++.** Bisecting down from `MakeGL` with
per-call-site traces ended at `SkMessageBus::Get()`, which is

```cpp
static auto* bus = new SkMessageBus<...>();
```

— a function-local static with a dynamic initialiser, and no GL or Skia in it.
A probe added to the spike shows a plain `new` succeeding and the identical
allocation behind a function-local static killing the process: **libstdc++'s
`__cxa_guard_acquire` faults in this statically linked VitaSDK build.**
Supplying the ARM EABI pair by hand — the guard is a 32-bit word whose low bit
means initialised — makes the probe pass and carries Ganesh all the way to a
drawn frame, because a definition in the program overrides the archive's and
Skia's own statics then use it too.

This is a much larger fact than the GPU work. Every dynamically initialised
function-local static anywhere in the engine goes through those guards, and it
is a candidate explanation for the intermittent hard fault that has been open
since the corpus work. The spike's version is correct for single-threaded
initialisation and nothing more; the engine needs a real one, and it is the
first item of the engine work below.

## Criteria 3 and 4: passed on hardware, 2026-08-22

`spikes/g2-ganesh` now draws the three operations from the measurement above,
on a 960×544 Ganesh render target and on an `SkSurfaces::Raster` of the same
size and colour type, and compares both the pixels and the clock. A baseline
draw — the same image, unscaled, unfiltered, no offscreen — runs alongside so
the three can be read as differences rather than absolutes.

### Criterion 3: the GPU agrees with the software rasteriser

There is no oracle on this console, so "correct" is defined as agreement with
the path the port ships today. A 320×320 window centred on the widget is read
back from both surfaces and compared per channel.

| operation | px gpu | px sw | colours gpu | colours sw | mean err | max | >8 | >24 |
|---|---|---|---|---|---|---|---|---|
| baseline image draw | 21,890 | 21,890 | 71 | 71 | 0.00 | 0 | 0.00% | 0.00% |
| saveLayer | 21,890 | 21,890 | 71 | 71 | 0.00 | 0 | 0.00% | 0.00% |
| colour filter | 21,898 | 21,898 | 47 | 47 | 0.00 | 1 | 0.00% | 0.00% |
| rotated 512→200 | 27,830 | 27,836 | 242 | 238 | 0.03 | 7 | 0.00% | 0.00% |
| localsend composite | 27,842 | 27,852 | 55 | 54 | 0.08 | 11 | 0.01% | 0.00% |

The first three are bit-exact. The two that resample disagree on a handful of
edge pixels by at most 11 of 255, which is two bilinear implementations
rounding differently and nothing more.

![GPU, software, and the difference amplified 16×](../results/g2-ganesh-composite-2026-08-22.png)

*Left: Ganesh on vitaGL. Centre: the software rasteriser. Right: the absolute
difference, multiplied by 16 to make it visible at all.*

**The first version of this check passed on nothing.** The source image had an
opaque white background, and `kSrcATop` is `src * dstAlpha + dst * (1 -
srcAlpha)` — an opaque tint over an opaque image is just the tint. The composite rendered
a flat 200×200 square in **two colours total**, and two identical flat squares
agree perfectly. Every number in the table was zero and every row said PASS.

It was caught by dumping the pixels and looking at the histogram, which is the
only reason this section is not a fabrication. Two things changed as a result:
the source image now has a real alpha silhouette, matching localsend's logo,
which is a PNG with transparency; and the comparison counts **distinct
colours** and fails below sixteen. Non-blank does not mean drawn, and a check
that cannot tell a solid fill from a photograph cannot answer this question.

### Criterion 4: 36× on the composite, and one operation that got slower

Twenty iterations each, microseconds per operation. `gpu` submits and waits
(`GrSyncCpu::kYes` → `glFinish` → `sceGxmFinish`) once per iteration; `gpu
batch` submits once for all twenty, which is the pipelining headroom.

| operation | software | gpu | gpu batch | ×  | × batched | first draw |
|---|---|---|---|---|---|---|
| baseline image draw | 1,155 | 1,626 | 259 | **0.7** | 4.5 | 2,663 |
| saveLayer | 2,419 | 4,035 | 3,920 | **0.6** | 0.6 | 4,182 |
| colour filter | 36,628 | 1,851 | 486 | **19.8** | 75.4 | 2,970 |
| rotated 512→200 | 107,519 | 1,992 | 551 | **54.0** | 195.0 | 2,800 |
| localsend composite | 172,054 | 4,761 | 3,946 | **36.1** | 43.6 | 4,618 |

**Criterion 4 passes: 36.1× against a bar of 10×.** The verdict is taken on the
per-submit column, not the batched one, because a frame ends in a submit
whether or not the operations inside it pipeline.

The software composite at 172 ms independently reproduces the 199 ms measured
in localsend's real frame, from a different image and a synthetic scene. The
model is faithful.

### What the isolated rows say, which is not what was expected

**`saveLayer` is slower on the GPU. So is a plain image draw.** Both come in at
0.6-0.7×, and batching rescues the image draw but not the offscreen: twenty
`saveLayer`s in one submit still cost 3,920 us each. That is not submit
overhead, it is the operation.

The Vita's SGX543 is a **tile-based deferred renderer**. Every render-target
switch resolves the tile buffer to memory and reloads it, so an offscreen costs
a full framebuffer round trip that an immediate-mode GPU does not pay. The
consequences section below predicted this would be where the spike got hard and
named readbacks; it is the same mechanism, one step earlier.

So the win is not "the GPU is faster". It is narrower and worth stating
precisely:

- **Per-pixel work moves to hardware and collapses.** The colour filter is
  19.8× and the rotated downscale is 54×. These are the operations that made
  the software rasteriser's cost depend on *what* is drawn rather than how
  much, which is the finding this whole ADR rests on.
- **Structural work does not.** Offscreens get *more* expensive, and cheap
  draws gain nothing.
- **The composite still wins by 36×** because software pays 170 ms for the
  filter and the resample, against which one 4 ms tile round trip is noise.

There is also a floor: the baseline costs 1,626 us per submit-and-wait against
259 us batched, so a submit costs about **1.4 ms**. That is 4% of a 33 ms frame
and 8% of a 16 ms one — acceptable, and a reason not to submit more than once
per frame.

`first draw` is 2.6-4.6 ms across the board, which is the ~3 ms warm-cache
figure from criterion 0 and not the ~250 ms cold compile. The shader cache was
already populated from earlier runs, so this measures the good case only.

### What this means for localsend

The widget drops from ~172 ms to ~4.8 ms. Holding everything else in that frame
on the CPU — which is pessimistic, since it would move too — localsend's
199 ms raster pass becomes roughly **32 ms, about 31 fps**, from 4.87. That
clears [ADR-0006](0006-performance-bar-set-from-measurement.md)'s bar with the
conservative assumption still in place.

### The risk this creates for the embedder work

A Flutter tree is full of offscreens. `Opacity`, `ClipRRect` with antialiasing,
`ShaderMask`, `BackdropFilter` and every `ColorFiltered` lower to a `saveLayer`,
and the row above says each one costs ~4 ms on this GPU against ~2.4 ms on the
CPU. A screen with ten layers and no expensive per-pixel work would be *slower*
on the GPU than it is today.

That is not an argument against the direction — the operations that actually
hurt are 20× to 54× better, and they are the ones the corpus found. It is an
argument that the embedder needs the software path kept and selectable, which
[ADR-0003](0003-software-rendering-first.md) already requires for a different
reason, and that layer count becomes a thing to measure. It is added to the
revisit triggers below.

One shim question is answered: `glBlendColor` is stubbed to a no-op because
vitaGL has no constant blend colour, and the colour filter renders bit-exact
anyway, so Skia did not select a constant-colour blend coefficient for these
paints. That is evidence for these five operations and not a general result.

## Flutter on the GPU, 2026-08-22: the raster pass is fixed and the frame is not

The embedder now has both paths. `shell_enable_gl = true`, a
`FlutterOpenGLRendererConfig` in `vita_embedder.cc`, the six shims and the
suffix-stripping loader moved out of the spike into a proc resolver, and
vitaGL owning GXM and the display in place of this file's own CDRAM
framebuffer. Which path runs is decided at startup: GL unless
`ux0:data/flutter-vita/software.on` holds a `1`, and software automatically if
vitaGL cannot bring a context up.

Three things had to be fixed before any of it linked, and only the first is
about the Vita:

- **A thread-safe `__cxa_guard_acquire`.** The spike's was three lines and
  correct only for single-threaded initialisation. The engine has a platform
  thread, a UI thread, a raster thread, an IO thread and Dart's workers, any of
  which can be first to touch a given static. `vita_cxa_guard.cc` is the real
  one: a global mutex and condition variable, a release barrier before the ABI's
  done-bit because the compiler tests that bit inline without a lock, and a
  recursive-initialisation check that traps with a message rather than waiting
  forever on a signal the waiting thread owes itself.
- **`embedder_external_texture_gl.cc`** includes Impeller's GLES backend
  unconditionally while `BUILD.gn` gates the dependency on
  `impeller_supports_rendering`, so it asks for `GLES3/gl3.h` with no include
  path to find it on.
- **`embedder.cc`** chooses `EmbedderSurfaceGLImpeller` on a *runtime* branch,
  referencing a class its own `BUILD.gn` did not build.

The second and third are the same upstream assumption: **`shell_enable_gl`
implies Impeller.** It holds everywhere else and cannot hold here, because
Impeller has no software backend and this port needs both. Recorded as
[patch 0009](../../patches/flutter-engine/0009-gl-without-impeller.patch).

### It renders

The gallery app draws correctly through Ganesh on vitaGL — text, Material
widgets, icons, an indeterminate spinner, a slider, antialiased rounded rects —
at 60 fps, which is the vsync ceiling rather than a measurement.

### localsend: 30× on raster, and no change to the frame rate

The corpus app that motivated this whole ADR, measured on hardware, same build,
switched between paths at run time:

| | software | GL |
|---|---|---|
| frame period | 168,268 us | 199,582 us |
| fps | **5.94** | **5.01** |
| raster | 156,103 us (92%) | **5,129 us (2%)** |
| raster max | 215,423 us | 9,713 us |
| present | 1,304 us | 196 us |

**Raster fell by 30×, from 156 ms to 5.1 ms, and the frame got no faster.** The
spike's 36× was not wrong — the raster column is the spike's prediction landing
almost exactly — but it was the answer to a question that turned out not to be
the binding one at the app level.

Two smaller findings sit inside that:

- **The first GL run of an app is not the one to measure.** It reported
  `raster max 1,006,493 us` — a one-second frame — and 5.40 fps. That is
  libshacccg compiling Ganesh's programs on first paint, at the ~250 ms each
  criterion 0 measured. The second launch, with the cache warm, is the table
  above. Anything quoting a cold run is quoting shader compilation.
- **`vglSwapBuffers` returns in 196 us**, so the frame rate is not vsync and
  not the present.

### What is not yet known

Roughly 194 ms per frame is now outside the raster window, against 12 ms on the
software path, and that is not explained. The obvious candidate is that the UI
thread was always a co-bottleneck and is now exposed — Flutter pipelines UI and
raster, so the period is the slower of the two, not their sum. But the software
run's own arithmetic argues against it: a 168 ms period with 156 ms of raster
leaves no room for a 194 ms UI thread.

So one of the two measurements is describing something other than what its name
says, and the honest position is that this is undiagnosed. An instrument for it
is in the embedder and has not yet been run: the raster thread's idle time,
present-done to the next `make_current`, reported as `gl wait`. If that is
~194 ms the raster thread is starved and the bottleneck genuinely moved
upstream; if it is near zero, the raster thread is busy somewhere this file does
not time and the 5.1 ms figure is incomplete.

**No performance claim should be made for the GL path until that number
exists.** The 30× on raster is measured and stands on its own; "the GPU makes
localsend faster" is not yet supported by anything.

### Known gaps in the GL path

- **No partial repaint.** `populate_existing_damage` is null, so every frame is
  a full repaint. ADR-0007 is a software-path property today.
- **No IME.** vitaGL owns GXM, so the common dialog's surfaces need pointing at
  its back buffer rather than at the CDRAM block. This is closer than it was:
  the note in `OpenImeDialog` says text input needs "a minimal GXM pipeline
  whose only job is to own the framebuffer", and vitaGL is exactly that.
- **No debug HUD.** It paints into a CPU framebuffer that no longer exists.
- **No resource context.** `make_resource_current` is null, so texture uploads
  are synchronous on the raster thread and the engine says so once at startup.
  Providing one needs a second GL context, and vitaGL has one.
- Screenshots still work, because `sceDisplayGetFrameBuf` asks the hardware
  what it is scanning out and does not care who allocated it.

## Three findings that cost the spike four runs

**1. The shader compiler works, and the taiHEN chain under it is real but not
a blocker.** Removing one layer at a time from the link line gives:

```
libvitaGL.a        -> shark_*, sceShaccCg*   (gxm.o, ffp.o, custom_shaders.o)
libvitashark.a     -> sceShaccCgExt*
libSceShaccCgExt.a -> taiHookFunctionOffsetForUser, taiInjectDataForUser, ...
```

`gxm.o` is vitaGL's own init, so `vglInit` calls `shark_init` before any Skia
code exists, and `ffp.o` means vitaGL compiles even its built-in fixed-function
shaders at run time. The chain is not optional in the packaged build.

It is also not a problem: `shark_init(NULL)` returns **0** on this console. The
module is present at `ur0:data/libshacccg.suprx` and the hooks resolve.

The taiHEN edge is the `*ForUser` family. Every `ForKernel` entry point in
`taihen.h` takes an explicit `SceUID pid`; the `ForUser` ones take none — they
patch `SceShaccCg` **inside our own address space** and die with the process.
That is not what [ADR-0011](0011-crash-recovery-without-taihen.md) declined:
its stated reasons are *a module inside SceShell can hang the shell* and *two
`config.txt` experiments left the console unbootable*, and an in-process hook
reaches neither. It is recorded here rather than treated as settled, because
ADR-0011's rule is written flat.

**2. A safe self fails in ways that look like hardware limits.**
`vita_create_self` builds a *safe* self by default, and a safe self cannot read
`ur0:` or resolve taiHEN's user hooks — regardless of the HENkaku "unsafe
homebrew" setting. The spike was built safe while the loader and the app
template have always been `UNSAFE`. The symptom was `vglInit` returning
`GL_FALSE` on a console with 182 MB free and the module correctly installed,
which reads as a platform limitation and is a missing keyword.

**3. `vglInit` returns `GL_FALSE` on a context that works.** Every check above
passes immediately after it. Removing the spike's own `shark_init` call did not
change the return value, so it is not induced by the probe. Three runs treated
the boolean as authoritative and exited without calling a single GL entry
point; what contradicted them was the console itself, showing vitaGL's splash
screen — `invoke_splashscreen`, on its own thread — rotating at a smooth 60 fps
while the report on disk claimed there was no context.

**Do not trust `vglInit`'s return value. Probe the context.**

A related trap, from the same run: vitaGL defers shark translation to link
time, so `glCompileShader` validates almost nothing. A vertex shader missing
its `attribute vec2 aPos;` declaration reported `PASS` from both compiles and
then hung the console inside `glLinkProgram`.

## Decision

**The GPU is now the primary performance target, and Skia Ganesh over vitaGL is
the route.** GLES2 is reordered from "Phase 5 optimisation" to the next major
engine work item, which is the reordering ADR-0003 asked to be made explicit.

**Engine work is gated on a spike**, because the feasibility table above
establishes that nothing *forbids* this and says nothing about whether vitaGL
serves what Ganesh asks for. The spike is not the port; it is the smallest
program that answers that. Exit criteria, all on real hardware:

1. ~~A vitaGL GLES2 context initialises, and `libshacccg.suprx` compiles a
   trivial shader at runtime.~~ **PASSED 2026-08-21** — see above. The module
   is user-installed and the community already relies on it; the dependency it
   drags in is stated in full above.
2. ~~Skia builds with `skia_use_gl = true` and `skia_gl_standard = "gles"` for
   `target_os = vita`, and a `GrDirectContext` is successfully created on a
   vitaGL context.~~ **PASSED 2026-08-21.** The blocker was neither Skia nor
   vitaGL: libstdc++'s `__cxa_guard_acquire` faults in this statically linked
   build, so every function-local static with a dynamic initialiser is a hard
   fault.
3. ~~Skia draws the three operations that dominate the measurement above —
   `saveLayer`, a colour filter, and a rotated downscale of a 512×512 image —
   and the output is correct.~~ **PASSED 2026-08-22** — bit-exact on three of
   the five, and at most 11 of 255 on the two that resample.
4. ~~The same three are timed against the software path. **The bar is 10×**, not
   "faster": below that, the binary-size and complexity cost is not obviously
   worth it and the per-workload tools above deserve another look.~~
   **PASSED 2026-08-22 at 36.1×** on the composite widget — with one operation,
   `saveLayer`, coming out *slower* on the GPU.

**The spike has passed, and the engine work is unblocked**: a
`FlutterOpenGLRendererConfig` path in `vita_embedder.cc`,
`populate_existing_damage` against GXM's buffering, the GN branch above
rewritten with its stale premise removed, and — first, because nothing else
runs without it — a thread-safe `__cxa_guard_acquire` for the engine build. The
spike's is correct for single-threaded initialisation only, and the engine has
a UI thread, a raster thread, an IO thread and Dart's workers.

## Consequences

- **[ADR-0003](0003-software-rendering-first.md) is not superseded.** Its
  decision — ship software first — was correct and is why there is a working
  port to measure. What changes is the ordering it deferred, exactly through
  the mechanism it specified.
- **The software path stays.** It is the fallback when `libshacccg.suprx` is
  absent, and `shell_enable_software` remains true regardless. Two paths is
  more embedder surface, and that cost is accepted.
- **`libshacccg.suprx` becomes a runtime dependency for the fast path.** An app
  must still start and render without it.
- Binary size grows by Skia's GL backend. Memory is not the binding constraint
  — 188 MiB largest contiguous, and the engine is ~14.5 MiB resident — so this
  is a download-size concern, not a device one.
- The Vita's GPU is a **tile-based deferred renderer**. Skia's GL backend
  assumes immediate-mode in places, and readbacks are disproportionately
  expensive on TBDR. Expect this to be where the spike actually gets hard.
- [ADR-0002](0002-skia-not-impeller.md) is untouched: this is Ganesh, Skia's
  GPU backend, not Impeller. Impeller has a GLES backend and is where upstream
  is investing, which is a real argument to revisit — but not one to take on
  the same day as reordering the renderer.

## The bound on this conclusion, stated honestly

localsend's headline number is dominated by **one pathological widget**. A GPU
fixes it; so would deleting one `ColorFiltered`. Anyone reading "97%" as "Flutter
is slow on Vita" has read too much into it.

The claim this ADR actually rests on is narrower and better supported:
**the software rasteriser's cost is driven by what is drawn, not how much**, and
the operations that hurt it — saveLayer, filters, resampling under a changing
transform — are the ones hardware performs for free. manga_reader's
5%-costs-as-much-as-89% pair is the cleaner evidence, because nothing
pathological is involved in it.

## Revisit trigger

- **The spike fails criterion 4.** If vitaGL plus Ganesh is under 10× on those
  three operations, this ADR is wrong and the answer is per-workload work:
  reduced resolution for fill-bound screens, and a `psvita` lint or widget set
  that steers apps away from the operations that hurt.
- **Layer-heavy screens turn out slower on the GPU.** Criterion 4 measured
  `saveLayer` at 0.6×, and a Flutter tree is full of them. If a real app's frame
  regresses once the embedder GL path exists, the answer is not to abandon the
  GPU but to choose the backend per app or per screen — which makes the
  two-path embedder a permanent feature rather than a transition.
- **`libshacccg.suprx` becomes unavailable or unacceptable.** Then Ganesh has
  no runtime shader compiler and the route is a precompiled shader cache, which
  is a materially different project.
- **Upstream removes the Ganesh GL backend.** Skia is investing in Graphite and
  Flutter in Impeller. [flutter-upgrade-cost.md](../flutter-upgrade-cost.md)
  shows Impeller took 336 files and +13,110 lines in one release window while
  the Skia software path took 5 insertions. If GL goes, the question reopens as
  Impeller-GLES versus staying on CPU.

## Related

- [ADR-0002](0002-skia-not-impeller.md) — Skia, not Impeller; unchanged here
- [ADR-0003](0003-software-rendering-first.md) — the decision this reorders, through its own trigger
- [ADR-0004](0004-static-single-binary.md) — why vitaGL being a static archive matters
- [ADR-0006](0006-performance-bar-set-from-measurement.md) — the bar this is measured against
- [ADR-0007](0007-enable-partial-repaint-in-software-path.md) — made the blit small, and thereby obsoleted the NEON-blit recommendation
- [corpus-localsend-2026-08-19.md](../results/corpus-localsend-2026-08-19.md) — the raster attribution in full
