# fvita_gles2 progress

How far the GLES2-over-sceGxm layer of ADR-0019 is from replacing vitaGL. The
blocks marked as generated are rewritten by `tools/gles2-progress.py` from the
source and `gles2/surface.txt`; the area table's `done` column is set by hand
and every change to it has to name its evidence in the last column.

<!-- progress:begin -->
**72% complete** (weighted areas, weights sum to 100).

| entry points | count |
|---|---|
| bound by Skia (`gles2/surface.txt`) | 114 |
| called in some run, implemented | 56 of 59 |
| never called, implemented anyway | 28 of 55 |
| recording stubs | 30 |
| missing | 0 |
<!-- progress:end -->

## Areas

<!-- areas:begin -->
| area | weight | done | evidence |
|---|---|---|---|
| Specification: the surface list, the shader corpus, the dialect | 6 | 90% | `gles2/surface.txt` (114 names, 59 called), 43 shaders in ADR-0018; the called set from one uninterrupted bench is the last 10% |
| Context: GPU memory, sceGxm init, display chain, scenes, present | 12 | 70% | M0 on hardware 2026-09-12. Frame notifications retire GPU memory (`fvgl_collect_garbage`), per-frame scratch rings, M1. Scenes switch targets (a texture or the display) on demand and the frame always ends on the display, M3 test 2026-09-12. Missing: depth and stencil surfaces |
| Buffers and vertex input: VBO, IBO, attribute pointers, client arrays, draw calls | 14 | 60% | M1 on hardware 2026-09-12: VBO with `glBufferData(NULL)`+`glBufferSubData`, client arrays and client indices, `glDrawArrays`, `glDrawElements` (u8/u16/u32), line strips expanded, constant attributes via instance streams, vertex-program cache per layout. Missing: gallery-scale measurement of `fvgl_subdata_into_used_buffer`, variant eviction |
| Textures: 2D, sub-image, copy, parameters, pixel store, formats | 10 | 75% | M3 test on hardware 2026-09-12: RGBA8, RGB (stored as RGBA8), ALPHA, LUMINANCE, LUMINANCE_ALPHA and RGB565 sample back the GL values; unpack alignment 1; linear filter with clamp; the white fallback for an incomplete sampler; glTexSubImage2D into a texture the previous frame samples (one counted stall); glCopyTexSubImage2D from the display. Lifecycle at gallery scale, bench 2026-09-12: live textures return to 2 after every scene, the garbage list drains to 0, CDRAM the layer owns peaks at 32 MiB (eleven render targets in the fade transitions) and ends the 34 scenes at 10.5 MiB with no refused allocation (`docs/results/snapshot-textures-2026-09-12.md`); a refused CDRAM block falls back to at most 8 MiB of main memory. Missing: mipmaps (strided layout has none), BGRA/4444/5551 unverified, cube maps refused, stall cost at gallery scale |
| Framebuffers: render to texture, per-target viewport and scissor, readback | 10 | 75% | M3 test on hardware 2026-09-12: a 128x64 RGBA8 texture as target, complete status, scissored clears, draws, gl_FragCoord unflipped (row 40.5 reads 161), glReadPixels from the texture, the texture sampled on the display afterwards. Bench 2026-09-12: render targets made and destroyed with their textures through 34 scenes, `tgt` back to 1 after each (page snapshots, saveLayers). Missing: renderbuffers (depth, stencil), the cost of target switches at gallery scale |
| Shader translation: GLSL ES 1.00 to Cg | 16 | 80% | M2 on hardware 2026-09-13: all 46 corpus shaders translate and compile through `libshacccg` on the console (median 144 ms, max 1.9 s per shader, cold). Locals that shadow attributes are renamed. Missing: `half` for `mediump`, constructs outside the corpus arrive as named errors |
| Programs: SceShaccCg compile, link, attribute and uniform reflection, uniform upload | 12 | 80% | M1: shader and program objects, link-time Cg compile, varying map, `glBindAttribLocation`, uniform table with locations, all `glUniform*` forms, matrix upload order verified by a translation through a `mat3`, fragment-program cache per blend state. M3 test: samplers bound to the unit `glUniform1i` named. Programs cached on disk by the hash of their Cg text (`ux0:data/fvita_gles2/cache`): the second launch of the bench read 62 of 64 from disk and compiled 2 (2026-09-13). Missing: relink and delete under load |
| Pipeline state: blend, masks, scissor, viewport, line width, front face, getters | 6 | 75% | M1: blend func/equation (separate forms) verified by two hand-computed blended pixels; `glGetIntegerv`/`Floatv`/`Booleanv` table; `glFinish`. M3: texture and framebuffer bindings, pack and unpack alignment in the getters. Missing: `glLineWidth` applied, depth/stencil state |
| Integration: `--gl gles2`, embedder switch, proc table, recording stubs, tracer | 6 | 80% | `tools/gles2-gen.py` generates `procs.c` and `stubs.c`. The embedder calls six functions of `flutter_vita_gl.h` and nothing else of either library (patch 0004); `templates/vita-app/gl_gles2.c` and `gl_vitagl.c` answer; `build-vita-app.sh --gl gles2`. The gallery ran on it 2026-09-12 (`docs/results/gallery-fvita-gles2-2026-09-12.md`). The exit path tears down 1315 textures and 54 render targets and hands back (`gles2-shutdown.txt`, watchdog in `gl_gles2.c`). `fvgl_stats` on every FRAMES line: it found the engine's snapshot-texture leak the same day (patch 0012). Missing: the tracer re-pointed at `fvgl_get_proc_address`, IME compositing over our frames |
| Parity: gallery screenshots, test apps, bench, vitaGL removed | 8 | 35% | Same engine, same day, both backends, 34 scenes (`docs/results/parity-2026-09-13.md`): raster per frame equal or lower on fvita_gles2 for 26 of 36 scenes (sum 185 vs 221 ms without the cache); the shader cache removed the eight 500 ms first-use frames, worst-frame sum 5917 vs vitaGL's 4450 ms, stall sum 11900 vs 10750 ms, with the UI-thread scenes moving as much between two of our own runs. Open: backdrop blur at 110 ms a frame against 42, route pushes 2 to 8 ms a frame over vitaGL, screenshots scene by scene, the five test apps not run on gles2 |
<!-- areas:end -->

