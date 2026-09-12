# fvita_gles2 progress

How far the GLES2-over-sceGxm layer of ADR-0019 is from replacing vitaGL. The
blocks marked as generated are rewritten by `tools/gles2-progress.py` from the
source and `gles2/surface.txt`; the area table's `done` column is set by hand
and every change to it has to name its evidence in the last column.

<!-- progress:begin -->
**15% complete** (weighted areas, weights sum to 100).

| entry points | count |
|---|---|
| bound by Skia (`gles2/surface.txt`) | 114 |
| called in some run, implemented | 10 of 59 |
| never called, implemented anyway | 0 of 55 |
| recording stubs | 0 |
| missing | 104 |
<!-- progress:end -->

## Areas

<!-- areas:begin -->
| area | weight | done | evidence |
|---|---|---|---|
| Specification: the surface list, the shader corpus, the dialect | 6 | 90% | `gles2/surface.txt` (114 names, 59 called), 43 shaders in ADR-0018; the called set from one uninterrupted bench is the last 10% |
| Context: GPU memory, sceGxm init, display chain, scenes, present | 12 | 45% | M0 on hardware 2026-09-12: `gles2/test` clears, scissors and presents through our context. Missing: deferred freeing of memory the GPU still reads, scenes per frame for target switches, depth and stencil surfaces |
| Buffers and vertex input: VBO, IBO, attribute pointers, client arrays, draw calls | 14 | 0% | |
| Textures: 2D, sub-image, copy, parameters, pixel store, formats | 10 | 0% | |
| Framebuffers: render to texture, per-target viewport and scissor, readback | 10 | 10% | `glReadPixels` on the default framebuffer, M0 |
| Shader translation: GLSL ES 1.00 to Cg | 16 | 0% | |
| Programs: SceShaccCg compile, link, attribute and uniform reflection, uniform upload | 12 | 15% | `gles2/src/shacc.c` compiles Cg on the console from our code; the clear pipeline registers and patches its two programs, M0 |
| Pipeline state: blend, masks, scissor, viewport, line width, front face, getters | 6 | 25% | clear colour, colour mask, exact scissor (region clip plus `clip()`), viewport flip, `glGetError`, `glGetString`, M0 |
| Integration: `--gl gles2`, embedder switch, proc table, recording stubs, tracer | 6 | 0% | |
| Parity: gallery screenshots, test apps, bench, vitaGL removed | 8 | 0% | |
<!-- areas:end -->

## Milestones

| | milestone | state |
|---|---|---|
| M0 | clear, scissor, present through our own sceGxm context | **done 2026-09-12**, `gles2/test` M0 passes 10 of 10 pixel checks on hardware |
| M1 | a triangle from run-time-translated GLSL | |
| M2 | the gallery's 43 shaders translate and compile | |
| M3 | the gallery draws under `--gl gles2` | |
| M4 | test apps and bench at parity | |
| M5 | vitaGL and vitashark gone | |

## Entry-point ledger

