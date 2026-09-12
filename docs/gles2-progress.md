# fvita_gles2 progress

How far the GLES2-over-sceGxm layer of ADR-0019 is from replacing vitaGL. The
blocks marked as generated are rewritten by `tools/gles2-progress.py` from the
source and `gles2/surface.txt`; the area table's `done` column is set by hand
and every change to it has to name its evidence in the last column.

<!-- progress:begin -->
**49% complete** (weighted areas, weights sum to 100).

| entry points | count |
|---|---|
| bound by Skia (`gles2/surface.txt`) | 114 |
| called in some run, implemented | 43 of 59 |
| never called, implemented anyway | 23 of 55 |
| recording stubs | 48 |
| missing | 0 |
<!-- progress:end -->

## Areas

<!-- areas:begin -->
| area | weight | done | evidence |
|---|---|---|---|
| Specification: the surface list, the shader corpus, the dialect | 6 | 90% | `gles2/surface.txt` (114 names, 59 called), 43 shaders in ADR-0018; the called set from one uninterrupted bench is the last 10% |
| Context: GPU memory, sceGxm init, display chain, scenes, present | 12 | 60% | M0 on hardware 2026-09-12. Frame notifications retire GPU memory (`fvgl_collect_garbage`), per-frame scratch rings, M1. Missing: scenes per frame for target switches, depth and stencil surfaces |
| Buffers and vertex input: VBO, IBO, attribute pointers, client arrays, draw calls | 14 | 60% | M1 on hardware 2026-09-12: VBO with `glBufferData(NULL)`+`glBufferSubData`, client arrays and client indices, `glDrawArrays`, `glDrawElements` (u8/u16/u32), line strips expanded, constant attributes via instance streams, vertex-program cache per layout. Missing: gallery-scale measurement of `fvgl_subdata_into_used_buffer`, variant eviction |
| Textures: 2D, sub-image, copy, parameters, pixel store, formats | 10 | 0% | |
| Framebuffers: render to texture, per-target viewport and scissor, readback | 10 | 10% | `glReadPixels` on the default framebuffer, M0 |
| Shader translation: GLSL ES 1.00 to Cg | 16 | 80% | M2 on hardware 2026-09-13: all 46 corpus shaders translate and compile through `libshacccg` on the console (median 144 ms, max 1.9 s per shader, cold). Locals that shadow attributes are renamed. Missing: `half` for `mediump`, constructs outside the corpus arrive as named errors |
| Programs: SceShaccCg compile, link, attribute and uniform reflection, uniform upload | 12 | 65% | M1: shader and program objects, link-time Cg compile, varying map, `glBindAttribLocation`, uniform table with locations, all `glUniform*` forms, matrix upload order verified by a translation through a `mat3`, fragment-program cache per blend state. Missing: samplers bound to textures, relink and delete under load |
| Pipeline state: blend, masks, scissor, viewport, line width, front face, getters | 6 | 70% | M1: blend func/equation (separate forms) verified by two hand-computed blended pixels; `glGetIntegerv`/`Floatv`/`Booleanv` table; `glFinish`. Missing: `glLineWidth` applied, depth/stencil state |
| Integration: `--gl gles2`, embedder switch, proc table, recording stubs, tracer | 6 | 30% | `tools/gles2-gen.py` generates `procs.c` (142 core names plus the extension names Skia asks for) and `stubs.c` (recording stubs writing `gles2-unimplemented.txt`). Missing: the build flag, the embedder switch, the tracer re-pointed |
| Parity: gallery screenshots, test apps, bench, vitaGL removed | 8 | 0% | |
<!-- areas:end -->

## Milestones