## Milestones

| | milestone | state |
|---|---|---|
| M0 | clear, scissor, present through our own sceGxm context | **done 2026-09-12**, `gles2/test` M0 passes 10 of 10 pixel checks on hardware |
| M1 | a triangle from run-time-translated GLSL | **done 2026-09-12**, `gles2/test` M1 passes 8 of 8 (mat3 convention, blend, gl_FragCoord, VBO and client paths) |
| M2 | the gallery's shaders translate and compile | **done 2026-09-13**, 46 of 46 on the console (`gles2/test` M2) |
| M3 | the gallery draws under `--gl gles2` | **done 2026-09-12**: `gles2/test` M3 35 of 35; the gallery renders through the layer, 22 programs, no stub called (`docs/results/gallery-fvita-gles2-2026-09-12.md`) |
| M4 | test apps and bench at parity | |
| M5 | vitaGL and vitashark gone | |

## Entry-point ledger

<!-- ledger:begin -->
| entry point | measured | peak calls | state |
|---|---|---|---|
| `eglQueryString` | never | 0 | stub |
| `glActiveTexture` | called | 722 | real |
| `glAttachShader` | called | 58 | real |
| `glBindAttribLocation` | called | 82 | real |
| `glBindBuffer` | called | 8322 | real |
| `glBindFramebuffer` | called | 1253 | real |
| `glBindRenderbuffer` | never | 0 | stub |
| `glBindTexture` | called | 3931 | real |
| `glBindVertexArrayOES` | called | 1 | stub |
| `glBlendEquation` | called | 1 | real |
| `glBlendFunc` | called | 365 | real |
| `glBufferData` | called | 6072 | real |
| `glBufferSubData` | called | 6065 | real |
| `glCheckFramebufferStatus` | called | 1 | real |
| `glClear` | called | 5612 | real |
| `glClearColor` | called | 875 | real |
| `glClearStencil` | never | 0 | stub |
| `glColorMask` | called | 1 | real |
| `glCompileShader` | called | 58 | real |
| `glCompressedTexImage2D` | never | 0 | stub |
| `glCopyTexSubImage2D` | called | 18 | real |
| `glCreateProgram` | called | 29 | real |
| `glCreateShader` | called | 58 | real |
| `glCullFace` | never | 0 | stub |
| `glDeleteBuffers` | called | 2 | real |
| `glDeleteFramebuffers` | never | 0 | real |
| `glDeleteProgram` | never | 0 | real |
| `glDeleteRenderbuffers` | never | 0 | stub |
| `glDeleteShader` | called | 58 | real |
| `glDeleteTextures` | called | 66 | real |
| `glDeleteVertexArraysOES` | never | 0 | stub |
| `glDepthMask` | called | 1 | real |
| `glDisable` | called | 329 | real |
| `glDisableVertexAttribArray` | called | 6593 | real |
| `glDrawArrays` | called | 2360 | real |
| `glDrawArraysInstancedEXT` | never | 0 | stub |
| `glDrawElements` | called | 16628 | real |
| `glDrawElementsInstancedEXT` | never | 0 | stub |
| `glEnable` | called | 325 | real |
| `glEnableVertexAttribArray` | called | 6583 | real |
| `glFinish` | never | 0 | real |
| `glFlush` | never | 0 | real |
| `glFlushMappedBufferRangeEXT` | never | 0 | stub |
| `glFramebufferRenderbuffer` | never | 0 | stub |
| `glFramebufferTexture2D` | called | 1 | real |
| `glFrontFace` | called | 1 | real |
| `glGenBuffers` | called | 7 | real |
| `glGenFramebuffers` | called | 1 | real |
| `glGenRenderbuffers` | never | 0 | stub |
| `glGenTextures` | called | 363 | real |
| `glGenVertexArraysOES` | never | 0 | stub |
| `glGenerateMipmap` | never | 0 | stub |
| `glGetBufferParameteriv` | never | 0 | real |
| `glGetError` | called | 18449 | real |
| `glGetFloatv` | never | 0 | real |
| `glGetFramebufferAttachmentParameteriv` | never | 0 | real |
| `glGetProgramBinaryOES` | never | 0 | stub |
| `glGetProgramInfoLog` | never | 0 | real |
| `glGetProgramiv` | called | 29 | real |
| `glGetShaderInfoLog` | never | 0 | real |
| `glGetShaderiv` | called | 58 | real |
| `glGetString` | called | 9 | real |
| `glGetStringi` | never | 0 | stub |
| `glGetUniformLocation` | called | 138 | real |
| `glIsTexture` | never | 0 | real |
| `glLineWidth` | called | 1 | real |
| `glLinkProgram` | called | 29 | real |
| `glMapBufferOES` | never | 0 | stub |
| `glMapBufferRangeEXT` | called | 1 | stub |
| `glPixelStorei` | called | 376 | real |
| `glPopGroupMarkerEXT` | never | 0 | stub |
| `glProgramBinaryOES` | never | 0 | stub |
| `glPushGroupMarkerEXT` | never | 0 | stub |
| `glReadPixels` | called | 1 | real |
| `glRenderbufferStorage` | never | 0 | stub |
| `glScissor` | called | 29 | real |
| `glStencilFunc` | never | 0 | stub |
| `glStencilFuncSeparate` | never | 0 | stub |
| `glStencilMask` | never | 0 | stub |
| `glStencilMaskSeparate` | never | 0 | stub |
| `glStencilOp` | never | 0 | stub |
| `glStencilOpSeparate` | never | 0 | stub |
| `glTexImage2D` | called | 363 | real |
| `glTexParameterf` | never | 0 | real |
| `glTexParameteri` | called | 2374 | real |
| `glTexParameteriv` | never | 0 | real |
| `glTexSubImage2D` | called | 375 | real |
| `glUniform1f` | never | 0 | real |
| `glUniform1fv` | called | 364 | real |
| `glUniform1i` | called | 22 | real |
| `glUniform1iv` | never | 0 | real |
| `glUniform2f` | called | 228 | real |
| `glUniform2fv` | called | 255 | real |
| `glUniform2i` | never | 0 | real |
| `glUniform2iv` | never | 0 | real |
| `glUniform3f` | never | 0 | real |
| `glUniform3fv` | never | 0 | real |
| `glUniform3i` | never | 0 | real |
| `glUniform3iv` | never | 0 | real |
| `glUniform4f` | called | 374 | real |
| `glUniform4fv` | called | 2136 | real |
| `glUniform4i` | never | 0 | real |
| `glUniform4iv` | never | 0 | real |
| `glUniformMatrix2fv` | never | 0 | real |
| `glUniformMatrix3fv` | called | 1270 | real |
| `glUniformMatrix4fv` | never | 0 | real |
| `glUnmapBufferOES` | called | 1 | stub |
| `glUseProgram` | called | 15289 | real |
| `glVertexAttrib1f` | never | 0 | real |
| `glVertexAttrib2fv` | never | 0 | real |
| `glVertexAttrib3fv` | never | 0 | real |
| `glVertexAttrib4fv` | never | 0 | real |
| `glVertexAttribPointer` | called | 42759 | real |
| `glViewport` | called | 621 | real |
<!-- ledger:end -->
