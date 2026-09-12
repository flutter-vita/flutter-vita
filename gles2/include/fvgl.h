// fvita_gles2: OpenGL ES 2.0 for the PlayStation Vita, over sceGxm.
//
// This is the whole of the API that is not GL. Everything else is the
// standard <GLES2/gl2.h> surface, resolved by name through
// fvgl_get_proc_address or linked by symbol.
//
// ADR-0019 says what this is for and how far along it is.
#ifndef FVGL_H
#define FVGL_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FvglConfig {
  int width;   // display size in pixels; 0 means 960
  int height;  // 0 means 544
  // How many display buffers to rotate through. 2 tears less memory, 3 never
  // waits on the scan-out. 0 means 3.
  int display_buffers;
  // Sony's Cg compiler, loaded at init. 0 means "ur0:data/libshacccg.suprx".
  const char* shacccg_path;
  // Where diagnostics go. 0 means sceClibPrintf.
  void (*log)(const char* line);
} FvglConfig;

// Brings up sceGxm, the display queue, the shader compiler and a context
// whose state is the GLES 2.0 initial state. 0 on success, a negative
// SCE error or -1 (with the reason in the log) otherwise.
int fvgl_init(const FvglConfig* config);

// Ends the current scene, queues the back buffer for scan-out, rotates.
void fvgl_swap(void);

// The GL entry point of that name, or 0 if it is not one this library has.
void* fvgl_get_proc_address(const char* name);

// Drains the display queue and releases sceGxm. Safe to call without init.
void fvgl_shutdown(void);

// For tests: translate one GLSL shader and run it through the console's Cg
// compiler, standalone (its varyings get indices in declaration order).
// 0 when the compiler accepted it, -1 with the reason in `log`.
int fvgl_debug_compile(const char* glsl, int fragment, char* log, unsigned log_size);

#ifdef __cplusplus
}
#endif
#endif
