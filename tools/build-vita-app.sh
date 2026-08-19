#!/usr/bin/env bash
# Build any Flutter app into a Vita .vpk.
#
#   ./tools/build-vita-app.sh <app-dir> [options]
#
#   --title-id ID     nine characters; see resolution order below
#   --name "Name"     LiveArea display name
#   --engine DIR      unpacked flutter-engine-vita-<version>/
#   --flutter DIR     Flutter SDK, default $HOME/fvm/versions/<pinned>
#   --out DIR         default <app-dir>/build/vita
#   --entry-point F   default lib/main.dart; real apps use flavors
#
# The app configures itself in pubspec.yaml, which is the opt-in surface:
#
#   vita:
#     title_id: FVTA00003        # optional; derived from the package name
#     name: My App               # optional; defaults to the package name
#
# Title id resolution: --title-id, then pubspec vita.title_id, then a value
# derived from the package name if a vita: block exists, then FVTA00002 -- the
# slot the dev loader installs into, which is what the counter app and the
# spikes want.
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
TITLE_ID=""
APP_NAME=""
ENGINE_DIR="$ROOT/out/artifacts/flutter-engine-vita-$FLUTTER_PIN"
FLUTTER_DIR="$HOME/fvm/versions/$FLUTTER_PIN"
OUT_DIR=""
# Flavors are the norm outside sample apps: the entry point is lib/main_prod.dart
# or lib/main_dev.dart and lib/main.dart does not exist. Hard-coding it made the
# corpus unbuildable for an app whose only sin was shipping three build flavors.
ENTRY_POINT="lib/main.dart"

while [ $# -gt 0 ]; do
  case "$1" in
    --title-id) TITLE_ID="$2"; shift 2 ;;
    --name)     APP_NAME="$2"; shift 2 ;;
    --engine)   ENGINE_DIR="$2"; shift 2 ;;
    --flutter)  FLUTTER_DIR="$2"; shift 2 ;;
    --out)      OUT_DIR="$2"; shift 2 ;;
    --entry-point) ENTRY_POINT="$2"; shift 2 ;;
    -h|--help)  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; exit 2 ;;
    *)          APP_DIR="$1"; shift ;;
  esac
done

[ -n "$APP_DIR" ] || { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
APP_DIR="$(cd "$APP_DIR" && pwd)"
[ -f "$APP_DIR/pubspec.yaml" ] || { echo "No pubspec.yaml in $APP_DIR" >&2; exit 1; }
[ -f "$APP_DIR/$ENTRY_POINT" ] || { echo "No $ENTRY_POINT in $APP_DIR" >&2; exit 1; }

: "${VITASDK:?Define VITASDK. See docs/dev-environment.md}"
export PATH="$VITASDK/bin:$PATH"

OUT_DIR="${OUT_DIR:-$APP_DIR/build/vita}"
SDK="$FLUTTER_DIR/bin/cache/dart-sdk"
PATCHED_SDK="$FLUTTER_DIR/bin/cache/artifacts/engine/common/flutter_patched_sdk_product"

# ---------------------------------------------------------------- vita: block
#
# The app's own configuration lives in the app, not in flags the developer has
# to remember and cannot commit (ADR-0009). The block is deliberately flat:
#
#   vita:
#     title_id: FVTA00003
#     name: My App
#
# Flat because this parser and the Dart one must never disagree, and a flat
# block is the largest shape both can read identically. Anything needing
# nesting should become a separate top-level key instead.
# `|| true` is load-bearing: an absent key is the normal case, but grep exits 1
# on no match and `set -o pipefail` propagates that, so without it a pubspec
# lacking `title_id` kills the script before it prints anything at all.
vita_key() {
  sed -n '/^vita:[[:space:]]*$/,/^[^[:space:]#]/p' "$APP_DIR/pubspec.yaml" \
    | grep -m1 "^[[:space:]]\+$1:" \
    | sed "s/^[[:space:]]*$1:[[:space:]]*//; s/[[:space:]]*$//" \
    | tr -d "\"'" || true
}
HAS_VITA_BLOCK=0
if grep -q '^vita:[[:space:]]*$' "$APP_DIR/pubspec.yaml"; then HAS_VITA_BLOCK=1; fi

# Precedence: explicit flag, then the app's own pubspec, then a default.
[ -n "$TITLE_ID" ]  || TITLE_ID="$(vita_key title_id)"
[ -n "$APP_NAME" ]  || APP_NAME="$(vita_key name)"

# The package name and the display name are different things and only one of
# them is safe in a path. `vita.name: Counter Demo` is correct as a LiveArea
# title and produces "Counter Demo.vpk" if it also names the file.
PKG_NAME="$(grep -m1 '^name:' "$APP_DIR/pubspec.yaml" | sed 's/^name: *//' | tr -d "\"'")"

