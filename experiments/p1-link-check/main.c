// Phase 1 link check.
//
// Compiling 494 objects proved nothing about whether they resolve against each
// other -- creating a static archive never links. This is the smallest program
// that forces a real link of the Dart AOT runtime for Vita.
//
// It is not expected to run yet, and it deliberately does almost nothing: the
// point is the undefined-symbol list, which is the honest remainder of Phase 1.

#include <stdio.h>
#include <string.h>

#include "dart_api.h"

int main(void) {
  // Referencing a handful of entry points across the runtime is enough to drag
  // in the VM, the heap, the object model and the platform layer.
  char* err = Dart_SetVMFlags(0, NULL);
  if (err != NULL) {
    printf("Dart_SetVMFlags: %s\n", err);
    return 1;
  }

  Dart_InitializeParams params;
  memset(&params, 0, sizeof(params));
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;

  err = Dart_Initialize(&params);
  if (err != NULL) {
    printf("Dart_Initialize: %s\n", err);
    return 1;
  }

  printf("dart version: %s\n", Dart_VersionString());
  Dart_Cleanup();
  return 0;
}
