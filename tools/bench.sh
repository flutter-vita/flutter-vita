#!/usr/bin/env bash
# Run the gallery's benchmark on both renderers and compare. ADR-0017.
#
#   ./tools/bench.sh                       software and GPU, then diff
#   ./tools/bench.sh --only sw|gl          one renderer
#   ./tools/bench.sh --baseline            write the result in as the baseline
#   ./tools/bench.sh --relaunch            reuse the installed build, skip the deploy
#   ./tools/bench.sh --host IP --loader-port N
#
# gl.on is read once at startup, so comparing renderers is always two runs and
# a relaunch. This is that, made into one command: deploy, run, flip, relaunch,
# run, pull both, print a table, and fail if a scene regressed against the
# committed baseline.
#
# It exists because every performance number this project produced before it
# came from a human driving an app by hand, once, on whatever binary happened
# to be installed -- and three of them collapsed in a single session on
# 2026-08-22. See the ADR's Context.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

HOST="${VITA_HOST:-192.168.0.32}"
DEV=1339
LDR=1341
APP_VPK="$ROOT/apps/gallery/build/vita/gallery.vpk"
BASELINE_DIR="$ROOT/apps/gallery/bench"
OUT_DIR="$ROOT/out/bench"
ONLY=""
WRITE_BASELINE=0
BUILD=1
# Reuse what is installed instead of staging 13 MB again.
#
# Off by default, and that default is not caution for its own sake: a "software"
# run on 2026-08-22 turned out to be running the GPU because the installed eboot
# predated the opt-in switch. The renderer check below is what makes this safe
# to turn on -- it reads what the display controller is actually scanning, so a
# stale binary is caught before any scene runs rather than after the numbers are
# published.
RELAUNCH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host)        HOST="$2"; shift 2 ;;
    --loader-port) LDR="$2"; shift 2 ;;
    --only)        ONLY="$2"; shift 2 ;;
    --baseline)    WRITE_BASELINE=1; shift ;;
    --no-build)    BUILD=0; shift ;;
    --relaunch)    RELAUNCH=1; BUILD=0; shift ;;
    -h|--help)     sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$2" | nc -w "${3:-20}" "$HOST" "$1" 2>/dev/null; }
# Write a switch file, through whichever of the two is actually listening.
#
# Both the app and the loader serve `put`, and which one holds the console
# depends on where the last run left it. Assuming the loader is up cost two
# silent aborts on 2026-08-24: nc found nothing on the loader port, `set -e`
# took the script down between two echoes, and the output looked like the
# script had simply stopped.
put() {  # <content> <device path>
  local content="$1" path="$2" size port reply
  size=${#content}
  for port in "$DEV" "$LDR"; do
    reply="$(printf 'put %s %s\n%s' "$size" "$path" "$content" \
      | nc -w 15 "$HOST" "$port" 2>/dev/null || true)"
    case "$reply" in *OK*) return 0 ;; esac
  done
  echo "!! could not write $path — nothing answered on $DEV or $LDR" >&2
  return 1
}

mkdir -p "$OUT_DIR" "$BASELINE_DIR"

if [ "$BUILD" -eq 1 ]; then
  echo "==> building gallery"
  "$HERE/build-vita-app.sh" "$ROOT/apps/gallery" >/dev/null
fi
[ -f "$APP_VPK" ] || { echo "!! no $APP_VPK" >&2; exit 1; }

# One run: set the renderer, deploy so the app restarts into it, wait for the
# result file, pull it.
#
# Deploying rather than relaunching is deliberate. `relaunch` is faster, but it
# reuses the installed eboot, and a stale eboot is exactly how a "software" run
# turned out to be running the GPU on 2026-08-22. A deploy makes the binary
# under test the binary that was just built.
run_one() {  # <sw|gl>
  local mode="$1" glval
  [ "$mode" = "gl" ] && glval=1 || glval=0

  echo "==> $mode: arming"
  put "$glval" "ux0:data/flutter-vita/gl.on"
  put "1"      "ux0:data/flutter-vita/bench.on"
  # Cleared first so a stale file from the previous run cannot be mistaken for
  # this one's output.
  put "0"      "ux0:data/flutter-vita/bench-done"

  if [ "$RELAUNCH" -eq 1 ] && say "$DEV" ping 4 | grep -q pong; then
    echo "==> $mode: relaunching the installed build"
    say "$DEV" relaunch 10 >/dev/null || true
  else
    echo "==> $mode: deploying"
    VITA_HOST="$HOST" "$HERE/deploy.sh" --vpk "$APP_VPK" --loader-port "$LDR" \
      >"$OUT_DIR/$mode-deploy.log" 2>&1 || true
  fi

  # The app waits three seconds after its first frame before measuring, which
  # is this window: the debug HUD costs ~300 us a frame and is drawn into the
  # frame it would be measuring, and only the engine can switch it off.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    say "$DEV" ping 4 | grep -q pong && break
    sleep 2
  done
  say "$DEV" "overlay off" 6 >/dev/null || true

  # What the app *asked* for is not what it got if the binary predates the
  # opt-in switch. shotinfo reports what the display controller is actually
  # scanning, so the renderer in the results comes from here and not from the
  # app.
  local actual info
  info="$(say "$DEV" shotinfo 8)"
  case "$info" in
    *match=vitaGL*) actual=gl ;;
    *match=yes*)    actual=sw ;;
    *)              actual=unknown ;;
  esac
  if [ "$actual" != "$mode" ]; then
    echo "!! asked for $mode, the device is running $actual" >&2
    echo "   $info" >&2
    echo "   A binary built against an older engine artifact ignores gl.on." >&2
    return 1
  fi
  echo "    renderer confirmed: $actual"

  echo "==> $mode: running scenes"
  local done=0
  for _ in $(seq 1 90); do
    if say "$DEV" "get ux0:data/flutter-vita/bench-done" 6 | grep -q '^1'; then
      done=1; break
    fi
    sleep 2
  done
  [ "$done" -eq 1 ] || { echo "!! $mode: the run never finished" >&2; return 1; }

  say "$DEV" "get ux0:data/flutter-vita/bench-result.json" 30 \
    > "$OUT_DIR/$mode.json"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT_DIR/$mode.json" \
    || { echo "!! $mode: result file is not valid JSON" >&2; return 1; }
  echo "    $OUT_DIR/$mode.json"
}

MODES="sw gl"
[ -n "$ONLY" ] && MODES="$ONLY"
for m in $MODES; do run_one "$m"; done

# Leave the console on software. A hard crash under GL wedges the whole thing
# (ADR-0014), so the resting state is the one that cannot.
put "0" "ux0:data/flutter-vita/gl.on"
put "0" "ux0:data/flutter-vita/bench.on"

echo
python3 "$HERE/bench-report.py" \
  --out "$OUT_DIR" --baseline "$BASELINE_DIR" --modes "$MODES" \
  ${WRITE_BASELINE:+$([ "$WRITE_BASELINE" -eq 1 ] && echo --write-baseline)}
