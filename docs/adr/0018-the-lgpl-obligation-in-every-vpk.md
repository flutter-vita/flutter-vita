# ADR-0018: vitaGL is LGPL, and the obligation lands on every developer who ships

**Status:** Accepted 2026-09-12 — our own GLES2 over sceGxm; nothing LGPL in the vpk and nothing LGPL required on the console. Carried out 2026-09-14: vitaGL and vitashark are out of the tree (`docs/results/m5-vitagl-out-2026-09-14.md`)
**Date:** 2026-09-09

## Context

`templates/vita-app/CMakeLists.txt` links `libvitaGL.a` into `eboot.bin`,
unconditionally, for every app this toolchain builds. vitaGL is
LGPL-3.0-or-later: `COPYING` is GPLv3, `COPYING.LESSER` is LGPLv3, and the
source headers say "version 3 of the License, or (at your option) any later
version". vitashark, which vitaGL calls for every shader, carries the same
licence.

Neither appears in `NOTICE`. That is a defect on its own and is fixed
separately.

The structural problem is LGPL-3 §4. A statically linked combined work may be
conveyed only if the conveyor also supplies what a recipient needs to relink it
against a modified version of the library. Object files, or a shared library
mechanism.

**That duty does not stop with us.** It attaches to every developer who builds a
`.vpk` with this toolchain and puts it on VitaDB. The stated goal of the project
is the opposite:

> I feel like if we depend on VitaGL we obligate our users and developers to do
> strange things with their vpks. It should not be like that. A developer should
> try and ship as he likes.

## The routes

Four exist. Two are somebody else's decision, and both are recorded here so the
list is complete.

**Ask Rinnegatamante for a linking exception.** Free if granted. Not ours to
decide.

**Make vitaGL a shared module.** §4(d)(1) removes the relink duty for a shared
library mechanism that uses a copy already on the user's system. One
`ux0:data/flutter-vita/vitaGL.suprx` is that. `experiments/vitagl-module`
tested it and the result is below.

The two live options are the remaining pair.

## Route A: ship the relink material automatically

`tools/build-vita-app.sh` writes a bundle beside each `.vpk`: the application's
object files, the vitaGL and vitashark sources, our patch series, and the link
line. The duty is then met mechanically and the developer does nothing at build
time.

Measured on this tree:

| Item | Size |
|---|---|
| `libflutter_engine_vita.a` | 67.0 MB, 19.2 MB gzipped |
| Application objects, bridge | 4.3 MB |
| vitaGL and vitashark source plus `patches/vitagl/` | ~1 MB |
| **Bundle** | **~22 MB** |
| The `.vpk` it accompanies | 14.7 MB |

The licence parcel is larger than the game. A developer must host it for every
release, on a channel that gives them one file slot. The predictable outcome is
that the bundle is built and never published, which leaves the developer in
breach and us with a tool nobody runs.

## Route B: our own GLES2 over GXM

No LGPL code in `eboot.bin`, so §4 never applies, and the module experiment
becomes unnecessary.

### How much of vitaGL is actually reachable

`--gc-sections` against a vitaGL rebuilt with `-ffunction-sections`, linked into
the bridge:

| | |
|---|---|
| vitaGL `.text` retained | 349,842 bytes across 769 functions |
| GL entry points retained | 372 |

**That 372 is not what the app uses. It is what `vglGetProcAddress` can hand
out.** Skia binds GL by name, so vitaGL's lookup table references every entry
point it has, and the linker cannot drop any of them. `glBegin`, `glVertex3f`,
`glMaterialf` and `gluLookAt` are all in a Flutter binary today. Object
granularity says even less: 29 of vitaGL's 30 translation units get pulled in,
because they cross-reference each other.

Where the retained code sits:

| Object | `.text` kept | What it is |
|---|---|---|
| `custom_shaders.o` | 81,084 | shader objects and the translation entry |
| `preprocessor.o` | 42,682 | a C preprocessor for GLSL |
| `ffp.o` | 41,952 | GL1.x fixed-function, which Flutter never touches |
| `gpu_utils.o` | 25,596 | |
| `textures.o` | 25,404 | |
| `expression.o` | 11,148 | preprocessor expression evaluation |
| `glsl_utils.o` | 10,976 | the GLSL rewrites |
| everything else | 111,000 | |

Shader translation is 145,890 bytes, **42% of the retained code**. The
fixed-function pipeline is another 12% that exists only because the lookup table
names it.

### What the port asks of vitaGL by name

Fifteen GL functions are linked into the engine by symbol rather than resolved
through the interface: `glAttachShader`, `glCompileShader`, `glCreateProgram`,
`glCreateShader`, `glDeleteProgram`, `glDeleteShader`, `glGetIntegerv`,
`glGetProgramInfoLog`, `glGetProgramiv`, `glGetShaderInfoLog`, `glGetShaderiv`,
`glGetString`, `glLinkProgram`, `glShaderSource`, `glTexParameterf`.

The vitaGL API proper is five calls: `vglInitExtended`, `vglSetShaderCachePath`,
`vglSetupRuntimeShaderCompiler`, `vglSwapBuffers`, `vglGetProcAddress`. Seven
more symbols are counters our own patches added.

### What Skia actually emits, measured

