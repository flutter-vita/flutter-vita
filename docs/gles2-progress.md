# fvita_gles2 progress

How far the GLES2-over-sceGxm layer of ADR-0019 is from complete. It has been
the only GL in the tree since 2026-09-14 (M5). The
blocks marked as generated are rewritten by `tools/gles2-progress.py` from the
source and `gles2/surface.txt`; the area table's `done` column is set by hand
and every change to it has to name its evidence in the last column.

<!-- progress:begin -->
**81% complete** (weighted areas, weights sum to 100).

| entry points | count |
|---|---|
| bound by Skia (`gles2/surface.txt`) | 108 |
| called in some run, implemented | 60 of 60 |
| never called, implemented anyway | 28 of 48 |
| recording stubs | 20 |
| missing | 0 |
<!-- progress:end -->

## Areas

<!-- areas:begin -->
| area | weight | done | evidence |
|---|---|---|---|
| Specification: the surface list, the shader corpus, the dialect | 6 | 100% | `gles2/surface.txt`: 108 names Skia binds on the layer itself, 60 called, measured by `experiments/gl-usage` wrapping `fvgl_get_proc_address` over one uninterrupted 36-scene bench on 2026-09-14 (the 14 extension names vitaGL advertised left the list); 47 shaders in the corpus |
| Context: GPU memory, sceGxm init, display chain, scenes, present | 12 | 70% | M0 on hardware 2026-09-12. Frame notifications retire GPU memory (`fvgl_collect_garbage`), per-frame scratch rings, M1. Scenes switch targets (a texture or the display) on demand and the frame always ends on the display, M3 test 2026-09-12. Missing: depth and stencil surfaces, and no Flutter app reaches them: `shell/common/context_options.cc` sets `fAvoidStencilBuffers` for every GL context and Ganesh never binds a depth buffer (read 2026-09-14), so under Flutter the stencil and renderbuffer entry points stay recording stubs with 0 calls |
| Buffers and vertex input: VBO, IBO, attribute pointers, client arrays, draw calls | 14 | 80% | M1 on hardware 2026-09-12: VBO with `glBufferData(NULL)`+`glBufferSubData`, client arrays and client indices, `glDrawArrays`, `glDrawElements` (u8/u16/u32), line strips expanded, constant attributes via instance streams, vertex-program cache per layout. Gallery scale, 2026-09-14 (`docs/results/log-writes-on-the-frame-threads-2026-09-14.md`): `sub 0` over 9360 frames, Skia never writes into a buffer a draw of the frame has read, so no copy path is needed; `var 33/33/0`, one layout and one blend state per program, no variant table full. Missing: eviction from the 32-entry variant tables, for an app that needs it |
| Textures: 2D, sub-image, copy, parameters, pixel store, formats | 10 | 80% | M3 test on hardware 2026-09-12: RGBA8, RGB (stored as RGBA8), ALPHA, LUMINANCE, LUMINANCE_ALPHA and RGB565 sample back the GL values; unpack alignment 1; linear filter with clamp; the white fallback for an incomplete sampler; glTexSubImage2D into a texture the previous frame samples (one counted stall); glCopyTexSubImage2D from the display. Lifecycle at gallery scale, bench 2026-09-12: live textures return to 2 after every scene, the garbage list drains to 0, CDRAM the layer owns peaks at 32 MiB (eleven render targets in the fade transitions) and ends the 34 scenes at 10.5 MiB with no refused allocation (`docs/results/snapshot-textures-2026-09-12.md`); a refused CDRAM block falls back to at most 8 MiB of main memory. glCopyTexSubImage2D is a GPU blit (`blit.c`); a texture drawn into becomes tiled, with staging blits for the CPU paths, M3 test 35 of 35 on 2026-09-13. Missing: mipmaps (strided layout has none), BGRA/4444/5551 unverified, cube maps refused, stall cost at gallery scale |
| Framebuffers: render to texture, per-target viewport and scissor, readback | 10 | 80% | M3 test on hardware 2026-09-12: a 128x64 RGBA8 texture as target, complete status, scissored clears, draws, gl_FragCoord unflipped (row 40.5 reads 161), glReadPixels from the texture, the texture sampled on the display afterwards. Bench 2026-09-12: render targets made and destroyed with their textures through 34 scenes, `tgt` back to 1 after each (page snapshots, saveLayers). Targets are tiled surfaces since 2026-09-13; GPU latency per frame on a page push 14 to 15 ms against 18 to 22 linear. Missing: renderbuffers (depth, stencil; no Flutter app reaches them: `shell/common/context_options.cc` sets `fAvoidStencilBuffers` for every GL context and Ganesh never binds a depth buffer (read 2026-09-14), so under Flutter the stencil and renderbuffer entry points stay recording stubs with 0 calls), the cost of target switches at gallery scale |
| Shader translation: GLSL ES 1.00 to Cg | 16 | 85% | M2 on hardware 2026-09-14: all 47 corpus shaders translate and compile through `libshacccg` on the console (median 144 ms, max 1.9 s per shader, cold). Locals that shadow attributes are renamed. User functions since 2026-09-14: wonderous' bicubic image shader carries its `MatrixEffect` child as one, the first Skia shader outside the gallery the layer met (`docs/results/test-apps-fvita-gles2-2026-09-13.md`); it is corpus 46 and compiles in 1391 ms. Missing: `half` for `mediump`, constructs outside the corpus arrive as named errors |
| Programs: SceShaccCg compile, link, attribute and uniform reflection, uniform upload | 12 | 80% | M1: shader and program objects, link-time Cg compile, varying map, `glBindAttribLocation`, uniform table with locations, all `glUniform*` forms, matrix upload order verified by a translation through a `mat3`, fragment-program cache per blend state. M3 test: samplers bound to the unit `glUniform1i` named. Programs cached on disk by the hash of their Cg text (`ux0:data/fvita_gles2/cache`): the second launch of the bench read 62 of 64 from disk and compiled 2 (2026-09-13). Link cost measured 2026-09-14: 70 links in a bench run, 184 to 210 ms in total, 2.6 to 3 ms each with the card read 1.7 to 2 ms of it, all on the raster thread at a scene's first frame. Missing: relink and delete under load |
| Pipeline state: blend, masks, scissor, viewport, line width, front face, getters | 6 | 75% | M1: blend func/equation (separate forms) verified by two hand-computed blended pixels; `glGetIntegerv`/`Floatv`/`Booleanv` table; `glFinish`. M3: texture and framebuffer bindings, pack and unpack alignment in the getters. Missing: `glLineWidth` applied, depth/stencil state (unreachable under Flutter, see the Context row) |
| Integration: the template, the embedder switch, proc table, recording stubs, tracer | 6 | 85% | `tools/gles2-gen.py` generates `procs.c` and `stubs.c`. The embedder calls six functions of `flutter_vita_gl.h` and nothing else of the layer (patch 0004); `templates/vita-app/gl_gles2.c` answers. The gallery ran on it 2026-09-12 (`docs/results/gallery-fvita-gles2-2026-09-12.md`). The exit path tears down 1315 textures and 54 render targets and hands back (`gles2-shutdown.txt`, watchdog in `gl_gles2.c`). `fvgl_stats` on every FRAMES line: it found the engine's snapshot-texture leak the same day (patch 0012). Since 2026-09-14 the template links fvita_gles2 for every app and `build-vita-app.sh` has no `--gl`: gallery builds 25 and 26 carry no vitaGL symbol and ran the 36-scene bench to the end, and the receiver on engine pin `a2f902e2` boots on the layer and deploys apps (`docs/results/m5-vitagl-out-2026-09-14.md`). Missing: the tracer re-pointed at `fvgl_get_proc_address`, the inline keyboard over our frames untested |
| Parity: gallery screenshots, test apps, bench, vitaGL removed | 8 | 85% | Same engine, same hour, both backends, 36 scenes, build 23 (`docs/results/parity-2026-09-13.md`, fourth section): sums vitaGL against fvita_gles2 are worst 3567 against 3033 ms, stall 11267 against 7650 ms, raster 216 against 212 ms; raster equal or lower on 20 of 36, higher by more than a millisecond on the Zoom route pushes and switch_fade. The freeze that stopped every other run was the Dart port's condition variable, fixed (`docs/results/the-frozen-ui-thread-2026-09-13.md`); material_3_demo renders and runs on gles2. All five test apps reach their screens on gles2 with the current engine, 2026-09-13/14 (`docs/results/test-apps-fvita-gles2-2026-09-13.md`): keklist, manga_reader, wonderous and localsend driven through their tabs, no stub called, one translator gap found and closed. vitaGL and vitashark left the tree on 2026-09-14 (M5); bench runs 24 to 26 on the shim-free engine sum to worst 2850 to 4350 ms, stall 7533 to 11800 ms, raster 222 to 267 ms, the spread from single-scene outliers (`docs/results/m5-vitagl-out-2026-09-14.md`). Log writes moved off the frame threads the same day: runs 29 and 30 are the best on record in every column (stall 6233 and 6217 ms, raster 198 ms, `docs/results/log-writes-on-the-frame-threads-2026-09-14.md`). Deferred on 2026-09-14: the Zoom transition's GPU time, screenshots scene by scene |
<!-- areas:end -->

