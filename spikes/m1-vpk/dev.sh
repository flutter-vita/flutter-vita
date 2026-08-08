#!/usr/bin/env bash
# Drive the Vita remotely. Two channels, because neither alone is enough:
#
#   BGFTP on 1337   — runs in the background, always reachable, can write
#                     ux0:app/FVTA00002/ but ONLY while our app is not running
#   dev server 1339 — inside our app (src/devserver.c), so only up while the
#                     app runs; can read logs and exit the app
#
#   ./dev.sh log        pull m1.log
#   ./dev.sh ping       is the app alive
#   ./dev.sh probe      which directories the app can write
#   ./dev.sh deploy     exit the app, upload the new build over BGFTP
#   ./dev.sh relaunch   re-run the installed binary (same code)
#   ./dev.sh exit       close the app
#
# After `deploy` you must tap Flutter Vita M1 on the LiveArea. That one tap is
# the only manual step left, and it is unavoidable without a SceShell plugin --
# vitacompanion would have done it but hangs this device (spikes/vita-tooling).
set -uo pipefail

VITA="${VITA_IP:-192.168.0.40}"
DEV="${VITA_DEV_PORT:-1339}"
FTP="${VITA_FTP_PORT:-1337}"
HERE="$(cd "$(dirname "$0")" && pwd)"
EBOOT="$HERE/out/staging/eboot.bin"
APPDIR="ux0:/app/FVTA00002"

# The wifi drops constantly; everything retries rather than failing once.
up() { for _ in $(seq 1 "${2:-30}"); do nc -z -G 2 -w 2 "$VITA" "$1" 2>/dev/null && return 0; sleep 3; done; return 1; }
dev() { up "$DEV" 10 || { echo "app not running (dev server $DEV silent)" >&2; return 1; }; printf '%s\n' "$1" | nc -w 25 "$VITA" "$DEV"; }

deploy() {
  [ -f "$EBOOT" ] || { echo "no $EBOOT — build first" >&2; return 1; }
  if up "$DEV" 3; then
    echo "closing the app so its directory unlocks…"
    printf 'exit\n' | nc -w 10 "$VITA" "$DEV" >/dev/null
    sleep 5
  fi
  up "$FTP" 40 || { echo "BGFTP not reachable on $FTP" >&2; return 1; }
  # Retry: the directory stays locked for a moment after the app exits.
  for i in $(seq 1 30); do
    if curl -sS --connect-timeout 25 -T "$EBOOT" "ftp://$VITA:$FTP/$APPDIR/eboot.bin" 2>/dev/null; then
      echo "deployed $(wc -c <"$EBOOT") bytes on try $i"
      echo "now tap Flutter Vita M1 on the LiveArea"
      return 0
    fi
    sleep 3
  done
  echo "upload kept failing — is the app really closed?" >&2; return 1
}

case "${1:-}" in
  ping|log|probe|relaunch|exit) dev "$1" ;;
  deploy)                       deploy ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
