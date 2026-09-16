// The channel registry behind fvita_plugin.h, and the two hooks the embedder
// calls: `flutter_vita_channel_call` for any `vita/...` channel it does not
// answer itself, and `flutter_vita_hardware_call_async`, the older name for
// the gallery's `vita/hardware`, which is now one registered channel like
// the others.
//
// Every call runs on a thread of its own and answers from it. The embedder
// calls in on the platform thread, the one that drains platform messages;
// until 2026-09-16 that thread waited for the check, so two calls asked for
// together ran one after the other and the microphone had finished
// recording before the speaker began. Now the call returns at once and the
// job's thread completes the message. A watchdog thread waits on the job
// with a 15 s deadline; whichever of the two is first answers, the other
// finds `answered` set and does nothing. A job that blocks in the system is
// left where it is: its buffers are its own, and whatever it writes later
// lands nowhere the caller reads.
#include "fvita_plugin.h"

#include <psp2/kernel/threadmgr.h>
#include <vitasdk/utils.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- registry --------------------------------------------------------------

enum { kMaxChannels = 32, kDefaultCap = 256 * 1024 };
typedef struct Channel {
  char name[48];
  FvitaChannelHandler handler;
  size_t cap;
} Channel;
static Channel g_channels[kMaxChannels];
static int g_channel_count;

static Channel* find_channel(const char* channel, int create) {
  for (int i = 0; i < g_channel_count; i++) {
    if (strcmp(g_channels[i].name, channel) == 0) return &g_channels[i];
  }
  if (!create || g_channel_count == kMaxChannels) return NULL;
  Channel* c = &g_channels[g_channel_count++];
  snprintf(c->name, sizeof c->name, "%s", channel);
  c->cap = kDefaultCap;
  return c;
}

void fvita_channel_register(const char* channel, FvitaChannelHandler handler) {
  Channel* c = find_channel(channel, 1);
  if (c != NULL) c->handler = handler;
}

void fvita_channel_reply_cap(const char* channel, size_t cap) {
  Channel* c = find_channel(channel, 1);
  if (c != NULL && cap >= 1024) c->cap = cap;
}

// ---- replies and arguments ------------------------------------------------

int fvita_reply_ok(char* out, size_t cap, const char* fmt, ...) {
  int n = snprintf(out, cap, "[");
  va_list ap;
  va_start(ap, fmt);
  n += vsnprintf(out + n, cap - (size_t)n, fmt, ap);
  va_end(ap);
  if ((size_t)n + 2 > cap) return -1;
  out[n++] = ']';
  out[n] = '\0';
  return n;
}

int fvita_reply_err(char* out, size_t cap, const char* code, const char* what, int sce) {
  if (sce == 0) return snprintf(out, cap, "[\"%s\",\"%s\",null]", code, what);
  return snprintf(out, cap, "[\"%s\",\"%s: 0x%08X\",null]", code, what, (unsigned)sce);
}

static const char* find_key(const char* body, size_t len, const char* key) {
  char pat[64];
  const int pl = snprintf(pat, sizeof pat, "\"%s\":", key);
  if (pl <= 0 || body == NULL) return NULL;
  for (size_t i = 0; i + (size_t)pl <= len; i++) {
    if (memcmp(body + i, pat, (size_t)pl) == 0) {
      const char* v = body + i + pl;
      while (v < body + len && (*v == ' ' || *v == '\t')) v++;
      return v;
    }
  }
  return NULL;
}

int fvita_json_int(const char* body, size_t len, const char* key, int dflt) {
  const char* v = find_key(body, len, key);
  return v != NULL ? atoi(v) : dflt;
}

double fvita_json_num(const char* body, size_t len, const char* key, double dflt) {
  const char* v = find_key(body, len, key);
  return v != NULL ? atof(v) : dflt;
}

int fvita_json_bool(const char* body, size_t len, const char* key, int dflt) {
  const char* v = find_key(body, len, key);
  if (v == NULL) return dflt;
  if (strncmp(v, "true", 4) == 0) return 1;
  if (strncmp(v, "false", 5) == 0) return 0;
  return dflt;
}

