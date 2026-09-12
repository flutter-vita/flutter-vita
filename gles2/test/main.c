// The fvita_gles2 milestone tests. Each one draws something whose pixels are
// known in advance, reads them back through glReadPixels, writes a report and
// the raw frame to ux0:data/flutter-vita, and hands the console back to the
// receiver so both can be pulled with `get`.
//
//   M0  clear, scissor, present: our own sceGxm context on the screen
//   M1  two triangles from GLSL: translator, link, uniforms (a mat3 among
//       them), VBO and client arrays, glDrawArrays and glDrawElements, blend,
//       gl_FragCoord the way Skia uses it
//   M2  every shader in gles2/corpus through the translator and the
//       console's Cg compiler
//
// A test runs for a few seconds so the frame is also visible on the panel.
#include <GLES2/gl2.h>
#include <fvgl.h>
#include <psp2/appmgr.h>
#include <psp2/io/dirent.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/io/dirent.h>
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

// ---- M1 --------------------------------------------------------------------

static const char kM1Vertex[] =
    "#version 100\n"
    "precision mediump float;\n"
    "uniform highp mat3 uXf;\n"
    "uniform highp vec4 uAdjust;\n"
    "attribute highp vec2 aPos;\n"
    "attribute mediump vec4 aColor;\n"
    "varying mediump vec4 vColor;\n"
    "void main() {\n"
    "  vColor = aColor;\n"
    "  highp vec3 p = uXf * vec3(aPos, 1.0);\n"
    "  gl_Position = vec4(p.xy, 0.0, 1.0);\n"
    "  gl_Position = vec4(gl_Position.xy * uAdjust.xz + gl_Position.ww * uAdjust.yw, 0.0, gl_Position.w);\n"
    "}\n";

static const char kM1Fragment[] =
    "#version 100\n"
    "precision mediump float;\n"
    "uniform mediump vec4 uTint;\n"
    "uniform highp vec2 u_skRTFlip;\n"
    "varying mediump vec4 vColor;\n"
    "void main() {\n"
    "  highp vec4 sk_FragCoord = vec4(gl_FragCoord.x, u_skRTFlip.x + u_skRTFlip.y * gl_FragCoord.y, gl_FragCoord.z, gl_FragCoord.w);\n"
    "  mediump float band = mod(floor(sk_FragCoord.y / 32.0), 2.0);\n"
    "  gl_FragColor = vColor * uTint * mix(1.0, 0.5, band);\n"
    "}\n";

static GLuint m1_shader(GLenum type, const char* src) {
  const GLuint s = glCreateShader(type);
  glShaderSource(s, 1, &src, NULL);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[512];
    glGetShaderInfoLog(s, sizeof log, NULL, log);
    sayf("m1 shader %s did not compile: %s", type == GL_VERTEX_SHADER ? "vertex" : "fragment", log);
  }
  return s;
}

