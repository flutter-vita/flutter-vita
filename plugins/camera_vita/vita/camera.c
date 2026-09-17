// camera on the Vita: the two cameras through SceCamera.
//
// A session per camera (0 front, 1 back): `open {which, width, height}`
// starts the camera into one ABGR frame buffer, `frame {id}` copies the
// frame there now into the reply as base64 RGBA (sceCameraRead mode 1
// returns the frame there is, it does not wait for a new one), `close {id}`
// stops it. `list` names the cameras the console has.
//
// The frame buffer is a physically contiguous memblock: the camera writes
// through the DMA engine, and a plain user block made sceCameraStart
// answer 0x80024003 (gallery build 30). The camera keeps writing while
// `frame` copies, so a frame can be two frames; a preview does not mind.
//
// The exposure takes most of a second to settle from the black the sensor
// starts at; the first frames of a session are dark.
#include <fvita_plugin.h>

#include <psp2/camera.h>
#include <psp2/kernel/sysmem.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct Session {
  int open;
  int w, h;
  SceUID block;
  void* base;
  uint64_t last_frame;
} Session;

static Session g_cam[2];

static int resolution_for(int w, int h) {
  if (w == 640 && h == 480) return SCE_CAMERA_RESOLUTION_640_480;
  if (w == 640 && h == 360) return SCE_CAMERA_RESOLUTION_640_360;
  if (w == 480 && h == 272) return SCE_CAMERA_RESOLUTION_480_272;
  if (w == 352 && h == 288) return SCE_CAMERA_RESOLUTION_352_288;
  if (w == 320 && h == 240) return SCE_CAMERA_RESOLUTION_320_240;
  if (w == 176 && h == 144) return SCE_CAMERA_RESOLUTION_176_144;
  if (w == 160 && h == 120) return SCE_CAMERA_RESOLUTION_160_120;
  return 0;
}

static int cam_close(int which) {
  Session* s = &g_cam[which];
  if (!s->open) return 0;
  sceCameraStop(which);
  sceCameraClose(which);
  sceKernelFreeMemBlock(s->block);
  memset(s, 0, sizeof *s);
  return 0;
}

static int cam_open(int which, int w, int h, char* out, size_t cap) {
  if (which < 0 || which > 1) return fvita_reply_err(out, cap, "args", "which is 0 or 1", 0);
  const int res = resolution_for(w, h);
  if (res == 0) return fvita_reply_err(out, cap, "args", "no such resolution", 0);
  cam_close(which);
  Session* s = &g_cam[which];
  const SceSize bytes = (SceSize)w * (SceSize)h * 4;
  s->block = sceKernelAllocMemBlock("fvita-camera", SCE_KERNEL_MEMBLOCK_TYPE_USER_MAIN_PHYCONT_NC_RW,
                                    (bytes + 0xFFFFF) & ~0xFFFFFu, NULL);
  if (s->block < 0) return fvita_reply_err(out, cap, "failed", "sceKernelAllocMemBlock", s->block);
  sceKernelGetMemBlockBase(s->block, &s->base);
  memset(s->base, 0, bytes);
  SceCameraInfo info;
  memset(&info, 0, sizeof info);
  info.size = sizeof info;
  info.priority = SCE_CAMERA_PRIORITY_SHARE;
  info.format = SCE_CAMERA_FORMAT_ABGR;
  info.resolution = (uint16_t)res;
  info.framerate = SCE_CAMERA_FRAMERATE_30_FPS;
  info.width = (uint16_t)w;
  info.height = (uint16_t)h;
  info.range = 1;
  info.sizeIBase = bytes;
  info.pIBase = s->base;
  int r = sceCameraOpen(which, &info);
  if (r < 0) {
    sceKernelFreeMemBlock(s->block);
    memset(s, 0, sizeof *s);
    return fvita_reply_err(out, cap, "failed", "sceCameraOpen", r);
  }
  r = sceCameraStart(which);
  if (r < 0) {
    sceCameraClose(which);
    sceKernelFreeMemBlock(s->block);
    memset(s, 0, sizeof *s);
    return fvita_reply_err(out, cap, "failed", "sceCameraStart", r);
  }
  s->open = 1;
  s->w = w;
  s->h = h;
  fvita_log("camera", "%d: open %dx%d", which, w, h);
  return fvita_reply_ok(out, cap, "{\"id\":%d,\"width\":%d,\"height\":%d}", which, w, h);
}

static int cam_frame(int which, char* out, size_t cap) {
  if (which < 0 || which > 1 || !g_cam[which].open) return fvita_reply_err(out, cap, "state", "camera not open", 0);
  Session* s = &g_cam[which];
  SceCameraRead rd;
  memset(&rd, 0, sizeof rd);
  rd.size = sizeof rd;
  rd.mode = 1;
  const int r = sceCameraRead(which, &rd);
  if (r < 0) return fvita_reply_err(out, cap, "failed", "sceCameraRead", r);
  const int fresh = rd.frame != s->last_frame;
  s->last_frame = rd.frame;
  const size_t bytes = (size_t)s->w * (size_t)s->h * 4;
  const size_t need = 4 * ((bytes + 2) / 3) + 128;
  if (need > cap) return fvita_reply_err(out, cap, "failed", "the reply buffer is smaller than a frame", 0);
  int n = snprintf(out, cap, "[{\"frame\":%llu,\"fresh\":%s,\"width\":%d,\"height\":%d,\"rgba\":\"",
                   (unsigned long long)rd.frame, fresh ? "true" : "false", s->w, s->h);
  n += (int)fvita_base64_encode(s->base, bytes, out + n);
  n += snprintf(out + n, cap - (size_t)n, "\"}]");
  return n;
}

static int handle(const char* method, const char* body, size_t len, char* out, size_t cap) {
  if (strcmp(method, "list") == 0) {
    // The PS TV has no cameras: sceCameraOpen fails there, and this list
    // is honest about it before an app tries.
    if (sceKernelGetModel() == 0x20000) return fvita_reply_ok(out, cap, "[]");
    return fvita_reply_ok(out, cap, "[{\"which\":0,\"name\":\"front\"},{\"which\":1,\"name\":\"back\"}]");
  }
  if (strcmp(method, "open") == 0) {
    return cam_open(fvita_json_int(body, len, "which", 0), fvita_json_int(body, len, "width", 320),
                    fvita_json_int(body, len, "height", 240), out, cap);
  }
  if (strcmp(method, "frame") == 0) return cam_frame(fvita_json_int(body, len, "id", 0), out, cap);
  if (strcmp(method, "close") == 0) {
    cam_close(fvita_json_int(body, len, "id", 0) & 1);
    return fvita_reply_ok(out, cap, "null");
  }
  return fvita_reply_err(out, cap, "unknown", method, 0);
}

__attribute__((constructor)) static void reg(void) {
  fvita_channel_register("vita/camera", handle);
  fvita_channel_reply_cap("vita/camera", 2 * 1024 * 1024);  // a 640x480 frame in base64 is 1.6 MB
}
