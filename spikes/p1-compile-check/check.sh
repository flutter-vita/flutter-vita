#!/usr/bin/env bash
# Phase 1 — compile Dart runtime sources for arm-vita-eabi without a full GN build.
#
# The proper Dart build needs depot_tools and a multi-gigabyte `gclient sync`.
# That is Phase 2 work. Meanwhile this gives the thing that actually matters
# while writing platform files: a compiler checking them against the real
# headers. It does not link, and it is not a substitute for the GN build --
# it is a fast inner loop that catches the majority of mistakes.
#
# Usage:  ./check.sh                 compile the default probe
#         ./check.sh path/to/file.cc compile a specific runtime source
set -euo pipefail

cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
SDK="$REPO/third_party/dart-sdk"

: "${VITASDK:=$HOME/vitasdk}"
export PATH="$VITASDK/bin:$PATH"

if [[ ! -d "$SDK/runtime" ]]; then
  echo "error: Dart SDK not checked out at $SDK" >&2
  echo "       see patches/dart-sdk/README.md" >&2
  exit 1
fi

# gnu++20, not c++20, and both halves matter:
#   C++20  -- Dart uses std::bit_cast, std::has_single_bit, std::bit_ceil.
#             Under C++17 the failure is dozens of unrelated-looking errors.
#   gnu    -- strict ISO mode sets __STRICT_ANSI__, which makes newlib hide its
#             POSIX extensions. Without this, strdup is "not declared".
FLAGS=(
  -std=gnu++20 -c -O2 -Wall
  -I"$SDK" -I"$SDK/runtime" -I"$SDK/runtime/include"
  -DDART_PRECOMPILED_RUNTIME   # AOT runtime only, no JIT -- ADR-0001
  -DTARGET_ARCH_ARM            # armv7
  -DPRODUCT -DNDEBUG
)

mkdir -p out

# With no argument, check every Vita platform file plus the header probe.
if [[ $# -gt 0 ]]; then
  SOURCES=("$1")
else
  SOURCES=(
    probe.cc
    "$SDK/runtime/vm/cpuinfo_vita.cc"
    "$SDK/runtime/vm/thread_interrupter_vita.cc"
    "$SDK/runtime/vm/virtual_memory_vita.cc"
    "$SDK/runtime/vm/cpu_arm.cc"
  )
fi

fail=0
for src in "${SOURCES[@]}"; do
  printf '  %-34s ' "$(basename "$src")"
  if arm-vita-eabi-g++ "${FLAGS[@]}" "$src" -o "out/$(basename "${src%.*}").o" 2>out/last-error.txt; then
    echo "OK"
  else
    echo "FAIL"
    grep -E "error" out/last-error.txt | head -5 | sed 's/^/      /'
    fail=1
  fi
done
exit $fail
