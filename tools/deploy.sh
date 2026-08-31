#!/usr/bin/env bash
# Build-to-running in one command, without touching the console.
#
#   ./tools/deploy.sh apps/conformance          build, then deploy
#   ./tools/deploy.sh apps/gallery --no-build   deploy what is already built
#   ./tools/deploy.sh --vpk path/to/app.vpk
#   ./tools/deploy.sh --vpk x.vpk --loader-port 1342
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
# flutter-vita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often. VITA_HOST still overrides
# it, and an IP is still the right answer when the name will not resolve.
HOST="${VITA_HOST:-flutter-vita.local}"

# Resolve the name once, then work in addresses for the rest of the run.
#
# Not premature. This script hands the app off to the loader and then keeps
# talking, and the mDNS responder lives in whichever of the two is running --
# so the name goes dark for the seconds between the app exiting and the loader
# answering. The first deploy after adding mDNS failed exactly there: staged
# fine, then "install failed", because the name stopped resolving mid-run.
#
# Resolving once removes the window. It also means a console that drops off the
# network mid-deploy fails with a connection error against a real address
# rather than a name lookup, which is the more legible of the two.
case "$HOST" in
  *[!0-9.]*)
    RESOLVED="$(python3 -c "import socket,sys
try: print(socket.gethostbyname(sys.argv[1]))
except OSError: pass" "$HOST" 2>/dev/null)"
    if [ -n "$RESOLVED" ]; then
      echo "    $HOST is $RESOLVED"
      HOST="$RESOLVED"
    else
      echo "!! $HOST does not resolve." >&2
      echo "   The responder runs inside the app or the loader, so nothing" >&2
      echo "   answers while neither is up. Set VITA_HOST to an address." >&2
      exit 1
    fi
    ;;
esac
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
    # Which loader to deploy through. The Flutter loader (ADR-0016) is tested
    # from a scratch slot on 1342 before it ever replaces the one on 1341.
    --loader-port) LDR="$2"; shift 2 ;;
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
    # "loader" matches both the C loader's bare reply and the Flutter
    # loader's "pong loader <slot> <port>".
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
#
# The record lives on the console, not here, and that is the whole point.
#
# It used to be out/.pushed/<titleid>/ on this machine, which is a cache of
# what the host believes the device holds -- and the host is not told when that
# stops being true. Promoting a package replaces ux0:app/<id> wholesale, and
# after one of those the stamps still said everything was pushed. The gallery
# deployed clean, printed "==> data files", sent nothing, and died three
# seconds in on "Must be able to initialize the ICU context. Tried:
# app0:/icudtl.dat" -- with the loader cheerfully reporting success, because
# from its point of view nothing had failed.
#
# One `get` at the start and one `put` at the end. A wiped directory takes the
# manifest with it, so the next deploy finds nothing recorded and pushes
# everything, which is exactly the behaviour that was missing.
MANIFEST="ux0:app/$TITLEID/.deploy-manifest"
# Outside $WORK, because the file list below is a find over $WORK and these
# two would be in it -- the first version of this pushed its own bookkeeping
# to the console.
HAVE="$(mktemp)"
NEXT="$(mktemp)"
trap 'rm -rf "$WORK" "$HAVE" "$NEXT"' EXIT
say "$LDR" "get $MANIFEST" 60 > "$HAVE" 2>/dev/null || true
# `get` on a missing file answers with an error line rather than nothing.
grep -q '^ERR' "$HAVE" 2>/dev/null && : > "$HAVE"

echo "==> data files"
: > "$NEXT"
pushed=0
skipped=0
while read -r rel; do
  want="$(shasum -a 1 "$WORK/$rel" | cut -d' ' -f1)"
  if grep -qxF "$want $rel" "$HAVE" 2>/dev/null; then
    printf '%s %s\n' "$want" "$rel" >> "$NEXT"
    skipped=$((skipped + 1))
    continue
  fi
  fsize="$(wc -c < "$WORK/$rel" | tr -d ' ')"
  printf '    %s (%s B)\n' "$rel" "$fsize"
  if { printf 'put %s ux0:app/%s/%s\n' "$fsize" "$TITLEID" "$rel"; cat "$WORK/$rel"; } \
       | nc -w 180 "$HOST" "$LDR" | grep -q OK; then
    printf '%s %s\n' "$want" "$rel" >> "$NEXT"
    pushed=$((pushed + 1))
  else
    echo "    !! push failed: $rel" >&2
  fi
done <<EOF
$( cd "$WORK" && find . -type f ! -name eboot.bin \
    \( -not -path "./sce_sys/*" -o -path "./sce_sys/param2.sfo" \) \
    | sed 's|^\./||' | sort )
EOF
printf '    %d pushed, %d already there\n' "$pushed" "$skipped"

# Written last, and only naming files the device confirmed. A push that failed
# is absent from it and is retried next run.
msize="$(wc -c < "$NEXT" | tr -d ' ')"
if [ "${msize:-0}" -gt 0 ]; then
  { printf 'put %s %s\n' "$msize" "$MANIFEST"; cat "$NEXT"; } \
    | nc -w 60 "$HOST" "$LDR" | grep -q OK \
    || echo "    !! could not record the manifest" >&2
fi

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
