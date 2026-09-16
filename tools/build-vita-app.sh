#!/usr/bin/env bash
# Build any Flutter app into a Vita .vpk: Dart to kernel, kernel to armv7
# assembly, assembly plus engine to an ELF, ELF to a signed .vpk.
#
#   ./tools/build-vita-app.sh <app-dir> [options]
#
#   --title-id ID     nine characters; see resolution order below
#   --name "Name"     LiveArea display name
#   --livearea DIR    icon0.png, bg0.png, startup.png, template.xml; default
#                     the template's set (docs/release-app.md)
#   --engine DIR      unpacked flutter-engine-vita-<version>/
#   --flutter DIR     Flutter SDK, default $HOME/fvm/versions/<pinned>
#   --out DIR         default <app-dir>/build/vita
#   --entry-point F   default lib/main.dart; real apps use flavors
#   --extra-source F  extra C/C++ compiled into the app; repeatable
#   --no-supervisor   leave out eboot2.bin (the receiver; ADR-0016)
#   --define K=V      preprocessor define for the extra sources; repeatable
#   --link-option F   extra linker flag, for measurement builds; repeatable
#   --debug           the default: dev server on 1339, the debug strip
#                     (L+R+SELECT), the bailout to the receiver
#   --release         none of those; what a shipped app is
#
# The app configures itself in pubspec.yaml:
#
#   vita:
#     title_id: FVTA00003        # optional; derived from the package name
#     hardware_checks: true      # optional; the gallery's Hardware tab (hardware.c)
#     name: My App               # optional; defaults to the package name
#     livearea: vita/livearea    # optional; the app's own art, relative to the app
#
# Title id resolution: --title-id, then pubspec vita.title_id, then a value
# derived from the package name if a vita: block exists, then FVTA00002 -- the
# slot the dev receiver installs into.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# The CLI resolves these and passes them in, because an installed flutter-vita
# has no repo to derive them from -- see ADR-0015. The $ROOT fallbacks keep a
# source checkout working exactly as before, which is also what makes this
# script still runnable by hand.
FLUTTER_PIN="${FLUTTER_VITA_PIN:-$(grep -m1 -oE '3\.[0-9]+\.[0-9]+' "$ROOT/VERSIONS.md" || echo 3.44.8)}"
APP_DIR=""
TITLE_ID=""
APP_NAME=""
ENGINE_DIR="${FLUTTER_VITA_ENGINE:-$ROOT/out/artifacts/flutter-engine-vita-$FLUTTER_PIN}"
FLUTTER_DIR="$HOME/fvm/versions/$FLUTTER_PIN"
OUT_DIR=""
# Flavors are the norm outside sample apps: the entry point is lib/main_prod.dart
# or lib/main_dev.dart and lib/main.dart does not exist. Hard-coding it made the
# test apps unbuildable for an app whose only sin was shipping three build flavors.
ENTRY_POINT="lib/main.dart"
# Product-specific C, and whether to ship the crash supervisor. Both exist for
# the receiver (ADR-0016), which is an ordinary app from this same script plus a
# translation unit that owns its port and its commands.
EXTRA_SOURCES=""
NO_SUPERVISOR="OFF"
EXTRA_DEFINES=""
EXTRA_LINK_OPTIONS=
# Debug and release are the same pipeline with a different final link. Release
# drops what serves the developer: the dev server's socket, the debug strip,
# the bailout, and the crash supervisor. See templates/vita-app/release.c.
# Debug is the default, and --debug says so out loud.
#
# Not a Dart-level distinction. Both modes compile the kernel with
# -Ddart.vm.product=true and the bundle with --release, because nothing here has
# ever built a JIT app.
RELEASE="OFF"

