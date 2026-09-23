// Framebuffer objects: a texture drawn into instead of the display.
//
// A framebuffer here holds one colour attachment and nothing else. There is
// no depth or stencil surface anywhere in this layer (glGetIntegerv says 0
// bits of each), and renderbuffers stay recording stubs until a run shows
// Skia asking for one.
//
// The attached texture gets its own SceGxmRenderTarget the first time it is
// attached, and a colour surface over its storage. Drawing into it is a
// scene on that target, opened by fvgl_scene_begin when the bound framebuffer
// differs from the one the open scene is on.
//
// Orientation: GL's window y for a texture target counts from the texture's
// row 0, and row 0 is the first row in memory, which is also the GPU's row 0.
// So a texture target is not flipped, where the display is. fvgl_target_extent
// tells the viewport, scissor, gl_FragCoord and glReadPixels which case holds.
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

static FvglFramebuffer* framebuffer_get(GLuint name) { return fvgl_table_get(&fvgl.framebuffers, name); }

FvglTexture* fvgl_current_target(void) {
  FvglFramebuffer* f = framebuffer_get(fvgl.bound_framebuffer);
  if (!f) return NULL;
  FvglTexture* t = fvgl_table_get(&fvgl.textures, f->color);
  return t && t->has_storage ? t : NULL;
}

// No target carries a depth or stencil surface yet: the display draws through
// sceGxmDepthStencilSurfaceInitDisabled and a framebuffer object holds one
// colour attachment. fvgl_apply_raster asks before it writes any depth or
// stencil state, so the tests stay off until there is something to test
// against.
bool fvgl_scene_has_depth(void) { return false; }

void fvgl_target_extent(int* width, int* height, bool* flipped) {
  const FvglTexture* t = fvgl_current_target();
  if (t) {
    *width = t->width;
    *height = t->height;
    *flipped = false;
  } else {
    *width = fvgl.width;
    *height = fvgl.height;
    *flipped = true;
  }
}

// Makes the texture drawable: a render target and a colour surface.
bool fvgl_texture_make_target(FvglTexture* t) {
  if (t->target) return true;
  if (!t->has_storage || t->gxm_format != SCE_GXM_TEXTURE_FORMAT_U8U8U8U8_ABGR) return false;
  // The tiled layout, unless the console refuses it; contents are kept.
  fvgl_texture_make_tiled(t);
  if (t->target) return true;  // the conversion's blit made it
  int r = sceGxmColorSurfaceInit(&t->surface, SCE_GXM_COLOR_FORMAT_A8B8G8R8,
                                 t->tiled ? SCE_GXM_COLOR_SURFACE_TILED : SCE_GXM_COLOR_SURFACE_LINEAR,
                                 SCE_GXM_COLOR_SURFACE_SCALE_NONE, SCE_GXM_OUTPUT_REGISTER_SIZE_32BIT,
                                 (unsigned)t->width, (unsigned)t->height, t->stride / 4, t->data);
  if (r < 0) {
    fvgl_log("sceGxmColorSurfaceInit %dx%d stride %u: 0x%08X", t->width, t->height, t->stride / 4, (unsigned)r);
    return false;
  }
  SceGxmRenderTargetParams params = {
      .flags = 0,
      .width = (uint16_t)t->width,
      .height = (uint16_t)t->height,
      .scenesPerFrame = 1,
      .multisampleMode = SCE_GXM_MULTISAMPLE_NONE,
      .multisampleLocations = 0,
      .driverMemBlock = -1,
  };
  r = sceGxmCreateRenderTarget(&params, &t->target);
  if (r < 0) {
    fvgl_log("sceGxmCreateRenderTarget %dx%d: 0x%08X", t->width, t->height, (unsigned)r);
    t->target = NULL;
    return false;
  }
  return true;
}

// ---- GL --------------------------------------------------------------------

