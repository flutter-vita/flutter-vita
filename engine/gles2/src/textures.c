// Texture objects: GL_TEXTURE_2D storage in GPU memory, sampled by the
// fragment programs through the units glUniform1i named.
//
// Every texture is a LINEAR_STRIDED SceGxmTexture. The stride is ours, so
// glTexSubImage2D is a row copy, and an RGBA8 texture's rows are padded to
// the display's stride granule so any of them can become a render target
// without moving. LINEAR_STRIDED has no mipmaps and one filter for both
// directions, which is what Skia asks of a 2D renderer that never calls
// glGenerateMipmap here (`engine/gles2/surface.txt`).
//
// The GPU runs behind the CPU, so a write into a texture a queued draw still
// samples has to wait for that draw. glTexImage2D gets a fresh block instead
// (the old one goes to the garbage); glTexSubImage2D waits, and counts.
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

// GL formats not in the SDK's gl2.h.
#define FVGL_BGRA_EXT 0x80E1

static const unsigned kTargetStrideGranule = 64;  // pixels, what the display uses

static FvglTexture* texture_new(void) {
  FvglTexture* t = calloc(1, sizeof *t);
  t->uid = -1;
  t->min_filter = GL_NEAREST_MIPMAP_LINEAR;
  t->mag_filter = GL_LINEAR;
  t->wrap_s = t->wrap_t = GL_REPEAT;
  t->params_dirty = true;
  return t;
}

static FvglTexture* texture_get(GLuint name) { return fvgl_table_get(&fvgl.textures, name); }

// The texture bound to the active unit's GL_TEXTURE_2D, or NULL with the
// error set.
static FvglTexture* texture_bound(GLenum target, const char* who) {
  if (target != GL_TEXTURE_2D) {
    if (target == GL_TEXTURE_CUBE_MAP || (target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z)) {
      static bool said;
      if (!said) fvgl_log("%s: cube maps are not supported here", who);
      said = true;
      fvgl_set_error(GL_INVALID_OPERATION);
    } else {
      fvgl_set_error(GL_INVALID_ENUM);
    }
    return NULL;
  }
  FvglTexture* t = texture_get(fvgl.unit_2d[fvgl.active_unit]);
  if (!t) fvgl_set_error(GL_INVALID_OPERATION);
  return t;
}

// ---- formats ---------------------------------------------------------------

// Expands GL_RGB rows to RGBA8: the strided layout refuses 3-byte texels
// (sceGxmTextureInitLinearStrided answers 0x805B0009, measured 2026-09-12).
static void rgb_to_rgba(uint8_t* dst, const uint8_t* src, int texels) {
  for (int i = 0; i < texels; i++) {
    dst[0] = src[0];
    dst[1] = src[1];
    dst[2] = src[2];
    dst[3] = 255;
    dst += 4;
    src += 3;
  }
}

typedef struct Format {
  GLenum format, type;
  unsigned src_bpp;  // bytes per texel in client memory
  unsigned bpp;      // bytes per texel in storage
  SceGxmTextureFormat gxm;
  FvglTexelConvert convert;  // NULL when storage is the client layout
} Format;

