// ADR-0014 spike, criteria 2 to 4: can Ganesh build a GrDirectContext on
// vitaGL, does it draw the right thing, and is it ten times faster?
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
// finishes, which leaves the receiver closed and nothing to read the file with.
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

#include "include/core/SkBitmap.h"
#include "include/core/SkBlendMode.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColorFilter.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkImage.h"
#include "include/core/SkPaint.h"
#include "include/core/SkRRect.h"
#include "include/core/SkSamplingOptions.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrContextOptions.h"
#include "include/gpu/ganesh/GrTypes.h"
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

// Hand the console back to the receiver, exactly as templates/vita-app/bailout.c
// does. Exiting to LiveArea instead leaves the receiver closed, so the next
// deploy stalls waiting for somebody to walk over and tap it -- which is the
// cost ADR-0011 exists to remove, reintroduced by a spike.
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
// while the spike exited to LiveArea, which left no receiver to read the file
// with. Now that it bails to the receiver, the receiver's own `get` command serves
// the report -- so the server was duplicating a facility that already existed,
// and the only thing it added was an app that sat on screen doing nothing.
//
// Read it with:
//   printf 'get REPORT\n' | nc -w 12 <vita> 1341
static void finish_and_hand_back(void) {
  if (g_out) { fclose(g_out); g_out = nullptr; }
  hand_back_to_receiver();
}


// Skia asks for entry points by name; vitaGL resolves them. This is the whole
// bridge between the two, and it is the piece with no precedent -- vitaGL is
// normally used by code that calls gl* directly rather than through a receiver.
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

// ---------------------------------------------------------------------------
// Criteria 3 and 4: do the three expensive operations draw correctly on the
// GPU, and how much faster are they than the software rasteriser?
//
// The three come from the measurement in ADR-0014, not from a list of things
// GPUs are good at. localsend's 199 ms raster pass is one widget:
//
//     Transform.rotate(child: ColorFiltered(child: image 512 -> 200))
//
// and removing only the ColorFiltered took it to ~110 ms, so the colour filter
// is about half and the rotated downscale is the other half. ColorFiltered
// forces a saveLayer, which is the third.
//
// Each is measured on its own *and* as the composite widget, because the
// isolated numbers say where the cost is and only the composite says whether
// localsend gets fixed. A baseline draw -- same image, no scale, no filter, no
// layer -- runs alongside them so ops 1..3 can be read as differences rather
// than absolutes.
// ---------------------------------------------------------------------------

static constexpr int kW = 960;    // the Vita's screen, so the numbers compare
static constexpr int kH = 544;    // directly with the corpus measurements
static constexpr int kIters = 20;
static constexpr int kWarm = 3;
static constexpr SkScalar kCx = 480, kCy = 272;
static constexpr SkScalar kSide = 200;   // localsend draws its logo at 200x200

// The correctness readback covers a 320x320 window centred on the widget --
// large enough to contain the 200x200 square rotated to its 283 px diagonal.
static constexpr int kRegion = 320;
static constexpr int kRegionX = (int)(kCx) - kRegion / 2;
static constexpr int kRegionY = (int)(kCy) - kRegion / 2;

static sk_sp<SkImage> g_src;

// A 512x512 source with deliberate high-frequency content on a **transparent**
// background. Both properties are load-bearing and the first version had
// neither by accident:
//
//   - Detail, because a flat image lets a bilinear downscale look correct
//     while doing nothing, and the question about resampling is what it does
//     to detail.
//   - Transparency, because kSrcATop over an opaque destination is
//     `src * dstAlpha + dst * (1 - srcAlpha)`, and with an opaque tint over an
//     opaque image that is just the tint. The first source had a white
//     background, so the composite rendered a flat 200x200 square of
//     0xFF3B5BDB in **two** colours total -- and two identical flat squares
//     agree perfectly, which is how a meaningless correctness check reports
//     PASS. localsend's logo is a PNG with alpha, so srcATop recolours a shape
//     there rather than erasing one.
static sk_sp<SkImage> make_source_image() {
  SkBitmap bm;
  if (!bm.tryAllocPixels(SkImageInfo::MakeN32Premul(512, 512))) return nullptr;
  SkCanvas c(bm);
  c.clear(SK_ColorTRANSPARENT);

  // Everything lives inside a disc, so the image has a real alpha silhouette
  // and not just a rectangle of pixels.
  c.save();
  c.clipRRect(SkRRect::MakeOval(SkRect::MakeXYWH(16, 16, 480, 480)), true);

  SkPaint p;
  p.setAntiAlias(false);
  for (int y = 0; y < 512; y += 16) {
    for (int x = 0; x < 512; x += 16) {
      // Half the squares stay transparent: alpha varies across the interior,
      // not only at the silhouette.
      p.setColor((((x / 16) ^ (y / 16)) & 1) ? 0xFF202020 : 0x40FFFFFF);
      c.drawRect(SkRect::MakeXYWH(x, y, 16, 16), p);
    }
  }
  p.setAntiAlias(true);
  p.setColor(0x80E03131); c.drawCircle(180, 180, 150, p);
  p.setColor(0xC0339AF0); c.drawCircle(340, 320, 130, p);
  p.setColor(0xFF2F9E44); c.drawCircle(256, 256,  60, p);
  c.restore();

  bm.setImmutable();
  return SkImages::RasterFromBitmap(bm);
}

