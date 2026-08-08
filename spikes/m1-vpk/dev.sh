#!/usr/bin/env bash
# Drive the Vita with no manual steps and no FTP.
#
#   M1     FVTA00002, port 1339 — the app under test
#   loader FVTA00003, port 1341 — built as an UNSAFE self, so it can write
#                                 ux0:app directly. That is the whole trick.
#
# vita_create_self builds a *safe* self by default, and a safe self is confined:
# ux0:app is invisible, not merely unwritable, whatever "Enable unsafe homebrew"
# is set to. Adding UNSAFE removes the -s flag from vita-make-fself and the
# confinement goes with it. Everything else here — BGFTP, the promoter, patch
# directories — was working around a restriction we had opted into.
#
#   ./dev.sh who      which app is running
#   ./dev.sh cycle    handoff -> stage -> install -> launch -> log
#   ./dev.sh log      pull m1.log
#   ./dev.sh probe    what the running app can write
set -uo pipefail

VITA="${VITA_IP:-192.168.0.32}"
DEV=1339
LDR=1341
HERE="$(cd "$(dirname "$0")" && pwd)"
EBOOT="$HERE/out/staging/eboot.bin"

open_() { nc -z -G 2 -w 2 "$VITA" "$1" 2>/dev/null; }
waitp() { for _ in $(seq 1 "${2:-40}"); do open_ "$1" && return 0; sleep 3; done; return 1; }
say()   { printf '%s\n' "$2" | nc -w 30 "$VITA" "$1"; }

who() {
  open_ "$DEV" && { echo "M1 (FVTA00002) on $DEV"; return 0; }
  open_ "$LDR" && { echo "loader (FVTA00003) on $LDR"; return 0; }
  echo "neither running — tap Flutter Vita Loader once"; return 1
}

cycle() {
  [ -f "$EBOOT" ] || { echo "no $EBOOT — build first" >&2; return 1; }

  if open_ "$DEV"; then
    echo "handoff M1 -> loader…"
    say "$DEV" handoff >/dev/null
    waitp "$LDR" 40 || { echo "loader never came up" >&2; return 1; }
  elif ! open_ "$LDR"; then
    echo "nothing running — tap Flutter Vita Loader once" >&2; return 1
  fi

  local size; size=$(wc -c <"$EBOOT" | tr -d ' ')
  echo "staging $size bytes to ux0:data…"
  { printf 'stage %s\n' "$size"; cat "$EBOOT"; } | nc -w 180 "$VITA" "$LDR"
  # Stage and install are separate so a dropped transfer -- routine on this
  # wifi -- cannot leave a half-written eboot.bin in ux0:app.
  echo "installing…"
  say "$LDR" install
  echo "launching…"
  say "$LDR" launch >/dev/null
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
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
