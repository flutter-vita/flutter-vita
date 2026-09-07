// ADR-0014 experiment, criterion 1: does vitaGL give Ganesh what it needs?
//
// The ADR established that nothing *forbids* a GPU backend -- vitaGL is
// installed as a static archive, Ganesh already compiles, and the one link
// failure was a shared-library target this port never builds. None of that
// says vitaGL actually serves what Skia asks for. This is the smallest program
// that finds out, and it deliberately runs before any Skia work: every check
// here is cheaper to fail than a Skia build configuration is.
//
// Reports to ux0:data/flutter-vita/gl-experiment.txt and then bails to the receiver,
// which is how the report gets read -- the receiver's `get` command can stream a
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
#include <psp2/appmgr.h>
#include <psp2/gxm.h>
#include <psp2/io/dirent.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/threadmgr.h>
#include <vitaGL.h>
#include <vitashark.h>


// Deliberately NOT bailout.h.
//
// vita_bail_to_loader launches the receiver and exits, which is the right
// behaviour for a Flutter app and the wrong one here. A failed vglInit leaves
// sceGxm and the display part-configured, and asking the shell to start
// another app from that state wedged the console hard enough that the PS
// button stopped responding and it took a 30-second power hold -- while the
// report on disk showed the experiment had already finished its work and reached
// the bail. So this exits plainly and lets the console return to LiveArea.
// One tap to reopen the receiver beats any chance of repeating that.
#define REPORT "ux0:data/flutter-vita/gl-experiment.txt"

// vitaGL allocates from the newlib heap as well as from its own GPU pools, and
// the VitaSDK default heap is far too small for it. Nearly every vitaGL port
// declares this; omitting it is a documented way to get an unexplained
// vglInit failure, which is exactly what the first run of this experiment produced.
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
// Without this the report is unreadable: the experiment returns to LiveArea when it
// exits, which leaves the receiver closed, and the receiver's `get` command is the
// only other way to pull a file off this console. Every iteration would need
// somebody to walk over and tap the receiver bubble -- the exact cost ADR-0011
// exists to remove, reintroduced through the back door.
//
// Deliberately NOT the bail-to-receiver route. Launching another app after a
// half-completed vglInit is what wedged the console hard enough to need a
// 30-second power hold; this touches no app manager at all.
//
// Bounded by kServeSeconds so a run nobody collects still returns the console
// to LiveArea on its own rather than sitting on a listener forever.

// Hand the console back to the receiver, exactly as templates/vita-app/bailout.c
// does. Exiting to LiveArea instead leaves the receiver closed, so the next
// deploy stalls waiting for somebody to walk over and tap it -- which is the
// cost ADR-0011 exists to remove, reintroduced by an experiment.
//
// Nothing may go between the launch and the exit. The "close the current
// application?" prompt appears only while the outgoing app is still alive; a
// sceKernelDelayThread here cost a prompt on every single bail until it was
// removed from bailout.c.
#define VITA_LOADER_TITLEID "FVTA00003"

static void hand_back_to_receiver(void) {
  // Let go of the GPU before asking the shell to switch.
  //
  // bailout.c does the launch-then-exit with nothing in between and never
  // prompts, but the app it runs in has never touched the GPU. This one holds
  // a live GXM context and a configured display, and it *did* prompt on every
  // run: "close the current application?" appears while the outgoing app is
  // still alive, and a process still tearing down the GPU is still alive.
  //
  // vitaGL offers no shutdown -- there is no vglEnd in the archive -- so this
  // goes to GXM directly. Draining the display queue first matters: terminating
  // with frames still in flight is a use-after-free of the buffers they name.
  //
  // Failures are ignored on purpose. If the GPU was never brought up these
  // return errors and there is nothing to release, which is the good case.
  sceGxmDisplayQueueFinish();
  sceGxmTerminate();

  sceAppMgrLaunchAppByUri(0xFFFFF, "psgm:play?titleid=" VITA_LOADER_TITLEID);

  // Nothing between the launch and the exit -- see bailout.c, where a 100 ms
  // delay here cost a prompt on every bail.
  sceKernelExitProcess(0);
}