`experiments/gl-usage/gl_shaders.c` wraps `glShaderSource` both ways Skia can
reach it and appends every shader to disk. One gallery run, 101,380 bytes:

| | |
|---|---|
| Shaders compiled | 114 |
| Distinct shaders among them | **43** |
| Median size | 556 bytes |
| Largest | 4,495 bytes |

Every one is `#version 100`. Not one uses `#extension`.

What appears:

| Construct | Shaders using it |
|---|---|
| `precision` qualifiers | 114 |
| `varying`, `sampler2D` | 114 |
| `uniform` | 103 |
| `mat2`/`mat3`/`mat4` | 64 |
| `attribute`, `gl_FragColor`, `gl_Position` | 57 |
| `texture2D`, always with a bias argument | 44 |
| arrays | 25 |
| `for` | 24 |
| `gl_FragCoord` | 5 |
| `if` | **1** |

What never appears, in any of the 114: `struct`, `while`, `discard`,
user-defined functions, `textureSize`, `gl_FrontFacing`, `gl_FragData`,
`gl_PointSize`, `gl_VertexID`, `gl_InstanceID`, `#extension`.

Read the two lists together. Skia's output is a narrow, repetitive dialect:
declarations, a straight-line `main`, arithmetic, one texture call shape, and
occasionally a bounded `for`. It has no functions to inline, no structs to lay
out, and one branch in the whole set.

Several of vitaGL's translator passes exist for constructs that never arrive
here. `gl_FrontFacing` has five code sites, `textureSize` has two, and
`gl_FragData`, `gl_PointSize`, `gl_VertexID` and `gl_InstanceID` have one
each. All dead for this port.

The `*=` case its author marked `FIXME: *= still not handled` occurs exactly
once, as `_52_color.xyz *= _52_color.w`. That is a vector scaled by a scalar,
which Cg accepts unchanged, so the gap does not bite: `vglMul` exists for
matrix multiplication order and nothing here needs it.

### The translator is the risk, and it is a text rewriter

`glsl_utils.c` plus the preprocessor is 4,591 lines. It does not parse GLSL. It
injects a 192-line Cg prelude that redefines GLSL shapes in Cg, runs a
preprocessor over the source, and then rewrites constructs by string surgery:
`*` becomes `vglMul()`, uniforms are hoisted, `textureSize` is rewritten, `.st`
swizzles are renamed, `gl_FrontFacing` is patched in.

This approach is approximate by construction and its failure mode is silent
misrewriting. We have already paid for that twice:
`patches/vitagl/0004-the-define-that-renamed-every-s.patch` exists because a
rewrite renamed identifiers it had no business touching, and
`patches/vitagl/0003-a-shader-that-failed-is-not-a-shader.patch` exists because
a refused compile left a null program that the next line dereferenced.

Owning the translator means owning that class of bug on hardware, one app at a
time, with no other project sharing the load.

### What the module experiment settled on the way past

`experiments/vitagl-module`, on hardware, 2026-09-09:

| | |
|---|---|
| A `.suprx` loads from `ux0:data` and is called through a stub | yes |
| `libshacccg` loads from inside a module | yes |
| `sceShaccCgExtEnableExtensions`, the taiHEN user hooks, from a module | returns 0 |
| The rest of `shark_init` | faults, and the eboot control faults identically |

So the module route is not closed by the platform. It is unresolved, and it is
no longer load bearing for either route above.

## Decision

**Write the GLES2 layer ourselves, over sceGxm, in this repo, under BSD-3.**
ADR-0019 holds the scope and the rules. The other routes are closed, for
reasons that are the project's and not the platform's:

| route | why not |
|---|---|
| A, ship the relink material | vitaGL stays in every vpk; every developer still carries the §4 duty and a 22 MB bundle |
| vitaGL as a `.suprx` on the console | the vpk is clean but the console is not: a developer who ships closed source still depends on an LGPL module being installed, and this toolchain has to be handed to any developer without that string attached |
| a licence exception from the author | not sought. The toolchain must not rest on a permission that one person can grant or withdraw |

The measurements that were in flight when this was written are in:

1. **Run-time entry points.** Three gallery runs: bound 114 or 115, called
   60, 61 and 60. Union over the runs: 59 distinct functions called, 55 never
   (all stencil, renderbuffers, instancing, VAOs, mapped buffers, program
   binaries, group markers, `glUniform{1,2,3,4}i*`, `glUniformMatrix{2,4}fv`,
   `glVertexAttrib*f*`, `glFlush`, `glFinish`, `glGenerateMipmap`).
   `experiments/gl-usage` is the instrument and stays.
2. **GLSL.** The dialect is the narrow corner: see "What Skia actually emits,
   measured" above. 43 distinct shaders, `#version 100`, no structs, no user
   functions, no `discard`, no `#extension`.

So the surface to build is 114 names of which 59 need to do real work, and one
shader dialect small enough to list. That is the size of the job, and it is
tracked in percentages in `docs/gles2-progress.md`.

## Consequences either way

`NOTICE` gains vitaGL and vitashark with their licence and the §4 statement.
`CONTRIBUTING.md` gains one line saying contributions are accepted under
BSD-3-Clause. Neither waits on this decision.

## Revisit when

Nothing external. The decision is a direction, and `docs/gles2-progress.md`
says how far along it is.
