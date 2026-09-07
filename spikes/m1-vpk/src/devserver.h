// On-device development server.
//
// Closes the edit -> deploy -> run loop without taiHEN. vitacompanion would
// have done this, but it hangs SceShell on this device regardless of which
// ports it uses (see spikes/vita-tooling/README.md), so the listener lives
// inside our own app instead. The tradeoff is that it only exists while our app
// is running: no button injection, no screenshots, and the first launch after a
// hard crash is still manual.
#ifndef DEVSERVER_H
#define DEVSERVER_H

#define DEVSERVER_PORT 1339

// Where `handoff` goes when nothing overrides it. Overridable at runtime by
// ux0:data/flutter-vita/receiver.titleid, and per-command by `handoff <titleid>`
// -- because a hardcoded slot is wrong the moment the receiver is reinstalled
// somewhere else, and every app on the card would otherwise need rebuilding.
#define DEVSERVER_DEFAULT_LOADER "FVTA00001"

// Serves until `exit` arrives or START is pressed. `log_line` receives progress
// messages and should append a newline itself.
//
// Returns 0 if it was asked to exit, negative if the server could not start --
// in which case the caller should fall back to waiting for START, since with no
// network there is no other way out.
int dev_server_run(void (*log_line)(const char* msg),
                   const char* log_path,
                   const char* eboot_path);

// Register a framebuffer source for the `shot` command.
//
// The server has no idea what an app draws with, so the app hands it a reader.
// `describe` gets a one-line human-readable summary of the display state, and
// the return value is the pixel data to stream, or NULL if there is nothing to
// capture yet.
//
// Whatever this returns must be the buffer the *display controller* is
// scanning, not the app's private copy of it. An app that dumps memory it
// wrote proves only that it wrote it; if sceDisplaySetFrameBuf never took, the
// capture looks perfect over a black panel.
void dev_server_set_framebuffer_source(
    const void* (*read_framebuffer)(unsigned int* size,
                                    char* describe,
                                    unsigned int describe_size));

// Register a handler for `tap <x> <y>`, in display pixels.
//
// This exists so input can be tested without a finger on the panel. It is not
// a substitute for the real thing -- it bypasses sceTouch entirely, so it
// proves the engine's pointer path and says nothing about coordinate scaling
// or the panel's sampling. Both are worth having: this one can run unattended
// on every deploy, and a human tap checks what it cannot.
//
// Called from the server's thread, so the handler must hand the event to
// whichever thread owns the engine rather than dispatching it directly.
void dev_server_set_tap_handler(void (*tap)(int x, int y));

// Register a handler for `swipe <x0> <y0> <x1> <y1> [steps]`, in display pixels.
//
// Scrolling could not be driven from the host at all before this: `tap` sends a
// down and an up in the same pass, and no amount of those scrolls a list. That
// left the heaviest thing an app does -- flinging a long list -- testable only
// by hand, which is why a reported "sometimes it sticks while scrolling" had
// nowhere to start.
//
// `steps` is the number of move events, and the handler is expected to spread
// them over consecutive frames rather than emitting them all at once. That is
// what makes the gesture a fling: Flutter's velocity tracker reads the
// timestamps on the moves, so a drag delivered in a single pass has infinite
// velocity and is discarded as a fluke.
void dev_server_set_swipe_handler(void (*swipe)(int x0, int y0,
                                                int x1, int y1, int steps));

// Register a handler for `overlay on|off`.
//
// The debug HUD is drawn over the app, so a screenshot taken for anything but
// debugging has it in the corner. This turns it off without a rebuild.
void dev_server_set_overlay_handler(void (*overlay)(int on));

// --- Extension points, for a product that embeds this server -------------
//
// The receiver (ADR-0016) is a Flutter app built from the same template as any
// other, so it links this same server rather than carrying a private copy.
// What it needs on top is a different port, three commands of its own, and a
// much smaller surface than an app under development wants. All three are
// registered from a constructor in the product's own translation unit, which
// runs before main() and therefore before dev_server_run.

// Listen somewhere other than DEVSERVER_PORT. Must be called before
// dev_server_run; ignored afterwards.
void dev_server_set_port(int port);

// Handle a command this server does not know.
//
// Called for every line, before the built-in dispatch, so it can also shadow
// a built-in. Returns 1 if it handled the line and 0 to fall through. Set
// `*stop` to 1 to close the listener and return from dev_server_run, which is
// what a command that hands the console to another process wants.
void dev_server_set_command_handler(
    int (*handle)(int sock, const char* line, int* stop));

// Reply on a connection, and write a line to the product's log. Exposed for
// the command handler above, which has no other way to do either.
void dev_server_send(int sock, const char* s);
void dev_server_log(const char* msg);

// Called once the network is up: SCE_SYSMODULE_NET loaded, sceNetInit and
// sceNetCtlInit done, immediately before the accept loop starts.
//
// This exists because there is no other safe moment. Registration happens in a
// constructor, which runs before main() and therefore long before any of that
// -- and a Vita stub for a module that is not resident is not a stub that
// returns an error, it is address zero. The receiver's first attempt at watching
// the IP called sceNetCtlInetGetInfo from its constructor and took the process
// down with a prefetch abort at PC 0.
void dev_server_set_ready_handler(void (*ready)(void));

// Serve only the deploy and debug loop: ping, probe, log, get, put, plus
// whatever the command handler adds. Everything else is refused.
//
// ADR-0016 decision 9. The receiver is the component that recovers from
// crashes, so it carries the least surface of anything here -- no handoff, no
// relaunch, no deliberate fault, and no crash supervisor either, since the
// supervisor's job is to bring the receiver back.
void dev_server_set_minimal(int minimal);

#endif  // DEVSERVER_H