## Milestones

| | milestone | state |
|---|---|---|
| M0 | clear, scissor, present through our own sceGxm context | **done 2026-09-12**, `gles2/test` M0 passes 10 of 10 pixel checks on hardware |
| M1 | a triangle from run-time-translated GLSL | **done 2026-09-12**, `gles2/test` M1 passes 8 of 8 (mat3 convention, blend, gl_FragCoord, VBO and client paths) |
| M2 | the gallery's shaders translate and compile | **done 2026-09-13**, 46 of 46 on the console (`gles2/test` M2); 47 of 47 on 2026-09-14 with wonderous' bicubic shader |
| M3 | the gallery draws under `--gl gles2` | **done 2026-09-12**: `gles2/test` M3 35 of 35; the gallery renders through the layer, 22 programs, no stub called (`docs/results/gallery-fvita-gles2-2026-09-12.md`) |
| M4 | test apps and bench at parity | **done 2026-09-14**: test apps five of five on gles2; bench, the build 23 pair (`docs/results/parity-2026-09-13.md`). Deferred: Zoom GPU time, screenshots scene by scene |
| M5 | vitaGL and vitashark gone | **done 2026-09-14**: `patches/vitagl/`, `gl_vitagl.c`, the embedder's vgl shims and `--gl` removed; NOTICE has no LGPL section. Gallery builds 25 and 26 carry no vitaGL symbol and ran 36 of 36 bench scenes; the receiver on the new pin boots on fvita_gles2 and deploys apps (`docs/results/m5-vitagl-out-2026-09-14.md`) |