// The swizzle names list the word's channels from its high end, as the
// colour formats do: U8U8U8U8_ABGR is the display's A8B8G8R8, R first in
// memory. So R000 is a texel whose alpha is the byte and whose colour is
// zero (GL_ALPHA), and 1RRR is one whose colour is the byte and whose alpha
// is one (GL_LUMINANCE). The M3 test reads all four channels back to check.
static const Format kFormats[] = {
    {GL_RGBA, GL_UNSIGNED_BYTE, 4, 4, SCE_GXM_TEXTURE_FORMAT_U8U8U8U8_ABGR, NULL},
    {FVGL_BGRA_EXT, GL_UNSIGNED_BYTE, 4, 4, SCE_GXM_TEXTURE_FORMAT_U8U8U8U8_ARGB, NULL},
    {GL_RGB, GL_UNSIGNED_BYTE, 3, 4, SCE_GXM_TEXTURE_FORMAT_U8U8U8U8_ABGR, rgb_to_rgba},
    {GL_RGB, GL_UNSIGNED_SHORT_5_6_5, 2, 2, SCE_GXM_TEXTURE_FORMAT_U5U6U5_RGB, NULL},
    {GL_RGBA, GL_UNSIGNED_SHORT_4_4_4_4, 2, 2, SCE_GXM_TEXTURE_FORMAT_U4U4U4U4_RGBA, NULL},
    {GL_RGBA, GL_UNSIGNED_SHORT_5_5_5_1, 2, 2, SCE_GXM_TEXTURE_FORMAT_U5U5U5U1_RGBA, NULL},
    {GL_ALPHA, GL_UNSIGNED_BYTE, 1, 1, SCE_GXM_TEXTURE_FORMAT_U8_R000, NULL},
    {GL_LUMINANCE, GL_UNSIGNED_BYTE, 1, 1, SCE_GXM_TEXTURE_FORMAT_U8_1RRR, NULL},
    {GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 2, 2, SCE_GXM_TEXTURE_FORMAT_U8U8_GRRR, NULL},
};

static const Format* format_find(GLenum format, GLenum type) {
  for (size_t i = 0; i < sizeof kFormats / sizeof kFormats[0]; i++) {
    if (kFormats[i].format == format && kFormats[i].type == type) return &kFormats[i];
  }
  return NULL;
}

static bool texture_is_rgba8(const FvglTexture* t) {
  return t->has_storage && t->gxm_format == SCE_GXM_TEXTURE_FORMAT_U8U8U8U8_ABGR;
}

// ---- sampler state ---------------------------------------------------------

static SceGxmTextureFilter filter_of(GLenum f) {
  switch (f) {
    case GL_NEAREST:
    case GL_NEAREST_MIPMAP_NEAREST:
    case GL_NEAREST_MIPMAP_LINEAR:
      return SCE_GXM_TEXTURE_FILTER_POINT;
    default:
      return SCE_GXM_TEXTURE_FILTER_LINEAR;
  }
}

static SceGxmTextureAddrMode wrap_of(GLenum w) {
  switch (w) {
    case GL_REPEAT: return SCE_GXM_TEXTURE_ADDR_REPEAT;
    case GL_MIRRORED_REPEAT: return SCE_GXM_TEXTURE_ADDR_MIRROR;
    default: return SCE_GXM_TEXTURE_ADDR_CLAMP;
  }
}

static void texture_apply_params(FvglTexture* t) {
  if (!t->has_storage || !t->params_dirty) return;
  // One filter for a strided texture, set through the "mag" setter; the bits
  // the min-filter setter writes hold part of the stride in this layout
  // (SceGxmTexture in the SDK header), so that one is never called. GL's
  // magnification filter is the one that matters for a 2D renderer drawing
  // at scale 1, and Skia sets both alike.
  sceGxmTextureSetMagFilter(&t->gxm, filter_of(t->mag_filter));
  sceGxmTextureSetUAddrMode(&t->gxm, wrap_of(t->wrap_s));
  sceGxmTextureSetVAddrMode(&t->gxm, wrap_of(t->wrap_t));
  t->params_dirty = false;
}

// ---- storage ---------------------------------------------------------------

static const size_t kFallbackBudget = 8u << 20;  // of main memory, for textures CDRAM refused
static size_t g_fallback_bytes;

static void texture_release_storage(FvglTexture* t) {
  if (fvgl.scene_target == t) fvgl_scene_end();
  if (t->target) fvgl_defer_destroy_target(t->target);
  t->target = NULL;
  if (t->in_fallback) {
    g_fallback_bytes -= t->bytes;
    t->in_fallback = false;
  }
  fvgl_defer_free(t->uid);
  t->uid = -1;
  t->data = NULL;
  t->bytes = 0;
  t->has_storage = false;
}

