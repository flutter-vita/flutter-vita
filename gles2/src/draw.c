// Vertex input and the draw calls: GL attribute arrays become sceGxm vertex
// streams, and a program becomes a patched vertex program per stream layout
// and a patched fragment program per blend state.
//
// sceGxm binds the vertex layout into the vertex program at creation and the
// blend state into the fragment program, so both are cached per GL program,
// keyed by what went into them. Skia uses a few layouts and a few blend
// modes per program, and the caches stay small.
//
// Every draw is indexed on this GPU. glDrawArrays draws through an identity
// index buffer with the streams rebased to `first`.
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

// ---- identity indices ------------------------------------------------------

static SceUID g_ident16_uid = -1, g_ident32_uid = -1;
static uint16_t* g_ident16;
static uint32_t* g_ident32;
static unsigned g_ident16_count, g_ident32_count;

static const void* identity_indices(unsigned count, SceGxmIndexFormat* format) {
  if (count <= 65536) {
    *format = SCE_GXM_INDEX_FORMAT_U16;
    if (count > g_ident16_count) {
      unsigned n = g_ident16_count ? g_ident16_count : 4096;
      while (n < count) n *= 2;
      if (n > 65536) n = 65536;
      fvgl_defer_free(g_ident16_uid);
      g_ident16 = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, n * sizeof(uint16_t), &g_ident16_uid);
      if (!g_ident16) return NULL;
      for (unsigned i = 0; i < n; i++) g_ident16[i] = (uint16_t)i;
      g_ident16_count = n;
    }
    return g_ident16;
  }
  *format = SCE_GXM_INDEX_FORMAT_U32;
  if (count > g_ident32_count) {
    unsigned n = g_ident32_count ? g_ident32_count : 65536;
    while (n < count) n *= 2;
    fvgl_defer_free(g_ident32_uid);
    g_ident32 = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, n * sizeof(uint32_t), &g_ident32_uid);
    if (!g_ident32) return NULL;
    for (unsigned i = 0; i < n; i++) g_ident32[i] = i;
    g_ident32_count = n;
  }
  return g_ident32;
}

void fvgl_draw_init(void) {
  for (int i = 0; i < FVGL_MAX_ATTRIBUTES; i++) {
    FvglVertexAttribState* a = &fvgl.attribs[i];
    memset(a, 0, sizeof *a);
    a->size = 4;
    a->type = GL_FLOAT;
    a->constant[3] = 1.0f;
  }
}

void fvgl_draw_shutdown(void) {
  fvgl_mem_free(g_ident16_uid);
  fvgl_mem_free(g_ident32_uid);
  g_ident16_uid = g_ident32_uid = -1;
  g_ident16 = NULL;
  g_ident32 = NULL;
  g_ident16_count = g_ident32_count = 0;
}

// ---- attribute state -------------------------------------------------------

static bool attrib_type_ok(GLenum type, GLint size, GLboolean normalized, uint8_t* format, unsigned* elem) {
  switch (type) {
    case GL_FLOAT: *format = SCE_GXM_ATTRIBUTE_FORMAT_F32; *elem = 4; break;
    case 0x8D61 /* GL_HALF_FLOAT_OES */: *format = SCE_GXM_ATTRIBUTE_FORMAT_F16; *elem = 2; break;
    case GL_UNSIGNED_BYTE: *format = normalized ? SCE_GXM_ATTRIBUTE_FORMAT_U8N : SCE_GXM_ATTRIBUTE_FORMAT_U8; *elem = 1; break;
    case GL_BYTE: *format = normalized ? SCE_GXM_ATTRIBUTE_FORMAT_S8N : SCE_GXM_ATTRIBUTE_FORMAT_S8; *elem = 1; break;
    case GL_UNSIGNED_SHORT: *format = normalized ? SCE_GXM_ATTRIBUTE_FORMAT_U16N : SCE_GXM_ATTRIBUTE_FORMAT_U16; *elem = 2; break;
    case GL_SHORT: *format = normalized ? SCE_GXM_ATTRIBUTE_FORMAT_S16N : SCE_GXM_ATTRIBUTE_FORMAT_S16; *elem = 2; break;
    default: return false;
  }
  return size >= 1 && size <= 4;
}

