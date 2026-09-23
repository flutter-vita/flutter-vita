// Pipeline state that is remembered here and applied at draw time, and the
// getters Skia reads its capabilities from.
#include <string.h>

#include "fvgl_internal.h"

static bool blend_factor_ok(GLenum f) {
  switch (f) {
    case GL_ZERO: case GL_ONE: case GL_SRC_COLOR: case GL_ONE_MINUS_SRC_COLOR: case GL_SRC_ALPHA:
    case GL_ONE_MINUS_SRC_ALPHA: case GL_DST_COLOR: case GL_ONE_MINUS_DST_COLOR: case GL_DST_ALPHA:
    case GL_ONE_MINUS_DST_ALPHA: case GL_SRC_ALPHA_SATURATE:
      return true;
    case GL_CONSTANT_COLOR: case GL_ONE_MINUS_CONSTANT_COLOR: case GL_CONSTANT_ALPHA: case GL_ONE_MINUS_CONSTANT_ALPHA:
      // Valid GL, no blend constant on this GPU. Not advertised, so Skia never asks.
      return false;
    default:
      return false;
  }
}

GL_APICALL void GL_APIENTRY glBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
  if (!blend_factor_ok(srcRGB) || !blend_factor_ok(dstRGB) || !blend_factor_ok(srcAlpha) || !blend_factor_ok(dstAlpha)) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  fvgl.blend.src_rgb = srcRGB;
  fvgl.blend.dst_rgb = dstRGB;
  fvgl.blend.src_alpha = srcAlpha;
  fvgl.blend.dst_alpha = dstAlpha;
}

GL_APICALL void GL_APIENTRY glBlendFunc(GLenum sfactor, GLenum dfactor) {
  glBlendFuncSeparate(sfactor, dfactor, sfactor, dfactor);
}

static bool blend_eq_ok(GLenum e) {
  return e == GL_FUNC_ADD || e == GL_FUNC_SUBTRACT || e == GL_FUNC_REVERSE_SUBTRACT;
}

GL_APICALL void GL_APIENTRY glBlendEquationSeparate(GLenum modeRGB, GLenum modeAlpha) {
  if (!blend_eq_ok(modeRGB) || !blend_eq_ok(modeAlpha)) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  fvgl.blend.eq_rgb = modeRGB;
  fvgl.blend.eq_alpha = modeAlpha;
}

GL_APICALL void GL_APIENTRY glBlendEquation(GLenum mode) { glBlendEquationSeparate(mode, mode); }

// GLES 2.0 has a blend constant; this GPU does not. The four factors that
// would read it are already refused by blend_factor_ok, so no draw can reach
// a value set here. It is kept because GL_BLEND_COLOR has to read back what
// was written, and refusing the call would fail a program that sets the
// constant and then never uses it.
GL_APICALL void GL_APIENTRY glBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
  const float in[4] = {red, green, blue, alpha};
  for (int i = 0; i < 4; i++) fvgl.blend_color[i] = in[i] < 0 ? 0 : in[i] > 1 ? 1 : in[i];
}

GL_APICALL void GL_APIENTRY glFrontFace(GLenum mode) {
  if (mode != GL_CW && mode != GL_CCW) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  fvgl.front_face = mode;
}

GL_APICALL void GL_APIENTRY glCullFace(GLenum mode) {
  if (mode != GL_FRONT && mode != GL_BACK && mode != GL_FRONT_AND_BACK) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  fvgl.cull_face = mode;
  fvgl.raster_dirty = true;
}

// ---- depth -----------------------------------------------------------------

GL_APICALL void GL_APIENTRY glDepthMask(GLboolean flag) {
  fvgl.depth_mask = flag ? GL_TRUE : GL_FALSE;
  fvgl.raster_dirty = true;
}

static bool compare_func_ok(GLenum f) {
  switch (f) {
    case GL_NEVER: case GL_LESS: case GL_EQUAL: case GL_LEQUAL:
    case GL_GREATER: case GL_NOTEQUAL: case GL_GEQUAL: case GL_ALWAYS:
      return true;
    default:
      return false;
  }
}