// Storage in one of two layouts. Linear, strided: what the CPU writes and
// the display scans out. Tiled, 32 by 32 texel tiles: what a render target
// gets, because the GPU samples a linear surface at full screen slowly enough
// that a page transition ran it past a vsync (docs/results/parity-2026-09-13.md);
// the CPU never reads or writes a tiled texture directly, it goes through a
// linear scratch texture and a blit.
static bool g_tiled_refused;  // the console said no to a tiled texture once; stay linear after

static bool texture_make_storage_layout(FvglTexture* t, const Format* f, int width, int height, bool tiled) {
  texture_release_storage(t);
  unsigned stride = (unsigned)width * f->bpp;
  unsigned rows = (unsigned)height;
  if (tiled) {
    stride = (((unsigned)width + 31u) & ~31u) * 4;
    rows = ((unsigned)height + 31u) & ~31u;
  } else if (f->bpp == 4) {
    // Any RGBA8 texture may be drawn into later: pad like the display.
    const unsigned px = ((unsigned)width + kTargetStrideGranule - 1) & ~(kTargetStrideGranule - 1);
    stride = px * 4;
  } else {
    stride = (stride + 15u) & ~15u;
  }
  const size_t bytes = (size_t)stride * (size_t)rows;
  // Small textures in main memory, where the granule is 4 KiB; big ones next
  // to the GPU.
  const FvglMemKind kind = bytes >= 256 * 1024 ? FVGL_MEM_CDRAM : FVGL_MEM_LPDDR_UNCACHED;
  t->data = fvgl_mem_alloc(kind, bytes, &t->uid);
  if (!t->data && kind == FVGL_MEM_CDRAM && g_fallback_bytes + bytes <= kFallbackBudget) {
    // CDRAM is full. The GPU reads main memory too, slower, and a texture
    // there beats GL_OUT_OF_MEMORY, which makes Skia drop the layer it was
    // for. Bounded, because main memory is the app's: unbounded, a leak of
    // 2 MiB render targets (the gallery's route scenes, 2026-09-12) took
    // 43 MiB of it and the Dart heap could no longer grow.
    t->data = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, bytes, &t->uid);
    if (t->data) {
      g_fallback_bytes += bytes;
      t->in_fallback = true;
      fvgl_note_lpddr_fallback();
    }
  }
  if (!t->data) {
    t->uid = -1;
    fvgl_set_error(GL_OUT_OF_MEMORY);
    return false;
  }
  const int r = tiled ? sceGxmTextureInitTiled(&t->gxm, t->data, f->gxm, (unsigned)width, (unsigned)height, 1)
                      : sceGxmTextureInitLinearStrided(&t->gxm, t->data, f->gxm, (unsigned)width, (unsigned)height,
                                                       stride);
  if (r < 0) {
    fvgl_log("sceGxmTextureInit%s %dx%d stride %u format 0x%08X: 0x%08X", tiled ? "Tiled" : "LinearStrided",
             width, height, stride, (unsigned)f->gxm, (unsigned)r);
    if (tiled) g_tiled_refused = true;
    fvgl_mem_free(t->uid);
    t->uid = -1;
    t->data = NULL;
    fvgl_set_error(GL_INVALID_OPERATION);
    return false;
  }
  t->bytes = bytes;
  t->width = width;
  t->height = height;
  t->format = f->format;
  t->type = f->type;
  t->bpp = f->bpp;
  t->src_bpp = f->src_bpp;
  t->convert = f->convert;
  t->stride = stride;
  t->gxm_format = f->gxm;
  t->tiled = tiled;
  t->has_storage = true;
  t->params_dirty = true;
  t->last_frame_used = 0;
  return true;
}

static bool texture_make_storage(FvglTexture* t, const Format* f, int width, int height) {
  return texture_make_storage_layout(t, f, width, height, false);
}

