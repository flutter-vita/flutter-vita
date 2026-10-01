// Framebuffer objects: a texture drawn into instead of the display.
//
// A framebuffer here holds a colour attachment, which is a texture, and a
// depth and a stencil attachment, which are renderbuffers (renderbuffers.c).
// The colour attachment may name a renderbuffer instead; that combination is
// legal GL and this layer cannot draw it, so the status says UNSUPPORTED.
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

bool fvgl_scene_has_depth(void) { return fvgl.scene_open && fvgl.scene_ds != NULL; }

bool fvgl_scene_uses_renderbuffer(const FvglRenderbuffer* rb) {
  return fvgl.scene_open && rb->has_storage && fvgl.scene_ds == &rb->surface;
}

static FvglRenderbuffer* renderbuffer_of(unsigned name) { return fvgl_table_get(&fvgl.renderbuffers, name); }

// The surface the current target draws through. A framebuffer object takes
// it from whichever of its two attachments has one -- the packed format
// carries both, so a depth-only attachment brings a stencil along and the
// bit counts below, not the surface, are what says which of them GL has.
//
// The display's surface is made on demand. Nothing allocates it until an app
// enables the depth or the stencil test or clears one of them, so a Flutter
// app never pays the two megabytes.
const SceGxmDepthStencilSurface* fvgl_target_depth_stencil(void) {
  FvglFramebuffer* f = framebuffer_get(fvgl.bound_framebuffer);
  if (f) {
    FvglRenderbuffer* rb = renderbuffer_of(f->depth);
    if (!rb || !rb->has_storage) rb = renderbuffer_of(f->stencil);
    if (!rb || !rb->has_storage) return NULL;
    // glCheckFramebufferStatus calls this combination incomplete, and a
    // program is free to draw without asking. A surface smaller than the
    // colour attachment would have the GPU write outside it, so it is
    // refused here as well and the draw goes without depth.
    const FvglTexture* t = fvgl_current_target();
    if (t && (rb->width < t->width || rb->height < t->height)) return NULL;
    return &rb->surface;
  }
  if (!fvgl.display_depth_wanted) return NULL;
  if (!fvgl.display_depth.has_storage && !fvgl_depth_stencil_make(&fvgl.display_depth, fvgl.width, fvgl.height)) {
    fvgl.display_depth_wanted = false;  // asked once, refused; do not ask every frame
    return NULL;
  }
  return &fvgl.display_depth.surface;
}

void fvgl_target_depth_stencil_bits(int* depth, int* stencil) {
  FvglFramebuffer* f = framebuffer_get(fvgl.bound_framebuffer);
  if (!f) {
    // The default framebuffer's format, whether or not the memory is taken yet.
    *depth = 24;
    *stencil = 8;
    return;
  }
  const FvglRenderbuffer* d = renderbuffer_of(f->depth);
  const FvglRenderbuffer* s = renderbuffer_of(f->stencil);
  *depth = d && d->has_storage ? (int)d->depth_bits : 0;
  *stencil = s && s->has_storage ? (int)s->stencil_bits : 0;
  // The surface is packed, so an attachment of either kind brings both. GL
  // reports what the attachment asked for, which is what a program can use.
}

// An app is about to read or write depth or stencil on the display. The
// surface appears at the next scene; a scene already open was begun without
// one, so it has to end for the state to take effect.
void fvgl_want_display_depth(void) {
  if (fvgl.display_depth_wanted) return;
  fvgl.display_depth_wanted = true;
  // A scene already open on the display was begun without a surface. The flag
  // is set whatever is bound, because an app that enables the depth test
  // inside a framebuffer object still has it enabled when it binds the
  // display again.
  if (fvgl.scene_open && !fvgl.scene_target && !fvgl.scene_ds) fvgl_scene_end();
}

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
    // A texture as the depth or the stencil attachment needs
    // GL_OES_depth_texture, which is not advertised, so no legal program
    // arrives here with one.
    if (attachment == GL_DEPTH_ATTACHMENT || attachment == GL_STENCIL_ATTACHMENT) {
      fvgl_set_error(GL_INVALID_OPERATION);
      return;
    }
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  if (fvgl.scene_target && fvgl_current_target() == fvgl.scene_target) fvgl_scene_end();
  f->color_renderbuffer = 0;
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

