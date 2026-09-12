// GLSL ES 1.00 to Cg, for the dialect Skia emits. See translate.h.
//
// The language accepted is the one measured in gles2/corpus: scalar, vector
// and matrix types, uniforms (arrays included), attributes, varyings, one
// `main`, blocks, `if`, `for`, `while`, `do`, assignments, the arithmetic
// operators, swizzles, constructors, and the built-in functions in the table
// below. Anything else stops with an error that names it, so a new app's
// shader turns into a line in a log and then a line in this file.
//
// What the translation has to get right, beyond spelling:
//
//   * GLSL matrices are column-major and `M * v` applies M; Cg's `mul` is
//     row-vector by default. A GLSL column becomes a Cg row (same
//     constructor argument order, same upload order), and `M * v` becomes
//     `mul(v, M)`, `v * M` becomes `mul(M, v)`, `A * B` becomes `mul(B, A)`.
//     That needs the type of every operand, so expressions are typed here.
//   * `vec4(x)` splats, `vec3(v4)` truncates, `float(i)` converts. Cg has
//     none of those as constructors, so each becomes a swizzle or a cast.
//   * `mod` is floored in GLSL and truncated in Cg; a helper does the GLSL one.
//   * Varyings need matching TEXCOORD indices on both sides; the link step
//     supplies the map.
//   * gl_FragCoord is bottom-up in GL and WPOS is top-down: a hidden uniform
//     fvgl_fc, set per render target, turns one into the other.
#include "translate.h"

#include <ctype.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- memory and errors ----------------------------------------------------

typedef struct Block {
  struct Block* next;
  size_t used, cap;
  char data[];
} Block;

typedef struct Tx Tx;

static void* tx_alloc(Tx* tx, size_t n);

typedef struct Buf {
  char* s;
  size_t len, cap;
} Buf;

// ---- tokens ------------------------------------------------------------------

typedef enum TokKind { TK_EOF, TK_IDENT, TK_INT, TK_FLOAT, TK_PUNCT } TokKind;

typedef struct Token {
  TokKind kind;
  const char* s;
  int len;
  int line;
} Token;

// ---- syntax tree -----------------------------------------------------------

typedef enum ExprKind {
  E_NUM,
  E_BOOL,
  E_IDENT,
  E_UNARY,    // op a          (-, !, ++pre, --pre)
  E_POSTFIX,  // a op          (++, --)
  E_BINARY,   // a op b
  E_ASSIGN,   // a op b        (=, +=, -=, *=, /=)
  E_TERNARY,  // a ? b : c
  E_CALL,     // name(args)
  E_INDEX,    // a[b]
  E_FIELD,    // a.name
} ExprKind;

typedef struct Expr {
  ExprKind kind;
  const char* op;  // punctuation text, interned from the token
  int oplen;
  struct Expr *a, *b, *c;
  const char* name;
  int namelen;
  struct Expr** args;
  int nargs;
  int line;
} Expr;

typedef struct Decl {
  const char* name;
  int namelen;
  FvglType type;
  Expr* init;
  bool is_const;
  struct Decl* next;
} Decl;

typedef enum StmtKind {
  S_BLOCK,
  S_DECL,
  S_EXPR,
  S_IF,
  S_FOR,
  S_WHILE,
  S_DO,
  S_RETURN,
  S_DISCARD,
  S_BREAK,
  S_CONTINUE,
  S_EMPTY,
} StmtKind;

typedef struct Stmt {
  StmtKind kind;
  struct Stmt** items;  // block
  int nitems;
  Decl* decls;
  Expr* expr;  // expression, return value, condition
  struct Stmt *then, *els, *body, *init;
  Expr *cond, *step;
  int line;
} Stmt;

// ---- symbols ---------------------------------------------------------------

typedef enum SymKind { SYM_ATTRIBUTE, SYM_UNIFORM, SYM_VARYING, SYM_LOCAL, SYM_CONST, SYM_BUILTIN } SymKind;

typedef struct Sym {
  const char* name;
  int namelen;
  FvglType type;
  SymKind kind;
  int scope;
  const char* alias;  // Cg spelling when it differs from the GLSL name
} Sym;

// ---- the translation state -------------------------------------------------

struct Tx {
  Block* blocks;
  jmp_buf fail;
  char* log;
  size_t log_size;

  const char* src;
  Token* toks;
  int ntoks, pos;

  bool fragment;
  const FvglVaryingMap* map;
  FvglShaderInfo* info;

  Sym* syms;
  int nsyms, symcap;
  int scope;

  // Globals in declaration order, for the header.
  Decl* globals;    // uniforms and consts
  Decl* attributes;
  Decl* varyings;
  Stmt* main_body;
  bool uses_fragcoord, uses_pointsize, uses_fragcolor;
};

static void* tx_alloc(Tx* tx, size_t n) {
  n = (n + 7) & ~(size_t)7;
  Block* b = tx->blocks;
  if (!b || b->used + n > b->cap) {
    size_t cap = n > 32768 ? n : 32768;
    b = malloc(sizeof(Block) + cap);
    if (!b) {
      snprintf(tx->log, tx->log_size, "out of memory");
      longjmp(tx->fail, 1);
    }
    b->next = tx->blocks;
    b->used = 0;
    b->cap = cap;
    tx->blocks = b;
  }
  void* p = b->data + b->used;
  b->used += n;
  memset(p, 0, n);
  return p;
}

static void tx_free_all(Tx* tx) {
  Block* b = tx->blocks;
  while (b) {
    Block* next = b->next;
    free(b);
    b = next;
  }
  tx->blocks = NULL;
  free(tx->syms);
  tx->syms = NULL;
}

static void fail(Tx* tx, int line, const char* fmt, ...) __attribute__((noreturn, format(printf, 3, 4)));
static void fail(Tx* tx, int line, const char* fmt, ...) {
  char msg[400];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof msg, fmt, ap);
  va_end(ap);
  snprintf(tx->log, tx->log_size, "line %d: %s", line, msg);
  longjmp(tx->fail, 1);
}

static void buf_put(Tx* tx, Buf* b, const char* s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap * 2 : 4096;
    while (cap < b->len + n + 1) cap *= 2;
    char* s2 = realloc(b->s, cap);
    if (!s2) fail(tx, 0, "out of memory");
    b->s = s2;
    b->cap = cap;
  }
  memcpy(b->s + b->len, s, n);
  b->len += n;
  b->s[b->len] = 0;
}

static void buf_str(Tx* tx, Buf* b, const char* s) { buf_put(tx, b, s, strlen(s)); }

static void buf_fmt(Tx* tx, Buf* b, const char* fmt, ...) __attribute__((format(printf, 3, 4)));
static void buf_fmt(Tx* tx, Buf* b, const char* fmt, ...) {
  char tmp[512];
  va_list ap;
  va_start(ap, fmt);
  const int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
  va_end(ap);
  buf_put(tx, b, tmp, (size_t)(n < (int)sizeof tmp ? n : (int)sizeof tmp - 1));
}

// ---- lexer -----------------------------------------------------------------

static const char* const kPuncts[] = {
    "<<=", ">>=", "++", "--", "<=", ">=", "==", "!=", "&&", "||", "^^", "+=", "-=", "*=", "/=",
    "<<", ">>", "+", "-", "*", "/", "%", "<", ">", "=", "!", "?", ":", ";", ",", ".", "(", ")",
    "[", "]", "{", "}", "&", "|", "^", "~", NULL};

static void lex(Tx* tx) {
  const char* p = tx->src;
  int line = 1;
  int cap = 1024;
  tx->toks = tx_alloc(tx, sizeof(Token) * (size_t)cap);
  tx->ntoks = 0;
  for (;;) {
    // Whitespace, comments, preprocessor lines.
    for (;;) {
      while (*p == ' ' || *p == '\t' || *p == '\r') p++;
      if (*p == '\n') {
        line++;
        p++;
        continue;
      }
      if (p[0] == '/' && p[1] == '/') {
        while (*p && *p != '\n') p++;
        continue;
      }
      if (p[0] == '/' && p[1] == '*') {
        p += 2;
        while (*p && !(p[0] == '*' && p[1] == '/')) {
          if (*p == '\n') line++;
          p++;
        }
        if (*p) p += 2;
        continue;
      }
      if (*p == '#') {
        const char* start = p;
        while (*p && *p != '\n') p++;
        const size_t n = (size_t)(p - start);
        if (n >= 8 && strncmp(start, "#version", 8) == 0) continue;
        char directive[64];
        snprintf(directive, sizeof directive, "%.*s", (int)(n < 40 ? n : 40), start);
        fail(tx, line, "preprocessor directive is not supported: %s", directive);
      }
      break;
    }
    if (tx->ntoks + 1 >= cap) {
      Token* bigger = tx_alloc(tx, sizeof(Token) * (size_t)cap * 2);
      memcpy(bigger, tx->toks, sizeof(Token) * (size_t)tx->ntoks);
      tx->toks = bigger;
      cap *= 2;
    }
    Token* t = &tx->toks[tx->ntoks++];
    t->s = p;
    t->line = line;
    if (!*p) {
      t->kind = TK_EOF;
      t->len = 0;
      return;
    }
    if (isalpha((unsigned char)*p) || *p == '_') {
      while (isalnum((unsigned char)*p) || *p == '_') p++;
      t->kind = TK_IDENT;
      t->len = (int)(p - t->s);
      continue;
    }
    if (isdigit((unsigned char)*p) || (*p == '.' && isdigit((unsigned char)p[1]))) {
      bool is_float = false;
      while (isdigit((unsigned char)*p)) p++;
      if (*p == '.') {
        is_float = true;
        p++;
        while (isdigit((unsigned char)*p)) p++;
      }
      if (*p == 'e' || *p == 'E') {
        is_float = true;
        p++;
        if (*p == '+' || *p == '-') p++;
        while (isdigit((unsigned char)*p)) p++;
      }
      if (*p == 'u' || *p == 'U') p++;  // not in ES 1.00, tolerated
      t->kind = is_float ? TK_FLOAT : TK_INT;
      t->len = (int)(p - t->s);
      continue;
    }
    for (int i = 0; kPuncts[i]; i++) {
      const size_t n = strlen(kPuncts[i]);
      if (strncmp(p, kPuncts[i], n) == 0) {
        t->kind = TK_PUNCT;
        t->len = (int)n;
        p += n;
        goto next;
      }
    }
    fail(tx, line, "unexpected character '%c'", *p);
  next:;
  }
}

