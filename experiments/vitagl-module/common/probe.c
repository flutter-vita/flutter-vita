// The shader compiler probe, compiled twice from this one file.
//
// Once into the module, where it is exported as spike_shader_probe, and once
// into the application, where it is called directly as local_shader_probe.
// That is the control the experiment needs. libshacccg took a prefetch abort
// at sceShaccCgSetDefaultAllocator when the caller was the module, and the
// only way to know whether the module caused it is to make the identical call
// from an eboot on the same console in the same run.
//
// PROBE_NAME is what the caller sees. Everything else here is static.
#include <psp2/kernel/modulemgr.h>
#include <psp2/kernel/processmgr.h>
#include <shacccg_ext.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vitashark.h>

// The path vitashark uses when shark_init is given NULL.
static const char* const kShaccCg = "ur0:/data/libshacccg.suprx";

// The caller's logger. A buffer returned at the end told us nothing: the
// process died inside libshacccg and the buffer died with it. The caller
// writes and syncs each line as it arrives, so the last line in the file is
// the last call that returned.
static void (*g_log)(const char*);

static void emit(const char* fmt, ...) {
  if (!g_log) return;
  char line[256];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  g_log(line);
}

// libshacccg says why it refused. Without this the failure is a null pointer
// and no reason, which is how the four vitaGL shader patches started.
static void on_log(const char* msg, shark_log_level level, int line) {
  static const char* const kName[] = {"info", "warn", "error"};
  emit("    shacccg %s line %d: %s\n",
       (level <= SHARK_LOG_ERROR) ? kName[level] : "?", line,
       msg ? msg : "(no text)");
}

// A vertex shader with nothing in it. The question is whether libshacccg runs
// here at all, so the shader must not be able to fail on its own merits.
static const char* const kSource =
    "void main(float3 aPosition, float4 out vPosition : POSITION) {\n"
    "  vPosition = float4(aPosition, 1.f);\n"
    "}\n";

// shark_init is four calls in a row and the fault was inside one of them, so
// they are made here one at a time with a line between each. The order and the
// arguments are vitashark's own, read out of its disassembly.
//
// sceShaccCgGetVersionString is not part of that sequence. It is here as the
// control: a plain call into libshacccg that touches nothing else. If it
// answers, a module can call the library, and whatever breaks afterwards is
// about the extensions rather than about being a module.
static void* shacccg_malloc(unsigned int size) { return malloc(size); }
static void shacccg_free(void* p) { free(p); }

int PROBE_NAME(void (*log)(const char*)) {
  g_log = log;
  // Two newlib heaps live in this process once the module is loaded, and a
  // null from either one would explain a null pointer inside libshacccg. Cheap
  // to rule out, expensive to guess at.
  void* t = malloc(64 * 1024);
  emit("  malloc 64K      %p %s\n", t, t ? "OK" : "FAILED");
  free(t);
  if (!t) return -1;

  int status = 0;
  const SceUID sh =
      sceKernelLoadStartModule(kShaccCg, 0, NULL, 0, NULL, &status);
  emit("  load shacccg    0x%08X status 0x%08X\n", (unsigned)sh,
       (unsigned)status);
  if (sh < 0) return -1;

  const char* ver = sceShaccCgGetVersionString();
  emit("  version         %s\n", ver ? ver : "(null)");

  const int ext = sceShaccCgExtEnableExtensions();
  emit("  extensions      %d %s\n", ext, ext == 0 ? "OK" : "FAILED");

  sceShaccCgSetDefaultAllocator(shacccg_malloc, shacccg_free);
  emit("  allocator       set\n");

  SceShaccCgCallbackList cbl;
  memset(&cbl, 0, sizeof cbl);
  sceShaccCgInitializeCallbackList(&cbl, SCE_SHACCCG_TRIVIAL);
  emit("  callbacks       set, openFile %p\n", (void*)cbl.openFile);

  // From here on it is vitashark's job again, so give libshacccg back and let
  // shark_init load it the way vitaGL does. Its own load returns
  // MODULEMGR_OLD_LIB if the module is still resident.
  sceShaccCgReleaseCompiler();
  int stop = 0;
  const int u = sceKernelStopUnloadModule(sh, 0, NULL, 0, NULL, &stop);
  emit("  unload shacccg  0x%08X (stop 0x%08X)\n", (unsigned)u,
       (unsigned)stop);

  emit("  shark_init      calling\n");
  const int init = shark_init(NULL);
  emit("  shark_init      %d %s\n", init, init >= 0 ? "OK" : "FAILED");
  if (init < 0) return -1;

  shark_install_log_cb(on_log);
  shark_set_warnings_level(SHARK_WARN_MAX);

  emit("  compile         calling\n");
  uint32_t size = 0;
  SceGxmProgram* prog =
      shark_compile_shader(kSource, &size, SHARK_VERTEX_SHADER);
  emit("  compile         %s\n", prog ? "OK" : "REFUSED");
  emit("  program         %u bytes\n", (unsigned)size);

  int ok = 0;
  if (prog && size >= 4) {
    // A SceGxmProgram starts with the magic 'GXP\0'. A non-null pointer alone
    // proves the call returned; the magic proves it returned a program.
    const unsigned char* b = (const unsigned char*)prog;
    ok = (b[0] == 'G' && b[1] == 'X' && b[2] == 'P');
    emit("  magic           %02X %02X %02X %02X %s\n", b[0], b[1], b[2], b[3],
         ok ? "GXP" : "NOT A PROGRAM");
  }

  shark_clear_output();
  shark_end();
  emit("  shark_end       done\n");
  return ok ? 0 : -2;
}

