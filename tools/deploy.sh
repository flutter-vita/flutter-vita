#!/usr/bin/env bash
# Build-to-running in one command, without touching the console.
#
#   ./tools/deploy.sh apps/conformance          build, then deploy
#   ./tools/deploy.sh apps/gallery --no-build   deploy what is already built
#   ./tools/deploy.sh --vpk path/to/app.vpk
#   ./tools/deploy.sh --vpk x.vpk --receiver-port 1342
#
# The tap was never necessary while the app was alive. `handoff` has been in the
# dev server since M1: the app launches the receiver and exits, and the receiver
# can replace an eboot.bin the app could not replace itself.
#
# So the order is: hand off if the app is up, use the receiver if it is up, and
# only ask for a tap when neither answers.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# flutter-vita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often. VITA_HOST still overrides
# it, and an IP is still the right answer when the name will not resolve.
HOST="${VITA_HOST:-flutter-vita.local}"
# Wait for the name, do not go round it.
#
# The responder lives inside whichever of the app and the receiver is running,
# so the name goes dark for the seconds between one exiting and the other
# answering. This used to resolve the name to an address and carry that
# address through the run, which papered over the gap.
#
# It also papered over everything else. An address in hand survives the console
# changing lease and the laptop changing network, and then reports a live
# console as dead. Retrying the name costs the same seconds and tells the
# truth: if it never comes back, nothing is running, and that is the answer.
wait_for_name() {
  case "$HOST" in
    *[!0-9.]*) ;;
    *) echo "!! $HOST is an address. This tool addresses the console by name." >&2
       exit 2 ;;
  esac
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if python3 -c "import socket,sys
try:
    socket.gethostbyname(sys.argv[1])
except OSError:
    raise SystemExit(1)" "$HOST" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "!! $HOST does not resolve after 20 s." >&2
  echo "   The responder runs inside the app or the receiver, so nothing" >&2
  echo "   answers while neither is up. Open the receiver on the console." >&2
  echo "   If one is running, read ux0:data/flutter-vita/mdns.txt: a zero" >&2
  echo "   'joined' means the console never hears a query, and a rising" >&2
  echo "   'sendfail' means its announcements are not leaving." >&2
  exit 1
}
wait_for_name
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
    # Which receiver to deploy through. The Flutter receiver (ADR-0016) is tested
    # from a scratch slot on 1342 before it ever replaces the one on 1341.
    --receiver-port) LDR="$2"; shift 2 ;;
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
  # Six, not three: measured on 2026-08-21, the receiver answered on the fifth
  # probe from a cold connect. Three tries reported a live receiver as dead and
  # sent the script down the "wait for a human tap" path for no reason.
  for _ in 1 2 3 4 5 6; do
    # "receiver" matches both the C receiver's bare reply and the Flutter
    # receiver's "pong receiver <slot> <port>".
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

# 1. Get to the receiver, by whatever route needs the least of the human.
if alive "$LDR" receiver; then
  echo "    receiver already up"
elif alive "$DEV" pong; then
  echo "    app is up — handing off to the receiver"
  say "$DEV" handoff 20 >/dev/null
  for i in $(seq 1 20); do
    alive "$LDR" receiver && break
    sleep 3
  done
  alive "$LDR" receiver || { echo "!! handoff did not bring the receiver up" >&2; exit 1; }
  echo "    receiver up, no tap needed"
else
  echo "    nothing is answering — a hard crash, so this one needs a tap"
  echo "    >>> open Flutter Vita Receiver; waiting up to 10 min"
  for i in $(seq 1 200); do
    alive "$LDR" receiver && break
    sleep 3
  done
  alive "$LDR" receiver || { echo "!! receiver never appeared" >&2; exit 1; }
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
# builds. The hash is recorded only after the device confirms, so a failed push
# retries next time rather than being remembered as done.
#
# The record lives on the console, not here, and that is the point. It used to
# be out/.pushed/<titleid>/ on this machine, a cache of what the host believes
# the device holds -- and the host is not told when that stops being true.
# Promoting a package replaces ux0:app/<id> wholesale, and after one of those
# the stamps still said everything was pushed: the gallery deployed clean, sent
# nothing, and died on "Must be able to initialize the ICU context".
#
# One `get` at the start and one `put` at the end. A wiped directory takes the
# manifest with it, so the next deploy pushes everything.
MANIFEST="ux0:app/$TITLEID/.deploy-manifest"
# Outside $WORK, because the file list below is a find over $WORK and these
# two would be in it -- the first version of this pushed its own bookkeeping
# to the console.
HAVE="$(mktemp)"
NEXT="$(mktemp)"
LIST="$(mktemp)"
trap 'rm -rf "$WORK" "$HAVE" "$NEXT" "$LIST"' EXIT
say "$LDR" "get $MANIFEST" 60 > "$HAVE" 2>/dev/null || true
# `get` on a missing file answers with an error line rather than nothing.
grep -q '^ERR' "$HAVE" 2>/dev/null && : > "$HAVE"

# The build's file list, in a file rather than a heredoc, because the removal
# pass below has to ask it "is this path still in the build" once per manifest
# line and a failed push must not read as a removal.
( cd "$WORK" && find . -type f ! -name eboot.bin \
    \( -not -path "./sce_sys/*" -o -path "./sce_sys/param2.sfo" \) \
    | sed 's|^\./||' | sort ) > "$LIST"

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
done < "$LIST"
printf '    %d pushed, %d already there\n' "$pushed" "$skipped"