GL_APICALL void GL_APIENTRY glDepthFunc(GLenum func) {
  if (!compare_func_ok(func)) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  fvgl.depth_func = func;
  fvgl.raster_dirty = true;
}

static float clamp01(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

// The range reaches the GPU as the viewport's z scale and offset, so it takes
// effect at the next apply_viewport -- which a scene and every glViewport do.
GL_APICALL void GL_APIENTRY glDepthRangef(GLfloat n, GLfloat f) {
  fvgl.depth_range[0] = clamp01(n);
  fvgl.depth_range[1] = clamp01(f);
  if (fvgl.scene_open) glViewport(fvgl.viewport[0], fvgl.viewport[1], fvgl.viewport[2], fvgl.viewport[3]);
}

GL_APICALL void GL_APIENTRY glClearDepthf(GLfloat d) { fvgl.clear_depth = clamp01(d); }

// ---- stencil ---------------------------------------------------------------
//
// Front and back are kept apart here exactly as GL keeps them; which of the
// two the GPU calls front depends on the target, and fvgl_apply_raster is
// where that is sorted out.

static bool stencil_face_ok(GLenum face) {
  return face == GL_FRONT || face == GL_BACK || face == GL_FRONT_AND_BACK;
}

static bool stencil_op_ok(GLenum op) {
  switch (op) {
    case GL_KEEP: case GL_ZERO: case GL_REPLACE: case GL_INCR:
    case GL_DECR: case GL_INVERT: case GL_INCR_WRAP: case GL_DECR_WRAP:
      return true;
    default:
      return false;
  }
}

GL_APICALL void GL_APIENTRY glStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask) {
  if (!stencil_face_ok(face) || !compare_func_ok(func)) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  for (int i = 0; i < 2; i++) {
    FvglStencilFace* f = i ? &fvgl.stencil_back : &fvgl.stencil_front;
    if (face != GL_FRONT_AND_BACK && (face == GL_BACK) != (i == 1)) continue;
    f->func = func;
    f->ref = ref;
    f->compare_mask = mask;
  }
  fvgl.raster_dirty = true;
}

GL_APICALL void GL_APIENTRY glStencilFunc(GLenum func, GLint ref, GLuint mask) {
  glStencilFuncSeparate(GL_FRONT_AND_BACK, func, ref, mask);
}

GL_APICALL void GL_APIENTRY glStencilOpSeparate(GLenum face, GLenum sfail, GLenum dpfail, GLenum dppass) {
  if (!stencil_face_ok(face) || !stencil_op_ok(sfail) || !stencil_op_ok(dpfail) || !stencil_op_ok(dppass)) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  for (int i = 0; i < 2; i++) {
    FvglStencilFace* f = i ? &fvgl.stencil_back : &fvgl.stencil_front;
    if (face != GL_FRONT_AND_BACK && (face == GL_BACK) != (i == 1)) continue;
    f->sfail = sfail;
    f->dpfail = dpfail;
    f->dppass = dppass;
  }
  fvgl.raster_dirty = true;
}

GL_APICALL void GL_APIENTRY glStencilOp(GLenum fail, GLenum zfail, GLenum zpass) {
  glStencilOpSeparate(GL_FRONT_AND_BACK, fail, zfail, zpass);
}

GL_APICALL void GL_APIENTRY glStencilMaskSeparate(GLenum face, GLuint mask) {
  if (!stencil_face_ok(face)) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  for (int i = 0; i < 2; i++) {
    FvglStencilFace* f = i ? &fvgl.stencil_back : &fvgl.stencil_front;
    if (face != GL_FRONT_AND_BACK && (face == GL_BACK) != (i == 1)) continue;
    f->write_mask = mask;
  }
  fvgl.raster_dirty = true;
}

GL_APICALL void GL_APIENTRY glStencilMask(GLuint mask) { glStencilMaskSeparate(GL_FRONT_AND_BACK, mask); }

