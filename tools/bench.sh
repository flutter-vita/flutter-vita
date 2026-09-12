#!/usr/bin/env bash
# Run the gallery's benchmark on both renderers and compare. ADR-0017.
#
#   ./tools/bench.sh                       the GPU, the only renderer anyone runs
#   ./tools/bench.sh --only sw             software, to localise a GL defect
#   ./tools/bench.sh --baseline            write the result in as the baseline
#   ./tools/bench.sh --relaunch            reuse the installed build, skip deploy
#   ./tools/bench.sh --leave sw|gl         renderer the console rests on (default gl)
#   ./tools/bench.sh --scenes a,b,c        run only these scenes
#   ./tools/bench.sh --host IP --receiver-port N
#
# gl.on is read once at startup, so comparing renderers is two runs and a
# relaunch. This is that in one command: deploy, run, flip, relaunch, run, pull
# both, print a table, and fail if a scene regressed against the baseline.
#
# Every performance number before it came from a human driving an app by hand,
# once, on whatever binary happened to be installed, and three of them collapsed
# in a single session on 2026-08-22. See the ADR's Context.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# flutter-vita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often. VITA_HOST still overrides
# it, and an IP is still the right answer when the name will not resolve.
HOST="${VITA_HOST:-flutter-vita.local}"
DEV=1339
LDR=1341
APP_VPK="$ROOT/apps/gallery/build/vita/gallery.vpk"
BASELINE_DIR="$ROOT/apps/gallery/bench"
OUT_DIR="$ROOT/out/bench"
# GPU only, unless asked otherwise.
#
# Every run used to do software and GPU and diff them. Nobody ships software
# rendering on this console, and running it doubled every measurement to produce
# a column nobody acts on. --only sw still localises a GL defect.
ONLY="gl"
# Which renderer the console is left on when the run finishes. See the note
# beside the write at the bottom.
LEAVE=gl
# Scene subset, written to bench.only for the app to read. Empty runs everything.
#
# A scene scheduled behind a leak measures the leak: on 2026-09-01 route_wrap and
# route_spans took the heap from 8 MB to the 159 MB ceiling, and every scene
# after them ran on a full heap. Isolating a group is the only way to measure one
# on a fresh heap.
SCENES=""
WRITE_BASELINE=0
BUILD=1
# Reuse what is installed instead of staging 13 MB again.
#
# Off by default: a "software" run on 2026-08-22 turned out to be running the GPU
# because the installed eboot predated the opt-in switch. The renderer check
# below reads what the display controller is scanning, so a stale binary is
# caught before any scene runs.
RELAUNCH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host)        HOST="$2"; shift 2 ;;
    --receiver-port) LDR="$2"; shift 2 ;;
    --only)        ONLY="$2"; shift 2 ;;
    --leave)       LEAVE="$2"; shift 2 ;;
    --scenes)      SCENES="$2"; shift 2 ;;
    --baseline)    WRITE_BASELINE=1; shift ;;
    --no-build)    BUILD=0; shift ;;
    --relaunch)    RELAUNCH=1; BUILD=0; shift ;;
    -h|--help)     sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# One bench at a time. There is one console, and two of these driving it
# produce a run that never finishes and a second run that measures the first.
# On 2026-09-09 that cost an afternoon: the app died between scenes, the GL
# call counter froze, and the older run reported "never finished" after 6,000 s
# while the newer one was still trying. Neither number could be used.
LOCK="${TMPDIR:-/tmp}/flutter-vita-bench.lock"
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "!! a bench is already running (pid $(cat "$LOCK")). One console, one bench." >&2
  exit 3
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

