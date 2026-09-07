#!/usr/bin/env bash
# Bless an engine artifact as the one the receiver links against.
#
#   ./tools/bless-receiver-engine.sh [--engine DIR] [--reason "..."]
#
# ADR-0016 decision 2. The receiver is the tool used to deploy a fix, so it must
# not link the engine that fix is fixing: an engine change that breaks an app
# would otherwise break the only way to replace that app. The pin is bumped by
# running this, deliberately, and never as a side effect of a rebuild.
#
# What it does is a copy and a receipt. The blessed tree is out/artifacts/
# receiver-engine/, which is gitignored -- what is committed is receiver/
# engine-pin.txt, recording exactly which engine that tree is supposed to be.
# tools/build-receiver.sh checks one against the other and refuses a mismatch,
# so a blessed tree that quietly drifts is a build error rather than a subtle
# runtime difference between the receiver and everything else.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

FLUTTER_PIN="${FLUTTER_VITA_PIN:-$(grep -m1 -oE '3\.[0-9]+\.[0-9]+' "$ROOT/VERSIONS.md" || echo 3.44.8)}"
SRC="$ROOT/out/artifacts/flutter-engine-vita-$FLUTTER_PIN"
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

MANIFEST="$SRC/MANIFEST.txt"
key() { grep -m1 "^$1 " "$MANIFEST" | awk '{print $2}'; }

echo "==> hashing $(du -h "$LIB" | cut -f1) engine archive"
SHA="$(shasum -a 256 "$LIB" | cut -d' ' -f1)"

if [ -f "$PIN" ]; then
  OLD="$(grep -m1 '^archive_sha256 ' "$PIN" | awk '{print $2}' || true)"
  if [ "$OLD" = "$SHA" ]; then
    echo "    already blessed; refreshing the tree only"
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

cat > "$PIN" <<EOF
# The engine the receiver links against -- ADR-0016 decision 2.
#
# Written by tools/bless-receiver-engine.sh; read by tools/build-receiver.sh, which
# refuses to build if out/artifacts/receiver-engine does not match. Bump it by
# running the bless script, never by editing this file: the sha is what makes
# the check mean anything.

flutter          $(key flutter)
framework_rev    $(key framework_rev)
engine           $(key engine)
dart             $(key dart)
archive_sha256   $SHA
blessed_at       $(date -u +%Y-%m-%dT%H:%M:%SZ)
blessed_from     ${SRC#"$ROOT/"}
reason           ${REASON:-no reason recorded}
EOF

echo
sed -n '/^flutter /,$p' "$PIN"
echo
echo "==> ${PIN#"$ROOT/"}"