GL_APICALL void GL_APIENTRY glVertexAttribPointer(GLuint index, GLint size, GLenum type, GLboolean normalized,
                                                  GLsizei stride, const void* pointer) {
  if (index >= FVGL_MAX_ATTRIBUTES) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  uint8_t format;
  unsigned elem;
  if (!attrib_type_ok(type, size, normalized, &format, &elem)) {
    fvgl_set_error(type == GL_FIXED ? GL_INVALID_OPERATION : GL_INVALID_ENUM);
    fvgl_log("glVertexAttribPointer type 0x%04X size %d: not supported", type, size);
    return;
  }
  if (stride < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  FvglVertexAttribState* a = &fvgl.attribs[index];
  a->size = size;
  a->type = type;
  a->normalized = normalized;
  a->stride = stride;
  a->pointer = pointer;
  a->buffer = fvgl.array_buffer;
}

GL_APICALL void GL_APIENTRY glEnableVertexAttribArray(GLuint index) {
  if (index >= FVGL_MAX_ATTRIBUTES) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  fvgl.attribs[index].enabled = true;
}

GL_APICALL void GL_APIENTRY glDisableVertexAttribArray(GLuint index) {
  if (index >= FVGL_MAX_ATTRIBUTES) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  fvgl.attribs[index].enabled = false;
}

static void attrib_constant(GLuint index, float x, float y, float z, float w) {
  if (index >= FVGL_MAX_ATTRIBUTES) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  float* c = fvgl.attribs[index].constant;
  c[0] = x; c[1] = y; c[2] = z; c[3] = w;
}

GL_APICALL void GL_APIENTRY glVertexAttrib1f(GLuint index, GLfloat x) { attrib_constant(index, x, 0, 0, 1); }
GL_APICALL void GL_APIENTRY glVertexAttrib2f(GLuint index, GLfloat x, GLfloat y) { attrib_constant(index, x, y, 0, 1); }
GL_APICALL void GL_APIENTRY glVertexAttrib3f(GLuint index, GLfloat x, GLfloat y, GLfloat z) { attrib_constant(index, x, y, z, 1); }
GL_APICALL void GL_APIENTRY glVertexAttrib4f(GLuint index, GLfloat x, GLfloat y, GLfloat z, GLfloat w) { attrib_constant(index, x, y, z, w); }
GL_APICALL void GL_APIENTRY glVertexAttrib1fv(GLuint index, const GLfloat* v) { attrib_constant(index, v[0], 0, 0, 1); }
GL_APICALL void GL_APIENTRY glVertexAttrib2fv(GLuint index, const GLfloat* v) { attrib_constant(index, v[0], v[1], 0, 1); }
GL_APICALL void GL_APIENTRY glVertexAttrib3fv(GLuint index, const GLfloat* v) { attrib_constant(index, v[0], v[1], v[2], 1); }
GL_APICALL void GL_APIENTRY glVertexAttrib4fv(GLuint index, const GLfloat* v) { attrib_constant(index, v[0], v[1], v[2], v[3]); }

// ---- layout ----------------------------------------------------------------

typedef struct Stream {
  const uint8_t* base;  // where the stream's element 0 is, after `first`
  uint16_t stride;
  uint16_t source;
} Stream;

typedef struct Layout {
  SceGxmVertexAttribute attributes[FVGL_MAX_ATTRIBUTES];
  int attribute_count;
  Stream streams[FVGL_MAX_ATTRIBUTES];
  int stream_count;
  uint8_t key[64];
  int key_len;
} Layout;

// vertex_count is how many vertices client-side arrays have to be copied for.
static bool build_layout(FvglProgram* p, GLint first, unsigned vertex_count, Layout* L) {
  memset(L, 0, sizeof *L);
  struct {
    const uint8_t* group_base;  // buffer start, or scratch copy
    uint16_t stride;
    uint16_t source;
    size_t offset;  // within the group base
    uint8_t format, comps;
    uint16_t reg;
  } in[FVGL_MAX_ATTRIBUTES];
  int n = 0;
  for (int i = 0; i < p->attribute_count; i++) {
    const FvglAttribute* pa = &p->attributes[i];
    if (!pa->param) continue;
    const FvglVertexAttribState* st = &fvgl.attribs[pa->location];
    in[n].reg = (uint16_t)sceGxmProgramParameterGetResourceIndex(pa->param);
    if (st->enabled) {
      uint8_t format = SCE_GXM_ATTRIBUTE_FORMAT_F32;
      unsigned elem = 4;
      attrib_type_ok(st->type, st->size, st->normalized, &format, &elem);
      const unsigned stride = st->stride ? (unsigned)st->stride : elem * (unsigned)st->size;
      in[n].format = format;
      in[n].comps = (uint8_t)st->size;
      in[n].stride = (uint16_t)stride;
      in[n].source = SCE_GXM_INDEX_SOURCE_INDEX_16BIT;
      if (st->buffer) {
        FvglBuffer* b = fvgl_table_get(&fvgl.buffers, st->buffer);
        if (!b || !b->data) {
          fvgl_log("draw: attribute %d points into a buffer with no data", pa->location);
          return false;
        }
        b->last_frame_used = fvgl.frame;
        in[n].group_base = b->data;
        in[n].offset = (size_t)(uintptr_t)st->pointer;
      } else {
        // A client-side array: copy the vertices this draw reads.
        if (!st->pointer) {
          fvgl_log("draw: attribute %d has no pointer", pa->location);
          return false;
        }
        const size_t bytes = (size_t)stride * (size_t)(first + (GLint)vertex_count);
        uint8_t* copy = fvgl_scratch_alloc(bytes, 16);
        if (!copy) return false;
        memcpy(copy, st->pointer, bytes);
        in[n].group_base = copy;
        in[n].offset = 0;
      }
    } else {
      float* c = fvgl_scratch_alloc(16, 16);
      if (!c) return false;
      memcpy(c, st->constant, 16);
      in[n].format = SCE_GXM_ATTRIBUTE_FORMAT_F32;
      in[n].comps = 4;
      in[n].stride = 16;
      in[n].source = SCE_GXM_INDEX_SOURCE_INSTANCE_16BIT;
      in[n].group_base = (const uint8_t*)c;
      in[n].offset = 0;
    }
    n++;
  }

  // Streams: one per (base, stride, source); attributes in a stream are
  // offsets from the smallest offset in it.
  size_t stream_min[FVGL_MAX_ATTRIBUTES];
  int stream_of[FVGL_MAX_ATTRIBUTES];
  for (int i = 0; i < n; i++) {
    int s = -1;
    for (int j = 0; j < L->stream_count; j++) {
      if (L->streams[j].base == in[i].group_base && L->streams[j].stride == in[i].stride &&
          L->streams[j].source == in[i].source) {
        s = j;
        break;
      }
    }
    if (s < 0) {
      s = L->stream_count++;
      L->streams[s].base = in[i].group_base;
      L->streams[s].stride = in[i].stride;
      L->streams[s].source = in[i].source;
      stream_min[s] = in[i].offset;
    } else if (in[i].offset < stream_min[s]) {
      stream_min[s] = in[i].offset;
    }
    stream_of[i] = s;
  }
  for (int i = 0; i < n; i++) {
    const int s = stream_of[i];
    const size_t rel = in[i].offset - stream_min[s];
    if (rel > 0xFFFF) {
      fvgl_log("draw: attribute offsets %u apart in one stream", (unsigned)rel);
      return false;
    }
    SceGxmVertexAttribute* a = &L->attributes[L->attribute_count++];
    a->streamIndex = (uint16_t)s;
    a->offset = (uint16_t)rel;
    a->format = in[i].format;
    a->componentCount = in[i].comps;
    a->regIndex = in[i].reg;
  }
  for (int s = 0; s < L->stream_count; s++) {
    // Rebase: element 0 of the stream is the group's smallest offset, moved
    // on by `first` elements for glDrawArrays.
    L->streams[s].base += stream_min[s];
    if (L->streams[s].source == SCE_GXM_INDEX_SOURCE_INDEX_16BIT) L->streams[s].base += (size_t)first * L->streams[s].stride;
  }

  // The cache key: everything the patcher is told.
  uint8_t* k = L->key;
  *k++ = (uint8_t)L->attribute_count;
  *k++ = (uint8_t)L->stream_count;
  for (int i = 0; i < L->attribute_count; i++) {
    const SceGxmVertexAttribute* a = &L->attributes[i];
    *k++ = (uint8_t)a->streamIndex;
    *k++ = a->format;
    *k++ = a->componentCount;
    *k++ = (uint8_t)a->regIndex;
    *k++ = (uint8_t)(a->offset & 0xFF);
    *k++ = (uint8_t)(a->offset >> 8);
  }
  for (int s = 0; s < L->stream_count; s++) {
    *k++ = (uint8_t)(L->streams[s].stride & 0xFF);
    *k++ = (uint8_t)(L->streams[s].stride >> 8);
    *k++ = (uint8_t)L->streams[s].source;
  }
  L->key_len = (int)(k - L->key);
  return true;
}

unsigned fvgl_vertex_variants, fvgl_fragment_variants, fvgl_variants_uncached;

static SceGxmVertexProgram* vertex_variant(FvglProgram* p, const Layout* L) {
  for (int i = 0; i < p->vertex_variant_count; i++) {
    FvglVertexVariant* v = &p->vertex_variants[i];
    if (v->key_len == L->key_len && memcmp(v->key, L->key, (size_t)L->key_len) == 0) return v->program;
  }
  SceGxmVertexStream streams[FVGL_MAX_ATTRIBUTES];
  for (int s = 0; s < L->stream_count; s++) {
    streams[s].stride = L->streams[s].stride;
    streams[s].indexSource = L->streams[s].source;
  }
  SceGxmVertexProgram* vp = NULL;
  const int r = sceGxmShaderPatcherCreateVertexProgram(fvgl.patcher, p->vid, L->attributes,
                                                       (unsigned)L->attribute_count, streams,
                                                       (unsigned)L->stream_count, &vp);
  if (r < 0) {
    fvgl_log("sceGxmShaderPatcherCreateVertexProgram: 0x%08X", (unsigned)r);
    return NULL;
  }
  if (p->vertex_variant_count < FVGL_MAX_VARIANTS) {
    FvglVertexVariant* v = &p->vertex_variants[p->vertex_variant_count++];
    memcpy(v->key, L->key, (size_t)L->key_len);
    v->key_len = L->key_len;
    v->program = vp;
    fvgl_vertex_variants++;
  } else {
    fvgl_variants_uncached++;
    fvgl_log("program has more than %d vertex layouts; one is not cached", FVGL_MAX_VARIANTS);
  }
  return vp;
}

// ---- blend -----------------------------------------------------------------

static uint8_t blend_factor(GLenum f) {
  switch (f) {
    case GL_ZERO: return SCE_GXM_BLEND_FACTOR_ZERO;
    case GL_ONE: return SCE_GXM_BLEND_FACTOR_ONE;
    case GL_SRC_COLOR: return SCE_GXM_BLEND_FACTOR_SRC_COLOR;
    case GL_ONE_MINUS_SRC_COLOR: return SCE_GXM_BLEND_FACTOR_ONE_MINUS_SRC_COLOR;
    case GL_SRC_ALPHA: return SCE_GXM_BLEND_FACTOR_SRC_ALPHA;
    case GL_ONE_MINUS_SRC_ALPHA: return SCE_GXM_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    case GL_DST_COLOR: return SCE_GXM_BLEND_FACTOR_DST_COLOR;
    case GL_ONE_MINUS_DST_COLOR: return SCE_GXM_BLEND_FACTOR_ONE_MINUS_DST_COLOR;
    case GL_DST_ALPHA: return SCE_GXM_BLEND_FACTOR_DST_ALPHA;
    case GL_ONE_MINUS_DST_ALPHA: return SCE_GXM_BLEND_FACTOR_ONE_MINUS_DST_ALPHA;
    case GL_SRC_ALPHA_SATURATE: return SCE_GXM_BLEND_FACTOR_SRC_ALPHA_SATURATE;
    default: return SCE_GXM_BLEND_FACTOR_ONE;
  }
}

static uint8_t blend_func(GLenum e) {
  switch (e) {
    case GL_FUNC_SUBTRACT: return SCE_GXM_BLEND_FUNC_SUBTRACT;
    case GL_FUNC_REVERSE_SUBTRACT: return SCE_GXM_BLEND_FUNC_REVERSE_SUBTRACT;
    default: return SCE_GXM_BLEND_FUNC_ADD;
  }
}

static SceGxmBlendInfo current_blend_info(uint32_t* key) {
  SceGxmBlendInfo b;
  memset(&b, 0, sizeof b);
  b.colorMask = (uint8_t)((fvgl.color_mask[0] ? SCE_GXM_COLOR_MASK_R : 0) | (fvgl.color_mask[1] ? SCE_GXM_COLOR_MASK_G : 0) |
                          (fvgl.color_mask[2] ? SCE_GXM_COLOR_MASK_B : 0) | (fvgl.color_mask[3] ? SCE_GXM_COLOR_MASK_A : 0));
  if (fvgl.blend.enabled) {
    b.colorFunc = blend_func(fvgl.blend.eq_rgb);
    b.alphaFunc = blend_func(fvgl.blend.eq_alpha);
    b.colorSrc = blend_factor(fvgl.blend.src_rgb);
    b.colorDst = blend_factor(fvgl.blend.dst_rgb);
    b.alphaSrc = blend_factor(fvgl.blend.src_alpha);
    b.alphaDst = blend_factor(fvgl.blend.dst_alpha);
  } else {
    b.colorFunc = SCE_GXM_BLEND_FUNC_NONE;
    b.alphaFunc = SCE_GXM_BLEND_FUNC_NONE;
    b.colorSrc = SCE_GXM_BLEND_FACTOR_ONE;
    b.colorDst = SCE_GXM_BLEND_FACTOR_ZERO;
    b.alphaSrc = SCE_GXM_BLEND_FACTOR_ONE;
    b.alphaDst = SCE_GXM_BLEND_FACTOR_ZERO;
  }
  memcpy(key, &b, 4);
  return b;
}

static SceGxmFragmentProgram* fragment_variant(FvglProgram* p) {
  uint32_t key;
  const SceGxmBlendInfo blend = current_blend_info(&key);
  for (int i = 0; i < p->fragment_variant_count; i++) {
    if (p->fragment_variants[i].key == key) return p->fragment_variants[i].program;
  }
  SceGxmFragmentProgram* fp = NULL;
  const int r = sceGxmShaderPatcherCreateFragmentProgram(fvgl.patcher, p->fid, SCE_GXM_OUTPUT_REGISTER_FORMAT_UCHAR4,
                                                         SCE_GXM_MULTISAMPLE_NONE, &blend, p->vgxp, &fp);
  if (r < 0) {
    fvgl_log("sceGxmShaderPatcherCreateFragmentProgram: 0x%08X", (unsigned)r);
    return NULL;
  }
  if (p->fragment_variant_count < FVGL_MAX_VARIANTS) {
    p->fragment_variants[p->fragment_variant_count].key = key;
    p->fragment_variants[p->fragment_variant_count].program = fp;
    p->fragment_variant_count++;
    fvgl_fragment_variants++;
  } else {
    fvgl_variants_uncached++;
    fvgl_log("program has more than %d blend states; one is not cached", FVGL_MAX_VARIANTS);
  }
  return fp;
}

// ---- uniforms into the ring ------------------------------------------------

static void upload_uniforms(FvglProgram* p) {
  void* vbuf = NULL;
  void* fbuf = NULL;
  sceGxmReserveVertexDefaultUniformBuffer(fvgl.gxm, &vbuf);
  sceGxmReserveFragmentDefaultUniformBuffer(fvgl.gxm, &fbuf);
  for (int i = 0; i < p->uniform_count; i++) {
    const FvglUniform* u = &p->uniforms[i];
    if (u->is_sampler) continue;
    const unsigned n = (unsigned)(u->array * u->components);
    if (u->vp && vbuf) sceGxmSetUniformDataF(vbuf, u->vp, 0, n, u->values);
    if (u->fp && fbuf) sceGxmSetUniformDataF(fbuf, u->fp, 0, n, u->values);
  }
  if (p->fc_param && fbuf) sceGxmSetUniformDataF(fbuf, p->fc_param, 0, 2, fvgl.fc);
  p->uniforms_dirty = false;
  fvgl.bound_program = p;
  fvgl.bound_fc[0] = fvgl.fc[0];
  fvgl.bound_fc[1] = fvgl.fc[1];
}

// ---- the draw --------------------------------------------------------------

static bool primitive(GLenum mode, SceGxmPrimitiveType* out) {
  switch (mode) {
    case GL_TRIANGLES: *out = SCE_GXM_PRIMITIVE_TRIANGLES; return true;
    case GL_TRIANGLE_STRIP: *out = SCE_GXM_PRIMITIVE_TRIANGLE_STRIP; return true;
    case GL_TRIANGLE_FAN: *out = SCE_GXM_PRIMITIVE_TRIANGLE_FAN; return true;
    case GL_LINES: *out = SCE_GXM_PRIMITIVE_LINES; return true;
    case GL_POINTS: *out = SCE_GXM_PRIMITIVE_POINTS; return true;
    case GL_LINE_STRIP:
    case GL_LINE_LOOP: *out = SCE_GXM_PRIMITIVE_LINES; return true;  // expanded by the caller
    default: return false;
  }
}

// Turns a line strip or loop into a line list in scratch memory.
static const void* expand_lines(GLenum mode, const void* indices, SceGxmIndexFormat format, unsigned count,
                                unsigned* out_count) {
  const unsigned segments = mode == GL_LINE_LOOP ? count : count - 1;
  *out_count = segments * 2;
  if (format == SCE_GXM_INDEX_FORMAT_U16) {
    const uint16_t* in = indices;
    uint16_t* out = fvgl_scratch_alloc(*out_count * sizeof(uint16_t), 4);
    if (!out) return NULL;
    for (unsigned i = 0; i < segments; i++) {
      out[i * 2] = in[i];
      out[i * 2 + 1] = in[(i + 1) % count];
    }
    return out;
  }
  const uint32_t* in = indices;
  uint32_t* out = fvgl_scratch_alloc(*out_count * sizeof(uint32_t), 4);
  if (!out) return NULL;
  for (unsigned i = 0; i < segments; i++) {
    out[i * 2] = in[i];
    out[i * 2 + 1] = in[(i + 1) % count];
  }
  return out;
}

static void draw(GLenum mode, GLint first, unsigned count, unsigned vertex_count, const void* indices,
                 SceGxmIndexFormat format) {
  FvglProgram* p = fvgl.current_program;
  if (!p || !p->linked) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  SceGxmPrimitiveType prim;
  if (!primitive(mode, &prim)) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  if (count == 0) return;
  if (mode == GL_LINE_STRIP || mode == GL_LINE_LOOP) {
    if (count < 2) return;
    indices = expand_lines(mode, indices, format, count, &count);
    if (!indices) return;
  }

  fvgl_scene_begin();
  if (!fvgl.scene_open) return;

  Layout L;
  if (!build_layout(p, first, vertex_count, &L)) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  SceGxmVertexProgram* vp = vertex_variant(p, &L);
  SceGxmFragmentProgram* fp = fragment_variant(p);
  if (!vp || !fp) return;

  sceGxmSetVertexProgram(fvgl.gxm, vp);
  sceGxmSetFragmentProgram(fvgl.gxm, fp);
  if (fvgl.bound_program != p || p->uniforms_dirty || fvgl.bound_fc[0] != fvgl.fc[0] || fvgl.bound_fc[1] != fvgl.fc[1])
    upload_uniforms(p);
  fvgl_bind_samplers(p);
  for (int s = 0; s < L.stream_count; s++) sceGxmSetVertexStream(fvgl.gxm, (unsigned)s, L.streams[s].base);

  const int r = sceGxmDraw(fvgl.gxm, prim, format, indices, count);
  if (r < 0) fvgl_log("sceGxmDraw: 0x%08X", (unsigned)r);
}

GL_APICALL void GL_APIENTRY glDrawArrays(GLenum mode, GLint first, GLsizei count) {
  if (first < 0 || count < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (count == 0) return;
  SceGxmIndexFormat format;
  const void* indices = identity_indices((unsigned)count, &format);
  if (!indices) return;
  draw(mode, first, (unsigned)count, (unsigned)count, indices, format);
}

GL_APICALL void GL_APIENTRY glDrawElements(GLenum mode, GLsizei count, GLenum type, const void* indices) {
  if (count < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (count == 0) return;
  unsigned elem;
  SceGxmIndexFormat format;
  switch (type) {
    case GL_UNSIGNED_BYTE: elem = 1; format = SCE_GXM_INDEX_FORMAT_U16; break;
    case GL_UNSIGNED_SHORT: elem = 2; format = SCE_GXM_INDEX_FORMAT_U16; break;
    case GL_UNSIGNED_INT: elem = 4; format = SCE_GXM_INDEX_FORMAT_U32; break;
    default: fvgl_set_error(GL_INVALID_ENUM); return;
  }
  const uint8_t* src;
  if (fvgl.element_buffer) {
    FvglBuffer* b = fvgl_table_get(&fvgl.buffers, fvgl.element_buffer);
    if (!b || !b->data || (size_t)(uintptr_t)indices + (size_t)count * elem > b->size) {
      fvgl_set_error(GL_INVALID_OPERATION);
      return;
    }
    b->last_frame_used = fvgl.frame;
    src = b->data + (uintptr_t)indices;
  } else {
    if (!indices) {
      fvgl_set_error(GL_INVALID_VALUE);
      return;
    }
    src = indices;
  }
  // The GPU reads u16 or u32; bytes are widened, and client memory is copied.
  const void* data = src;
  unsigned max_index = 0;
  const bool need_max = fvgl.array_buffer == 0;  // some attribute may be client-side
  if (type == GL_UNSIGNED_BYTE) {
    uint16_t* w = fvgl_scratch_alloc((size_t)count * 2, 4);
    if (!w) return;
    for (GLsizei i = 0; i < count; i++) {
      w[i] = src[i];
      if (w[i] > max_index) max_index = w[i];
    }
    data = w;
  } else if (!fvgl.element_buffer) {
    void* w = fvgl_scratch_alloc((size_t)count * elem, 4);
    if (!w) return;
    memcpy(w, src, (size_t)count * elem);
    data = w;
  }
  if (need_max && type != GL_UNSIGNED_BYTE) {
    for (GLsizei i = 0; i < count; i++) {
      const unsigned v = elem == 2 ? ((const uint16_t*)src)[i] : ((const uint32_t*)src)[i];
      if (v > max_index) max_index = v;
    }
  }
  draw(mode, 0, (unsigned)count, max_index + 1, data, format);
}