static const Format* format_rgba8(void) { return format_find(GL_RGBA, GL_UNSIGNED_BYTE); }

// A linear RGBA8 texture outside the object table, for staging.
FvglTexture* fvgl_texture_scratch_linear(int width, int height) {
  FvglTexture* t = texture_new();
  t->linear_only = true;
  if (!texture_make_storage_layout(t, format_rgba8(), width, height, false)) {
    free(t);
    return NULL;
  }
  return t;
}

void fvgl_texture_scratch_free(FvglTexture* t) {
  if (!t) return;
  texture_release_storage(t);
  free(t);
}

// The texture in the tiled layout, contents kept. Once tiled it stays so.
bool fvgl_texture_make_tiled(FvglTexture* t) {
  if (t->tiled) return true;
  if (!texture_is_rgba8(t) || t->linear_only || g_tiled_refused) return false;
  // The old storage is the source of a blit into the new one; it stays
  // mapped until the GPU is past this frame, which is after the blit.
  FvglTexture old = *t;
  t->uid = -1;
  t->data = NULL;
  t->target = NULL;
  t->has_storage = false;
  t->in_fallback = false;
  if (!texture_make_storage_layout(t, format_rgba8(), old.width, old.height, true)) {
    *t = old;
    if (g_tiled_refused) fvgl_log("tiled render targets refused here; staying linear");
    return false;
  }
  t->min_filter = old.min_filter;
  t->mag_filter = old.mag_filter;
  t->wrap_s = old.wrap_s;
  t->wrap_t = old.wrap_t;
  t->params_dirty = true;
  if (old.target) fvgl_defer_destroy_target(old.target);
  if (old.in_fallback) g_fallback_bytes -= old.bytes;
  if (!fvgl_blit(t, 0, 0, &old.gxm, old.width, old.height, false, 0, 0, old.width, old.height)) {
    fvgl_log("tiled conversion blit failed for %dx%d", old.width, old.height);
  }
  fvgl_defer_free(old.uid);
  return true;
}

// A linear copy of `t`, finished, for the CPU to read.
FvglTexture* fvgl_texture_linear_copy(FvglTexture* t) {
  FvglTexture* copy = fvgl_texture_scratch_linear(t->width, t->height);
  if (!copy) return NULL;
  if (!fvgl_blit(copy, 0, 0, &t->gxm, t->width, t->height, false, 0, 0, t->width, t->height)) {
    fvgl_texture_scratch_free(copy);
    return NULL;
  }
  fvgl_wait_for_frame(fvgl.frame);
  return copy;
}

static void texture_write_linear(FvglTexture* t, int x, int y, int w, int h, const void* pixels);

// Copies rows from client memory laid out with the unpack alignment. A tiled
// texture takes them through a linear staging texture and a blit, so the CPU
// never has to know the tile order, and never waits for the GPU either.
static void texture_write(FvglTexture* t, int x, int y, int w, int h, const void* pixels) {
  if (!t->tiled) {
    texture_write_linear(t, x, y, w, h, pixels);
    return;
  }
  FvglTexture* staging = fvgl_texture_scratch_linear(w, h);
  if (!staging) {
    fvgl_set_error(GL_OUT_OF_MEMORY);
    return;
  }
  texture_write_linear(staging, 0, 0, w, h, pixels);
  if (!fvgl_blit(t, x, y, &staging->gxm, w, h, false, 0, 0, w, h)) fvgl_set_error(GL_OUT_OF_MEMORY);
  fvgl_texture_scratch_free(staging);
}

static void texture_write_linear(FvglTexture* t, int x, int y, int w, int h, const void* pixels) {
  const size_t tight = (size_t)w * t->src_bpp;
  const size_t align = (size_t)fvgl.unpack_alignment;
  const size_t src_stride = (tight + align - 1) & ~(align - 1);
  const uint8_t* src = pixels;
  uint8_t* dst = t->data + (size_t)y * t->stride + (size_t)x * t->bpp;
  for (int row = 0; row < h; row++) {
    if (t->convert) t->convert(dst, src, w);
    else memcpy(dst, src, tight);
    src += src_stride;
    dst += t->stride;
  }
}

