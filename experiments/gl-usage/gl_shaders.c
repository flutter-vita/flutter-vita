// Write down every shader Skia compiles.
//
// ADR-0018 turns on whether the GLSL Skia emits uses a narrow corner of the
// language or all of it, because vitaGL's translator does not parse GLSL. It
// rewrites it with strstr and strcasestr, and its failure mode is renaming
// something it should not have touched. Two of our four vitaGL patches are
// that bug. Sizing a translator of our own means seeing the input.
//
// Built with --extra-source and -Wl,--wrap=glShaderSource. Skia reaches
// glShaderSource two ways -- by symbol from the engine, and by the pointer
// fvgl_get_proc_address hands it -- so gl_usage.c returns this function for
// that name instead of a counting thunk. Since 2026-09-12 the shaders of a
// run are also what `engine/gles2/corpus/` is grown from.
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <stdio.h>
#include <string.h>

#define DUMP "ux0:data/flutter-vita/skia-shaders.glsl"
#define CAP (1024 * 1024)

typedef unsigned int GLuint;
typedef int GLsizei;
typedef char GLchar;
typedef int GLint;

void __real_glShaderSource(GLuint shader, GLsizei count,
                           const GLchar* const* string, const GLint* length);

static int g_written;
static int g_n;

void __wrap_glShaderSource(GLuint shader, GLsizei count,
                           const GLchar* const* string, const GLint* length) {
  if (g_written < CAP && string) {
    // Appended rather than one file per shader: one `get` pulls the lot, and
    // the count is in the separators.
    const SceUID fd = sceIoOpen(DUMP, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_APPEND, 0777);
    if (fd >= 0) {
      char sep[64];
      const int n = snprintf(sep, sizeof sep, "\n/* ---- shader %d ---- */\n", g_n++);
      sceIoWrite(fd, sep, (SceSize)n);
      g_written += n;
      for (int i = 0; i < count; i++) {
        if (!string[i]) continue;
        const int len =
            (length && length[i] >= 0) ? length[i] : (int)strlen(string[i]);
        sceIoWrite(fd, string[i], (SceSize)len);
        g_written += len;
      }
      sceIoClose(fd);
    }
  }
  __real_glShaderSource(shader, count, string, length);
}
