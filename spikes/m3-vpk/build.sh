#!/usr/bin/env bash
# Build the Flutter Vita .vpk: snapshot, then link, then package.
#
# Every step checks its own exit status. Phase 1 lost time three separate times
# to a step that failed while the pipeline reported success -- `ninja | grep`
# returning grep's status, a missing check, and a stale tool that ran after its
# rebuild had failed. Do not add a step without a check.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ENGINE_SRC="$ROOT/third_party/flutter/engine/src"
ENGINE_OUT="$ENGINE_SRC/out/vita_release"
GEN_SNAPSHOT="$ENGINE_OUT/clang_arm64/gen_snapshot_armv7"
APP_DILL="${APP_DILL:-$ROOT/spikes/b1-aot-snapshot/out/hello.dill}"

: "${VITASDK:?Define VITASDK. See docs/dev-environment.md}"
export PATH="$VITASDK/bin:$HOME/depot_tools:$PATH"

mkdir -p "$HERE/out"

echo "==> engine objects"
ninja -C "$ENGINE_OUT" flutter/shell/platform/embedder:vita_embedder

echo "==> gen_snapshot"
[ -x "$GEN_SNAPSHOT" ] || {
  echo "No gen_snapshot at $GEN_SNAPSHOT"
  echo "  ninja -C $ENGINE_OUT flutter/lib/snapshot:create_arm_gen_snapshot"
  exit 1
}
[ -f "$APP_DILL" ] || { echo "No app kernel at $APP_DILL"; exit 1; }

"$GEN_SNAPSHOT" \
  --snapshot_kind=app-aot-assembly \
  --assembly="$HERE/out/snapshot.S" \
  "$APP_DILL"
echo "    snapshot.S $(stat -f%z "$HERE/out/snapshot.S") B"

echo "==> link and package"
rm -rf "$HERE/build"
cmake -S "$HERE" -B "$HERE/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$HERE/build" -j"$(sysctl -n hw.ncpu)"

VPK="$HERE/build/flutter_vita_m3.vpk"
[ -f "$VPK" ] || { echo "No vpk produced"; exit 1; }
echo "==> $VPK  $(stat -f%z "$VPK") B"

echo "==> .text budget"
arm-vita-eabi-size -A "$HERE/build/flutter_vita_m3" | grep -E "^\.text|^\.rodata|^\.bss"