// A write is about to land in storage a queued draw may still read.
static void texture_wait_idle(FvglTexture* t) {
  if (t->last_frame_used == 0) return;
  fvgl_wait_for_frame(t->last_frame_used);
}

// ---- GL: objects -----------------------------------------------------------

GL_APICALL void GL_APIENTRY glGenTextures(GLsizei n, GLuint* textures) {
  if (!fvgl.up) return;
  if (n < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  for (GLsizei i = 0; i < n; i++) textures[i] = fvgl_table_add(&fvgl.textures, texture_new());
}

GL_APICALL void GL_APIENTRY glActiveTexture(GLenum texture) {
  if (texture < GL_TEXTURE0 || texture >= GL_TEXTURE0 + FVGL_MAX_TEXTURE_UNITS) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  fvgl.active_unit = (int)(texture - GL_TEXTURE0);
}

GL_APICALL void GL_APIENTRY glBindTexture(GLenum target, GLuint texture) {
  if (!fvgl.up) return;
  if (target != GL_TEXTURE_2D && target != GL_TEXTURE_CUBE_MAP) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  if (texture != 0 && !texture_get(texture)) {
    // A name never handed out by glGenTextures still works in GL: make it.
    while (fvgl.textures.count < texture) fvgl_table_add(&fvgl.textures, texture_new());
  }
  if (target == GL_TEXTURE_2D) fvgl.unit_2d[fvgl.active_unit] = texture;
  else fvgl.unit_cube[fvgl.active_unit] = texture;
}

GL_APICALL void GL_APIENTRY glDeleteTextures(GLsizei n, const GLuint* textures) {
  if (!fvgl.up) return;
  if (n < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  for (GLsizei i = 0; i < n; i++) {
    FvglTexture* t = texture_get(textures[i]);
    if (!t) continue;
    texture_release_storage(t);
    fvgl_framebuffers_forget_texture(textures[i]);
    for (int u = 0; u < FVGL_MAX_TEXTURE_UNITS; u++) {
      if (fvgl.unit_2d[u] == textures[i]) fvgl.unit_2d[u] = 0;
      if (fvgl.unit_cube[u] == textures[i]) fvgl.unit_cube[u] = 0;
    }
    free(t);
    fvgl_table_clear(&fvgl.textures, textures[i]);
  }
}

GL_APICALL GLboolean GL_APIENTRY glIsTexture(GLuint texture) { if (!fvgl.up) return GL_FALSE; return texture_get(texture) != NULL; }

// ---- GL: images ------------------------------------------------------------

GL_APICALL void GL_APIENTRY glPixelStorei(GLenum pname, GLint param) {
  if (param != 1 && param != 2 && param != 4 && param != 8) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (pname == GL_UNPACK_ALIGNMENT) fvgl.unpack_alignment = param;
  else if (pname == GL_PACK_ALIGNMENT) fvgl.pack_alignment = param;
  else fvgl_set_error(GL_INVALID_ENUM);
}

GL_APICALL void GL_APIENTRY glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width,
                                         GLsizei height, GLint border, GLenum format, GLenum type,
                                         const void* pixels) {
  if (!fvgl.up) return;
  FvglTexture* t = texture_bound(target, "glTexImage2D");
  if (!t) return;
  if (width < 0 || height < 0 || width > 4096 || height > 4096 || border != 0 || level < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if ((GLenum)internalformat != format) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  const Format* f = format_find(format, type);
  if (!f) {
    fvgl_log("glTexImage2D format 0x%04X type 0x%04X: not supported", format, type);
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  if (level > 0) {
    // No mipmaps in a strided layout. The base level is what gets sampled.
    static unsigned said;
    if (said++ == 0) fvgl_log("glTexImage2D level %d ignored: no mipmaps here", level);
    return;
  }
  if (width == 0 || height == 0) {
    texture_release_storage(t);
    return;
  }
  if (!texture_make_storage(t, f, width, height)) return;
  if (pixels) texture_write(t, 0, 0, width, height, pixels);
  else memset(t->data, 0, t->bytes);
}

GL_APICALL void GL_APIENTRY glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset,
                                            GLsizei width, GLsizei height, GLenum format, GLenum type,
                                            const void* pixels) {
  if (!fvgl.up) return;
  FvglTexture* t = texture_bound(target, "glTexSubImage2D");
  if (!t) return;
  if (level > 0) return;  // as glTexImage2D
  if (!t->has_storage) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  if (xoffset < 0 || yoffset < 0 || width < 0 || height < 0 || xoffset + width > t->width ||
      yoffset + height > t->height) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (format != t->format || type != t->type) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  if (!pixels || width == 0 || height == 0) return;
  if (!t->tiled) texture_wait_idle(t);
  texture_write(t, xoffset, yoffset, width, height, pixels);
}

// GLES 2.0 defines the two compressed calls and no compressed format; a
// format arrives only through an extension. This layer advertises none
// (GL_NUM_COMPRESSED_TEXTURE_FORMATS reads 0 and GL_COMPRESSED_TEXTURE_FORMATS
// is empty), so every internalformat is an unknown one and GL_INVALID_ENUM is
// the answer the spec asks for.
//
// The GPU has PVRTC, UBC and ETC1 in hardware. Adding one means advertising
// its extension, a base format in texture_storage, and a size rule per block
// in place of the bytes-per-texel this file counts with. Nothing asks: Skia
// reaches a compressed format only through the caps it reads here, and
// Flutter hands it raster images it decoded itself.
GL_APICALL void GL_APIENTRY glCompressedTexImage2D(GLenum target, GLint level, GLenum internalformat, GLsizei width,
                                                   GLsizei height, GLint border, GLsizei imageSize,
                                                   const void* data) {
  (void)target;
  (void)internalformat;
  (void)data;
  if (level < 0 || width < 0 || height < 0 || border != 0 || imageSize < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  fvgl_set_error(GL_INVALID_ENUM);
}

GL_APICALL void GL_APIENTRY glCompressedTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset,
                                                      GLsizei width, GLsizei height, GLenum format,
                                                      GLsizei imageSize, const void* data) {
  (void)target;
  (void)format;
  (void)data;
  if (level < 0 || xoffset < 0 || yoffset < 0 || width < 0 || height < 0 || imageSize < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  // No texture here has compressed storage, so there is nothing to write into.
  fvgl_set_error(GL_INVALID_OPERATION);
}

GL_APICALL void GL_APIENTRY glCopyTexImage2D(GLenum target, GLint level, GLenum internalformat, GLint x, GLint y,
                                             GLsizei width, GLsizei height, GLint border) {
  if (!fvgl.up) return;
  FvglTexture* t = texture_bound(target, "glCopyTexImage2D");
  if (!t) return;
  if (level > 0) return;
  if (internalformat != GL_RGBA || border != 0) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  if (width < 0 || height < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (!texture_make_storage(t, format_find(GL_RGBA, GL_UNSIGNED_BYTE), width, height)) return;
  glCopyTexSubImage2D(target, 0, 0, 0, x, y, width, height);
}

GL_APICALL void GL_APIENTRY glCopyTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x,
                                                GLint y, GLsizei width, GLsizei height) {
  if (!fvgl.up) return;
  FvglTexture* t = texture_bound(target, "glCopyTexSubImage2D");
  if (!t) return;
  if (level > 0) return;
  if (!texture_is_rgba8(t)) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  if (xoffset < 0 || yoffset < 0 || width < 0 || height < 0 || xoffset + width > t->width ||
      yoffset + height > t->height) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  FvglTexture* from = fvgl_current_target();
  if (from == t) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  if (width == 0 || height == 0) return;
  if (fvgl_blit_from_target(t, xoffset, yoffset, x, y, width, height)) return;
  // The CPU path, for a destination that cannot be a render target.
  int fw, fh;
  bool flipped;
  fvgl_target_extent(&fw, &fh, &flipped);
  if ((from && from->tiled) || t->tiled) {
    fvgl_set_error(GL_OUT_OF_MEMORY);
    return;
  }
  const uint8_t* src;
  unsigned src_stride;
  if (from) {
    src = from->data;
    src_stride = from->stride;
  } else {
    src = fvgl.display[fvgl.back].data;
    src_stride = (unsigned)fvgl.display_stride * 4;
  }
  // The source has to be in memory: everything queued lands first. That is a
  // stall, and Skia does this for backdrop effects; it is counted with the
  // texture writes into in-flight storage.
  fvgl_wait_for_frame(fvgl.frame);
  for (GLsizei row = 0; row < height; row++) {
    const int gy = y + row;
    const int sy = flipped ? fh - 1 - gy : gy;
    uint8_t* dst = t->data + (size_t)(yoffset + row) * t->stride + (size_t)xoffset * 4;
    if (sy < 0 || sy >= fh) {
      memset(dst, 0, (size_t)width * 4);
      continue;
    }
    for (GLsizei col = 0; col < width; col++) {
      const int gx = x + col;
      if (gx < 0 || gx >= fw) memset(dst + col * 4, 0, 4);
      else memcpy(dst + col * 4, src + (size_t)sy * src_stride + (size_t)gx * 4, 4);
    }
  }
}

// ---- GL: parameters --------------------------------------------------------

static void texture_param(GLenum target, GLenum pname, GLint value) {
  FvglTexture* t = texture_bound(target, "glTexParameter");
  if (!t) return;
  switch (pname) {
    case GL_TEXTURE_MIN_FILTER:
      if (value != GL_NEAREST && value != GL_LINEAR && value != GL_NEAREST_MIPMAP_NEAREST &&
          value != GL_LINEAR_MIPMAP_NEAREST && value != GL_NEAREST_MIPMAP_LINEAR && value != GL_LINEAR_MIPMAP_LINEAR) {
        fvgl_set_error(GL_INVALID_ENUM);
        return;
      }
      t->min_filter = (GLenum)value;
      break;
    case GL_TEXTURE_MAG_FILTER:
      if (value != GL_NEAREST && value != GL_LINEAR) {
        fvgl_set_error(GL_INVALID_ENUM);
        return;
      }
      t->mag_filter = (GLenum)value;
      break;
    case GL_TEXTURE_WRAP_S:
    case GL_TEXTURE_WRAP_T:
      if (value != GL_REPEAT && value != GL_MIRRORED_REPEAT && value != GL_CLAMP_TO_EDGE) {
        fvgl_set_error(GL_INVALID_ENUM);
        return;
      }
      if (pname == GL_TEXTURE_WRAP_S) t->wrap_s = (GLenum)value;
      else t->wrap_t = (GLenum)value;
      break;
    default:
      fvgl_set_error(GL_INVALID_ENUM);
      return;
  }
  t->params_dirty = true;
}

GL_APICALL void GL_APIENTRY glTexParameteri(GLenum target, GLenum pname, GLint param) { texture_param(target, pname, param); }
GL_APICALL void GL_APIENTRY glTexParameterf(GLenum target, GLenum pname, GLfloat param) { texture_param(target, pname, (GLint)param); }
GL_APICALL void GL_APIENTRY glTexParameteriv(GLenum target, GLenum pname, const GLint* params) { texture_param(target, pname, params[0]); }
GL_APICALL void GL_APIENTRY glTexParameterfv(GLenum target, GLenum pname, const GLfloat* params) { texture_param(target, pname, (GLint)params[0]); }

GL_APICALL void GL_APIENTRY glGetTexParameteriv(GLenum target, GLenum pname, GLint* params) {
  FvglTexture* t = texture_bound(target, "glGetTexParameteriv");
  if (!t || !params) return;
  switch (pname) {
    case GL_TEXTURE_MIN_FILTER: *params = (GLint)t->min_filter; break;
    case GL_TEXTURE_MAG_FILTER: *params = (GLint)t->mag_filter; break;
    case GL_TEXTURE_WRAP_S: *params = (GLint)t->wrap_s; break;
    case GL_TEXTURE_WRAP_T: *params = (GLint)t->wrap_t; break;
    default: fvgl_set_error(GL_INVALID_ENUM); break;
  }
}

GL_APICALL void GL_APIENTRY glGetTexParameterfv(GLenum target, GLenum pname, GLfloat* params) {
  GLint v = 0;
  glGetTexParameteriv(target, pname, &v);
  if (params) *params = (GLfloat)v;
}

// ---- draw-time binding -----------------------------------------------------

void fvgl_bind_samplers(FvglProgram* p) {
  for (int i = 0; i < p->uniform_count; i++) {
    const FvglUniform* u = &p->uniforms[i];
    if (!u->is_sampler || !u->fp) continue;
    FvglTexture* t = NULL;
    if (u->unit >= 0 && u->unit < FVGL_MAX_TEXTURE_UNITS) t = texture_get(fvgl.unit_2d[u->unit]);
    // Incomplete, or being drawn into right now: GL says the sample is
    // undefined and this GPU says a fault, so it reads the fallback.
    if (!t || !t->has_storage || t == fvgl.scene_target) t = &fvgl.fallback;
    texture_apply_params(t);
    t->last_frame_used = fvgl.frame;
    const int r = sceGxmSetFragmentTexture(fvgl.gxm, sceGxmProgramParameterGetResourceIndex(u->fp), &t->gxm);
    if (r < 0) fvgl_log("sceGxmSetFragmentTexture unit %d: 0x%08X", u->unit, (unsigned)r);
  }
}

// ---- lifetime --------------------------------------------------------------

int fvgl_textures_init(void) {
  fvgl.active_unit = 0;
  fvgl.unpack_alignment = fvgl.pack_alignment = 4;
  FvglTexture* f = &fvgl.fallback;
  memset(f, 0, sizeof *f);
  f->uid = -1;
  f->min_filter = f->mag_filter = GL_NEAREST;
  f->wrap_s = f->wrap_t = GL_CLAMP_TO_EDGE;
  if (!texture_make_storage(f, format_find(GL_RGBA, GL_UNSIGNED_BYTE), 1, 1)) return -1;
  memset(f->data, 0xFF, 4);
  return 0;
}

void fvgl_texture_stats(FvglStats* out) {
  out->textures_live = out->textures_bytes = out->targets_live = 0;
  for (unsigned i = 0; i < fvgl.textures.count; i++) {
    const FvglTexture* t = fvgl.textures.items[i];
    if (!t || !t->has_storage) continue;
    out->textures_live++;
    out->textures_bytes += (unsigned)t->bytes;
    if (t->target) out->targets_live++;
  }
}

void fvgl_textures_shutdown(void) {
  for (unsigned i = 1; i <= fvgl.textures.count; i++) {
    FvglTexture* t = texture_get(i);
    if (!t) continue;
    if (t->target) sceGxmDestroyRenderTarget(t->target);
    fvgl_mem_free(t->uid);
    free(t);
  }
  free(fvgl.textures.items);
  memset(&fvgl.textures, 0, sizeof fvgl.textures);
  fvgl_mem_free(fvgl.fallback.uid);
  fvgl.fallback.uid = -1;
  memset(fvgl.unit_2d, 0, sizeof fvgl.unit_2d);
  memset(fvgl.unit_cube, 0, sizeof fvgl.unit_cube);
}
