#!/usr/bin/env bash
# Talk to the on-device dev server (src/devserver.c).
#
#   ./dev.sh ping              is it alive?
#   ./dev.sh log               print m1.log from the device
#   ./dev.sh push              upload build/…/eboot.bin
#   ./dev.sh run               push, then relaunch
#   ./dev.sh relaunch          relaunch whatever is installed
#   ./dev.sh exit              stop the dev server
#
# This exists because vitacompanion hangs SceShell on this device whatever ports
# it uses; the listener lives inside our own app instead. It is therefore only
# reachable while the app is running -- if it has crashed or been exited, launch
# Flutter Vita M1 from the LiveArea once and it is reachable again.
set -uo pipefail

VITA="${VITA_IP:-192.168.0.40}"
PORT="${VITA_DEV_PORT:-1339}"
HERE="$(cd "$(dirname "$0")" && pwd)"
EBOOT="$HERE/out/staging/eboot.bin"

# The Vita's wifi drops constantly, so every command retries rather than failing
# on the first refused connection.
wait_up() {
  for _ in $(seq 1 "${1:-40}"); do
    nc -z -G 2 -w 2 "$VITA" "$PORT" 2>/dev/null && return 0
    sleep 3
  done
  echo "dev server not answering on $VITA:$PORT" >&2
  echo "  (is Flutter Vita M1 running? it only listens while the app is up)" >&2
  return 1
}

cmd_simple() {
  wait_up || return 1
  printf '%s\n' "$1" | nc -w 10 "$VITA" "$PORT"
}

cmd_push() {
  [ -f "$EBOOT" ] || { echo "no $EBOOT — build first" >&2; return 1; }
  local size
  size=$(stat -f%z "$EBOOT" 2>/dev/null || stat -c%s "$EBOOT")
  wait_up || return 1
  echo "pushing $size bytes…"
  # Header line then raw bytes on the same connection.
  { printf 'upload %s\n' "$size"; cat "$EBOOT"; } | nc -w 120 "$VITA" "$PORT"
}

case "${1:-}" in
  ping|log|relaunch|exit) cmd_simple "$1" ;;
  push)                   cmd_push ;;
  run)                    cmd_push && sleep 1 && cmd_simple relaunch ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
