#!/usr/bin/env bash
# Drive the Vita. No FTP, no taps in the normal case.
#
#   M1     FVTA00002, port 1339 — the app under test
#   loader FVTA00003, port 1341 — installs and launches M1
#
# Both are UNSAFE selfs, so each can write ux0:app and replace the other.
# BGFTP is deliberately not used: the loop diagnoses itself through the `get`
# and `ls` commands in the apps.
#
#   ./dev.sh cycle     handoff -> stage -> install -> launch -> log
#   ./dev.sh who       which app is running
#   ./dev.sh log       pull m1.log
#   ./dev.sh crash     pull and symbolicate the newest crash dump
#   ./dev.sh get P F   copy a file off the device
#   ./dev.sh sup       is the background supervisor alive
#   ./dev.sh watch     wait until either app appears, then say which
#
# On a crash the cycle says so, pulls the dump, and then WATCHES CONTINUOUSLY
# for the loader rather than failing. Tap it whenever you notice; the wait is
# half an hour, so a tap is never missed and never has to be repeated.
set -uo pipefail

VITA="${VITA_IP:-192.168.0.32}"
DEV=1339
LDR=1341
SUP=1342   # background supervisor (eboot2.bin), survives crashes
HERE="$(cd "$(dirname "$0")" && pwd)"
EBOOT="$HERE/out/staging/eboot.bin"
ELF="$HERE/build/flutter_vita_m1"
DUMPS="$HERE/out/dumps"
# How long to keep watching for the loader after a crash.
#
# Long on purpose. Three minutes was too short: the app crashes, the loader gets
# tapped a minute or two later, and by then the script has given up -- so the tap
# goes unnoticed and has to be repeated. Waiting half an hour costs nothing and
# means a tap is never wasted.
TAP_WAIT="${TAP_WAIT:-1800}"

open_() { nc -z -G 2 -w 2 "$VITA" "$1" 2>/dev/null; }
say()   { printf '%s\n' "$2" | nc -w 30 "$VITA" "$1"; }
# Which port is alive, if any. Empty means nothing is running.
live()  { open_ "$DEV" && { echo "$DEV"; return; }; open_ "$LDR" && { echo "$LDR"; return; }; echo ""; }

