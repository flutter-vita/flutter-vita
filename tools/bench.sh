#!/usr/bin/env bash
# Run the gallery's benchmark on both renderers and compare. ADR-0017.
#
#   ./tools/bench.sh                       the GPU, the only renderer anyone runs
#   ./tools/bench.sh --only sw             software, to localise a GL defect
#   ./tools/bench.sh --baseline            write the result in as the baseline
#   ./tools/bench.sh --baseline-add        add the result to the baseline: one
#                                          --baseline, then two of these, makes a
#                                          baseline over three launches
#   ./tools/bench.sh --relaunch            reuse the installed build, skip deploy
#   ./tools/bench.sh --leave sw|gl         renderer the console rests on (default gl)
#   ./tools/bench.sh --scenes a,b,c        run only these scenes
#   ./tools/bench.sh --stuck-after 150     seconds on one scene before it is stuck
#   ./tools/bench.sh --host IP --receiver-port N
#   ./tools/bench.sh --suite conformance   the probe suite, unattended, out/bench/conformance.json
#   ./tools/bench.sh --suite hardware      the hardware checks, out/bench/hardware.json
#   ./tools/bench.sh --suite all           scenes, then conformance, then hardware
#
# A scene that does not end is handled, not waited on. The app itself relaunches
# when its UI thread stops answering for 30 s (the embedder's watchdog, which
# leaves stall.txt and stall.log on the card); this script covers the other
# case, a UI thread that answers while the scene never advances: after
# --stuck-after seconds on one scene it takes two `diag` samples and the log,
# saves them under out/bench/, resolves the stacks against the ELF of this
# build, and sends `relaunch`. Either way the app resumes from bench-partial.json,
# skips the scene it was inside, marks it interrupted, and the run completes.
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

# fluttervita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often. VITA_HOST still overrides
# it, and an IP is still the right answer when the name will not resolve.
HOST="${VITA_HOST:-fluttervita.local}"
DEV=1339
LDR=1341
APP_VPK="$ROOT/samples/gallery/build/vita/gallery.vpk"
BASELINE_DIR="$ROOT/samples/gallery/bench"
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
# Seconds on one scene before the host declares it stuck. The longest scene is
# under a minute on the GPU; software runs are slower and can raise this.
STUCK_AFTER=150
# Which of the gallery's suites: scenes (the benchmark, the default),
# conformance, hardware, or all three in that order. Each is started by its
# own switch on the card and ends with its own done marker (samples/README.md).
SUITE="scenes"

while [ $# -gt 0 ]; do
  case "$1" in
    --suite)       SUITE="$2"; shift 2 ;;
    --host)        HOST="$2"; shift 2 ;;
    --receiver-port) LDR="$2"; shift 2 ;;
    --only)        ONLY="$2"; shift 2 ;;
    --leave)       LEAVE="$2"; shift 2 ;;
    --scenes)      SCENES="$2"; shift 2 ;;
    --stuck-after) STUCK_AFTER="$2"; shift 2 ;;
    --baseline)    WRITE_BASELINE=1; shift ;;
    --baseline-add) WRITE_BASELINE=2; shift ;;
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

mkdir -p "$OUT_DIR" "$BASELINE_DIR"

if [ "$BUILD" -eq 1 ]; then
  echo "==> building gallery"
  "$HERE/build-vita-app.sh" "$ROOT/samples/gallery" >/dev/null
fi
[ -f "$APP_VPK" ] || { echo "!! no $APP_VPK" >&2; exit 1; }

# One run: set the renderer, deploy so the app restarts into it, wait for the
# result file, pull it.
#
# The ELF of the build under test, for the stack scans. build-vita-app.sh
# leaves it next to the vpk; a --no-build run of a vpk from elsewhere has none
# that matches, and a mismatched ELF resolves to nonsense, so it is used only
# when its eboot is the one in the vpk.
elf_for_vpk() {
  local elf="$ROOT/samples/gallery/build/vita/cmake/flutter_vita_app"
  local built="$ROOT/samples/gallery/build/vita/cmake/flutter_vita_app.vpk"
  [ -f "$elf" ] && [ -f "$built" ] || return 1
  local a b
  a="$(unzip -p "$APP_VPK" eboot.bin 2>/dev/null | md5 -q 2>/dev/null || true)"
  b="$(unzip -p "$built" eboot.bin 2>/dev/null | md5 -q 2>/dev/null || true)"
  [ -n "$a" ] && [ "$a" = "$b" ] || return 1
  echo "$elf"
}

