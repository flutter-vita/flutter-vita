// ADR-0014 spike, criterion 1: does vitaGL give Ganesh what it needs?
//
// The ADR established that nothing *forbids* a GPU backend -- vitaGL is
// installed as a static archive, Ganesh already compiles, and the one link
// failure was a shared-library target this port never builds. None of that
// says vitaGL actually serves what Skia asks for. This is the smallest program
// that finds out, and it deliberately runs before any Skia work: every check
// here is cheaper to fail than a Skia build configuration is.
//
// Reports to ux0:data/flutter-vita/gl-spike.txt and then bails to the loader,
// which is how the report gets read -- the loader's `get` command can stream a
// file back, and nothing else is listening once this exits.
//
// The checks are ordered by what Ganesh needs, cheapest first:
//
//   1. A GL context at all.
//   2. Strings and limits -- GL_SHADING_LANGUAGE_VERSION is the one that
//      matters, because Ganesh generates GLSL and needs to know the dialect.
//   3. Runtime shader compilation. This is the libshacccg.suprx dependency
//      made concrete: Ganesh compiles shaders it generates at run time, so a
//      precompiled .gxp cache is not an option for it.
//   4. Render to texture. Non-negotiable: every saveLayer -- the operation
//      that costs half of localsend's 199 ms frame -- is an offscreen target.
//   5. A readback that proves the pixels are real rather than merely
//      unreported errors.

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/sysmem.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>
#include <psp2/net/netctl.h>
#include <psp2/sysmodule.h>
#include <vitaGL.h>
#include <vitashark.h>


// Deliberately NOT bailout.h.
//
// vita_bail_to_loader launches the loader and exits, which is the right
// behaviour for a Flutter app and the wrong one here. A failed vglInit leaves
// sceGxm and the display part-configured, and asking the shell to start
// another app from that state wedged the console hard enough that the PS
// button stopped responding and it took a 30-second power hold -- while the
// report on disk showed the spike had already finished its work and reached
// the bail. So this exits plainly and lets the console return to LiveArea.
// One tap to reopen the loader beats any chance of repeating that.
#define REPORT "ux0:data/flutter-vita/gl-spike.txt"

// vitaGL allocates from the newlib heap as well as from its own GPU pools, and
// the VitaSDK default heap is far too small for it. Nearly every vitaGL port
// declares this; omitting it is a documented way to get an unexplained
// vglInit failure, which is exactly what the first run of this spike produced.
unsigned int _newlib_heap_size_user = 64 * 1024 * 1024;

static FILE* g_out;
static int g_fail;

static void say(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(g_out, fmt, ap);
  va_end(ap);
  fflush(g_out);
}

// Announce a step before entering it. The report is flushed line by line, so
// the last `>>` on disk is the call that did not return -- which is the only
// way to locate a hang on a console with no debugger and no way to interrupt.
//
// Added after the first run that reached the GPU wedged the console: vitaGL had
// clearly initialised (the display showed a band of garbage along the bottom),
// but nothing said which of the six calls after it never came back.
static void enter(const char* what) {
  say(">> %s\n", what);
}

static void check(const char* what, int ok, const char* detail) {
  say("%-34s %s%s%s\n", what, ok ? "PASS" : "FAIL",
      detail && detail[0] ? "  " : "", detail ? detail : "");
  if (!ok) g_fail++;
}

// glGetError is sticky and reports one error per call, so drain it. A single
// glGetError() after a sequence hides everything but the last failure.
static int drain_gl_errors(const char* stage) {
  int seen = 0;
  for (;;) {
    GLenum e = glGetError();
    if (e == GL_NO_ERROR) break;
    say("    gl error at %s: 0x%04X\n", stage, (unsigned)e);
    seen++;
    if (seen > 8) break;  // a driver stuck in error would loop forever
  }
  return seen;
}

// Valid GLSL ES 1.00, declarations included.
//
// The first version of these omitted `attribute vec2 aPos;` on the theory that
// vitaGL's translator supplies the semantic from glBindAttribLocation. Both
// shaders then reported PASS from glCompileShader and the console hung inside
// glLinkProgram -- because vitaGL defers the real shark translation to link
// time, so glCompileShader validates almost nothing and an undefined
// identifier surfaces as a hang in the linker rather than a compile error.
static const char* kVert =
    "attribute vec2 aPos;\n"
    "void main() {\n"
    "  gl_Position = vec4(aPos, 0.0, 1.0);\n"
    "}\n";

static const char* kFrag =
    "precision mediump float;\n"
    "void main() {\n"
    "  gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "}\n";

