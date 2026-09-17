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

// A recording stub was called: GL_INVALID_OPERATION, and the name on the card once.
void fvgl_stub_called(const char* name);

// ---- GPU memory ------------------------------------------------------------

typedef enum FvglMemKind {
  FVGL_MEM_LPDDR_UNCACHED,  // CPU writes, GPU reads: vertex data, uniforms
  FVGL_MEM_LPDDR_CACHED,    // CPU reads back a lot: staging
  FVGL_MEM_CDRAM,           // display and render surfaces, textures
} FvglMemKind;

// A memblock mapped for the GPU. size is rounded up to the block's granule.
void* fvgl_mem_alloc(FvglMemKind kind, size_t size, SceUID* uid_out);
void fvgl_mem_free(SceUID uid);
void fvgl_note_lpddr_fallback(void);
extern unsigned fvgl_us_queue_wait, fvgl_us_garbage, fvgl_us_memblock;
static inline uint64_t fvgl_now_us(void) {
  extern uint64_t sceKernelGetProcessTimeWide(void);
  return sceKernelGetProcessTimeWide();
}
void fvgl_texture_stats(FvglStats* out);

// USSE memory for shader code, mapped for the vertex or the fragment unit.
void* fvgl_usse_alloc(bool fragment, size_t size, unsigned* usse_offset,
                      SceUID* uid_out);
void fvgl_usse_free(bool fragment, SceUID uid);

// ---- the Cg compiler -------------------------------------------------------

int fvgl_shacc_init(const char* module_path);
// Cg text in, a SceGxmProgram in host memory out (free() it after
// unregistering). On failure returns 0 and puts the diagnostics in log.
void fvgl_shader_cache_init(const char* dir);
extern unsigned fvgl_shader_cache_hits, fvgl_shader_cache_misses;
SceGxmProgram* fvgl_shacc_compile(const char* cg_source, bool fragment,
                                  char* log, size_t log_size);
void fvgl_shacc_shutdown(void);

// ---- frames and deferred freeing ------------------------------------------
//
// The GPU runs behind the CPU. Memory a draw referenced cannot be freed until
// that draw has executed, so a free is stamped with the frame number and
// done once the GPU has signalled that frame complete.

void fvgl_defer_free(SceUID uid);
void fvgl_defer_free_usse(bool fragment, SceUID uid);
void fvgl_defer_destroy_target(SceGxmRenderTarget* target);
uint32_t fvgl_gpu_completed_frame(void);
void fvgl_collect_garbage(bool everything);
// Blocks until the GPU reports `frame` done. A frame that is still being
// recorded cannot complete, so for the current frame this finishes the
// context instead. Both are counted, because both are stalls.
void fvgl_wait_for_frame(uint32_t frame);
extern unsigned fvgl_stalls_previous_frame, fvgl_stalls_this_frame;
extern unsigned fvgl_subdata_into_used_buffer;
extern unsigned fvgl_vertex_variants, fvgl_fragment_variants, fvgl_variants_uncached;
extern unsigned fvgl_us_link, fvgl_us_cache_read;

// Per-frame scratch memory for client-side vertex arrays and converted
// indices. Valid until the display buffer it belongs to comes round again.
void* fvgl_scratch_alloc(size_t size, size_t align);
void fvgl_scratch_reset(int display_index);
int fvgl_scratch_init(void);
void fvgl_scratch_shutdown(void);

// ---- objects ---------------------------------------------------------------

typedef struct FvglTable {
  void** items;
  unsigned count, cap;  // names are 1..count
} FvglTable;

unsigned fvgl_table_add(FvglTable* t, void* item);
void* fvgl_table_get(const FvglTable* t, unsigned name);
void fvgl_table_clear(FvglTable* t, unsigned name);

typedef struct FvglBuffer {
  SceUID uid;
  uint8_t* data;
  size_t size;      // what glBufferData set
  size_t capacity;  // what the block holds
  GLenum usage;
  uint32_t last_frame_used;
} FvglBuffer;

#include "translate.h"

typedef struct FvglShader {
  GLenum type;
  char* source;
  bool compiled;
  bool delete_pending;
  int attached;  // programs holding it
  FvglShaderInfo info;
  char log[1024];
} FvglShader;

