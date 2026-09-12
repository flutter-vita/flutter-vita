// State shared by the translation units of fvita_gles2. Nothing here is API.
#ifndef FVGL_INTERNAL_H
#define FVGL_INTERNAL_H

#include <GLES2/gl2.h>
#include <psp2/gxm.h>
#include <psp2/types.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "fvgl.h"

// ---- diagnostics -----------------------------------------------------------

void fvgl_log(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

// Records the first GL error since the last glGetError, as the spec asks.
void fvgl_set_error(GLenum error);

// ---- GPU memory ------------------------------------------------------------

typedef enum FvglMemKind {
  FVGL_MEM_LPDDR_UNCACHED,  // CPU writes, GPU reads: vertex data, uniforms
  FVGL_MEM_LPDDR_CACHED,    // CPU reads back a lot: staging
  FVGL_MEM_CDRAM,           // display and render surfaces, textures
} FvglMemKind;

// A memblock mapped for the GPU. size is rounded up to the block's granule.
void* fvgl_mem_alloc(FvglMemKind kind, size_t size, SceUID* uid_out);
void fvgl_mem_free(SceUID uid);

// USSE memory for shader code, mapped for the vertex or the fragment unit.
void* fvgl_usse_alloc(bool fragment, size_t size, unsigned* usse_offset,
                      SceUID* uid_out);
void fvgl_usse_free(bool fragment, SceUID uid);

// ---- the Cg compiler -------------------------------------------------------

int fvgl_shacc_init(const char* module_path);
// Cg text in, a SceGxmProgram in host memory out (free() it after
// unregistering). On failure returns 0 and puts the diagnostics in log.
SceGxmProgram* fvgl_shacc_compile(const char* cg_source, bool fragment,
                                  char* log, size_t log_size);
void fvgl_shacc_shutdown(void);

// ---- the context -----------------------------------------------------------

#define FVGL_MAX_DISPLAY_BUFFERS 3

typedef struct FvglDisplayBuffer {
  SceUID uid;
  void* data;
  SceGxmColorSurface surface;
  SceGxmSyncObject* sync;
} FvglDisplayBuffer;

typedef struct FvglClearPipeline {
  SceGxmProgram* vertex_gxp;
  SceGxmProgram* fragment_gxp;
  SceGxmShaderPatcherId vertex_id;
  SceGxmShaderPatcherId fragment_id;
  SceGxmVertexProgram* vertex;
  // One fragment program per colour mask, made on first use. Index is the
  // GL mask bits r|g<<1|b<<2|a<<3.
  SceGxmFragmentProgram* fragment[16];
  const SceGxmProgramParameter* color_param;
  const SceGxmProgramParameter* scissor_param;
  SceUID vertex_uid;
  float* vertices;   // three, clip space, a triangle that covers the target
  SceUID index_uid;
  uint16_t* indices;
} FvglClearPipeline;

typedef struct FvglContext {
  bool up;
  int width, height;
  void (*log)(const char*);

  SceGxmContext* gxm;
  void* host_mem;
  SceUID vdm_uid, vertex_ring_uid, fragment_ring_uid, fragment_usse_uid;
  SceGxmShaderPatcher* patcher;
  SceUID patcher_buffer_uid, patcher_vertex_usse_uid,
      patcher_fragment_usse_uid;

  SceGxmRenderTarget* display_target;
  SceGxmDepthStencilSurface no_depth;
  int display_buffer_count;
  FvglDisplayBuffer display[FVGL_MAX_DISPLAY_BUFFERS];
  int back, front;  // indices into display[]

  // A scene is open between the first draw into a target and the moment the
  // target changes or the frame is presented.
  bool scene_open;

  FvglClearPipeline clear;

  // GL state this file owns.
  GLenum error;
  float clear_color[4];
  GLboolean color_mask[4];
  bool scissor_enabled;
  GLint scissor[4];
  GLint viewport[4];
} FvglContext;

extern FvglContext fvgl;

// Makes sure a scene is open on the current target and the raster state
// matches the GL state. Every draw and clear starts here.
void fvgl_scene_begin(void);
void fvgl_scene_end(void);

// The GL calls implemented in context.c and registered in procs.c.
GL_APICALL void GL_APIENTRY glClearColor(GLfloat, GLfloat, GLfloat, GLfloat);
GL_APICALL void GL_APIENTRY glClear(GLbitfield);
GL_APICALL void GL_APIENTRY glColorMask(GLboolean, GLboolean, GLboolean, GLboolean);
GL_APICALL void GL_APIENTRY glScissor(GLint, GLint, GLsizei, GLsizei);
GL_APICALL void GL_APIENTRY glViewport(GLint, GLint, GLsizei, GLsizei);
GL_APICALL void GL_APIENTRY glEnable(GLenum);
GL_APICALL void GL_APIENTRY glDisable(GLenum);
GL_APICALL void GL_APIENTRY glReadPixels(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*);
GL_APICALL GLenum GL_APIENTRY glGetError(void);
GL_APICALL const GLubyte* GL_APIENTRY glGetString(GLenum);

#endif
