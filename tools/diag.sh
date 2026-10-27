#!/usr/bin/env bash
# Ask a running app why nothing is moving, and resolve the answer.
#
#   ./tools/diag.sh                       two samples, five seconds apart
#   ./tools/diag.sh --once                one sample
#   ./tools/diag.sh --gap 15              a longer window between them
#   ./tools/diag.sh --port 1341           the bridge instead of an app
#   ./tools/diag.sh --elf path/to/elf     symbolicate the stack scans
#   ./tools/diag.sh --resolve report.txt --elf path/to/elf
#                                         no sampling: resolve a saved report
#                                         (a STALL block from app.log, the
#                                         watchdog's stall.txt, bench.sh's
#                                         stuck file)
#
# Two samples, not one, and that is the whole reason this script exists rather
# than a bare `printf 'diag\n' | nc`. Every per-thread figure in the report is
# a delta against the previous sample, so a single call reports a window of
# unknown length and tells you almost nothing; a pair reports the seconds
# between them, and the difference between a thread that is parked and a thread
# that is spinning only exists in that difference.
#
# The first sample is printed too, because its *absolute* columns -- status,
# what each thread is waiting on, the raster phase, free memory -- are already
# worth reading.
#
# `at` lines are a scan of each thread's live stack for things that look like
# Thumb return addresses. They are a heuristic and they include stale frames.
# With --elf they are resolved through the anchor the report prints: the module
# loads somewhere other than its ELF vaddr, so every address is shifted by a
# constant, and one known symbol is enough to recover it.
#
# **The ELF must be the one running on the console.** Every build relocates.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${VITA_HOST:-fluttervita.local}"
PORT="${DEV_PORT:-1339}"
ELF=""
GAP=5
ONCE=0
RESOLVE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --once)    ONCE=1; shift ;;
    --gap)     GAP="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --host)    HOST="$2"; shift 2 ;;
    --elf)     ELF="$2"; shift 2 ;;
    --resolve) RESOLVE="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$RESOLVE" ]; then
  [ -n "$ELF" ] || { echo "!! --resolve needs --elf" >&2; exit 2; }
  [ -f "$RESOLVE" ] || { echo "!! no such report: $RESOLVE" >&2; exit 2; }
  RAW="$RESOLVE"
else
  RAW="$(mktemp)"
  trap 'rm -f "$RAW"' EXIT
fi

sample() {
  printf 'diag\n' | nc -4 -w 25 "$HOST" "$PORT" \
    || { echo "!! no answer from $HOST:$PORT" >&2; exit 1; }
}

[ -n "$RESOLVE" ] || {
  echo "== sample 1"
  sample
  if [ "$ONCE" != "1" ]; then
    sleep "$GAP"
    echo
    echo "== sample 2 (deltas are over the last ${GAP}s)"
    sample
  fi
} | tee "$RAW"

[ -n "$ELF" ] || exit 0

echo
echo "== resolved"
SDK_DIR="$("$(dirname "$0")/vitasdk.sh" --find)"
NM="$SDK_DIR/bin/arm-vita-eabi-nm"
A2L="$SDK_DIR/bin/arm-vita-eabi-addr2line"
ELF_ANCHOR="$("$NM" "$ELF" | grep -i 'BuildDiag' | head -1 | awk '{print $1}')"
[ -n "$ELF_ANCHOR" ] || { echo "!! no BuildDiag in $ELF -- wrong binary?" >&2; exit 1; }

"$("$HERE/flutter-sdk.sh")/bin/cache/dart-sdk/bin/dart" "$HERE/diag-resolve.dart" \
  "$RAW" "$ELF" "$ELF_ANCHOR" "$A2L"