# Resolve the `at` lines of a saved report in place of the reader having to.
resolve_report() {  # <report file>
  local elf
  elf="$(elf_for_vpk)" || { echo "       (no matching ELF, stacks left raw)"; return 0; }
  "$HERE/diag.sh" --resolve "$1" --elf "$elf" > "$1.resolved" 2>&1 || true
  echo "       resolved: $1.resolved"
  # The two threads that matter, first frames only, so the verdict is on screen.
  grep -A 6 -E "^(io.flutter.ui|io.flutter.raster) " "$1.resolved" | sed 's/^/       /' | head -n 16
}

# A scene has been running longer than any scene should. Take the evidence,
# then get the console back.
on_stuck() {  # <mode> <scene> <seconds> <n>
  local mode="$1" scene="$2" secs="$3" n="$4"
  local f="$OUT_DIR/$mode-stuck-$scene-$n.txt"
  echo "    !! $scene has run for ${secs}s -- taking diag twice, then relaunching"
  {
    echo "== $mode $scene stuck after ${secs}s, sample 1"
    say "$DEV" diag 12 || true
    sleep 5
    echo "== sample 2 (deltas are over the last 5s)"
    say "$DEV" diag 12 || true
    echo "== log"
    say "$DEV" log 20 || true
  } > "$f" 2>&1
  echo "       $f"
  resolve_report "$f"
  say "$DEV" relaunch 10 >/dev/null || true
  # Back up, on the same build, from the next scene.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 2
    say "$DEV" ping 4 | grep -q pong && break
  done
  say "$DEV" "overlay off" 6 >/dev/null || true
}

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
  # The gallery's strip of live numbers ticks twice a second through the
  # scenes and its frame costs them stalls (run 35 against 36, 2026-09-14).
  # Frozen for the host's runs, so their sums compare with the runs before
  # the strip; a run from the console's own TESTS tab keeps it live.
  put "1"      "ux0:data/flutter-vita/hud.off"
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
  # And the resume state, so this run starts from scene one. The app clears
  # both itself when it finishes; this covers a run that never did.
  put "[]"     "ux0:data/flutter-vita/bench-partial.json"
  put "-"      "ux0:data/flutter-vita/bench-scene"
  # The watchdog's report, if it fires during this run. Cleared for the same
  # reason: there is no rm, and a stale report reads as this run's.
  put "-"      "ux0:data/flutter-vita/stall.txt"

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
  # Retried, because the first sample can be too early: sceDisplayGetFrameBuf
  # has nothing to report until the layer has presented once.
  local actual=unknown backend=unknown info=""
  for _ in 1 2 3 4 5 6 7 8; do
    info="$(say "$DEV" shotinfo 8)"
    # The GL side names its backend (ADR-0019); vitaGL was the other name
    # until 2026-09-14.
    case "$info" in
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
  local done=0 scene="" scene_at=0 stuck_n=0 now
  # nc's -w is an idle timeout, and the dev server keeps a connection open
  # for the next command, so every query here costs the full -w. Two seconds
  # is plenty now that nc -4 skips the 5 s AAAA lookup (see deploy.sh): a
  # miss only delays a poll.
  for i in $(seq 1 600); do
    if say "$DEV" "get ux0:data/flutter-vita/bench-done" 2 | grep -q '^1'; then
      done=1; break
    fi
    # Which scene, every other poll. Printed when it changes, so the run
    # reads as progress rather than as silence -- and timed, so a scene that
    # never ends is caught here rather than by someone watching the console.
    if [ $((i % 2)) -eq 0 ]; then
      local s
      s="$(say "$DEV" "get ux0:data/flutter-vita/bench-scene" 2 | tr -d '\r\n' || true)"
      now=$(date +%s)
      if [ -n "$s" ] && [ "$s" != "$scene" ]; then
        scene="$s"; scene_at=$now
        echo "    $(date +%H:%M:%S) scene $scene"
      elif [ -n "$scene" ] && [ "$scene" != "-" ] && [ $((now - scene_at)) -ge "$STUCK_AFTER" ]; then
        stuck_n=$((stuck_n + 1))
        on_stuck "$mode" "${scene##* }" "$((now - scene_at))" "$stuck_n"
        scene=""; scene_at=$now
      fi
    fi
    sleep 2
  done
  [ "$done" -eq 1 ] || { echo "!! $mode: the run never finished" >&2; return 1; }

  # The watchdog's evidence, if it fired: stall.txt starts with a sample header
  # rather than the dash written at arming.
  local stall
  stall="$(say "$DEV" "get ux0:data/flutter-vita/stall.txt" 20 || true)"
  if [ "${stall#==}" != "$stall" ]; then
    printf '%s\n' "$stall" > "$OUT_DIR/$mode-stall.txt"
    say "$DEV" "get ux0:data/flutter-vita/stall.log" 30 > "$OUT_DIR/$mode-stall.log" || true
    echo "    !! the app's watchdog relaunched it during this run"
    echo "       $OUT_DIR/$mode-stall.txt (two diag samples), $OUT_DIR/$mode-stall.log"
    resolve_report "$OUT_DIR/$mode-stall.txt"
  fi

  say "$DEV" "get ux0:data/flutter-vita/bench-result.json" 30 \
    > "$OUT_DIR/$mode.json"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT_DIR/$mode.json" \
    || { echo "!! $mode: result file is not valid JSON" >&2; return 1; }
  echo "    $OUT_DIR/$mode.json"
}