static SkRect widget_rect() {
  return SkRect::MakeXYWH(kCx - kSide / 2, kCy - kSide / 2, kSide, kSide);
}

static sk_sp<SkColorFilter> tint() {
  // localsend's ColorFilter.mode(primary, BlendMode.srcATop).
  return SkColorFilters::Blend(0xFF3B5BDB, SkBlendMode::kSrcATop);
}

typedef void (*OpFn)(SkCanvas*, int);

// Baseline: one image draw, 1:1, nearest, no filter and no layer.
static void op_baseline(SkCanvas* c, int) {
  const SkSamplingOptions s(SkFilterMode::kNearest, SkMipmapMode::kNone);
  c->drawImageRect(g_src, SkRect::MakeWH(kSide, kSide), widget_rect(), s,
                   nullptr, SkCanvas::kStrict_SrcRectConstraint);
}

// Baseline plus an offscreen. This is the allocate / render / composite cost
// with nothing else in it, and it is what every ColorFiltered, Opacity and
// ShaderMask in a Flutter tree pays.
static void op_savelayer(SkCanvas* c, int i) {
  c->saveLayer(widget_rect(), nullptr);
  op_baseline(c, i);
  c->restore();
}

// Baseline plus a per-pixel blend against a constant colour.
static void op_colorfilter(SkCanvas* c, int) {
  SkPaint p;
  p.setColorFilter(tint());
  const SkSamplingOptions s(SkFilterMode::kNearest, SkMipmapMode::kNone);
  c->drawImageRect(g_src, SkRect::MakeWH(kSide, kSide), widget_rect(), s, &p,
                   SkCanvas::kStrict_SrcRectConstraint);
}

// 512 -> 200 bilinear under a matrix that changes every frame. The changing
// angle is the point: a fixed transform lets Skia cache, and the widget this
// models rotates at 30 fps so nothing ever does.
static void op_rotscale(SkCanvas* c, int i) {
  const SkSamplingOptions s(SkFilterMode::kLinear, SkMipmapMode::kNone);
  c->save();
  c->rotate(i * 12.0f + 7.0f, kCx, kCy);
  c->drawImageRect(g_src, SkRect::MakeWH(512, 512), widget_rect(), s, nullptr,
                   SkCanvas::kStrict_SrcRectConstraint);
  c->restore();
}

// The widget itself. ColorFiltered lowers to a saveLayer whose *paint* carries
// the filter -- the child draws normally into the offscreen and the filter runs
// over the result -- so this is the shape Flutter actually emits, not a colour
// filter bolted onto the image paint.
static void op_composite(SkCanvas* c, int i) {
  const SkSamplingOptions s(SkFilterMode::kLinear, SkMipmapMode::kNone);
  SkPaint layer;
  layer.setColorFilter(tint());
  c->save();
  c->rotate(i * 12.0f + 7.0f, kCx, kCy);
  c->saveLayer(widget_rect(), &layer);
  c->drawImageRect(g_src, SkRect::MakeWH(512, 512), widget_rect(), s, nullptr,
                   SkCanvas::kStrict_SrcRectConstraint);
  c->restore();
  c->restore();
}

struct Op { const char* name; OpFn fn; };
static const Op kOps[] = {
    {"baseline image draw", op_baseline},
    {"saveLayer", op_savelayer},
    {"colour filter", op_colorfilter},
    {"rotated 512->200", op_rotscale},
    {"localsend composite", op_composite},
};
static const int kNumOps = (int)(sizeof kOps / sizeof kOps[0]);

