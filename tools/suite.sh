#!/usr/bin/env bash
# Run one of the gallery's suites on the console, unattended, and print the verdict.
#
#   ./tools/suite.sh conformance           the probe suite, out/suite/conformance.json
#   ./tools/suite.sh hardware              the hardware checks, out/suite/hardware.json
#   ./tools/suite.sh all                   conformance, then hardware
#   ./tools/suite.sh conformance --relaunch    reuse the installed build, skip build and deploy
#   ./tools/suite.sh conformance --no-build    deploy what is already built
#   ./tools/suite.sh conformance --host NAME --receiver-port N
#
# Each suite is started by its own switch on the card and ends with its own
# done marker (samples/README.md). This script arms the switch, deploys the
# gallery (or relaunches it), waits for the marker and pulls the result. The
# verdicts are pass counts, not timings, so there is no baseline.
#
# The benchmark's scenes were the third suite until 2026-10-01. They are
# github.com/flutter-vita/flutter-vita-bench now, with their own tool/bench.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# fluttervita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often.
HOST="${VITA_HOST:-fluttervita.local}"
DEV=1339
LDR=1341
APP_VPK="$ROOT/samples/gallery/build/vita/gallery.vpk"
OUT_DIR="$ROOT/out/suite"
BUILD=1
RELAUNCH=0
SUITE=""

while [ $# -gt 0 ]; do
  case "$1" in
    conformance|hardware|all) SUITE="$1"; shift ;;
    --host)        HOST="$2"; shift 2 ;;
    --receiver-port) LDR="$2"; shift 2 ;;
    --no-build)    BUILD=0; shift ;;
    --relaunch)    RELAUNCH=1; BUILD=0; shift ;;
    -h|--help)     sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
[ -n "$SUITE" ] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# One run at a time. There is one console, and two of these driving it
# produce a run that never finishes and a second run that measures the first.
LOCK="${TMPDIR:-/tmp}/flutter-vita-suite.lock"
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "!! a suite is already running (pid $(cat "$LOCK")). One console, one run." >&2
  exit 3
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

say() { printf '%s\n' "$2" | nc -4 -w "${3:-20}" "$HOST" "$1" 2>/dev/null; }
# Write a switch file, through whichever of the two is actually listening.
#
# Both the app and the receiver serve `put`, and which one holds the console
# depends on where the last run left it. Assuming the receiver cost two silent
# aborts on 2026-08-24: nc found nothing, `set -e` took the script down between
# two echoes, and the output looked like it had simply stopped.
put() {  # <content> <device path>
  local content="$1" path="$2" size port reply
  size=${#content}
  for port in "$DEV" "$LDR"; do
    reply="$(printf 'put %s %s\n%s' "$size" "$path" "$content" \
      | nc -4 -w 15 "$HOST" "$port" 2>/dev/null || true)"
    case "$reply" in *OK*) return 0 ;; esac
  done
  echo "!! could not write $path — nothing answered on $DEV or $LDR" >&2
  return 1
}

mkdir -p "$OUT_DIR"

if [ "$BUILD" -eq 1 ]; then
  echo "==> building gallery"
  "$HERE/build-vita-app.sh" "$ROOT/samples/gallery" >/dev/null
fi
[ "$RELAUNCH" -eq 1 ] || [ -f "$APP_VPK" ] || { echo "!! no $APP_VPK" >&2; exit 1; }

# Arm the switch, deploy (or relaunch), wait for the done marker, pull the
# result. The first suite of a run deploys; the second relaunches the build the
# first one installed.
run_suite() {  # <conformance|hardware>
  local suite="$1"
  echo "==> $suite: arming"
  put "0" "ux0:data/flutter-vita/software.on"
  put "0" "ux0:data/flutter-vita/hud.off"
  put "1" "ux0:data/flutter-vita/$suite.on"
  put "0" "ux0:data/flutter-vita/$suite-done"
  # The watchdog's report, if it fires during this run. There is no rm, and a
  # stale report reads as this run's.
  put "-" "ux0:data/flutter-vita/stall.txt"
  if [ "$RELAUNCH" -eq 1 ] && say "$DEV" ping 4 | grep -q pong; then
    echo "==> $suite: relaunching the installed build"
    say "$DEV" relaunch 10 >/dev/null || true
  else
    echo "==> $suite: deploying"
    VITA_HOST="$HOST" "$HERE/deploy.sh" --vpk "$APP_VPK" --receiver-port "$LDR" \
      >"$OUT_DIR/$suite-deploy.log" 2>&1 || true
  fi
  echo "==> $suite: running"
  local started done=0 i
  started=$(date +%s)
  for i in $(seq 1 300); do
    if say "$DEV" "get ux0:data/flutter-vita/$suite-done" 2 | grep -q '^1'; then
      done=1; break
    fi
    # Once every 20 s, so the wait reads as progress rather than silence.
    [ $((i % 10)) -eq 0 ] && echo "    $(date +%H:%M:%S) $suite running, $(( $(date +%s) - started )) s"
    sleep 2
  done
  put "0" "ux0:data/flutter-vita/$suite.on"
  [ "$done" -eq 1 ] || { echo "!! $suite: the run never finished" >&2; return 1; }
  say "$DEV" "get ux0:data/flutter-vita/$suite-result.json" 30 > "$OUT_DIR/$suite.json"
  python3 - "$OUT_DIR/$suite.json" "$suite" <<'PY' || return 1
import json, sys
d = json.load(open(sys.argv[1]))
suite = sys.argv[2]
print(f"    {sys.argv[1]}  ({d.get('engine', 'no engine stamp')})")
if suite == "conformance":
    print(f"    {d['pass']} pass  {d['fail']} fail  {d['skip']} skip")
    for p in d["probes"]:
        if p["outcome"] == "fail":
            print(f"      FAIL {p['group']}/{p['name']}  {p['detail']}")
else:
    print(f"    {d['pass']} pass  {d['fail']} fail  {d['eye']} by eye  {d['off']} off")
    for c in d["checks"]:
        if c["state"] != "pass":
            print(f"      {c['state'].upper():4s} {c['title']}: {c['detail']}")
PY
}

case "$SUITE" in
  all)
    run_suite conformance || true
    RELAUNCH=1
    run_suite hardware ;;
  *)
    run_suite "$SUITE" ;;
esac
