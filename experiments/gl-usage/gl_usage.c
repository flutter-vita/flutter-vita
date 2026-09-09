// Count what an app really asks of vitaGL.
//
// Built into the app with --extra-source and
// --extra-link-option -Wl,--wrap=vglGetProcAddress, so every name Skia resolves
// comes through here and every call it then makes goes through a thunk.
//
// This exists to size one decision: whether a GLES2 layer of our own over GXM
// is a subset of vitaGL or a rewrite of it. vitaGL answers 372 GL names and
// nothing static can narrow that, because Skia binds by name and vitaGL's
// lookup table references them all.
//
// Three call paths are outside this count and all three are small and known.
// Fifteen GL functions are linked into the engine by symbol rather than
// resolved: glAttachShader, glCompileShader, glCreateProgram, glCreateShader,
// glDeleteProgram, glDeleteShader, glGetIntegerv, glGetProgramInfoLog,
// glGetProgramiv, glGetShaderInfoLog, glGetShaderiv, glGetString,
// glLinkProgram, glShaderSource and glTexParameterf. Seven more are the
// engine's own VitaGl* shims, which Skia gets before vglGetProcAddress is
// consulted. And five vgl* calls are the vitaGL API proper: vglInitExtended,
// vglSetShaderCachePath, vglSetupRuntimeShaderCompiler, vglSwapBuffers and
// vglGetProcAddress itself.
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

void* __real_vglGetProcAddress(const char* name);

void* __wrap_vglGetProcAddress(const char* name) {
  void* real = __real_vglGetProcAddress(name);
  if (!real) return real;

  // vitaGL answers several names with one function, so match on the target
  // rather than the name. Two thunks for one function would count it twice.
  for (int i = 0; i < g_used; i++) {
    if (gl_targets[i] == real) return gl_thunks + (unsigned)i * THUNK;
  }
  if (g_used >= SLOTS) return real;  // uncounted rather than wrong

  const int i = g_used++;
  gl_targets[i] = real;
  snprintf(g_names[i], sizeof g_names[i], "%s", name ? name : "?");
  return gl_thunks + (unsigned)i * THUNK;
}

static void write_report(void) {
  const SceUID fd =
      sceIoOpen(REPORT, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
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
}

// The report is written on a timer rather than at exit, because the runs that
// matter are the ones that end in a crash or in a handoff to the receiver, and
// neither of those unwinds anything.
static int reporter(SceSize argc, void* argv) {
  (void)argc;
  (void)argv;
  for (;;) {
    sceKernelDelayThread(3 * 1000 * 1000);
    write_report();
  }
  return 0;
}

__attribute__((constructor)) static void gl_usage_start(void) {
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  const SceUID th =
      sceKernelCreateThread("gl_usage", reporter, 0x10000100, 0x2000, 0, 0, NULL);
  if (th >= 0) sceKernelStartThread(th, 0, NULL);
}