// GPU work is asynchronous, so a timing loop that only records commands
// measures the driver's command buffer. GrSyncCpu::kYes makes Skia call
// glFinish, which vitaGL implements as sceGxmFinish -- a real wait on the GPU.
static void gpu_sync(GrDirectContext* ctx, SkSurface* s) {
  ctx->flushAndSubmit(s, GrSyncCpu::kYes);
}

struct Result {
  double sw_us;      // software, per iteration
  double gpu_us;     // GPU, one submit-and-wait per iteration
  double gpu_bat_us; // GPU, kIters iterations then one submit-and-wait
  double warm_us;    // first-ever draw, which is where shader compilation lands
};

static double bench_sw(SkSurface* s, OpFn fn) {
  SkCanvas* c = s->getCanvas();
  for (int i = 0; i < kWarm; i++) fn(c, i);
  const uint64_t t0 = sceKernelGetProcessTimeWide();
  for (int i = 0; i < kIters; i++) fn(c, i);
  return (double)(sceKernelGetProcessTimeWide() - t0) / kIters;
}

static void bench_gpu(GrDirectContext* ctx, SkSurface* s, OpFn fn, Result* r) {
  SkCanvas* c = s->getCanvas();

  // The first draw of a given paint configuration is where Ganesh generates
  // and links its GLSL, which criterion 0 measured at ~250 ms cold and ~3 ms
  // from the cache. Reported separately rather than folded into the mean,
  // because it is a once-per-shader cost and the steady state is not.
  const uint64_t w0 = sceKernelGetProcessTimeWide();
  fn(c, 0);
  gpu_sync(ctx, s);
  r->warm_us = (double)(sceKernelGetProcessTimeWide() - w0);

  for (int i = 1; i < kWarm; i++) fn(c, i);
  gpu_sync(ctx, s);

  const uint64_t t0 = sceKernelGetProcessTimeWide();
  for (int i = 0; i < kIters; i++) { fn(c, i); gpu_sync(ctx, s); }
  r->gpu_us = (double)(sceKernelGetProcessTimeWide() - t0) / kIters;

  const uint64_t t1 = sceKernelGetProcessTimeWide();
  for (int i = 0; i < kIters; i++) fn(c, i);
  gpu_sync(ctx, s);
  r->gpu_bat_us = (double)(sceKernelGetProcessTimeWide() - t1) / kIters;
}

// Criterion 3. "The output is correct" has no oracle on this console, so
// correctness is defined as agreement with the software rasteriser, which is
// the path the port ships today and the one the corpus screenshots came from.
//
// The non-blank counts are load-bearing: two identical blank surfaces agree
// perfectly, and that is the failure this check exists to catch.
struct Diff {
  int nonblank_sw, nonblank_gpu;
  int distinct_gpu, distinct_sw;  // see count_distinct
  double mean_err, pct_over_8, pct_over_24;
  int max_err;
};

// How many different colours are actually on the surface, quantised to RGB565
// so that antialiasing noise does not inflate it.
//
// This exists because the first run of criterion 3 passed on an image that had
// been reduced to two colours. Non-blank does not mean drawn: a solid fill is
// as non-blank as a photograph, and a check that cannot tell them apart cannot
// answer "is the output correct".
static int count_distinct(const uint8_t* buf, size_t n) {
  static uint32_t seen[65536 / 32];
  memset(seen, 0, sizeof seen);
  int distinct = 0;
  for (size_t px = 0; px < n; px++) {
    const uint8_t* q = buf + px * 4;
    const unsigned key = ((q[0] >> 3) << 11) | ((q[1] >> 2) << 5) | (q[2] >> 3);
    if (seen[key >> 5] & (1u << (key & 31))) continue;
    seen[key >> 5] |= 1u << (key & 31);
    distinct++;
  }
  return distinct;
}