say() { printf '%s\n' "$2" | nc -w "${3:-20}" "$HOST" "$1" 2>/dev/null; }
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
# Deploying rather than relaunching is deliberate. `relaunch` reuses the
# installed eboot, which is how a "software" run turned out to be GL on
# 2026-08-22.
run_one() {  # <sw|gl>
  # software.on, not gl.on: the default flipped to GL on 2026-08-24, so the
  # switch that exists is the one that opts *out*.
  local mode="$1" swval
  [ "$mode" = "sw" ] && swval=1 || swval=0

  echo "==> $mode: arming"
  put "$swval" "ux0:data/flutter-vita/software.on"
  put "1"      "ux0:data/flutter-vita/bench.on"
  # Always written, even when empty: the receiver can put a file and cannot
  # delete one, so a stale subset from the previous invocation would silently
  # restrict a run that asked for everything.
  # A zero-byte put is refused by the Flutter receiver ("ERR size", measured
  # 2026-09-12), so an empty subset goes as a newline; the app trims it to
  # nothing and runs everything.
  put "${SCENES:-$'\n'}" "ux0:data/flutter-vita/bench.only"
  # Cleared first so a stale file from the previous run cannot be mistaken for
  # this one's output.
  put "0"      "ux0:data/flutter-vita/bench-done"

  if [ "$RELAUNCH" -eq 1 ] && say "$DEV" ping 4 | grep -q pong; then
    echo "==> $mode: relaunching the installed build"
    say "$DEV" relaunch 10 >/dev/null || true
  else
    echo "==> $mode: deploying"
    VITA_HOST="$HOST" "$HERE/deploy.sh" --vpk "$APP_VPK" --receiver-port "$LDR" \
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

  # What the app asked for is not what it got if the binary predates the opt-in
  # switch, so the renderer in the results comes from shotinfo, which reports
  # what the display controller is scanning.
  # Retried, because the first sample can be too early: on the GL path
  # sceDisplayGetFrameBuf has nothing to report until vitaGL has presented once.
  local actual=unknown backend=unknown info=""
  for _ in 1 2 3 4 5 6 7 8; do
    info="$(say "$DEV" shotinfo 8)"
    # The GL side names its backend (ADR-0019): vitaGL or fvita_gles2.
    case "$info" in
      *match=vitaGL*)      actual=gl; backend=vitaGL; break ;;
      *match=fvita_gles2*) actual=gl; backend=fvita_gles2; break ;;
      *match=yes*)         actual=sw; backend=software; break ;;
    esac
    sleep 2
  done
  if [ "$actual" != "$mode" ]; then
    echo "!! asked for $mode, the device is running $actual" >&2
    echo "   $info" >&2
    echo "   A binary built against an older engine artifact ignores" >&2
    echo "   software.on and picks its own renderer." >&2
    return 1
  fi
  echo "    renderer confirmed: $actual ($backend)"

  # 20 minutes. The old budget was 180 s, which fitted the eighteen scenes
  # that existed on 2026-08-25 and nothing since: the suite is 34 scenes now
  # and a software run of it takes longer than that on its own. A poll budget
  # that expires mid-run reports "the run never finished", which reads as a
  # hang and is not one.
  echo "==> $mode: running scenes"
  local done=0
  for i in $(seq 1 600); do
    if say "$DEV" "get ux0:data/flutter-vita/bench-done" 6 | grep -q '^1'; then
      done=1; break
    fi
    # Something every half minute, so a long run is distinguishable from a
    # dead one without reading the app log.
    if [ $((i % 15)) -eq 0 ]; then
      echo "    still running (${i}0s)"
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

# What renderer the console is left on.
#
# This used to be software unconditionally, because a hard crash under GL wedges
# the console (ADR-0014). Two things changed on 2026-09-01: the reservation that
# took GXM down is checked (patches/vitagl/0002) and the shader that would not
# link now links (0004). The old default meanwhile left every app launched after
# a bench run silently on the software path, including runs read as GL.
#
# So the resting state is GL, and --leave sw restores the old behaviour.
put "$([ "$LEAVE" = sw ] && echo 1 || echo 0)" "ux0:data/flutter-vita/software.on"
put "0" "ux0:data/flutter-vita/bench.on"

echo
python3 "$HERE/bench-report.py" \
  --out "$OUT_DIR" --baseline "$BASELINE_DIR" --modes "$MODES" \
  ${WRITE_BASELINE:+$([ "$WRITE_BASELINE" -eq 1 ] && echo --write-baseline)}
