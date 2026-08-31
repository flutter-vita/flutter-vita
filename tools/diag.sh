#!/usr/bin/env bash
# Ask a running app why nothing is moving.
#
#   ./tools/diag.sh                    two samples, five seconds apart
#   ./tools/diag.sh --once             one sample
#   ./tools/diag.sh --gap 15           a longer window between them
#   ./tools/diag.sh --port 1341        the loader instead of an app
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
set -euo pipefail

HOST="${VITA_HOST:-flutter-vita.local}"
PORT="${DEV_PORT:-1339}"
GAP=5
ONCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --once)    ONCE=1; shift ;;
    --gap)     GAP="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --host)    HOST="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

sample() {
  printf 'diag\n' | nc -w 20 "$HOST" "$PORT" \
    || { echo "!! no answer from $HOST:$PORT" >&2; exit 1; }
}

echo "== sample 1"
sample
[ "$ONCE" = "1" ] && exit 0

sleep "$GAP"
echo
echo "== sample 2 (deltas are over the last ${GAP}s)"
sample
