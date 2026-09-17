// The fvita_gles2 milestone tests. Each one draws something whose pixels are
// known in advance, reads them back through glReadPixels, writes a report and
// the raw frame to ux0:data/flutter-vita, and hands the console back to the
// receiver so both can be pulled with `get`.
//
//   M0  clear, scissor, present: our own sceGxm context on the screen
//   M1  two triangles from GLSL: translator, link, uniforms (a mat3 among
//       them), VBO and client arrays, glDrawArrays and glDrawElements, blend,
//       gl_FragCoord the way Skia uses it
//   M2  every shader in engine/gles2/corpus through the translator and the
//       console's Cg compiler
//   M3  textures and framebuffers: the GL formats' swizzles, row order,
//       unpack alignment, filtering, a write into a texture in flight, an
//       incomplete sampler, render to texture with scissor and gl_FragCoord,
//       readback from a texture, and a copy from the display into one
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

static void launch_receiver(void) {
  sceAppMgrLaunchAppByUri(0xFFFFF, "psgm:play?titleid=" RECEIVER);
  sceKernelExitProcess(0);
}

// The shutdown on 2026-09-12 never returned and the console sat on the last
// frame until a hand opened the receiver. The stages are logged, and this
// thread hands over regardless after ten seconds.
static int watchdog(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  sceKernelDelayThread(10 * 1000 * 1000);
  say("watchdog: shutdown did not return in 10 s");
  launch_receiver();
  return 0;
}

static void hand_back(void) {
  const SceUID w = sceKernelCreateThread("watchdog", watchdog, 0x10000100, 0x4000, 0, 0, NULL);
  if (w >= 0) sceKernelStartThread(w, 0, NULL);
  fvgl_shutdown();
  if (g_report >= 0) sceIoClose(g_report);
  launch_receiver();
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

// ---- M3 --------------------------------------------------------------------

static const char kM3Vertex[] =
    "#version 100\n"
    "attribute highp vec2 aPos;\n"
    "attribute mediump vec2 aUV;\n"
    "varying mediump vec2 vUV;\n"
    "void main() { vUV = aUV; gl_Position = vec4(aPos, 0.0, 1.0); }\n";

static const char kM3Fragment[] =
    "#version 100\n"
    "precision mediump float;\n"
    "uniform sampler2D uTex;\n"
    "varying mediump vec2 vUV;\n"
    "void main() { gl_FragColor = texture2D(uTex, vUV); }\n";

// Red rises with the GL row: 0 at the bottom of the target, 1 at row 64.
static const char kM3Gradient[] =
    "#version 100\n"
    "precision mediump float;\n"
    "void main() { gl_FragColor = vec4(gl_FragCoord.y / 64.0, 0.0, 0.0, 1.0); }\n";

typedef struct Expect4 {
  int x, y;
  int r, g, b, a;  // -1: not checked
  const char* what;
} Expect4;

static int check_pixels(const char* tag, const unsigned char* pixels, int w, const Expect4* expect, size_t count,
                        int tolerance) {
  int failed = 0;
  for (size_t i = 0; i < count; i++) {
    const Expect4* e = &expect[i];
    const unsigned char* px = pixels + ((size_t)e->y * (size_t)w + (size_t)e->x) * 4;
    const int want[4] = {e->r, e->g, e->b, e->a};
    int ok = 1;
    for (int c = 0; c < 4; c++) ok = ok && (want[c] < 0 || abs(px[c] - want[c]) <= tolerance);
    sayf("%s %s (%3d,%3d) got %3u %3u %3u %3u want %3d %3d %3d %3d  %s", tag, ok ? "ok  " : "FAIL", e->x, e->y,
         px[0], px[1], px[2], px[3], e->r, e->g, e->b, e->a, e->what);
    failed += !ok;
  }
  return failed;
}

static GLuint m3_program(const char* vsrc, const char* fsrc) {
  const GLuint vs = m1_shader(GL_VERTEX_SHADER, vsrc);
  const GLuint fs = m1_shader(GL_FRAGMENT_SHADER, fsrc);
  const GLuint prog = glCreateProgram();
  glAttachShader(prog, vs);
  glAttachShader(prog, fs);
  glBindAttribLocation(prog, 0, "aPos");
  glBindAttribLocation(prog, 1, "aUV");
  glLinkProgram(prog);
  GLint linked = 0;
  glGetProgramiv(prog, GL_LINK_STATUS, &linked);
  if (!linked) {
    char log[512];
    glGetProgramInfoLog(prog, sizeof log, NULL, log);
    sayf("m3 link failed: %s", log);
    return 0;
  }
  glDeleteShader(vs);
  glDeleteShader(fs);
  return prog;
}

// A quad over GL pixel rectangle [x0,x1)x[y0,y1) of a target tw x th, with
// uv (0,0) at its bottom-left, from client arrays.
static void m3_quad(int x0, int y0, int x1, int y1, int tw, int th) {
  const float fx0 = (float)x0 / tw * 2 - 1, fx1 = (float)x1 / tw * 2 - 1;
  const float fy0 = (float)y0 / th * 2 - 1, fy1 = (float)y1 / th * 2 - 1;
  const float v[] = {fx0, fy0, 0, 0, fx1, fy0, 1, 0, fx1, fy1, 1, 1, fx0, fy1, 0, 1};
  const unsigned short idx[] = {0, 1, 2, 0, 2, 3};
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  glEnableVertexAttribArray(0);
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, v);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, v + 2);
  glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, idx);
}