int fvita_json_str(const char* body, size_t len, const char* key, char* out, size_t cap) {
  const char* v = find_key(body, len, key);
  if (v == NULL || v >= body + len || *v != '"') return -1;
  v++;
  size_t n = 0;
  while (v < body + len && *v != '"') {
    char c = *v++;
    if (c == '\\' && v < body + len) {
      c = *v++;
      if (c == 'n') c = '\n';
    }
    if (n + 1 < cap) out[n++] = c;
  }
  if (cap) out[n] = '\0';
  return (int)n;
}

void fvita_log(const char* tag, const char* fmt, ...) {
  char line[240];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  // stderr is the engine's log file, unbuffered: the line is on the card
  // before this returns, so a call that never comes back still leaves its
  // last step.
  fprintf(stderr, "%s: %s\n", tag, line);
}

// ---- base64 -----------------------------------------------------------------

static const char kB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

size_t fvita_base64_encode(const unsigned char* in, size_t n, char* out) {
  size_t o = 0;
  for (size_t i = 0; i < n; i += 3) {
    const unsigned v = (unsigned)in[i] << 16 | (i + 1 < n ? (unsigned)in[i + 1] << 8 : 0u) |
                       (i + 2 < n ? (unsigned)in[i + 2] : 0u);
    out[o++] = kB64[v >> 18 & 63];
    out[o++] = kB64[v >> 12 & 63];
    out[o++] = i + 1 < n ? kB64[v >> 6 & 63] : '=';
    out[o++] = i + 2 < n ? kB64[v & 63] : '=';
  }
  out[o] = '\0';
  return o;
}

int fvita_base64_decode(const char* in, size_t n, unsigned char* out, size_t cap) {
  unsigned acc = 0;
  int bits = 0;
  size_t o = 0;
  for (size_t i = 0; i < n; i++) {
    const char c = in[i];
    int v;
    if (c >= 'A' && c <= 'Z') v = c - 'A';
    else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
    else if (c >= '0' && c <= '9') v = c - '0' + 52;
    else if (c == '+') v = 62;
    else if (c == '/') v = 63;
    else if (c == '=' || c == '\n' || c == '\r' || c == ' ') continue;
    else return -1;
    acc = acc << 6 | (unsigned)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      if (o < cap) out[o] = (unsigned char)(acc >> bits & 0xFF);
      o++;
    }
  }
  return o <= cap ? (int)o : -1;
}

// ---- threads ------------------------------------------------------------------

void fvita_thread_delete(int thread) {
  vitasdk_delete_thread_reent(thread);
  sceKernelDeleteThread(thread);
}

void fvita_thread_exit_delete(void) {
  vitasdk_delete_thread_reent(sceKernelGetThreadId());
  // Nothing from the C library between here and the exit: the record it
  // would want is gone.
  sceKernelExitDeleteThread(0);
  for (;;) sceKernelDelayThread(1000 * 1000);
}

// ---- jobs ---------------------------------------------------------------------

typedef struct Job {
  char channel[48];
  char method[48];
  char* body;
  size_t body_len;
  char* out;
  size_t cap;
  FvitaChannelHandler handler;
  void (*respond)(void* ctx, const char* reply, size_t len);
  void* ctx;
  volatile int answered;
  SceUID thread;
} Job;

// Exactly one answer per job. The two threads race for `answered`; the
// processor's compare-and-swap decides.
static void job_answer(Job* j, const char* reply, size_t len) {
  if (__sync_val_compare_and_swap(&j->answered, 0, 1) != 0) return;
  j->respond(j->ctx, reply, len);
}

