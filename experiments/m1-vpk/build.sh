#!/usr/bin/env bash
# Build the M1 vpk: Dart AOT running on the Vita.
#
# Prerequisites, in order:
#   1. ninja -C third_party/sdk/out/vita obj/runtime/libdart_aotruntime_product.a
#   2. ninja -C third_party/sdk/out/host gen_snapshot_product_vita_arm
#   3. experiments/b1-aot-snapshot/build.sh     (Dart -> kernel)
#   4. experiments/m1-snapshot/build.sh         (kernel -> vita armv7 snapshot)
#   5. experiments/m1-snapshot/extract-blobs.sh (snapshot -> four blobs)
set -euo pipefail
cd "$(dirname "$0")"
: "${VITASDK:=$HOME/vitasdk}"; export VITASDK; export PATH="$VITASDK/bin:$PATH"
export CMAKE_POLICY_VERSION_MINIMUM=3.5
[[ "${1:-}" == "clean" ]] && rm -rf build
[[ -f ../m1-snapshot/out/blobs/vm_snapshot_data.bin ]] || {
  echo "error: no blobs -- run ../m1-snapshot/extract-blobs.sh" >&2; exit 1; }
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
echo; echo "==> build/flutter_vita_m1.vpk"; unzip -l build/flutter_vita_m1.vpk
