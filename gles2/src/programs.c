// Shader and program objects: GLSL in at glShaderSource, a pair of patched
// sceGxm programs and a uniform table out at glLinkProgram.
//
// Compilation is split the way the console forces it. glCompileShader parses
// the GLSL and reports what the translator refuses; the Cg compiler runs at
// glLinkProgram, because a varying's TEXCOORD index has to be the same in both
// shaders and only the link sees both. So a Cg compiler error is a link
// error, which GL allows and Skia checks for.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

static FvglShader* shader_get(GLuint name, const char* who) {
  FvglShader* s = fvgl_table_get(&fvgl.shaders, name);
  if (!s) {
    fvgl_set_error(fvgl_table_get(&fvgl.programs, name) ? GL_INVALID_OPERATION : GL_INVALID_VALUE);
    if (who) fvgl_log("%s: no shader %u", who, name);
  }
  return s;
}

static FvglProgram* program_get(GLuint name, const char* who) {
  FvglProgram* p = fvgl_table_get(&fvgl.programs, name);
  if (!p) {
    fvgl_set_error(fvgl_table_get(&fvgl.shaders, name) ? GL_INVALID_OPERATION : GL_INVALID_VALUE);
    if (who) fvgl_log("%s: no program %u", who, name);
  }
  return p;
}

static void shader_destroy(FvglShader* s, GLuint name) {
  free(s->source);
  free(s);
  fvgl_table_clear(&fvgl.shaders, name);
}

// ---- shaders ---------------------------------------------------------------

GL_APICALL GLuint GL_APIENTRY glCreateShader(GLenum type) {
  if (type != GL_VERTEX_SHADER && type != GL_FRAGMENT_SHADER) {
    fvgl_set_error(GL_INVALID_ENUM);
    return 0;
  }
  FvglShader* s = calloc(1, sizeof *s);
  s->type = type;
  return fvgl_table_add(&fvgl.shaders, s);
}

