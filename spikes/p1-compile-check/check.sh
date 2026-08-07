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

# C++20 is required: Dart uses std::bit_cast, std::has_single_bit, std::bit_ceil.
# Under C++17 the failure looks like dozens of unrelated errors.
FLAGS=(
  -std=c++20 -c -O2 -Wall
  -I"$SDK" -I"$SDK/runtime" -I"$SDK/runtime/include"
  -DDART_PRECOMPILED_RUNTIME   # AOT runtime only, no JIT -- ADR-0001
  -DTARGET_ARCH_ARM            # armv7
  -DPRODUCT -DNDEBUG
)

SRC="${1:-probe.cc}"
mkdir -p out
echo "==> arm-vita-eabi-g++ $SRC"
arm-vita-eabi-g++ "${FLAGS[@]}" "$SRC" -o "out/$(basename "${SRC%.*}").o"
echo "==> ok: out/$(basename "${SRC%.*}").o"
ls -la "out/$(basename "${SRC%.*}").o"
