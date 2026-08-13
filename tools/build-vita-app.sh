#!/usr/bin/env bash
# Build any Flutter app into a Vita .vpk.
#
#   ./tools/build-vita-app.sh <app-dir> [options]
#
#   --title-id ID     nine characters, default FVTA00002 (the dev loader's slot)
#   --name "Name"     LiveArea display name, default from pubspec
#   --engine DIR      unpacked flutter-engine-vita-<version>/
#   --flutter DIR     Flutter SDK, default $HOME/fvm/versions/<pinned>
#   --out DIR         default <app-dir>/build/vita
#
# This is the whole pipeline in one place: Dart to kernel, kernel to armv7
# assembly, assembly plus engine to an ELF, ELF to a signed .vpk. It is what a
# `flutter-vita build` command would call, written as a shell script first so
# the steps are legible before they are wrapped.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

FLUTTER_PIN="$(grep -m1 -oE '3\.[0-9]+\.[0-9]+' "$ROOT/VERSIONS.md" || echo 3.44.8)"
APP_DIR=""
TITLE_ID="FVTA00002"
APP_NAME=""
ENGINE_DIR="$ROOT/out/artifacts/flutter-engine-vita-$FLUTTER_PIN"
FLUTTER_DIR="$HOME/fvm/versions/$FLUTTER_PIN"
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --title-id) TITLE_ID="$2"; shift 2 ;;
    --name)     APP_NAME="$2"; shift 2 ;;
    --engine)   ENGINE_DIR="$2"; shift 2 ;;
    --flutter)  FLUTTER_DIR="$2"; shift 2 ;;
    --out)      OUT_DIR="$2"; shift 2 ;;
    -h|--help)  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; exit 2 ;;
    *)          APP_DIR="$1"; shift ;;
  esac
done

[ -n "$APP_DIR" ] || { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
APP_DIR="$(cd "$APP_DIR" && pwd)"
[ -f "$APP_DIR/pubspec.yaml" ] || { echo "No pubspec.yaml in $APP_DIR" >&2; exit 1; }

: "${VITASDK:?Define VITASDK. See docs/dev-environment.md}"
export PATH="$VITASDK/bin:$PATH"

OUT_DIR="${OUT_DIR:-$APP_DIR/build/vita}"
SDK="$FLUTTER_DIR/bin/cache/dart-sdk"
PATCHED_SDK="$FLUTTER_DIR/bin/cache/artifacts/engine/common/flutter_patched_sdk_product"

# Title IDs are exactly nine characters and the packer produces a broken .vpk
# rather than complaining, so check here where the message can be useful.
[ "${#TITLE_ID}" -eq 9 ] || { echo "TITLE_ID must be 9 characters, got '$TITLE_ID'" >&2; exit 1; }

[ -d "$ENGINE_DIR" ] || {
  echo "No engine at $ENGINE_DIR" >&2
  echo "  Unpack flutter-engine-vita-$FLUTTER_PIN.tar.gz, or run tools/package-engine.sh" >&2
  exit 1
}
[ -d "$PATCHED_SDK" ] || {
  echo "No flutter_patched_sdk_product at $PATCHED_SDK" >&2
  echo "  Run: $FLUTTER_DIR/bin/flutter precache" >&2
  exit 1
}

# gen_snapshot is a build-machine binary, so it is per host in the artifact.
HOST="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
GEN_SNAPSHOT="$ENGINE_DIR/host-$HOST/gen_snapshot_armv7"
[ -x "$GEN_SNAPSHOT" ] || {
  echo "No gen_snapshot for $HOST at $GEN_SNAPSHOT" >&2
  echo "  The artifact was built on a different host. Build one, or use that host." >&2
  exit 1
}

if [ -z "$APP_NAME" ]; then
  APP_NAME="$(grep -m1 '^name:' "$APP_DIR/pubspec.yaml" | sed 's/^name: *//' | tr -d '"'"'")"
fi

mkdir -p "$OUT_DIR"
echo "==> $APP_NAME [$TITLE_ID]"

echo "==> flutter build bundle"
( cd "$APP_DIR" && "$FLUTTER_DIR/bin/flutter" pub get >/dev/null &&
  "$FLUTTER_DIR/bin/flutter" build bundle --release >/dev/null )
ASSETS="$APP_DIR/build/flutter_assets"
[ -d "$ASSETS" ] || { echo "No bundle at $ASSETS" >&2; exit 1; }

# The kernel and the bundle must come from the same source tree. The asset
# manifest is looked up by keys the compiled code asks for, so a mismatched
# pair fails at runtime looking like an asset bug rather than a stale build.
echo "==> kernel"
"$SDK/bin/dartaotruntime" \
  "$SDK/bin/snapshots/frontend_server_aot.dart.snapshot" \
  --sdk-root "$PATCHED_SDK/" \
  --target=flutter \
  --aot --tfa \
  -Ddart.vm.product=true \
  --packages "$APP_DIR/.dart_tool/package_config.json" \
  --output-dill "$OUT_DIR/app.dill" \
  "$APP_DIR/lib/main.dart" >/dev/null
echo "    app.dill $(stat -f%z "$OUT_DIR/app.dill" 2>/dev/null || stat -c%s "$OUT_DIR/app.dill") B"

# Skipped when the kernel has not moved: this emits tens of megabytes of
# assembly and the assembler then has to chew through all of it, on every
# build, whether or not the Dart side changed.
echo "==> snapshot"
DILL_HASH="$(shasum -a 1 "$OUT_DIR/app.dill" | cut -d' ' -f1)"
STAMP="$OUT_DIR/snapshot.S.dill-sha1"
if [ -f "$OUT_DIR/snapshot.S" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$DILL_HASH" ]; then
  echo "    unchanged kernel, reusing snapshot.S"
else
  "$GEN_SNAPSHOT" \
    --snapshot_kind=app-aot-assembly \
    --assembly="$OUT_DIR/snapshot.S" \
    "$OUT_DIR/app.dill"
  echo "    snapshot.S $(stat -f%z "$OUT_DIR/snapshot.S" 2>/dev/null || stat -c%s "$OUT_DIR/snapshot.S") B"
  # Written only after success, so an interrupted run regenerates next time
  # rather than being remembered as done.
  echo "$DILL_HASH" > "$STAMP"
fi

echo "==> link and package"
cmake -S "$ROOT/templates/vita-app" -B "$OUT_DIR/cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DAPP_NAME="$APP_NAME" \
  -DTITLE_ID="$TITLE_ID" \
  -DSNAPSHOT_S="$OUT_DIR/snapshot.S" \
  -DFLUTTER_ASSETS="$ASSETS" \
  -DENGINE_DIR="$ENGINE_DIR" >/dev/null
cmake --build "$OUT_DIR/cmake" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

VPK="$(find "$OUT_DIR/cmake" -name '*.vpk' | head -1)"
[ -n "$VPK" ] || { echo "No .vpk produced" >&2; exit 1; }
cp "$VPK" "$OUT_DIR/$APP_NAME.vpk"

echo
echo "==> $OUT_DIR/$APP_NAME.vpk  $(du -h "$OUT_DIR/$APP_NAME.vpk" | cut -f1)"
arm-vita-eabi-size -A "$OUT_DIR/cmake/flutter_vita_app" | grep -E "^\.text|^\.rodata|^\.bss"
