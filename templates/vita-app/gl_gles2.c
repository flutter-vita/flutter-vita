// The GL platform under Ganesh, provided by fvita_gles2 (ADR-0019).
//
// The answer to flutter_vita_gl.h (gl_vitagl.c was the other until
// 2026-09-14). fvgl.h is the whole of the library's own API: everything else
// Skia reaches by name through fvgl_get_proc_address.
#include <fvgl.h>
#include <psp2/kernel/threadmgr.h>
#include <stddef.h>
#include <stdio.h>

#include "flutter_vita_gl.h"

// bailout.c in a development build; absent from a release one.
extern void vita_bail_to_loader(const char* reason) __attribute__((weak));

static void (*g_log_line)(const char*);
static int g_dialog_said;

// The embedder's line sink writes what it is given and nothing more (the dev
// server appends its own newline; fvgl does not), so the newline goes on here.
static void log_line(const char* line) {
  if (!g_log_line) return;
  char buf[520];
  snprintf(buf, sizeof buf, "%s\n", line);
  g_log_line(buf);
}

int flutter_vita_gl_init(int width, int height, void (*log)(const char*)) {
  g_log_line = log;
  FvglConfig config = {
      .width = width,
      .height = height,
      .display_buffers = 3,
      .shacccg_path = NULL,  // ur0:data/libshacccg.suprx
      // Compiled programs, keyed by source, shared by every app on this
      // console that uses the layer: the same Skia shader is the same text
      // whichever app asked for it. (vitaGL kept its cache in
      // ux0:data/shader_cache; that directory is nobody's now.)
      .shader_cache_dir = "ux0:data/fvita_gles2/cache",
      .log = log_line,
  };
  return fvgl_init(&config);
}

void flutter_vita_gl_swap(int dialog_open) {
  // A common dialog over the frame needs sceCommonDialogUpdate run against
  // the back buffer before it is queued; the layer does that inside its
  // swap while the flag is up. Until 2026-09-14 it did not, and the
  // keyboard opened invisibly over GL content: the gallery's hardware tab
  // saw "IME open" in the log and nothing on the panel.
  if (dialog_open && !g_dialog_said) {
    log_line("flutter-vita: a common dialog is open; fvita_gles2 composites it");
    g_dialog_said = 1;
  }
  fvgl_set_common_dialog(dialog_open);
  fvgl_swap();
}

void* flutter_vita_gl_proc_address(const char* name) { return fvgl_get_proc_address(name); }

void flutter_vita_gl_set_frame_hook(void (*hook)(void*, void*, int, int, int), void* ctx) {
  fvgl_set_frame_hook(hook, ctx);
}

// fvgl_shutdown did not return on the gallery's first exit (2026-09-12) and
// the console sat on the last frame. The stages it reached are in
// ux0:data/flutter-vita/gles2-shutdown.txt; this thread makes sure the
// bridge comes up regardless.
static volatile int g_shutdown_started, g_shutdown_done;

static int shutdown_watchdog(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  sceKernelDelayThread(5 * 1000 * 1000);
  if (g_shutdown_done) return 0;
  log_line("fvita_gles2: shutdown did not return in 5 s; bailing to the bridge");
  if (vita_bail_to_loader) vita_bail_to_loader("fvgl_shutdown did not return in 5 s");
  return 0;
}

void flutter_vita_gl_shutdown(void) {
  // Once. The bail-out above runs flutter_vita_gpu_shutdown a second time from
  // the watchdog's thread while the first call may still be inside.
  if (__sync_lock_test_and_set(&g_shutdown_started, 1)) return;
  const SceUID w = sceKernelCreateThread("fvgl-shutdown-watchdog", shutdown_watchdog, 0x10000100, 0x4000, 0, 0, NULL);
  if (w >= 0) sceKernelStartThread(w, 0, NULL);
  fvgl_shutdown();
  g_shutdown_done = 1;
}

const char* flutter_vita_gl_backend(void) { return "fvita_gles2"; }

// The GPU's own time, not the display queue's latency: the layer's meter
// thread reads the completion notification every millisecond.
unsigned flutter_vita_gl_gpu_us(unsigned* frames) {
  FvglStats s;
  fvgl_stats(&s);
  if (frames) *frames = s.frames_gpu_done;
  return s.us_gpu_busy;
}

// What the layer holds and how often the raster thread waited for the GPU.
// CDRAM is the number to watch: the first gallery bench on this layer
// (2026-09-12) ran it down to nothing in the route_* scenes while Skia's own
// cache stayed at 4 MiB, and the kernel's free total cannot say who had it.
void flutter_vita_gl_stats(char* out, int cap) {
  FvglStats s;
  fvgl_stats(&s);
  snprintf(out, (size_t)cap,
           "gles2 cdram %u/%uK lpddr %u/%uK tex %u/%uK tgt %u gc %u fail %u fb %u st %u/%u sh %u/%u "
           "sub %u var %u/%u/%u us q %u gc %u mb %u ln %u/%u gpu %u max %u n %u busy %u/%u fr %u/%u",
           s.cdram_blocks, s.cdram_bytes >> 10, s.lpddr_blocks, s.lpddr_bytes >> 10, s.textures_live,
           s.textures_bytes >> 10, s.targets_live, s.garbage_pending, s.cdram_failures, s.lpddr_fallbacks,
           s.stalls_previous_frame, s.stalls_this_frame, s.shader_cache_hits, s.shader_cache_misses,
           s.subdata_into_used, s.vertex_variants, s.fragment_variants, s.variants_uncached, s.us_queue_wait,
           s.us_garbage, s.us_memblock, s.us_link, s.us_cache_read, s.us_gpu_latency, s.us_gpu_latency_max,
           s.frames_flipped, s.us_gpu_busy, s.frames_gpu_done, s.frame, s.frame_done);
}