// ---- token helpers ---------------------------------------------------------

static Token* peek(Tx* tx) { return &tx->toks[tx->pos]; }
static Token* peek2(Tx* tx) {
  return tx->toks[tx->pos].kind == TK_EOF ? &tx->toks[tx->pos] : &tx->toks[tx->pos + 1];
}
static Token* next(Tx* tx) {
  Token* t = &tx->toks[tx->pos];
  if (t->kind != TK_EOF) tx->pos++;
  return t;
}

static bool tok_is(const Token* t, const char* s) {
  const size_t n = strlen(s);
  return (t->kind == TK_PUNCT || t->kind == TK_IDENT) && (size_t)t->len == n && strncmp(t->s, s, n) == 0;
}

static bool accept(Tx* tx, const char* s) {
  if (tok_is(peek(tx), s)) {
    next(tx);
    return true;
  }
  return false;
}

static Token* expect(Tx* tx, const char* s) {
  Token* t = peek(tx);
  if (!tok_is(t, s)) fail(tx, t->line, "expected '%s', found '%.*s'", s, t->len, t->s);
  return next(tx);
}

static Token* expect_ident(Tx* tx) {
  Token* t = peek(tx);
  if (t->kind != TK_IDENT) fail(tx, t->line, "expected a name, found '%.*s'", t->len, t->s);
  return next(tx);
}

static const char* intern(Tx* tx, const char* s, int n) {
  char* p = tx_alloc(tx, (size_t)n + 1);
  memcpy(p, s, (size_t)n);
  p[n] = 0;
  return p;
}

// ---- types -----------------------------------------------------------------

static FvglType type_make(FvglBase base, int cols, int rows) {
  FvglType t = {(unsigned char)base, (unsigned char)cols, (unsigned char)rows, 0};
  return t;
}
static bool type_is_scalar(FvglType t) { return t.cols == 1 && t.rows == 0 && t.array == 0; }
static bool type_is_vector(FvglType t) { return t.cols > 1 && t.rows == 0 && t.array == 0; }
static bool type_is_matrix(FvglType t) { return t.rows > 0 && t.array == 0; }
static bool type_same(FvglType a, FvglType b) {
  return a.base == b.base && a.cols == b.cols && a.rows == b.rows && a.array == b.array;
}

int fvgl_type_components(FvglType t) {
  return t.rows ? (int)t.cols * (int)t.rows : (int)t.cols;
}

// The GLSL type named by an identifier, or false.
static bool type_by_name(const Token* t, FvglType* out) {
  static const struct {
    const char* name;
    FvglBase base;
    int cols, rows;
  } k[] = {
      {"void", FVGL_T_VOID, 1, 0},   {"bool", FVGL_T_BOOL, 1, 0},    {"int", FVGL_T_INT, 1, 0},
      {"float", FVGL_T_FLOAT, 1, 0}, {"vec2", FVGL_T_FLOAT, 2, 0},   {"vec3", FVGL_T_FLOAT, 3, 0},
      {"vec4", FVGL_T_FLOAT, 4, 0},  {"ivec2", FVGL_T_INT, 2, 0},    {"ivec3", FVGL_T_INT, 3, 0},
      {"ivec4", FVGL_T_INT, 4, 0},   {"bvec2", FVGL_T_BOOL, 2, 0},   {"bvec3", FVGL_T_BOOL, 3, 0},
      {"bvec4", FVGL_T_BOOL, 4, 0},  {"mat2", FVGL_T_FLOAT, 2, 2},   {"mat3", FVGL_T_FLOAT, 3, 3},
      {"mat4", FVGL_T_FLOAT, 4, 4},  {"sampler2D", FVGL_T_SAMPLER2D, 1, 0},
      {"samplerCube", FVGL_T_SAMPLERCUBE, 1, 0},
  };
  if (t->kind != TK_IDENT) return false;
  for (size_t i = 0; i < sizeof k / sizeof k[0]; i++) {
    if (tok_is(t, k[i].name)) {
      *out = type_make(k[i].base, k[i].cols, k[i].rows);
      return true;
    }
  }
  return false;
}

static const char* cg_type_name(Tx* tx, FvglType t, int line) {
  static const char* const f[] = {"", "float", "float2", "float3", "float4"};
  static const char* const i[] = {"", "int", "int2", "int3", "int4"};
  static const char* const b[] = {"", "bool", "bool2", "bool3", "bool4"};
  static const char* const m[] = {"", "", "float2x2", "float3x3", "float4x4"};
  switch (t.base) {
    case FVGL_T_VOID: return "void";
    case FVGL_T_SAMPLER2D: return "sampler2D";
    case FVGL_T_SAMPLERCUBE: return "samplerCUBE";
    case FVGL_T_BOOL: return b[t.cols];
    case FVGL_T_INT: return i[t.cols];
    case FVGL_T_FLOAT: return t.rows ? m[t.cols] : f[t.cols];
  }
  fail(tx, line, "type has no Cg spelling");
}

// ---- symbols ---------------------------------------------------------------

static void sym_add(Tx* tx, const char* name, int namelen, FvglType type, SymKind kind, int line) {
  for (int i = tx->nsyms - 1; i >= 0; i--) {
    Sym* s = &tx->syms[i];
    if (s->scope != tx->scope) break;
    if (s->namelen == namelen && strncmp(s->name, name, (size_t)namelen) == 0)
      fail(tx, line, "'%.*s' is declared twice in the same scope", namelen, name);
  }
  if (tx->nsyms == tx->symcap) {
    tx->symcap = tx->symcap ? tx->symcap * 2 : 128;
    tx->syms = realloc(tx->syms, sizeof(Sym) * (size_t)tx->symcap);
    if (!tx->syms) fail(tx, line, "out of memory");
  }
  Sym* s = &tx->syms[tx->nsyms++];
  s->name = name;
  s->namelen = namelen;
  s->type = type;
  s->kind = kind;
  s->scope = tx->scope;
  s->alias = NULL;
}

static Sym* sym_find(Tx* tx, const char* name, int namelen) {
  for (int i = tx->nsyms - 1; i >= 0; i--) {
    Sym* s = &tx->syms[i];
    if (s->namelen == namelen && strncmp(s->name, name, (size_t)namelen) == 0) return s;
  }
  return NULL;
}

static void scope_push(Tx* tx) { tx->scope++; }
static void scope_pop(Tx* tx) {
  while (tx->nsyms > 0 && tx->syms[tx->nsyms - 1].scope == tx->scope) tx->nsyms--;
  tx->scope--;
}

// ---- parser: expressions ---------------------------------------------------

static Expr* expr_new(Tx* tx, ExprKind kind, int line) {
  Expr* e = tx_alloc(tx, sizeof *e);
  e->kind = kind;
  e->line = line;
  return e;
}

static Expr* parse_assignment(Tx* tx);
static Expr* parse_expression(Tx* tx);

static Expr* parse_primary(Tx* tx) {
  Token* t = peek(tx);
  if (t->kind == TK_INT || t->kind == TK_FLOAT) {
    next(tx);
    Expr* e = expr_new(tx, E_NUM, t->line);
    e->name = intern(tx, t->s, t->len);
    e->namelen = t->len;
    e->oplen = t->kind == TK_FLOAT;  // 1 when a float literal
    return e;
  }
  if (tok_is(t, "true") || tok_is(t, "false")) {
    next(tx);
    Expr* e = expr_new(tx, E_BOOL, t->line);
    e->name = intern(tx, t->s, t->len);
    e->namelen = t->len;
    return e;
  }
  if (accept(tx, "(")) {
    Expr* inner = parse_expression(tx);
    expect(tx, ")");
    return inner;
  }
  if (t->kind == TK_IDENT) {
    next(tx);
    if (tok_is(peek(tx), "(")) {
      next(tx);
      Expr* e = expr_new(tx, E_CALL, t->line);
      e->name = intern(tx, t->s, t->len);
      e->namelen = t->len;
      Expr* args[32];
      int n = 0;
      if (!accept(tx, ")")) {
        do {
          if (n == 32) fail(tx, t->line, "more than 32 arguments");
          args[n++] = parse_assignment(tx);
        } while (accept(tx, ","));
        expect(tx, ")");
      }
      e->args = tx_alloc(tx, sizeof(Expr*) * (size_t)(n ? n : 1));
      memcpy(e->args, args, sizeof(Expr*) * (size_t)n);
      e->nargs = n;
      return e;
    }
    Expr* e = expr_new(tx, E_IDENT, t->line);
    e->name = intern(tx, t->s, t->len);
    e->namelen = t->len;
    return e;
  }
  fail(tx, t->line, "unexpected '%.*s' in an expression", t->len, t->s);
}

