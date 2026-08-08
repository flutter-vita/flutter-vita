#!/usr/bin/env bash
# Drive the Vita with no manual steps, via two apps that launch each other.
#
#   M1     FVTA00002, port 1339 — the thing under test; changes every iteration
#   loader FVTA00003, port 1341 — tiny and stable; the only thing that can
#                                 replace M1's eboot.bin
#
# Neither can do it alone: an app cannot write its own ux0:app directory (it is
# ENOENT inside the sandbox), and while it runs nobody else can either. So the
# two hand control back and forth. See spikes/vita-tooling/README.md.
#
#   ./dev.sh who      which app is running
#   ./dev.sh log      pull m1.log
#   ./dev.sh cycle    full loop: handoff -> stage -> install -> launch -> log
#   ./dev.sh handoff  M1 -> loader
#   ./dev.sh launch   loader -> M1
#   ./dev.sh probe    ask whichever is up what it can write
set -uo pipefail

VITA="${VITA_IP:-192.168.0.32}"
DEV=1339      # M1
LDR=1341      # loader
FTP=1337      # BGFTP, background, always on
HERE="$(cd "$(dirname "$0")" && pwd)"
EBOOT="$HERE/out/staging/eboot.bin"

# This wifi drops constantly; nothing here fails on a single refused connection.
open_()  { nc -z -G 2 -w 2 "$VITA" "$1" 2>/dev/null; }
waitp()  { for _ in $(seq 1 "${2:-40}"); do open_ "$1" && return 0; sleep 3; done; return 1; }
say()    { printf '%s\n' "$2" | nc -w 25 "$VITA" "$1"; }

who() {
  open_ "$DEV" && { echo "M1 (FVTA00002) on $DEV"; return 0; }
  open_ "$LDR" && { echo "loader (FVTA00003) on $LDR"; return 0; }
  echo "neither is running"; return 1
}

to_loader() {
  open_ "$LDR" && return 0
  if open_ "$DEV"; then
    echo "handing off M1 -> loader…"
    say "$DEV" handoff >/dev/null
    waitp "$LDR" 40 && return 0
    echo "loader never came up after handoff" >&2; return 1
  fi
  echo "nothing is running — tap Flutter Vita Loader once on the LiveArea" >&2
  return 1
}

cycle() {
  [ -f "$EBOOT" ] || { echo "no $EBOOT — build first" >&2; return 1; }
  to_loader || return 1
  local size; size=$(wc -c <"$EBOOT" | tr -d ' ')
  echo "staging $size bytes…"
  { printf 'stage %s\n' "$size"; cat "$EBOOT"; } | nc -w 180 "$VITA" "$LDR"
  echo "installing and launching…"
  say "$LDR" deploy
  waitp "$DEV" 60 || { echo "M1 did not come up" >&2; return 1; }
  echo "--- m1.log ---"
  say "$DEV" log
}

case "${1:-}" in
  who)     who ;;
  log)     say "$DEV" log ;;
  probe)   open_ "$DEV" && say "$DEV" probe || say "$LDR" probe ;;
  handoff) say "$DEV" handoff ;;
  launch)  say "$LDR" launch ;;
  cycle)   cycle ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
