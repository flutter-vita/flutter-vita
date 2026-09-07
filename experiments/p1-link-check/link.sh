#!/usr/bin/env bash
# Phase 1 link check -- the test that compiling could not perform.
#
# Creating a static archive never resolves symbols, so 494 cleanly compiled
# objects said nothing about whether the runtime is complete. This links them
# all against a minimal main() and reports any undefined symbols.
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
: "${VITASDK:=$HOME/vitasdk}"; export PATH="$VITASDK/bin:$PATH"
OUT="$REPO/third_party/sdk/out/vita"
mkdir -p out

arm-vita-eabi-gcc -c main.c -o out/main.o \
  -I "$REPO/third_party/sdk/runtime/include" -I "$REPO/third_party/sdk/runtime"

# -lpthread is required: VitaSDK keeps pthreads in a separate library, unlike
# glibc where they now live in libc.
arm-vita-eabi-g++ out/main.o $(find "$OUT/obj" -name "*.o" | tr '\n' ' ') \
  -o out/dartvm.elf \
  -lSceLibKernel_stub -lSceSysmem_stub -lSceKernelThreadMgr_stub \
  -lSceIofilemgr_stub -lpthread -lc -lm

arm-vita-eabi-strip -o out/dartvm-stripped.elf out/dartvm.elf
echo "==> linked"
file out/dartvm.elf
arm-vita-eabi-size out/dartvm-stripped.elf
