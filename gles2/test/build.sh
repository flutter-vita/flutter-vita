#!/usr/bin/env bash
# Build the fvita_gles2 on-console test.
set -euo pipefail
: "${VITASDK:?Define VITASDK. See docs/dev-environment.md}"
export PATH="$VITASDK/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
cmake -S "$HERE" -B "$HERE/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$HERE/build" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
echo "==> $HERE/build/fvita_gles2_test.vpk"
