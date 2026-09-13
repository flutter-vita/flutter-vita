#!/usr/bin/env bash
# Deploy an experiment, launch it, and get its report back -- assuming it crashes.
#
#   ./tools/run-experiment.sh <vpk> <report-path-on-device>
#
# deploy.sh waits for the app to open its dev port, which an experiment never does:
# an experiment runs, writes a file and ends, so that wait is pure latency, and when
# the experiment faults instead it is latency followed by a ten-minute prompt for a
# tap. This installs, launches, and then watches the *receiver* rather than the
# app, because the receiver coming back is the signal either way -- the experiment
# handed the console over on its own, or it faulted and somebody opened the
# receiver. Both end with a readable report.
#
# Short timeouts throughout, deliberately. A crash is the expected outcome of a
# experiment, not an exception to plan around.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# flutter-vita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often. VITA_HOST still overrides
# it, and an IP is still the right answer when the name will not resolve.
HOST="${VITA_HOST:-flutter-vita.local}"
# The receiver's port. 1341 is the real one; a scratch receiver (ADR-0016) answers
# somewhere else, and an experiment deployed through it needs to be told.
LDR="${RECEIVER_PORT:-1341}"
VPK="${1:?usage: run-experiment.sh <vpk> <report-path>}"
REPORT="${2:?usage: run-experiment.sh <vpk> <report-path>}"
DEADLINE="${EXPERIMENT_DEADLINE:-90}"

ldr() { printf '%s\n' "$1" | nc -4 -w 3 "$HOST" "$LDR" 2>/dev/null; }

wait_receiver() {
  local until=$((SECONDS + $1))
  while [ $SECONDS -lt $until ]; do
    ldr ping | grep -q receiver && return 0
  done
  return 1
}

echo "==> installing $(basename "$VPK")"
VITA_HOST="$HOST" "$HERE/deploy.sh" --vpk "$VPK" --no-launch \
  --receiver-port "$LDR" >/dev/null 2>&1 || {
  echo "!! install failed -- is the receiver open?" >&2; exit 1; }

echo "==> launching"
ldr launch >/dev/null

# The receiver is gone the moment the app starts; waiting for it to disappear
# first avoids reading the report from the previous run.
sleep 2

echo "==> waiting for the receiver (experiment ends, or it crashes and you open it)"
if wait_receiver "$DEADLINE"; then
  echo "    receiver back"
else
  echo "!! receiver did not return within ${DEADLINE}s -- open it and re-run with --report-only" >&2
  exit 2
fi

echo "==> report"
for _ in 1 2 3 4 5 6; do
  out="$(printf 'get %s\n' "$REPORT" | nc -4 -w 8 "$HOST" "$LDR" 2>/dev/null)"
  [ -n "$out" ] && { printf '%s\n' "$out"; exit 0; }
done
echo "!! no report at $REPORT" >&2
exit 3
