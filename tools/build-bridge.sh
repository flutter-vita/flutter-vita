#!/usr/bin/env bash
# Build the bridge into a .vpk.
#
#   ./tools/build-bridge.sh                 the real bridge: FVTA00001, port 1341
#   ./tools/build-bridge.sh --scratch       a second one: FVTA00004, port 1342
#
#   --title-id ID   override the slot
#   --port N        override the port
#
# The bridge is an ordinary Flutter-Vita application -- same template, same
# build script, same snapshot -- plus one translation unit that owns the port
# and the commands, and minus the crash supervisor.
#
# --scratch exists because replacing FVTA00001 in place replaces the only way to
# install anything. A scratch bridge installs beside the working one, on its
# own port, and is driven with `./tools/deploy.sh --bridge-port 1342`.
#
# tools/install-vpk.sh registers the id as part of installing, so the slot does
# not have to exist first.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

ENGINE="$ROOT/out/artifacts/bridge-engine"
PIN="$ROOT/bridge/engine-pin.txt"
# FVTA00001 since 2026-08-31. It was FVTA00003 for as long as the bridge had
# to be installed by VitaShell, which meant living in whichever slot someone
# had already created by hand. The bridge registers its own title id now, so
# the number is a choice rather than an inheritance.
TITLE_ID="FVTA00001"
PORT=1341
NAME="Flutter Bridge"

while [ $# -gt 0 ]; do
  case "$1" in
    --scratch)  TITLE_ID="FVTA00004"; PORT=1342; NAME="Flutter Bridge (scratch)"; shift ;;
    --title-id) TITLE_ID="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    -h|--help)  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------- the pin check
#
# ADR-0016 decision 2: the bridge links a pinned engine, not the one under
# development, so that a broken engine can cost you your app and never your
# ability to replace it. The sha is what makes that mean anything -- without
# it "the pinned tree" is just a directory someone could have rsynced over.
[ -f "$PIN" ] || {
  echo "No $PIN. Run tools/pin-bridge-engine.sh." >&2; exit 1; }

WANT="$(grep -m1 '^archive_sha256 ' "$PIN" | awk '{print $2}')"
WANT_EMBEDDER="$(grep -m1 '^embedder_sha256 ' "$PIN" | awk '{print $2}')"

