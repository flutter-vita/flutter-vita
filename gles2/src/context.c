// The sceGxm context, the display chain, and the GL state that lives on the
// default framebuffer: clear, scissor, viewport, colour mask, readback.
//
// Two conventions are decided here and everything else follows them:
//
//   * GL's window origin is bottom-left; the console's surfaces and its WPOS
//     are top-left. On the display the viewport transform flips (yScale is
//     negative), the scissor is converted to rows, and glReadPixels reads rows
//     bottom-up. A texture target is not flipped: its GL row 0 is its memory
//     row 0 (framebuffers.c says why). fvgl_target_extent tells which holds.
//   * The hardware's region clip works on 32x32 tiles, so it cannot be the
//     scissor test on its own. It rejects whole tiles cheaply; the exact edge
//     is a clip() against a rectangle uniform in every fragment program,
//     starting with the clear's.
//
// A "scene" is sceGxm's unit of rendering into one target. One is opened by
// the first draw or clear and closed when the target changes, when pixels are
// read back, or when the frame is presented.
#include <psp2/common_dialog.h>
#include <psp2/display.h>
#include <psp2/io/fcntl.h>
#include <psp2/kernel/clib.h>
#include <psp2/kernel/threadmgr.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

FvglContext fvgl;

// ---- diagnostics -----------------------------------------------------------

void fvgl_log(const char* fmt, ...) {
  char line[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  if (fvgl.log) fvgl.log(line);
  else sceClibPrintf("fvgl: %s\n", line);
}

void fvgl_set_error(GLenum error) {
  if (fvgl.error == GL_NO_ERROR) fvgl.error = error;
}

// ---- recording stubs -------------------------------------------------------

#define FVGL_UNIMPLEMENTED_FILE "ux0:data/flutter-vita/gles2-unimplemented.txt"

void fvgl_stub_called(const char* name) {
  static const char* seen[64];
  static int nseen;
  fvgl_set_error(GL_INVALID_OPERATION);
  for (int i = 0; i < nseen; i++) {
    if (seen[i] == name) return;
  }
  if (nseen < 64) seen[nseen++] = name;
  fvgl_log("unimplemented: %s", name);
  const SceUID fd = sceIoOpen(FVGL_UNIMPLEMENTED_FILE, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_APPEND, 0777);
  if (fd < 0) return;
  sceIoWrite(fd, name, strlen(name));
  sceIoWrite(fd, "\n", 1);
  sceIoClose(fd);
}

// ---- display chain ---------------------------------------------------------

typedef struct DisplayCallbackData {
  void* address;
  uint64_t queued_us;  // when the raster thread queued it
} DisplayCallbackData;

// The display queue's thread runs this once the GPU has finished the frame.
// Its distance from the queueing is the GPU's latency for that frame, which
// nothing else in the process can see.
unsigned fvgl_us_gpu_latency, fvgl_us_gpu_latency_max, fvgl_frames_flipped;

// Set from any thread, read on the display queue's. The context goes in
// before the function and the function goes out before the context, so the
// callback never pairs a hook with the wrong context.
static FvglFrameHook volatile g_frame_hook;
static void* volatile g_frame_hook_ctx;

void fvgl_set_frame_hook(FvglFrameHook hook, void* ctx) {
  if (hook) {
    g_frame_hook_ctx = ctx;
    __sync_synchronize();
    g_frame_hook = hook;
  } else {
    g_frame_hook = 0;
    __sync_synchronize();
    g_frame_hook_ctx = 0;
  }
}

static void display_callback(const void* data) {
  const DisplayCallbackData* d = data;
  const unsigned latency = (unsigned)(fvgl_now_us() - d->queued_us);
  fvgl_us_gpu_latency += latency;
  if (latency > fvgl_us_gpu_latency_max) fvgl_us_gpu_latency_max = latency;
  fvgl_frames_flipped++;
  const FvglFrameHook hook = g_frame_hook;
  if (hook) hook(g_frame_hook_ctx, d->address, fvgl.width, fvgl.height, (int)fvgl.display_stride);
  SceDisplayFrameBuf fb;
  memset(&fb, 0, sizeof fb);
  fb.size = sizeof fb;
  fb.base = d->address;
  fb.pitch = fvgl.display_stride;
  fb.pixelformat = SCE_DISPLAY_PIXELFORMAT_A8B8G8R8;
  fb.width = (unsigned)fvgl.width;
  fb.height = (unsigned)fvgl.height;
  sceDisplaySetFrameBuf(&fb, SCE_DISPLAY_SETBUF_NEXTFRAME);
  sceDisplayWaitVblankStart();
}

// ---- shader patcher callbacks ---------------------------------------------

static void* patcher_host_alloc(void* user, SceSize size) {
  (void)user;
  return malloc(size);
}
static void patcher_host_free(void* user, void* mem) {
  (void)user;
  free(mem);
}

// ---- the clear pipeline ----------------------------------------------------
//
// sceGxm has no clear. A clear is a triangle that covers the target, drawn
// with the depth and stencil tests always passing, the colour mask of the
// moment, and the write masks of whichever buffers the call names. Its clip z
// carries the depth value, and the stencil value rides in as the reference
// with a REPLACE on pass.

static const char kClearVertexCg[] =
    "uniform float uDepth;\n"
    "void main(float2 aPosition, float4 out vPosition : POSITION) {\n"
    "  vPosition = float4(aPosition, uDepth, 1.0f);\n"
    "}\n";

static const char kClearFragmentCg[] =
    "uniform float4 uColor;\n"
    "uniform float4 uScissor;\n"  // x0, y0(row), x1, y1(row), exclusive max
    "float4 main(float4 wpos : WPOS) : COLOR {\n"
    "  clip(float4(wpos.x - uScissor.x, uScissor.z - wpos.x,\n"
    "              wpos.y - uScissor.y, uScissor.w - wpos.y));\n"
    "  return uColor;\n"
    "}\n";

static int clear_pipeline_init(void) {
  FvglClearPipeline* c = &fvgl.clear;
  char log[1024];
  c->vertex_gxp = fvgl_shacc_compile(kClearVertexCg, false, log, sizeof log);
  if (!c->vertex_gxp) {
    fvgl_log("clear vertex shader: %s", log);
    return -1;
  }
  c->fragment_gxp = fvgl_shacc_compile(kClearFragmentCg, true, log, sizeof log);
  if (!c->fragment_gxp) {
    fvgl_log("clear fragment shader: %s", log);
    return -1;
  }
  int r = sceGxmShaderPatcherRegisterProgram(fvgl.patcher, c->vertex_gxp, &c->vertex_id);
  if (r < 0) {
    fvgl_log("register clear vertex: 0x%08X", (unsigned)r);
    return r;
  }
  r = sceGxmShaderPatcherRegisterProgram(fvgl.patcher, c->fragment_gxp, &c->fragment_id);
  if (r < 0) {
    fvgl_log("register clear fragment: 0x%08X", (unsigned)r);
    return r;
  }
  const SceGxmProgramParameter* position =
      sceGxmProgramFindParameterByName(c->vertex_gxp, "aPosition");
  c->color_param = sceGxmProgramFindParameterByName(c->fragment_gxp, "uColor");
  c->scissor_param = sceGxmProgramFindParameterByName(c->fragment_gxp, "uScissor");
  c->depth_param = sceGxmProgramFindParameterByName(c->vertex_gxp, "uDepth");
  if (!position || !c->color_param || !c->scissor_param || !c->depth_param) {
    fvgl_log("clear shaders compiled without their parameters");
    return -1;
  }
  SceGxmVertexAttribute attribute = {
      .streamIndex = 0,
      .offset = 0,
      .format = SCE_GXM_ATTRIBUTE_FORMAT_F32,
      .componentCount = 2,
      .regIndex = (uint16_t)sceGxmProgramParameterGetResourceIndex(position),
  };
  SceGxmVertexStream stream = {.stride = 2 * sizeof(float),
                               .indexSource = SCE_GXM_INDEX_SOURCE_INDEX_16BIT};
  r = sceGxmShaderPatcherCreateVertexProgram(fvgl.patcher, c->vertex_id, &attribute, 1,
                                             &stream, 1, &c->vertex);
  if (r < 0) {
    fvgl_log("clear vertex program: 0x%08X", (unsigned)r);
    return r;
  }
  c->vertices = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, 3 * 2 * sizeof(float), &c->vertex_uid);
  c->indices = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, 3 * sizeof(uint16_t), &c->index_uid);
  if (!c->vertices || !c->indices) return -1;
  // One triangle whose inside covers all of clip space.
  const float v[6] = {-1.f, -1.f, 3.f, -1.f, -1.f, 3.f};
  memcpy(c->vertices, v, sizeof v);
  c->indices[0] = 0;
  c->indices[1] = 1;
  c->indices[2] = 2;
  return 0;
}

