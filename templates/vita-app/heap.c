// How much of the process budget newlib gets for malloc.
//
// VitaSDK carves the C heap out of the process memory budget **once, at
// startup**, as a fixed arena sized by this symbol, and applies a modest
// default when an app does not define it. Nothing grows it later.
//
// That default is what killed every long-running app on this port. The bail
// reason was
//
//     emutls: memalign failed for thread_local storage
//
// while the frame log reported 86 MB of free user memory and the whole run had
// consumed 2 MB. Both numbers were true: sceKernelGetFreeMemorySize reports the
// *process budget*, and knows nothing about how much of it newlib was handed.
// The arena was full with most of the budget still unclaimed, because nothing
// had ever asked for it.
//
// emutls was the messenger rather than the cause — a small allocation made
// constantly, on one of the few paths that checks for NULL and exits cleanly
// instead of crashing somewhere less legible.
//
// The size is a trade with no safe default: too large and the block cannot be
// allocated at startup, so the app does not launch at all; too small and the
// same failure returns later and looks like a different bug. This value leaves
// headroom for the memblocks the engine allocates separately — the AOT
// snapshot's VM domain, and Skia's surfaces — which do **not** come out of here.
//
// Tuned by measurement, both directions:
//
//   default   ~88 MB of the budget left free, and the arena filled — the crash
//   200 MB    ran, and left only 10 MB free. Too tight: the memblocks above are
//             allocated later and from what remains, so a frame that needs a
//             new surface has almost nowhere to go
//   160 MB    ~50 MB free, which is headroom for surfaces without giving the
//             arena back its old ceiling
unsigned int _newlib_heap_size_user = 160 * 1024 * 1024;