GL_APICALL void GL_APIENTRY glShaderSource(GLuint shader, GLsizei count, const GLchar* const* string,
                                           const GLint* length) {
  FvglShader* s = shader_get(shader, "glShaderSource");
  if (!s) return;
  if (count < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  size_t total = 0;
  for (GLsizei i = 0; i < count; i++) {
    if (!string[i]) continue;
    total += (length && length[i] >= 0) ? (size_t)length[i] : strlen(string[i]);
  }
  char* src = malloc(total + 1);
  size_t at = 0;
  for (GLsizei i = 0; i < count; i++) {
    if (!string[i]) continue;
    const size_t n = (length && length[i] >= 0) ? (size_t)length[i] : strlen(string[i]);
    memcpy(src + at, string[i], n);
    at += n;
  }
  src[at] = 0;
  free(s->source);
  s->source = src;
  s->compiled = false;
}

GL_APICALL void GL_APIENTRY glCompileShader(GLuint shader) {
  FvglShader* s = shader_get(shader, "glCompileShader");
  if (!s) return;
  if (!s->source) {
    snprintf(s->log, sizeof s->log, "no source");
    s->compiled = false;
    return;
  }
  const int r = fvgl_translate(s->source, s->type == GL_FRAGMENT_SHADER, NULL, NULL, &s->info, s->log, sizeof s->log);
  s->compiled = r == 0;
  if (!s->compiled) fvgl_log("shader %u refused: %s", shader, s->log);
}

GL_APICALL void GL_APIENTRY glGetShaderiv(GLuint shader, GLenum pname, GLint* params) {
  FvglShader* s = shader_get(shader, "glGetShaderiv");
  if (!s || !params) return;
  switch (pname) {
    case GL_SHADER_TYPE: *params = (GLint)s->type; break;
    case GL_DELETE_STATUS: *params = s->delete_pending; break;
    case GL_COMPILE_STATUS: *params = s->compiled; break;
    case GL_INFO_LOG_LENGTH: *params = s->log[0] ? (GLint)strlen(s->log) + 1 : 0; break;
    case GL_SHADER_SOURCE_LENGTH: *params = s->source ? (GLint)strlen(s->source) + 1 : 0; break;
    default: fvgl_set_error(GL_INVALID_ENUM); break;
  }
}

static void copy_log(const char* log, GLsizei bufsize, GLsizei* length, GLchar* out) {
  if (bufsize < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  const size_t n = strlen(log);
  const size_t w = bufsize > 0 ? (n < (size_t)bufsize - 1 ? n : (size_t)bufsize - 1) : 0;
  if (out && bufsize > 0) {
    memcpy(out, log, w);
    out[w] = 0;
  }
  if (length) *length = (GLsizei)w;
}

GL_APICALL void GL_APIENTRY glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
  FvglShader* s = shader_get(shader, "glGetShaderInfoLog");
  if (!s) return;
  copy_log(s->log, bufSize, length, infoLog);
}

GL_APICALL void GL_APIENTRY glGetShaderSource(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* source) {
  FvglShader* s = shader_get(shader, "glGetShaderSource");
  if (!s) return;
  copy_log(s->source ? s->source : "", bufSize, length, source);
}

GL_APICALL void GL_APIENTRY glDeleteShader(GLuint shader) {
  if (shader == 0) return;
  FvglShader* s = shader_get(shader, "glDeleteShader");
  if (!s) return;
  if (s->attached > 0) {
    s->delete_pending = true;
    return;
  }
  shader_destroy(s, shader);
}

GL_APICALL GLboolean GL_APIENTRY glIsShader(GLuint shader) {
  return fvgl_table_get(&fvgl.shaders, shader) != NULL;
}

// ---- programs --------------------------------------------------------------

static void program_release_gxm(FvglProgram* p) {
  for (int i = 0; i < p->vertex_variant_count; i++)
    sceGxmShaderPatcherReleaseVertexProgram(fvgl.patcher, p->vertex_variants[i].program);
  for (int i = 0; i < p->fragment_variant_count; i++)
    sceGxmShaderPatcherReleaseFragmentProgram(fvgl.patcher, p->fragment_variants[i].program);
  fvgl_vertex_variants -= (unsigned)p->vertex_variant_count;
  fvgl_fragment_variants -= (unsigned)p->fragment_variant_count;
  p->vertex_variant_count = p->fragment_variant_count = 0;
  if (p->vid) sceGxmShaderPatcherUnregisterProgram(fvgl.patcher, p->vid);
  if (p->fid) sceGxmShaderPatcherUnregisterProgram(fvgl.patcher, p->fid);
  p->vid = p->fid = 0;
  free(p->vgxp);
  free(p->fgxp);
  p->vgxp = p->fgxp = NULL;
  for (int i = 0; i < p->uniform_count; i++) free(p->uniforms[i].values);
  p->uniform_count = 0;
  p->attribute_count = 0;
  p->fc_param = NULL;
  p->linked = false;
}

static void shader_detach(FvglShader* s, unsigned name) {
  if (!s) return;
  s->attached--;
  if (s->attached <= 0 && s->delete_pending) shader_destroy(s, name);
}

static void program_destroy(FvglProgram* p, GLuint name) {
  if (fvgl.bound_program == p) fvgl.bound_program = NULL;
  program_release_gxm(p);
  shader_detach(p->vs, p->vs_name);
  shader_detach(p->fs, p->fs_name);
  free(p);
  fvgl_table_clear(&fvgl.programs, name);
}

GL_APICALL GLuint GL_APIENTRY glCreateProgram(void) {
  FvglProgram* p = calloc(1, sizeof *p);
  return fvgl_table_add(&fvgl.programs, p);
}

GL_APICALL void GL_APIENTRY glAttachShader(GLuint program, GLuint shader) {
  FvglProgram* p = program_get(program, "glAttachShader");
  FvglShader* s = shader_get(shader, "glAttachShader");
  if (!p || !s) return;
  FvglShader** slot = s->type == GL_VERTEX_SHADER ? &p->vs : &p->fs;
  if (*slot) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  *slot = s;
  if (s->type == GL_VERTEX_SHADER) p->vs_name = shader;
  else p->fs_name = shader;
  s->attached++;
}

GL_APICALL void GL_APIENTRY glDetachShader(GLuint program, GLuint shader) {
  FvglProgram* p = program_get(program, "glDetachShader");
  FvglShader* s = shader_get(shader, "glDetachShader");
  if (!p || !s) return;
  if (p->vs == s) {
    p->vs = NULL;
    p->vs_name = 0;
  } else if (p->fs == s) {
    p->fs = NULL;
    p->fs_name = 0;
  } else {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  shader_detach(s, shader);
}

GL_APICALL void GL_APIENTRY glBindAttribLocation(GLuint program, GLuint index, const GLchar* name) {
  FvglProgram* p = program_get(program, "glBindAttribLocation");
  if (!p || !name) return;
  if (index >= FVGL_MAX_ATTRIBUTES) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (strncmp(name, "gl_", 3) == 0) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  for (int i = 0; i < p->bound_count; i++) {
    if (strcmp(p->bound_names[i], name) == 0) {
      p->bound_locations[i] = (int)index;
      return;
    }
  }
  if (p->bound_count == FVGL_MAX_ATTRIBUTES) return;
  snprintf(p->bound_names[p->bound_count], FVGL_NAME_MAX, "%s", name);
  p->bound_locations[p->bound_count] = (int)index;
  p->bound_count++;
}

static int compare_names(const void* a, const void* b) { return strcmp(a, b); }

static void link_fail(FvglProgram* p, const char* stage, const char* what) {
  snprintf(p->log, sizeof p->log, "%s shader: %.*s", stage, (int)sizeof p->log - 24, what);
  fvgl_log("link failed, %s", p->log);
  program_release_gxm(p);
}

static FvglUniform* uniform_find(FvglProgram* p, const char* name) {
  for (int i = 0; i < p->uniform_count; i++) {
    if (strcmp(p->uniforms[i].name, name) == 0) return &p->uniforms[i];
  }
  return NULL;
}

static void add_uniforms(FvglProgram* p, const FvglShaderInfo* info, const SceGxmProgram* gxp, bool fragment) {
  for (int i = 0; i < info->uniform_count; i++) {
    const FvglDecl* d = &info->uniforms[i];
    FvglUniform* u = uniform_find(p, d->name);
    if (!u) {
      if (p->uniform_count == FVGL_MAX_UNIFORMS) break;
      u = &p->uniforms[p->uniform_count++];
      memset(u, 0, sizeof *u);
      snprintf(u->name, sizeof u->name, "%s", d->name);
      u->type = d->type;
      u->components = fvgl_type_components(d->type);
      u->array = d->type.array ? d->type.array : 1;
      u->is_sampler = d->type.base == FVGL_T_SAMPLER2D || d->type.base == FVGL_T_SAMPLERCUBE;
      u->values = calloc((size_t)u->array * (size_t)u->components, sizeof(float));
    }
    char cg[FVGL_NAME_MAX];
    fvgl_cg_name(d->name, cg);
    const SceGxmProgramParameter* param = sceGxmProgramFindParameterByName(gxp, cg);
    if (fragment) u->fp = param;
    else u->vp = param;
  }
}

// Where the raster thread's link time goes, cumulative: the whole of
// glLinkProgram, and the part of it that reads programs back from the card.
unsigned fvgl_us_link, fvgl_us_cache_read;

GL_APICALL void GL_APIENTRY glLinkProgram(GLuint program) {
  FvglProgram* p = program_get(program, "glLinkProgram");
  if (!p) return;
  const uint64_t t0 = fvgl_now_us();
  const unsigned read0 = fvgl_us_cache_read;
  program_release_gxm(p);
  p->log[0] = 0;
  if (!p->vs || !p->fs) {
    snprintf(p->log, sizeof p->log, "a vertex and a fragment shader are both needed");
    return;
  }
  if (!p->vs->compiled || !p->fs->compiled) {
    snprintf(p->log, sizeof p->log, "attached shader did not compile");
    return;
  }

  // Varyings: the union of both sides, sorted, so the indices agree.
  FvglVaryingMap map;
  map.count = 0;
  const FvglShaderInfo* infos[2] = {&p->vs->info, &p->fs->info};
  for (int k = 0; k < 2; k++) {
    for (int i = 0; i < infos[k]->varying_count; i++) {
      const char* name = infos[k]->varyings[i].name;
      bool have = false;
      for (int j = 0; j < map.count; j++) have = have || strcmp(map.names[j], name) == 0;
      if (have) continue;
      if (map.count == FVGL_MAX_VARYINGS) {
        snprintf(p->log, sizeof p->log, "more than %d varyings", FVGL_MAX_VARYINGS);
        fvgl_log("link failed: %s", p->log);
        return;
      }
      snprintf(map.names[map.count++], FVGL_NAME_MAX, "%s", name);
    }
  }
  qsort(map.names, (size_t)map.count, sizeof map.names[0], compare_names);

  char* vcg = NULL;
  char* fcg = NULL;
  char log[1024];
  FvglShaderInfo vinfo, finfo;
  if (fvgl_translate(p->vs->source, false, &map, &vcg, &vinfo, log, sizeof log) != 0) {
    link_fail(p, "vertex", log);
    return;
  }
  if (fvgl_translate(p->fs->source, true, &map, &fcg, &finfo, log, sizeof log) != 0) {
    free(vcg);
    link_fail(p, "fragment", log);
    return;
  }
  p->vgxp = fvgl_shacc_compile(vcg, false, log, sizeof log);
  if (!p->vgxp) {
    fvgl_log("vertex Cg that failed:\n%s", vcg);
    free(vcg);
    free(fcg);
    link_fail(p, "vertex", log);
    return;
  }
  p->fgxp = fvgl_shacc_compile(fcg, true, log, sizeof log);
  if (!p->fgxp) {
    fvgl_log("fragment Cg that failed:\n%s", fcg);
    free(vcg);
    free(fcg);
    link_fail(p, "fragment", log);
    return;
  }
  free(vcg);
  free(fcg);

  int r = sceGxmShaderPatcherRegisterProgram(fvgl.patcher, p->vgxp, &p->vid);
  if (r < 0) {
    snprintf(log, sizeof log, "sceGxmShaderPatcherRegisterProgram 0x%08X", (unsigned)r);
    link_fail(p, "vertex", log);
    return;
  }
  r = sceGxmShaderPatcherRegisterProgram(fvgl.patcher, p->fgxp, &p->fid);
  if (r < 0) {
    snprintf(log, sizeof log, "sceGxmShaderPatcherRegisterProgram 0x%08X", (unsigned)r);
    link_fail(p, "fragment", log);
    return;
  }

  // Attributes: bound locations first, the rest fill the gaps in order.
  bool taken[FVGL_MAX_ATTRIBUTES] = {false};
  p->attribute_count = 0;
  for (int i = 0; i < vinfo.attribute_count && p->attribute_count < FVGL_MAX_ATTRIBUTES; i++) {
    FvglAttribute* a = &p->attributes[p->attribute_count++];
    snprintf(a->name, sizeof a->name, "%s", vinfo.attributes[i].name);
    a->location = -1;
    a->components = fvgl_type_components(vinfo.attributes[i].type);
    for (int j = 0; j < p->bound_count; j++) {
      if (strcmp(p->bound_names[j], a->name) == 0) {
        a->location = p->bound_locations[j];
        taken[a->location] = true;
      }
    }
    char cg[FVGL_NAME_MAX];
    fvgl_cg_name(a->name, cg);
    a->param = sceGxmProgramFindParameterByName(p->vgxp, cg);
  }
  int next_free = 0;
  for (int i = 0; i < p->attribute_count; i++) {
    if (p->attributes[i].location >= 0) continue;
    while (next_free < FVGL_MAX_ATTRIBUTES && taken[next_free]) next_free++;
    if (next_free == FVGL_MAX_ATTRIBUTES) {
      link_fail(p, "vertex", "too many attributes");
      return;
    }
    p->attributes[i].location = next_free;
    taken[next_free++] = true;
  }

  p->uniform_count = 0;
  add_uniforms(p, &vinfo, p->vgxp, false);
  add_uniforms(p, &finfo, p->fgxp, true);
  p->fc_param = finfo.uses_fragcoord ? sceGxmProgramFindParameterByName(p->fgxp, "fvgl_fc") : NULL;

  p->linked = true;
  p->uniforms_dirty = true;
  const unsigned took = (unsigned)(fvgl_now_us() - t0);
  fvgl_us_link += took;
  fvgl_log("program %u linked: %d attributes, %d uniforms, %d varyings, vs %u B, fs %u B, %u us (card %u us)",
           program, p->attribute_count, p->uniform_count, map.count, sceGxmProgramGetSize(p->vgxp),
           sceGxmProgramGetSize(p->fgxp), took, fvgl_us_cache_read - read0);
}

GL_APICALL void GL_APIENTRY glUseProgram(GLuint program) {
  if (program == 0) {
    fvgl.current_program = NULL;
    return;
  }
  FvglProgram* p = program_get(program, "glUseProgram");
  if (!p) return;
  if (!p->linked) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return;
  }
  fvgl.current_program = p;
}

GL_APICALL void GL_APIENTRY glValidateProgram(GLuint program) { (void)program_get(program, "glValidateProgram"); }

GL_APICALL void GL_APIENTRY glGetProgramiv(GLuint program, GLenum pname, GLint* params) {
  FvglProgram* p = program_get(program, "glGetProgramiv");
  if (!p || !params) return;
  switch (pname) {
    case GL_DELETE_STATUS: *params = p->delete_pending; break;
    case GL_LINK_STATUS: *params = p->linked; break;
    case GL_VALIDATE_STATUS: *params = p->linked; break;
    case GL_INFO_LOG_LENGTH: *params = p->log[0] ? (GLint)strlen(p->log) + 1 : 0; break;
    case GL_ATTACHED_SHADERS: *params = (p->vs != NULL) + (p->fs != NULL); break;
    case GL_ACTIVE_ATTRIBUTES: *params = p->attribute_count; break;
    case GL_ACTIVE_UNIFORMS: *params = p->uniform_count; break;
    case GL_ACTIVE_ATTRIBUTE_MAX_LENGTH:
    case GL_ACTIVE_UNIFORM_MAX_LENGTH: *params = FVGL_NAME_MAX; break;
    default: fvgl_set_error(GL_INVALID_ENUM); break;
  }
}

GL_APICALL void GL_APIENTRY glGetProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
  FvglProgram* p = program_get(program, "glGetProgramInfoLog");
  if (!p) return;
  copy_log(p->log, bufSize, length, infoLog);
}