while [ $# -gt 0 ]; do
  case "$1" in
    --title-id) TITLE_ID="$2"; shift 2 ;;
    --name)     APP_NAME="$2"; shift 2 ;;
    --livearea) LIVEAREA_DIR="$(cd "$2" && pwd)"; shift 2 ;;
    --engine)   ENGINE_DIR="$2"; shift 2 ;;
    --flutter)  FLUTTER_DIR="$2"; shift 2 ;;
    --out)      OUT_DIR="$2"; shift 2 ;;
    --entry-point) ENTRY_POINT="$2"; shift 2 ;;
    --extra-source)
      src="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
      [ -f "$src" ] || { echo "no such file: $2" >&2; exit 1; }
      EXTRA_SOURCES="${EXTRA_SOURCES:+$EXTRA_SOURCES;}$src"; shift 2 ;;
    --no-supervisor) NO_SUPERVISOR="ON"; shift ;;
    # Implies --no-supervisor. The supervisor's whole job is relaunching the
    # development receiver when the app dies, and a release build is one that has
    # no receiver to relaunch.
    --release)  RELEASE="ON"; NO_SUPERVISOR="ON"; shift ;;
    --debug)    RELEASE="OFF"; shift ;;
    --define) EXTRA_DEFINES="${EXTRA_DEFINES:+$EXTRA_DEFINES;}$2"; shift 2 ;;
    # For measurement builds. experiments/gl-usage needs
    # -Wl,--wrap=vglGetProcAddress and there is no other way in.
    --link-option) EXTRA_LINK_OPTIONS="${EXTRA_LINK_OPTIONS:+$EXTRA_LINK_OPTIONS;}$2"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; exit 2 ;;
    *)          APP_DIR="$1"; shift ;;
  esac
done

[ -n "$APP_DIR" ] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
APP_DIR="$(cd "$APP_DIR" && pwd)"
[ -f "$APP_DIR/pubspec.yaml" ] || { echo "No pubspec.yaml in $APP_DIR" >&2; exit 1; }
[ -f "$APP_DIR/$ENTRY_POINT" ] || { echo "No $ENTRY_POINT in $APP_DIR" >&2; exit 1; }

: "${VITASDK:?Define VITASDK. See docs/dev-environment.md}"
export PATH="$VITASDK/bin:$PATH"

OUT_DIR="${OUT_DIR:-$APP_DIR/build/vita}"
# Absolute, because the paths derived from it are handed to cmake, which runs
# with its own working directory. A relative --out produced "Cannot find source
# file: <out>/snapshot.S" from a run that had just written exactly that file.
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
SDK="$FLUTTER_DIR/bin/cache/dart-sdk"
# Prefer the engine artifact's own platform dill over the Flutter cache's.
#
# The cache's is stock Flutter's, and its dart:io does not declare the natives
# this port adds, so an app compiled against it fails to resolve them at snapshot
# time. See package-engine.sh. The cache stays as the fallback for an older
# artifact that predates this.
PATCHED_SDK="$FLUTTER_DIR/bin/cache/artifacts/engine/common/flutter_patched_sdk_product"
if [ -f "$ENGINE_DIR/flutter_patched_sdk/platform_strong.dill" ]; then
  PATCHED_SDK="$ENGINE_DIR/flutter_patched_sdk"
fi

# ---------------------------------------------------------------- vita: block
#
# The app's own configuration lives in the app, not in flags nobody can commit
# (ADR-0009). Flat because this parser and the Dart one must never disagree, and
# a flat block is the largest shape both read identically:
#
#   vita:
#     title_id: FVTA00003
#     name: My App
#
# `|| true` is load-bearing: grep exits 1 on no match and `set -o pipefail`
# propagates that, so without it a pubspec lacking `title_id` kills the script.
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
# `hardware_checks: true` compiles templates/vita-app/hardware.c and links the
# camera, motion and audio stubs; the gallery's Hardware tab needs it and no
# other app does.
HARDWARE_CHECKS="OFF"
[ "$(vita_key hardware_checks)" = "true" ] && HARDWARE_CHECKS="ON"
# The app's own LiveArea art, relative to the app; the template's set otherwise.
if [ -z "${LIVEAREA_DIR:-}" ] && [ -n "$(vita_key livearea)" ]; then
  LIVEAREA_DIR="$(cd "$APP_DIR/$(vita_key livearea)" && pwd)"
fi

# The package name and the display name are different things and only one of
# them is safe in a path. `vita.name: Counter Demo` is correct as a LiveArea
# title and produces "Counter Demo.vpk" if it also names the file.
PKG_NAME="$(grep -m1 '^name:' "$APP_DIR/pubspec.yaml" | sed 's/^name: *//' | tr -d "\"'")"

# Derive a title id from the package name when the app opted in but did not pick
# one. Deterministic, so the same app always lands in the same slot and
# reinstalling replaces rather than accumulates.
#
# Only for apps with a vita: block. Without one the default stays FVTA00002, the
# slot the dev receiver installs into.
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
# The app's own, though Sony's sample gives its background app a distinct id.
# That sample is installed by the promoter, which registers every title in the
# package; ours is side-loaded into a directory the receiver can write, so the
# only id the shell knows is the app's.
#
# Measured: with a distinct id, sceBgAppUtilStartBgApp returned 0 and the shell
# then put "could not find app" on the panel and never ran eboot2.bin.
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
# different revision builds and packages without complaint, then misbehaves at
# runtime in ways that look like anything but a version skew. So this refuses
# rather than warns.
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
echo "==> $APP_NAME [$TITLE_ID]$([ "$RELEASE" = ON ] && echo '  release')"