static bool compare_region(GrDirectContext* ctx, SkSurface* gpu, SkSurface* sw,
                           OpFn fn, const SkImageInfo& region_info,
                           uint8_t* buf_gpu, uint8_t* buf_sw, Diff* d) {
  const size_t rb = region_info.minRowBytes();

  gpu->getCanvas()->clear(SK_ColorBLACK);
  fn(gpu->getCanvas(), 3);
  gpu_sync(ctx, gpu);

  sw->getCanvas()->clear(SK_ColorBLACK);
  fn(sw->getCanvas(), 3);

  if (!gpu->readPixels(region_info, buf_gpu, rb, kRegionX, kRegionY)) return false;
  if (!sw->readPixels(region_info, buf_sw, rb, kRegionX, kRegionY)) return false;

  const size_t n = (size_t)kRegion * kRegion;
  long long sum = 0;
  int over8 = 0, over24 = 0;
  *d = Diff{};
  for (size_t px = 0; px < n; px++) {
    const uint8_t* a = buf_gpu + px * 4;
    const uint8_t* b = buf_sw + px * 4;
    int worst = 0;
    for (int ch = 0; ch < 4; ch++) {
      const int delta = a[ch] > b[ch] ? a[ch] - b[ch] : b[ch] - a[ch];
      if (delta > worst) worst = delta;
    }
    sum += worst;
    if (worst > 8) over8++;
    if (worst > 24) over24++;
    if (worst > d->max_err) d->max_err = worst;
    // Anything not still the black we cleared to
    if (a[0] || a[1] || a[2]) d->nonblank_gpu++;
    if (b[0] || b[1] || b[2]) d->nonblank_sw++;
  }
  d->distinct_gpu = count_distinct(buf_gpu, n);
  d->distinct_sw = count_distinct(buf_sw, n);
  d->mean_err = (double)sum / (double)n;
  d->pct_over_8 = 100.0 * over8 / (double)n;
  d->pct_over_24 = 100.0 * over24 / (double)n;
  return true;
}

static void dump_raw(const char* path, const uint8_t* buf, size_t bytes) {
  FILE* f = fopen(path, "wb");
  if (!f) return;
  fwrite(buf, 1, bytes, f);
  fclose(f);
}