static SceGxmFragmentProgram* clear_fragment_for_mask(unsigned gl_mask) {
  FvglClearPipeline* c = &fvgl.clear;
  if (c->fragment[gl_mask]) return c->fragment[gl_mask];
  SceGxmBlendInfo blend;
  memset(&blend, 0, sizeof blend);
  blend.colorMask = (uint8_t)(((gl_mask & 1) ? SCE_GXM_COLOR_MASK_R : 0) |
                              ((gl_mask & 2) ? SCE_GXM_COLOR_MASK_G : 0) |
                              ((gl_mask & 4) ? SCE_GXM_COLOR_MASK_B : 0) |
                              ((gl_mask & 8) ? SCE_GXM_COLOR_MASK_A : 0));
  blend.colorFunc = SCE_GXM_BLEND_FUNC_NONE;
  blend.alphaFunc = SCE_GXM_BLEND_FUNC_NONE;
  blend.colorSrc = SCE_GXM_BLEND_FACTOR_ONE;
  blend.colorDst = SCE_GXM_BLEND_FACTOR_ZERO;
  blend.alphaSrc = SCE_GXM_BLEND_FACTOR_ONE;
  blend.alphaDst = SCE_GXM_BLEND_FACTOR_ZERO;
  const int r = sceGxmShaderPatcherCreateFragmentProgram(
      fvgl.patcher, c->fragment_id, SCE_GXM_OUTPUT_REGISTER_FORMAT_UCHAR4,
      SCE_GXM_MULTISAMPLE_NONE, &blend, c->vertex_gxp, &c->fragment[gl_mask]);
  if (r < 0) {
    fvgl_log("clear fragment program mask %u: 0x%08X", gl_mask, (unsigned)r);
    return NULL;
  }
  return c->fragment[gl_mask];
}

// ---- scissor and viewport in the console's terms ---------------------------

// The scissor as rows, clamped to the target. Returns false when it is empty.
static bool scissor_rows(int* x0, int* y0, int* x1, int* y1) {
  int w, h;
  bool flipped;
  fvgl_target_extent(&w, &h, &flipped);
  if (!fvgl.scissor_enabled) {
    *x0 = 0; *y0 = 0; *x1 = w; *y1 = h;
    return true;
  }
  int sx0 = fvgl.scissor[0], sy0 = fvgl.scissor[1];
  int sx1 = sx0 + fvgl.scissor[2], sy1 = sy0 + fvgl.scissor[3];
  if (sx0 < 0) sx0 = 0;
  if (sy0 < 0) sy0 = 0;
  if (sx1 > w) sx1 = w;
  if (sy1 > h) sy1 = h;
  if (sx1 <= sx0 || sy1 <= sy0) return false;
  *x0 = sx0;
  *x1 = sx1;
  if (flipped) {
    *y0 = h - sy1;  // GL top edge, as a row from the top
    *y1 = h - sy0;
  } else {
    *y0 = sy0;
    *y1 = sy1;
  }
  return true;
}

static void apply_region_clip(void) {
  int x0, y0, x1, y1;
  if (!scissor_rows(&x0, &y0, &x1, &y1)) {
    sceGxmSetRegionClip(fvgl.gxm, SCE_GXM_REGION_CLIP_ALL, 0, 0, 0, 0);
    return;
  }
  sceGxmSetRegionClip(fvgl.gxm, SCE_GXM_REGION_CLIP_OUTSIDE, (unsigned)x0, (unsigned)y0,
                      (unsigned)(x1 - 1), (unsigned)(y1 - 1));
}

static void apply_viewport_z(int x, int y, int w, int h, float z_offset, float z_scale) {
  int tw, th;
  bool flipped;
  fvgl_target_extent(&tw, &th, &flipped);
  if (flipped) {
    // GL: NDC y = +1 is the top of the viewport, which is row H - (y + h).
    sceGxmSetViewport(fvgl.gxm, (float)x + w * 0.5f, w * 0.5f,
                      (float)(th - y) - h * 0.5f, -h * 0.5f, z_offset, z_scale);
  } else {
    sceGxmSetViewport(fvgl.gxm, (float)x + w * 0.5f, w * 0.5f, (float)y + h * 0.5f, h * 0.5f, z_offset, z_scale);
  }
}

static void apply_viewport(int x, int y, int w, int h) {
  // glDepthRangef(n, f) maps clip z in [-1, 1] onto [n, f], which is exactly
  // the offset and scale the viewport takes.
  const float n = fvgl.depth_range[0], f = fvgl.depth_range[1];
  apply_viewport_z(x, y, w, h, (f + n) * 0.5f, (f - n) * 0.5f);
}

// ---- culling, depth and stencil, in the console's terms --------------------
//
// GL decides which side of a triangle faces the viewer from the sign of its
// area in *window* coordinates, and so does the GPU -- but the two do not
// share a window. The display is drawn bottom-up (fvgl_target_extent calls it
// flipped, and apply_viewport gives it a negative height), so a triangle GL
// calls counter-clockwise reaches the rasteriser clockwise, and front and
// back change places. A texture target is not flipped and they agree.
//
// Two things follow, and both are easy to get wrong: the face glCullFace
// names is culled in the other winding on the display, and which of the
// hardware's two sides carries GL's front stencil state changes with the
// target as well as with glFrontFace.

static SceGxmDepthFunc depth_func_of(GLenum f) {
  switch (f) {
    case GL_NEVER: return SCE_GXM_DEPTH_FUNC_NEVER;
    case GL_LESS: return SCE_GXM_DEPTH_FUNC_LESS;
    case GL_EQUAL: return SCE_GXM_DEPTH_FUNC_EQUAL;
    case GL_LEQUAL: return SCE_GXM_DEPTH_FUNC_LESS_EQUAL;
    case GL_GREATER: return SCE_GXM_DEPTH_FUNC_GREATER;
    case GL_NOTEQUAL: return SCE_GXM_DEPTH_FUNC_NOT_EQUAL;
    case GL_GEQUAL: return SCE_GXM_DEPTH_FUNC_GREATER_EQUAL;
    default: return SCE_GXM_DEPTH_FUNC_ALWAYS;
  }
}

static SceGxmStencilFunc stencil_func_of(GLenum f) {
  switch (f) {
    case GL_NEVER: return SCE_GXM_STENCIL_FUNC_NEVER;
    case GL_LESS: return SCE_GXM_STENCIL_FUNC_LESS;
    case GL_EQUAL: return SCE_GXM_STENCIL_FUNC_EQUAL;
    case GL_LEQUAL: return SCE_GXM_STENCIL_FUNC_LESS_EQUAL;
    case GL_GREATER: return SCE_GXM_STENCIL_FUNC_GREATER;
    case GL_NOTEQUAL: return SCE_GXM_STENCIL_FUNC_NOT_EQUAL;
    case GL_GEQUAL: return SCE_GXM_STENCIL_FUNC_GREATER_EQUAL;
    default: return SCE_GXM_STENCIL_FUNC_ALWAYS;
  }
}

