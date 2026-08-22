// ADR-0014 spike, criterion 2: can Ganesh build a GrDirectContext on vitaGL?
//
// g1 proved the GL context itself: runtime shader compilation, program
// linkage, render-to-texture and a correct readback, all on hardware. It said
// nothing about Skia, which is the half of criterion 2 that can actually fail
// on something not already known -- the engine now *compiles* Skia's GLES
// backend for arm-vita-eabi and defines GrDirectContexts::MakeGL(), and
// whether that function returns a context when handed vitaGL is a different
// question from whether it links.
//
// Reports over TCP and exits, same as g1: the app returns to LiveArea when it
// finishes, which leaves the loader closed and nothing to read the file with.
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <psp2/appmgr.h>
#include <psp2/gxm.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>

#include <vitaGL.h>

#include "required_names.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkPaint.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrContextOptions.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLInterface.h"

#define REPORT "ux0:data/flutter-vita/ganesh-spike.txt"

// vitaGL wants a real heap; g1 established 64 MB is enough for a context.
// Ganesh allocates on top of that, so this is larger.
extern "C" unsigned int _newlib_heap_size_user = 128 * 1024 * 1024;

// The Vita's main thread gets a small default stack, and Skia's context
// construction is a deep chain of nested C++ constructors. spikes/m1-vpk
// already raises this for the same reason, so the project has met the limit
// before; this spike had not set it, and the fault is inside a constructor
// several frames down from MakeGL.
extern "C" unsigned int sceUserMainThreadStackSize = 1 * 1024 * 1024;

// Thread-safe statics, supplied because libstdc++'s are not usable here.
//
// A function-local static with a dynamic initialiser -- `static T* p = new
// T();` -- compiles to a __cxa_guard_acquire / __cxa_guard_release pair around
// the construction. Those come from libstdc++, and on this statically linked
// VitaSDK build calling one faults: the probe in main() shows a plain `new`
// succeeding and the identical allocation behind a function-local static
// killing the process.
//
// These are the ARM EABI shape: the guard is a 32-bit word whose low bit means
// "already initialised". They are correct for single-threaded initialisation
// and nothing more, which is what this spike does -- everything here runs on
// the main thread before any Skia worker exists. A real fix belongs in the
// engine build rather than in one program's translation unit.
//
// Defining them here overrides the archive's, so Skia's own function-local
// statics -- SkMessageBus::Get() being the one that faulted -- use these too.
extern "C" {
int __cxa_guard_acquire(int* g) { return !(*g & 1); }
void __cxa_guard_release(int* g) { *g = 1; }
void __cxa_guard_abort(int*) {}
}

static FILE* g_out;
static int g_fail;

static void say(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(g_out, fmt, ap);
  va_end(ap);
  fflush(g_out);
}

// The last `>>` on disk is the call that did not return. There is no debugger
// on this console and no way to interrupt a hang, so this is the only way to
// locate one.
static void enter(const char* what) { say(">> %s\n", what); }

static void check(const char* what, bool ok, const char* detail) {
  say("%-34s %s%s%s\n", what, ok ? "PASS" : "FAIL",
      detail && detail[0] ? "  " : "", detail ? detail : "");
  if (!ok) g_fail++;
}

// Hand the console back to the loader, exactly as templates/vita-app/bailout.c
// does. Exiting to LiveArea instead leaves the loader closed, so the next
// deploy stalls waiting for somebody to walk over and tap it -- which is the
// cost ADR-0011 exists to remove, reintroduced by a spike.
//
// Nothing may go between the launch and the exit. The "close the current
// application?" prompt appears only while the outgoing app is still alive; a
// sceKernelDelayThread here cost a prompt on every single bail until it was
// removed from bailout.c.
#define VITA_LOADER_TITLEID "FVTA00003"

