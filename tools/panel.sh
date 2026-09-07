#!/usr/bin/env bash
# Drive the receiver's panel from here, and see what it drew.
#
#   ./tools/panel.sh tab crashes          switch tabs
#   ./tools/panel.sh select 0             open the first row of a list tab
#   ./tools/panel.sh back                 leave a detail view
#   ./tools/panel.sh shot out/panel.png   screenshot only
#
# Any command other than `shot` is followed by a screenshot, because the reason
# to press something remotely is to see the result.
#
# `tap x y` exists in the dev server and is refused in minimal mode, and that
# allowlist is compiled into the pinned engine -- so reaching the CRASHES tab
# from the host would mean re-pinning an engine to look at a layout. The panel
# reads one line out of ux0:data/flutter-vita/panel-request.txt instead.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOST="${VITA_HOST:-flutter-vita.local}"
PORT="${RECEIVER_PORT:-1341}"
REQ="ux0:data/flutter-vita/panel-request.txt"

[ $# -gt 0 ] || { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

if [ "$1" = "shot" ]; then
  OUT="${2:-$ROOT/out/panel.png}"
else
  LINE="$*"
  # The panel removes the file after reading it, so a request that is never
  # picked up is a panel that is not running -- which the screenshot shows.
  { printf 'put %s %s\n' "$(( ${#LINE} + 1 ))" "$REQ"; printf '%s\n' "$LINE"; } \
    | nc -w 30 "$HOST" "$PORT" | grep -q OK \
    || { echo "!! the receiver did not take '$LINE'" >&2; exit 1; }
  # Two poll ticks: one to read the request, one to rebuild and present.
  sleep 2
  OUT="$ROOT/out/panel.png"
fi

mkdir -p "$(dirname "$OUT")"
RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT
printf 'shot\n' | nc -w 120 "$HOST" "$PORT" > "$RAW"
[ -s "$RAW" ] || { echo "!! empty framebuffer" >&2; exit 1; }
"$HERE/rgba2png.py" "$RAW" "$OUT"