| | milestone | state |
|---|---|---|
| M0 | clear, scissor, present through our own sceGxm context | **done 2026-09-12**, `gles2/test` M0 passes 10 of 10 pixel checks on hardware |
| M1 | a triangle from run-time-translated GLSL | **done 2026-09-12**, `gles2/test` M1 passes 8 of 8 (mat3 convention, blend, gl_FragCoord, VBO and client paths) |
| M2 | the gallery's shaders translate and compile | **done 2026-09-13**, 46 of 46 on the console (`gles2/test` M2) |
| M3 | the gallery draws under `--gl gles2` | |
| M4 | test apps and bench at parity | |
| M5 | vitaGL and vitashark gone | |

## Entry-point ledger

<!-- ledger:begin -->
| entry point | measured | peak calls | state |
|---|---|---|---|
| `eglQueryString` | never | 0 | stub |
| `glActiveTexture` | called | 722 | stub |
| `glAttachShader` | called | 58 | real |
| `glBindAttribLocation` | called | 82 | real |
| `glBindBuffer` | called | 8322 | real |
| `glBindFramebuffer` | called | 1253 | stub |
| `glBindRenderbuffer` | never | 0 | stub |
| `glBindTexture` | called | 3931 | stub |
| `glBindVertexArrayOES` | called | 1 | stub |
| `glBlendEquation` | called | 1 | real |
| `glBlendFunc` | called | 365 | real |
| `glBufferData` | called | 6072 | real |
| `glBufferSubData` | called | 6065 | real |
| `glCheckFramebufferStatus` | called | 1 | stub |
| `glClear` | called | 5612 | real |
| `glClearColor` | called | 875 | real |
| `glClearStencil` | never | 0 | stub |
| `glColorMask` | called | 1 | real |
| `glCompileShader` | called | 58 | real |
| `glCompressedTexImage2D` | never | 0 | stub |
| `glCopyTexSubImage2D` | called | 18 | stub |
| `glCreateProgram` | called | 29 | real |
| `glCreateShader` | called | 58 | real |
| `glCullFace` | never | 0 | stub |
| `glDeleteBuffers` | called | 2 | real |
| `glDeleteFramebuffers` | never | 0 | stub |
| `glDeleteProgram` | never | 0 | real |
| `glDeleteRenderbuffers` | never | 0 | stub |
| `glDeleteShader` | called | 58 | real |
| `glDeleteTextures` | called | 66 | stub |
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
| `glFramebufferTexture2D` | called | 1 | stub |
| `glFrontFace` | called | 1 | real |
| `glGenBuffers` | called | 7 | real |
| `glGenFramebuffers` | called | 1 | stub |
| `glGenRenderbuffers` | never | 0 | stub |
| `glGenTextures` | called | 363 | stub |
| `glGenVertexArraysOES` | never | 0 | stub |
| `glGenerateMipmap` | never | 0 | stub |
| `glGetBufferParameteriv` | never | 0 | real |
| `glGetError` | called | 18449 | real |
| `glGetFloatv` | never | 0 | real |
| `glGetFramebufferAttachmentParameteriv` | never | 0 | stub |
| `glGetProgramBinaryOES` | never | 0 | stub |
| `glGetProgramInfoLog` | never | 0 | real |
| `glGetProgramiv` | called | 29 | real |
| `glGetShaderInfoLog` | never | 0 | real |
| `glGetShaderiv` | called | 58 | real |
| `glGetString` | called | 9 | real |
| `glGetStringi` | never | 0 | stub |
| `glGetUniformLocation` | called | 138 | real |
| `glIsTexture` | never | 0 | stub |
| `glLineWidth` | called | 1 | real |
| `glLinkProgram` | called | 29 | real |
| `glMapBufferOES` | never | 0 | stub |
| `glMapBufferRangeEXT` | called | 1 | stub |
| `glPixelStorei` | called | 376 | stub |
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
| `glTexImage2D` | called | 363 | stub |
| `glTexParameterf` | never | 0 | stub |
| `glTexParameteri` | called | 2374 | stub |
| `glTexParameteriv` | never | 0 | stub |
| `glTexSubImage2D` | called | 375 | stub |
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