GL_APICALL void GL_APIENTRY glGenFramebuffers(GLsizei n, GLuint* framebuffers) {
  if (!fvgl.up) return;
  if (n < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  for (GLsizei i = 0; i < n; i++) framebuffers[i] = fvgl_table_add(&fvgl.framebuffers, calloc(1, sizeof(FvglFramebuffer)));
}

GL_APICALL void GL_APIENTRY glBindFramebuffer(GLenum target, GLuint framebuffer) {
  if (!fvgl.up) return;
  if (target != GL_FRAMEBUFFER) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  if (framebuffer != 0 && !framebuffer_get(framebuffer)) {
    while (fvgl.framebuffers.count < framebuffer) fvgl_table_add(&fvgl.framebuffers, calloc(1, sizeof(FvglFramebuffer)));
  }
  fvgl.bound_framebuffer = framebuffer;
  // The scene, if open, stays on its target until the next draw or clear
  // asks for the new one; nothing to do here.
}

GL_APICALL void GL_APIENTRY glDeleteFramebuffers(GLsizei n, const GLuint* framebuffers) {
  if (!fvgl.up) return;
  if (n < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  for (GLsizei i = 0; i < n; i++) {
    FvglFramebuffer* f = framebuffer_get(framebuffers[i]);
    if (!f) continue;
    if (fvgl.bound_framebuffer == framebuffers[i]) fvgl.bound_framebuffer = 0;
    free(f);
    fvgl_table_clear(&fvgl.framebuffers, framebuffers[i]);
  }
}

GL_APICALL GLboolean GL_APIENTRY glIsFramebuffer(GLuint framebuffer) { if (!fvgl.up) return GL_FALSE; return framebuffer_get(framebuffer) != NULL; }

GL_APICALL void GL_APIENTRY glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture,
                                                   GLint level) {
  if (!fvgl.up) return;
  if (target != GL_FRAMEBUFFER) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  FvglFramebuffer* f = framebuffer_get(fvgl.bound_framebuffer);
  if (!f) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  if (attachment != GL_COLOR_ATTACHMENT0) {
    // Depth and stencil attachments are valid GL; there is no surface for
    // them here, and the status query says so.
    if (attachment == GL_DEPTH_ATTACHMENT || attachment == GL_STENCIL_ATTACHMENT) return;
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  if (fvgl.scene_target && fvgl_current_target() == fvgl.scene_target) fvgl_scene_end();
  if (texture == 0) {
    f->color = 0;
    return;
  }
  if (textarget != GL_TEXTURE_2D || level != 0) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  FvglTexture* t = fvgl_table_get(&fvgl.textures, texture);
  if (!t) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  f->color = texture;
  // The render target is made now when the storage exists, or at the first
  // scene otherwise (Skia attaches before it uploads, sometimes).
  if (t->has_storage && !fvgl_texture_make_target(t)) fvgl_log("texture %u cannot be a render target", texture);
}

GL_APICALL GLenum GL_APIENTRY glCheckFramebufferStatus(GLenum target) {
  if (target != GL_FRAMEBUFFER) {
    fvgl_set_error(GL_INVALID_ENUM);
    return 0;
  }
  if (fvgl.bound_framebuffer == 0) return GL_FRAMEBUFFER_COMPLETE;
  FvglFramebuffer* f = framebuffer_get(fvgl.bound_framebuffer);
  if (!f || !f->color) return GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT;
  FvglTexture* t = fvgl_table_get(&fvgl.textures, f->color);
  if (!t || !t->has_storage) return GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT;
  if (!fvgl_texture_make_target(t)) return GL_FRAMEBUFFER_UNSUPPORTED;
  return GL_FRAMEBUFFER_COMPLETE;
}

GL_APICALL void GL_APIENTRY glGetFramebufferAttachmentParameteriv(GLenum target, GLenum attachment, GLenum pname,
                                                                  GLint* params) {
  if (target != GL_FRAMEBUFFER) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  FvglFramebuffer* f = framebuffer_get(fvgl.bound_framebuffer);
  if (!f || !params) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  const unsigned name = attachment == GL_COLOR_ATTACHMENT0 ? f->color : 0;
  switch (pname) {
    case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE: *params = name ? GL_TEXTURE : GL_NONE; break;
    case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME: *params = (GLint)name; break;
    case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL: *params = 0; break;
    case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE: *params = 0; break;
    default: fvgl_set_error(GL_INVALID_ENUM); break;
  }
}

// ---- lifetime --------------------------------------------------------------

void fvgl_framebuffers_forget_texture(unsigned texture) {
  for (unsigned i = 1; i <= fvgl.framebuffers.count; i++) {
    FvglFramebuffer* f = framebuffer_get(i);
    if (f && f->color == texture) f->color = 0;
  }
}

void fvgl_framebuffers_shutdown(void) {
  for (unsigned i = 1; i <= fvgl.framebuffers.count; i++) free(framebuffer_get(i));
  free(fvgl.framebuffers.items);
  memset(&fvgl.framebuffers, 0, sizeof fvgl.framebuffers);
  fvgl.bound_framebuffer = 0;
}
