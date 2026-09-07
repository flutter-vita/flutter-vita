#!/usr/bin/env bash
# Phase 0.5 Track A — build the probe .vpk.
#
# Usage:  ./build.sh            build
#         ./build.sh clean      rebuild from scratch
set -euo pipefail

cd "$(dirname "$0")"

: "${VITASDK:=$HOME/vitasdk}"
export VITASDK
export PATH="$VITASDK/bin:$PATH"

if [[ ! -x "$VITASDK/bin/arm-vita-eabi-gcc" ]]; then
  echo "error: VitaSDK not found at $VITASDK" >&2
  echo "       see docs/dev-environment.md" >&2
  exit 1
fi

[[ "${1:-}" == "clean" ]] && rm -rf build

# Some VitaSDK library ports still declare cmake_minimum_required < 3.5, which
# CMake 4 rejects outright. Harmless on CMake 3.x.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build

VPK="build/flutter_vita_probe.vpk"
echo
echo "==> $VPK"
ls -la "$VPK"
unzip -l "$VPK"