static SceGxmStencilOp stencil_op_of(GLenum op) {
  switch (op) {
    case GL_ZERO: return SCE_GXM_STENCIL_OP_ZERO;
    case GL_REPLACE: return SCE_GXM_STENCIL_OP_REPLACE;
    case GL_INCR: return SCE_GXM_STENCIL_OP_INCR;
    case GL_DECR: return SCE_GXM_STENCIL_OP_DECR;
    case GL_INVERT: return SCE_GXM_STENCIL_OP_INVERT;
    case GL_INCR_WRAP: return SCE_GXM_STENCIL_OP_INCR_WRAP;
    case GL_DECR_WRAP: return SCE_GXM_STENCIL_OP_DECR_WRAP;
    default: return SCE_GXM_STENCIL_OP_KEEP;
  }
}

// The console's answer, measured by M6 on 2026-09-24: SCE_GXM_CULL_CW names
// the winding the hardware KEEPS, not the one it removes. The SDK header
// reads the other way ("clockwise hardware culling"), and the first version
// of this function believed it: with front CCW and GL_BACK culled, the
// counter-clockwise quad disappeared and the clockwise one stayed, on both
// targets. So the enum that goes out is the front winding in the
// rasteriser's own frame.
static SceGxmCullMode cull_mode_of(bool flipped) {
  if (!fvgl.cull_enabled || fvgl.cull_face == GL_FRONT_AND_BACK) return SCE_GXM_CULL_NONE;
  // Which winding GL wants gone, in GL's own window.
  const bool cull_cw = (fvgl.cull_face == GL_BACK) == (fvgl.front_face == GL_CCW);
  // On a flipped target that winding reaches the rasteriser the other way
  // round, and the enum then names the one left standing.
  return (cull_cw != flipped) ? SCE_GXM_CULL_CCW : SCE_GXM_CULL_CW;
}

// One side's stencil state, or the pass-everything state when the target has
// no stencil to test against.
static void apply_stencil_side(bool gxm_front, const FvglStencilFace* f, bool have) {
  const SceGxmStencilFunc func = have ? stencil_func_of(f->func) : SCE_GXM_STENCIL_FUNC_ALWAYS;
  const SceGxmStencilOp sfail = have ? stencil_op_of(f->sfail) : SCE_GXM_STENCIL_OP_KEEP;
  const SceGxmStencilOp dpfail = have ? stencil_op_of(f->dpfail) : SCE_GXM_STENCIL_OP_KEEP;
  const SceGxmStencilOp dppass = have ? stencil_op_of(f->dppass) : SCE_GXM_STENCIL_OP_KEEP;
  const unsigned char compare = have ? (unsigned char)f->compare_mask : 0xFF;
  const unsigned char write = have ? (unsigned char)f->write_mask : 0;
  // GL clamps the reference to the stencil width, which is eight bits here.
  unsigned ref = f->ref < 0 ? 0u : (unsigned)f->ref;
  if (ref > 0xFFu) ref = 0xFFu;
  if (gxm_front) {
    sceGxmSetFrontStencilFunc(fvgl.gxm, func, sfail, dpfail, dppass, compare, write);
    sceGxmSetFrontStencilRef(fvgl.gxm, ref);
  } else {
    sceGxmSetBackStencilFunc(fvgl.gxm, func, sfail, dpfail, dppass, compare, write);
    sceGxmSetBackStencilRef(fvgl.gxm, ref);
  }
}

void fvgl_apply_raster(void) {
  if (!fvgl.scene_open) return;
  int w, h;
  bool flipped;
  fvgl_target_extent(&w, &h, &flipped);
  const bool have_ds = fvgl_scene_has_depth();

  sceGxmSetCullMode(fvgl.gxm, cull_mode_of(flipped));

  // With GL_DEPTH_TEST off, GL bypasses the comparison *and* the update: a
  // fragment passes and the depth buffer keeps what it had. So the test being
  // off is not the same as GL_ALWAYS with the mask on, and the write follows
  // the test, not only the mask.
  const bool test = have_ds && fvgl.depth_test_enabled;
  const SceGxmDepthFunc func = test ? depth_func_of(fvgl.depth_func) : SCE_GXM_DEPTH_FUNC_ALWAYS;
  const SceGxmDepthWriteMode write =
      (test && fvgl.depth_mask) ? SCE_GXM_DEPTH_WRITE_ENABLED : SCE_GXM_DEPTH_WRITE_DISABLED;
  sceGxmSetFrontDepthFunc(fvgl.gxm, func);
  sceGxmSetBackDepthFunc(fvgl.gxm, func);
  sceGxmSetFrontDepthWriteEnable(fvgl.gxm, write);
  sceGxmSetBackDepthWriteEnable(fvgl.gxm, write);

  // GL_POLYGON_OFFSET_FILL is remembered by set_capability; the bias reaches
  // the GPU only with a depth surface behind it.
  const bool bias = have_ds && fvgl.polygon_offset_fill;
  const int factor = bias ? (int)fvgl.polygon_offset[0] : 0;
  const int units = bias ? (int)fvgl.polygon_offset[1] : 0;
  sceGxmSetFrontDepthBias(fvgl.gxm, factor, units);
  sceGxmSetBackDepthBias(fvgl.gxm, factor, units);

  // Two-sided stencil is off by default, and off means every triangle takes
  // the front state whatever its winding. M6 measured that on 2026-09-24:
  // with it off, the front-facing and the back-facing box came out alike on
  // each target, and opposite between them.
  const bool stencil = have_ds && fvgl.stencil_test_enabled;
  sceGxmSetTwoSidedEnable(fvgl.gxm, stencil ? SCE_GXM_TWO_SIDED_ENABLED : SCE_GXM_TWO_SIDED_DISABLED);
  // Which of the hardware's two sides is GL's front depends on glFrontFace as
  // well as on the target. The rasteriser's frame counts rows downwards, so a
  // GL front face is counter-clockwise there when GL calls counter-clockwise
  // front and the target is not flipped, or when both are the other way.
  const bool gl_front_is_ccw = (fvgl.front_face == GL_CCW) != flipped;
  apply_stencil_side(gl_front_is_ccw, &fvgl.stencil_front, stencil);
  apply_stencil_side(!gl_front_is_ccw, &fvgl.stencil_back, stencil);

  fvgl.raster_dirty = false;
}

// ---- GPU meter -------------------------------------------------------------
//
// How long the GPU worked, as opposed to how long a frame sat in the display
// queue. The queue's callback fires when the GPU has finished a frame *and*
// the previous callback has come back from its vblank wait, so its distance
// from the queueing (us_gpu_latency) reads a whole frame period whenever the
// pipeline is full, busy GPU or not: the gallery's strip said 126% over a
// still panel. The frame_done notification is written by the GPU itself,
// with no wait in front of it. A thread reads it every millisecond and, for
// each frame that completed, adds the time from that frame's first scene (or
// the previous completion, whichever is later) to now. Vertex work of the
// next frame overlapping fragment work of this one is counted once, which
// is what "busy" means here.
static uint64_t g_frame_first_scene_us[64];  // by frame number, mod 64
static uint32_t g_frame_marked = ~0u;
unsigned fvgl_us_gpu_busy, fvgl_frames_gpu_done;
static volatile bool g_meter_stop;
static SceUID g_meter_thread = -1;

