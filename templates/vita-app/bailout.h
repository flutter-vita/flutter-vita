// Clean exit to the loader, for failures the program can see coming.
//
// See bailout.c for why this exists and what it can and cannot catch.
#ifndef VITA_BAILOUT_H
#define VITA_BAILOUT_H

#ifdef __cplusplus
extern "C" {
#endif

// Record `reason`, launch the dev loader, and exit the process cleanly.
//
// Call it anywhere continuing would mean a fault -- a NULL that the caller
// cannot check, an allocation that failed, a table that is full. Does not
// return.
//
// The point is the *clean* exit. A faulting process puts an error dialog on
// the console and needs a person to dismiss it and then find the loader; a
// process that exits normally does neither.
void vita_bail_to_loader(const char* reason);

#ifdef __cplusplus
}
#endif

#endif  // VITA_BAILOUT_H