GL_APICALL void GL_APIENTRY glClearStencil(GLint s) { fvgl.clear_stencil = s; }

GL_APICALL void GL_APIENTRY glLineWidth(GLfloat width) {
  if (width <= 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  fvgl.line_width = width;
}

// The only hint GLES 2.0 defines is the mipmap one, and this layer builds
// mipmaps one way. Stored, so the getter answers, and otherwise ignored:
// a hint that changes nothing is still a legal hint.
GL_APICALL void GL_APIENTRY glHint(GLenum target, GLenum mode) {
  if (target != GL_GENERATE_MIPMAP_HINT) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  if (mode != GL_FASTEST && mode != GL_NICEST && mode != GL_DONT_CARE) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  fvgl.generate_mipmap_hint = mode;
}

// Depth bias, in the units sceGxmSetFrontDepthBias takes. It reaches the GPU
// only while GL_POLYGON_OFFSET_FILL is on and a depth surface exists; see
// fvgl_apply_depth_stencil.
GL_APICALL void GL_APIENTRY glPolygonOffset(GLfloat factor, GLfloat units) {
  fvgl.polygon_offset[0] = factor;
  fvgl.polygon_offset[1] = units;
}

// Multisampling is off on every surface here (GL_SAMPLES reads 0), so the
// coverage value changes no fragment. Stored for the getters.
GL_APICALL void GL_APIENTRY glSampleCoverage(GLfloat value, GLboolean invert) {
  fvgl.sample_coverage = value < 0 ? 0 : value > 1 ? 1 : value;
  fvgl.sample_coverage_invert = invert ? GL_TRUE : GL_FALSE;
}

// A hint that the compiler can go. It cannot: every glLinkProgram runs Cg
// through libshacccg, so the module stays loaded for the life of the context.
GL_APICALL void GL_APIENTRY glReleaseShaderCompiler(void) {}

// No binary format is advertised (GL_NUM_SHADER_BINARY_FORMATS reads 0), so
// every binaryformat is invalid, which is what GL asks for.
GL_APICALL void GL_APIENTRY glShaderBinary(GLsizei count, const GLuint* shaders, GLenum binaryformat,
                                           const void* binary, GLsizei length) {
  (void)shaders;
  (void)binary;
  if (count < 0 || length < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  (void)binaryformat;
  fvgl_set_error(GL_INVALID_ENUM);
}

GL_APICALL void GL_APIENTRY glFlush(void) { if (!fvgl.up) return;}

GL_APICALL void GL_APIENTRY glFinish(void) {
  if (!fvgl.up) return;
  fvgl_scene_end();
  if (!fvgl.gxm) return;
  sceGxmFinish(fvgl.gxm);
  *fvgl.frame_done = fvgl.frame - 1;
}

GL_APICALL GLboolean GL_APIENTRY glIsEnabled(GLenum cap) {
  switch (cap) {
    case GL_SCISSOR_TEST: return fvgl.scissor_enabled;
    case GL_BLEND: return fvgl.blend.enabled;
    case GL_CULL_FACE: return fvgl.cull_enabled;
    case GL_DEPTH_TEST: return fvgl.depth_test_enabled;
    case GL_STENCIL_TEST: return fvgl.stencil_test_enabled;
    case GL_DITHER: return fvgl.dither_enabled;
    case GL_POLYGON_OFFSET_FILL: return fvgl.polygon_offset_fill;
    case GL_SAMPLE_ALPHA_TO_COVERAGE:
    case GL_SAMPLE_COVERAGE: return GL_FALSE;  // no surface here is multisampled
    default: fvgl_set_error(GL_INVALID_ENUM); return GL_FALSE;
  }
}

// ---- getters ---------------------------------------------------------------
//
// One table in floats; the integer and boolean forms convert. The limits are
// the GPU's where the SDK states them and GLES 2.0's minimums otherwise.

static int get_values(GLenum pname, float* v) {
  switch (pname) {
    case GL_MAX_TEXTURE_SIZE: v[0] = 4096; return 1;
    case GL_MAX_CUBE_MAP_TEXTURE_SIZE: v[0] = 4096; return 1;
    case GL_MAX_RENDERBUFFER_SIZE: v[0] = 4096; return 1;
    case GL_MAX_VIEWPORT_DIMS: v[0] = 4096; v[1] = 4096; return 2;
    case GL_MAX_VERTEX_ATTRIBS: v[0] = FVGL_MAX_ATTRIBUTES; return 1;
    case GL_MAX_VERTEX_UNIFORM_VECTORS: v[0] = 128; return 1;
    case GL_MAX_FRAGMENT_UNIFORM_VECTORS: v[0] = 64; return 1;
    case GL_MAX_VARYING_VECTORS: v[0] = FVGL_MAX_VARYINGS; return 1;
    case GL_MAX_TEXTURE_IMAGE_UNITS: v[0] = FVGL_MAX_TEXTURE_UNITS; return 1;
    case GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS: v[0] = 0; return 1;
    case GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS: v[0] = FVGL_MAX_TEXTURE_UNITS; return 1;
    case GL_ALIASED_LINE_WIDTH_RANGE: v[0] = 1; v[1] = 1; return 2;
    case GL_ALIASED_POINT_SIZE_RANGE: v[0] = 1; v[1] = 1; return 2;
    case GL_NUM_COMPRESSED_TEXTURE_FORMATS: v[0] = 0; return 1;
    case GL_NUM_SHADER_BINARY_FORMATS: v[0] = 0; return 1;
    // GL_NUM_PROGRAM_BINARY_FORMATS_OES. Not advertised, and Skia asks anyway
    // and trusts the count (GrGLCaps.cpp, fProgramBinarySupport); zero turns
    // its program cache off, which is right, the compiled programs live in
    // this layer's own cache on the card.
    case 0x87FE: v[0] = 0; return 1;
    case GL_SUBPIXEL_BITS: v[0] = 4; return 1;
    case GL_SAMPLE_BUFFERS: v[0] = 0; return 1;
    case GL_SAMPLES: v[0] = 0; return 1;
    case GL_RED_BITS: case GL_GREEN_BITS: case GL_BLUE_BITS: case GL_ALPHA_BITS: v[0] = 8; return 1;
    case GL_DEPTH_BITS: v[0] = 0; return 1;
    case GL_STENCIL_BITS: v[0] = 0; return 1;
    case GL_IMPLEMENTATION_COLOR_READ_FORMAT: v[0] = GL_RGBA; return 1;
    case GL_IMPLEMENTATION_COLOR_READ_TYPE: v[0] = GL_UNSIGNED_BYTE; return 1;
    case GL_PACK_ALIGNMENT: v[0] = (float)fvgl.pack_alignment; return 1;
    case GL_UNPACK_ALIGNMENT: v[0] = (float)fvgl.unpack_alignment; return 1;
    case GL_VIEWPORT:
      for (int i = 0; i < 4; i++) v[i] = (float)fvgl.viewport[i];
      return 4;
    case GL_SCISSOR_BOX:
      for (int i = 0; i < 4; i++) v[i] = (float)fvgl.scissor[i];
      return 4;
    case GL_COLOR_CLEAR_VALUE:
      for (int i = 0; i < 4; i++) v[i] = fvgl.clear_color[i];
      return 4;
    case GL_COLOR_WRITEMASK:
      for (int i = 0; i < 4; i++) v[i] = fvgl.color_mask[i];
      return 4;
    case GL_ARRAY_BUFFER_BINDING: v[0] = (float)fvgl.array_buffer; return 1;
    case GL_ELEMENT_ARRAY_BUFFER_BINDING: v[0] = (float)fvgl.element_buffer; return 1;
    case GL_FRAMEBUFFER_BINDING: v[0] = (float)fvgl.bound_framebuffer; return 1;
    case GL_RENDERBUFFER_BINDING: v[0] = 0; return 1;
    case GL_ACTIVE_TEXTURE: v[0] = (float)(GL_TEXTURE0 + (GLenum)fvgl.active_unit); return 1;
    case GL_TEXTURE_BINDING_2D: v[0] = (float)fvgl.unit_2d[fvgl.active_unit]; return 1;
    case GL_TEXTURE_BINDING_CUBE_MAP: v[0] = (float)fvgl.unit_cube[fvgl.active_unit]; return 1;
    case GL_CURRENT_PROGRAM: {
      float n = 0;
      for (unsigned i = 1; i <= fvgl.programs.count; i++)
        if (fvgl_table_get(&fvgl.programs, i) == fvgl.current_program) n = (float)i;
      v[0] = n;
      return 1;
    }
    case GL_BLEND: v[0] = fvgl.blend.enabled; return 1;
    case GL_SCISSOR_TEST: v[0] = fvgl.scissor_enabled; return 1;
    case GL_BLEND_SRC_RGB: v[0] = (float)fvgl.blend.src_rgb; return 1;
    case GL_BLEND_DST_RGB: v[0] = (float)fvgl.blend.dst_rgb; return 1;
    case GL_BLEND_SRC_ALPHA: v[0] = (float)fvgl.blend.src_alpha; return 1;
    case GL_BLEND_DST_ALPHA: v[0] = (float)fvgl.blend.dst_alpha; return 1;
    case GL_BLEND_EQUATION_RGB: v[0] = (float)fvgl.blend.eq_rgb; return 1;
    case GL_BLEND_EQUATION_ALPHA: v[0] = (float)fvgl.blend.eq_alpha; return 1;
    case GL_DEPTH_WRITEMASK: v[0] = fvgl.depth_mask; return 1;
    case GL_FRONT_FACE: v[0] = (float)fvgl.front_face; return 1;
    case GL_LINE_WIDTH: v[0] = fvgl.line_width; return 1;
    case GL_BLEND_COLOR:
      for (int i = 0; i < 4; i++) v[i] = fvgl.blend_color[i];
      return 4;
    case GL_POLYGON_OFFSET_FACTOR: v[0] = fvgl.polygon_offset[0]; return 1;
    case GL_POLYGON_OFFSET_UNITS: v[0] = fvgl.polygon_offset[1]; return 1;
    case GL_SAMPLE_COVERAGE_VALUE: v[0] = fvgl.sample_coverage; return 1;
    case GL_SAMPLE_COVERAGE_INVERT: v[0] = fvgl.sample_coverage_invert; return 1;
    case GL_GENERATE_MIPMAP_HINT: v[0] = (float)fvgl.generate_mipmap_hint; return 1;
    case GL_CULL_FACE: v[0] = fvgl.cull_enabled; return 1;
    case GL_CULL_FACE_MODE: v[0] = (float)fvgl.cull_face; return 1;
    case GL_DEPTH_TEST: v[0] = fvgl.depth_test_enabled; return 1;
    case GL_DEPTH_FUNC: v[0] = (float)fvgl.depth_func; return 1;
    case GL_DEPTH_RANGE: v[0] = fvgl.depth_range[0]; v[1] = fvgl.depth_range[1]; return 2;
    case GL_DEPTH_CLEAR_VALUE: v[0] = fvgl.clear_depth; return 1;
    case GL_POLYGON_OFFSET_FILL: v[0] = fvgl.polygon_offset_fill; return 1;
    case GL_DITHER: v[0] = fvgl.dither_enabled; return 1;
    case GL_STENCIL_TEST: v[0] = fvgl.stencil_test_enabled; return 1;
    case GL_STENCIL_CLEAR_VALUE: v[0] = (float)fvgl.clear_stencil; return 1;
    case GL_STENCIL_FUNC: v[0] = (float)fvgl.stencil_front.func; return 1;
    case GL_STENCIL_REF: v[0] = (float)fvgl.stencil_front.ref; return 1;
    case GL_STENCIL_VALUE_MASK: v[0] = (float)fvgl.stencil_front.compare_mask; return 1;
    case GL_STENCIL_WRITEMASK: v[0] = (float)fvgl.stencil_front.write_mask; return 1;
    case GL_STENCIL_FAIL: v[0] = (float)fvgl.stencil_front.sfail; return 1;
    case GL_STENCIL_PASS_DEPTH_FAIL: v[0] = (float)fvgl.stencil_front.dpfail; return 1;
    case GL_STENCIL_PASS_DEPTH_PASS: v[0] = (float)fvgl.stencil_front.dppass; return 1;
    case GL_STENCIL_BACK_FUNC: v[0] = (float)fvgl.stencil_back.func; return 1;
    case GL_STENCIL_BACK_REF: v[0] = (float)fvgl.stencil_back.ref; return 1;
    case GL_STENCIL_BACK_VALUE_MASK: v[0] = (float)fvgl.stencil_back.compare_mask; return 1;
    case GL_STENCIL_BACK_WRITEMASK: v[0] = (float)fvgl.stencil_back.write_mask; return 1;
    case GL_STENCIL_BACK_FAIL: v[0] = (float)fvgl.stencil_back.sfail; return 1;
    case GL_STENCIL_BACK_PASS_DEPTH_FAIL: v[0] = (float)fvgl.stencil_back.dpfail; return 1;
    case GL_STENCIL_BACK_PASS_DEPTH_PASS: v[0] = (float)fvgl.stencil_back.dppass; return 1;
    default: return 0;
  }
}

GL_APICALL void GL_APIENTRY glGetFloatv(GLenum pname, GLfloat* data) {
  float v[4];
  const int n = get_values(pname, v);
  if (!n) {
    fvgl_set_error(GL_INVALID_ENUM);
    fvgl_log("glGetFloatv 0x%04X: not known here", pname);
    return;
  }
  for (int i = 0; i < n; i++) data[i] = v[i];
}

GL_APICALL void GL_APIENTRY glGetIntegerv(GLenum pname, GLint* data) {
  float v[4];
  const int n = get_values(pname, v);
  if (!n) {
    fvgl_set_error(GL_INVALID_ENUM);
    fvgl_log("glGetIntegerv 0x%04X: not known here", pname);
    return;
  }
  for (int i = 0; i < n; i++) data[i] = (GLint)v[i];
}

GL_APICALL void GL_APIENTRY glGetBooleanv(GLenum pname, GLboolean* data) {
  float v[4];
  const int n = get_values(pname, v);
  if (!n) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  for (int i = 0; i < n; i++) data[i] = v[i] != 0;
}

// What a `precision` qualifier buys in a shader compiled here. Skia reads this
// once for the fragment stage (GrGLCaps::initGLSL) to learn whether half and
// float are the same width, and it steers what it writes in `half`.
//
// The truth today is that every qualifier is 32-bit float: the translator
// spells lowp, mediump and highp as Cg `float`, so the ranges below are IEEE
// single for all three. When mediump becomes Cg `half` (on the backlog), the
// medium and low rows here change with it, or Skia will be told a lie.
// Integers are 32-bit too; GLES asks for their precision as 0.
GL_APICALL void GL_APIENTRY glGetShaderPrecisionFormat(GLenum shadertype, GLenum precisiontype, GLint* range,
                                                        GLint* precision) {
  if (shadertype != GL_VERTEX_SHADER && shadertype != GL_FRAGMENT_SHADER) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  switch (precisiontype) {
    case GL_LOW_FLOAT:
    case GL_MEDIUM_FLOAT:
    case GL_HIGH_FLOAT:
      if (range) { range[0] = 127; range[1] = 127; }
      if (precision) *precision = 23;
      return;
    case GL_LOW_INT:
    case GL_MEDIUM_INT:
    case GL_HIGH_INT:
      if (range) { range[0] = 31; range[1] = 30; }
      if (precision) *precision = 0;
      return;
    default:
      fvgl_set_error(GL_INVALID_ENUM);
      return;
  }
}