static int gpu_meter(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  uint32_t last = fvgl_gpu_completed_frame();
  uint64_t last_done = fvgl_now_us();
  while (!g_meter_stop) {
    sceKernelDelayThread(1000);
    const uint32_t done = fvgl_gpu_completed_frame();
    if (done == last || done < last) {
      last = done;
      continue;
    }
    const uint64_t now = fvgl_now_us();
    uint64_t start = g_frame_first_scene_us[(last + 1) % 64];
    if (start < last_done) start = last_done;
    if (now > start) fvgl_us_gpu_busy += (unsigned)(now - start);
    fvgl_frames_gpu_done += done - last;
    last = done;
    last_done = now;
  }
  return 0;
}

static void meter_start(void) {
  g_meter_stop = false;
  g_meter_thread = sceKernelCreateThread("fvgl-gpu-meter", gpu_meter, 0x10000100, 0x1000, 0, 0, NULL);
  if (g_meter_thread >= 0) sceKernelStartThread(g_meter_thread, 0, NULL);
}

static void meter_stop(void) {
  if (g_meter_thread < 0) return;
  g_meter_stop = true;
  SceUInt timeout = 50 * 1000;
  sceKernelWaitThreadEnd(g_meter_thread, NULL, &timeout);
  sceKernelDeleteThread(g_meter_thread);
  g_meter_thread = -1;
}

// ---- scenes ----------------------------------------------------------------

void fvgl_scene_begin(void) {
  FvglTexture* target = fvgl_current_target();
  if (fvgl.scene_open) {
    if (fvgl.scene_target == target) return;
    fvgl_scene_end();
  }
  if (g_frame_marked != fvgl.frame) {
    g_frame_marked = fvgl.frame;
    g_frame_first_scene_us[fvgl.frame % 64] = fvgl_now_us();
  }
  // The depth and stencil surface is fixed for the length of a scene: this is
  // the one moment it can be chosen, and fvgl_scene_has_depth answers from it
  // until the scene ends.
  const SceGxmDepthStencilSurface* ds = fvgl_target_depth_stencil();
  const bool has_depth = ds != NULL;
  if (!ds) ds = &fvgl.no_depth;
  int r;
  if (target) {
    if (!fvgl_texture_make_target(target)) {
      fvgl_log("draw into a texture that cannot be a render target");
      return;
    }
    r = sceGxmBeginScene(fvgl.gxm, 0, target->target, NULL, NULL, NULL, &target->surface, ds);
    fvgl.fc[0] = 0.0f;  // gl_FragCoord.y is the row
    fvgl.fc[1] = 1.0f;
  } else {
    FvglDisplayBuffer* b = &fvgl.display[fvgl.back];
    r = sceGxmBeginScene(fvgl.gxm, 0, fvgl.display_target, NULL, NULL, b->sync, &b->surface, ds);
    fvgl.fc[0] = (float)fvgl.height;  // GL's y is the row counted from the bottom
    fvgl.fc[1] = -1.0f;
  }
  if (r < 0) {
    fvgl_log("sceGxmBeginScene: 0x%08X", (unsigned)r);
    return;
  }
  fvgl.scene_open = true;
  fvgl.scene_ds = has_depth ? ds : NULL;
  fvgl.scene_target = target;
  if (target) target->last_frame_used = fvgl.frame;
  fvgl.bound_program = NULL;  // a new scene starts with no programs set
  // A new scene starts with none of the raster state set, whatever the last
  // one had.
  fvgl.raster_dirty = true;
  fvgl_apply_raster();
  apply_region_clip();
  apply_viewport(fvgl.viewport[0], fvgl.viewport[1], fvgl.viewport[2], fvgl.viewport[3]);
}

void fvgl_scene_end(void) {
  if (!fvgl.scene_open) return;
  const int r = sceGxmEndScene(fvgl.gxm, NULL, NULL);
  if (r < 0) fvgl_log("sceGxmEndScene: 0x%08X", (unsigned)r);
  fvgl.scene_open = false;
  fvgl.scene_ds = NULL;
  fvgl.scene_target = NULL;
}

// ---- init and teardown -----------------------------------------------------

static int display_chain_init(int count) {
  fvgl.display_stride = ((unsigned)fvgl.width + 63u) & ~63u;
  const size_t bytes = (size_t)fvgl.display_stride * (size_t)fvgl.height * 4;
  fvgl.display_buffer_count = count;
  for (int i = 0; i < count; i++) {
    FvglDisplayBuffer* b = &fvgl.display[i];
    b->data = fvgl_mem_alloc(FVGL_MEM_CDRAM, bytes, &b->uid);
    if (!b->data) return -1;
    memset(b->data, 0, bytes);
    int r = sceGxmColorSurfaceInit(&b->surface, SCE_GXM_COLOR_FORMAT_A8B8G8R8,
                                   SCE_GXM_COLOR_SURFACE_LINEAR,
                                   SCE_GXM_COLOR_SURFACE_SCALE_NONE,
                                   SCE_GXM_OUTPUT_REGISTER_SIZE_32BIT,
                                   (unsigned)fvgl.width, (unsigned)fvgl.height,
                                   fvgl.display_stride, b->data);
    if (r < 0) {
      fvgl_log("sceGxmColorSurfaceInit %d: 0x%08X", i, (unsigned)r);
      return r;
    }
    r = sceGxmSyncObjectCreate(&b->sync);
    if (r < 0) {
      fvgl_log("sceGxmSyncObjectCreate %d: 0x%08X", i, (unsigned)r);
      return r;
    }
  }
  fvgl.back = 0;
  fvgl.front = count - 1;
  return 0;
}