<!-- ledger:begin -->
| entry point | measured | peak calls | state |
|---|---|---|---|
| `eglQueryString` | never | 0 | missing |
| `glActiveTexture` | called | 722 | missing |
| `glAttachShader` | called | 58 | missing |
| `glBindAttribLocation` | called | 82 | missing |
| `glBindBuffer` | called | 8322 | missing |
| `glBindFramebuffer` | called | 1253 | missing |
| `glBindRenderbuffer` | never | 0 | missing |
| `glBindTexture` | called | 3931 | missing |
| `glBindVertexArrayOES` | called | 1 | missing |
| `glBlendEquation` | called | 1 | missing |
| `glBlendFunc` | called | 365 | missing |
| `glBufferData` | called | 6072 | missing |
| `glBufferSubData` | called | 6065 | missing |
| `glCheckFramebufferStatus` | called | 1 | missing |
| `glClear` | called | 5612 | real |
| `glClearColor` | called | 875 | real |
| `glClearStencil` | never | 0 | missing |
| `glColorMask` | called | 1 | real |
| `glCompileShader` | called | 58 | missing |
| `glCompressedTexImage2D` | never | 0 | missing |
| `glCopyTexSubImage2D` | called | 18 | missing |
| `glCreateProgram` | called | 29 | missing |
| `glCreateShader` | called | 58 | missing |
| `glCullFace` | never | 0 | missing |
| `glDeleteBuffers` | called | 2 | missing |
| `glDeleteFramebuffers` | never | 0 | missing |
| `glDeleteProgram` | never | 0 | missing |
| `glDeleteRenderbuffers` | never | 0 | missing |
| `glDeleteShader` | called | 58 | missing |
| `glDeleteTextures` | called | 66 | missing |
| `glDeleteVertexArraysOES` | never | 0 | missing |
| `glDepthMask` | called | 1 | missing |
| `glDisable` | called | 329 | real |
| `glDisableVertexAttribArray` | called | 6593 | missing |
| `glDrawArrays` | called | 2360 | missing |
| `glDrawArraysInstancedEXT` | never | 0 | missing |
| `glDrawElements` | called | 16628 | missing |
| `glDrawElementsInstancedEXT` | never | 0 | missing |
| `glEnable` | called | 325 | real |
| `glEnableVertexAttribArray` | called | 6583 | missing |
| `glFinish` | never | 0 | missing |
| `glFlush` | never | 0 | missing |
| `glFlushMappedBufferRangeEXT` | never | 0 | missing |
| `glFramebufferRenderbuffer` | never | 0 | missing |
| `glFramebufferTexture2D` | called | 1 | missing |
| `glFrontFace` | called | 1 | missing |
| `glGenBuffers` | called | 7 | missing |
| `glGenFramebuffers` | called | 1 | missing |
| `glGenRenderbuffers` | never | 0 | missing |
| `glGenTextures` | called | 363 | missing |
| `glGenVertexArraysOES` | never | 0 | missing |
| `glGenerateMipmap` | never | 0 | missing |
| `glGetBufferParameteriv` | never | 0 | missing |
| `glGetError` | called | 18449 | real |
| `glGetFloatv` | never | 0 | missing |
| `glGetFramebufferAttachmentParameteriv` | never | 0 | missing |
| `glGetProgramBinaryOES` | never | 0 | missing |
| `glGetProgramInfoLog` | never | 0 | missing |
| `glGetProgramiv` | called | 29 | missing |
| `glGetShaderInfoLog` | never | 0 | missing |
| `glGetShaderiv` | called | 58 | missing |
| `glGetString` | called | 9 | real |
| `glGetStringi` | never | 0 | missing |
| `glGetUniformLocation` | called | 138 | missing |
| `glIsTexture` | never | 0 | missing |
| `glLineWidth` | called | 1 | missing |
| `glLinkProgram` | called | 29 | missing |
| `glMapBufferOES` | never | 0 | missing |
| `glMapBufferRangeEXT` | called | 1 | missing |
| `glPixelStorei` | called | 376 | missing |
| `glPopGroupMarkerEXT` | never | 0 | missing |
| `glProgramBinaryOES` | never | 0 | missing |
| `glPushGroupMarkerEXT` | never | 0 | missing |
| `glReadPixels` | called | 1 | real |
| `glRenderbufferStorage` | never | 0 | missing |
| `glScissor` | called | 29 | real |
| `glStencilFunc` | never | 0 | missing |
| `glStencilFuncSeparate` | never | 0 | missing |
| `glStencilMask` | never | 0 | missing |
| `glStencilMaskSeparate` | never | 0 | missing |
| `glStencilOp` | never | 0 | missing |
| `glStencilOpSeparate` | never | 0 | missing |
| `glTexImage2D` | called | 363 | missing |
| `glTexParameterf` | never | 0 | missing |
| `glTexParameteri` | called | 2374 | missing |
| `glTexParameteriv` | never | 0 | missing |
| `glTexSubImage2D` | called | 375 | missing |
| `glUniform1f` | never | 0 | missing |
| `glUniform1fv` | called | 364 | missing |
| `glUniform1i` | called | 22 | missing |
| `glUniform1iv` | never | 0 | missing |
| `glUniform2f` | called | 228 | missing |
| `glUniform2fv` | called | 255 | missing |
| `glUniform2i` | never | 0 | missing |
| `glUniform2iv` | never | 0 | missing |
| `glUniform3f` | never | 0 | missing |
| `glUniform3fv` | never | 0 | missing |
| `glUniform3i` | never | 0 | missing |
| `glUniform3iv` | never | 0 | missing |
| `glUniform4f` | called | 374 | missing |
| `glUniform4fv` | called | 2136 | missing |
| `glUniform4i` | never | 0 | missing |
| `glUniform4iv` | never | 0 | missing |
| `glUniformMatrix2fv` | never | 0 | missing |
| `glUniformMatrix3fv` | called | 1270 | missing |
| `glUniformMatrix4fv` | never | 0 | missing |
| `glUnmapBufferOES` | called | 1 | missing |
| `glUseProgram` | called | 15289 | missing |
| `glVertexAttrib1f` | never | 0 | missing |
| `glVertexAttrib2fv` | never | 0 | missing |
| `glVertexAttrib3fv` | never | 0 | missing |
| `glVertexAttrib4fv` | never | 0 | missing |
| `glVertexAttribPointer` | called | 42759 | missing |
| `glViewport` | called | 621 | real |
<!-- ledger:end -->
