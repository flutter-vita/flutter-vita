// GLSL ES 1.00, as Skia emits it, to Cg, as the Vita's compiler takes it.
//
// Two passes over a shader: glCompileShader parses it and records what it
// declares; glLinkProgram, knowing both shaders, assigns each varying a
// TEXCOORD index and emits the Cg. The same function does both: pass a null
// varying map to parse only.
#ifndef FVGL_TRANSLATE_H
#define FVGL_TRANSLATE_H

#include <stdbool.h>
#include <stddef.h>

#define FVGL_NAME_MAX 64
#define FVGL_MAX_ATTRIBUTES 16
#define FVGL_MAX_VARYINGS 10  // TEXCOORD0..9 on this GPU
#define FVGL_MAX_UNIFORMS 64

typedef enum FvglBase {
  FVGL_T_VOID,
  FVGL_T_BOOL,
  FVGL_T_INT,
  FVGL_T_FLOAT,
  FVGL_T_SAMPLER2D,
  FVGL_T_SAMPLERCUBE,
  FVGL_T_STRUCT,  // only inside a shader: never a uniform, attribute or varying
} FvglBase;

// cols is the vector length, or the matrix dimension when rows > 0; 0 for a
// struct, which is neither scalar nor vector.
typedef struct FvglType {
  unsigned char base, cols, rows;
  unsigned char strct;  // FVGL_T_STRUCT: 1 + the struct's index in its shader
  int array;  // element count, 0 when not an array
} FvglType;

typedef struct FvglDecl {
  char name[FVGL_NAME_MAX];
  FvglType type;
} FvglDecl;

typedef struct FvglShaderInfo {
  int attribute_count;
  FvglDecl attributes[FVGL_MAX_ATTRIBUTES];
  int varying_count;
  FvglDecl varyings[FVGL_MAX_VARYINGS];
  int uniform_count;
  FvglDecl uniforms[FVGL_MAX_UNIFORMS];
  bool uses_fragcoord;
  bool uses_pointsize;
} FvglShaderInfo;

// Varying name -> TEXCOORD index, decided at link over both shaders.
typedef struct FvglVaryingMap {
  int count;
  char names[FVGL_MAX_VARYINGS][FVGL_NAME_MAX];
} FvglVaryingMap;

// Parses `glsl`, fills `info`, and when `map` is given writes the Cg into a
// malloc'd string at *cg_out. Returns 0, or -1 with the reason in `log`
// naming the construct it refused.
int fvgl_translate(const char* glsl, bool fragment, const FvglVaryingMap* map,
                   char** cg_out, FvglShaderInfo* info, char* log, size_t log_size);

// Component count of a type: 1 for scalars, n for vectors, n*n for matrices.
int fvgl_type_components(FvglType t);

// The Cg spelling of a GLSL identifier: the same, or prefixed when the name
// is a Cg keyword. What sceGxmProgramFindParameterByName has to be asked for.
void fvgl_cg_name(const char* glsl_name, char out[FVGL_NAME_MAX]);

#endif