int fvgl_init(const FvglConfig* config) {
  if (fvgl.up) return 0;
  memset(&fvgl, 0, sizeof fvgl);
  fvgl.width = config && config->width ? config->width : 960;
  fvgl.height = config && config->height ? config->height : 544;
  fvgl.log = config ? config->log : NULL;
  int buffers = config && config->display_buffers ? config->display_buffers : 3;
  if (buffers > FVGL_MAX_DISPLAY_BUFFERS) buffers = FVGL_MAX_DISPLAY_BUFFERS;
  const char* compiler =
      config && config->shacccg_path ? config->shacccg_path : "ur0:data/libshacccg.suprx";
  fvgl.vdm_uid = fvgl.vertex_ring_uid = fvgl.fragment_ring_uid = fvgl.fragment_usse_uid = -1;
  fvgl.patcher_buffer_uid = fvgl.patcher_vertex_usse_uid = fvgl.patcher_fragment_usse_uid = -1;
  fvgl.clear.vertex_uid = fvgl.clear.index_uid = -1;
  fvgl.display_depth.uid = -1;
  for (int i = 0; i < FVGL_MAX_DISPLAY_BUFFERS; i++) fvgl.display[i].uid = -1;

  SceGxmInitializeParams init = {
      .flags = 0,
      .displayQueueMaxPendingCount = (unsigned)(buffers - 1),
      .displayQueueCallback = display_callback,
      .displayQueueCallbackDataSize = sizeof(DisplayCallbackData),
      .parameterBufferSize = SCE_GXM_DEFAULT_PARAMETER_BUFFER_SIZE,
  };
  int r = sceGxmInitialize(&init);
  if (r < 0) {
    fvgl_log("sceGxmInitialize: 0x%08X", (unsigned)r);
    return r;
  }

  // The context and its ring buffers.
  fvgl.host_mem = malloc(SCE_GXM_MINIMUM_CONTEXT_HOST_MEM_SIZE);
  void* vdm = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, SCE_GXM_DEFAULT_VDM_RING_BUFFER_SIZE, &fvgl.vdm_uid);
  void* vertex = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, SCE_GXM_DEFAULT_VERTEX_RING_BUFFER_SIZE, &fvgl.vertex_ring_uid);
  void* fragment = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, SCE_GXM_DEFAULT_FRAGMENT_RING_BUFFER_SIZE, &fvgl.fragment_ring_uid);
  unsigned fragment_usse_offset = 0;
  void* fragment_usse = fvgl_usse_alloc(true, SCE_GXM_DEFAULT_FRAGMENT_USSE_RING_BUFFER_SIZE,
                                        &fragment_usse_offset, &fvgl.fragment_usse_uid);
  if (!fvgl.host_mem || !vdm || !vertex || !fragment || !fragment_usse) goto fail;
  SceGxmContextParams ctx = {
      .hostMem = fvgl.host_mem,
      .hostMemSize = SCE_GXM_MINIMUM_CONTEXT_HOST_MEM_SIZE,
      .vdmRingBufferMem = vdm,
      .vdmRingBufferMemSize = SCE_GXM_DEFAULT_VDM_RING_BUFFER_SIZE,
      .vertexRingBufferMem = vertex,
      .vertexRingBufferMemSize = SCE_GXM_DEFAULT_VERTEX_RING_BUFFER_SIZE,
      .fragmentRingBufferMem = fragment,
      .fragmentRingBufferMemSize = SCE_GXM_DEFAULT_FRAGMENT_RING_BUFFER_SIZE,
      .fragmentUsseRingBufferMem = fragment_usse,
      .fragmentUsseRingBufferMemSize = SCE_GXM_DEFAULT_FRAGMENT_USSE_RING_BUFFER_SIZE,
      .fragmentUsseRingBufferOffset = fragment_usse_offset,
  };
  r = sceGxmCreateContext(&ctx, &fvgl.gxm);
  if (r < 0) {
    fvgl_log("sceGxmCreateContext: 0x%08X", (unsigned)r);
    goto fail;
  }

  // The render target the display buffers are drawn through.
  SceGxmRenderTargetParams target = {
      .flags = 0,
      .width = (uint16_t)fvgl.width,
      .height = (uint16_t)fvgl.height,
      .scenesPerFrame = 1,
      .multisampleMode = SCE_GXM_MULTISAMPLE_NONE,
      .multisampleLocations = 0,
      .driverMemBlock = -1,
  };
  r = sceGxmCreateRenderTarget(&target, &fvgl.display_target);
  if (r < 0) {
    fvgl_log("sceGxmCreateRenderTarget: 0x%08X", (unsigned)r);
    goto fail;
  }
  if (display_chain_init(buffers) < 0) goto fail;
  sceGxmDepthStencilSurfaceInitDisabled(&fvgl.no_depth);

  // The shader patcher, which turns compiled programs into ones bound to a
  // vertex layout and a blend state.
  enum { kPatcherBuffer = 512 * 1024, kPatcherUsse = 256 * 1024 };
  unsigned vertex_usse_offset = 0;
  void* patcher_buffer = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, kPatcherBuffer, &fvgl.patcher_buffer_uid);
  void* patcher_vertex_usse = fvgl_usse_alloc(false, kPatcherUsse, &vertex_usse_offset, &fvgl.patcher_vertex_usse_uid);
  unsigned patcher_fragment_usse_offset = 0;
  void* patcher_fragment_usse = fvgl_usse_alloc(true, kPatcherUsse, &patcher_fragment_usse_offset, &fvgl.patcher_fragment_usse_uid);
  if (!patcher_buffer || !patcher_vertex_usse || !patcher_fragment_usse) goto fail;
  SceGxmShaderPatcherParams patcher = {
      .userData = NULL,
      .hostAllocCallback = patcher_host_alloc,
      .hostFreeCallback = patcher_host_free,
      .bufferAllocCallback = NULL,
      .bufferFreeCallback = NULL,
      .bufferMem = patcher_buffer,
      .bufferMemSize = kPatcherBuffer,
      .vertexUsseAllocCallback = NULL,
      .vertexUsseFreeCallback = NULL,
      .vertexUsseMem = patcher_vertex_usse,
      .vertexUsseMemSize = kPatcherUsse,
      .vertexUsseOffset = vertex_usse_offset,
      .fragmentUsseAllocCallback = NULL,
      .fragmentUsseFreeCallback = NULL,
      .fragmentUsseMem = patcher_fragment_usse,
      .fragmentUsseMemSize = kPatcherUsse,
      .fragmentUsseOffset = patcher_fragment_usse_offset,
  };
  r = sceGxmShaderPatcherCreate(&patcher, &fvgl.patcher);
  if (r < 0) {
    fvgl_log("sceGxmShaderPatcherCreate: 0x%08X", (unsigned)r);
    goto fail;
  }

  r = fvgl_shacc_init(compiler);
  if (r < 0) goto fail;
  fvgl_shader_cache_init(config ? config->shader_cache_dir : NULL);
  if (clear_pipeline_init() < 0) goto fail;
  if (fvgl_blit_init() < 0) goto fail;

  if (fvgl_scratch_init() < 0) goto fail;
  fvgl_draw_init();
  if (fvgl_textures_init() < 0) goto fail;
  // The GPU writes the number of each finished frame here.
  fvgl.frame_done = sceGxmGetNotificationRegion();
  *fvgl.frame_done = 0;
  fvgl.frame = 1;

  // GLES 2.0 initial state.
  fvgl.error = GL_NO_ERROR;
  fvgl.color_mask[0] = fvgl.color_mask[1] = fvgl.color_mask[2] = fvgl.color_mask[3] = GL_TRUE;
  fvgl.scissor_enabled = false;
  fvgl.scissor[0] = 0; fvgl.scissor[1] = 0; fvgl.scissor[2] = fvgl.width; fvgl.scissor[3] = fvgl.height;
  fvgl.viewport[0] = 0; fvgl.viewport[1] = 0; fvgl.viewport[2] = fvgl.width; fvgl.viewport[3] = fvgl.height;
  fvgl.blend.enabled = false;
  fvgl.blend.src_rgb = fvgl.blend.src_alpha = GL_ONE;
  fvgl.blend.dst_rgb = fvgl.blend.dst_alpha = GL_ZERO;
  fvgl.blend.eq_rgb = fvgl.blend.eq_alpha = GL_FUNC_ADD;
  fvgl.front_face = GL_CCW;
  fvgl.depth_mask = GL_TRUE;
  fvgl.line_width = 1.0f;
  fvgl.sample_coverage = 1.0f;
  fvgl.sample_coverage_invert = GL_FALSE;
  fvgl.generate_mipmap_hint = GL_DONT_CARE;
  fvgl.depth_func = GL_LESS;
  fvgl.depth_range[0] = 0.0f;
  fvgl.depth_range[1] = 1.0f;
  fvgl.clear_depth = 1.0f;
  fvgl.clear_stencil = 0;
  fvgl.cull_face = GL_BACK;
  for (int i = 0; i < 2; i++) {
    FvglStencilFace* f = i ? &fvgl.stencil_back : &fvgl.stencil_front;
    f->func = GL_ALWAYS;
    f->ref = 0;
    f->compare_mask = 0xFFFFFFFFu;
    f->write_mask = 0xFFFFFFFFu;
    f->sfail = f->dpfail = f->dppass = GL_KEEP;
  }
  fvgl.raster_dirty = true;
  fvgl.up = true;
  meter_start();
  fvgl_log("up: %dx%d, %d display buffers, stride %u", fvgl.width, fvgl.height, buffers, fvgl.display_stride);
  return 0;

fail:
  fvgl_shutdown();
  return -1;
}

// The shutdown stages, in the log and in a file of their own. The log is the
// app's, and the bridge that takes over afterwards writes the same file, so
// a hang here used to leave nothing behind (the gallery, 2026-09-12).
#define FVGL_SHUTDOWN_FILE "ux0:data/flutter-vita/gles2-shutdown.txt"

static void shutdown_stage(const char* what) {
  static bool started;
  fvgl_log("shutdown: %s", what);
  const SceUID fd = sceIoOpen(FVGL_SHUTDOWN_FILE,
                              SCE_O_WRONLY | SCE_O_CREAT | (started ? SCE_O_APPEND : SCE_O_TRUNC), 0777);
  started = true;
  if (fd < 0) return;
  sceIoWrite(fd, what, strlen(what));
  sceIoWrite(fd, "\n", 1);
  sceIoClose(fd);
}

