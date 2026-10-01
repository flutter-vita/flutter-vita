// Renderbuffer objects, and the depth and stencil surface behind them.
//
// One allocation rule serves both the default framebuffer's depth and every
// renderbuffer a program makes: packed 24-bit depth with 8-bit stencil
// (SCE_GXM_DEPTH_STENCIL_FORMAT_S8D24), tiled, rounded up to whole 32x32
// tiles because that is how the hardware addresses depth. The stencil shares
// the depth allocation, so the surface takes a null stencil pointer.
//
// Every depth or stencil format a program can ask for gets that same surface.
// GL lets an implementation give more bits than the internalformat names, so
// GL_DEPTH_COMPONENT16 is answered with 24 and the getter says 24. A
// renderbuffer asked for a colour format is remembered and given no storage:
// it is legal GL, nothing here can draw into one (the colour path goes
// through a texture's SceGxmColorSurface), and a framebuffer that has one
// attached answers GL_FRAMEBUFFER_UNSUPPORTED. Making them real means giving
// a renderbuffer the colour surface and render target that fvgl_texture_make_target
// builds for a texture; no caller has asked.
//
// Force load and force store are both on. Without them the depth contents
// live in tile memory for one scene and are gone at the next, and GL says a
// depth buffer keeps what was written until something clears it. It costs
// bandwidth on every scene that has a surface -- which is no scene at all in
// an app that never enables the depth or stencil test, because the display's
// surface is not allocated until one of them does.
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

// Formats not in the SDK's gl2.h; they come from OES extensions that are not
// advertised, and Skia's ES2 path names the first two anyway.
#define FVGL_DEPTH_COMPONENT24 0x81A6
#define FVGL_DEPTH24_STENCIL8 0x88F0
#define FVGL_RGB8 0x8051
#define FVGL_RGBA8 0x8058

static FvglRenderbuffer* renderbuffer_get(GLuint name) { return fvgl_table_get(&fvgl.renderbuffers, name); }

// The renderbuffer bound to GL_RENDERBUFFER, or NULL with the error set.
static FvglRenderbuffer* renderbuffer_bound(GLenum target, const char* who) {
  if (target != GL_RENDERBUFFER) {
    fvgl_set_error(GL_INVALID_ENUM);
    return NULL;
  }
  FvglRenderbuffer* rb = renderbuffer_get(fvgl.bound_renderbuffer);
  if (!rb) {
    fvgl_set_error(GL_INVALID_OPERATION);
    fvgl_log("%s: no renderbuffer is bound", who);
  }
  return rb;
}

// ---- the surface -----------------------------------------------------------

void fvgl_depth_stencil_free(FvglRenderbuffer* rb) {
  if (!rb->has_storage) return;
  fvgl_defer_free(rb->uid);
  rb->uid = -1;
  rb->data = NULL;
  rb->bytes = 0;
  rb->has_storage = false;
}

bool fvgl_depth_stencil_make(FvglRenderbuffer* rb, int width, int height) {
  fvgl_depth_stencil_free(rb);
  if (width <= 0 || height <= 0) return false;
  const unsigned aw = ((unsigned)width + SCE_GXM_TILE_SIZEX - 1) & ~(SCE_GXM_TILE_SIZEX - 1);
  const unsigned ah = ((unsigned)height + SCE_GXM_TILE_SIZEY - 1) & ~(SCE_GXM_TILE_SIZEY - 1);
  const size_t bytes = (size_t)aw * (size_t)ah * 4;
  rb->data = fvgl_mem_alloc(FVGL_MEM_CDRAM, bytes, &rb->uid);
  if (!rb->data) {
    fvgl_log("depth and stencil %dx%d: no memory for %u KiB", width, height, (unsigned)(bytes >> 10));
    rb->uid = -1;
    return false;
  }
  // Packed: the stencil lives in the same allocation as the depth, so the
  // stencil pointer is null.
  const int r = sceGxmDepthStencilSurfaceInit(&rb->surface, SCE_GXM_DEPTH_STENCIL_FORMAT_S8D24,
                                              SCE_GXM_DEPTH_STENCIL_SURFACE_TILED, aw, rb->data, NULL);
  if (r < 0) {
    fvgl_log("sceGxmDepthStencilSurfaceInit %ux%u: 0x%08X", aw, ah, (unsigned)r);
    fvgl_defer_free(rb->uid);
    rb->uid = -1;
    rb->data = NULL;
    return false;
  }
  sceGxmDepthStencilSurfaceSetForceLoadMode(&rb->surface, SCE_GXM_DEPTH_STENCIL_FORCE_LOAD_ENABLED);
  sceGxmDepthStencilSurfaceSetForceStoreMode(&rb->surface, SCE_GXM_DEPTH_STENCIL_FORCE_STORE_ENABLED);
  rb->bytes = bytes;
  rb->width = width;
  rb->height = height;
  rb->stride = aw;
  rb->has_storage = true;
  return true;
}