echo "==> flutter build bundle"
( cd "$APP_DIR" && "$FLUTTER_DIR/bin/flutter" pub get >/dev/null &&
  "$FLUTTER_DIR/bin/flutter" build bundle --release -t "$ENTRY_POINT" >/dev/null )
ASSETS="$APP_DIR/build/flutter_assets"
[ -d "$ASSETS" ] || { echo "No bundle at $ASSETS" >&2; exit 1; }

# Where pub actually put the package config.
#
# Not always $APP_DIR/.dart_tool. A pub workspace resolves once for the whole
# tree and writes a single package_config.json at the root, leaving each member's
# .dart_tool without one. flutter/samples is laid out that way.
#
# The failure looks like anything but a missing file: frontend_server falls back
# to a relative .dart_tool, finds nothing, and reports `Not found:
# package:flutter/material.dart` on every import -- 1,900 errors that read as a
# broken SDK, printed to a stdout this script sends to /dev/null.
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

# The app's Vita plugins: every resolved package with a vita/plugin.cmake
# (ADR-0009, templates/vita-app/fvita_plugin.h). Their C is compiled into
# this app; the list goes to the template as VITA_PLUGINS.
VITA_PLUGINS="$(python3 - "$PACKAGES" <<'PY'
import json, os, sys, urllib.parse
cfg = json.load(open(sys.argv[1]))
base = os.path.dirname(sys.argv[1])
found = []
for pkg in cfg.get("packages", []):
    uri = pkg.get("rootUri", "")
    if uri.startswith("file://"):
        root = urllib.parse.unquote(uri[len("file://"):])
    else:
        root = os.path.normpath(os.path.join(base, uri))
    p = os.path.join(root, "vita", "plugin.cmake")
    if os.path.isfile(p):
        found.append(p)
print(";".join(found))
PY
)"
if [ -n "$VITA_PLUGINS" ]; then
  echo "==> vita plugins"
  echo "$VITA_PLUGINS" | tr ';' '\n' | sed 's|/vita/plugin.cmake$||; s|.*/||; s|^|    |'
fi

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
cmake -S "${FLUTTER_VITA_TEMPLATE:-$ROOT/templates/vita-app}" -B "$OUT_DIR/cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DAPP_NAME="$APP_NAME" \
  -DTITLE_ID="$TITLE_ID" \
  -DSUPERVISOR_TITLE_ID="$SUPERVISOR_TITLE_ID" \
  -DSNAPSHOT_S="$OUT_DIR/snapshot.S" \
  -DFLUTTER_ASSETS="$ASSETS" \
  -DENGINE_DIR="$ENGINE_DIR" \
  -DEXTRA_SOURCES="$EXTRA_SOURCES" \
  -DNO_SUPERVISOR="$NO_SUPERVISOR" \
  -DRELEASE="$RELEASE" \
  -DEXTRA_DEFINES="$EXTRA_DEFINES" \
  -DEXTRA_LINK_OPTIONS="$EXTRA_LINK_OPTIONS" \
  -DHARDWARE_CHECKS="$HARDWARE_CHECKS" \
  -DVITA_PLUGINS="$VITA_PLUGINS" \
  -DGLES2_DIR="$ROOT/gles2" \
  ${LIVEAREA_DIR:+-DLIVEAREA_DIR="$LIVEAREA_DIR"} \
  -DTOOLS_DIR="$ROOT/tools" >/dev/null
cmake --build "$OUT_DIR/cmake" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

VPK="$(find "$OUT_DIR/cmake" -name '*.vpk' | head -1)"
[ -n "$VPK" ] || { echo "No .vpk produced" >&2; exit 1; }
cp "$VPK" "$OUT_DIR/$PKG_NAME.vpk"

echo
echo "==> $OUT_DIR/$PKG_NAME.vpk  $(du -h "$OUT_DIR/$PKG_NAME.vpk" | cut -f1)"
arm-vita-eabi-size -A "$OUT_DIR/cmake/flutter_vita_app" | grep -E "^\.text|^\.rodata|^\.bss"
