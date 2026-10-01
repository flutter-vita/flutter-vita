#!/usr/bin/env bash
# Pin an engine artifact as the one the receiver links against.
#
#   ./tools/pin-receiver-engine.sh [--engine DIR] [--reason "..."]
#
# ADR-0016 decision 2. The receiver is the tool used to deploy a fix, so it must
# not link the engine that fix is fixing: an engine change that breaks an app
# would otherwise break the only way to replace that app. The pin is bumped by
# running this, deliberately, and never as a side effect of a rebuild.
#
# What it does is a copy and a receipt. The pinned tree is out/artifacts/
# receiver-engine/, which is gitignored -- what is committed is receiver/
# engine-pin.txt, recording exactly which engine that tree is supposed to be.
# tools/build-receiver.sh checks one against the other and refuses a mismatch,
# so a pinned tree that quietly drifts is a build error rather than a subtle
# runtime difference between the receiver and everything else.
#
# The embedder (embedder, the flutter-vita-embedder submodule) is
# pinned with it, as embedder/ inside the same tree: it is compiled into
# every app, so an embedder change is as able to break the receiver as an
# engine change, and the two are one unit as far as the receiver is
# concerned.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# The Flutter version, from versions.json (the one machine-read pin).
FLUTTER_PIN="${FLUTTER_VITA_PIN:-$(sed -n 's/^[[:space:]]*"flutter":[[:space:]]*"\([0-9.]*\)".*/\1/p' "$ROOT/versions.json" 2>/dev/null | head -1)}"
[ -n "$FLUTTER_PIN" ] || FLUTTER_PIN=3.44.8
SRC="$ROOT/out/artifacts/flutter-engine-vita-$FLUTTER_PIN"
EMBEDDER="${FLUTTER_VITA_EMBEDDER:-$ROOT/embedder}"
DEST="$ROOT/out/artifacts/receiver-engine"
PIN="$ROOT/receiver/engine-pin.txt"
REASON=""

while [ $# -gt 0 ]; do
  case "$1" in
    --engine) SRC="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -d "$SRC" ] || { echo "No engine at $SRC" >&2; exit 1; }
LIB="$SRC/lib/libflutter_engine_vita.a"
[ -f "$LIB" ] || { echo "No engine archive at $LIB" >&2; exit 1; }
[ -f "$EMBEDDER/CMakeLists.txt" ] || {
  echo "No embedder at $EMBEDDER. It is a submodule: git submodule update --init" >&2
  exit 1
}

# One hash over the files an app compiles, so the pinned copy can be checked
# the same way as the archive. The generator, its font and the docs stay out.
embedder_sha() {
  (cd "$1" && find CMakeLists.txt src include -type f | LC_ALL=C sort \
     | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
}

MANIFEST="$SRC/MANIFEST.txt"
key() { grep -m1 "^$1 " "$MANIFEST" | awk '{print $2}'; }

echo "==> hashing $(du -h "$LIB" | cut -f1) engine archive"
SHA="$(shasum -a 256 "$LIB" | cut -d' ' -f1)"
EMBEDDER_SHA="$(embedder_sha "$EMBEDDER")"
EMBEDDER_REV="$(git -C "$EMBEDDER" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$EMBEDDER" status --porcelain -- CMakeLists.txt src include 2>/dev/null)" ]; then
  EMBEDDER_REV="$EMBEDDER_REV-dirty"
fi

if [ -f "$PIN" ]; then
  OLD="$(grep -m1 '^archive_sha256 ' "$PIN" | awk '{print $2}' || true)"
  if [ "$OLD" = "$SHA" ]; then
    echo "    already pinned; refreshing the tree only"
  else
    echo "    bumping the pin"
    echo "      was $OLD"
    echo "      now $SHA"
  fi
fi

echo "==> copying to $DEST"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$SRC" "$DEST"
mkdir -p "$DEST/embedder"
cp "$EMBEDDER/CMakeLists.txt" "$DEST/embedder/"
cp -R "$EMBEDDER/src" "$EMBEDDER/include" "$DEST/embedder/"

cat > "$PIN" <<EOF
# The engine the receiver links against -- ADR-0016 decision 2.
#
# Written by tools/pin-receiver-engine.sh; read by tools/build-receiver.sh, which
# refuses to build if out/artifacts/receiver-engine does not match. Bump it by
# running the pin script, never by editing this file: the sha is what makes
# the check mean anything.

flutter          $(key flutter)
framework_rev    $(key framework_rev)
engine           $(key engine)
dart             $(key dart)
archive_sha256   $SHA
embedder         $EMBEDDER_REV
embedder_sha256  $EMBEDDER_SHA
pinned_at        $(date -u +%Y-%m-%dT%H:%M:%SZ)
pinned_from      ${SRC#"$ROOT/"}
reason           ${REASON:-no reason recorded}
EOF

echo
sed -n '/^flutter /,$p' "$PIN"
echo
echo "==> ${PIN#"$ROOT/"}"