typedef struct FvglUniform {
  char name[FVGL_NAME_MAX];
  FvglType type;
  int components;  // per element
  int array;       // element count, 1 when not an array
  const SceGxmProgramParameter* vp;
  const SceGxmProgramParameter* fp;
  float* values;   // array * components, GL layout (matrix columns in order)
  bool is_sampler;
  int unit;        // sampler: the texture unit glUniform1i set
} FvglUniform;

typedef struct FvglAttribute {
  char name[FVGL_NAME_MAX];
  int location;
  const SceGxmProgramParameter* param;  // null when the compiler dropped it
  int components;                       // the shader's
} FvglAttribute;

#define FVGL_MAX_VARIANTS 32

typedef struct FvglVertexVariant {
  uint8_t key[64];
  int key_len;
  SceGxmVertexProgram* program;
} FvglVertexVariant;

typedef struct FvglFragmentVariant {
  uint32_t key;
  SceGxmFragmentProgram* program;
} FvglFragmentVariant;

typedef struct FvglProgram {
  FvglShader* vs;
  FvglShader* fs;
  unsigned vs_name, fs_name;
  bool linked;
  bool delete_pending;
  char log[1024];
  SceGxmProgram* vgxp;
  SceGxmProgram* fgxp;
  SceGxmShaderPatcherId vid, fid;
  int uniform_count;
  FvglUniform uniforms[FVGL_MAX_UNIFORMS];
  int attribute_count;
  FvglAttribute attributes[FVGL_MAX_ATTRIBUTES];
  // glBindAttribLocation calls, applied at link.
  int bound_count;
  char bound_names[FVGL_MAX_ATTRIBUTES][FVGL_NAME_MAX];
  int bound_locations[FVGL_MAX_ATTRIBUTES];
  const SceGxmProgramParameter* fc_param;  // fvgl_fc, when the fragment shader reads gl_FragCoord
  int vertex_variant_count;
  FvglVertexVariant vertex_variants[FVGL_MAX_VARIANTS];
  int fragment_variant_count;
  FvglFragmentVariant fragment_variants[FVGL_MAX_VARIANTS];
  bool uniforms_dirty;
} FvglProgram;

typedef void (*FvglTexelConvert)(uint8_t* dst, const uint8_t* src, int texels);

typedef struct FvglTexture {
  SceUID uid;
  uint8_t* data;
  size_t bytes;  // of the block
  int width, height;
  GLenum format, type;  // the GL pair the storage was made for
  unsigned bpp;         // bytes per texel in storage
  unsigned src_bpp;     // bytes per texel as GL hands them in
  FvglTexelConvert convert;  // client texels to storage texels, NULL for a copy
  unsigned stride;      // bytes per row
  SceGxmTextureFormat gxm_format;
  SceGxmTexture gxm;
  bool has_storage;
  bool in_fallback;  // storage is main memory because CDRAM was full
  bool tiled;        // 32x32 tiles, the layout render targets get; the CPU never touches it
  bool linear_only;  // a staging texture the CPU reads: stays linear when drawn into
  bool params_dirty;  // filters or wrap changed since gxm was set up
  GLenum min_filter, mag_filter, wrap_s, wrap_t;
  uint32_t last_frame_used;
  // Made when the texture is first attached to a framebuffer.
  SceGxmRenderTarget* target;
  SceGxmColorSurface surface;
} FvglTexture;

typedef struct FvglFramebuffer {
  unsigned color;  // texture name at GL_COLOR_ATTACHMENT0, 0 when none
} FvglFramebuffer;

#define FVGL_MAX_TEXTURE_UNITS 8

typedef struct FvglVertexAttribState {
  bool enabled;
  GLint size;
  GLenum type;
  GLboolean normalized;
  GLsizei stride;
  const void* pointer;
  unsigned buffer;  // the GL_ARRAY_BUFFER bound at glVertexAttribPointer time
  float constant[4];
} FvglVertexAttribState;

