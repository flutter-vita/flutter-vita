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
//
// In front of the compiler sits a cache of its output on disk, keyed by the
// text it was given. Ganesh makes a program per paint configuration, so a
// launch without the cache is a compile (150 ms to 1.9 s each on the console,
// M2) the first time each widget paints: a stutter, not a slow start.
#include <psp2/io/dirent.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/modulemgr.h>
#include <psp2/shacccg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

static SceUID g_module = -1;
static SceShaccCgCallbackList g_callbacks;
static char g_cache_dir[128];
unsigned fvgl_shader_cache_hits, fvgl_shader_cache_misses;

// ---- cache -----------------------------------------------------------------

// FNV-1a over the profile and the source. The compile options are constants
// below; kCacheVersion changes when they do, or when the translator's output
// for the same GLSL changes meaning, so an old entry can never be picked up.
enum { kCacheVersion = 1 };

static uint64_t cache_key(const char* cg_source, bool fragment) {
  uint64_t h = 0xcbf29ce484222325ull;
  const uint8_t head[2] = {(uint8_t)kCacheVersion, (uint8_t)(fragment ? 'f' : 'v')};
  for (int i = 0; i < 2; i++) h = (h ^ head[i]) * 0x100000001b3ull;
  for (const uint8_t* c = (const uint8_t*)cg_source; *c; c++) h = (h ^ *c) * 0x100000001b3ull;
  return h;
}

static void cache_path(char* out, size_t cap, uint64_t key, bool fragment) {
  snprintf(out, cap, "%s/%016llx.%s", g_cache_dir, (unsigned long long)key, fragment ? "fgxp" : "vgxp");
}

static SceGxmProgram* cache_read(uint64_t key, bool fragment) {
  char path[192];
  cache_path(path, sizeof path, key, fragment);
  const SceUID fd = sceIoOpen(path, SCE_O_RDONLY, 0);
  if (fd < 0) return NULL;
  const SceOff size = sceIoLseek(fd, 0, SCE_SEEK_END);
  sceIoLseek(fd, 0, SCE_SEEK_SET);
  SceGxmProgram* program = NULL;
  if (size > 0 && size < (1 << 20)) {
    program = malloc((size_t)size);
    if (program && sceIoRead(fd, program, (SceSize)size) != size) {
      free(program);
      program = NULL;
    }
  }
  sceIoClose(fd);
  // A truncated or foreign file must not reach the patcher.
  if (program && (sceGxmProgramCheck(program) < 0 || sceGxmProgramGetSize(program) != (unsigned)size)) {
    free(program);
    program = NULL;
    sceIoRemove(path);
  }
  return program;
}

static void cache_write(uint64_t key, bool fragment, const SceGxmProgram* program) {
  // Written under a temporary name and renamed, so a launch that dies mid
  // write leaves no half file under the real one.
  char path[192], tmp[200];
  cache_path(path, sizeof path, key, fragment);
  snprintf(tmp, sizeof tmp, "%s.tmp", path);
  const SceUID fd = sceIoOpen(tmp, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) return;
  const unsigned size = sceGxmProgramGetSize(program);
  const int wrote = sceIoWrite(fd, program, size);
  sceIoClose(fd);
  if (wrote == (int)size) sceIoRename(tmp, path);
  else sceIoRemove(tmp);
}

void fvgl_shader_cache_init(const char* dir) {
  g_cache_dir[0] = 0;
  if (!dir || !*dir) return;
  // Parents first: sceIoMkdir does not create them.
  char path[128];
  snprintf(path, sizeof path, "%s", dir);
  for (char* c = path + 1; *c; c++) {
    if (*c != '/') continue;
    *c = 0;
    if (strchr(path, ':')) sceIoMkdir(path, 0777);
    *c = '/';
  }
  sceIoMkdir(path, 0777);
  SceIoStat st;
  if (sceIoGetstat(path, &st) < 0) {
    fvgl_log("shader cache %s: cannot create, compiling every launch", path);
    return;
  }
  snprintf(g_cache_dir, sizeof g_cache_dir, "%s", path);
}
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
  const uint64_t key = cache_key(cg_source, fragment);
  if (g_cache_dir[0]) {
    SceGxmProgram* cached = cache_read(key, fragment);
    if (cached) {
      fvgl_shader_cache_hits++;
      return cached;
    }
    fvgl_shader_cache_misses++;
  }
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
  if (program && g_cache_dir[0]) cache_write(key, fragment, program);
  return program;
}

void fvgl_shacc_shutdown(void) {
  if (g_module < 0) return;
  sceShaccCgReleaseCompiler();
  sceKernelStopUnloadModule(g_module, 0, NULL, 0, NULL, NULL);
  g_module = -1;
}