static int job_thread(SceSize args, void* argp) {
  (void)args;
  Job* j = *(Job**)argp;
  const int rc = j->handler(j->method, j->body, j->body_len, j->out, j->cap);
  if (rc < 0) {
    char err[160];
    const int n = snprintf(err, sizeof err, "[\"failed\",\"%s %s: the handler failed\",null]", j->channel, j->method);
    job_answer(j, err, (size_t)n);
  } else {
    job_answer(j, j->out, (size_t)rc);
  }
  return 0;
}

// Ends through fvita_thread_exit_delete, never a return. A thread that has
// ended stays allocated until it is deleted, and nothing else holds this
// one's id: until 2026-09-16 every call leaked one, the receiver's audio
// view polls four times a second, and after a few minutes
// sceKernelCreateThread answered 0x8002450D to everyone -- the Dart VM
// included, which aborted on "Could not start thread DartWorker". The
// same day, with the kernel object deleted but newlib's record not, the
// gallery died after two hours in pthread_create (see fvita_plugin.h).
static int watchdog_thread(SceSize args, void* argp) {
  (void)args;
  Job* j = *(Job**)argp;
  SceUInt timeout = 15 * 1000 * 1000;
  if (sceKernelWaitThreadEnd(j->thread, NULL, &timeout) < 0) {
    char err[160];
    const int n = snprintf(err, sizeof err, "[\"timeout\",\"%s %s: no answer in 15 s\",null]", j->channel, j->method);
    fvita_log("plugin", "%s %s: no answer in 15 s, thread abandoned", j->channel, j->method);
    job_answer(j, err, (size_t)n);
    // The job's memory stays with the abandoned thread.
  } else {
    fvita_thread_delete(j->thread);
    free(j->body);
    free(j->out);
    free(j);
  }
  fvita_thread_exit_delete();
}

int flutter_vita_channel_call(const char* channel, const char* method, const char* body, size_t body_len,
                              void (*respond)(void* ctx, const char* reply, size_t len), void* ctx) {
  if (channel == NULL || method == NULL || respond == NULL) return -1;
  const Channel* c = find_channel(channel, 0);
  if (c == NULL || c->handler == NULL) return -1;
  Job* j = calloc(1, sizeof *j);
  if (j == NULL) return -1;
  snprintf(j->channel, sizeof j->channel, "%s", channel);
  snprintf(j->method, sizeof j->method, "%s", method);
  j->handler = c->handler;
  j->body_len = body != NULL ? body_len : 0;
  j->body = malloc(j->body_len + 1);
  j->cap = c->cap;  // 256 KB unless the plugin asked for more: a second of audio fits, a camera frame does not
  j->out = malloc(j->cap);
  if (j->body == NULL || j->out == NULL) {
    free(j->body);
    free(j->out);
    free(j);
    return -1;
  }
  if (j->body_len) memcpy(j->body, body, j->body_len);
  j->body[j->body_len] = '\0';
  j->out[0] = '\0';
  j->respond = respond;
  j->ctx = ctx;
  j->thread = sceKernelCreateThread("fvita-plugin", job_thread, 0x10000100, 0x10000, 0, 0, NULL);
  const SceUID dog = j->thread < 0 ? j->thread
                                   : sceKernelCreateThread("fvita-plugin-dog", watchdog_thread, 0x10000100, 0x1000, 0, 0, NULL);
  if (j->thread < 0 || dog < 0) {
    fvita_log("plugin", "%s %s: sceKernelCreateThread 0x%08X", channel, method,
              (unsigned)(j->thread < 0 ? j->thread : dog));
    if (j->thread >= 0) sceKernelDeleteThread(j->thread);
    free(j->body);
    free(j->out);
    free(j);
    return -1;
  }
  sceKernelStartThread(j->thread, sizeof j, &j);
  sceKernelStartThread(dog, sizeof j, &j);
  return 0;
}

// The gallery's channel under the name the embedder's earlier hook used.
int flutter_vita_hardware_call_async(const char* method, const char* body, size_t body_len,
                                     void (*respond)(void* ctx, const char* reply, size_t len), void* ctx) {
  return flutter_vita_channel_call("vita/hardware", method, body, body_len, respond, ctx);
}