GL_APICALL GLint GL_APIENTRY glGetUniformLocation(GLuint program, const GLchar* name) {
  FvglProgram* p = program_get(program, "glGetUniformLocation");
  if (!p || !name || !p->linked) return -1;
  // "name[0]" asks for the array's first element, which is the array.
  char plain[FVGL_NAME_MAX];
  snprintf(plain, sizeof plain, "%s", name);
  const size_t n = strlen(plain);
  if (n > 3 && strcmp(plain + n - 3, "[0]") == 0) plain[n - 3] = 0;
  for (int i = 0; i < p->uniform_count; i++) {
    if (strcmp(p->uniforms[i].name, plain) == 0) {
      // Dropped by the compiler on both sides: inactive, as GL says.
      if (!p->uniforms[i].vp && !p->uniforms[i].fp) return -1;
      return i;
    }
  }
  return -1;
}

GL_APICALL GLint GL_APIENTRY glGetAttribLocation(GLuint program, const GLchar* name) {
  FvglProgram* p = program_get(program, "glGetAttribLocation");
  if (!p || !name || !p->linked) return -1;
  for (int i = 0; i < p->attribute_count; i++) {
    if (strcmp(p->attributes[i].name, name) == 0) return p->attributes[i].location;
  }
  return -1;
}

