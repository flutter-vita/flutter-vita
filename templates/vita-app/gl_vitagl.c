// The GL platform under Ganesh, provided by vitaGL (ADR-0014).
//
// One of two answers to flutter_vita_gl.h; gl_gles2.c is the other, and
// FLUTTER_VITA_GL in CMakeLists.txt picks. This one leaves with ADR-0019's
// M5, and everything vitaGL-specific the embedder used to do at start-up
// lives here until then.
#include <psp2/gxm.h>
#include <psp2/io/stat.h>
#include <stdio.h>
#include <vitaGL.h>

#include "flutter_vita_gl.h"

// kGlRamThresholdBytes is the one to reach for if the engine starts failing
// allocations under GL. vitaGL claims the newlib arena for its own RAM pool
// and leaves *this much* behind for malloc; its own default is 16 MB, which is
// not enough to build a GrDirectContext in. heap.c sizes the arena at 160 MB,
// so this leaves vitaGL roughly 40 MB and the engine the rest -- and the
// software surfaces the CPU path allocates are gone, which pays for some of it.
enum { kGlLegacyPoolBytes = 0x100000, kGlRamThresholdBytes = 120 * 1024 * 1024 };
static const char kShaderCachePath[] = "ux0:data/shader_cache";

int flutter_vita_gl_init(int width, int height, void (*log_line)(const char*)) {
  (void)log_line;
  // Point the shader cache somewhere writable before vitaGL starts.
  //
  // Without it every Ganesh program pays libshacccg's compile on every launch:
  // ADR-0014 measured 205 ms for a one-line shader and 405 ms for a short one,
  // against ~3 ms once cached. Ganesh generates a program per paint
  // configuration, so uncached is not a slow start, it is a stutter every time
  // a new widget first paints.
  //
  // Two things have to be true for this to work, and both were found the hard
  // way. The archive must be built with HAVE_SHADER_CACHE=1 -- the VitaSDK
  // package has it off, and vglSetShaderCachePath there is a two-byte `bx lr`
  // that silently does nothing. And the directories have to exist, because
  // vitaGL opens the .gxp for writing and sceIoOpen does not create parents.
  // The version number in the path is vitaGL's, not ours, so cover the range;
  // an mkdir of a directory that exists costs nothing.
  vglSetShaderCachePath(kShaderCachePath);
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir(kShaderCachePath, 0777);
  for (int v = 0; v < 8; v++) {
    char p[64];
    snprintf(p, sizeof p, "%s/v%d", kShaderCachePath, v);
    sceIoMkdir(p, 0777);
    snprintf(p, sizeof p, "%s/v%d/v", kShaderCachePath, v);
    sceIoMkdir(p, 0777);
    snprintf(p, sizeof p, "%s/v%d/f", kShaderCachePath, v);
    sceIoMkdir(p, 0777);
  }

  // The fourth argument is the one that matters and the one that is easy to
  // get wrong: see kGlRamThresholdBytes.
  //
  // The return value is not believed by the caller. It was GL_FALSE on a
  // context that worked, three runs of the g1 spike out of three, while the
  // console showed vitaGL's splash rotating at 60 fps. The caller probes
  // glGetString instead.
  //
  // There used to be two vglSwapBuffers(GL_FALSE) after this, to end vitaGL's
  // boot splashscreen before the engine drew anything. The library is built
  // with NO_SPLASHSCREEN=1 now; patches/vitagl/README.md says what ending it
  // used to cost.
  const GLboolean up = vglInitExtended(kGlLegacyPoolBytes, width, height, kGlRamThresholdBytes,
                                       SCE_GXM_MULTISAMPLE_NONE);
  return up ? 0 : 1;
}

void flutter_vita_gl_swap(int dialog_open) {
  // The flag is `has_commondialog`: vitaGL runs sceCommonDialogUpdate against
  // its own back buffer, which is how the libime keyboard reaches the screen.
  vglSwapBuffers(dialog_open ? GL_TRUE : GL_FALSE);
}

void* flutter_vita_gl_proc_address(const char* name) { return vglGetProcAddress(name); }

void flutter_vita_gl_shutdown(void) {
  // Drain before terminate. Terminating with flips still queued is a
  // use-after-free of the buffers they name, in the driver's own bookkeeping.
  sceGxmDisplayQueueFinish();
  sceGxmTerminate();
}

const char* flutter_vita_gl_backend(void) { return "vitaGL"; }
