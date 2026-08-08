#!/usr/bin/env bash
# Drive the Vita with no manual steps.
#
# Three parties, each doing the one thing it is allowed to do:
#
#   BGFTP  1337  a SceShell plugin, so it runs with shell permissions and is the
#                only thing here that can write ux0:app/. Always reachable.
#   M1     1339  FVTA00002, the app under test. Can hand off, and read its log.
#   loader 1341  FVTA00003, 47 KB. Cannot write ux0:app either -- sandboxed
#                homebrew gets ENOENT there -- but it CAN launch M1, and that is
#                the whole reason it exists.
#
# The loop: M1 hands off so its directory unlocks, BGFTP writes the new binary,
# the loader launches M1 again.
#
#   ./dev.sh who      which app is running
#   ./dev.sh cycle    handoff -> upload -> launch -> log     (the one you want)
#   ./dev.sh log      pull m1.log
#   ./dev.sh handoff  M1 -> loader
#   ./dev.sh launch   loader -> M1
set -uo pipefail

VITA="${VITA_IP:-192.168.0.32}"
DEV=1339
LDR=1341
FTP=1337
HERE="$(cd "$(dirname "$0")" && pwd)"
EBOOT="$HERE/out/staging/eboot.bin"

open_() { nc -z -G 2 -w 2 "$VITA" "$1" 2>/dev/null; }
waitp() { for _ in $(seq 1 "${2:-40}"); do open_ "$1" && return 0; sleep 3; done; return 1; }
say()   { printf '%s\n' "$2" | nc -w 25 "$VITA" "$1"; }

who() {
  open_ "$DEV" && { echo "M1 (FVTA00002) on $DEV"; return 0; }
  open_ "$LDR" && { echo "loader (FVTA00003) on $LDR"; return 0; }
  echo "neither running — tap Flutter Vita Loader once"; return 1
}

cycle() {
  [ -f "$EBOOT" ] || { echo "no $EBOOT — build first" >&2; return 1; }

  if open_ "$DEV"; then
    echo "handing off M1 -> loader (releases the ux0:app lock)…"
    say "$DEV" handoff >/dev/null
    waitp "$LDR" 40 || { echo "loader never came up" >&2; return 1; }
  elif ! open_ "$LDR"; then
    echo "nothing running — tap Flutter Vita Loader once" >&2; return 1
  fi

  # Only BGFTP can write here, and only while M1 is not running. Both true now.
  echo "uploading $(wc -c <"$EBOOT" | tr -d ' ') bytes over BGFTP…"
  waitp "$FTP" 40 || { echo "BGFTP unreachable" >&2; return 1; }
  local ok=0
  for i in $(seq 1 40); do
    if curl -sS --connect-timeout 30 -T "$EBOOT" \
         "ftp://$VITA:$FTP/ux0:/app/FVTA00002/eboot.bin" 2>/dev/null; then
      ok=1; echo "  uploaded (try $i)"; break
    fi
    sleep 3
  done
  [ "$ok" = 1 ] || { echo "upload failed" >&2; return 1; }

  echo "launching M1…"
  say "$LDR" launch >/dev/null
  waitp "$DEV" 60 || { echo "M1 did not come up" >&2; return 1; }
  echo "--- m1.log ---"
  say "$DEV" log
}

case "${1:-}" in
  who)     who ;;
  log)     say "$DEV" log ;;
  handoff) say "$DEV" handoff ;;
  launch)  say "$LDR" launch ;;
  probe)   open_ "$DEV" && say "$DEV" probe || say "$LDR" probe ;;
  cycle)   cycle ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
