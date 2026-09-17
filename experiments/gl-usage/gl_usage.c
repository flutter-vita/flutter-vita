// Count what an app really asks of the GL layer.
//
// Built into the app with --extra-source and
// --link-option -Wl,--wrap=fvgl_get_proc_address, so every name Skia resolves
// comes through here and every call it then makes goes through a thunk:
//
//   ./tools/build-vita-app.sh samples/gallery \
//       --extra-source experiments/gl-usage/gl_usage.c \
//       --extra-source experiments/gl-usage/gl_thunks.S \
//       --link-option -Wl,--wrap=fvgl_get_proc_address
//
// It sized ADR-0019's decision against vitaGL (372 names answered, and nothing
// static could narrow that, because Skia binds by name). It now measures the
// layer of our own: fvita_gles2 answers 142 names, 35 of them recording stubs,
// and `engine/gles2/surface.txt` carries this tool's counts, which is what
// tools/gles2-progress.py reads for the ledger. A new app is measured the
// same way: build it with the three options above, drive it, pull
// ux0:data/flutter-vita/gl-usage.txt, and merge the peaks into surface.txt.
//
// Two call paths are outside this count and both are small and known. The
// embedder's link probe calls thirteen GL functions by symbol (glCreateShader
// through glDeleteProgram, glGetString) once at start-up. And the layer's own
// six flutter_vita_gl.h functions are not GL.
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/threadmgr.h>
#include <stdio.h>
#include <string.h>

#define SLOTS 384
#define THUNK 64
#define REPORT "ux0:data/flutter-vita/gl-usage.txt"

// Read and written by gl_thunks.S. Not static, and the names are load bearing.
unsigned int gl_counters[SLOTS];
void* gl_targets[SLOTS];
extern unsigned char gl_thunks[];

// Skia passes string literals out of its own rodata, which outlive the process,
// but a copy costs 12 KB and removes the question.
static char g_names[SLOTS][32];
static int g_used;

void* __real_fvgl_get_proc_address(const char* name);

// Defined by gl_shaders.c when it is in the build, and weak so that it is not.
__attribute__((weak)) void __wrap_glShaderSource(unsigned int, int,
                                                 const char* const*,
                                                 const int*);

void* __wrap_fvgl_get_proc_address(const char* name) {
  void* real = __real_fvgl_get_proc_address(name);
  if (!real) return real;

  // Skia compiles through the pointer it was handed, so a wrap on the symbol
  // alone misses every shader. Hand back the dumper rather than a thunk.
  if (__wrap_glShaderSource && name && strcmp(name, "glShaderSource") == 0) {
    return (void*)__wrap_glShaderSource;
  }

  // A layer may answer several names with one function (vitaGL did), so match
  // on the target rather than the name. Two thunks for one function would
  // count it twice.
  for (int i = 0; i < g_used; i++) {
    if (gl_targets[i] == real) return gl_thunks + (unsigned)i * THUNK;
  }
  if (g_used >= SLOTS) return real;  // uncounted rather than wrong

  const int i = g_used++;
  gl_targets[i] = real;
  snprintf(g_names[i], sizeof g_names[i], "%s", name ? name : "?");
  return gl_thunks + (unsigned)i * THUNK;
}

// Written whole under a temporary name and renamed into place. The first
// version truncated REPORT and rewrote it a line at a time, and the run that
// stalled on 2026-09-11 was killed by the receiver's watchdog in the middle of
// one such rewrite, leaving 79 of 114 lines and no way to tell.
static void write_report(void) {
  const SceUID fd =
      sceIoOpen(REPORT ".tmp", SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) return;
  char line[96];
  int called = 0;
  for (int i = 0; i < g_used; i++) {
    if (gl_counters[i]) called++;
  }
  int n = snprintf(line, sizeof line, "bound %d  called %d  never %d\n", g_used,
                   called, g_used - called);
  sceIoWrite(fd, line, (SceSize)n);
  for (int i = 0; i < g_used; i++) {
    n = snprintf(line, sizeof line, "%10u  %s\n", gl_counters[i], g_names[i]);
    sceIoWrite(fd, line, (SceSize)n);
  }
  sceIoClose(fd);
  sceIoRemove(REPORT);
  sceIoRename(REPORT ".tmp", REPORT);
}

// The report is written on a timer rather than at exit, because the runs that
// matter are the ones that end in a crash or in a handoff to the receiver, and
// neither of those unwinds anything.
static int reporter(SceSize argc, void* argv) {
  (void)argc;
  (void)argv;
  // Written once before anything is bound. An empty table on the card and no
  // table at all are different failures, and the first run could not tell them
  // apart.
  write_report();
  for (;;) {
    sceKernelDelayThread(3 * 1000 * 1000);
    write_report();
  }
  return 0;
}

__attribute__((constructor)) static void gl_usage_start(void) {
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  const SceUID th =
      sceKernelCreateThread("gl_usage", reporter, 0x10000100, 0x8000, 0, 0, NULL);
  if (th >= 0) sceKernelStartThread(th, 0, NULL);
}