static GLuint m3_texture(GLenum format, GLenum type, int w, int h, const void* data, GLenum filter, GLenum wrap) {
  GLuint t = 0;
  glGenTextures(1, &t);
  glBindTexture(GL_TEXTURE_2D, t);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (GLint)filter);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (GLint)filter);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (GLint)wrap);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (GLint)wrap);
  glTexImage2D(GL_TEXTURE_2D, 0, (GLint)format, w, h, 0, format, type, data);
  return t;
}

extern unsigned fvgl_stalls_previous_frame, fvgl_stalls_this_frame;

static int m3(void) {
  const int W = 960, H = 544;
  const GLuint prog = m3_program(kM3Vertex, kM3Fragment);
  const GLuint gradient = m3_program(kM3Vertex, kM3Gradient);
  if (!prog || !gradient) return 1;
  glUseProgram(prog);
  glUniform1i(glGetUniformLocation(prog, "uTex"), 0);
  glActiveTexture(GL_TEXTURE0);
  glDisable(GL_BLEND);
  glDisable(GL_SCISSOR_TEST);

  // A: RGBA 2x2, row 0 red green, row 1 blue white.
  static const unsigned char a_px[] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
  const GLuint texA = m3_texture(GL_RGBA, GL_UNSIGNED_BYTE, 2, 2, a_px, GL_NEAREST, GL_CLAMP_TO_EDGE);
  // B: alpha 2x1.
  static const unsigned char b_px[] = {64, 192};
  const GLuint texB = m3_texture(GL_ALPHA, GL_UNSIGNED_BYTE, 2, 1, b_px, GL_NEAREST, GL_CLAMP_TO_EDGE);
  // C: luminance 2x1.
  static const unsigned char c_px[] = {100, 200};
  const GLuint texC = m3_texture(GL_LUMINANCE, GL_UNSIGNED_BYTE, 2, 1, c_px, GL_NEAREST, GL_CLAMP_TO_EDGE);
  // D: RGB 3x2 with 9-byte rows: needs unpack alignment 1.
  static const unsigned char d_px[] = {255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255, 0, 0, 0, 255, 0};
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  const GLuint texD = m3_texture(GL_RGB, GL_UNSIGNED_BYTE, 3, 2, d_px, GL_NEAREST, GL_CLAMP_TO_EDGE);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  // E: RGBA 2x1 black white, linear, clamped.
  static const unsigned char e_px[] = {0, 0, 0, 255, 255, 255, 255, 255};
  const GLuint texE = m3_texture(GL_RGBA, GL_UNSIGNED_BYTE, 2, 1, e_px, GL_LINEAR, GL_CLAMP_TO_EDGE);
  // H: RGB565 2x1 red blue. I: luminance alpha 2x1.
  static const unsigned short h_px[] = {0xF800, 0x001F};
  const GLuint texH = m3_texture(GL_RGB, GL_UNSIGNED_SHORT_5_6_5, 2, 1, h_px, GL_NEAREST, GL_CLAMP_TO_EDGE);
  static const unsigned char i_px[] = {100, 64, 200, 192};
  const GLuint texI = m3_texture(GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 2, 1, i_px, GL_NEAREST, GL_CLAMP_TO_EDGE);
  // F: the render target, 128x64.
  const GLuint texF = m3_texture(GL_RGBA, GL_UNSIGNED_BYTE, 128, 64, NULL, GL_NEAREST, GL_CLAMP_TO_EDGE);
  // G: filled by a copy from the display.
  const GLuint texG = m3_texture(GL_RGBA, GL_UNSIGNED_BYTE, 200, 200, NULL, GL_NEAREST, GL_CLAMP_TO_EDGE);

  GLuint fbo = 0;
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texF, 0);
  const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  sayf("m3 framebuffer status 0x%04X (complete is 0x%04X)", status, GL_FRAMEBUFFER_COMPLETE);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);

  int failed = status != GL_FRAMEBUFFER_COMPLETE;
  unsigned char* fbo_pixels = malloc(128 * 64 * 4);
  unsigned char* pixels = malloc((size_t)W * H * 4);

  for (int frame = 0; frame <= 60; frame++) {
    const int last = frame == 60;
    if (last) {
      // Into a texture the previous frame's draws still sample.
      static const unsigned char yellow[] = {255, 255, 0, 255};
      glBindTexture(GL_TEXTURE_2D, texA);
      glTexSubImage2D(GL_TEXTURE_2D, 0, 1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, yellow);
    }

    // Into F: green, a red bottom-left quadrant by scissor, A in the
    // top-right quadrant, the gradient in the top-left.
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glViewport(0, 0, 128, 64);
    glClearColor(0, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_SCISSOR_TEST);
    glScissor(0, 0, 64, 32);
    glClearColor(1, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_SCISSOR_TEST);
    glUseProgram(prog);
    glBindTexture(GL_TEXTURE_2D, texA);
    m3_quad(64, 32, 128, 64, 128, 64);
    glUseProgram(gradient);
    m3_quad(0, 32, 64, 64, 128, 64);
    if (last) {
      glReadPixels(0, 0, 128, 64, GL_RGBA, GL_UNSIGNED_BYTE, fbo_pixels);
      static const Expect4 expect[] = {
          {10, 10, 255, 0, 0, 255, "F: red quadrant (scissored clear)"},
          {100, 10, 0, 255, 0, 255, "F: green, right of the red"},
          {70, 40, 255, 0, 0, 255, "F: A's texel (0,0) red"},
          {120, 40, 0, 255, 0, 255, "F: A's texel (1,0) green"},
          {70, 60, 0, 0, 255, 255, "F: A's texel (0,1) blue"},
          {100, 50, 255, 255, 0, 255, "F: A's texel (1,1), yellow after the update"},
          {5, 40, 161, 0, 0, 255, "F: gradient at row 40, gl_FragCoord.y = 40.5"},
          {5, 60, 241, 0, 0, 255, "F: gradient at row 60"},
      };
      failed += check_pixels("m3", fbo_pixels, 128, expect, sizeof expect / sizeof expect[0], 4);
    }

    // The display.
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, W, H);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog);
    glBindTexture(GL_TEXTURE_2D, texA);
    m3_quad(0, 0, 200, 200, W, H);
    glBindTexture(GL_TEXTURE_2D, texB);
    m3_quad(200, 0, 400, 100, W, H);
    glBindTexture(GL_TEXTURE_2D, texC);
    m3_quad(400, 0, 600, 100, W, H);
    glBindTexture(GL_TEXTURE_2D, texD);
    m3_quad(600, 0, 900, 200, W, H);
    glBindTexture(GL_TEXTURE_2D, texE);
    m3_quad(0, 200, 200, 300, W, H);
    glBindTexture(GL_TEXTURE_2D, 0);
    m3_quad(200, 200, 300, 300, W, H);
    glBindTexture(GL_TEXTURE_2D, texH);
    m3_quad(700, 200, 800, 300, W, H);
    glBindTexture(GL_TEXTURE_2D, texI);
    m3_quad(800, 200, 900, 300, W, H);
    glBindTexture(GL_TEXTURE_2D, texF);
    m3_quad(400, 200, 656, 328, W, H);
    if (last) {
      // A's quad, as drawn on the display this frame, into G, then G on screen.
      glBindTexture(GL_TEXTURE_2D, texG);
      glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, 200, 200);
      m3_quad(700, 300, 900, 500, W, H);
    }
    if (!last) fvgl_swap();
  }

  glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
  const GLenum err = glGetError();
  sayf("m3 glGetError 0x%04X", err);
  const SceUID f = sceIoOpen(DIR "gles2-m3.rgba", SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (f >= 0) {
    sceIoWrite(f, pixels, (SceSize)(W * H * 4));
    sceIoClose(f);
  }
  static const Expect4 expect[] = {
      {50, 50, 255, 0, 0, 255, "A texel (0,0) red: RGBA order, row 0 at the bottom"},
      {150, 50, 0, 255, 0, 255, "A texel (1,0) green"},
      {50, 150, 0, 0, 255, 255, "A texel (0,1) blue"},
      {150, 150, 255, 255, 0, 255, "A texel (1,1) yellow: glTexSubImage2D landed"},
      {250, 50, 0, 0, 0, 64, "B alpha 64: GL_ALPHA is (0,0,0,a)"},
      {350, 50, 0, 0, 0, 192, "B alpha 192"},
      {450, 50, 100, 100, 100, 255, "C luminance 100: (l,l,l,1)"},
      {550, 50, 200, 200, 200, 255, "C luminance 200"},
      {650, 50, 255, 0, 0, 255, "D (0,0) red: 9-byte rows with alignment 1"},
      {750, 50, 0, 255, 0, 255, "D (1,0) green"},
      {850, 50, 0, 0, 255, 255, "D (2,0) blue"},
      {650, 150, 0, 0, 255, 255, "D (0,1) blue"},
      {850, 150, 0, 255, 0, 255, "D (2,1) green"},
      {10, 250, 0, 0, 0, 255, "E clamped left: black"},
      {100, 250, 128, 128, 128, 255, "E centre: linear, half"},
      {190, 250, 255, 255, 255, 255, "E clamped right: white"},
      {250, 250, 255, 255, 255, 255, "no texture bound: white"},
      {725, 250, 255, 0, 0, 255, "H 565 red"},
      {775, 250, 0, 0, 255, 255, "H 565 blue"},
      {825, 250, 100, 100, 100, 64, "I luminance alpha (100,64)"},
      {875, 250, 200, 200, 200, 192, "I luminance alpha (200,192)"},
      {410, 210, 255, 0, 0, 255, "F on screen: red quadrant at its bottom-left"},
      {560, 220, 0, 255, 0, 255, "F on screen: green"},
      {600, 300, 255, 255, 0, 255, "F on screen: A's yellow texel, drawn into F"},
      {420, 300, 201, 0, 0, 255, "F on screen: gradient row 50 (2x scale)"},
      {750, 350, 255, 0, 0, 255, "G, copied from the display: A's red"},
      {850, 450, 255, 255, 0, 255, "G: A's yellow"},
  };
  failed += check_pixels("m3", pixels, W, expect, sizeof expect / sizeof expect[0], 4);
  sayf("m3 stalls: %u on a previous frame, %u on this frame", fvgl_stalls_previous_frame, fvgl_stalls_this_frame);
  free(pixels);
  free(fbo_pixels);
  fvgl_swap();
  const GLuint textures[] = {texA, texB, texC, texD, texE, texF, texG, texH, texI};
  glDeleteTextures(9, textures);
  glDeleteFramebuffers(1, &fbo);
  glDeleteProgram(prog);
  glDeleteProgram(gradient);
  sayf("m3 %s: %d checks failed", failed ? "FAILED" : "PASSED", failed);
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
    m3();
  }
  // A moment on screen so the result is also visible, then back.
  sceKernelDelayThread(1500 * 1000);
  hand_back();
  return 0;
}
