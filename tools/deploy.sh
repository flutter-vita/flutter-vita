#!/usr/bin/env bash
# Build-to-running in one command, without touching the console.
#
#   ./tools/deploy.sh apps/conformance          build, then deploy
#   ./tools/deploy.sh apps/gallery --no-build   deploy what is already built
#   ./tools/deploy.sh --vpk path/to/app.vpk
#
# The tap was never necessary while the app was alive. `handoff` has been in
# the dev server since M1 -- the app launches the loader and exits, and the
# loader can then replace an eboot.bin the app could not replace itself -- and
# every test script in this project has instead sat waiting for a human to open
# the loader. That was a scripting mistake, not a missing feature, and it cost
# a tap per iteration for weeks.
#
# So the order is: hand off if the app is up, use the loader if it is up, and
# only ask for a tap when neither answers -- which, with ADR-0011's clean exit
# on foreseeable failures, now means a genuine wild-pointer crash.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOST="${VITA_HOST:-192.168.0.32}"
DEV=1339
LDR=1341
TITLEID="FVTA00002"
APP_DIR=""
VPK=""
BUILD=1
LAUNCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --host)      HOST="$2"; shift 2 ;;
    --vpk)       VPK="$2"; BUILD=0; shift 2 ;;
    --no-build)  BUILD=0; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           APP_DIR="$1"; shift ;;
  esac
done

say()  { printf '%s\n' "$2" | nc -w "${3:-30}" "$HOST" "$1" 2>/dev/null; }
# Retried, because one connect is not evidence: the listeners are non-blocking
# and a single probe races the accept loop.
alive() {
  local port="$1" want="$2"
  # Six, not three: measured on 2026-08-21, the loader answered on the fifth
  # probe from a cold connect. Three tries reported a live loader as dead and
  # sent the script down the "wait for a human tap" path for no reason.
  for _ in 1 2 3 4 5 6; do
    say "$port" ping 6 | grep -q "$want" && return 0
    sleep 1
  done
  return 1
}

if [ "$BUILD" -eq 1 ]; then
  [ -n "$APP_DIR" ] || { echo "which app? e.g. ./tools/deploy.sh apps/gallery" >&2; exit 2; }
  "$HERE/build-vita-app.sh" "$APP_DIR" || exit 1
fi
if [ -z "$VPK" ]; then
  [ -n "$APP_DIR" ] || { echo "no --vpk and no app directory" >&2; exit 2; }
  VPK="$(find "$ROOT/$APP_DIR/build/vita" -maxdepth 1 -name '*.vpk' 2>/dev/null | head -1)"
  [ -n "$VPK" ] || VPK="$(find "$APP_DIR/build/vita" -maxdepth 1 -name '*.vpk' 2>/dev/null | head -1)"
fi
[ -f "$VPK" ] || { echo "!! no .vpk found — build first" >&2; exit 1; }

echo "==> $(basename "$VPK")"

# 1. Get to the loader, by whatever route needs the least of the human.
if alive "$LDR" loader; then
  echo "    loader already up"
elif alive "$DEV" pong; then
  echo "    app is up — handing off to the loader"
  say "$DEV" handoff 20 >/dev/null
  for i in $(seq 1 20); do
    alive "$LDR" loader && break
    sleep 3
  done
  alive "$LDR" loader || { echo "!! handoff did not bring the loader up" >&2; exit 1; }
  echo "    loader up, no tap needed"
else
  echo "    nothing is answering — a hard crash, so this one needs a tap"
  echo "    >>> open Flutter Vita Loader; waiting up to 10 min"
  for i in $(seq 1 200); do
    alive "$LDR" loader && break
    sleep 3
  done
  alive "$LDR" loader || { echo "!! loader never appeared" >&2; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$VPK" -d "$WORK"
[ -s "$WORK/eboot.bin" ] || { echo "!! no eboot.bin in the vpk" >&2; exit 1; }

SIZE="$(wc -c < "$WORK/eboot.bin" | tr -d ' ')"
echo "==> staging eboot.bin ($SIZE bytes)"
{ printf 'stage %s\n' "$SIZE"; cat "$WORK/eboot.bin"; } \
  | nc -w 300 "$HOST" "$LDR" | grep -q OK || {
    echo "!! stage failed — wifi drop mid-transfer?" >&2; exit 1; }

echo "==> installing"
ok=0
for _ in 1 2 3; do
  say "$LDR" install 90 | grep -q OK && { ok=1; break; }
  sleep 2
done
[ "$ok" -eq 1 ] || { echo "!! install failed" >&2; exit 1; }

# Data files, only the ones that changed.
#
# icudtl.dat and the fonts are 2.7 MiB between them and never change between
# builds; re-sending them every cycle would add a transfer to every iteration
# for nothing. The hash is recorded only after the device confirms, so a failed
# push retries next time rather than being remembered as done.
STAMP="$ROOT/out/.pushed/$TITLEID"
mkdir -p "$STAMP"
echo "==> data files"
( cd "$WORK" && find . -type f ! -name eboot.bin \
    \( -not -path "./sce_sys/*" -o -path "./sce_sys/param2.sfo" \) | sed 's|^\./||' ) \
| while read -r rel; do
    want="$(shasum -a 1 "$WORK/$rel" | cut -d' ' -f1)"
    have=""; [ -f "$STAMP/${rel//\//_}" ] && have="$(cat "$STAMP/${rel//\//_}")"
    [ "$want" = "$have" ] && continue
    fsize="$(wc -c < "$WORK/$rel" | tr -d ' ')"
    printf '    %s (%s B)\n' "$rel" "$fsize"
    if { printf 'put %s ux0:app/%s/%s\n' "$fsize" "$TITLEID" "$rel"; cat "$WORK/$rel"; } \
         | nc -w 180 "$HOST" "$LDR" | grep -q OK; then
      echo "$want" > "$STAMP/${rel//\//_}"
    else
      echo "    !! push failed: $rel" >&2
    fi
  done

if [ "$LAUNCH" -eq 1 ]; then
  echo "==> launching"
  for _ in 1 2 3 4 5; do
    say "$LDR" launch 20 | grep -q "OK launching" && break
    sleep 3
  done
  for i in $(seq 1 20); do
    alive "$DEV" pong && { echo "    up on $DEV after $((i * 3))s"; exit 0; }
    sleep 3
  done
  echo "!! the app never opened $DEV" >&2
  exit 2
fi