# Derive a title id from the package name when the app opted in but did not
# pick one. Nine characters, four letters and five digits, deterministic -- the
# same app always lands in the same slot, so reinstalling replaces rather than
# accumulates, and two different apps essentially never collide.
#
# Only for apps with a vita: block. Without one, the default stays FVTA00002,
# which is the slot the dev loader installs into: deriving there would break the
# edit-run loop for the counter app and every spike.
derive_title_id() {
  local n l1 l2
  n=$((16#$(printf '%s' "$1" | shasum -a 1 | cut -c1-8)))
  l1=$((n / 26 % 26)); l2=$((n % 26))
  printf 'FV%b%b%05d' \
    "\\0$(printf '%o' $((65 + l1)))" \
    "\\0$(printf '%o' $((65 + l2)))" \
    "$((n / 676 % 100000))"
}
if [ -z "$TITLE_ID" ]; then
  if [ "$HAS_VITA_BLOCK" -eq 1 ]; then
    # Keyed on the package name, not the display name: renaming the LiveArea
    # tile should not move the app to a different install slot.
    TITLE_ID="$(derive_title_id "$PKG_NAME")"
  else
    TITLE_ID="FVTA00002"
  fi
fi

# Title IDs are exactly nine characters and the packer produces a broken .vpk
# rather than complaining, so check here where the message can be useful.
[ "${#TITLE_ID}" -eq 9 ] || { echo "TITLE_ID must be 9 characters, got '$TITLE_ID'" >&2; exit 1; }

# The title id that goes into sce_sys/param2.sfo, for eboot2.bin.
#
# The app's own, and that is deliberate even though Sony's sample and BGFTP both
# give their background app a *distinct* id. Both of those are installed by the
# promoter, which registers every title in the package; ours is side-loaded into
# an app directory the loader can write, so the only id the shell has a record
# of is the app's.
#
# Measured, not assumed. With a distinct id (FVSV00003) the call succeeded --
# sceBgAppUtilStartBgApp returned 0 -- and the shell then put "could not find
# app" on the panel and never ran eboot2.bin: it resolves the background app
# through its installed-titles database, and an id nothing installed is not in
# it.
SUPERVISOR_TITLE_ID="$TITLE_ID"

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

# ------------------------------------------------------- engine/SDK lockstep
#
# dart:ui and the engine are one source tree cut in half. A framework from a
# different revision links and builds and packages without complaint, then
# misbehaves at runtime in ways that look like anything but a version skew.
#
# So this refuses rather than warns. A warning here is worth nothing: it scrolls
# past in a build log and the failure it predicts arrives hours later wearing a
# different face.
MANIFEST="$ENGINE_DIR/MANIFEST.txt"
ENGINE_REV="$(grep -m1 '^framework_rev ' "$MANIFEST" 2>/dev/null | awk '{print $2}' || true)"
SDK_JSON="$FLUTTER_DIR/bin/cache/flutter.version.json"
SDK_REV="$(grep -o '"frameworkRevision": *"[^"]*"' "$SDK_JSON" 2>/dev/null | sed 's/.*: *"//; s/"$//' || true)"

if [ -z "$ENGINE_REV" ]; then
  # Artifacts built before framework_rev existed. Nothing to check against, and
  # guessing would defeat the point of checking.
  echo "!! $MANIFEST has no framework_rev — cannot verify SDK compatibility" >&2
  echo "   Repackage with tools/package-engine.sh to get a checkable artifact." >&2
elif [ -z "$SDK_REV" ]; then
  echo "!! no frameworkRevision in $SDK_JSON — cannot verify SDK compatibility" >&2
elif [ "$ENGINE_REV" != "$SDK_REV" ]; then
  echo "!! Flutter SDK does not match the engine artifact." >&2
  echo >&2
  echo "   engine artifact was built against  $ENGINE_REV" >&2
  echo "   your Flutter SDK is                $SDK_REV" >&2
  echo "   ($FLUTTER_DIR)" >&2
  echo >&2
  echo "   dart:ui and the engine are one source tree cut in half. Building" >&2
  echo "   across a mismatch produces a .vpk that links cleanly and then fails" >&2
  echo "   at runtime for reasons that will not look like this." >&2
  echo >&2
  echo "   Use the matching SDK, or an engine artifact built against yours." >&2
  exit 1
fi

# gen_snapshot is a build-machine binary, so it is per host in the artifact.
HOST="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
GEN_SNAPSHOT="$ENGINE_DIR/host-$HOST/gen_snapshot_armv7"
[ -x "$GEN_SNAPSHOT" ] || {
  echo "No gen_snapshot for $HOST at $GEN_SNAPSHOT" >&2
  echo "  The artifact was built on a different host. Build one, or use that host." >&2
  exit 1
}

[ -n "$APP_NAME" ] || APP_NAME="$PKG_NAME"

mkdir -p "$OUT_DIR"
echo "==> $APP_NAME [$TITLE_ID]"

echo "==> flutter build bundle"
( cd "$APP_DIR" && "$FLUTTER_DIR/bin/flutter" pub get >/dev/null &&
  "$FLUTTER_DIR/bin/flutter" build bundle --release -t "$ENTRY_POINT" >/dev/null )
ASSETS="$APP_DIR/build/flutter_assets"
[ -d "$ASSETS" ] || { echo "No bundle at $ASSETS" >&2; exit 1; }

# Where pub actually put the package config.
#
# Not always $APP_DIR/.dart_tool. A pub *workspace* -- one pubspec at the root
# with `workspace:` listing its members -- resolves once for the whole tree and
# writes a single package_config.json at the root, leaving each member's own
# .dart_tool without one. flutter/samples is laid out that way, so the control
# app of the corpus was the app that found this.
#
# The failure it produced is worth recording, because it looks like anything but
# a missing file: frontend_server falls back to a *relative* .dart_tool, finds
# nothing, and reports `Not found: package:flutter/material.dart` on every
# import in the program -- 1,900 errors that read as a broken SDK. It then exits
# 254 having printed all of that to stdout, which this script sends to
# /dev/null, so the visible result was an empty failure.
#
# So: walk up, the way Dart itself does, and say which one was used.
PACKAGES=""
probe="$APP_DIR"
while [ "$probe" != "/" ]; do
  if [ -f "$probe/.dart_tool/package_config.json" ]; then
    PACKAGES="$probe/.dart_tool/package_config.json"
    break
  fi
  probe="$(dirname "$probe")"
done
[ -n "$PACKAGES" ] || {
  echo "No .dart_tool/package_config.json at or above $APP_DIR." >&2
  echo "Run 'flutter pub get' there first." >&2
  exit 1
}
[ "$PACKAGES" = "$APP_DIR/.dart_tool/package_config.json" ] ||
  echo "    packages from $(dirname "$(dirname "$PACKAGES")")  (pub workspace)"

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
  --packages "$PACKAGES" \
  --output-dill "$OUT_DIR/app.dill" \
  "$APP_DIR/$ENTRY_POINT" >"$OUT_DIR/frontend_server.log" 2>&1 || {
    echo "Kernel compilation failed. Last errors:" >&2
    grep -v '^+file:' "$OUT_DIR/frontend_server.log" | head -30 >&2
    echo "    full output: $OUT_DIR/frontend_server.log" >&2
    exit 1
  }
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
  -DSUPERVISOR_TITLE_ID="$SUPERVISOR_TITLE_ID" \
  -DSNAPSHOT_S="$OUT_DIR/snapshot.S" \
  -DFLUTTER_ASSETS="$ASSETS" \
  -DENGINE_DIR="$ENGINE_DIR" >/dev/null
cmake --build "$OUT_DIR/cmake" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

VPK="$(find "$OUT_DIR/cmake" -name '*.vpk' | head -1)"
[ -n "$VPK" ] || { echo "No .vpk produced" >&2; exit 1; }
cp "$VPK" "$OUT_DIR/$PKG_NAME.vpk"

echo
echo "==> $OUT_DIR/$PKG_NAME.vpk  $(du -h "$OUT_DIR/$PKG_NAME.vpk" | cut -f1)"
arm-vita-eabi-size -A "$OUT_DIR/cmake/flutter_vita_app" | grep -E "^\.text|^\.rodata|^\.bss"
