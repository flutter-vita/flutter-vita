// A copy from the current target into a texture, done by the GPU.
//
// glCopyTexSubImage2D is how Skia takes the backdrop for a blur: the pixels
// under a layer, out of the frame being drawn, into a texture it then
// downsamples. Done on the CPU that is a sceGxmFinish (the source is not
// rendered until the GPU is done with everything queued) and a loop over the
// region, and the gallery's blur_backdrop scene paid 110 ms a frame for it
// (docs/results/parity-2026-09-13.md). Done here it is one more scene in
// the same queue: the source's scene ends, a scene on the destination draws
// a quad sampling the source, and the frame goes on. The GPU orders the
// scenes; nobody waits.
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

static const char kBlitVertexCg[] =
    "void main(float2 aPosition, float2 aTexCoord,\n"
    "          float4 out vPosition : POSITION, float2 out vTexCoord : TEXCOORD0) {\n"
    "  vPosition = float4(aPosition, 1.0f, 1.0f);\n"
    "  vTexCoord = aTexCoord;\n"
    "}\n";

static const char kBlitFragmentCg[] =
    "uniform sampler2D uSource;\n"
    "float4 main(float2 vTexCoord : TEXCOORD0) : COLOR {\n"
    "  return tex2D(uSource, vTexCoord);\n"
    "}\n";

static struct {
  SceGxmProgram* vertex_gxp;
  SceGxmProgram* fragment_gxp;
  SceGxmShaderPatcherId vertex_id, fragment_id;
  SceGxmVertexProgram* vertex;
  SceGxmFragmentProgram* fragment;
  unsigned sampler_index;
  SceUID index_uid;
  uint16_t* indices;  // two triangles over a quad
  bool up;
} g_blit;

int fvgl_blit_init(void) {
  char log[1024];
  g_blit.index_uid = -1;
  g_blit.vertex_gxp = fvgl_shacc_compile(kBlitVertexCg, false, log, sizeof log);
  if (!g_blit.vertex_gxp) {
    fvgl_log("blit vertex shader: %s", log);
    return -1;
  }
  g_blit.fragment_gxp = fvgl_shacc_compile(kBlitFragmentCg, true, log, sizeof log);
  if (!g_blit.fragment_gxp) {
    fvgl_log("blit fragment shader: %s", log);
    return -1;
  }
  int r = sceGxmShaderPatcherRegisterProgram(fvgl.patcher, g_blit.vertex_gxp, &g_blit.vertex_id);
  if (r < 0) return r;
  r = sceGxmShaderPatcherRegisterProgram(fvgl.patcher, g_blit.fragment_gxp, &g_blit.fragment_id);
  if (r < 0) return r;
  const SceGxmProgramParameter* position = sceGxmProgramFindParameterByName(g_blit.vertex_gxp, "aPosition");
  const SceGxmProgramParameter* texcoord = sceGxmProgramFindParameterByName(g_blit.vertex_gxp, "aTexCoord");
  const SceGxmProgramParameter* source = sceGxmProgramFindParameterByName(g_blit.fragment_gxp, "uSource");
  if (!position || !texcoord || !source) {
    fvgl_log("blit shaders compiled without their parameters");
    return -1;
  }
  g_blit.sampler_index = sceGxmProgramParameterGetResourceIndex(source);
  const SceGxmVertexAttribute attributes[2] = {
      {.streamIndex = 0, .offset = 0, .format = SCE_GXM_ATTRIBUTE_FORMAT_F32, .componentCount = 2,
       .regIndex = (uint16_t)sceGxmProgramParameterGetResourceIndex(position)},
      {.streamIndex = 0, .offset = 2 * sizeof(float), .format = SCE_GXM_ATTRIBUTE_FORMAT_F32, .componentCount = 2,
       .regIndex = (uint16_t)sceGxmProgramParameterGetResourceIndex(texcoord)},
  };
  const SceGxmVertexStream stream = {.stride = 4 * sizeof(float), .indexSource = SCE_GXM_INDEX_SOURCE_INDEX_16BIT};
  r = sceGxmShaderPatcherCreateVertexProgram(fvgl.patcher, g_blit.vertex_id, attributes, 2, &stream, 1,
                                             &g_blit.vertex);
  if (r < 0) {
    fvgl_log("blit vertex program: 0x%08X", (unsigned)r);
    return r;
  }
  SceGxmBlendInfo blend;
  memset(&blend, 0, sizeof blend);
  blend.colorMask = SCE_GXM_COLOR_MASK_ALL;
  blend.colorFunc = SCE_GXM_BLEND_FUNC_NONE;
  blend.alphaFunc = SCE_GXM_BLEND_FUNC_NONE;
  blend.colorSrc = SCE_GXM_BLEND_FACTOR_ONE;
  blend.colorDst = SCE_GXM_BLEND_FACTOR_ZERO;
  blend.alphaSrc = SCE_GXM_BLEND_FACTOR_ONE;
  blend.alphaDst = SCE_GXM_BLEND_FACTOR_ZERO;
  r = sceGxmShaderPatcherCreateFragmentProgram(fvgl.patcher, g_blit.fragment_id,
                                               SCE_GXM_OUTPUT_REGISTER_FORMAT_UCHAR4, SCE_GXM_MULTISAMPLE_NONE,
                                               &blend, g_blit.vertex_gxp, &g_blit.fragment);
  if (r < 0) {
    fvgl_log("blit fragment program: 0x%08X", (unsigned)r);
    return r;
  }
  g_blit.indices = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, 6 * sizeof(uint16_t), &g_blit.index_uid);
  if (!g_blit.indices) return -1;
  const uint16_t quad[6] = {0, 1, 2, 2, 1, 3};
  memcpy(g_blit.indices, quad, sizeof quad);
  g_blit.up = true;
  return 0;
}