# Files the console has and the build no longer does.
#
# Without this the deploy only ever adds and overwrites, and anything dropped
# from a package stays in ux0:app/<titleid> for the life of the install. On
# 2026-09-09 assets/fonts/NotoEmoji-Regular.ttf was removed from the repo, from
# tools/package-engine.sh and from templates/vita-app/CMakeLists.txt, the
# gallery was rebuilt and deployed clean -- and `ls ux0:app/FVTA00002/fonts`
# still listed it at 1,982,596 bytes beside the three files the build ships. It
# was still in app0:/fonts and still a candidate for every codepoint, so the
# removal it was supposed to demonstrate could not be observed at all.
#
# Two sources, because neither is enough on its own.
#
# The manifest is what this script pushed and is the only record that reaches
# into directories the build has stopped filling entirely. It is not the truth
# about the console, though: the deploy that drops a file also drops its line,
# so a file stranded by an earlier version of this script is not in it -- which
# is exactly the case above -- and a promote replaces ux0:app/<id> wholesale
# without telling the host, which is the failure the comment on MANIFEST above
# records.
#
# `ls` is the truth, and is asked only about the directories this build fills.
# sce_sys is not one of them: the build list names sce_sys/param2.sfo alone,
# and param.sfo and the LiveArea beside it were written by the install and are
# not this pass's to remove.
echo "==> stale files"
GONE="$(mktemp)"
DIRS="$(mktemp)"
LSOUT="$(mktemp)"
trap 'rm -rf "$WORK" "$HAVE" "$NEXT" "$LIST" "$GONE" "$DIRS" "$LSOUT"' EXIT
: > "$GONE"

while read -r sha rel; do
  [ -n "$rel" ] || continue
  # The manifest is read back off the console, so it is input. A path that
  # climbs out of the title's directory is not one this may act on, and is not
  # one worth carrying forward either.
  case "$rel" in
    /*|*..*) echo "    !! not touching odd manifest path: $rel" >&2; continue ;;
  esac
  grep -qxF "$rel" "$LIST" || printf '%s\n' "$rel" >> "$GONE"
done < "$HAVE"

# The dirname of every file in the build, plus the root for the files that have
# none. `ls` caps at 200 entries, so a very large directory is swept in part --
# that costs a stale file left behind, never a live one removed.
{ sed -n 's|/[^/]*$||p' "$LIST" | grep -v '^sce_sys' | sort -u; echo "."; } \
  | sort -u > "$DIRS"
while read -r dir; do
  if [ "$dir" = "." ]; then
    base="ux0:app/$TITLEID"; prefix=""
  else
    base="ux0:app/$TITLEID/$dir"; prefix="$dir/"
  fi
  say "$LDR" "ls $base" 60 > "$LSOUT" 2>/dev/null || continue
  # `-` is a file; `d` is a directory and is left alone, and so are the ERR and
  # `(N entries)` lines, none of which start with one.
  while read -r kind name; do
    [ "$kind" = "-" ] || continue
    [ -n "$name" ] || continue
    rel="$prefix$name"
    # Neither is in the build list and both belong on the console: eboot.bin is
    # installed rather than pushed, and the manifest is this script's own.
    case "$rel" in
      eboot.bin|.deploy-manifest) continue ;;
    esac
    grep -qxF "$rel" "$LIST" && continue
    grep -qxF "$rel" "$GONE" || printf '%s\n' "$rel" >> "$GONE"
  done < "$LSOUT"
done < "$DIRS"

removed=0
rmfail=0
while read -r rel; do
  [ -n "$rel" ] || continue
  printf '    removing %s\n' "$rel"
  reply="$(say "$LDR" "rm ux0:app/$TITLEID/$rel" 60)"
  case "$reply" in
    OK*) removed=$((removed + 1)) ;;
    *)
      echo "    !! rm $rel: ${reply:-no reply} — retried next deploy" >&2
      # Back into the manifest if it was ever in it, because the manifest
      # records what the console holds and the console still holds this.
      awk -v r="$rel" '$2 == r { print; exit }' "$HAVE" >> "$NEXT"
      rmfail=$((rmfail + 1)) ;;
  esac
done < "$GONE"
if [ "$removed" -eq 0 ] && [ "$rmfail" -eq 0 ]; then
  echo "    none"
else
  printf '    %d removed, %d could not be\n' "$removed" "$rmfail"
fi
if [ "$rmfail" -gt 0 ]; then
  # The likeliest reason, and the fix. A receiver built before `rm` existed
  # refuses the line rather than failing at it, and says so every deploy.
  echo "    (a receiver without \`rm\` answers ERR here — ./tools/selfupdate-receiver.sh)" >&2
fi

# Written last, and only naming files the device confirmed. A push that failed
# is absent from it and is retried next run.
#
# Retried, like the install and unlike the first version of this. The write is
# small and idempotent, and the receiver's listener is non-blocking and single
# threaded -- the same race `alive` probes six times for. On 2026-09-09 a
# deploy printed "could not record the manifest" and the manifest was on the
# console, complete and correct: the put had landed and the reply had not been
# read. A retry costs a second and stops the script lying about the one file
# whose whole job is to be believed next run.
msize="$(wc -c < "$NEXT" | tr -d ' ')"
if [ "${msize:-0}" -gt 0 ]; then
  ok=0
  for _ in 1 2 3; do
    { printf 'put %s %s\n' "$msize" "$MANIFEST"; cat "$NEXT"; } \
      | nc -w 60 "$HOST" "$LDR" | grep -q OK && { ok=1; break; }
    sleep 2
  done
  [ "$ok" -eq 1 ] || echo "    !! could not record the manifest" >&2
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