// Write the report, hand the console back, exit. No waiting.
//
// This used to run a TCP server and sit on it for up to 45 seconds so the
// report could be collected before the process ended. That was necessary only
// while the experiment exited to LiveArea, which left no receiver to read the file
// with. Now that it bails to the receiver, the receiver's own `get` command serves
// the report -- so the server was duplicating a facility that already existed,
// and the only thing it added was an app that sat on screen doing nothing.
//
// Read it with:
//   printf 'get REPORT\n' | nc -w 12 <vita> 1341
static void finish_and_hand_back(void) {
  if (g_out) { fclose(g_out); g_out = NULL; }
  hand_back_to_receiver();
}


int main(void) {
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  g_out = fopen(REPORT, "w");
  if (!g_out) {
    return 1;
  }

  say("ADR-0014 experiment -- vitaGL / Ganesh feasibility\n");
  say("=============================================\n\n");

  // 1. Context.
  //
  // Split into attempts rather than one call, because the first run of this
  // experiment reported nothing except `vglInit FAIL`, which does not distinguish
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

  // Point the cache somewhere writable before vitaGL starts. With
  // HAVE_SHADER_CACHE compiled in this actually does something; against the
  // VitaSDK package it is a two-byte no-op.
  vglSetShaderCachePath("ux0:data/shader_cache");

  // Make the shader cache usable before vitaGL starts.
  //
  // The archive carries the cache (vglSetShaderCachePath is defined, and the
  // path format "ux0:data/shader_cache/v%d/f/%08X-%016llX.gxp" is in the
  // binary) but recompiling the identical shader in a later run cost the same
  // 194 ms as the first, so nothing was being written. The likeliest reason is
  // that vitaGL opens the .gxp for writing without creating the directories
  // above it, and sceIoOpen does not make parents. Report whether the tree was
  // already there, then create it.
  {
    SceUID d = sceIoDopen("ux0:data/shader_cache");
    say("shader cache dir %s\n",
        d >= 0 ? "exists" : "absent -- creating");
    if (d >= 0) sceIoDclose(d);
    sceIoMkdir("ux0:data/shader_cache", 0777);
    // The version directory is a number this program does not know, so cover
    // the plausible range; a mkdir that already exists is harmless.
    for (int v = 0; v < 8; v++) {
      char p[64];
      snprintf(p, sizeof p, "ux0:data/shader_cache/v%d", v);
      sceIoMkdir(p, 0777);
      snprintf(p, sizeof p, "ux0:data/shader_cache/v%d/v", v);
      sceIoMkdir(p, 0777);
      snprintf(p, sizeof p, "ux0:data/shader_cache/v%d/f", v);
      sceIoMkdir(p, 0777);
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

  // 3b. What a shader costs to compile at run time.
  //
  // This is the risk ADR-0014's criteria missed. Ganesh generates GLSL per
  // paint configuration and libshacccg compiles it on a 333 MHz ARM, so a GPU
  // backend can trade a slow steady-state frame for a stall every time a new
  // paint appears -- which for a UI toolkit is worse, however fast the
  // steady state gets.
  //
  // vitaGL's shader cache is compiled into the packaged archive
  // (vglSetShaderCachePath is defined, and the .gxp path format strings are in
  // the binary), so the question has two halves: what a cold compile costs,
  // and what the cache saves. Each shader below is textually unique, so every
  // one of them is a cache miss by construction; the fixed pair above has
  // already been compiled by an earlier run and is the warm case.
  // Stop the splash screen before timing anything.
  //
  // vitaGL starts invoke_splashscreen on its own thread inside vglInit and
  // stops it in clear_splashscreen, which runs on the first buffer swap. This
  // experiment renders to an FBO and reads back, so it never swapped and the logo
  // was still rotating at 60 fps through every measurement below -- a render
  // thread competing for the GPU and holding splash_mutex while a compile is
  // supposedly being timed.
  //
  // The tell was in the numbers: twelve samples over two runs, six textually
  // different shaders, all within 191.9-195.0 ms. Compilers vary with their
  // input. That flat a result is something periodic being waited on, not work
  // being done, so the first measurements are void rather than merely noisy.
  enter("vglSwapBuffers (ends the splash screen)");
  vglSwapBuffers(GL_FALSE);
  vglSwapBuffers(GL_FALSE);

  say("\n-- runtime shader compilation cost --\n");
  //
  // Six near-identical shaders all cost the same, which says nothing: they
  // differ by one literal, so identical cost is what a working compiler would
  // also produce. What separates "libshacccg is slow" from "something fixed is
  // paid per link" is whether the time tracks complexity. These three differ by
  // roughly an order of magnitude in arithmetic each.
  {
    static const char* kTrivial =
        "precision mediump float;\n"
        "void main() { gl_FragColor = vec4(%d.0/255.0, 0.0, 0.0, 1.0); }\n";
    static const char* kMedium =
        "precision mediump float;\n"
        "void main() {\n"
        "  vec4 c = vec4(%d.0/255.0);\n"
        "  for (int i = 0; i < 8; i++) c = c * 0.99 + sin(c) * 0.01;\n"
        "  gl_FragColor = c;\n"
        "}\n";
    static const char* kHeavy =
        "precision highp float;\n"
        "void main() {\n"
        "  vec4 c = vec4(%d.0/255.0);\n"
        "  for (int i = 0; i < 64; i++) {\n"
        "    c = c * 0.99 + sin(c) * 0.01 + cos(c.yzwx) * 0.005;\n"
        "    c = normalize(c + vec4(0.001)) * length(c);\n"
        "  }\n"
        "  gl_FragColor = c;\n"
        "}\n";
    struct { const char* name; const char* tmpl; } kCases[] = {
      {"trivial", kTrivial}, {"medium ", kMedium}, {"heavy  ", kHeavy},
    };
    for (unsigned k = 0; k < sizeof kCases / sizeof kCases[0]; k++) {
      char src[1024];
      snprintf(src, sizeof src, kCases[k].tmpl, 40 + (int)k);
      const char* sp = src;
      GLuint sh = glCreateShader(GL_FRAGMENT_SHADER);
      glShaderSource(sh, 1, &sp, NULL);
      glCompileShader(sh);
      GLuint pr = glCreateProgram();
      glAttachShader(pr, vs);
      glAttachShader(pr, sh);
      glBindAttribLocation(pr, 0, "aPos");
      const uint64_t t0 = sceKernelGetProcessTimeWide();
      glLinkProgram(pr);
      GLint lok = 0;
      glGetProgramiv(pr, GL_LINK_STATUS, &lok);
      const uint64_t us = sceKernelGetProcessTimeWide() - t0;
      say("  %s link %7llu us  (%u chars)  %s\n", kCases[k].name,
          (unsigned long long)us, (unsigned)strlen(src),
          lok == GL_TRUE ? "ok" : "FAILED");
      glDeleteProgram(pr);
      glDeleteShader(sh);
    }

    // Same source twice in one process: if the second is free, vitaGL caches
    // in memory and only the on-disk cache is broken.
    char src[256];
    snprintf(src, sizeof src, kTrivial, 99);
    for (int rep = 0; rep < 2; rep++) {
      const char* sp = src;
      GLuint sh = glCreateShader(GL_FRAGMENT_SHADER);
      glShaderSource(sh, 1, &sp, NULL);
      glCompileShader(sh);
      GLuint pr = glCreateProgram();
      glAttachShader(pr, vs);
      glAttachShader(pr, sh);
      glBindAttribLocation(pr, 0, "aPos");
      const uint64_t t0 = sceKernelGetProcessTimeWide();
      glLinkProgram(pr);
      const uint64_t us = sceKernelGetProcessTimeWide() - t0;
      say("  identical source, pass %d: %llu us\n", rep + 1,
          (unsigned long long)us);
      glDeleteProgram(pr);
      glDeleteShader(sh);
    }

    for (int v = 0; v < 4; v++) {
      for (int kk = 0; kk < 2; kk++) {
        char dir[64];
        snprintf(dir, sizeof dir, "ux0:data/shader_cache/v%d/%s", v,
                 kk ? "f" : "v");
        SceUID d = sceIoDopen(dir);
        if (d < 0) continue;
        int n = 0;
        SceIoDirent ent;
        memset(&ent, 0, sizeof ent);
        while (sceIoDread(d, &ent) > 0) { n++; memset(&ent, 0, sizeof ent); }
        sceIoDclose(d);
        say("  cache %s: %d file(s)\n", dir, n);
      }
    }
    say("\n  A frame at 30 fps is 33,333 us. Compare.\n");
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
  say("PHYC  free %u\n", (unsigned)vglMemFree(VGL_MEM_PHYCONT));

  say("\n=============================================\n");
  say("%s (%d failed)\n", g_fail == 0 ? "ALL CHECKS PASSED" : "FAILURES PRESENT", g_fail);

  finish_and_hand_back();
  return 0;
}
