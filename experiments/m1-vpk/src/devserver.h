// On-device development server: the edit -> deploy -> run loop without taiHEN.
//
// vitacompanion hangs SceShell on this device (experiments/vita-tooling), so the
// listener lives inside our own app. It exists only while the app runs.
#ifndef DEVSERVER_H
#define DEVSERVER_H

#define DEVSERVER_PORT 1339

// Default handoff target. Overridden by ux0:data/flutter-vita/receiver.titleid
// or by `handoff <titleid>`, so reinstalling the receiver needs no rebuild.
#define DEVSERVER_DEFAULT_LOADER "FVTA00001"

// Serves until `exit` arrives or START is pressed. Returns 0 on exit, negative
// if the server could not start, in which case the caller must wait for START.
// `log_line` appends its own newline.
int dev_server_run(void (*log_line)(const char* msg),
                   const char* log_path,
                   const char* eboot_path);

// Register a framebuffer source for `shot`. `describe` gets a one-line summary
// of the display state; the return is the pixels, or NULL if nothing to capture.
//
// It must be the buffer the display controller scans, not the app's private
// copy: dumping memory we wrote proves only that we wrote it.
void dev_server_set_framebuffer_source(
    const void* (*read_framebuffer)(unsigned int* size,
                                    char* describe,
                                    unsigned int describe_size));

// Register a handler for `tap <x> <y>`, in display pixels.
//
// It bypasses sceTouch, so it proves the engine's pointer path and says nothing
// about coordinate scaling or panel sampling. Called from the server's thread,
// so hand the event to whichever thread owns the engine.
void dev_server_set_tap_handler(void (*tap)(int x, int y));

// Register a handler for `swipe <x0> <y0> <x1> <y1> [steps]`, in display pixels.
//
// `tap` sends a down and an up in one pass and cannot scroll anything. `steps`
// is the number of move events, and the handler must spread them over
// consecutive frames: Flutter's velocity tracker reads their timestamps, so a
// drag delivered in one pass has infinite velocity and is discarded.
void dev_server_set_swipe_handler(void (*swipe)(int x0, int y0,
                                                int x1, int y1, int steps));

// Register a handler for `overlay on|off`. The debug HUD is drawn over the app,
// so a screenshot taken for anything else has it in the corner. The same
// handler gets -1 when L + R + SELECT is pressed on the pad, meaning "the
// other state".
void dev_server_set_overlay_handler(void (*overlay)(int on));

// --- Extension points, for a product that embeds this server -------------
//
// The receiver (ADR-0016) links this server rather than copying it. It needs a
// different port, three commands of its own, and a smaller surface. All three
// are registered from a constructor, which runs before dev_server_run.

// Listen somewhere other than DEVSERVER_PORT. Must be called before
// dev_server_run; ignored afterwards.
void dev_server_set_port(int port);

// Handle a command this server does not know. Called for every line before the
// built-in dispatch, so it can shadow a built-in. Returns 1 if it handled the
// line. Set `*stop` to 1 to close the listener and return from dev_server_run.
void dev_server_set_command_handler(
    int (*handle)(int sock, const char* line, int* stop));

// Reply on a connection, and write a line to the product's log. Exposed for
// the command handler above, which has no other way to do either.
void dev_server_send(int sock, const char* s);
void dev_server_log(const char* msg);

// Called once the network is up: SCE_SYSMODULE_NET loaded, sceNetInit and
// sceNetCtlInit done, immediately before the accept loop.
//
// There is no earlier safe moment. A Vita stub for a non-resident module is
// address zero, not an error: calling sceNetCtlInetGetInfo from a constructor
// took the process down with a prefetch abort at PC 0.
void dev_server_set_ready_handler(void (*ready)(void));

// Serve only ping, probe, log, get, put, plus whatever the command handler
// adds. ADR-0016 decision 9: the receiver recovers from crashes, so it carries
// no handoff, no relaunch, no deliberate fault, and no crash supervisor.
void dev_server_set_minimal(int minimal);

#endif  // DEVSERVER_H