# The conformance and hardware suites: arm the switch, relaunch (or deploy),
# wait for the done marker, pull the result. No renderer flip, no baseline;
# their verdicts are pass counts, printed here and kept as JSON.
run_suite() {  # <conformance|hardware>
  local suite="$1"
  echo "==> $suite: arming"
  put "0" "ux0:data/flutter-vita/bench.on"
  put "0" "ux0:data/flutter-vita/software.on"
  put "0" "ux0:data/flutter-vita/hud.off"
  put "1" "ux0:data/flutter-vita/$suite.on"
  put "0" "ux0:data/flutter-vita/$suite-done"
  put "-" "ux0:data/flutter-vita/stall.txt"
  if [ "$RELAUNCH" -eq 1 ] && say "$DEV" ping 4 | grep -q pong; then
    echo "==> $suite: relaunching the installed build"
    say "$DEV" relaunch 10 >/dev/null || true
  elif say "$DEV" ping 4 | grep -q pong; then
    echo "==> $suite: relaunching the installed build (deployed for the scenes)"
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
  scenes|all) ;;
  conformance|hardware)
    run_suite "$SUITE"
    exit $? ;;
  *) echo "unknown suite: $SUITE (scenes, conformance, hardware, all)" >&2; exit 2 ;;
esac

MODES="sw gl"
[ -n "$ONLY" ] && MODES="$ONLY"
for m in $MODES; do run_one "$m"; done
if [ "$SUITE" = all ]; then
  RELAUNCH=1
  run_suite conformance || true
  run_suite hardware || true
fi

# What renderer the console is left on.
#
# This used to be software unconditionally, because a hard crash under GL wedges
# the console (ADR-0014). Two things changed on 2026-09-01: the reservation that
# took GXM down became checked and the shader that would not link linked (both
# in vitaGL then, docs/results/shader-compile-failures-2026-09-01.md). The old
# default meanwhile left every app launched after a bench run silently on the
# software path, including runs read as GL.
#
# So the resting state is GL, and --leave sw restores the old behaviour.
put "$([ "$LEAVE" = sw ] && echo 1 || echo 0)" "ux0:data/flutter-vita/software.on"
put "0" "ux0:data/flutter-vita/bench.on"
put "0" "ux0:data/flutter-vita/hud.off"

echo
python3 "$HERE/bench-report.py" \
  --out "$OUT_DIR" --baseline "$BASELINE_DIR" --modes "$MODES" \
  ${WRITE_BASELINE:+$([ "$WRITE_BASELINE" -eq 1 ] && echo --write-baseline)} \
  ${WRITE_BASELINE:+$([ "$WRITE_BASELINE" -eq 2 ] && echo --add-to-baseline)}
