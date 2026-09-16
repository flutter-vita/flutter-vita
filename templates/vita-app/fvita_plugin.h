// The native half of a Vita plugin.
//
// A Vita implementation of a pub package (ADR-0009) is a Dart package with a
// `vita/` directory: `plugin.cmake` names its C sources and stub libraries,
// and tools/build-vita-app.sh compiles them into the app that depends on
// the package. The C talks to Dart over one method channel per plugin,
// `vita/<name>`, JSONMethodCodec; the embedder hands every `vita/...`
// channel it does not answer itself to `flutter_vita_channel_call` in
// plugin.c, which finds the handler registered for the channel.
//
// A handler is a plain function: method, body, a buffer for the reply
// envelope. It runs on a thread of its own with a 15 s deadline, so it may
// block (a second of tone, a camera frame), and two calls asked for
// together run together. Registration from a constructor, so a plugin is
// one file:
//
//   static int handle(const char* method, const char* body, size_t len,
//                     char* out, size_t cap) { ... }
//   __attribute__((constructor)) static void reg(void) {
//     fvita_channel_register("vita/battery", handle);
//   }
//
// The reply envelope is JSONMethodCodec's: `[result]` for success, or
// `[code, message, details]` for an error, which Dart sees as a
// PlatformException. fvita_reply_ok and fvita_reply_err write those.
#ifndef FVITA_PLUGIN_H
#define FVITA_PLUGIN_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*FvitaChannelHandler)(const char* method, const char* body, size_t body_len, char* out, size_t cap);

// At most 32 channels; a second registration for a channel replaces the
// first, so a plugin can be shadowed by an app for a test.
void fvita_channel_register(const char* channel, FvitaChannelHandler handler);

// `[` + the formatted result + `]`. Returns the length, or -1 when it does
// not fit.
int fvita_reply_ok(char* out, size_t cap, const char* fmt, ...) __attribute__((format(printf, 3, 4)));

// `["<code>","<what>: 0x<sce>",null]`; with sce == 0 the message is `what`
// alone. Returns the length.
int fvita_reply_err(char* out, size_t cap, const char* code, const char* what, int sce);

// Arguments, straight out of the JSON body: the first `"key":` and the value
// after it. Enough for the arguments a plugin takes; not a JSON parser.
int fvita_json_int(const char* body, size_t len, const char* key, int dflt);
double fvita_json_num(const char* body, size_t len, const char* key, double dflt);
// A string value, unescaped for \" and \\ only; returns its length or -1.
int fvita_json_str(const char* body, size_t len, const char* key, char* out, size_t cap);
int fvita_json_bool(const char* body, size_t len, const char* key, int dflt);

// A line in the app's log, now: "<tag>: <message>".
void fvita_log(const char* tag, const char* fmt, ...) __attribute__((format(printf, 2, 3)));

// Base64, for bytes that have to cross the JSON codec (a recording, a WAV to
// play). Returns the length written; the buffer needs 4 * ((n + 2) / 3) + 1.
size_t fvita_base64_encode(const unsigned char* in, size_t n, char* out);
// Returns the number of bytes decoded, or -1 on a bad character.
int fvita_base64_decode(const char* in, size_t n, unsigned char* out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif
