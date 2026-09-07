#!/usr/bin/env bash
# Build the ADR-0014 vitaGL feasibility experiment.
set -euo pipefail
: "${VITASDK:?Define VITASDK. See docs/dev-environment.md}"
export PATH="$VITASDK/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
cmake -S "$HERE" -B "$HERE/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$HERE/build" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
echo "==> $HERE/build/flutter_vita_g1.vpk"