void fvgl_shutdown(void) {
  char counts[128];
  snprintf(counts, sizeof counts, "begin: %u programs %u textures %u buffers %u framebuffers, frame %u done %u",
           fvgl.programs.count, fvgl.textures.count, fvgl.buffers.count, fvgl.framebuffers.count,
           (unsigned)fvgl.frame, (unsigned)fvgl_gpu_completed_frame());
  shutdown_stage(counts);
  fvgl_set_frame_hook(0, 0);  // the frames still queued go out as they are
  // Down first, then torn down. This runs on whichever thread asked for the
  // exit while the raster thread goes on calling GL between frames: Skia
  // frees what it has not used for a while, and on 2026-09-14 (the
  // gallery's build 29, a 26-minute run) its glDeleteTextures ran into the
  // texture loop below and freed a struct twice, a data abort in free(). The
  // object entry points return at once while `up` is false; the pause lets
  // a call that had already passed that test finish.
  fvgl.up = false;
  sceKernelDelayThread(20 * 1000);
  shutdown_stage("finish");
  meter_stop();
  if (fvgl.gxm) {
    fvgl_scene_end();
    sceGxmFinish(fvgl.gxm);
  }
  shutdown_stage("display queue");
  sceGxmDisplayQueueFinish();
  shutdown_stage("programs");
  if (fvgl.patcher) fvgl_programs_shutdown();
  shutdown_stage("buffers");
  fvgl_buffers_shutdown();
  shutdown_stage("framebuffers and textures");
  fvgl_framebuffers_shutdown();
  fvgl_renderbuffers_shutdown();
  fvgl_depth_stencil_free(&fvgl.display_depth);
  fvgl_textures_shutdown();
  fvgl_draw_shutdown();
  fvgl_blit_shutdown();
  fvgl_scratch_shutdown();
  shutdown_stage("garbage");
  fvgl_collect_garbage(true);
  shutdown_stage("patcher");
  FvglClearPipeline* c = &fvgl.clear;
  if (fvgl.patcher) {
    for (int i = 0; i < 16; i++) {
      if (c->fragment[i]) sceGxmShaderPatcherReleaseFragmentProgram(fvgl.patcher, c->fragment[i]);
    }
    if (c->vertex) sceGxmShaderPatcherReleaseVertexProgram(fvgl.patcher, c->vertex);
    if (c->fragment_id) sceGxmShaderPatcherUnregisterProgram(fvgl.patcher, c->fragment_id);
    if (c->vertex_id) sceGxmShaderPatcherUnregisterProgram(fvgl.patcher, c->vertex_id);
    sceGxmShaderPatcherDestroy(fvgl.patcher);
  }
  free(c->vertex_gxp);
  free(c->fragment_gxp);
  fvgl_mem_free(c->vertex_uid);
  fvgl_mem_free(c->index_uid);
  fvgl_shacc_shutdown();
  shutdown_stage("display and context");
  if (fvgl.dialog_depth) fvgl_mem_free(fvgl.dialog_depth_uid);
  for (int i = 0; i < FVGL_MAX_DISPLAY_BUFFERS; i++) {
    if (fvgl.display[i].sync) sceGxmSyncObjectDestroy(fvgl.display[i].sync);
    fvgl_mem_free(fvgl.display[i].uid);
  }
  if (fvgl.display_target) sceGxmDestroyRenderTarget(fvgl.display_target);
  if (fvgl.gxm) sceGxmDestroyContext(fvgl.gxm);
  fvgl_usse_free(true, fvgl.patcher_fragment_usse_uid);
  fvgl_usse_free(false, fvgl.patcher_vertex_usse_uid);
  fvgl_mem_free(fvgl.patcher_buffer_uid);
  fvgl_usse_free(true, fvgl.fragment_usse_uid);
  fvgl_mem_free(fvgl.fragment_ring_uid);
  fvgl_mem_free(fvgl.vertex_ring_uid);
  fvgl_mem_free(fvgl.vdm_uid);
  free(fvgl.host_mem);
  shutdown_stage("terminate");
  // The notification region goes with sceGxmTerminate; nothing after this
  // point may read it, and fvgl_gpu_completed_frame answers 0 without it.
  fvgl.frame_done = NULL;
  sceGxmTerminate();
  shutdown_stage("down");
  memset(&fvgl, 0, sizeof fvgl);
}

// ---- present ---------------------------------------------------------------

void fvgl_set_common_dialog(int open) { fvgl.dialog_open = open != 0; }

// The shell draws the dialog into the back buffer between our last scene and
// the queue entry, ordered on the same sync object. It asks for a depth
// surface the size of the display; nothing of ours uses it, so it is made
// once, on the first dialog, in whole tiles the way the hardware addresses
// it. Why here and not in the app: the back buffer and its sync object are
// this file's, and the raster thread is the one thread that talks to GXM.
static void dialog_update(FvglDisplayBuffer* back) {
  if (!fvgl.dialog_depth) {
    const unsigned dw = ((unsigned)fvgl.width + SCE_GXM_TILE_SIZEX - 1) & ~(SCE_GXM_TILE_SIZEX - 1);
    const unsigned dh = ((unsigned)fvgl.height + SCE_GXM_TILE_SIZEY - 1) & ~(SCE_GXM_TILE_SIZEY - 1);
    fvgl.dialog_depth = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, (size_t)dw * dh * 4, &fvgl.dialog_depth_uid);
    if (!fvgl.dialog_depth) {
      static bool said;
      if (!said) fvgl_log("common dialog: no memory for a depth surface");
      said = true;
      return;
    }
  }
  SceCommonDialogUpdateParam p;
  memset(&p, 0, sizeof p);
  p.renderTarget.colorFormat = SCE_GXM_COLOR_FORMAT_A8B8G8R8;
  p.renderTarget.surfaceType = SCE_GXM_COLOR_SURFACE_LINEAR;
  p.renderTarget.width = (unsigned)fvgl.width;
  p.renderTarget.height = (unsigned)fvgl.height;
  p.renderTarget.strideInPixels = fvgl.display_stride;
  p.renderTarget.colorSurfaceData = back->data;
  p.renderTarget.depthSurfaceData = fvgl.dialog_depth;
  p.displaySyncObject = back->sync;
  const int r = sceCommonDialogUpdate(&p);
  if (r < 0) {
    static unsigned said;
    if (said++ < 4) fvgl_log("sceCommonDialogUpdate: 0x%08X", (unsigned)r);
  }
}

void fvgl_swap(void) {
  if (!fvgl.up) return;
  // The frame ends on the display, whatever was bound: a frame nobody drew
  // into still has to go through the queue, or the chain and the sync objects
  // fall out of step with each other, and a scene on a texture cannot carry
  // the display's sync object.
  if (fvgl.scene_open && fvgl.scene_target) fvgl_scene_end();
  if (!fvgl.scene_open) {
    const unsigned bound = fvgl.bound_framebuffer;
    fvgl.bound_framebuffer = 0;
    fvgl_scene_begin();
    fvgl.bound_framebuffer = bound;
  }
  // The last scene of the frame carries the notification: when the GPU has
  // run it, everything the frame referenced can go.
  if (fvgl.scene_open) {
    SceGxmNotification done = {.address = fvgl.frame_done, .value = fvgl.frame};
    const int r = sceGxmEndScene(fvgl.gxm, NULL, &done);
    if (r < 0) fvgl_log("sceGxmEndScene: 0x%08X", (unsigned)r);
    fvgl.scene_open = false;
    fvgl.scene_ds = NULL;
    fvgl.scene_target = NULL;
  }
  FvglDisplayBuffer* back = &fvgl.display[fvgl.back];
  FvglDisplayBuffer* front = &fvgl.display[fvgl.front];
  if (fvgl.dialog_open) dialog_update(back);
  sceGxmPadHeartbeat(&back->surface, back->sync);
  const uint64_t t0 = fvgl_now_us();
  DisplayCallbackData data = {.address = back->data, .queued_us = t0};
  const int r = sceGxmDisplayQueueAddEntry(front->sync, back->sync, &data);
  fvgl_us_queue_wait += (unsigned)(fvgl_now_us() - t0);
  if (r < 0) fvgl_log("sceGxmDisplayQueueAddEntry: 0x%08X", (unsigned)r);
  fvgl.front = fvgl.back;
  fvgl.back = (fvgl.back + 1) % fvgl.display_buffer_count;
  fvgl.frame++;
  fvgl_scratch_reset(fvgl.back);
  fvgl_collect_garbage(false);
}