embedder_sha() {
  (cd "$1" && find CMakeLists.txt src include -type f | LC_ALL=C sort \
     | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
}

# The pinned tree is gitignored, so a fresh clone has none. When the engine
# `flutter-vita precache` downloaded and the embedder submodule are exactly
# what the pin names, the tree is a copy of the two and nothing has to be
# decided: copy them, and leave the pin file as it is. Anything else is a real
# bump, which stays a deliberate run of the pin script.
if [ ! -d "$ENGINE" ]; then
  FROM="$ROOT/out/artifacts/flutter-engine-vita-$(grep -m1 '^flutter ' "$PIN" | awk '{print $2}')"
  EMB="$ROOT/embedder"
  if [ -f "$FROM/lib/libflutter_engine_vita.a" ] && [ -f "$EMB/CMakeLists.txt" ] &&
     [ "$(shasum -a 256 "$FROM/lib/libflutter_engine_vita.a" | cut -d' ' -f1)" = "$WANT" ] &&
     [ "$(embedder_sha "$EMB")" = "$WANT_EMBEDDER" ]; then
    echo "==> restoring the pinned engine from ${FROM#"$ROOT/"} and embedder/ (both match the pin)"
    cp -R "$FROM" "$ENGINE"
    mkdir -p "$ENGINE/embedder"
    cp "$EMB/CMakeLists.txt" "$ENGINE/embedder/"
    cp -R "$EMB/src" "$EMB/include" "$ENGINE/embedder/"
  else
    echo "No pinned engine at $ENGINE, and nothing here matches the pin:" >&2
    echo "  ${FROM#"$ROOT/"} and embedder/ must hash to what $PIN names." >&2
    echo "  Run 'flutter-vita precache' and 'git submodule update --init', or" >&2
    echo "  bump the pin on purpose: ./tools/pin-bridge-engine.sh --reason '...'" >&2
    exit 1
  fi
fi
HAVE="$(shasum -a 256 "$ENGINE/lib/libflutter_engine_vita.a" | cut -d' ' -f1)"
if [ "$WANT" != "$HAVE" ]; then
  echo "!! the pinned engine does not match the pin." >&2
  echo "   $PIN says  $WANT" >&2
  echo "   $ENGINE has $HAVE" >&2
  echo >&2
  echo "   Either the tree was overwritten, or the pin should be bumped." >&2
  echo "   Bumping is deliberate: ./tools/pin-bridge-engine.sh --reason '...'" >&2
  exit 1
fi
# The embedder pinned beside it, checked the same way (see the pin script).
[ -d "$ENGINE/embedder" ] || {
  echo "!! the pinned tree has no embedder/. Re-pin: ./tools/pin-bridge-engine.sh --reason '...'" >&2
  exit 1
}
HAVE_EMBEDDER="$(embedder_sha "$ENGINE/embedder")"
if [ "$WANT_EMBEDDER" != "$HAVE_EMBEDDER" ]; then
  echo "!! the pinned embedder does not match the pin." >&2
  echo "   $PIN says  $WANT_EMBEDDER" >&2
  echo "   $ENGINE/embedder has $HAVE_EMBEDDER" >&2
  echo "   Bumping is deliberate: ./tools/pin-bridge-engine.sh --reason '...'" >&2
  exit 1
fi
echo "==> pinned engine $(grep -m1 '^flutter ' "$PIN" | awk '{print $2}') ($(echo "$HAVE" | cut -c1-12)), embedder $(grep -m1 '^embedder ' "$PIN" | awk '{print $2}')"

# --------------------------------------------------------------- build_info
#
# Generated rather than committed: three of the four values are properties of
# the engine artifact, and a committed copy is a copy that can disagree with
# the thing it describes. The fourth is the bridge's own version, which comes
# from its pubspec.
key() { grep -m1 "^$1 " "$PIN" | awk '{print $2}'; }
VERSION="$(grep -m1 '^version:' "$ROOT/bridge/app/pubspec.yaml" | sed 's/^version: *//')"
# The tool's release, from versions.json; and git's description of this
# checkout when it has moved past the tag (3.44.8_0.1.0-12-gcb878d8), so a
# bridge built between releases says which build it is.
TOOL_RELEASE="$(sed -n 's/^[[:space:]]*"release":[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/versions.json" 2>/dev/null | head -1)"
TOOL_BUILD="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || true)"
[ -n "$TOOL_BUILD" ] || TOOL_BUILD="$TOOL_RELEASE"
cat > "$ROOT/bridge/app/lib/build_info.dart" <<EOF
// GENERATED by tools/build-bridge.sh. Do not edit, and do not commit.
//
// What the screen's bottom line reports. The engine values describe the
// *pinned* engine (ADR-0016 decision 2), which is deliberately not the
// engine in the tree.
const String kBridgeVersion = '$VERSION';
const String kToolRelease = '$TOOL_RELEASE';
const String kToolBuild = '$TOOL_BUILD';
const String kFlutterVersion = '$(key flutter)';
const String kEngineRevision = '$(key engine)';
const String kFrameworkRevision = '$(key framework_rev)';
EOF

# The installer (vpk.c) inflates the vpk with VitaSDK's zlib. Its libz.a comes
# from the vdpm package, not from VitaSDK's base archive that tools/vitasdk.sh
# installs; an app build never needs it.
VITASDK="$("$HERE/vitasdk.sh")" || exit 1
[ -f "$VITASDK/arm-vita-eabi/lib/libz.a" ] || {
  echo "!! the bridge needs VitaSDK's zlib, and $VITASDK has no libz.a." >&2
  echo "   Run: $VITASDK/bin/vdpm install zlib" >&2
  exit 1
}

echo "==> $NAME [$TITLE_ID] on port $PORT"
exec "$HERE/build-vita-app.sh" "$ROOT/bridge/app" \
  --engine "$ENGINE" \
  --embedder "$ENGINE/embedder" \
  --title-id "$TITLE_ID" \
  --name "$NAME" \
  --extra-source "$ROOT/bridge/src/bridge_dev.c" \
  --extra-source "$ROOT/bridge/src/vpk.c" \
  --extra-lib z \
  --no-supervisor \
  --define "BRIDGE_PORT=$PORT" \
  --define "SELF_TITLEID=\"$TITLE_ID\"" \
  --define "TARGET_TITLEID=\"FVTA00002\""
