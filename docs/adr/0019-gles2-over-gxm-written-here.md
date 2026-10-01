# ADR-0019: GLES2 over sceGxm, written here

**Status:** Accepted; the only GL in the tree since 2026-09-14, when vitaGL
and vitashark left it (M5 in `docs/gles2-progress.md`)
**Date:** 2026-09-12

## Context

ADR-0018 closed every route that leaves vitaGL anywhere near a shipped app.
The reason is the project's, not the platform's: this toolchain is handed to
any developer, closed source included, and nothing in a vpk and nothing
required on the console may carry an LGPL string. No exception is sought.

What Skia needs from a GL is measured, not assumed:

| | |
|---|---|
| entry points Skia binds through `GetProcAddress` | 114 |
| of those, called in at least one gallery run | 59 |
| never called in any run | 55 |
| GL symbols the engine links by name | 15 |
| vitaGL API calls the embedder makes | 5 |
| distinct shaders the gallery compiles | 43, `#version 100`, no structs, user functions, `discard` or `#extension` |

`experiments/gl-usage` produced the counts and `experiments/gl-usage/gl_shaders.c`
the shader corpus. Both stay as the instrument.

## Decision

A GLES2 implementation lives in this repo at `gles2/`, builds to
`libfvita_gles2.a`, is BSD-3-Clause, and sits on `sceGxm` and `SceShaccCg`
directly.

**Scope is the measured surface.** All 114 names resolve, because Skia's
interface validation refuses a context with a hole in it. The 59 called ones
are implemented to the GLES 2.0 specification. The 55 never-called ones start
as recording stubs: they behave as the specification's no-op where one exists
(`glFlush`), otherwise they set `GL_INVALID_OPERATION`, and every first call is
written to `ux0:data/flutter-vita/gles2-unimplemented.txt` with the name. An
app that needs one says so on the card, and the stub becomes a function then.

**Shaders are compiled on the console, as today.** GLSL ES 1.00 in, Cg out,
`SceShaccCg` compiles the Cg. The translator handles the dialect listed in
ADR-0018 and refuses anything outside it with a compile error naming the
construct, so the dialect grows by measurement. `libshacccg.suprx` is Sony's
compiler and is already what every GPU-path console has installed.

**Clean room.** No vitaGL or vitashark source is opened while this is written.
References are the Khronos GLES 2.0 and GLSL ES 1.00 specifications, the
Khronos `GLES2/gl2.h` header (MIT), and VitaSDK's `psp2/gxm.h` and
`psp2/shacccg.h`. The GLES header is used from the SDK, not copied in.

**Both backends build until the last milestone.** `build-vita-app.sh --gl
gles2|vitagl` selects the link, default `vitagl` until the gallery, the test
apps and the bench show parity, then the default flips and vitaGL leaves the
template, `NOTICE` and the docs in one commit.

## Milestones, in order

| | milestone | proven by |
|---|---|---|
| M0 | a test app clears the screen through our own `sceGxm` context and presents it | a screenshot pulled over the dev server |
| M1 | a triangle, shader compiled at run time from GLSL through our translator | the same |
| M2 | the gallery's 43 shaders translate and compile | a host-side test over the corpus plus one on-console run |
| M3 | the gallery draws under `--gl gles2` | screenshots against the vitaGL build, scene by scene |
| M4 | test apps and the bench at parity | `bench.sh` against the committed baseline |
| M5 | vitaGL and vitashark gone from the template, `NOTICE`, and the engine artifact | `apply-patches.sh --verify`, a vpk with no LGPL inside |

Progress is a percentage in `docs/gles2-progress.md`, recomputed by
`tools/gles2-progress.py` from the source, never by hand. No dates: the
project does not predict development time.

## Consequences

- The port stops depending on anyone's licence choices for its GPU path.
- The translator is ours to debug; when a new app's shader fails it is a
  measured gap with a name, not a text-rewrite surprise.
- Until M5 every GL change is measured twice, once per backend, which is the
  point of keeping both.
- The tracer's `--wrap=vglGetProcAddress` becomes `--wrap=fvgl_get_proc_address`
  at M3; the counts keep the same file and format.

## Related

- [ADR-0018](0018-the-lgpl-obligation-in-every-vpk.md), the decision this executes
- [ADR-0016](0016-the-bridge-becomes-a-flutter-app.md), the bridge renders in software and never links this
- `experiments/gl-usage`, `experiments/vitagl-module`