// ---- formats ---------------------------------------------------------------

// Depth and stencil bits for an internalformat, or false when it names a
// colour format (valid, and given no storage here) or nothing at all.
static bool depth_stencil_format(GLenum f, unsigned* depth, unsigned* stencil) {
  switch (f) {
    case GL_DEPTH_COMPONENT16:
    case FVGL_DEPTH_COMPONENT24:
      // The surface is 24-bit whichever was asked for, and the getter says so.
      *depth = 24;
      *stencil = 0;
      return true;
    case GL_STENCIL_INDEX8:
      *depth = 0;
      *stencil = 8;
      return true;
    case FVGL_DEPTH24_STENCIL8:
      *depth = 24;
      *stencil = 8;
      return true;
    default:
      *depth = 0;
      *stencil = 0;
      return false;
  }
}

static bool colour_format(GLenum f) {
  switch (f) {
    case GL_RGBA4: case GL_RGB565: case GL_RGB5_A1: case FVGL_RGB8: case FVGL_RGBA8:
      return true;
    default:
      return false;
  }
}

// ---- GL --------------------------------------------------------------------

GL_APICALL void GL_APIENTRY glGenRenderbuffers(GLsizei n, GLuint* renderbuffers) {
  if (!fvgl.up) return;
  if (n < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  for (GLsizei i = 0; i < n; i++) {
    FvglRenderbuffer* rb = calloc(1, sizeof *rb);
    if (!rb) {
      fvgl_set_error(GL_OUT_OF_MEMORY);
      return;
    }
    rb->uid = -1;
    renderbuffers[i] = fvgl_table_add(&fvgl.renderbuffers, rb);
  }
}

GL_APICALL void GL_APIENTRY glBindRenderbuffer(GLenum target, GLuint renderbuffer) {
  if (!fvgl.up) return;
  if (target != GL_RENDERBUFFER) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  // A name that glGenRenderbuffers never handed out is still bindable, as it
  // is for every other object in this layer.
  if (renderbuffer != 0 && !renderbuffer_get(renderbuffer)) {
    while (fvgl.renderbuffers.count < renderbuffer) {
      FvglRenderbuffer* rb = calloc(1, sizeof *rb);
      if (!rb) {
        fvgl_set_error(GL_OUT_OF_MEMORY);
        return;
      }
      rb->uid = -1;
      fvgl_table_add(&fvgl.renderbuffers, rb);
    }
  }
  fvgl.bound_renderbuffer = renderbuffer;
}

GL_APICALL void GL_APIENTRY glDeleteRenderbuffers(GLsizei n, const GLuint* renderbuffers) {
  if (!fvgl.up) return;
  if (n < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  for (GLsizei i = 0; i < n; i++) {
    FvglRenderbuffer* rb = renderbuffer_get(renderbuffers[i]);
    if (!rb) continue;
    // A scene drawing through this surface has to end before the memory goes.
    if (fvgl_scene_uses_renderbuffer(rb)) fvgl_scene_end();
    fvgl_framebuffers_forget_renderbuffer(renderbuffers[i]);
    if (fvgl.bound_renderbuffer == renderbuffers[i]) fvgl.bound_renderbuffer = 0;
    fvgl_depth_stencil_free(rb);
    free(rb);
    fvgl_table_clear(&fvgl.renderbuffers, renderbuffers[i]);
  }
}

GL_APICALL GLboolean GL_APIENTRY glIsRenderbuffer(GLuint renderbuffer) {
  if (!fvgl.up) return GL_FALSE;
  return renderbuffer_get(renderbuffer) != NULL;
}

GL_APICALL void GL_APIENTRY glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width,
                                                  GLsizei height) {
  if (!fvgl.up) return;
  FvglRenderbuffer* rb = renderbuffer_bound(target, "glRenderbufferStorage");
  if (!rb) return;
  if (width < 0 || height < 0 || width > 4096 || height > 4096) {
    fvgl_set_error(GL_INVALID_VALUE);  // GL_MAX_RENDERBUFFER_SIZE
    return;
  }
  unsigned depth, stencil;
  const bool ds = depth_stencil_format(internalformat, &depth, &stencil);
  if (!ds && !colour_format(internalformat)) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  if (fvgl_scene_uses_renderbuffer(rb)) fvgl_scene_end();
  fvgl_depth_stencil_free(rb);
  rb->format = internalformat;
  rb->width = width;
  rb->height = height;
  rb->depth_bits = depth;
  rb->stencil_bits = stencil;
  if (!ds) return;  // a colour renderbuffer keeps its size and gets no surface
  if (!fvgl_depth_stencil_make(rb, width, height)) fvgl_set_error(GL_OUT_OF_MEMORY);
}

GL_APICALL void GL_APIENTRY glGetRenderbufferParameteriv(GLenum target, GLenum pname, GLint* params) {
  if (!fvgl.up) return;
  FvglRenderbuffer* rb = renderbuffer_bound(target, "glGetRenderbufferParameteriv");
  if (!rb || !params) return;
  switch (pname) {
    case GL_RENDERBUFFER_WIDTH: *params = rb->width; break;
    case GL_RENDERBUFFER_HEIGHT: *params = rb->height; break;
    case GL_RENDERBUFFER_INTERNAL_FORMAT: *params = (GLint)rb->format; break;
    case GL_RENDERBUFFER_DEPTH_SIZE: *params = (GLint)rb->depth_bits; break;
    case GL_RENDERBUFFER_STENCIL_SIZE: *params = (GLint)rb->stencil_bits; break;
    // A colour renderbuffer has a size and no storage, so the channel widths
    // come from the format it was asked for.
    case GL_RENDERBUFFER_RED_SIZE:
    case GL_RENDERBUFFER_GREEN_SIZE:
    case GL_RENDERBUFFER_BLUE_SIZE:
    case GL_RENDERBUFFER_ALPHA_SIZE: {
      int r = 0, g = 0, b = 0, a = 0;
      switch (rb->format) {
        case GL_RGBA4: r = g = b = a = 4; break;
        case GL_RGB565: r = 5; g = 6; b = 5; break;
        case GL_RGB5_A1: r = g = b = 5; a = 1; break;
        case FVGL_RGB8: r = g = b = 8; break;
        case FVGL_RGBA8: r = g = b = a = 8; break;
        default: break;
      }
      *params = pname == GL_RENDERBUFFER_RED_SIZE     ? r
                : pname == GL_RENDERBUFFER_GREEN_SIZE ? g
                : pname == GL_RENDERBUFFER_BLUE_SIZE  ? b
                                                      : a;
      break;
    }
    default:
      fvgl_set_error(GL_INVALID_ENUM);
      break;
  }
}

// ---- lifetime --------------------------------------------------------------

void fvgl_renderbuffers_shutdown(void) {
  for (unsigned i = 1; i <= fvgl.renderbuffers.count; i++) {
    FvglRenderbuffer* rb = renderbuffer_get(i);
    if (!rb) continue;
    fvgl_depth_stencil_free(rb);
    free(rb);
  }
  free(fvgl.renderbuffers.items);
  memset(&fvgl.renderbuffers, 0, sizeof fvgl.renderbuffers);
  fvgl.bound_renderbuffer = 0;
}
