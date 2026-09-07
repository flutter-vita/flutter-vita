// Smallest translation unit that proves the Dart runtime headers compile for
// arm-vita-eabi with patch 0001 applied.
//
// virtual_memory.h is deliberately the include under test: it pulls in
// platform/globals.h and platform/utils.h, which are exactly what patch 0001
// touches, and it is the header the first real platform file
// (virtual_memory_vita.cc) will implement against.

#include "vm/virtual_memory.h"

namespace dart {

void ProbeTouchesTheApi() {
  (void)VirtualMemory::PageSize();
}

}  // namespace dart