waitp() {
  local port="$1" secs="${2:-60}" waited=0
  while [ "$waited" -lt "$secs" ]; do
    open_ "$port" && return 0
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

# Recover after a crash. The supervisor is a background app, so it outlives the
# foreground app dying -- if it answers, recovery needs no human at all. Falling
# back to asking for a tap only when it is absent.
wait_for_tap() {
  if open_ "$SUP"; then
    echo "  supervisor is alive — relaunching the loader, no tap needed" >&2
    say "$SUP" "launch FVTA00003" >/dev/null
    waitp "$LDR" 45 && { echo "  loader is back" >&2; return 0; }
    echo "  supervisor could not bring the loader back" >&2
  fi
  echo "  >>> tap Flutter Vita Loader on the Vita" >&2
  echo "      watching continuously for up to $((TAP_WAIT / 60)) min — tap whenever you like" >&2
  local waited=0
  while [ "$waited" -lt "$TAP_WAIT" ]; do
    local p; p="$(live)"
    if [ -n "$p" ]; then
      echo "  detected port $p after ${waited}s — carrying on" >&2
      return 0
    fi
    # Occasional progress, so a long wait cannot be mistaken for a hang.
    if [ "$waited" -gt 0 ] && [ $((waited % 60)) -eq 0 ]; then
      echo "      still watching (${waited}s)" >&2
    fi
    sleep 3; waited=$((waited + 3))
  done
  echo "  nothing came up within ${TAP_WAIT}s" >&2
  return 1
}

# Newest psp2core dump name, via whichever app is alive.
newest_dump() {
  local p; p="$(live)"; [ -z "$p" ] && return 1
  printf 'ls ux0:data\n' | nc -w 25 "$VITA" "$p" 2>/dev/null \
    | grep -o "psp2core-[0-9]*-0x[0-9a-f]*-[^ ]*\.psp2dmp" \
    | sort -t- -k2 -n | tail -1
}

cmd_get() {  # <device path> <local path>
  local p; p="$(live)"; [ -z "$p" ] && { echo "nothing running" >&2; return 1; }
  mkdir -p "$(dirname "$2")"
  printf 'get %s\n' "$1" | nc -w 120 "$VITA" "$p" > "$2"
  [ -s "$2" ] || { echo "empty: $1" >&2; rm -f "$2"; return 1; }
  echo "  pulled $1 -> $2 ($(wc -c <"$2" | tr -d ' ') B)"
}

cmd_crash() {
  local d; d="$(newest_dump)" || { echo "cannot list dumps" >&2; return 1; }
  [ -z "$d" ] && { echo "no dumps on the device" >&2; return 1; }
  echo "newest dump: $d"
  cmd_get "ux0:data/$d" "$DUMPS/$d" || return 1
  [ -x "$HERE/out/vpc-venv/bin/python3" ] || { echo "  (no analyser venv)"; return 0; }
  echo "--- symbolicated ---"
  ( export PATH="$HOME/vitasdk/bin:$PATH"
    "$HERE/out/vpc-venv/bin/python3" "$HERE/out/vita-parse-core/main.py" \
      "$DUMPS/$d" "$ELF" 2>/dev/null | sed -e 's/\x1b\[[0-9;]*m//g' \
      | grep -E "Stop reason|PC:|^ *R[0-9]+:|<.*\+0x" | head -14 )
}

cycle() {
  [ -f "$EBOOT" ] || { echo "no $EBOOT — build first" >&2; return 1; }

  # Nothing alive means a previous run crashed. Say so, and wait rather than
  # failing: with both apps dead only a tap can restart the loop.
  if [ -z "$(live)" ]; then
    echo "nothing is running — the last run probably crashed"
    wait_for_tap || return 1
  fi

  if open_ "$DEV"; then
    echo "handoff M1 -> loader…"
    say "$DEV" handoff >/dev/null
    if ! waitp "$LDR" 45; then
      echo "!! the loader never came up after handoff" >&2
      echo "   (M1 exited but the launch did not take -- see spikes/vita-tooling)" >&2
      wait_for_tap || return 1
    fi
  fi

  local size; size=$(wc -c <"$EBOOT" | tr -d ' ')
  echo "staging $size bytes…"
  if ! { printf 'stage %s\n' "$size"; cat "$EBOOT"; } | nc -w 180 "$VITA" "$LDR" | grep -q OK; then
    echo "!! stage failed (wifi drop mid-transfer?)" >&2; return 1
  fi
  echo "installing…"
  say "$LDR" install | grep -q OK || { echo "!! install failed" >&2; return 1; }

  echo "launching…"
  say "$LDR" launch >/dev/null
  if ! waitp "$DEV" 60; then
    # The interesting case: M1 was installed and launched but never answered.
    echo "!! M1 CRASHED (installed and launched, but never opened $DEV)" >&2
    if [ -n "$(live)" ]; then
      echo "   pulling the crash dump…" >&2
      cmd_crash >&2
    else
      echo "   both apps are down, so the dump cannot be pulled yet." >&2
      wait_for_tap && cmd_crash >&2
    fi
    return 2   # distinct exit code: crashed, as opposed to 1 for setup errors
  fi

  echo "--- m1.log ---"
  say "$DEV" log
}

case "${1:-}" in
  sup)     open_ "$SUP" && say "$SUP" ping || echo "supervisor not running" ;;
  who)     p="$(live)"; [ "$p" = "$DEV" ] && echo "M1 on $DEV" || { [ "$p" = "$LDR" ] && echo "loader on $LDR" || echo "nothing running"; } ;;
  log)     say "$DEV" log ;;
  probe)   p="$(live)"; say "$p" probe ;;
  handoff) say "$DEV" handoff ;;
  launch)  say "$LDR" launch ;;
  crash)   cmd_crash ;;
  get)     cmd_get "${2:?device path}" "${3:?local path}" ;;
  watch)   wait_for_tap && { p="$(live)"; echo "up on port $p"; } ;;
  cycle)   cycle ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
