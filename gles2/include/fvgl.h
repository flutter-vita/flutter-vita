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
  // A directory for compiled programs, keyed by their source, so a shader
  // compiles once per console rather than once per launch. Created if
  // missing, parents included. 0 means no cache.
  const char* shader_cache_dir;
  // Where diagnostics go. 0 means sceClibPrintf.
  void (*log)(const char* line);
} FvglConfig;

// Brings up sceGxm, the display queue, the shader compiler and a context
// whose state is the GLES 2.0 initial state. 0 on success, a negative
// SCE error or -1 (with the reason in the log) otherwise.
int fvgl_init(const FvglConfig* config);

// Ends the current scene, queues the back buffer for scan-out, rotates.
void fvgl_swap(void);

// While `open` is non-zero every swap runs sceCommonDialogUpdate against the
// back buffer before queueing it: that is how the shell draws a common
// dialog (the libime keyboard, the message dialogs) over GL content. A
// per-frame cost, so the app says when. sceCommonDialogSetConfigParam is
// the app's, after init.
void fvgl_set_common_dialog(int open);

// The GL entry point of that name, or 0 if it is not one this library has.
void* fvgl_get_proc_address(const char* name);

// Drains the display queue and releases sceGxm. Safe to call without init.
void fvgl_shutdown(void);

// Counters, for a HUD or a log line. All cumulative since init except the
// live ones, which are what the layer holds at the moment of the call.
typedef struct FvglStats {
  unsigned cdram_blocks, cdram_bytes;  // live memblocks the layer owns
  unsigned lpddr_blocks, lpddr_bytes;
  unsigned cdram_failures;   // CDRAM allocations the kernel refused
  unsigned lpddr_fallbacks;  // textures that went to LPDDR because of one
  unsigned garbage_pending;  // blocks freed by GL, still owned until the GPU is past them
  unsigned textures_live, textures_bytes;  // textures with storage
  unsigned targets_live;                   // textures that have been drawn into
  unsigned stalls_previous_frame, stalls_this_frame;  // raster-thread waits for the GPU
  unsigned shader_cache_hits, shader_cache_misses;    // programs read from disk, programs compiled
  unsigned subdata_into_used;  // glBufferSubData into a buffer a draw of the same frame read
  // Patched programs alive: one vertex program per (GL program, vertex
  // layout), one fragment program per (GL program, blend state); and how many
  // draws made one that no table had room for, which is a leak until eviction exists.
  unsigned vertex_variants, fragment_variants, variants_uncached;
  // Where the raster thread's time goes inside the layer, microseconds,
  // cumulative: the wait to queue a frame for scan-out, releasing GPU memory
  // the GPU is past, mapping and unmapping memblocks.
  unsigned us_queue_wait, us_garbage, us_memblock;
  unsigned us_link, us_cache_read;  // glLinkProgram, and its reads of the on-card program cache
  // From queueing a frame to the display queue's thread taking it: the sum,
  // the largest, and how many frames. A full pipeline reads a frame period
  // here whatever the GPU did; see us_gpu_busy for the GPU's own time.
  unsigned us_gpu_latency, us_gpu_latency_max, frames_flipped;
  // Time the GPU spent on frames, from a frame's first scene (or the previous
  // frame's completion) to its completion notification, read every
  // millisecond; and how many frames completed. Busy over wall time is GPU
  // load.
  unsigned us_gpu_busy, frames_gpu_done;
  unsigned frame, frame_done;  // the frame being built, the last one the GPU finished
} FvglStats;
void fvgl_stats(FvglStats* out);

// For tests: translate one GLSL shader and run it through the console's Cg
// compiler, standalone (its varyings get indices in declaration order).
// 0 when the compiler accepted it, -1 with the reason in `log`.
int fvgl_debug_compile(const char* glsl, int fragment, char* log, unsigned log_size);

#ifdef __cplusplus
}
#endif
#endif