GL_APICALL void GL_APIENTRY glDeleteProgram(GLuint program) {
  if (program == 0) return;
  FvglProgram* p = program_get(program, "glDeleteProgram");
  if (!p) return;
  if (fvgl.current_program == p) {
    p->delete_pending = true;
    return;
  }
  program_destroy(p, program);
}

GL_APICALL GLboolean GL_APIENTRY glIsProgram(GLuint program) {
  return fvgl_table_get(&fvgl.programs, program) != NULL;
}

// ---- uniforms --------------------------------------------------------------

static FvglUniform* uniform_for(GLint location, int components, bool matrix) {
  FvglProgram* p = fvgl.current_program;
  if (!p) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return NULL;
  }
  if (location == -1) return NULL;
  if (location < 0 || location >= p->uniform_count) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return NULL;
  }
  FvglUniform* u = &p->uniforms[location];
  const bool is_matrix = u->type.rows > 0;
  if (is_matrix != matrix || (u->is_sampler ? components != 1 : u->components != components)) {
    fvgl_set_error(GL_INVALID_OPERATION);
    return NULL;
  }
  p->uniforms_dirty = true;
  return u;
}

static void uniform_store(FvglUniform* u, GLsizei count, const float* v) {
  if (count < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (count > u->array) count = u->array;
  memcpy(u->values, v, sizeof(float) * (size_t)count * (size_t)u->components);
}

static void uniform_store_i(FvglUniform* u, GLsizei count, const GLint* v) {
  if (count < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (count > u->array) count = u->array;
  for (GLsizei i = 0; i < count * u->components; i++) u->values[i] = (float)v[i];
}

GL_APICALL void GL_APIENTRY glUniform1f(GLint location, GLfloat v0) {
  FvglUniform* u = uniform_for(location, 1, false);
  if (u) uniform_store(u, 1, &v0);
}
GL_APICALL void GL_APIENTRY glUniform2f(GLint location, GLfloat v0, GLfloat v1) {
  FvglUniform* u = uniform_for(location, 2, false);
  const float v[2] = {v0, v1};
  if (u) uniform_store(u, 1, v);
}
GL_APICALL void GL_APIENTRY glUniform3f(GLint location, GLfloat v0, GLfloat v1, GLfloat v2) {
  FvglUniform* u = uniform_for(location, 3, false);
  const float v[3] = {v0, v1, v2};
  if (u) uniform_store(u, 1, v);
}
GL_APICALL void GL_APIENTRY glUniform4f(GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3) {
  FvglUniform* u = uniform_for(location, 4, false);
  const float v[4] = {v0, v1, v2, v3};
  if (u) uniform_store(u, 1, v);
}
GL_APICALL void GL_APIENTRY glUniform1fv(GLint location, GLsizei count, const GLfloat* v) {
  FvglUniform* u = uniform_for(location, 1, false);
  if (u) uniform_store(u, count, v);
}
GL_APICALL void GL_APIENTRY glUniform2fv(GLint location, GLsizei count, const GLfloat* v) {
  FvglUniform* u = uniform_for(location, 2, false);
  if (u) uniform_store(u, count, v);
}
GL_APICALL void GL_APIENTRY glUniform3fv(GLint location, GLsizei count, const GLfloat* v) {
  FvglUniform* u = uniform_for(location, 3, false);
  if (u) uniform_store(u, count, v);
}
GL_APICALL void GL_APIENTRY glUniform4fv(GLint location, GLsizei count, const GLfloat* v) {
  FvglUniform* u = uniform_for(location, 4, false);
  if (u) uniform_store(u, count, v);
}

GL_APICALL void GL_APIENTRY glUniform1i(GLint location, GLint v0) {
  FvglUniform* u = uniform_for(location, 1, false);
  if (!u) return;
  if (u->is_sampler) u->unit = v0;
  else u->values[0] = (float)v0;
}
GL_APICALL void GL_APIENTRY glUniform2i(GLint location, GLint v0, GLint v1) {
  FvglUniform* u = uniform_for(location, 2, false);
  const GLint v[2] = {v0, v1};
  if (u) uniform_store_i(u, 1, v);
}
GL_APICALL void GL_APIENTRY glUniform3i(GLint location, GLint v0, GLint v1, GLint v2) {
  FvglUniform* u = uniform_for(location, 3, false);
  const GLint v[3] = {v0, v1, v2};
  if (u) uniform_store_i(u, 1, v);
}
GL_APICALL void GL_APIENTRY glUniform4i(GLint location, GLint v0, GLint v1, GLint v2, GLint v3) {
  FvglUniform* u = uniform_for(location, 4, false);
  const GLint v[4] = {v0, v1, v2, v3};
  if (u) uniform_store_i(u, 1, v);
}
GL_APICALL void GL_APIENTRY glUniform1iv(GLint location, GLsizei count, const GLint* v) {
  FvglUniform* u = uniform_for(location, 1, false);
  if (!u) return;
  if (u->is_sampler) u->unit = count > 0 ? v[0] : u->unit;
  else uniform_store_i(u, count, v);
}
GL_APICALL void GL_APIENTRY glUniform2iv(GLint location, GLsizei count, const GLint* v) {
  FvglUniform* u = uniform_for(location, 2, false);
  if (u) uniform_store_i(u, count, v);
}
GL_APICALL void GL_APIENTRY glUniform3iv(GLint location, GLsizei count, const GLint* v) {
  FvglUniform* u = uniform_for(location, 3, false);
  if (u) uniform_store_i(u, count, v);
}
GL_APICALL void GL_APIENTRY glUniform4iv(GLint location, GLsizei count, const GLint* v) {
  FvglUniform* u = uniform_for(location, 4, false);
  if (u) uniform_store_i(u, count, v);
}

static void uniform_matrix(GLint location, int n, GLsizei count, GLboolean transpose, const GLfloat* v) {
  FvglUniform* u = uniform_for(location, n * n, true);
  if (!u) return;
  if (count < 0) {
    fvgl_set_error(GL_INVALID_VALUE);
    return;
  }
  if (count > u->array) count = u->array;
  for (GLsizei e = 0; e < count; e++) {
    float* dst = u->values + e * n * n;
    const float* src = v + e * n * n;
    if (!transpose) {
      memcpy(dst, src, sizeof(float) * (size_t)(n * n));
    } else {
      for (int c = 0; c < n; c++)
        for (int r = 0; r < n; r++) dst[c * n + r] = src[r * n + c];
    }
  }
}

GL_APICALL void GL_APIENTRY glUniformMatrix2fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
  uniform_matrix(location, 2, count, transpose, value);
}
GL_APICALL void GL_APIENTRY glUniformMatrix3fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
  uniform_matrix(location, 3, count, transpose, value);
}
GL_APICALL void GL_APIENTRY glUniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
  uniform_matrix(location, 4, count, transpose, value);
}

