// Sony's Cg compiler, driven from the console.
//
// libshacccg.suprx is what compiles shaders at run time on this platform.
// It takes Cg, and translate.c is what turns Skia's GLSL into that Cg. This
// file only knows how to hand text to the compiler and get a SceGxmProgram
// back.
//
// The compiler reads sources through callbacks. The trivial callback set from
// sceShaccCgInitializeCallbackList covers everything but opening the file,
// and the "file" here is the string we were given, under a made-up name.
#include <psp2/kernel/modulemgr.h>
#include <psp2/shacccg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

static SceUID g_module = -1;
static SceShaccCgCallbackList g_callbacks;
static const char* g_source;  // the text being compiled, for open_file

static void* shacc_malloc(unsigned int n) { return malloc(n); }
static void shacc_free(void* p) { free(p); }

static SceShaccCgSourceFile* open_file(const char* name,
                                       const SceShaccCgSourceLocation* from,
                                       const SceShaccCgCompileOptions* opts,
                                       const char** error) {
  (void)from;
  (void)opts;
  if (strcmp(name, "main.cg") != 0 || g_source == NULL) {
    if (error) *error = "fvgl: no such source";
    return NULL;
  }
  SceShaccCgSourceFile* f = calloc(1, sizeof *f);
  f->fileName = "main.cg";
  f->text = g_source;
  f->size = (SceUInt32)strlen(g_source);
  return f;
}

static void release_file(const SceShaccCgSourceFile* f,
                         const SceShaccCgCompileOptions* opts) {
  (void)opts;
  free((void*)f);
}

int fvgl_shacc_init(const char* module_path) {
  if (g_module >= 0) return 0;
  int status = 0;
  g_module = sceKernelLoadStartModule(module_path, 0, NULL, 0, NULL, &status);
  if (g_module < 0) {
    fvgl_log("%s: 0x%08X. Sony's shader compiler is not on this console.",
             module_path, (unsigned)g_module);
    return (int)g_module;
  }
  sceShaccCgSetDefaultAllocator(shacc_malloc, shacc_free);
  sceShaccCgInitializeCallbackList(&g_callbacks, SCE_SHACCCG_TRIVIAL);
  g_callbacks.openFile = open_file;
  g_callbacks.releaseFile = release_file;
  fvgl_log("SceShaccCg %s", sceShaccCgGetVersionString());
  return 0;
}

SceGxmProgram* fvgl_shacc_compile(const char* cg_source, bool fragment,
                                  char* log, size_t log_size) {
  if (log_size) log[0] = 0;
  if (g_module < 0) {
    snprintf(log, log_size, "shader compiler not loaded");
    return NULL;
  }
  SceShaccCgCompileOptions opts;
  memset(&opts, 0, sizeof opts);
  sceShaccCgInitializeCompileOptions(&opts);
  opts.mainSourceFile = "main.cg";
  opts.targetProfile = fragment ? SCE_SHACCCG_PROFILE_FP : SCE_SHACCCG_PROFILE_VP;
  opts.entryFunctionName = "main";
  opts.optimizationLevel = 3;
  opts.useFastmath = 1;
  opts.useFastprecision = 0;
  opts.useFastint = 1;
  opts.warningLevel = 1;

  g_source = cg_source;
  const SceShaccCgCompileOutput* out =
      sceShaccCgCompileProgram(&opts, &g_callbacks, 0);
  g_source = NULL;
  if (out == NULL) {
    snprintf(log, log_size, "sceShaccCgCompileProgram returned nothing");
    return NULL;
  }
  size_t used = 0;
  for (int i = 0; i < out->diagnosticCount && used + 1 < log_size; i++) {
    const SceShaccCgDiagnosticMessage* d = &out->diagnostics[i];
    const unsigned line = d->location ? d->location->lineNumber : 0;
    const int n = snprintf(log + used, log_size - used, "%s:%u: %s\n",
                           d->level == SCE_SHACCCG_DIAGNOSTIC_LEVEL_ERROR ? "error"
                           : d->level == SCE_SHACCCG_DIAGNOSTIC_LEVEL_WARNING ? "warning"
                                                                               : "info",
                           line, d->message ? d->message : "");
    if (n > 0) used += (size_t)n;
  }
  SceGxmProgram* program = NULL;
  if (out->programData && out->programSize) {
    program = malloc(out->programSize);
    if (program) memcpy(program, out->programData, out->programSize);
  }
  sceShaccCgDestroyCompileOutput(out);
  return program;
}

void fvgl_shacc_shutdown(void) {
  if (g_module < 0) return;
  sceShaccCgReleaseCompiler();
  sceKernelStopUnloadModule(g_module, 0, NULL, 0, NULL, NULL);
  g_module = -1;
}
