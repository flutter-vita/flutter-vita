// The fvita_gles2 milestone tests. Each one draws something whose pixels are
// known in advance, reads them back through glReadPixels, writes a report and
// the raw frame to ux0:data/flutter-vita, and hands the console back to the
// receiver so both can be pulled with `get`.
//
//   M0  clear, scissor, present: our own sceGxm context on the screen
//
// A test runs for a few seconds so the frame is also visible on the panel.
#include <GLES2/gl2.h>
#include <fvgl.h>
#include <psp2/appmgr.h>
#include <psp2/io/dirent.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DIR "ux0:data/flutter-vita/"
#define RECEIVER "FVTA00001"

static SceUID g_report = -1;

static void say(const char* line) {
  if (g_report < 0) return;
  sceIoWrite(g_report, line, strlen(line));
  sceIoWrite(g_report, "\n", 1);
}

static void sayf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void sayf(const char* fmt, ...) {
  char line[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  say(line);
}

static void hand_back(void) {
  if (g_report >= 0) sceIoClose(g_report);
  fvgl_shutdown();
  sceAppMgrLaunchAppByUri(0xFFFFF, "psgm:play?titleid=" RECEIVER);
  sceKernelExitProcess(0);
}

// ---- M0 --------------------------------------------------------------------

typedef struct Expect {
  int x, y;  // GL window coordinates
  unsigned char r, g, b;
  const char* what;
} Expect;

static void m0_frame(void) {
  glDisable(GL_SCISSOR_TEST);
  glClearColor(0.10f, 0.25f, 0.80f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  // Bottom-left quadrant, tile aligned in x, not in y (272 = 8.5 tiles).
  glEnable(GL_SCISSOR_TEST);
  glScissor(0, 0, 480, 272);
  glClearColor(1.0f, 0.5f, 0.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  // A small rectangle aligned to nothing.
  glScissor(600, 300, 100, 50);
  glClearColor(0.0f, 1.0f, 0.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  glDisable(GL_SCISSOR_TEST);
}

static int m0(void) {
  static const Expect expect[] = {
      {10, 10, 255, 128, 0, "orange, bottom-left quadrant"},
      {479, 271, 255, 128, 0, "orange, its top-right pixel"},
      {480, 271, 26, 64, 204, "blue, one pixel right of it"},
      {479, 272, 26, 64, 204, "blue, one pixel above it"},
      {950, 534, 26, 64, 204, "blue, top-right of the screen"},
      {600, 300, 0, 255, 0, "green, rectangle's bottom-left"},
      {699, 349, 0, 255, 0, "green, rectangle's top-right"},
      {700, 349, 26, 64, 204, "blue, right of the rectangle"},
      {699, 350, 26, 64, 204, "blue, above the rectangle"},
      {599, 300, 26, 64, 204, "blue, left of the rectangle"},
  };
  for (int frame = 0; frame < 180; frame++) {
    m0_frame();
    fvgl_swap();
  }
  // One more frame, read back before it is presented.
  m0_frame();
  const int w = 960, h = 544;
  unsigned char* pixels = malloc((size_t)w * h * 4);
  glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
  const GLenum err = glGetError();
  sayf("m0 glGetError 0x%04X", err);
  const SceUID f = sceIoOpen(DIR "gles2-m0.rgba", SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (f >= 0) {
    sceIoWrite(f, pixels, (SceSize)(w * h * 4));
    sceIoClose(f);
  }
  int failed = 0;
  for (size_t i = 0; i < sizeof expect / sizeof expect[0]; i++) {
    const Expect* e = &expect[i];
    const unsigned char* p = pixels + ((size_t)e->y * w + e->x) * 4;
    const int ok = abs(p[0] - e->r) <= 2 && abs(p[1] - e->g) <= 2 && abs(p[2] - e->b) <= 2;
    sayf("m0 %s (%d,%d) got %3u %3u %3u want %3u %3u %3u  %s", ok ? "ok  " : "FAIL",
         e->x, e->y, p[0], p[1], p[2], e->r, e->g, e->b, e->what);
    failed += !ok;
  }
  free(pixels);
  fvgl_swap();
  sayf("m0 %s: %d of %u checks failed", failed ? "FAILED" : "PASSED", failed,
       (unsigned)(sizeof expect / sizeof expect[0]));
  return failed;
}

int main(void) {
  sceIoMkdir(DIR, 0777);
  g_report = sceIoOpen(DIR "gles2-test.txt", SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  say("fvita_gles2 test");
  FvglConfig config;
  memset(&config, 0, sizeof config);
  config.log = say;
  const int r = fvgl_init(&config);
  sayf("fvgl_init %d", r);
  if (r == 0) m0();
  // A moment on screen so the result is also visible, then back.
  sceKernelDelayThread(1500 * 1000);
  hand_back();
  return 0;
}