static Expr* parse_postfix(Tx* tx) {
  Expr* e = parse_primary(tx);
  for (;;) {
    Token* t = peek(tx);
    if (tok_is(t, "[")) {
      next(tx);
      Expr* idx = parse_expression(tx);
      expect(tx, "]");
      Expr* n = expr_new(tx, E_INDEX, t->line);
      n->a = e;
      n->b = idx;
      e = n;
    } else if (tok_is(t, ".")) {
      next(tx);
      Token* f = expect_ident(tx);
      Expr* n = expr_new(tx, E_FIELD, t->line);
      n->a = e;
      n->name = intern(tx, f->s, f->len);
      n->namelen = f->len;
      e = n;
    } else if (tok_is(t, "++") || tok_is(t, "--")) {
      next(tx);
      Expr* n = expr_new(tx, E_POSTFIX, t->line);
      n->a = e;
      n->op = intern(tx, t->s, t->len);
      n->oplen = t->len;
      e = n;
    } else {
      return e;
    }
  }
}

static Expr* parse_unary(Tx* tx) {
  Token* t = peek(tx);
  if (tok_is(t, "-") || tok_is(t, "+") || tok_is(t, "!") || tok_is(t, "++") || tok_is(t, "--")) {
    next(tx);
    Expr* e = expr_new(tx, E_UNARY, t->line);
    e->op = intern(tx, t->s, t->len);
    e->oplen = t->len;
    e->a = parse_unary(tx);
    return e;
  }
  if (tok_is(t, "~")) fail(tx, t->line, "operator '~' is not in GLSL ES 1.00");
  return parse_postfix(tx);
}

// Binary operators by precedence, lowest first.
static const char* const kBinaryLevels[][6] = {
    {"||", NULL}, {"^^", NULL}, {"&&", NULL}, {"==", "!=", NULL}, {"<", ">", "<=", ">=", NULL},
    {"+", "-", NULL}, {"*", "/", NULL},
};
enum { kBinaryLevelCount = sizeof kBinaryLevels / sizeof kBinaryLevels[0] };

static Expr* parse_binary(Tx* tx, int level) {
  if (level == kBinaryLevelCount) return parse_unary(tx);
  Expr* left = parse_binary(tx, level + 1);
  for (;;) {
    Token* t = peek(tx);
    bool matched = false;
    for (int i = 0; kBinaryLevels[level][i]; i++) {
      if (tok_is(t, kBinaryLevels[level][i])) {
        matched = true;
        break;
      }
    }
    if (!matched) return left;
    if (tok_is(t, "%")) fail(tx, t->line, "operator '%%' is not in GLSL ES 1.00");
    next(tx);
    Expr* e = expr_new(tx, E_BINARY, t->line);
    e->op = intern(tx, t->s, t->len);
    e->oplen = t->len;
    e->a = left;
    e->b = parse_binary(tx, level + 1);
    left = e;
  }
}

static Expr* parse_ternary(Tx* tx) {
  Expr* c = parse_binary(tx, 0);
  Token* t = peek(tx);
  if (!tok_is(t, "?")) return c;
  next(tx);
  Expr* e = expr_new(tx, E_TERNARY, t->line);
  e->a = c;
  e->b = parse_assignment(tx);
  expect(tx, ":");
  e->c = parse_assignment(tx);
  return e;
}

static Expr* parse_assignment(Tx* tx) {
  Expr* left = parse_ternary(tx);
  Token* t = peek(tx);
  static const char* const ops[] = {"=", "+=", "-=", "*=", "/=", NULL};
  for (int i = 0; ops[i]; i++) {
    if (tok_is(t, ops[i])) {
      next(tx);
      Expr* e = expr_new(tx, E_ASSIGN, t->line);
      e->op = intern(tx, t->s, t->len);
      e->oplen = t->len;
      e->a = left;
      e->b = parse_assignment(tx);
      return e;
    }
  }
  if (tok_is(t, "%=") || tok_is(t, "<<=") || tok_is(t, ">>="))
    fail(tx, t->line, "operator '%.*s' is not in GLSL ES 1.00", t->len, t->s);
  return left;
}

static Expr* parse_expression(Tx* tx) {
  Expr* e = parse_assignment(tx);
  while (tok_is(peek(tx), ",")) fail(tx, peek(tx)->line, "the comma operator is not supported");
  return e;
}

// ---- parser: declarations and statements ----------------------------------

typedef struct Qualifiers {
  bool is_const, is_attribute, is_uniform, is_varying, is_invariant;
} Qualifiers;

static void parse_qualifiers(Tx* tx, Qualifiers* q) {
  memset(q, 0, sizeof *q);
  for (;;) {
    Token* t = peek(tx);
    if (tok_is(t, "const")) q->is_const = true;
    else if (tok_is(t, "attribute")) q->is_attribute = true;
    else if (tok_is(t, "uniform")) q->is_uniform = true;
    else if (tok_is(t, "varying")) q->is_varying = true;
    else if (tok_is(t, "invariant")) q->is_invariant = true;
    else if (tok_is(t, "highp") || tok_is(t, "mediump") || tok_is(t, "lowp")) { /* dropped */ }
    else if (tok_is(t, "in") || tok_is(t, "out") || tok_is(t, "inout"))
      fail(tx, t->line, "'%.*s' qualifier is not in GLSL ES 1.00", t->len, t->s);
    else return;
    next(tx);
  }
}

static int parse_array_size(Tx* tx) {
  if (!accept(tx, "[")) return 0;
  Token* t = peek(tx);
  if (t->kind != TK_INT) fail(tx, t->line, "array size must be an integer literal");
  next(tx);
  const int n = atoi(t->s);
  expect(tx, "]");
  if (n <= 0) fail(tx, t->line, "array size must be positive");
  return n;
}

// type name [ '[' n ']' ] [ '=' init ] { ',' name ... } ';'
static Decl* parse_declarators(Tx* tx, FvglType base, bool is_const, SymKind kind) {
  Decl* head = NULL;
  Decl** tail = &head;
  do {
    Token* name = expect_ident(tx);
    Decl* d = tx_alloc(tx, sizeof *d);
    d->name = intern(tx, name->s, name->len);
    d->namelen = name->len;
    d->type = base;
    d->type.array = parse_array_size(tx);
    d->is_const = is_const;
    if (accept(tx, "=")) d->init = parse_assignment(tx);
    sym_add(tx, d->name, d->namelen, d->type, kind, name->line);
    *tail = d;
    tail = &d->next;
  } while (accept(tx, ","));
  expect(tx, ";");
  return head;
}

static Stmt* stmt_new(Tx* tx, StmtKind kind, int line) {
  Stmt* s = tx_alloc(tx, sizeof *s);
  s->kind = kind;
  s->line = line;
  return s;
}

static Stmt* parse_statement(Tx* tx);

static Stmt* parse_block(Tx* tx) {
  Token* open = expect(tx, "{");
  Stmt* block = stmt_new(tx, S_BLOCK, open->line);
  Stmt* items[512];
  int n = 0;
  scope_push(tx);
  while (!accept(tx, "}")) {
    if (peek(tx)->kind == TK_EOF) fail(tx, open->line, "block is not closed");
    if (n == 512) fail(tx, open->line, "more than 512 statements in one block");
    items[n++] = parse_statement(tx);
  }
  scope_pop(tx);
  block->items = tx_alloc(tx, sizeof(Stmt*) * (size_t)(n ? n : 1));
  memcpy(block->items, items, sizeof(Stmt*) * (size_t)n);
  block->nitems = n;
  return block;
}

// Is the upcoming statement a declaration? Qualifier or type name followed by
// a name says yes; a type name followed by '(' is a constructor call.
static bool starts_declaration(Tx* tx) {
  Token* t = peek(tx);
  if (tok_is(t, "const") || tok_is(t, "highp") || tok_is(t, "mediump") || tok_is(t, "lowp")) return true;
  FvglType tmp;
  if (!type_by_name(t, &tmp)) return false;
  return peek2(tx)->kind == TK_IDENT;
}

static Stmt* parse_declaration_statement(Tx* tx) {
  Token* start = peek(tx);
  Qualifiers q;
  parse_qualifiers(tx, &q);
  if (q.is_attribute || q.is_uniform || q.is_varying)
    fail(tx, start->line, "attribute, uniform and varying belong at file scope");
  FvglType type;
  Token* t = peek(tx);
  if (!type_by_name(t, &type)) fail(tx, t->line, "expected a type, found '%.*s'", t->len, t->s);
  next(tx);
  Stmt* s = stmt_new(tx, S_DECL, start->line);
  s->decls = parse_declarators(tx, type, q.is_const, q.is_const ? SYM_CONST : SYM_LOCAL);
  return s;
}

