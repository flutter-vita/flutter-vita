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

#endif  // DEVSERVER_H
