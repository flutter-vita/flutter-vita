#ifndef VITA_BAILOUT_H
#define VITA_BAILOUT_H

#ifdef __cplusplus
extern "C" {
#endif

// Record `reason`, launch the dev receiver, and exit cleanly. Does not return.
//
// The clean exit is the point: a faulting process leaves an error dialog on the
// console for someone to dismiss by hand.
void vita_bail_to_loader(const char* reason);

// The same, naming the address to record as the caller. abort() passes its
// own return address, so the record names the code that aborted rather than
// abort itself.
void vita_bail_to_loader_from(const char* reason, const void* caller);

#ifdef __cplusplus
}
#endif

#endif  // VITA_BAILOUT_H