static Stmt* parse_statement(Tx* tx) {
  Token* t = peek(tx);
  if (tok_is(t, "{")) return parse_block(tx);
  if (accept(tx, ";")) return stmt_new(tx, S_EMPTY, t->line);
  if (tok_is(t, "if")) {
    next(tx);
    Stmt* s = stmt_new(tx, S_IF, t->line);
    expect(tx, "(");
    s->cond = parse_expression(tx);
    expect(tx, ")");
    s->then = parse_statement(tx);
    if (accept(tx, "else")) s->els = parse_statement(tx);
    return s;
  }
  if (tok_is(t, "for")) {
    next(tx);
    Stmt* s = stmt_new(tx, S_FOR, t->line);
    expect(tx, "(");
    scope_push(tx);
    if (starts_declaration(tx)) s->init = parse_declaration_statement(tx);
    else if (accept(tx, ";")) s->init = NULL;
    else {
      s->init = stmt_new(tx, S_EXPR, t->line);
      s->init->expr = parse_expression(tx);
      expect(tx, ";");
    }
    if (!tok_is(peek(tx), ";")) s->cond = parse_expression(tx);
    expect(tx, ";");
    if (!tok_is(peek(tx), ")")) s->step = parse_expression(tx);
    expect(tx, ")");
    s->body = parse_statement(tx);
    scope_pop(tx);
    return s;
  }
  if (tok_is(t, "while")) {
    next(tx);
    Stmt* s = stmt_new(tx, S_WHILE, t->line);
    expect(tx, "(");
    s->cond = parse_expression(tx);
    expect(tx, ")");
    s->body = parse_statement(tx);
    return s;
  }
  if (tok_is(t, "do")) {
    next(tx);
    Stmt* s = stmt_new(tx, S_DO, t->line);
    s->body = parse_statement(tx);
    expect(tx, "while");
    expect(tx, "(");
    s->cond = parse_expression(tx);
    expect(tx, ")");
    expect(tx, ";");
    return s;
  }
  if (tok_is(t, "return")) {
    next(tx);
    Stmt* s = stmt_new(tx, S_RETURN, t->line);
    if (!tok_is(peek(tx), ";")) fail(tx, t->line, "'return' with a value inside main");
    expect(tx, ";");
    return s;
  }
  if (tok_is(t, "discard")) {
    next(tx);
    expect(tx, ";");
    return stmt_new(tx, S_DISCARD, t->line);
  }
  if (tok_is(t, "break")) {
    next(tx);
    expect(tx, ";");
    return stmt_new(tx, S_BREAK, t->line);
  }
  if (tok_is(t, "continue")) {
    next(tx);
    expect(tx, ";");
    return stmt_new(tx, S_CONTINUE, t->line);
  }
  if (tok_is(t, "struct")) fail(tx, t->line, "struct is not supported");
  if (tok_is(t, "precision")) {
    while (!accept(tx, ";")) next(tx);
    return stmt_new(tx, S_EMPTY, t->line);
  }
  if (starts_declaration(tx)) return parse_declaration_statement(tx);
  Stmt* s = stmt_new(tx, S_EXPR, t->line);
  s->expr = parse_expression(tx);
  expect(tx, ";");
  return s;
}

static void add_builtins(Tx* tx) {
  const FvglType v4 = type_make(FVGL_T_FLOAT, 4, 0);
  const FvglType f1 = type_make(FVGL_T_FLOAT, 1, 0);
  if (tx->fragment) {
    sym_add(tx, "gl_FragColor", 12, v4, SYM_BUILTIN, 0);
    sym_add(tx, "gl_FragCoord", 12, v4, SYM_BUILTIN, 0);
  } else {
    sym_add(tx, "gl_Position", 11, v4, SYM_BUILTIN, 0);
    sym_add(tx, "gl_PointSize", 12, f1, SYM_BUILTIN, 0);
  }
}

static void parse_unit(Tx* tx) {
  Decl** gtail = &tx->globals;
  Decl** atail = &tx->attributes;
  Decl** vtail = &tx->varyings;
  while (peek(tx)->kind != TK_EOF) {
    Token* t = peek(tx);
    if (tok_is(t, "precision")) {
      while (!accept(tx, ";")) {
        if (peek(tx)->kind == TK_EOF) fail(tx, t->line, "precision statement is not closed");
        next(tx);
      }
      continue;
    }
    if (tok_is(t, "struct")) fail(tx, t->line, "struct is not supported");
    if (tok_is(t, "invariant") && peek2(tx)->kind == TK_IDENT && !tok_is(peek2(tx), "varying")) {
      // `invariant gl_Position;`
      next(tx);
      next(tx);
      expect(tx, ";");
      continue;
    }
    Qualifiers q;
    parse_qualifiers(tx, &q);
    FvglType type;
    Token* tt = peek(tx);
    if (!type_by_name(tt, &type)) fail(tx, tt->line, "expected a declaration, found '%.*s'", tt->len, tt->s);
    next(tx);
    // Function definition?
    if (peek(tx)->kind == TK_IDENT && tok_is(peek2(tx), "(")) {
      Token* name = next(tx);
      if (!tok_is(name, "main"))
        fail(tx, name->line, "user-defined function '%.*s' is not supported (only main)", name->len, name->s);
      if (type.base != FVGL_T_VOID) fail(tx, name->line, "main must return void");
      expect(tx, "(");
      if (!accept(tx, ")")) {
        accept(tx, "void");
        expect(tx, ")");
      }
      if (tx->main_body) fail(tx, name->line, "main is defined twice");
      tx->main_body = parse_block(tx);
      continue;
    }
    if (q.is_attribute) {
      if (tx->fragment) fail(tx, tt->line, "attribute in a fragment shader");
      Decl* d = parse_declarators(tx, type, false, SYM_ATTRIBUTE);
      for (Decl* i = d; i; i = i->next) {
        if (i->type.array) fail(tx, tt->line, "attribute arrays are not supported");
        if (i->type.rows) fail(tx, tt->line, "matrix attributes are not supported");
      }
      *atail = d;
      while (*atail) atail = &(*atail)->next;
    } else if (q.is_varying) {
      Decl* d = parse_declarators(tx, type, false, SYM_VARYING);
      for (Decl* i = d; i; i = i->next) {
        if (i->type.array) fail(tx, tt->line, "varying arrays are not supported");
        if (i->type.rows) fail(tx, tt->line, "matrix varyings are not supported");
      }
      *vtail = d;
      while (*vtail) vtail = &(*vtail)->next;
    } else if (q.is_uniform) {
      Decl* d = parse_declarators(tx, type, false, SYM_UNIFORM);
      *gtail = d;
      while (*gtail) gtail = &(*gtail)->next;
    } else if (q.is_const) {
      Decl* d = parse_declarators(tx, type, true, SYM_CONST);
      for (Decl* i = d; i; i = i->next) {
        if (!i->init) fail(tx, tt->line, "const '%s' without a value", i->name);
      }
      *gtail = d;
      while (*gtail) gtail = &(*gtail)->next;
    } else {
      fail(tx, tt->line, "global variables without a qualifier are not supported");
    }
  }
  if (!tx->main_body) fail(tx, 0, "no main");
}

// ---- emitter ---------------------------------------------------------------

static FvglType emit_expr(Tx* tx, Expr* e, Buf* out);

// Names that are Cg keywords or Cg built-ins a GLSL program may reuse.
static bool cg_reserved(const char* name) {
  static const char* const k[] = {
      "half", "half2", "half3", "half4", "fixed", "fixed2", "fixed3", "fixed4", "double", "in", "out", "inout",
      "static", "extern", "register", "packed", "uniform", "sampler", "sampler1D", "sampler2D", "sampler3D",
      "samplerCUBE", "samplerRECT", "texture", "matrix", "vector", "string", "technique", "pass", "asm",
      "typedef", "struct", "union", "enum", "class", "template", "this", "operator", "unsigned", "signed",
      "char", "short", "long", "auto", "case", "switch", "default", "goto", "sizeof", "volatile", "interface",
      "lerp", "frac", "saturate", "mul", "tex2D", "tex2Dbias", "tex2Dproj", "texCUBE", "rsqrt", "ddx", "ddy",
      "fmod", "clip", "float1", "int1", "bool1", "float1x1", "main", "fvgl_fc", "fvgl_wpos", "fvgl_mod",
      "gl_FragCoord", "gl_FragColor", "gl_Position", "gl_PointSize", NULL};
  for (int i = 0; k[i]; i++) {
    if (strcmp(name, k[i]) == 0) return true;
  }
  return false;
}

void fvgl_cg_name(const char* glsl_name, char out[FVGL_NAME_MAX]) {
  const bool prefix = !(glsl_name[0] == 'g' && glsl_name[1] == 'l' && glsl_name[2] == '_') && cg_reserved(glsl_name);
  snprintf(out, FVGL_NAME_MAX, "%s%s", prefix ? "fv_" : "", glsl_name);
}

static void emit_name(Tx* tx, Buf* out, const char* name) {
  if (name[0] == 'g' && name[1] == 'l' && name[2] == '_') {
    buf_str(tx, out, name);
    return;
  }
  if (cg_reserved(name)) buf_str(tx, out, "fv_");
  buf_str(tx, out, name);
}

static FvglType emit_number(Tx* tx, Expr* e, Buf* out) {
  buf_str(tx, out, e->name);
  return type_make(e->oplen ? FVGL_T_FLOAT : FVGL_T_INT, 1, 0);
}

static FvglType emit_ident(Tx* tx, Expr* e, Buf* out) {
  Sym* s = sym_find(tx, e->name, e->namelen);
  if (!s) fail(tx, e->line, "'%s' is not declared", e->name);
  if (s->kind == SYM_BUILTIN) {
    if (strcmp(e->name, "gl_FragCoord") == 0) tx->uses_fragcoord = true;
    if (strcmp(e->name, "gl_PointSize") == 0) tx->uses_pointsize = true;
    if (strcmp(e->name, "gl_FragColor") == 0) tx->uses_fragcolor = true;
  }
  if (s->alias) buf_str(tx, out, s->alias);
  else emit_name(tx, out, e->name);
  return s->type;
}

static const char* swizzle_letter(char c) {
  switch (c) {
    case 'x': case 'r': case 's': return "x";
    case 'y': case 'g': case 't': return "y";
    case 'z': case 'b': case 'p': return "z";
    case 'w': case 'a': case 'q': return "w";
    default: return NULL;
  }
}

static FvglType emit_field(Tx* tx, Expr* e, Buf* out) {
  Buf inner = {0};
  FvglType t = emit_expr(tx, e->a, &inner);
  if (!type_is_vector(t) && !type_is_scalar(t))
    fail(tx, e->line, "'.%s' on something that is not a vector", e->name);
  if (e->namelen < 1 || e->namelen > 4) fail(tx, e->line, "bad swizzle '.%s'", e->name);
  char sw[5] = {0};
  for (int i = 0; i < e->namelen; i++) {
    const char* l = swizzle_letter(e->name[i]);
    if (!l) fail(tx, e->line, "bad swizzle '.%s'", e->name);
    const int idx = l[0] - 'x';
    if (idx >= t.cols) fail(tx, e->line, "swizzle '.%s' reaches past a %d-component vector", e->name, t.cols);
    sw[i] = l[0];
  }
  // A swizzle on a scalar or a compound expression needs parentheses in Cg.
  const bool simple = e->a->kind == E_IDENT || e->a->kind == E_INDEX || e->a->kind == E_FIELD || e->a->kind == E_CALL;
  if (!simple) buf_str(tx, out, "(");
  buf_put(tx, out, inner.s, inner.len);
  if (!simple) buf_str(tx, out, ")");
  buf_fmt(tx, out, ".%s", sw);
  free(inner.s);
  FvglType r = t;
  r.cols = (unsigned char)e->namelen;
  r.rows = 0;
  return r;
}