static void hand_back_to_loader(void) {
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
// while the spike exited to LiveArea, which left no loader to read the file
// with. Now that it bails to the loader, the loader's own `get` command serves
// the report -- so the server was duplicating a facility that already existed,
// and the only thing it added was an app that sat on screen doing nothing.
//
// Read it with:
//   printf 'get REPORT\n' | nc -w 12 <vita> 1341
static void finish_and_hand_back(void) {
  if (g_out) { fclose(g_out); g_out = nullptr; }
  hand_back_to_loader();
}


// Skia asks for entry points by name; vitaGL resolves them. This is the whole
// bridge between the two, and it is the piece with no precedent -- vitaGL is
// normally used by code that calls gl* directly rather than through a loader.
// vitaGL is an incomplete GLES2: three functions Skia requires *unconditionally*
// are declared in GLES2/gl2.h and not implemented. Found by diffing the 92
// names in GrGLInterface::validate's unconditional block against the archive's
// symbol table, after validate() rejected the assembled interface and MakeGL
// returned null.
//
//   glTexParameterfv          -- shimmable exactly
//   glBlendColor              -- shimmable only as a no-op; see below
//   glCompressedTexSubImage2D -- stub; Skia gates real use on caps
//   glGetRenderbufferParameteriv -- stub; found second, from the framebuffer
//                                   block at GrGLInterfaceAutogen.cpp:490
//
// These exist to find out whether those three are the *only* thing in the way.
// Two of them are not honest implementations and must not be mistaken for one.
extern "C" {

// Exact. Every pname Skia passes here is scalar, so the vector form is the
// scalar form with one element.
static void vita_glTexParameterfv(GLenum target, GLenum pname,
                                  const GLfloat* params) {
  glTexParameterf(target, pname, params[0]);
}

// NOT exact. vitaGL exposes no constant blend colour, so this drops the value
// on the floor: correct only for as long as Skia never selects a
// constant-colour blend coefficient. Whether that holds is a question for
// criterion 3, and if it does not the fix is in vitaGL rather than here.
static void vita_glBlendColor(GLfloat, GLfloat, GLfloat, GLfloat) {}

// Stub. Skia gates compressed-texture *updates* on caps it queries
// separately, so the pointer has to be non-null to pass validation while the
// path behind it stays unreached.
static void vita_glCompressedTexSubImage2D(GLenum, GLint, GLint, GLint,
                                           GLsizei, GLsizei, GLenum, GLsizei,
                                           const void*) {}

// Tracing wrappers.
//
// MakeGL dies with no output of its own, and the report is flushed line by
// line, so the last trace on disk is the call that did not return. GrGLCaps
// init is almost entirely these two, and vitaGL is an incomplete GLES2 -- an
// unrecognised pname that leaves the out-parameter untouched hands Skia
// whatever was on the stack.
static int g_trace;

// Overrides the engine's weak no-op. Every Skia GL call reports here while
// tracing is on, and the report is flushed line by line -- so after a hard
// fault the last line on disk is the call site that did not return. Only the
// file's basename, because the full path repeated a few hundred times is
// unreadable and identical on every line.
extern "C" void fvita_gl_trace(const char* file, int line) {
  if (!g_trace || !g_out) return;
  const char* slash = strrchr(file, '/');
  say("  @ %s:%d\n", slash ? slash + 1 : file, line);
}

static void vita_glGetIntegerv(GLenum pname, GLint* params) {
  if (params) *params = 0;  // so an unhandled pname is 0, not stack garbage
  if (g_trace) say("  glGetIntegerv(0x%04X)\n", (unsigned)pname);

  // Report zero program binary formats, which switches Skia's program-binary
  // path off at its own branch:
  //
  //     GR_GL_GetIntegerv(gli, GR_GL_NUM_PROGRAM_BINARY_FORMATS, &count);
  //     if (count > 0) { ... } else { fProgramBinarySupport = false; }
  //         -- GrGLCaps.cpp:847
  //
  // vitaGL answers 1 here and advertises GL_OES_get_program_binary, and the
  // trace stops on the very next call. Claiming an extension without providing
  // its entry points is a thing this driver does -- GL_EXT_debug_marker was the
  // case that broke validate() -- so this tests whether it is doing it again.
  if (pname == 0x87FE) {  // GL_NUM_PROGRAM_BINARY_FORMATS
    if (params) *params = 0;
    if (g_trace) say("    -> 0 (forced; program binaries disabled)\n");
    return;
  }

  glGetIntegerv(pname, params);
  if (g_trace) say("    -> %d\n", params ? (int)*params : 0);
}

static const GLubyte* vita_glGetString(GLenum name) {
  if (g_trace) say("  glGetString(0x%04X)\n", (unsigned)name);
  const GLubyte* r = glGetString(name);
  if (g_trace) say("    -> %s\n", r ? (const char*)r : "(null)");
  return r;
}

// Stub. Skia calls this to interrogate a renderbuffer it did not create --
// dimensions, format, sample count. Ganesh allocates its own render targets
// here, so the query should not be reached; returning zeroes is wrong but
// unreached, and the pointer has to exist for validate() to pass.
static void vita_glGetRenderbufferParameteriv(GLenum, GLenum, GLint* params) {
  if (params) *params = 0;
}

// Genuinely correct as a no-op: an event marker is a debug annotation for a
// GPU profiler and has no rendering effect. vitaGL advertises
// GL_EXT_debug_marker in GL_EXTENSIONS and implements only two of the three
// entry points that extension promises, which is why Skia asked for it.
static void vita_glInsertEventMarker(GLsizei, const GLchar*) {}

// Stub with real values, and the one most likely to be wrong.
//
// Skia uses this to decide what precision qualifiers to emit. These are the
// values a driver reports for highp float; the SGX543 supports highp properly
// in vertex shaders and approximates it in fragment shaders, so claiming it
// unconditionally may cost speed or accuracy. Flagged for criterion 3, which
// is where a wrong answer here would show up as artifacts rather than a
// failure to start.
static void vita_glGetShaderPrecisionFormat(GLenum, GLenum precisiontype,
                                            GLint* range, GLint* precision) {
  // Spelled numerically: vitaGL's headers omit GL_LOW_INT/MEDIUM_INT/HIGH_INT
  // even though it advertises GLES2, which is the same gap as the missing
  // functions, one layer up.
  const bool is_int = precisiontype == 0x8DF3 ||  // GL_LOW_INT
                      precisiontype == 0x8DF4 ||  // GL_MEDIUM_INT
                      precisiontype == 0x8DF5;    // GL_HIGH_INT
  if (range) { range[0] = 127; range[1] = 127; }
  if (precision) *precision = is_int ? 0 : 23;
}

}  // extern "C"

static int g_shimmed;
static int g_desuffixed;

// Set by a TEMPORARY diagnostic patch to Skia's RETURN_FALSE_INTERFACE macro.
// validate() has 55 return-false branches and, in a release build, reports
// which one fired to nobody. Zero means the patch is not in this engine.
extern "C" int g_skia_validate_fail_line;

static GrGLFuncPtr vita_get_proc(void*, const char name[]) {
  struct { const char* name; GrGLFuncPtr fn; } kShims[] = {
    {"glTexParameterfv", reinterpret_cast<GrGLFuncPtr>(vita_glTexParameterfv)},
    {"glBlendColor", reinterpret_cast<GrGLFuncPtr>(vita_glBlendColor)},
    {"glCompressedTexSubImage2D",
     reinterpret_cast<GrGLFuncPtr>(vita_glCompressedTexSubImage2D)},
    {"glGetIntegerv", reinterpret_cast<GrGLFuncPtr>(vita_glGetIntegerv)},
    {"glGetString", reinterpret_cast<GrGLFuncPtr>(vita_glGetString)},
    {"glGetRenderbufferParameteriv",
     reinterpret_cast<GrGLFuncPtr>(vita_glGetRenderbufferParameteriv)},
    // The name Skia asks for, not the name the spec calls it.
    {"glInsertEventMarkerEXT",
     reinterpret_cast<GrGLFuncPtr>(vita_glInsertEventMarker)},
    {"glGetShaderPrecisionFormat",
     reinterpret_cast<GrGLFuncPtr>(vita_glGetShaderPrecisionFormat)},
  };
  for (const auto& s : kShims) {
    if (strcmp(name, s.name) == 0) {
      if (!vglGetProcAddress(name)) g_shimmed++;  // traced ones do resolve
      return s.fn;
    }
  }

  if (void* p = vglGetProcAddress(name)) {
    return reinterpret_cast<GrGLFuncPtr>(p);
  }

  // Retry without the vendor suffix.
  //
  // Skia's assembler asks for extension entry points by their suffixed names --
  // GET_PROC_SUFFIX(PopGroupMarker, EXT) requests "glPopGroupMarkerEXT" -- while
  // vitaGL exports the core spelling, "glPopGroupMarker", and no alias. So a
  // function that is present fails to resolve purely on its name, which is why
  // an offline symbol-table diff said the debug-marker block was satisfied and
  // the console disagreed.
  static const char* const kSuffixes[] = {
      "EXT", "OES", "ARB", "KHR", "APPLE", "ANGLE", "NV", "IMG"};
  const size_t len = strlen(name);
  for (const char* suffix : kSuffixes) {
    const size_t slen = strlen(suffix);
    if (len <= slen || strcmp(name + len - slen, suffix) != 0) continue;
    char base[128];
    if (len - slen >= sizeof base) continue;
    memcpy(base, name, len - slen);
    base[len - slen] = '\0';
    if (void* p = vglGetProcAddress(base)) {
      g_desuffixed++;
      return reinterpret_cast<GrGLFuncPtr>(p);
    }
  }
  // Every name Skia asked for and did not get. A driver that advertises an
  // extension without its entry points -- which vitaGL does, GL_EXT_debug_marker
  // being the case that broke validate() -- defeats Skia's null checks, because
  // Skia trusts the extension string and calls straight through. Any name here
  // is a candidate for the jump to zero that ends this program.
  say("  UNRESOLVED %s\n", name);
  return nullptr;
}

int main() {
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  g_out = fopen(REPORT, "w");
  if (!g_out) return 1;

  // The fault is inside SkMessageBus::Get(), which is
  //
  //     static auto* bus = new SkMessageBus<...>();
  //
  // -- a function-local static and a new, with no Skia or GL in it. If that
  // pattern is broken in this binary then the problem is the C++ runtime on a
  // statically linked VitaSDK build, not Ganesh, and it would be a much larger
  // fact about the port than a GPU backend. Testing it before assuming Skia.
  say("-- C++ runtime probes --\n");
  {
    int* heap = new int(42);
    say("plain new                  %s\n", (heap && *heap == 42) ? "ok" : "FAIL");
    delete heap;
  }
  {
    struct Probe { int v; Probe() : v(7) {} };
    auto local_static = []() -> Probe* {
      static Probe* p = new Probe();  // exactly SkMessageBus::Get()'s shape
      return p;
    };
    Probe* a = local_static();
    Probe* b = local_static();
    say("function-local static new  %s (same=%d, v=%d)\n",
        (a && a->v == 7 && a == b) ? "ok" : "FAIL", a == b, a ? a->v : -1);
  }
  say("\n");

  say("ADR-0014 spike -- Ganesh on vitaGL\n");
  say("==================================\n\n");

  // g1 established that vglInit returns GL_FALSE on a context that works, so
  // the return value is recorded and not believed.
  // vglInitExtended, not vglInit, and the fourth argument is the point.
  //
  // vglInit takes the newlib heap for vitaGL's own RAM pool and leaves only
  // ram_threshold behind -- 16 MB by default. Everything Skia allocates goes
  // through malloc, so Ganesh was being handed 16 MB to build a GrDirectContext
  // in, and MakeGL never returned. This leaves 64 MB of the 128 MB heap for
  // malloc and gives the rest to vitaGL.
  vglSetShaderCachePath("ux0:data/shader_cache");
  enter("vglInitExtended(0x100000, 960, 544, 64 MiB threshold)");
  const GLboolean up = vglInitExtended(0x100000, 960, 544,
                                       64 * 1024 * 1024,
                                       SCE_GXM_MULTISAMPLE_NONE);
  say("vglInit returned %d%s\n", (int)up,
      up == GL_TRUE ? "" : "  <- known vitaGL quirk, see ADR-0014");

  const char* ver = (const char*)glGetString(GL_VERSION);
  say("GL_VERSION %s\n\n", ver ? ver : "(null)");

  const char* ext = (const char*)glGetString(GL_EXTENSIONS);
  say("GL_EXTENSIONS %s\n\n", ext ? ext : "(null)");

  // One run, complete answer. Iterating validate()'s branches a deploy at a
  // time found three gaps and was going to find more; this reports every name
  // the loader will not resolve, so the shim list can be written once.
  say("-- names vglGetProcAddress will not resolve --\n");
  int unresolved = 0;
  for (size_t i = 0; i < sizeof kRequiredNames / sizeof kRequiredNames[0]; i++) {
    if (!vglGetProcAddress(kRequiredNames[i])) {
      say("  %s\n", kRequiredNames[i]);
      unresolved++;
    }
  }
  say("  (%d of %u)\n\n", unresolved,
      (unsigned)(sizeof kRequiredNames / sizeof kRequiredNames[0]));

  enter("GrGLMakeAssembledGLESInterface");
  sk_sp<const GrGLInterface> iface =
      GrGLMakeAssembledGLESInterface(nullptr, vita_get_proc);
  say("shims supplied for %d function(s) vitaGL does not implement\n",
      g_shimmed);
  say("resolved %d more by stripping a vendor suffix\n", g_desuffixed);
  check("assemble GL interface", iface != nullptr,
        iface ? "" : "vglGetProcAddress resolved too few entry points");

  if (iface) {
    enter("GrGLInterface::validate");
    const bool valid = iface->validate();
    char b[128];
    snprintf(b, sizeof b,
             "GrGLInterfaceAutogen.cpp:%d", g_skia_validate_fail_line);
    check("interface validates", valid, valid ? "" : b);
  }

  if (!iface) {
    say("\nNo GL interface; a context cannot be built without one.\n");
    say("\n==================================\n");
    say("FAILURES PRESENT (%d failed)\n", g_fail);
    finish_and_hand_back();
    return 1;
  }

  // Free malloc heap immediately before the call that died, because the
  // hypothesis under test is that there is not enough of it.
  {
    size_t probe = 0;
    for (size_t mb = 64; mb >= 1; mb /= 2) {
      void* p = malloc(mb * 1024 * 1024);
      if (p) { free(p); probe = mb; break; }
    }
    say("\nlargest single malloc that succeeds: %u MiB\n", (unsigned)probe);
  }

  say("\n-- tracing GL queries; the last line is the call that did not return --\n");
  g_trace = 1;
  enter("GrDirectContexts::MakeGL");
  GrContextOptions options;
  sk_sp<GrDirectContext> ctx = GrDirectContexts::MakeGL(iface, options);
  g_trace = 0;
  check("GrDirectContext created", ctx != nullptr,
        ctx ? "" : "MakeGL returned null");

  if (ctx) {
    say("\n-- what Ganesh thinks it is talking to --\n");
    say("backend                     %d (0 = kOpenGL)\n",
        (int)ctx->backend());
    say("maxTextureSize              %d\n", ctx->maxTextureSize());
    say("maxRenderTargetSize         %d\n", ctx->maxRenderTargetSize());

    // A render target is what every saveLayer needs, and it is the operation
    // the whole GPU direction exists to make cheaper.
    enter("SkSurfaces::RenderTarget");
    SkImageInfo info = SkImageInfo::MakeN32Premul(256, 256);
    sk_sp<SkSurface> surface = SkSurfaces::RenderTarget(
        ctx.get(), skgpu::Budgeted::kYes, info);
    check("GPU render target surface", surface != nullptr,
          surface ? "" : "SkSurfaces::RenderTarget returned null");

    if (surface) {
      enter("draw and flush");
      SkCanvas* canvas = surface->getCanvas();
      canvas->clear(SK_ColorGREEN);
      SkPaint paint;
      paint.setColor(SK_ColorRED);
      paint.setAntiAlias(true);
      canvas->drawCircle(128, 128, 64, paint);
      ctx->flushAndSubmit();
      check("draw and submit", true, "no fault");
    }
  }

  say("\n==================================\n");
  say("%s (%d failed)\n",
      g_fail == 0 ? "ALL CHECKS PASSED" : "FAILURES PRESENT", g_fail);
  finish_and_hand_back();
  return 0;
}
