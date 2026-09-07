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

#ifdef __cplusplus
}
#endif

#endif  // VITA_BAILOUT_H