static FvglType emit_index(Tx* tx, Expr* e, Buf* out) {
  Buf a = {0}, b = {0};
  FvglType ta = emit_expr(tx, e->a, &a);
  FvglType tb = emit_expr(tx, e->b, &b);
  if (tb.base != FVGL_T_INT || !type_is_scalar(tb)) fail(tx, e->line, "index is not an int");
  buf_put(tx, out, a.s, a.len);
  buf_str(tx, out, "[");
  buf_put(tx, out, b.s, b.len);
  buf_str(tx, out, "]");
  free(a.s);
  free(b.s);
  FvglType r = ta;
  if (ta.array) {
    r.array = 0;
  } else if (type_is_matrix(ta)) {
    r.rows = 0;  // a column of the GLSL matrix, a row of ours: same numbers
  } else if (type_is_vector(ta)) {
    r.cols = 1;
  } else {
    fail(tx, e->line, "index on something that is not an array, matrix or vector");
  }
  return r;
}

// The widest type among arguments, for gen-type built-ins.
static FvglType widest(FvglType* ts, int n) {
  FvglType w = ts[0];
  for (int i = 1; i < n; i++) {
    if (fvgl_type_components(ts[i]) > fvgl_type_components(w)) w = ts[i];
  }
  return w;
}

typedef enum Ret { R_GEN, R_FLOAT, R_BOOL, R_BVEC, R_VEC4, R_ARG0, R_VEC3 } Ret;

static const struct Builtin {
  const char* glsl;
  const char* cg;
  int min_args, max_args;
  Ret ret;
} kBuiltins[] = {
    {"radians", "radians", 1, 1, R_GEN},       {"degrees", "degrees", 1, 1, R_GEN},
    {"sin", "sin", 1, 1, R_GEN},               {"cos", "cos", 1, 1, R_GEN},
    {"tan", "tan", 1, 1, R_GEN},               {"asin", "asin", 1, 1, R_GEN},
    {"acos", "acos", 1, 1, R_GEN},             {"atan", NULL, 1, 2, R_GEN},
    {"pow", "pow", 2, 2, R_GEN},               {"exp", "exp", 1, 1, R_GEN},
    {"log", "log", 1, 1, R_GEN},               {"exp2", "exp2", 1, 1, R_GEN},
    {"log2", "log2", 1, 1, R_GEN},             {"sqrt", "sqrt", 1, 1, R_GEN},
    {"inversesqrt", "rsqrt", 1, 1, R_GEN},     {"abs", "abs", 1, 1, R_GEN},
    {"sign", "sign", 1, 1, R_GEN},             {"floor", "floor", 1, 1, R_GEN},
    {"ceil", "ceil", 1, 1, R_GEN},             {"fract", "frac", 1, 1, R_GEN},
    {"mod", "fvgl_mod", 2, 2, R_GEN},          {"min", "min", 2, 2, R_GEN},
    {"max", "max", 2, 2, R_GEN},               {"clamp", "clamp", 3, 3, R_GEN},
    {"mix", "lerp", 3, 3, R_GEN},              {"step", "step", 2, 2, R_GEN},
    {"smoothstep", "smoothstep", 3, 3, R_GEN}, {"length", "length", 1, 1, R_FLOAT},
    {"distance", "distance", 2, 2, R_FLOAT},   {"dot", "dot", 2, 2, R_FLOAT},
    {"cross", "cross", 2, 2, R_VEC3},          {"normalize", "normalize", 1, 1, R_ARG0},
    {"faceforward", "faceforward", 3, 3, R_ARG0}, {"reflect", "reflect", 2, 2, R_ARG0},
    {"refract", "refract", 3, 3, R_ARG0},      {"matrixCompMult", NULL, 2, 2, R_ARG0},
    {"lessThan", "<", 2, 2, R_BVEC},           {"lessThanEqual", "<=", 2, 2, R_BVEC},
    {"greaterThan", ">", 2, 2, R_BVEC},        {"greaterThanEqual", ">=", 2, 2, R_BVEC},
    {"equal", "==", 2, 2, R_BVEC},             {"notEqual", "!=", 2, 2, R_BVEC},
    {"any", "any", 1, 1, R_BOOL},              {"all", "all", 1, 1, R_BOOL},
    {"not", "!", 1, 1, R_BVEC},                {"texture2D", NULL, 2, 3, R_VEC4},
    {"texture2DProj", NULL, 2, 2, R_VEC4},     {"textureCube", "texCUBE", 2, 2, R_VEC4},
    {"dFdx", "ddx", 1, 1, R_GEN},              {"dFdy", "ddy", 1, 1, R_GEN},
    {"fwidth", "fwidth", 1, 1, R_GEN},
};