void fvgl_blit_shutdown(void) {
  if (g_blit.fragment) sceGxmShaderPatcherReleaseFragmentProgram(fvgl.patcher, g_blit.fragment);
  if (g_blit.vertex) sceGxmShaderPatcherReleaseVertexProgram(fvgl.patcher, g_blit.vertex);
  if (g_blit.fragment_id) sceGxmShaderPatcherUnregisterProgram(fvgl.patcher, g_blit.fragment_id);
  if (g_blit.vertex_id) sceGxmShaderPatcherUnregisterProgram(fvgl.patcher, g_blit.vertex_id);
  fvgl_mem_free(g_blit.index_uid);
  free(g_blit.vertex_gxp);
  free(g_blit.fragment_gxp);
  memset(&g_blit, 0, sizeof g_blit);
  g_blit.index_uid = -1;
}

// Copies the GL rectangle (x, y, w, h) of the current target into rows
// yoffset.. of `dst`, columns xoffset... `dst` is RGBA8 with storage and is
// not the current target. Returns false when the GPU path is not available
// and the caller has to do it on the CPU.
bool fvgl_blit_from_target(FvglTexture* dst, int xoffset, int yoffset, int x, int y, int w, int h) {
  if (!g_blit.up || !fvgl_texture_make_target(dst)) return false;
  FvglTexture* from = fvgl_current_target();
  int fw, fh;
  bool flipped;
  fvgl_target_extent(&fw, &fh, &flipped);

  // The source, as a texture. A texture target already is one; the display's
  // back buffer has the same layout and gets a descriptor of its own here.
  SceGxmTexture source;
  if (from) {
    source = from->gxm;
  } else {
    const FvglDisplayBuffer* b = &fvgl.display[fvgl.back];
    const int r = sceGxmTextureInitLinearStrided(&source, b->data, SCE_GXM_TEXTURE_FORMAT_U8U8U8U8_ABGR,
                                                 (unsigned)fw, (unsigned)fh, fvgl.display_stride * 4);
    if (r < 0) {
      fvgl_log("blit: display as texture: 0x%08X", (unsigned)r);
      return false;
    }
  }
  sceGxmTextureSetMagFilter(&source, SCE_GXM_TEXTURE_FILTER_POINT);
  sceGxmTextureSetUAddrMode(&source, SCE_GXM_TEXTURE_ADDR_CLAMP);
  sceGxmTextureSetVAddrMode(&source, SCE_GXM_TEXTURE_ADDR_CLAMP);

  // The quad: destination pixels in the target's clip space (row 0 at NDC
  // y = -1 on a texture target), source texels as texture coordinates. On
  // the display GL's row y counts from the bottom, and v from the top.
  float* v = fvgl_scratch_alloc(4 * 4 * sizeof(float), 16);
  if (!v) return false;
  const float tw = (float)dst->width, th = (float)dst->height;
  const float x0 = (float)xoffset / tw * 2.f - 1.f, x1 = (float)(xoffset + w) / tw * 2.f - 1.f;
  const float y0 = (float)yoffset / th * 2.f - 1.f, y1 = (float)(yoffset + h) / th * 2.f - 1.f;
  const float u0 = (float)x / (float)fw, u1 = (float)(x + w) / (float)fw;
  const float v0 = flipped ? (float)(fh - y) / (float)fh : (float)y / (float)fh;
  const float v1 = flipped ? (float)(fh - y - h) / (float)fh : (float)(y + h) / (float)fh;
  const float quad[16] = {x0, y0, u0, v0, x1, y0, u1, v0, x0, y1, u0, v1, x1, y1, u1, v1};
  memcpy(v, quad, sizeof quad);

  // Everything drawn so far lands first.
  fvgl_scene_end();
  int r = sceGxmBeginScene(fvgl.gxm, 0, dst->target, NULL, NULL, NULL, &dst->surface, &fvgl.no_depth);
  if (r < 0) {
    fvgl_log("blit scene: 0x%08X", (unsigned)r);
    return false;
  }
  sceGxmSetFrontDepthFunc(fvgl.gxm, SCE_GXM_DEPTH_FUNC_ALWAYS);
  sceGxmSetBackDepthFunc(fvgl.gxm, SCE_GXM_DEPTH_FUNC_ALWAYS);
  sceGxmSetFrontDepthWriteEnable(fvgl.gxm, SCE_GXM_DEPTH_WRITE_DISABLED);
  sceGxmSetBackDepthWriteEnable(fvgl.gxm, SCE_GXM_DEPTH_WRITE_DISABLED);
  sceGxmSetCullMode(fvgl.gxm, SCE_GXM_CULL_NONE);
  sceGxmSetRegionClip(fvgl.gxm, SCE_GXM_REGION_CLIP_NONE, 0, 0, 0, 0);
  sceGxmSetViewport(fvgl.gxm, tw * 0.5f, tw * 0.5f, th * 0.5f, th * 0.5f, 0.5f, 0.5f);
  sceGxmSetVertexProgram(fvgl.gxm, g_blit.vertex);
  sceGxmSetFragmentProgram(fvgl.gxm, g_blit.fragment);
  r = sceGxmSetFragmentTexture(fvgl.gxm, g_blit.sampler_index, &source);
  if (r < 0) fvgl_log("blit source texture: 0x%08X", (unsigned)r);
  sceGxmSetVertexStream(fvgl.gxm, 0, v);
  r = sceGxmDraw(fvgl.gxm, SCE_GXM_PRIMITIVE_TRIANGLES, SCE_GXM_INDEX_FORMAT_U16, g_blit.indices, 6);
  if (r < 0) fvgl_log("blit draw: 0x%08X", (unsigned)r);
  r = sceGxmEndScene(fvgl.gxm, NULL, NULL);
  if (r < 0) fvgl_log("blit end scene: 0x%08X", (unsigned)r);
  // The next GL draw reopens its own scene, with its own state.
  fvgl.bound_program = NULL;
  dst->last_frame_used = fvgl.frame;
  fvgl_blits++;
  return true;
}

unsigned fvgl_blits;
