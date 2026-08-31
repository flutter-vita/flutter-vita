// What a shipping app links instead of the dev loop.
//
// The dev server, the debug HUD and the bailout path are three separate
// mechanisms with one property in common: each is reachable from outside the
// app, and each exists to serve whoever is developing it. A build handed to
// someone else should have none of them.
//
//   the dev server   a listening socket on 1339 that will read and write any
//                    path on the memory card, unauthenticated, and stream the
//                    framebuffer to anyone who connects
//   the debug HUD    frame rate, damaged area, blit cost and free memory, drawn
//                    over the top-right corner of every frame
//   bailout.c        turns an abort into "launch FVTA00003 and exit", which on
//                    a console with no development loader on it means the app
//                    vanishes to LiveArea for no reason the user can see
//
// Dropping the first and third is a matter of leaving two files out of the
// build. The HUD is not, because it lives inside the engine archive, so it is
// switched off by *adding* a definition: the engine's is weak and a strong one
// linked alongside wins.
//
// The five stubs are here because the embedder calls them unconditionally and
// the linker needs bodies. They are not conditionally compiled in the engine,
// and should not be -- the embedder is one artifact shared by every app, and
// an engine that knows whether it is a release build is an engine that has to
// be built twice.
//
// What this does NOT remove is the log file. The engine opens
// ux0:data/flutter-vita/app.log before anything else runs and writes it
// unbuffered, and that is inside the archive with no weak symbol to override
// yet. A release app still writes it; nothing can be read back over the
// network, because the thing that served files is gone.

#include <stddef.h>

// Strong against the engine's weak `= 1`. See the comment above.
int flutter_vita_debug_overlay = 0;

// The dev server's five entry points, as no-ops.
//
// dev_server_run returns 0, not a negative: the embedder reads negative as
// "the socket would not come up", which is a diagnostic about a server that is
// trying to exist. This one is not trying. Its thread exits and the engine
// carries on, which is what the embedder does with either answer.
int dev_server_run(void (*log_line)(const char* msg),
                   const char* log_path,
                   const char* eboot_path) {
  (void)log_line;
  (void)log_path;
  (void)eboot_path;
  return 0;
}

void dev_server_set_framebuffer_source(
    const void* (*read_framebuffer)(unsigned int* size,
                                    char* describe,
                                    unsigned int describe_size)) {
  (void)read_framebuffer;
}

void dev_server_set_tap_handler(void (*tap)(int x, int y)) { (void)tap; }

void dev_server_set_swipe_handler(void (*swipe)(int x0, int y0,
                                                int x1, int y1, int steps)) {
  (void)swipe;
}

void dev_server_set_overlay_handler(void (*overlay)(int on)) { (void)overlay; }