static FvglType emit_call(Tx* tx, Expr* e, Buf* out) {
  // Arguments first, so their types are known.
  Buf args[32];
  FvglType types[32];
  memset(args, 0, sizeof args);
  for (int i = 0; i < e->nargs; i++) types[i] = emit_expr(tx, e->args[i], &args[i]);

  FvglType ctor;
  Token fake = {TK_IDENT, e->name, e->namelen, e->line};
  if (type_by_name(&fake, &ctor)) {
    // A constructor.
    if (ctor.base == FVGL_T_VOID || ctor.base == FVGL_T_SAMPLER2D || ctor.base == FVGL_T_SAMPLERCUBE)
      fail(tx, e->line, "'%s' cannot be constructed", e->name);
    if (e->nargs == 0) fail(tx, e->line, "constructor '%s' with no arguments", e->name);
    const char* cgname = cg_type_name(tx, ctor, e->line);
    if (e->nargs == 1) {
      const FvglType a = types[0];
      if (type_same(a, ctor)) {
        buf_str(tx, out, "(");
        buf_put(tx, out, args[0].s, args[0].len);
        buf_str(tx, out, ")");
      } else if (type_is_scalar(ctor)) {
        // float(x), int(x), bool(x): a cast, from a scalar or a vector's first component.
        buf_fmt(tx, out, "((%s)(", cgname);
        buf_put(tx, out, args[0].s, args[0].len);
        buf_str(tx, out, type_is_scalar(a) ? "))" : ").x)");
      } else if (type_is_vector(ctor) && type_is_scalar(a)) {
        // Splat. A literal is repeated; anything else is swizzled once.
        if (e->args[0]->kind == E_NUM) {
          buf_fmt(tx, out, "%s(", cgname);
          for (int i = 0; i < ctor.cols; i++) buf_fmt(tx, out, "%s%s", i ? ", " : "", args[0].s);
          buf_str(tx, out, ")");
        } else {
          static const char* const sw[] = {"", "x", "xx", "xxx", "xxxx"};
          const char* elem = cg_type_name(tx, type_make(ctor.base, 1, 0), e->line);
          buf_fmt(tx, out, "((%s)(", elem);
          buf_put(tx, out, args[0].s, args[0].len);
          buf_fmt(tx, out, ")).%s", sw[ctor.cols]);
        }
      } else if (type_is_vector(ctor) && type_is_vector(a) && a.cols >= ctor.cols) {
        // Truncation, and a base change if there is one.
        static const char* const sw[] = {"", "x", "xy", "xyz", "xyzw"};
        if (a.base != ctor.base) buf_fmt(tx, out, "((%s)(", cgname);
        else buf_str(tx, out, "(");
        buf_put(tx, out, args[0].s, args[0].len);
        buf_fmt(tx, out, ").%s%s", a.cols > ctor.cols ? sw[ctor.cols] : "", a.base != ctor.base ? ")" : "");
      } else if (type_is_matrix(ctor) && type_is_scalar(a)) {
        // mat3(s): s on the diagonal.
        buf_fmt(tx, out, "%s(", cgname);
        for (int r = 0; r < ctor.rows; r++) {
          for (int c = 0; c < ctor.cols; c++) {
            if (r || c) buf_str(tx, out, ", ");
            if (r == c) buf_put(tx, out, args[0].s, args[0].len);
            else buf_str(tx, out, "0.0");
          }
        }
        buf_str(tx, out, ")");
      } else if (type_is_matrix(ctor) && type_is_matrix(a)) {
        if (a.cols < ctor.cols) fail(tx, e->line, "%s from a smaller matrix is not supported", e->name);
        buf_fmt(tx, out, "((%s)(", cgname);
        buf_put(tx, out, args[0].s, args[0].len);
        buf_str(tx, out, "))");
      } else {
        fail(tx, e->line, "constructor %s from that argument type is not supported", e->name);
      }
    } else {
      int have = 0;
      for (int i = 0; i < e->nargs; i++) {
        if (types[i].array || types[i].base == FVGL_T_SAMPLER2D) fail(tx, e->line, "bad argument to %s", e->name);
        have += fvgl_type_components(types[i]);
      }
      const int need = fvgl_type_components(ctor);
      if (have < need) fail(tx, e->line, "%s needs %d components, got %d", e->name, need, have);
      buf_fmt(tx, out, "%s(", cgname);
      for (int i = 0; i < e->nargs; i++) {
        if (i) buf_str(tx, out, ", ");
        // Cg wants matching element types inside a constructor.
        if (types[i].base != ctor.base) {
          FvglType want = types[i];
          want.base = ctor.base;
          buf_fmt(tx, out, "((%s)(", cg_type_name(tx, want, e->line));
          buf_put(tx, out, args[i].s, args[i].len);
          buf_str(tx, out, "))");
        } else {
          buf_put(tx, out, args[i].s, args[i].len);
        }
      }
      buf_str(tx, out, ")");
    }
    for (int i = 0; i < e->nargs; i++) free(args[i].s);
    return ctor;
  }

  const struct Builtin* b = NULL;
  for (size_t i = 0; i < sizeof kBuiltins / sizeof kBuiltins[0]; i++) {
    if (strcmp(kBuiltins[i].glsl, e->name) == 0) {
      b = &kBuiltins[i];
      break;
    }
  }
  if (!b) {
    if (sym_find(tx, e->name, e->namelen)) fail(tx, e->line, "'%s' is a variable, not a function", e->name);
    fail(tx, e->line, "function '%s' is not a GLSL ES 1.00 built-in (user functions are not supported)", e->name);
  }
  if (e->nargs < b->min_args || e->nargs > b->max_args)
    fail(tx, e->line, "%s takes %d to %d arguments, got %d", b->glsl, b->min_args, b->max_args, e->nargs);

  FvglType ret;
  switch (b->ret) {
    case R_GEN: ret = widest(types, e->nargs); break;
    case R_FLOAT: ret = type_make(FVGL_T_FLOAT, 1, 0); break;
    case R_BOOL: ret = type_make(FVGL_T_BOOL, 1, 0); break;
    case R_BVEC: ret = type_make(FVGL_T_BOOL, types[0].cols, 0); break;
    case R_VEC4: ret = type_make(FVGL_T_FLOAT, 4, 0); break;
    case R_VEC3: ret = type_make(FVGL_T_FLOAT, 3, 0); break;
    default: ret = types[0]; break;
  }

  if (strcmp(b->glsl, "texture2D") == 0) {
    if (types[0].base != FVGL_T_SAMPLER2D) fail(tx, e->line, "texture2D on something that is not a sampler2D");
    if (e->nargs == 3) {
      buf_str(tx, out, "tex2Dbias(");
      buf_put(tx, out, args[0].s, args[0].len);
      buf_str(tx, out, ", float4(");
      buf_put(tx, out, args[1].s, args[1].len);
      buf_str(tx, out, ", 0.0, ");
      buf_put(tx, out, args[2].s, args[2].len);
      buf_str(tx, out, "))");
    } else {
      buf_str(tx, out, "tex2D(");
      buf_put(tx, out, args[0].s, args[0].len);
      buf_str(tx, out, ", ");
      buf_put(tx, out, args[1].s, args[1].len);
      buf_str(tx, out, ")");
    }
  } else if (strcmp(b->glsl, "texture2DProj") == 0) {
    buf_str(tx, out, "tex2Dproj(");
    buf_put(tx, out, args[0].s, args[0].len);
    buf_str(tx, out, ", ");
    buf_put(tx, out, args[1].s, args[1].len);
    buf_str(tx, out, ")");
  } else if (strcmp(b->glsl, "atan") == 0) {
    buf_str(tx, out, e->nargs == 2 ? "atan2(" : "atan(");
    for (int i = 0; i < e->nargs; i++) {
      if (i) buf_str(tx, out, ", ");
      buf_put(tx, out, args[i].s, args[i].len);
    }
    buf_str(tx, out, ")");
  } else if (strcmp(b->glsl, "matrixCompMult") == 0) {
    buf_str(tx, out, "(");
    buf_put(tx, out, args[0].s, args[0].len);
    buf_str(tx, out, " * ");
    buf_put(tx, out, args[1].s, args[1].len);
    buf_str(tx, out, ")");
  } else if (b->ret == R_BVEC && strcmp(b->glsl, "not") != 0) {
    buf_str(tx, out, "(");
    buf_put(tx, out, args[0].s, args[0].len);
    buf_fmt(tx, out, " %s ", b->cg);
    buf_put(tx, out, args[1].s, args[1].len);
    buf_str(tx, out, ")");
  } else if (strcmp(b->glsl, "not") == 0) {
    buf_str(tx, out, "(!(");
    buf_put(tx, out, args[0].s, args[0].len);
    buf_str(tx, out, "))");
  } else {
    buf_fmt(tx, out, "%s(", b->cg);
    for (int i = 0; i < e->nargs; i++) {
      if (i) buf_str(tx, out, ", ");
      buf_put(tx, out, args[i].s, args[i].len);
    }
    buf_str(tx, out, ")");
  }
  for (int i = 0; i < e->nargs; i++) free(args[i].s);
  return ret;
}

// The type of `a op b` for arithmetic, and whether it is a matrix product.
static FvglType arith_type(Tx* tx, int line, const char* op, FvglType a, FvglType b, bool* matrix_product) {
  *matrix_product = false;
  if (a.array || b.array) fail(tx, line, "arithmetic on a whole array");
  if (a.base == FVGL_T_SAMPLER2D || b.base == FVGL_T_SAMPLER2D) fail(tx, line, "arithmetic on a sampler");
  if (op[0] == '*') {
    if (type_is_matrix(a) && type_is_vector(b)) {
      if (a.cols != b.cols) fail(tx, line, "matrix * vector of different sizes");
      *matrix_product = true;
      return b;
    }
    if (type_is_vector(a) && type_is_matrix(b)) {
      if (a.cols != b.cols) fail(tx, line, "vector * matrix of different sizes");
      *matrix_product = true;
      return a;
    }
    if (type_is_matrix(a) && type_is_matrix(b)) {
      if (a.cols != b.cols) fail(tx, line, "matrix * matrix of different sizes");
      *matrix_product = true;
      return a;
    }
  }
  if (type_is_scalar(a)) return type_is_scalar(b) ? (a.base == FVGL_T_FLOAT ? a : b) : b;
  if (type_is_scalar(b)) return a;
  if (fvgl_type_components(a) != fvgl_type_components(b) || type_is_matrix(a) != type_is_matrix(b))
    fail(tx, line, "operator '%s' between different sizes", op);
  return a;
}

static FvglType emit_binary(Tx* tx, Expr* e, Buf* out) {
  Buf a = {0}, b = {0};
  const FvglType ta = emit_expr(tx, e->a, &a);
  const FvglType tb = emit_expr(tx, e->b, &b);
  const char* op = e->op;
  FvglType r;
  if (strcmp(op, "&&") == 0 || strcmp(op, "||") == 0 || strcmp(op, "^^") == 0) {
    if (!type_is_scalar(ta) || !type_is_scalar(tb) || ta.base != FVGL_T_BOOL || tb.base != FVGL_T_BOOL)
      fail(tx, e->line, "'%s' needs two bools", op);
    r = type_make(FVGL_T_BOOL, 1, 0);
    if (strcmp(op, "^^") == 0) op = "!=";
    buf_str(tx, out, "(");
    buf_put(tx, out, a.s, a.len);
    buf_fmt(tx, out, " %s ", op);
    buf_put(tx, out, b.s, b.len);
    buf_str(tx, out, ")");
  } else if (strcmp(op, "==") == 0 || strcmp(op, "!=") == 0) {
    r = type_make(FVGL_T_BOOL, 1, 0);
    if (!type_same(ta, tb) && !(type_is_scalar(ta) && type_is_scalar(tb)))
      fail(tx, e->line, "'%s' between different types", op);
    if (type_is_scalar(ta)) {
      buf_str(tx, out, "(");
      buf_put(tx, out, a.s, a.len);
      buf_fmt(tx, out, " %s ", op);
      buf_put(tx, out, b.s, b.len);
      buf_str(tx, out, ")");
    } else {
      // Whole-value equality: Cg compares per component.
      buf_str(tx, out, op[0] == '=' ? "all(" : "any(");
      buf_put(tx, out, a.s, a.len);
      buf_fmt(tx, out, " %s ", op);
      buf_put(tx, out, b.s, b.len);
      buf_str(tx, out, ")");
    }
  } else if (op[0] == '<' || op[0] == '>') {
    if (!type_is_scalar(ta) || !type_is_scalar(tb)) fail(tx, e->line, "'%s' on vectors; use lessThan and friends", op);
    r = type_make(FVGL_T_BOOL, 1, 0);
    buf_str(tx, out, "(");
    buf_put(tx, out, a.s, a.len);
    buf_fmt(tx, out, " %s ", op);
    buf_put(tx, out, b.s, b.len);
    buf_str(tx, out, ")");
  } else {
    bool mp;
    r = arith_type(tx, e->line, op, ta, tb, &mp);
    if (mp) {
      // GLSL applies the left matrix to the right operand; with GLSL columns
      // stored as Cg rows that is mul(right, left).
      buf_str(tx, out, "mul(");
      buf_put(tx, out, b.s, b.len);
      buf_str(tx, out, ", ");
      buf_put(tx, out, a.s, a.len);
      buf_str(tx, out, ")");
    } else {
      buf_str(tx, out, "(");
      buf_put(tx, out, a.s, a.len);
      buf_fmt(tx, out, " %s ", op);
      buf_put(tx, out, b.s, b.len);
      buf_str(tx, out, ")");
    }
  }
  free(a.s);
  free(b.s);
  return r;
}