static GLuint compile(GLenum type, const char* src, const char* label) {
  GLuint s = glCreateShader(type);
  if (!s) { check(label, 0, "glCreateShader returned 0"); return 0; }
  glShaderSource(s, 1, &src, NULL);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  char log[512] = {0};
  GLsizei n = 0;
  glGetShaderInfoLog(s, sizeof log - 1, &n, log);
  check(label, ok == GL_TRUE, n > 0 ? log : "");
  return ok == GL_TRUE ? s : 0;
}

// Serve the report over TCP, then exit. Called on every exit path.
//
// Without this the report is unreadable: the spike returns to LiveArea when it
// exits, which leaves the loader closed, and the loader's `get` command is the
// only other way to pull a file off this console. Every iteration would need
// somebody to walk over and tap the loader bubble -- the exact cost ADR-0011
// exists to remove, reintroduced through the back door.
//
// Deliberately NOT the bail-to-loader route. Launching another app after a
// half-completed vglInit is what wedged the console hard enough to need a
// 30-second power hold; this touches no app manager at all.
//
// Bounded by kServeSeconds so a run nobody collects still returns the console
// to LiveArea on its own rather than sitting on a listener forever.
#define SPIKE_PORT 1342
#define kServeSeconds 240

static char g_net_pool[16 * 1024];

static void serve_report_then_exit(void) {
  if (g_out) { fclose(g_out); g_out = NULL; }

  if (sceSysmoduleLoadModule(SCE_SYSMODULE_NET) < 0) sceKernelExitProcess(0);
  SceNetInitParam np;
  np.memory = g_net_pool;
  np.size = sizeof g_net_pool;
  np.flags = 0;
  const int ni = sceNetInit(&np);
  if (ni < 0 && ni != (int)0x80410103) sceKernelExitProcess(0);
  sceNetCtlInit();

  const int srv =
      sceNetSocket("fvita-g1", SCE_NET_AF_INET, SCE_NET_SOCK_STREAM, 0);
  if (srv < 0) sceKernelExitProcess(0);
  int one = 1;
  sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_REUSEADDR, &one,
                   sizeof one);
  SceNetSockaddrIn addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = SCE_NET_AF_INET;
  addr.sin_addr.s_addr = sceNetHtonl(SCE_NET_INADDR_ANY);
  addr.sin_port = sceNetHtons(SPIKE_PORT);
  if (sceNetBind(srv, (SceNetSockaddr*)&addr, sizeof addr) < 0 ||
      sceNetListen(srv, 2) < 0) {
    sceNetSocketClose(srv);
    sceKernelExitProcess(0);
  }
  sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_NBIO, &one, sizeof one);

  // 10 polls a second, so the deadline is in tenths.
  for (int tick = 0; tick < kServeSeconds * 10; tick++) {
    const int c = sceNetAccept(srv, NULL, NULL);
    if (c >= 0) {
      int zero = 0;
      sceNetSetsockopt(c, SCE_NET_SOL_SOCKET, SCE_NET_SO_NBIO, &zero,
                       sizeof zero);
      SceUID fd = sceIoOpen(REPORT, SCE_O_RDONLY, 0777);
      if (fd >= 0) {
        static char buf[4096];
        int n;
        while ((n = sceIoRead(fd, buf, sizeof buf)) > 0) {
          int off = 0;
          while (off < n) {
            const int w = sceNetSend(c, buf + off, n - off, 0);
            if (w <= 0) { n = -1; break; }
            off += w;
          }
          if (n < 0) break;
        }
        sceIoClose(fd);
      }
      sceNetSocketClose(c);
      break;  // one reader is all this needs
    }
    sceKernelDelayThread(100 * 1000);
  }

  sceNetSocketClose(srv);
  sceKernelExitProcess(0);
}