void fvgl_programs_shutdown(void) {
  for (unsigned i = 1; i <= fvgl.programs.count; i++) {
    FvglProgram* p = fvgl_table_get(&fvgl.programs, i);
    if (p) program_destroy(p, i);
  }
  for (unsigned i = 1; i <= fvgl.shaders.count; i++) {
    FvglShader* s = fvgl_table_get(&fvgl.shaders, i);
    if (s) shader_destroy(s, i);
  }
  free(fvgl.programs.items);
  free(fvgl.shaders.items);
  memset(&fvgl.programs, 0, sizeof fvgl.programs);
  memset(&fvgl.shaders, 0, sizeof fvgl.shaders);
  fvgl.current_program = fvgl.bound_program = NULL;
}

int fvgl_debug_compile(const char* glsl, int fragment, char* log, unsigned log_size) {
  FvglShaderInfo info;
  if (fvgl_translate(glsl, fragment != 0, NULL, NULL, &info, log, log_size) != 0) return -1;
  FvglVaryingMap map;
  map.count = info.varying_count;
  for (int i = 0; i < info.varying_count; i++) snprintf(map.names[i], FVGL_NAME_MAX, "%s", info.varyings[i].name);
  char* cg = NULL;
  if (fvgl_translate(glsl, fragment != 0, &map, &cg, &info, log, log_size) != 0) return -1;
  SceGxmProgram* gxp = fvgl_shacc_compile(cg, fragment != 0, log, log_size);
  if (!gxp) {
    fvgl_log("Cg the compiler refused:\n%s", cg);
    free(cg);
    return -1;
  }
  free(cg);
  free(gxp);
  return 0;
}