static void check_lvalue(Tx* tx, Expr* e) {
  Expr* base = e;
  while (base->kind == E_FIELD || base->kind == E_INDEX) base = base->a;
  if (base->kind != E_IDENT) fail(tx, e->line, "assignment to something that is not a variable");
  Sym* s = sym_find(tx, base->name, base->namelen);
  if (!s) fail(tx, e->line, "'%s' is not declared", base->name);
  if (s->kind == SYM_UNIFORM || s->kind == SYM_ATTRIBUTE || s->kind == SYM_CONST)
    fail(tx, e->line, "assignment to %s '%s'", s->kind == SYM_UNIFORM ? "uniform" : s->kind == SYM_ATTRIBUTE ? "attribute" : "const", base->name);
  if (tx->fragment && s->kind == SYM_VARYING) fail(tx, e->line, "assignment to varying '%s' in a fragment shader", base->name);
  if (s->kind == SYM_BUILTIN && strcmp(base->name, "gl_FragCoord") == 0) fail(tx, e->line, "assignment to gl_FragCoord");
}

static FvglType emit_assign(Tx* tx, Expr* e, Buf* out) {
  check_lvalue(tx, e->a);
  Buf a = {0}, b = {0};
  const FvglType ta = emit_expr(tx, e->a, &a);
  const FvglType tb = emit_expr(tx, e->b, &b);
  if (strcmp(e->op, "=") == 0) {
    if (!type_same(ta, tb) && !(type_is_scalar(ta) && type_is_scalar(tb)) &&
        !(fvgl_type_components(ta) == fvgl_type_components(tb) && ta.rows == tb.rows))
      fail(tx, e->line, "assignment of a %d-component value to a %d-component variable",
           fvgl_type_components(tb), fvgl_type_components(ta));
    buf_put(tx, out, a.s, a.len);
    buf_str(tx, out, " = ");
    buf_put(tx, out, b.s, b.len);
  } else {
    char op[2] = {e->op[0], 0};
    bool mp;
    arith_type(tx, e->line, op, ta, tb, &mp);
    if (mp) {
      buf_put(tx, out, a.s, a.len);
      buf_str(tx, out, " = mul(");
      buf_put(tx, out, b.s, b.len);
      buf_str(tx, out, ", ");
      buf_put(tx, out, a.s, a.len);
      buf_str(tx, out, ")");
    } else {
      buf_put(tx, out, a.s, a.len);
      buf_fmt(tx, out, " %s ", e->op);
      buf_put(tx, out, b.s, b.len);
    }
  }
  free(a.s);
  free(b.s);
  return ta;
}

static FvglType emit_expr(Tx* tx, Expr* e, Buf* out) {
  switch (e->kind) {
    case E_NUM: return emit_number(tx, e, out);
    case E_BOOL:
      buf_str(tx, out, e->name);
      return type_make(FVGL_T_BOOL, 1, 0);
    case E_IDENT: return emit_ident(tx, e, out);
    case E_FIELD: return emit_field(tx, e, out);
    case E_INDEX: return emit_index(tx, e, out);
    case E_CALL: return emit_call(tx, e, out);
    case E_BINARY: return emit_binary(tx, e, out);
    case E_ASSIGN: return emit_assign(tx, e, out);
    case E_UNARY: {
      if (e->op[0] == '+' && e->oplen == 2) check_lvalue(tx, e->a);
      if (e->op[0] == '-' && e->oplen == 2) check_lvalue(tx, e->a);
      Buf a = {0};
      const FvglType t = emit_expr(tx, e->a, &a);
      if (e->op[0] == '!' && t.base != FVGL_T_BOOL) fail(tx, e->line, "'!' on something that is not a bool");
      buf_fmt(tx, out, "(%s", e->op);
      buf_put(tx, out, a.s, a.len);
      buf_str(tx, out, ")");
      free(a.s);
      return t;
    }
    case E_POSTFIX: {
      check_lvalue(tx, e->a);
      Buf a = {0};
      const FvglType t = emit_expr(tx, e->a, &a);
      buf_str(tx, out, "(");
      buf_put(tx, out, a.s, a.len);
      buf_fmt(tx, out, "%s)", e->op);
      free(a.s);
      return t;
    }
    case E_TERNARY: {
      Buf a = {0}, b = {0}, c = {0};
      const FvglType ta = emit_expr(tx, e->a, &a);
      const FvglType tb = emit_expr(tx, e->b, &b);
      const FvglType tc = emit_expr(tx, e->c, &c);
      if (!type_is_scalar(ta) || ta.base != FVGL_T_BOOL) fail(tx, e->line, "'?:' condition is not a bool");
      if (!type_same(tb, tc)) fail(tx, e->line, "'?:' branches have different types");
      buf_str(tx, out, "(");
      buf_put(tx, out, a.s, a.len);
      buf_str(tx, out, " ? ");
      buf_put(tx, out, b.s, b.len);
      buf_str(tx, out, " : ");
      buf_put(tx, out, c.s, c.len);
      buf_str(tx, out, ")");
      free(a.s);
      free(b.s);
      free(c.s);
      return tb;
    }
  }
  fail(tx, e->line, "unknown expression");
}

static void indent(Tx* tx, Buf* out, int depth) {
  for (int i = 0; i < depth; i++) buf_str(tx, out, "  ");
}

static void emit_decl_list(Tx* tx, Decl* d, Buf* out, bool global, const char* alias) {
  for (; d; d = d->next) {
    // The initializer first: it is evaluated before the name comes into scope.
    Buf v = {0};
    if (d->init) {
      const FvglType t = emit_expr(tx, d->init, &v);
      if (!type_same(t, d->type) && !(type_is_scalar(t) && type_is_scalar(d->type)))
        fail(tx, 0, "initializer of '%s' has a different type", d->name);
    }
    if (d->is_const) buf_str(tx, out, global ? "static const " : "const ");
    buf_fmt(tx, out, "%s ", cg_type_name(tx, d->type, 0));
    if (alias) buf_str(tx, out, alias);
    else emit_name(tx, out, d->name);
    if (d->type.array) buf_fmt(tx, out, "[%d]", d->type.array);
    if (d->init) {
      buf_str(tx, out, " = ");
      buf_put(tx, out, v.s, v.len);
    }
    free(v.s);
    buf_str(tx, out, ";\n");
  }
}

static void emit_stmt(Tx* tx, Stmt* s, Buf* out, int depth);

static void emit_body(Tx* tx, Stmt* s, Buf* out, int depth) {
  if (s->kind == S_BLOCK) {
    buf_str(tx, out, " {\n");
    scope_push(tx);
    for (int i = 0; i < s->nitems; i++) emit_stmt(tx, s->items[i], out, depth + 1);
    scope_pop(tx);
    indent(tx, out, depth);
    buf_str(tx, out, "}");
  } else {
    buf_str(tx, out, "\n");
    emit_stmt(tx, s, out, depth + 1);
    // emit_stmt ends its line; the caller adds nothing.
  }
}

// A local may shadow an attribute, a varying or a built-in in GLSL, where
// main's body is a scope of its own. In Cg those are main's parameters and
// live in the same scope as the body, so such a local is spelled differently.
// The GLSL name stays what the program is asked about; only the text changes.
static const char* shadow_alias(Tx* tx, const Decl* d) {
  Sym* outer = sym_find(tx, d->name, d->namelen);
  if (!outer || outer->scope != 0) return NULL;
  if (outer->kind != SYM_ATTRIBUTE && outer->kind != SYM_VARYING && outer->kind != SYM_BUILTIN) return NULL;
  char* alias = tx_alloc(tx, (size_t)d->namelen + 8);
  snprintf(alias, (size_t)d->namelen + 8, "%s_l%d", d->name, tx->scope);
  return alias;
}

static void redeclare(Tx* tx, Decl* d, const char* alias) {
  for (; d; d = d->next) {
    sym_add(tx, d->name, d->namelen, d->type, d->is_const ? SYM_CONST : SYM_LOCAL, 0);
    tx->syms[tx->nsyms - 1].alias = alias;
  }
}

