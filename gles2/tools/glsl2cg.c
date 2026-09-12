// Host-side driver for the translator: GLSL in, Cg out, for eyes and tests.
//
//   glsl2cg [-f|-v] file.glsl        translate one shader (kind from the name if omitted)
//
// Varyings get TEXCOORD indices in declaration order, which is what the link
// step does too when both shaders agree.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/translate.h"

static char* slurp(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char* s = malloc((size_t)n + 1);
  fread(s, 1, (size_t)n, f);
  s[n] = 0;
  fclose(f);
  return s;
}

int main(int argc, char** argv) {
  int fragment = -1;
  const char* path = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-f") == 0) fragment = 1;
    else if (strcmp(argv[i], "-v") == 0) fragment = 0;
    else path = argv[i];
  }
  if (!path) {
    fprintf(stderr, "usage: glsl2cg [-f|-v] file.glsl\n");
    return 2;
  }
  if (fragment < 0) fragment = strstr(path, "frag") != NULL;
  char* src = slurp(path);
  if (!src) {
    perror(path);
    return 2;
  }
  char log[1024];
  FvglShaderInfo info;
  // Pass one: parse, to learn the varyings.
  if (fvgl_translate(src, fragment, NULL, NULL, &info, log, sizeof log) != 0) {
    fprintf(stderr, "%s: %s\n", path, log);
    return 1;
  }
  FvglVaryingMap map;
  map.count = info.varying_count;
  for (int i = 0; i < info.varying_count; i++) snprintf(map.names[i], sizeof map.names[i], "%s", info.varyings[i].name);
  char* cg = NULL;
  if (fvgl_translate(src, fragment, &map, &cg, &info, log, sizeof log) != 0) {
    fprintf(stderr, "%s: %s\n", path, log);
    return 1;
  }
  fputs(cg, stdout);
  free(cg);
  free(src);
  return 0;
}