GL_APICALL void GL_APIENTRY glFramebufferRenderbuffer(GLenum target, GLenum attachment,
                                                      GLenum renderbuffertarget, GLuint renderbuffer) {
  if (!fvgl.up) return;
  if (target != GL_FRAMEBUFFER || renderbuffertarget != GL_RENDERBUFFER) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  FvglFramebuffer* f = framebuffer_get(fvgl.bound_framebuffer);
  if (!f) {
    fvgl_set_error(GL_INVALID_OPERATION);  // nothing can attach to the display
    return;
  }
  if (renderbuffer != 0 && !renderbuffer_of(renderbuffer)) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  // The open scene, if it is this framebuffer's, was begun with the old
  // attachments.
  if (fvgl.scene_open && fvgl_current_target() == fvgl.scene_target) fvgl_scene_end();
  switch (attachment) {
    case GL_DEPTH_ATTACHMENT: f->depth = renderbuffer; break;
    case GL_STENCIL_ATTACHMENT: f->stencil = renderbuffer; break;
    case GL_COLOR_ATTACHMENT0:
      f->color_renderbuffer = renderbuffer;
      if (renderbuffer) f->color = 0;
      break;
    default:
      fvgl_set_error(GL_INVALID_ENUM);
      return;
  }
}

GL_APICALL GLenum GL_APIENTRY glCheckFramebufferStatus(GLenum target) {
  if (target != GL_FRAMEBUFFER) {
    fvgl_set_error(GL_INVALID_ENUM);
    return 0;
  }
  if (fvgl.bound_framebuffer == 0) return GL_FRAMEBUFFER_COMPLETE;
  FvglFramebuffer* f = framebuffer_get(fvgl.bound_framebuffer);
  if (!f) return GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT;
  // Nothing here can draw into a renderbuffer's colour; see renderbuffers.c.
  if (f->color_renderbuffer) return GL_FRAMEBUFFER_UNSUPPORTED;
  if (!f->color) return GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT;
  FvglTexture* t = fvgl_table_get(&fvgl.textures, f->color);
  if (!t || !t->has_storage) return GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT;
  if (!fvgl_texture_make_target(t)) return GL_FRAMEBUFFER_UNSUPPORTED;
  // Every attachment has to cover the same rectangle. The surface is made in
  // whole tiles and may be larger than the colour, which GL allows; what it
  // may not be is smaller.
  const unsigned rbs[2] = {f->depth, f->stencil};
  for (int i = 0; i < 2; i++) {
    if (!rbs[i]) continue;
    const FvglRenderbuffer* rb = renderbuffer_of(rbs[i]);
    if (!rb || !rb->has_storage) return GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT;
    if (rb->width < t->width || rb->height < t->height) return GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS;
  }
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
  unsigned name = 0;
  GLenum kind = GL_NONE;
  switch (attachment) {
    case GL_COLOR_ATTACHMENT0:
      name = f->color ? f->color : f->color_renderbuffer;
      kind = f->color ? GL_TEXTURE : f->color_renderbuffer ? GL_RENDERBUFFER : GL_NONE;
      break;
    case GL_DEPTH_ATTACHMENT:
      name = f->depth;
      kind = name ? GL_RENDERBUFFER : GL_NONE;
      break;
    case GL_STENCIL_ATTACHMENT:
      name = f->stencil;
      kind = name ? GL_RENDERBUFFER : GL_NONE;
      break;
    default:
      fvgl_set_error(GL_INVALID_ENUM);
      return;
  }
  switch (pname) {
    case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE: *params = (GLint)kind; break;
    case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME: *params = (GLint)name; break;
    case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL:
    case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE:
      // Only a texture attachment has these, and this layer attaches level 0
      // of a GL_TEXTURE_2D and nothing else.
      if (kind != GL_TEXTURE) {
        fvgl_set_error(GL_INVALID_ENUM);
        return;
      }
      *params = 0;
      break;
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

void fvgl_framebuffers_forget_renderbuffer(unsigned renderbuffer) {
  for (unsigned i = 1; i <= fvgl.framebuffers.count; i++) {
    FvglFramebuffer* f = framebuffer_get(i);
    if (!f) continue;
    if (f->depth == renderbuffer) f->depth = 0;
    if (f->stencil == renderbuffer) f->stencil = 0;
    if (f->color_renderbuffer == renderbuffer) f->color_renderbuffer = 0;
  }
}

void fvgl_framebuffers_shutdown(void) {
  for (unsigned i = 1; i <= fvgl.framebuffers.count; i++) free(framebuffer_get(i));
  free(fvgl.framebuffers.items);
  memset(&fvgl.framebuffers, 0, sizeof fvgl.framebuffers);
  fvgl.bound_framebuffer = 0;
}