static void emit_stmt(Tx* tx, Stmt* s, Buf* out, int depth) {
  switch (s->kind) {
    case S_BLOCK:
      indent(tx, out, depth);
      buf_str(tx, out, "{\n");
      scope_push(tx);
      for (int i = 0; i < s->nitems; i++) emit_stmt(tx, s->items[i], out, depth + 1);
      scope_pop(tx);
      indent(tx, out, depth);
      buf_str(tx, out, "}\n");
      return;
    case S_DECL:
      // Declared as it is emitted, so later statements see it; the parse pass
      // already checked for duplicates. One line per name.
      for (Decl* d = s->decls; d; d = d->next) {
        Decl one = *d;
        one.next = NULL;
        const char* alias = shadow_alias(tx, d);
        indent(tx, out, depth);
        emit_decl_list(tx, &one, out, false, alias);
        redeclare(tx, &one, alias);
      }
      return;
    case S_EXPR: {
      Buf v = {0};
      emit_expr(tx, s->expr, &v);
      indent(tx, out, depth);
      buf_put(tx, out, v.s, v.len);
      buf_str(tx, out, ";\n");
      free(v.s);
      return;
    }
    case S_IF: {
      Buf c = {0};
      const FvglType t = emit_expr(tx, s->cond, &c);
      if (!type_is_scalar(t) || t.base != FVGL_T_BOOL) fail(tx, s->line, "if condition is not a bool");
      indent(tx, out, depth);
      buf_str(tx, out, "if (");
      buf_put(tx, out, c.s, c.len);
      buf_str(tx, out, ")");
      free(c.s);
      emit_body(tx, s->then, out, depth);
      if (s->els) {
        if (s->then->kind == S_BLOCK) buf_str(tx, out, " else");
        else {
          indent(tx, out, depth);
          buf_str(tx, out, "else");
        }
        if (s->els->kind == S_IF) {
          buf_str(tx, out, " ");
          Buf tmp = {0};
          emit_stmt(tx, s->els, &tmp, depth);
          // Drop the indentation emit_stmt put in front of the nested if.
          size_t skip = 0;
          while (skip < tmp.len && tmp.s[skip] == ' ') skip++;
          buf_put(tx, out, tmp.s + skip, tmp.len - skip);
          free(tmp.s);
          return;
        }
        emit_body(tx, s->els, out, depth);
      }
      buf_str(tx, out, "\n");
      return;
    }
    case S_FOR: {
      scope_push(tx);
      indent(tx, out, depth);
      buf_str(tx, out, "for (");
      if (s->init && s->init->kind == S_DECL) {
        Buf tmp = {0};
        emit_stmt(tx, s->init, &tmp, 0);
        // one declaration, without its newline
        size_t n = tmp.len;
        while (n && (tmp.s[n - 1] == '\n' || tmp.s[n - 1] == ';')) n--;
        buf_put(tx, out, tmp.s, n);
        free(tmp.s);
      } else if (s->init) {
        Buf tmp = {0};
        emit_expr(tx, s->init->expr, &tmp);
        buf_put(tx, out, tmp.s, tmp.len);
        free(tmp.s);
      }
      buf_str(tx, out, "; ");
      if (s->cond) {
        Buf tmp = {0};
        const FvglType t = emit_expr(tx, s->cond, &tmp);
        if (!type_is_scalar(t) || t.base != FVGL_T_BOOL) fail(tx, s->line, "for condition is not a bool");
        buf_put(tx, out, tmp.s, tmp.len);
        free(tmp.s);
      }
      buf_str(tx, out, "; ");
      if (s->step) {
        Buf tmp = {0};
        emit_expr(tx, s->step, &tmp);
        buf_put(tx, out, tmp.s, tmp.len);
        free(tmp.s);
      }
      buf_str(tx, out, ")");
      emit_body(tx, s->body, out, depth);
      buf_str(tx, out, "\n");
      scope_pop(tx);
      return;
    }
    case S_WHILE: {
      Buf c = {0};
      const FvglType t = emit_expr(tx, s->cond, &c);
      if (!type_is_scalar(t) || t.base != FVGL_T_BOOL) fail(tx, s->line, "while condition is not a bool");
      indent(tx, out, depth);
      buf_str(tx, out, "while (");
      buf_put(tx, out, c.s, c.len);
      buf_str(tx, out, ")");
      free(c.s);
      emit_body(tx, s->body, out, depth);
      buf_str(tx, out, "\n");
      return;
    }
    case S_DO: {
      indent(tx, out, depth);
      buf_str(tx, out, "do");
      emit_body(tx, s->body, out, depth);
      Buf c = {0};
      const FvglType t = emit_expr(tx, s->cond, &c);
      if (!type_is_scalar(t) || t.base != FVGL_T_BOOL) fail(tx, s->line, "do-while condition is not a bool");
      buf_str(tx, out, " while (");
      buf_put(tx, out, c.s, c.len);
      buf_str(tx, out, ");\n");
      free(c.s);
      return;
    }
    case S_RETURN:
      indent(tx, out, depth);
      buf_str(tx, out, tx->fragment ? "return gl_FragColor;\n" : "return;\n");
      return;
    case S_DISCARD:
      if (!tx->fragment) fail(tx, s->line, "discard in a vertex shader");
      indent(tx, out, depth);
      buf_str(tx, out, "discard;\n");
      return;
    case S_BREAK:
      indent(tx, out, depth);
      buf_str(tx, out, "break;\n");
      return;
    case S_CONTINUE:
      indent(tx, out, depth);
      buf_str(tx, out, "continue;\n");
      return;
    case S_EMPTY:
      return;
  }
}

static int varying_index(Tx* tx, const char* name) {
  if (!tx->map) return -1;
  for (int i = 0; i < tx->map->count; i++) {
    if (strcmp(tx->map->names[i], name) == 0) return i;
  }
  fail(tx, 0, "varying '%s' has no TEXCOORD assigned", name);
}

static const char kPrelude[] =
    "// Generated by fvita_gles2 from GLSL ES 1.00.\n"
    "float fvgl_mod(float x, float y) { return x - y * floor(x / y); }\n"
    "float2 fvgl_mod(float2 x, float2 y) { return x - y * floor(x / y); }\n"
    "float3 fvgl_mod(float3 x, float3 y) { return x - y * floor(x / y); }\n"
    "float4 fvgl_mod(float4 x, float4 y) { return x - y * floor(x / y); }\n"
    "float2 fvgl_mod(float2 x, float y) { return x - y * floor(x / y); }\n"
    "float3 fvgl_mod(float3 x, float y) { return x - y * floor(x / y); }\n"
    "float4 fvgl_mod(float4 x, float y) { return x - y * floor(x / y); }\n";

static void emit_unit(Tx* tx, Buf* out) {
  // The body first, into its own buffer: it tells us which built-ins are used.
  Buf body = {0};
  scope_push(tx);
  for (int i = 0; i < tx->main_body->nitems; i++) emit_stmt(tx, tx->main_body->items[i], &body, 1);
  scope_pop(tx);

  buf_str(tx, out, kPrelude);
  if (tx->uses_fragcoord) buf_str(tx, out, "uniform float2 fvgl_fc;\n");
  for (Decl* d = tx->globals; d; d = d->next) {
    if (!d->is_const) buf_str(tx, out, "uniform ");
    Decl one = *d;
    one.next = NULL;
    emit_decl_list(tx, &one, out, true, NULL);
  }

  // main's parameter list.
  buf_str(tx, out, tx->fragment ? "\nfloat4 main(" : "\nvoid main(");
  bool first = true;
  if (!tx->fragment) {
    for (Decl* d = tx->attributes; d; d = d->next) {
      buf_fmt(tx, out, "%s\n    %s ", first ? "" : ",", cg_type_name(tx, d->type, 0));
      emit_name(tx, out, d->name);
      first = false;
    }
  }
  for (Decl* d = tx->varyings; d; d = d->next) {
    const int idx = varying_index(tx, d->name);
    buf_fmt(tx, out, "%s\n    %s%s ", first ? "" : ",", tx->fragment ? "" : "out ", cg_type_name(tx, d->type, 0));
    emit_name(tx, out, d->name);
    buf_fmt(tx, out, " : TEXCOORD%d", idx);
    first = false;
  }
  if (tx->fragment) {
    if (tx->uses_fragcoord) {
      buf_fmt(tx, out, "%s\n    float4 fvgl_wpos : WPOS", first ? "" : ",");
      first = false;
    }
    buf_str(tx, out, ") : COLOR {\n");
    buf_str(tx, out, "  float4 gl_FragColor = float4(0.0, 0.0, 0.0, 0.0);\n");
    if (tx->uses_fragcoord)
      buf_str(tx, out, "  float4 gl_FragCoord = float4(fvgl_wpos.x, fvgl_fc.x + fvgl_fc.y * fvgl_wpos.y, fvgl_wpos.z, fvgl_wpos.w);\n");
  } else {
    buf_fmt(tx, out, "%s\n    out float4 gl_Position : POSITION", first ? "" : ",");
    if (tx->uses_pointsize) buf_str(tx, out, ",\n    out float gl_PointSize : PSIZE");
    buf_str(tx, out, ") {\n");
  }
  buf_put(tx, out, body.s, body.len);
  if (tx->fragment) buf_str(tx, out, "  return gl_FragColor;\n");
  buf_str(tx, out, "}\n");
  free(body.s);
}

// ---- entry -----------------------------------------------------------------

static void fill_info(Tx* tx) {
  FvglShaderInfo* info = tx->info;
  memset(info, 0, sizeof *info);
  for (Decl* d = tx->attributes; d; d = d->next) {
    if (info->attribute_count == FVGL_MAX_ATTRIBUTES) fail(tx, 0, "more than %d attributes", FVGL_MAX_ATTRIBUTES);
    FvglDecl* o = &info->attributes[info->attribute_count++];
    snprintf(o->name, sizeof o->name, "%s", d->name);
    o->type = d->type;
  }
  for (Decl* d = tx->varyings; d; d = d->next) {
    if (info->varying_count == FVGL_MAX_VARYINGS) fail(tx, 0, "more than %d varyings", FVGL_MAX_VARYINGS);
    FvglDecl* o = &info->varyings[info->varying_count++];
    snprintf(o->name, sizeof o->name, "%s", d->name);
    o->type = d->type;
  }
  for (Decl* d = tx->globals; d; d = d->next) {
    if (d->is_const) continue;
    if (info->uniform_count == FVGL_MAX_UNIFORMS) fail(tx, 0, "more than %d uniforms", FVGL_MAX_UNIFORMS);
    FvglDecl* o = &info->uniforms[info->uniform_count++];
    snprintf(o->name, sizeof o->name, "%s", d->name);
    o->type = d->type;
  }
  info->uses_fragcoord = tx->uses_fragcoord;
  info->uses_pointsize = tx->uses_pointsize;
}

int fvgl_translate(const char* glsl, bool fragment, const FvglVaryingMap* map,
                   char** cg_out, FvglShaderInfo* info, char* log, size_t log_size) {
  Tx tx;
  memset(&tx, 0, sizeof tx);
  tx.log = log;
  tx.log_size = log_size;
  tx.src = glsl;
  tx.fragment = fragment;
  tx.map = map;
  tx.info = info;
  if (log_size) log[0] = 0;
  if (cg_out) *cg_out = NULL;
  Buf out = {0};
  if (setjmp(tx.fail)) {
    free(out.s);
    tx_free_all(&tx);
    return -1;
  }
  lex(&tx);
  add_builtins(&tx);
  parse_unit(&tx);
  // Emit always, so the built-in usage and the type errors are found at
  // compile time too; without a map the text is thrown away.
  emit_unit(&tx, &out);
  fill_info(&tx);
  if (cg_out && map) {
    *cg_out = out.s;
  } else {
    free(out.s);
  }
  tx_free_all(&tx);
  return 0;
}
