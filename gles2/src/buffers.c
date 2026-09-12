// Buffer objects: GL_ARRAY_BUFFER and GL_ELEMENT_ARRAY_BUFFER in memory the
// GPU reads directly.
//
// glBufferData on a buffer a queued draw still reads gets a fresh block and
// the old one goes to the garbage stamped with the current frame. That is the
// orphaning Skia does once per draw batch, and it is the reason a buffer is
// never freed here directly. glBufferSubData writes in place: Skia only ever
// appends behind what earlier draws in the frame referenced, and a write into
// a range the GPU has not read yet is safe. The counter says how often a
// write lands in a buffer a draw of this frame already used, which is the case
// that would need a copy.
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

unsigned fvgl_subdata_into_used_buffer;

static FvglBuffer* buffer_bound(GLenum target) {
  unsigned name;
  if (target == GL_ARRAY_BUFFER) name = fvgl.array_buffer;
  else if (target == GL_ELEMENT_ARRAY_BUFFER) name = fvgl.element_buffer;
  else {
    fvgl_set_error(GL_INVALID_ENUM);
    return NULL;
  }
  FvglBuffer* b = fvgl_table_get(&fvgl.buffers, name);
  if (!b) fvgl_set_error(GL_INVALID_OPERATION);
  return b;
}

GL_APICALL void GL_APIENTRY glGenBuffers(GLsizei n, GLuint* buffers) {
  if (n < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  for (GLsizei i = 0; i < n; i++) {
    FvglBuffer* b = calloc(1, sizeof *b);
    b->uid = -1;
    buffers[i] = fvgl_table_add(&fvgl.buffers, b);
  }
}

GL_APICALL void GL_APIENTRY glBindBuffer(GLenum target, GLuint buffer) {
  if (buffer != 0 && !fvgl_table_get(&fvgl.buffers, buffer)) {
    // A name never handed out by glGenBuffers still works in GL: make it.
    while (fvgl.buffers.count < buffer) {
      FvglBuffer* b = calloc(1, sizeof *b);
      b->uid = -1;
      fvgl_table_add(&fvgl.buffers, b);
    }
  }
  if (target == GL_ARRAY_BUFFER) fvgl.array_buffer = buffer;
  else if (target == GL_ELEMENT_ARRAY_BUFFER) fvgl.element_buffer = buffer;
  else fvgl_set_error(GL_INVALID_ENUM);
}

GL_APICALL void GL_APIENTRY glDeleteBuffers(GLsizei n, const GLuint* buffers) {
  if (n < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  for (GLsizei i = 0; i < n; i++) {
    FvglBuffer* b = fvgl_table_get(&fvgl.buffers, buffers[i]);
    if (!b) continue;
    fvgl_defer_free(b->uid);
    free(b);
    fvgl_table_clear(&fvgl.buffers, buffers[i]);
    if (fvgl.array_buffer == buffers[i]) fvgl.array_buffer = 0;
    if (fvgl.element_buffer == buffers[i]) fvgl.element_buffer = 0;
    for (int a = 0; a < FVGL_MAX_ATTRIBUTES; a++) {
      if (fvgl.attribs[a].buffer == buffers[i]) fvgl.attribs[a].buffer = 0;
    }
  }
}

GL_APICALL GLboolean GL_APIENTRY glIsBuffer(GLuint buffer) {
  return fvgl_table_get(&fvgl.buffers, buffer) != NULL;
}

GL_APICALL void GL_APIENTRY glBufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage) {
  FvglBuffer* b = buffer_bound(target);
  if (!b) return;
  if (size < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  b->usage = usage;
  const bool in_flight = b->uid >= 0 && b->last_frame_used > fvgl_gpu_completed_frame();
  if (b->uid >= 0 && (in_flight || b->capacity < (size_t)size)) {
    fvgl_defer_free(b->uid);
    b->uid = -1;
    b->data = NULL;
    b->capacity = 0;
  }
  if (b->uid < 0 && size > 0) {
    b->data = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, (size_t)size, &b->uid);
    if (!b->data) {
      b->uid = -1;
      fvgl_set_error(GL_OUT_OF_MEMORY);
      return;
    }
    // The block is a multiple of 4 KiB; the rest of it is usable capacity.
    b->capacity = ((size_t)size + 4095) & ~(size_t)4095;
  }
  b->size = (size_t)size;
  b->last_frame_used = 0;
  if (data && size > 0) memcpy(b->data, data, (size_t)size);
}

GL_APICALL void GL_APIENTRY glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) {
  FvglBuffer* b = buffer_bound(target);
  if (!b) return;
  if (offset < 0 || size < 0 || (size_t)offset + (size_t)size > b->size) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (!data || size == 0) return;
  if (b->last_frame_used == fvgl.frame) fvgl_subdata_into_used_buffer++;
  memcpy(b->data + offset, data, (size_t)size);
}

GL_APICALL void GL_APIENTRY glGetBufferParameteriv(GLenum target, GLenum pname, GLint* params) {
  FvglBuffer* b = buffer_bound(target);
  if (!b || !params) return;
  switch (pname) {
    case GL_BUFFER_SIZE: *params = (GLint)b->size; break;
    case GL_BUFFER_USAGE: *params = (GLint)b->usage; break;
    default: fvgl_set_error(GL_INVALID_ENUM); break;
  }
}

void fvgl_buffers_shutdown(void) {
  for (unsigned i = 1; i <= fvgl.buffers.count; i++) {
    FvglBuffer* b = fvgl_table_get(&fvgl.buffers, i);
    if (!b) continue;
    fvgl_mem_free(b->uid);
    free(b);
  }
  free(fvgl.buffers.items);
  memset(&fvgl.buffers, 0, sizeof fvgl.buffers);
  fvgl.array_buffer = fvgl.element_buffer = 0;
}
