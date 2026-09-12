// The GL platform under Ganesh, provided by fvita_gles2 (ADR-0019).
//
// One of two answers to flutter_vita_gl.h; gl_vitagl.c is the other, and
// FLUTTER_VITA_GL in CMakeLists.txt picks. fvgl.h is the whole of the
// library's own API: everything else Skia reaches by name through
// fvgl_get_proc_address.
#include <fvgl.h>
#include <stddef.h>
#include <stdio.h>

#include "flutter_vita_gl.h"

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
      .log = log_line,
  };
  return fvgl_init(&config);
}

void flutter_vita_gl_swap(int dialog_open) {
  // A common dialog over the frame needs sceCommonDialogUpdate run against
  // the back buffer before it is queued. Not done yet under this backend:
  // the keyboard is invisible over GL content until it is, and the tracker
  // (docs/gles2-progress.md) carries it.
  if (dialog_open && !g_dialog_said) {
    log_line("flutter-vita: a common dialog is open; fvita_gles2 does not composite it yet");
    g_dialog_said = 1;
  }
  fvgl_swap();
}

void* flutter_vita_gl_proc_address(const char* name) { return fvgl_get_proc_address(name); }

void flutter_vita_gl_shutdown(void) { fvgl_shutdown(); }

const char* flutter_vita_gl_backend(void) { return "fvita_gles2"; }
