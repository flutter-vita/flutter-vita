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
#include <cstring>

#include <psp2/appmgr.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>

#include <vitaGL.h>

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
  sceAppMgrLaunchAppByUri(0xFFFFF, "psgm:play?titleid=" VITA_LOADER_TITLEID);
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

}  // extern "C"

static int g_shimmed;

static GrGLFuncPtr vita_get_proc(void*, const char name[]) {
  struct { const char* name; GrGLFuncPtr fn; } kShims[] = {
    {"glTexParameterfv", reinterpret_cast<GrGLFuncPtr>(vita_glTexParameterfv)},
    {"glBlendColor", reinterpret_cast<GrGLFuncPtr>(vita_glBlendColor)},
    {"glCompressedTexSubImage2D",
     reinterpret_cast<GrGLFuncPtr>(vita_glCompressedTexSubImage2D)},
  };
  for (const auto& s : kShims) {
    if (strcmp(name, s.name) == 0) {
      if (!vglGetProcAddress(name)) g_shimmed++;
      return s.fn;
    }
  }
  return reinterpret_cast<GrGLFuncPtr>(vglGetProcAddress(name));
}

int main() {
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  g_out = fopen(REPORT, "w");
  if (!g_out) return 1;

  say("ADR-0014 spike -- Ganesh on vitaGL\n");
  say("==================================\n\n");

  // g1 established that vglInit returns GL_FALSE on a context that works, so
  // the return value is recorded and not believed.
  enter("vglInit(0x100000)");
  const GLboolean up = vglInit(0x100000);
  say("vglInit returned %d%s\n", (int)up,
      up == GL_TRUE ? "" : "  <- known vitaGL quirk, see ADR-0014");

  const char* ver = (const char*)glGetString(GL_VERSION);
  say("GL_VERSION %s\n\n", ver ? ver : "(null)");

  const char* ext = (const char*)glGetString(GL_EXTENSIONS);
  say("GL_EXTENSIONS %s\n\n", ext ? ext : "(null)");

  enter("GrGLMakeAssembledGLESInterface");
  sk_sp<const GrGLInterface> iface =
      GrGLMakeAssembledGLESInterface(nullptr, vita_get_proc);
  say("shims supplied for %d function(s) vitaGL does not implement\n",
      g_shimmed);
  check("assemble GL interface", iface != nullptr,
        iface ? "" : "vglGetProcAddress resolved too few entry points");

  if (iface) {
    enter("GrGLInterface::validate");
    const bool valid = iface->validate();
    check("interface validates", valid,
          valid ? "" : "Skia rejected the assembled interface");
  }

  if (!iface) {
    say("\nNo GL interface; a context cannot be built without one.\n");
    say("\n==================================\n");
    say("FAILURES PRESENT (%d failed)\n", g_fail);
    finish_and_hand_back();
    return 1;
  }

  enter("GrDirectContexts::MakeGL");
  GrContextOptions options;
  sk_sp<GrDirectContext> ctx = GrDirectContexts::MakeGL(iface, options);
  check("GrDirectContext created", ctx != nullptr,
        ctx ? "" : "MakeGL returned null");

  if (ctx) {
    say("\n-- what Ganesh thinks it is talking to --\n");
    say("backend                     %d (1 = OpenGL)\n",
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
