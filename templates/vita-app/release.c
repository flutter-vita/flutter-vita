// What a shipping app links instead of the dev loop.
//
// The dev server (an unauthenticated socket on 1339 that reads and writes any
// path on the card) and bailout.c (which launches FVTA00001 on abort, so on a
// console with no receiver the app just vanishes) are dropped by leaving their
// files out of the build. The debug HUD lives inside the engine archive, so it
// is switched off by defining a strong symbol against the engine's weak one.
//
// The five stubs exist because the embedder calls them unconditionally. Making
// them conditional in the engine would mean building the engine twice.
//
// The log file stays. The engine opens it before anything else runs and there
// is no weak symbol to override yet, but nothing can read it back once the
// server is gone.

#include <stddef.h>

// Strong against the engine's weak `= 1`. See the comment above.
int flutter_vita_debug_overlay = 0;

// Same again for the UI-thread watchdog: a shipping app never relaunches
// itself on a wedged UI thread, that is a dev-loop convenience.
int flutter_vita_watchdog = 0;

// Returns 0, not a negative: the embedder reads negative as "the socket would
// not come up", and this one is not trying to come up.
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
