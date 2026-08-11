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
# CLEANDEAD=1 drops objects the build graph no longer produces.
#
# The link below globs ~2700 objects out of the tree rather than naming them,
# so an orphan is not ignored -- it is linked. Swapping txt's platform.cc for
# platform_vita.cc left the old object behind and the link failed with
# "multiple definition of txt::GetDefaultFontManager", which reads like a
# source bug and is a stale artifact.
#
# **Opt-in, not automatic**, and that is a correction. It ran on every build
# for exactly one iteration, and the next build went full -- 3058 edges
# including host-toolchain flatbuffers, over 30 minutes, for an edit to two
# .cc files. Guarding every build against something that has happened once, at
# the cost of the scarcest resource in this project, is a bad trade. Pass it
# when you remove or rename a source; otherwise leave it alone.
if [ -n "${CLEANDEAD:-}" ]; then
  ninja -C "$ENGINE_OUT" -t cleandead
fi

ninja -C "$ENGINE_OUT" flutter/shell/platform/embedder:vita_embedder

echo "==> gen_snapshot"
[ -x "$GEN_SNAPSHOT" ] || {
  echo "No gen_snapshot at $GEN_SNAPSHOT"
  echo "  ninja -C $ENGINE_OUT flutter/lib/snapshot:create_arm_gen_snapshot"
  exit 1
}
[ -f "$APP_DILL" ] || { echo "No app kernel at $APP_DILL"; exit 1; }

# Skip when the kernel has not changed.
#
# gen_snapshot emits a 5.3 MB assembly file and the assembler then chews
# through it, on every build, whether or not the Dart side moved. Almost every
# iteration in this project is an engine or embedder change with the same
# .dill, so this was pure repeated cost. The stamp records the hash of the
# input that produced the current snapshot.S; anything else -- a missing
# snapshot.S, a different kernel, a stamp from an interrupted run -- falls
# through and regenerates.
DILL_HASH="$(shasum -a 1 "$APP_DILL" | cut -d' ' -f1)"
STAMP="$HERE/out/snapshot.S.dill-sha1"
if [ -f "$HERE/out/snapshot.S" ] && [ -f "$STAMP" ] &&
   [ "$(cat "$STAMP")" = "$DILL_HASH" ]; then
  echo "    unchanged kernel, reusing snapshot.S"
else
"$GEN_SNAPSHOT" \
  --snapshot_kind=app-aot-assembly \
  --assembly="$HERE/out/snapshot.S" \
  "$APP_DILL"
echo "    snapshot.S $(stat -f%z "$HERE/out/snapshot.S") B"
  # Written only after gen_snapshot succeeded, so an interrupted run
  # regenerates next time rather than being remembered as done.
  echo "$DILL_HASH" > "$STAMP"
fi

echo "==> link and package"
# Configure once and reuse. `rm -rf build` re-ran the whole CMake configure and
# re-globbed 2700 objects on every iteration to protect against a stale cache;
# the cache is keyed on inputs that do not move, and the object glob is
# re-evaluated at configure time anyway. Blow it away by hand if it misbehaves.
cmake -S "$HERE" -B "$HERE/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$HERE/build" -j"$(sysctl -n hw.ncpu)"

VPK="$HERE/build/flutter_vita_m3.vpk"
[ -f "$VPK" ] || { echo "No vpk produced"; exit 1; }
echo "==> $VPK  $(stat -f%z "$VPK") B"

echo "==> .text budget"
arm-vita-eabi-size -A "$HERE/build/flutter_vita_m3" | grep -E "^\.text|^\.rodata|^\.bss"