// ---- GL --------------------------------------------------------------------

GL_APICALL void GL_APIENTRY glClearColor(GLfloat r, GLfloat g, GLfloat b, GLfloat a) {
  fvgl.clear_color[0] = r < 0 ? 0 : r > 1 ? 1 : r;
  fvgl.clear_color[1] = g < 0 ? 0 : g > 1 ? 1 : g;
  fvgl.clear_color[2] = b < 0 ? 0 : b > 1 ? 1 : b;
  fvgl.clear_color[3] = a < 0 ? 0 : a > 1 ? 1 : a;
}

GL_APICALL void GL_APIENTRY glColorMask(GLboolean r, GLboolean g, GLboolean b, GLboolean a) {
  fvgl.color_mask[0] = r ? GL_TRUE : GL_FALSE;
  fvgl.color_mask[1] = g ? GL_TRUE : GL_FALSE;
  fvgl.color_mask[2] = b ? GL_TRUE : GL_FALSE;
  fvgl.color_mask[3] = a ? GL_TRUE : GL_FALSE;
}

GL_APICALL void GL_APIENTRY glScissor(GLint x, GLint y, GLsizei w, GLsizei h) {
  if (w < 0 || h < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  fvgl.scissor[0] = x; fvgl.scissor[1] = y; fvgl.scissor[2] = w; fvgl.scissor[3] = h;
  if (fvgl.scene_open) apply_region_clip();
}

GL_APICALL void GL_APIENTRY glViewport(GLint x, GLint y, GLsizei w, GLsizei h) {
  if (w < 0 || h < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  fvgl.viewport[0] = x; fvgl.viewport[1] = y; fvgl.viewport[2] = w; fvgl.viewport[3] = h;
  if (fvgl.scene_open) apply_viewport(x, y, w, h);
}

static bool set_capability(GLenum cap, bool on) {
  switch (cap) {
    case GL_SCISSOR_TEST:
      fvgl.scissor_enabled = on;
      if (fvgl.scene_open) apply_region_clip();
      return true;
    case GL_BLEND: fvgl.blend.enabled = on; return true;
    case GL_CULL_FACE: fvgl.cull_enabled = on; fvgl.raster_dirty = true; return true;
    case GL_DEPTH_TEST:
      fvgl.depth_test_enabled = on;
      fvgl.raster_dirty = true;
      if (on) fvgl_want_display_depth();
      return true;
    case GL_STENCIL_TEST:
      fvgl.stencil_test_enabled = on;
      fvgl.raster_dirty = true;
      if (on) fvgl_want_display_depth();
      return true;
    case GL_POLYGON_OFFSET_FILL: fvgl.polygon_offset_fill = on; fvgl.raster_dirty = true; return true;
    // Dithering is the GPU's own and cannot be turned off per draw; the value
    // is remembered so glIsEnabled answers with it.
    case GL_DITHER: fvgl.dither_enabled = on; return true;
    // Valid, remembered nowhere: no surface here is multisampled.
    case GL_SAMPLE_ALPHA_TO_COVERAGE:
    case GL_SAMPLE_COVERAGE:
      return true;
    default:
      return false;
  }
}

GL_APICALL void GL_APIENTRY glEnable(GLenum cap) {
  if (!set_capability(cap, true)) fvgl_set_error(GL_INVALID_ENUM);
}

GL_APICALL void GL_APIENTRY glDisable(GLenum cap) {
  if (!set_capability(cap, false)) fvgl_set_error(GL_INVALID_ENUM);
}

// The raster state the clear triangle needs: nothing culled, every test
// passing, and a write mask for each buffer the call named. It leaves the GXM
// context disagreeing with the GL state, so the next draw applies it again.
static void apply_clear_raster(bool depth, bool stencil) {
  sceGxmSetCullMode(fvgl.gxm, SCE_GXM_CULL_NONE);
  // Both sides get the same state below, so one side is enough.
  sceGxmSetTwoSidedEnable(fvgl.gxm, SCE_GXM_TWO_SIDED_DISABLED);
  sceGxmSetFrontDepthFunc(fvgl.gxm, SCE_GXM_DEPTH_FUNC_ALWAYS);
  sceGxmSetBackDepthFunc(fvgl.gxm, SCE_GXM_DEPTH_FUNC_ALWAYS);
  const SceGxmDepthWriteMode w = depth ? SCE_GXM_DEPTH_WRITE_ENABLED : SCE_GXM_DEPTH_WRITE_DISABLED;
  sceGxmSetFrontDepthWriteEnable(fvgl.gxm, w);
  sceGxmSetBackDepthWriteEnable(fvgl.gxm, w);
  sceGxmSetFrontDepthBias(fvgl.gxm, 0, 0);
  sceGxmSetBackDepthBias(fvgl.gxm, 0, 0);
  // Both tests pass, so REPLACE runs on every fragment and writes the
  // reference through the write mask -- which is what clearing a stencil to a
  // value under a mask means. GL ES 2.0 names one mask for the operation and
  // this layer takes the front one, as the desktop implementations do.
  const SceGxmStencilOp pass = stencil ? SCE_GXM_STENCIL_OP_REPLACE : SCE_GXM_STENCIL_OP_KEEP;
  const unsigned char write = stencil ? (unsigned char)fvgl.stencil_front.write_mask : 0;
  const unsigned ref = (unsigned)(fvgl.clear_stencil & 0xFF);
  sceGxmSetFrontStencilFunc(fvgl.gxm, SCE_GXM_STENCIL_FUNC_ALWAYS, SCE_GXM_STENCIL_OP_KEEP,
                            SCE_GXM_STENCIL_OP_KEEP, pass, 0xFF, write);
  sceGxmSetBackStencilFunc(fvgl.gxm, SCE_GXM_STENCIL_FUNC_ALWAYS, SCE_GXM_STENCIL_OP_KEEP,
                           SCE_GXM_STENCIL_OP_KEEP, pass, 0xFF, write);
  sceGxmSetFrontStencilRef(fvgl.gxm, ref);
  sceGxmSetBackStencilRef(fvgl.gxm, ref);
  fvgl.raster_dirty = true;
}

GL_APICALL void GL_APIENTRY glClear(GLbitfield mask) {
  if (!fvgl.up) return;
  if (mask & ~(GLbitfield)(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (mask == 0) return;
  // Asking to clear either of them on the display is one of the two things
  // that make its surface appear; enabling a test is the other.
  if (mask & (GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)) fvgl_want_display_depth();
  const unsigned gl_mask = (fvgl.color_mask[0] ? 1u : 0u) | (fvgl.color_mask[1] ? 2u : 0u) |
                           (fvgl.color_mask[2] ? 4u : 0u) | (fvgl.color_mask[3] ? 8u : 0u);
  int x0, y0, x1, y1;
  if (!scissor_rows(&x0, &y0, &x1, &y1)) return;  // the scissor is empty

  fvgl_scene_begin();
  if (!fvgl.scene_open) return;
  const bool have_ds = fvgl.scene_ds != NULL;
  const bool want_color = (mask & GL_COLOR_BUFFER_BIT) && gl_mask != 0;
  const bool want_depth = (mask & GL_DEPTH_BUFFER_BIT) && have_ds && fvgl.depth_mask;
  const bool want_stencil =
      (mask & GL_STENCIL_BUFFER_BIT) && have_ds && (fvgl.stencil_front.write_mask & 0xFFu) != 0;
  if (!want_color && !want_depth && !want_stencil) return;

  // A clear of depth or stencil alone writes no colour, and a fragment
  // program with an empty colour mask is how that is said here.
  SceGxmFragmentProgram* fp = clear_fragment_for_mask(want_color ? gl_mask : 0);
  if (!fp) return;

  // A clear ignores the viewport, and its depth value goes in as clip z, so
  // the z map is the identity rather than glDepthRangef's.
  int tw, th;
  bool flipped;
  fvgl_target_extent(&tw, &th, &flipped);
  apply_viewport_z(0, 0, tw, th, 0.5f, 0.5f);
  apply_clear_raster(want_depth, want_stencil);
  sceGxmSetVertexProgram(fvgl.gxm, fvgl.clear.vertex);
  sceGxmSetFragmentProgram(fvgl.gxm, fp);
  fvgl.bound_program = NULL;
  void* uniforms = NULL;
  sceGxmReserveFragmentDefaultUniformBuffer(fvgl.gxm, &uniforms);
  sceGxmSetUniformDataF(uniforms, fvgl.clear.color_param, 0, 4, fvgl.clear_color);
  const float scissor[4] = {(float)x0, (float)y0, (float)x1, (float)y1};
  sceGxmSetUniformDataF(uniforms, fvgl.clear.scissor_param, 0, 4, scissor);
  void* vertex_uniforms = NULL;
  sceGxmReserveVertexDefaultUniformBuffer(fvgl.gxm, &vertex_uniforms);
  // GL's clear depth is a window value in [0, 1]; the identity map above
  // turns clip z into it as z * 0.5 + 0.5.
  const float clip_z = fvgl.clear_depth * 2.0f - 1.0f;
  sceGxmSetUniformDataF(vertex_uniforms, fvgl.clear.depth_param, 0, 1, &clip_z);
  sceGxmSetVertexStream(fvgl.gxm, 0, fvgl.clear.vertices);
  const int r = sceGxmDraw(fvgl.gxm, SCE_GXM_PRIMITIVE_TRIANGLES, SCE_GXM_INDEX_FORMAT_U16,
                           fvgl.clear.indices, 3);
  if (r < 0) fvgl_log("clear draw: 0x%08X", (unsigned)r);
  apply_viewport(fvgl.viewport[0], fvgl.viewport[1], fvgl.viewport[2], fvgl.viewport[3]);
}

GL_APICALL void GL_APIENTRY glReadPixels(GLint x, GLint y, GLsizei w, GLsizei h, GLenum format,
                                         GLenum type, void* pixels) {
  if (!fvgl.up) return;
  if (format != GL_RGBA || type != GL_UNSIGNED_BYTE) {
    fvgl_set_error(GL_INVALID_ENUM);
    return;
  }
  if (w < 0 || h < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  // Everything queued so far has to land in memory first. A tiled target is
  // read through a linear copy the GPU makes, which lands with the rest.
  FvglTexture* t = fvgl_current_target();
  FvglTexture* copy = NULL;
  if (t && t->tiled) {
    copy = fvgl_texture_linear_copy(t);
    if (!copy) {
      fvgl_set_error(GL_OUT_OF_MEMORY);
      return;
    }
  }
  fvgl_scene_end();
  sceGxmFinish(fvgl.gxm);
  *fvgl.frame_done = fvgl.frame - 1;  // nothing older than this frame is in flight now
  int tw, th;
  bool flipped;
  fvgl_target_extent(&tw, &th, &flipped);
  const FvglTexture* read = copy ? copy : t;
  const uint8_t* src = read ? read->data : fvgl.display[fvgl.back].data;
  const size_t src_stride = read ? read->stride : (size_t)fvgl.display_stride * 4;
  const size_t row_bytes = ((size_t)w * 4 + (size_t)fvgl.pack_alignment - 1) & ~((size_t)fvgl.pack_alignment - 1);
  uint8_t* dst = pixels;
  for (GLsizei row = 0; row < h; row++) {
    const int gy = y + row;  // GL row
    const int sy = flipped ? th - 1 - gy : gy;
    for (GLsizei col = 0; col < w; col++) {
      const int gx = x + col;
      uint8_t* out = dst + (size_t)row * row_bytes + (size_t)col * 4;
      if (gx < 0 || gx >= tw || sy < 0 || sy >= th) {
        out[0] = out[1] = out[2] = out[3] = 0;
        continue;
      }
      // A8B8G8R8 in a little-endian word is R, G, B, A in memory: GL_RGBA.
      memcpy(out, src + (size_t)sy * src_stride + (size_t)gx * 4, 4);
    }
  }
  fvgl_texture_scratch_free(copy);
}

GL_APICALL GLenum GL_APIENTRY glGetError(void) {
  if (!fvgl.up) return GL_NO_ERROR;
  const GLenum e = fvgl.error;
  fvgl.error = GL_NO_ERROR;
  return e;
}

// Skia's GrGLCaps takes RGBA8 as a render target format on ES2 only when this
// is advertised (otherwise the wrapped display FBO is refused and nothing
// draws). Nothing else is advertised: every extension Skia asks for by name
// would send it down a path with calls this layer does not have, and its
// fallbacks for an empty string are all core GLES 2.0.
static const char* const kExtensions[] = {"GL_OES_rgb8_rgba8"};

GL_APICALL const GLubyte* GL_APIENTRY glGetString(GLenum name) {
  switch (name) {
    case GL_VENDOR: return (const GLubyte*)"flutter-vita";
    case GL_RENDERER: return (const GLubyte*)"fvita_gles2 over sceGxm";
    case GL_VERSION: return (const GLubyte*)"OpenGL ES 2.0 fvita_gles2";
    case GL_SHADING_LANGUAGE_VERSION: return (const GLubyte*)"OpenGL ES GLSL ES 1.00";
    case GL_EXTENSIONS: return (const GLubyte*)kExtensions[0];
    default:
      fvgl_set_error(GL_INVALID_ENUM);
      return NULL;
  }
}

// The indexed form. It belongs to GLES 3.0 and Skia only calls it when the
// version says 3.0, which this never does; it is here so the name in the proc
// table answers with the same list glGetString gives rather than recording a
// gap that is not one.
GL_APICALL const GLubyte* GL_APIENTRY glGetStringi(GLenum name, GLuint index) {
  if (name != GL_EXTENSIONS) {
    fvgl_set_error(GL_INVALID_ENUM);
    return NULL;
  }
  if (index >= sizeof kExtensions / sizeof kExtensions[0]) {
    fvgl_set_error(GL_INVALID_VALUE);
    return NULL;
  }
  return (const GLubyte*)kExtensions[index];
}

// There is no EGL on this console: the embedder owns the display and the
// swap, and fvgl_init takes the place of eglInitialize. Skia's GL interface
// asks for the EGL extension string before it decides anything, and an empty
// string is the true answer -- no EGL extension is present. The other three
// names say what is behind the interface, for a log that prints them.
GL_APICALL const char* GL_APIENTRY eglQueryString(void* display, int name) {
  (void)display;
  switch (name) {
    case 0x3053: return "flutter-vita";       // EGL_VENDOR
    case 0x3054: return "1.4 fvita_gles2";    // EGL_VERSION
    case 0x3055: return "";                   // EGL_EXTENSIONS
    case 0x308D: return "OpenGL_ES";          // EGL_CLIENT_APIS
    default: return NULL;
  }
}