static int m1(void) {
  glClearColor(0, 0, 0, 1);
  glDisable(GL_SCISSOR_TEST);

  const GLuint vs = m1_shader(GL_VERTEX_SHADER, kM1Vertex);
  const GLuint fs = m1_shader(GL_FRAGMENT_SHADER, kM1Fragment);
  const GLuint prog = glCreateProgram();
  glAttachShader(prog, vs);
  glAttachShader(prog, fs);
  glBindAttribLocation(prog, 3, "aPos");
  glBindAttribLocation(prog, 1, "aColor");
  glLinkProgram(prog);
  GLint linked = 0;
  glGetProgramiv(prog, GL_LINK_STATUS, &linked);
  if (!linked) {
    char log[512];
    glGetProgramInfoLog(prog, sizeof log, NULL, log);
    sayf("m1 link failed: %s", log);
    return 1;
  }
  sayf("m1 linked; aPos at %d, aColor at %d, uXf %d uAdjust %d uTint %d u_skRTFlip %d",
       glGetAttribLocation(prog, "aPos"), glGetAttribLocation(prog, "aColor"), glGetUniformLocation(prog, "uXf"),
       glGetUniformLocation(prog, "uAdjust"), glGetUniformLocation(prog, "uTint"), glGetUniformLocation(prog, "u_skRTFlip"));
  glUseProgram(prog);

  // Triangle A: a VBO, interleaved position and colour, red, drawn with a
  // translation of +0.5 in x through the mat3 (GLSL column-major layout).
  const float a[] = {
      -0.9f, -0.9f, 1, 0, 0, 1,
      -0.1f, -0.9f, 1, 0, 0, 1,
      -0.9f, -0.1f, 1, 0, 0, 1,
  };
  GLuint vbo = 0;
  glGenBuffers(1, &vbo);
  glBindBuffer(GL_ARRAY_BUFFER, vbo);
  glBufferData(GL_ARRAY_BUFFER, sizeof a, NULL, GL_DYNAMIC_DRAW);
  glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof a, a);
  glEnableVertexAttribArray(3);
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(3, 2, GL_FLOAT, GL_FALSE, 24, (const void*)0);
  glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, 24, (const void*)8);
  const float translate[9] = {1, 0, 0, 0, 1, 0, 0.5f, 0, 1};
  const float identity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
  glUniformMatrix3fv(glGetUniformLocation(prog, "uXf"), 1, GL_FALSE, translate);
  glUniform4f(glGetUniformLocation(prog, "uAdjust"), 1, 0, 1, 0);
  glUniform4f(glGetUniformLocation(prog, "uTint"), 1, 1, 1, 1);
  glUniform2f(glGetUniformLocation(prog, "u_skRTFlip"), 544, -1);

  // Triangle B: client-side arrays and client-side indices, a quad, blue at
  // half alpha over A, identity matrix.
  const float b_pos[] = {-0.6f, -0.45f, 0.05f, -0.45f, 0.05f, 0.1f, -0.6f, 0.1f};
  const float b_col[] = {0, 0, 1, 0.5f, 0, 0, 1, 0.5f, 0, 0, 1, 0.5f, 0, 0, 1, 0.5f};
  const unsigned short b_idx[] = {0, 1, 2, 0, 2, 3};

  for (int frame = 0; frame < 181; frame++) {
    glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_BLEND);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glVertexAttribPointer(3, 2, GL_FLOAT, GL_FALSE, 24, (const void*)0);
    glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, 24, (const void*)8);
    glUniformMatrix3fv(glGetUniformLocation(prog, "uXf"), 1, GL_FALSE, translate);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glVertexAttribPointer(3, 2, GL_FLOAT, GL_FALSE, 0, b_pos);
    glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, 0, b_col);
    glUniformMatrix3fv(glGetUniformLocation(prog, "uXf"), 1, GL_FALSE, identity);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, b_idx);
    if (frame < 180) fvgl_swap();
  }

  static const Expect expect[] = {
      {520, 80, 255, 0, 0, "A alone, band 0: red"},
      {300, 200, 128, 0, 128, "B over A, band 0"},
      {600, 40, 128, 0, 0, "A alone, band 1: half red"},
      {640, 100, 0, 0, 0, "outside both: black"},
      {300, 320, 0, 0, 0, "above B, left of A's edge: black"},
      {450, 250, 0, 0, 32, "B alone, band 1: quarter blue"},
      {300, 160, 96, 0, 32, "B over A, band 1"},
      {250, 200, 0, 0, 128, "B alone, band 0: half blue"},
  };
  const int w = 960, h = 544;
  unsigned char* pixels = malloc((size_t)w * h * 4);
  glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
  const GLenum err = glGetError();
  sayf("m1 glGetError 0x%04X", err);
  const SceUID f = sceIoOpen(DIR "gles2-m1.rgba", SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (f >= 0) {
    sceIoWrite(f, pixels, (SceSize)(w * h * 4));
    sceIoClose(f);
  }
  int failed = 0;
  for (size_t i = 0; i < sizeof expect / sizeof expect[0]; i++) {
    const Expect* e = &expect[i];
    const unsigned char* px = pixels + ((size_t)e->y * w + e->x) * 4;
    const int ok = abs(px[0] - e->r) <= 3 && abs(px[1] - e->g) <= 3 && abs(px[2] - e->b) <= 3;
    sayf("m1 %s (%d,%d) got %3u %3u %3u want %3u %3u %3u  %s", ok ? "ok  " : "FAIL",
         e->x, e->y, px[0], px[1], px[2], e->r, e->g, e->b, e->what);
    failed += !ok;
  }
  free(pixels);
  fvgl_swap();
  glDeleteBuffers(1, &vbo);
  glDeleteProgram(prog);
  glDeleteShader(vs);
  glDeleteShader(fs);
  sayf("m1 %s: %d of %u checks failed", failed ? "FAILED" : "PASSED", failed,
       (unsigned)(sizeof expect / sizeof expect[0]));
  return failed;
}

// ---- M2 --------------------------------------------------------------------

static char* read_file(const char* path, unsigned* size) {
  const SceUID fd = sceIoOpen(path, SCE_O_RDONLY, 0);
  if (fd < 0) return NULL;
  const int n = (int)sceIoLseek(fd, 0, SCE_SEEK_END);
  sceIoLseek(fd, 0, SCE_SEEK_SET);
  char* s = malloc((size_t)n + 1);
  const int got = sceIoRead(fd, s, (SceSize)n);
  sceIoClose(fd);
  if (got < 0) {
    free(s);
    return NULL;
  }
  s[got] = 0;
  if (size) *size = (unsigned)got;
  return s;
}

static int m2(void) {
  const SceUID dir = sceIoDopen("app0:corpus");
  if (dir < 0) {
    sayf("m2 no corpus directory: 0x%08X", (unsigned)dir);
    return 1;
  }
  int total = 0, failed = 0;
  SceIoDirent ent;
  while (sceIoDread(dir, &ent) > 0) {
    if (ent.d_name[0] == '.') continue;
    char path[256];
    snprintf(path, sizeof path, "app0:corpus/%s", ent.d_name);
    char* src = read_file(path, NULL);
    if (!src) {
      sayf("m2 %s: unreadable", ent.d_name);
      failed++;
      total++;
      continue;
    }
    const int fragment = strstr(ent.d_name, "frag") != NULL;
    char log[1024];
    const SceUInt64 t0 = sceKernelGetProcessTimeWide();
    const int r = fvgl_debug_compile(src, fragment, log, sizeof log);
    const unsigned ms = (unsigned)((sceKernelGetProcessTimeWide() - t0) / 1000);
    sayf("m2 %s %-20s %4u ms %s", r == 0 ? "ok  " : "FAIL", ent.d_name, ms, r == 0 ? "" : log);
    failed += r != 0;
    total++;
    free(src);
  }
  sceIoDclose(dir);
  sayf("m2 %s: %d of %d shaders failed", failed ? "FAILED" : "PASSED", failed, total);
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
  if (r == 0) {
    m0();
    m1();
    m2();
  }
  // A moment on screen so the result is also visible, then back.
  sceKernelDelayThread(1500 * 1000);
  hand_back();
  return 0;
}