int main(void) {
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  g_out = fopen(REPORT, "w");
  if (!g_out) {
    return 1;
  }

  say("ADR-0014 spike -- vitaGL / Ganesh feasibility\n");
  say("=============================================\n\n");

  // 1. Context.
  //
  // Split into attempts rather than one call, because the first run of this
  // spike reported nothing except `vglInit FAIL`, which does not distinguish
  // "no memory" from "no shader compiler" from "no GPU". An instrument that
  // cannot say which of three things went wrong is barely an instrument.
  //
  // libshacccg.suprx is confirmed present at ur0:data on this console, so the
  // runtime compiler is set up separately below and its failure is reported on
  // its own line.
  {
    SceKernelFreeMemorySizeInfo mem;
    mem.size = sizeof(mem);
    if (sceKernelGetFreeMemorySize(&mem) >= 0) {
      say("free before init: user %u KiB, cdram %u KiB, phycont %u KiB\n\n",
          (unsigned)(mem.size_user / 1024), (unsigned)(mem.size_cdram / 1024),
          (unsigned)(mem.size_phycont / 1024));
    }
  }

  // One init attempt per run, and this run tries the canonical call.
  //
  // Two runs have failed and between them they tested three of the four
  // interesting combinations. Run 1 was vglInit(0x100000) against VitaSDK's
  // default heap, which is far too small for vitaGL. Run 2 raised the heap to
  // 64 MB but asked for a *zero* legacy pool, by both routes, on the reasoning
  // that Ganesh never uses immediate mode. Zero is not obviously a value
  // vitaGL accepts, and "the pool Ganesh needs" is not the same question as
  // "the pool vglInit will start with".
  //
  // So: the documented call, with a real pool, on a heap that is big enough --
  // the combination neither previous run covered. Only one attempt, because a
  // failed init leaves the GPU in a state the next attempt inherits.
  // No pre-emptive shark_init here any more.
  //
  // One run did call it directly, and it returned 0 -- which settled the open
  // question: libshacccg.suprx loads and the SceShaccCgExt -> taiHEN hook chain
  // resolves from an UNSAFE self. That answer is banked and the probe removed,
  // because vitaGL's gxm.o calls shark_init itself from inside vglInit, and a
  // compiler this program already initialised is a plausible reason for vglInit
  // to return GL_FALSE while every context it built works perfectly.
  enter("vglInit(0x100000)");
  const GLboolean up = vglInit(0x100000);

  // Report the raw value rather than a verdict, and DO NOT stop on a false.
  //
  // Three runs treated GL_FALSE here as "no context" and exited without
  // touching a single GL entry point. That was wrong, and the console said so:
  // vitaGL's splash screen -- invoke_splashscreen, on its own thread, started
  // early inside vglInit and stopped only by clear_splashscreen -- was
  // observed rotating at a smooth 60 fps while the report on disk claimed
  // there was no context. A splash that animates is GXM initialised, a display
  // configured, and vitaGL's own shaders compiled at run time. Whatever
  // vglInit is unhappy about, it is not any of those.
  //
  // So the boolean is now one data point among several, and the checks below
  // run either way. glGetString returning a real vendor string is stronger
  // evidence of a working context than a return code is of a broken one.
  // Reported, not counted. vglInit returns GL_FALSE on this console while
  // every context it builds works: strings, limits, runtime shader compile,
  // link, FBO and a correct green readback all pass immediately afterwards.
  // Removing this program's own shark_init call did not change the return
  // value, so it is not induced by the probe. Treating it as a failure is what
  // stopped three earlier runs before they touched a single GL entry point.
  say("vglInit returned %d (0x100000 pool, 64 MiB heap)%s\n", (int)up,
      up == GL_TRUE ? "" : "  <- known vitaGL quirk, context works anyway");
  // The runtime GLSL compiler, reported separately so that a context without a
  // compiler is a distinguishable result. Ganesh generates shader source at
  // run time, so a precompiled .gxp cache cannot substitute for this.
  enter("vglSetupRuntimeShaderCompiler");
  vglSetupRuntimeShaderCompiler(SHARK_OPT_DEFAULT, 0, 0, 0);

  // 2. Who are we talking to.
  say("\n-- strings --\n");
  const char* vendor = (const char*)glGetString(GL_VENDOR);
  const char* rend   = (const char*)glGetString(GL_RENDERER);
  const char* ver    = (const char*)glGetString(GL_VERSION);
  const char* glsl   = (const char*)glGetString(GL_SHADING_LANGUAGE_VERSION);
  say("GL_VENDOR                   %s\n", vendor ? vendor : "(null)");
  say("GL_RENDERER                 %s\n", rend ? rend : "(null)");
  say("GL_VERSION                  %s\n", ver ? ver : "(null)");
  say("GL_SHADING_LANGUAGE_VERSION %s\n", glsl ? glsl : "(null)");

  say("\n-- limits Ganesh reads at context creation --\n");
  struct { GLenum e; const char* name; } lim[] = {
    { GL_MAX_TEXTURE_SIZE,          "GL_MAX_TEXTURE_SIZE" },
    { GL_MAX_RENDERBUFFER_SIZE,     "GL_MAX_RENDERBUFFER_SIZE" },
    { GL_MAX_VERTEX_ATTRIBS,        "GL_MAX_VERTEX_ATTRIBS" },
    { GL_MAX_TEXTURE_IMAGE_UNITS,   "GL_MAX_TEXTURE_IMAGE_UNITS" },
    { GL_MAX_VERTEX_UNIFORM_VECTORS,"GL_MAX_VERTEX_UNIFORM_VECTORS" },
    { GL_MAX_FRAGMENT_UNIFORM_VECTORS,"GL_MAX_FRAGMENT_UNIFORM_VECTORS" },
    { GL_MAX_VARYING_VECTORS,       "GL_MAX_VARYING_VECTORS" },
  };
  for (unsigned i = 0; i < sizeof lim / sizeof lim[0]; i++) {
    GLint v = -1;
    glGetIntegerv(lim[i].e, &v);
    say("%-34s %d\n", lim[i].name, (int)v);
  }
  drain_gl_errors("limits");

  say("\n-- checks --\n");

  // 3. Runtime shader compilation: the libshacccg dependency, made concrete.
  //
  // Note the sources declare no attribute themselves -- vitaGL's translator
  // supplies `aPos` semantics from the bound attribute. If this fails on the
  // vertex shader but the fragment one passes, the compiler is present and the
  // dialect is the problem, which is a very different result from "no
  // compiler at all".
  enter("glCompileShader fragment");
  GLuint fs = compile(GL_FRAGMENT_SHADER, kFrag, "compile fragment shader");
  enter("glCompileShader vertex");
  GLuint vs = compile(GL_VERTEX_SHADER, kVert, "compile vertex shader");

  GLuint prog = 0;
  if (vs && fs) {
    prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glBindAttribLocation(prog, 0, "aPos");
    enter("glLinkProgram");
    glLinkProgram(prog);
    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    char log[512] = {0};
    GLsizei n = 0;
    glGetProgramInfoLog(prog, sizeof log - 1, &n, log);
    check("link program", ok == GL_TRUE, n > 0 ? log : "");
    if (ok != GL_TRUE) prog = 0;
  } else {
    check("link program", 0, "skipped, a shader did not compile");
  }

  // 4. Render to texture. Every saveLayer is one of these.
  GLuint tex = 0, fbo = 0;
  enter("FBO setup");
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  char stbuf[64];
  snprintf(stbuf, sizeof stbuf, "status 0x%04X", (unsigned)st);
  check("FBO with texture attachment", st == GL_FRAMEBUFFER_COMPLETE, stbuf);
  drain_gl_errors("fbo setup");

  // 5. Draw, then read back. Green is what the fragment shader writes, so a
  //    green pixel proves the whole chain and not just the absence of errors.
  int readback_ok = 0;
  unsigned char px[4] = {0, 0, 0, 0};
  if (st == GL_FRAMEBUFFER_COMPLETE && prog) {
    static const float tri[] = { -1.f, -1.f,  3.f, -1.f,  -1.f, 3.f };
    enter("viewport/clear/useProgram");
    glViewport(0, 0, 64, 64);
    glClearColor(1.f, 0.f, 0.f, 1.f);   // red, so a failed draw is obvious
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, tri);
    enter("glDrawArrays");
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // No glFinish. It is an unbounded wait for the GPU to retire work, and in
    // a probe whose whole question is "does this GPU work at all" that is the
    // wrong primitive: the first run that got this far hung the console hard
    // enough that the PS button stopped responding and it needed a 30-second
    // power hold. glReadPixels below synchronises anyway -- it must, since it
    // returns pixels -- so the glFinish was buying nothing but a second place
    // to hang.
    enter("glReadPixels");
    glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    readback_ok = (px[1] > 200 && px[0] < 64);
  }
  char pxbuf[80];
  snprintf(pxbuf, sizeof pxbuf, "centre pixel rgba %u,%u,%u,%u (want green)",
           px[0], px[1], px[2], px[3]);
  check("draw into FBO and read back", readback_ok, pxbuf);
  drain_gl_errors("draw");

  say("\n-- memory pools --\n");
  say("VRAM  free %u\n", (unsigned)vglMemFree(VGL_MEM_VRAM));
  say("RAM   free %u\n", (unsigned)vglMemFree(VGL_MEM_RAM));
  say("SLOW  free %u\n", (unsigned)vglMemFree(VGL_MEM_SLOW));

  say("\n=============================================\n");
  say("%s (%d failed)\n", g_fail == 0 ? "ALL CHECKS PASSED" : "FAILURES PRESENT", g_fail);

  serve_report_then_exit();
  return 0;
}
