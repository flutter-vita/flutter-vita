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

#endif  // DEVSERVER_H