typedef struct FvglBlendState {
  bool enabled;
  GLenum src_rgb, dst_rgb, src_alpha, dst_alpha;
  GLenum eq_rgb, eq_alpha;
} FvglBlendState;

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
  unsigned display_stride;  // pixels per row of a display buffer
  FvglDisplayBuffer display[FVGL_MAX_DISPLAY_BUFFERS];
  int back, front;  // indices into display[]

  // A common dialog is up: swap composites it (fvgl_set_common_dialog). The
  // shell wants a depth surface to draw with; made on the first dialog.
  bool dialog_open;
  void* dialog_depth;
  SceUID dialog_depth_uid;

  // A scene is open between the first draw into a target and the moment the
  // target changes or the frame is presented.
  bool scene_open;

  FvglClearPipeline clear;

  // Frame bookkeeping. `frame` is the one being recorded; the GPU writes the
  // number of the last one it finished into the notification slot.
  uint32_t frame;
  volatile unsigned* frame_done;

  // GL state.
  GLenum error;
  float clear_color[4];
  GLboolean color_mask[4];
  bool scissor_enabled;
  GLint scissor[4];
  GLint viewport[4];
  FvglBlendState blend;
  GLenum front_face;
  GLboolean depth_mask;
  float line_width;
  bool cull_enabled, depth_test_enabled, stencil_test_enabled, dither_enabled;

  FvglTable shaders, programs, buffers, textures, framebuffers;
  FvglProgram* current_program;
  FvglProgram* bound_program;  // what the GXM context last saw
  unsigned array_buffer, element_buffer;
  FvglVertexAttribState attribs[FVGL_MAX_ATTRIBUTES];

  int active_unit;
  unsigned unit_2d[FVGL_MAX_TEXTURE_UNITS];    // GL_TEXTURE_2D binding per unit
  unsigned unit_cube[FVGL_MAX_TEXTURE_UNITS];  // GL_TEXTURE_CUBE_MAP, bound and refused
  GLint unpack_alignment, pack_alignment;
  FvglTexture fallback;  // 1x1 opaque white: what an incomplete sampler reads

  // The render target: the display, or the texture attached to the bound
  // framebuffer. The scene, if one is open, is on `scene_target`.
  unsigned bound_framebuffer;
  FvglTexture* scene_target;

  // The hidden fragment uniform behind gl_FragCoord: (a, b) with y = a + b * wpos.y.
  float fc[2];
  float bound_fc[2];
} FvglContext;

extern FvglContext fvgl;

// Makes sure a scene is open on the current target and the raster state
// matches the GL state. Every draw and clear starts here.
void fvgl_scene_begin(void);
void fvgl_scene_end(void);

// The texture the bound framebuffer draws into, NULL for the display.
FvglTexture* fvgl_current_target(void);
int fvgl_blit_init(void);
void fvgl_blit_shutdown(void);
bool fvgl_blit_from_target(FvglTexture* dst, int xoffset, int yoffset, int x, int y, int w, int h);
bool fvgl_blit(FvglTexture* dst, int xoffset, int yoffset, const SceGxmTexture* source, int fw, int fh,
               bool flipped, int x, int y, int w, int h);
bool fvgl_current_target_as_texture(SceGxmTexture* out, int* fw, int* fh, bool* flipped);
// A linear copy of a tiled texture for the CPU to read, made by the GPU and
// finished. The caller frees it with fvgl_texture_scratch_free.
FvglTexture* fvgl_texture_linear_copy(FvglTexture* t);
FvglTexture* fvgl_texture_scratch_linear(int width, int height);
void fvgl_texture_scratch_free(FvglTexture* t);
bool fvgl_texture_make_tiled(FvglTexture* t);
extern unsigned fvgl_blits;
// The target's size, and whether GL rows are counted from its bottom
// (the display) or match memory rows (a texture).
void fvgl_target_extent(int* width, int* height, bool* flipped);

// programs.c
void fvgl_programs_shutdown(void);
// textures.c
int fvgl_textures_init(void);
void fvgl_textures_shutdown(void);
// Sets the fragment textures the program's samplers name. Called per draw.
void fvgl_bind_samplers(FvglProgram* p);
// framebuffers.c
void fvgl_framebuffers_shutdown(void);
// A render target and colour surface over the texture's storage, once.
bool fvgl_texture_make_target(FvglTexture* t);
// A texture is being deleted: framebuffers pointing at it lose the attachment.
void fvgl_framebuffers_forget_texture(unsigned texture);
// draw.c
void fvgl_draw_init(void);
void fvgl_draw_shutdown(void);
void fvgl_buffers_shutdown(void);

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
