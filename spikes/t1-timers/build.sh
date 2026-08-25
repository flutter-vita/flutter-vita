#!/usr/bin/env bash
# Build the T1 vpk. No Dart, no engine -- this is only VitaSDK.
set -euo pipefail
cd "$(dirname "$0")"
: "${VITASDK:=$HOME/vitasdk}"; export VITASDK; export PATH="$VITASDK/bin:$PATH"
export CMAKE_POLICY_VERSION_MINIMUM=3.5
[[ "${1:-}" == "clean" ]] && rm -rf build
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build
echo; echo "==> build/flutter_vita_t1.vpk"