static void run_benchmarks(GrDirectContext* ctx) {
  say("\n\n-- criteria 3 and 4 --\n");

  enter("make 512x512 source image");
  g_src = make_source_image();
  check("source image", g_src != nullptr, "");
  if (!g_src) return;

  // N32 is what the engine's software surface uses. If Ganesh cannot make a
  // renderable target in it, fall back and say so -- but both surfaces must
  // agree on the colour type or the pixel comparison is comparing channel
  // orders.
  SkColorType ct = kN32_SkColorType;
  SkImageInfo info = SkImageInfo::Make(kW, kH, ct, kPremul_SkAlphaType);
  enter("SkSurfaces::RenderTarget 960x544");
  sk_sp<SkSurface> gpu =
      SkSurfaces::RenderTarget(ctx, skgpu::Budgeted::kYes, info);
  if (!gpu) {
    ct = kRGBA_8888_SkColorType;
    info = SkImageInfo::Make(kW, kH, ct, kPremul_SkAlphaType);
    gpu = SkSurfaces::RenderTarget(ctx, skgpu::Budgeted::kYes, info);
    say("N32 render target failed; fell back to kRGBA_8888\n");
  }
  check("960x544 GPU surface", gpu != nullptr, "");
  if (!gpu) return;

  sk_sp<SkSurface> sw = SkSurfaces::Raster(info);
  check("960x544 raster surface", sw != nullptr, "");
  if (!sw) return;
  say("colour type %d (N32 is %d)\n\n", (int)ct, (int)kN32_SkColorType);

  // ---- criterion 3 -------------------------------------------------------
  const SkImageInfo region = SkImageInfo::Make(kRegion, kRegion, ct,
                                               kPremul_SkAlphaType);
  const size_t region_bytes = region.minRowBytes() * kRegion;
  uint8_t* buf_gpu = (uint8_t*)malloc(region_bytes);
  uint8_t* buf_sw = (uint8_t*)malloc(region_bytes);

  if (buf_gpu && buf_sw) {
    say("-- criterion 3: GPU output against the software rasteriser --\n");
    say("%-22s %7s %7s %6s %6s %7s %5s %6s %6s\n", "operation", "px gpu",
        "px sw", "col g", "col s", "mean", "max", ">8", ">24");
    for (int i = 0; i < kNumOps; i++) {
      enter(kOps[i].name);
      Diff d;
      if (!compare_region(ctx, gpu.get(), sw.get(), kOps[i].fn, region,
                          buf_gpu, buf_sw, &d)) {
        check(kOps[i].name, false, "readPixels failed");
        continue;
      }
      say("%-22s %7d %7d %6d %6d %7.2f %5d %5.2f%% %5.2f%%\n", kOps[i].name,
          d.nonblank_gpu, d.nonblank_sw, d.distinct_gpu, d.distinct_sw,
          d.mean_err, d.max_err, d.pct_over_8, d.pct_over_24);

      // Both drew something, they drew it in the same place, and they agree
      // almost everywhere. Edges will not match -- two different rasterisers
      // antialias differently -- so the bar is on the bulk, not the maximum.
      const bool drew = d.nonblank_gpu > 5000 && d.nonblank_sw > 5000 &&
                        d.distinct_gpu >= 16 && d.distinct_sw >= 16;
      const bool same_coverage =
          drew && (double)d.nonblank_gpu / d.nonblank_sw > 0.9 &&
          (double)d.nonblank_gpu / d.nonblank_sw < 1.1;
      char note[96];
      snprintf(note, sizeof note, "%s%s%s",
               drew ? "" : "blank, or too few distinct colours to mean anything; ",
               same_coverage ? "" : "coverage differs; ",
               d.pct_over_24 < 5.0 ? "" : "over 5% of pixels differ by >24");
      check("  correct", drew && same_coverage && d.pct_over_24 < 5.0, note);
    }

    // The composite pair goes to disk as raw pixels. Numbers can agree while
    // both images are wrong in the same way; this is the one that gets looked
    // at.
    enter("dump composite pair");
    Diff d;
    if (compare_region(ctx, gpu.get(), sw.get(), op_composite, region, buf_gpu,
                       buf_sw, &d)) {
      dump_raw("ux0:data/flutter-vita/g2-composite-gpu.raw", buf_gpu,
               region_bytes);
      dump_raw("ux0:data/flutter-vita/g2-composite-sw.raw", buf_sw,
               region_bytes);
      say("wrote %dx%d raw pairs (%u bytes each, colour type %d)\n", kRegion,
          kRegion, (unsigned)region_bytes, (int)ct);
    }
  }
  free(buf_gpu);
  free(buf_sw);

  // ---- criterion 4 -------------------------------------------------------
  say("\n-- criterion 4: microseconds per operation, bar is 10x --\n");
  say("%-22s %10s %10s %10s %8s %8s %10s\n", "operation", "software", "gpu",
      "gpu batch", "x", "x batch", "first draw");

  Result results[kNumOps];
  for (int i = 0; i < kNumOps; i++) {
    Result r = {};
    enter(kOps[i].name);
    sw->getCanvas()->clear(SK_ColorBLACK);
    r.sw_us = bench_sw(sw.get(), kOps[i].fn);
    gpu->getCanvas()->clear(SK_ColorBLACK);
    bench_gpu(ctx, gpu.get(), kOps[i].fn, &r);
    results[i] = r;
    say("%-22s %10.0f %10.0f %10.0f %8.1f %8.1f %10.0f\n", kOps[i].name,
        r.sw_us, r.gpu_us, r.gpu_bat_us,
        r.gpu_us > 0 ? r.sw_us / r.gpu_us : 0.0,
        r.gpu_bat_us > 0 ? r.sw_us / r.gpu_bat_us : 0.0, r.warm_us);
  }

  // The verdict is taken on the composite and on the per-submit column, not on
  // the batched one. The composite because it is the widget that produced the
  // 199 ms frame; per-submit because a frame ends in a submit whether or not
  // the ops inside it pipeline, and claiming the batched figure would be
  // measuring a frame that never happens.
  const Result& c = results[kNumOps - 1];
  const double ratio = c.gpu_us > 0 ? c.sw_us / c.gpu_us : 0.0;
  say("\ncomposite widget: %.0f us software, %.0f us GPU -> %.1fx\n", c.sw_us,
      c.gpu_us, ratio);
  check("criterion 4 (10x on the composite)", ratio >= 10.0,
        ratio >= 10.0 ? "" : "below the bar set in ADR-0014");
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
  // the receiver will not resolve, so the shim list can be written once.
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

    run_benchmarks(ctx.get());
  }

  say("\n==================================\n");
  say("%s (%d failed)\n",
      g_fail == 0 ? "ALL CHECKS PASSED" : "FAILURES PRESENT", g_fail);
  finish_and_hand_back();
  return 0;
}