## Entry-point ledger

<!-- ledger:begin -->
| entry point | measured | peak calls | state |
|---|---|---|---|
| `eglQueryString` | never | 0 | stub |
| `glActiveTexture` | called | 1029 | real |
| `glAttachShader` | called | 66 | real |
| `glBindAttribLocation` | called | 95 | real |
| `glBindBuffer` | called | 28579 | real |
| `glBindFramebuffer` | called | 3153 | real |
| `glBindRenderbuffer` | never | 0 | stub |
| `glBindTexture` | called | 8234 | real |
| `glBlendColor` | never | 0 | stub |
| `glBlendEquation` | called | 1 | real |
| `glBlendFunc` | called | 383 | real |
| `glBufferData` | called | 13454 | real |
| `glBufferSubData` | called | 13445 | real |
| `glCheckFramebufferStatus` | called | 448 | real |
| `glClear` | called | 11590 | real |
| `glClearColor` | called | 2123 | real |
| `glClearStencil` | never | 0 | stub |
| `glColorMask` | called | 1 | real |
| `glCompileShader` | called | 66 | real |
| `glCompressedTexImage2D` | never | 0 | stub |
| `glCompressedTexSubImage2D` | never | 0 | stub |
| `glCopyTexSubImage2D` | called | 76 | real |
| `glCreateProgram` | called | 33 | real |
| `glCreateShader` | called | 66 | real |
| `glCullFace` | never | 0 | stub |
| `glDeleteBuffers` | called | 3 | real |
| `glDeleteFramebuffers` | called | 447 | real |
| `glDeleteProgram` | never | 0 | real |
| `glDeleteRenderbuffers` | never | 0 | stub |
| `glDeleteShader` | called | 66 | real |
| `glDeleteTextures` | called | 658 | real |
| `glDepthMask` | called | 1 | real |
| `glDisable` | called | 1183 | real |
| `glDisableVertexAttribArray` | called | 15233 | real |
| `glDrawArrays` | called | 4308 | real |
| `glDrawElements` | called | 39278 | real |
| `glEnable` | called | 1179 | real |
| `glEnableVertexAttribArray` | called | 15223 | real |
| `glFinish` | never | 0 | real |
| `glFlush` | never | 0 | real |
| `glFramebufferRenderbuffer` | never | 0 | stub |
| `glFramebufferTexture2D` | called | 448 | real |
| `glFrontFace` | called | 1 | real |
| `glGenBuffers` | called | 9 | real |
| `glGenFramebuffers` | called | 448 | real |
| `glGenRenderbuffers` | never | 0 | stub |
| `glGenTextures` | called | 660 | real |
| `glGenerateMipmap` | never | 0 | stub |
| `glGetBufferParameteriv` | never | 0 | real |
| `glGetError` | called | 37256 | real |
| `glGetFloatv` | never | 0 | real |
| `glGetFramebufferAttachmentParameteriv` | never | 0 | real |
| `glGetIntegerv` | called | 7 | real |
| `glGetProgramInfoLog` | never | 0 | real |
| `glGetProgramiv` | called | 33 | real |
| `glGetRenderbufferParameteriv` | never | 0 | stub |
| `glGetShaderInfoLog` | never | 0 | real |
| `glGetShaderPrecisionFormat` | called | 4 | real |
| `glGetShaderiv` | called | 66 | real |
| `glGetString` | called | 9 | real |
| `glGetStringi` | never | 0 | stub |
| `glGetUniformLocation` | called | 148 | real |
| `glIsTexture` | never | 0 | real |
| `glLineWidth` | called | 1 | real |
| `glLinkProgram` | called | 33 | real |
| `glPixelStorei` | called | 434 | real |
| `glReadPixels` | called | 1 | real |
| `glRenderbufferStorage` | never | 0 | stub |
| `glScissor` | called | 801 | real |
| `glShaderSource` | called | 66 | real |
| `glStencilFunc` | never | 0 | stub |
| `glStencilFuncSeparate` | never | 0 | stub |
| `glStencilMask` | never | 0 | stub |
| `glStencilMaskSeparate` | never | 0 | stub |
| `glStencilOp` | never | 0 | stub |
| `glStencilOpSeparate` | never | 0 | stub |
| `glTexImage2D` | called | 660 | real |
| `glTexParameterf` | never | 0 | real |
| `glTexParameterfv` | never | 0 | real |
| `glTexParameteri` | called | 3942 | real |
| `glTexParameteriv` | never | 0 | real |
| `glTexSubImage2D` | called | 433 | real |
| `glUniform1f` | never | 0 | real |
| `glUniform1fv` | called | 382 | real |
| `glUniform1i` | called | 25 | real |
| `glUniform1iv` | never | 0 | real |
| `glUniform2f` | called | 268 | real |
| `glUniform2fv` | called | 284 | real |
| `glUniform2i` | never | 0 | real |
| `glUniform2iv` | never | 0 | real |
| `glUniform3f` | never | 0 | real |
| `glUniform3fv` | never | 0 | real |
| `glUniform3i` | never | 0 | real |
| `glUniform3iv` | never | 0 | real |
| `glUniform4f` | called | 435 | real |
| `glUniform4fv` | called | 4748 | real |
| `glUniform4i` | never | 0 | real |
| `glUniform4iv` | never | 0 | real |
| `glUniformMatrix2fv` | never | 0 | real |
| `glUniformMatrix3fv` | called | 1385 | real |
| `glUniformMatrix4fv` | never | 0 | real |
| `glUseProgram` | called | 34689 | real |
| `glVertexAttrib1f` | never | 0 | real |
| `glVertexAttrib2fv` | never | 0 | real |
| `glVertexAttrib3fv` | never | 0 | real |
| `glVertexAttrib4fv` | never | 0 | real |
| `glVertexAttribPointer` | called | 105515 | real |
| `glViewport` | called | 1729 | real |
<!-- ledger:end -->
