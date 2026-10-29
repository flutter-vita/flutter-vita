#!/usr/bin/env bash
# Build-to-running in one command, without touching the console.
#
#   ./tools/deploy.sh samples/gallery               build, then deploy
#   ./tools/deploy.sh samples/gallery --no-build   deploy what is already built
#   ./tools/deploy.sh --vpk path/to/app.vpk
#   ./tools/deploy.sh --vpk x.vpk --bridge-port 1342
#
# The tap was never necessary while the app was alive. `handoff` has been in the
# dev server since M1: the app launches the bridge and exits, and the bridge
# can replace an eboot.bin the app could not replace itself.
#
# So the order is: hand off if the app is up, use the bridge if it is up, and
# only ask for a tap when neither answers.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# fluttervita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often. VITA_HOST still overrides
# it, and an IP is still the right answer when the name will not resolve.
HOST="${VITA_HOST:-fluttervita.local}"
# Wait for the name, do not go round it.
#
# The responder lives inside whichever of the app and the bridge is running,
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
  # The system resolver: mDNSResponder on macOS, nss-mdns on Linux. A miss
  # costs dscacheutil 10 s, so the limit is in seconds, not attempts.
  local deadline=$((SECONDS + 20))
  while :; do
    if command -v getent >/dev/null 2>&1; then
      getent ahostsv4 "$HOST" >/dev/null 2>&1 && return 0
    else
      dscacheutil -q host -a name "$HOST" 2>/dev/null | grep -q '^ip_address:' && return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 2
  done
  echo "!! $HOST does not resolve after 20 s." >&2
  echo "   The responder runs inside the app or the bridge, so nothing" >&2
  echo "   answers while neither is up. Open the bridge on the console." >&2
  echo "   If one is running, read ux0:data/flutter-vita/mdns.txt: a zero" >&2
  echo "   'joined' means the console never hears a query, and a rising" >&2
  echo "   'sendfail' means its announcements are not leaving. 'joined 1'" >&2
  echo "   with 'queries 0' means no multicast reaches it: is this Mac on" >&2
  echo "   5 GHz? The Vita has 2.4 GHz only, and many routers drop multicast" >&2
  echo "   between the two radios (docs/configure-console.md)." >&2
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
    # Which bridge to deploy through. The Flutter bridge (ADR-0016) is tested
    # from a scratch slot on 1342 before it ever replaces the one on 1341.
    --bridge-port) LDR="$2"; shift 2 ;;
    --vpk)       VPK="$2"; BUILD=0; shift 2 ;;
    --no-build)  BUILD=0; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           APP_DIR="$1"; shift ;;
  esac
done

# -4 on every nc here and in the other tools. Without it macOS asks mDNS for
# an AAAA record first, the console's responder has no IPv6 to answer with,
# and getaddrinfo waits the full 5.00 s before it falls back to the A record.
# Measured 2026-09-14: connect 5.01 s, reply 0.01 s; with -4 the whole ping is
# 0.06 s. That one lookup was the "cold bridge" of every earlier note, and
# it was paid once per file below: the 454-file wonderous bundle took 45 min.
say()  { printf '%s\n' "$2" | nc -4 -w "${3:-30}" "$HOST" "$1" 2>/dev/null; }
# Retried, because one connect is not evidence: the listeners are non-blocking
# and a single probe races the accept loop.
alive() {
  local port="$1" want="$2"
  # Six, not three: measured on 2026-08-21, the bridge answered on the fifth
  # probe from a cold connect. Three tries reported a live bridge as dead and
  # sent the script down the "wait for a human tap" path for no reason. (Most
  # of that "cold" was the 5 s AAAA lookup above; the retries stay, because a
  # bridge that has just started is a real case too.)
  for _ in 1 2 3 4 5 6; do
    say "$port" ping 6 | grep -q "$want" && return 0
    sleep 1
  done
  return 1
}

if [ "$BUILD" -eq 1 ]; then
  [ -n "$APP_DIR" ] || { echo "which app? e.g. ./tools/deploy.sh samples/gallery" >&2; exit 2; }
  "$HERE/build-vita-app.sh" "$APP_DIR" || exit 1
fi
if [ -z "$VPK" ]; then
  [ -n "$APP_DIR" ] || { echo "no --vpk and no app directory" >&2; exit 2; }
  VPK="$(find "$ROOT/$APP_DIR/build/vita" -maxdepth 1 -name '*.vpk' 2>/dev/null | head -1)"
  [ -n "$VPK" ] || VPK="$(find "$APP_DIR/build/vita" -maxdepth 1 -name '*.vpk' 2>/dev/null | head -1)"
fi
[ -f "$VPK" ] || { echo "!! no .vpk found — build first" >&2; exit 1; }

echo "==> $(basename "$VPK")"

# 1. Get to the bridge, by whatever route needs the least of the human.
if alive "$LDR" bridge; then
  echo "    bridge already up"
elif alive "$DEV" pong; then
  echo "    app is up — handing off to the bridge"
  say "$DEV" handoff 20 >/dev/null
  for i in $(seq 1 20); do
    alive "$LDR" bridge && break
    sleep 3
  done
  alive "$LDR" bridge || { echo "!! handoff did not bring the bridge up" >&2; exit 1; }
  echo "    bridge up, no tap needed"
else
  echo "    nothing is answering — a hard crash, so this one needs a tap"
  echo "    >>> open Flutter Bridge; waiting up to 10 min"
  for i in $(seq 1 200); do
    alive "$LDR" bridge && break
    sleep 3
  done
  alive "$LDR" bridge || { echo "!! bridge never appeared" >&2; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$VPK" -d "$WORK"
[ -s "$WORK/eboot.bin" ] || { echo "!! no eboot.bin in the vpk" >&2; exit 1; }

SIZE="$(wc -c < "$WORK/eboot.bin" | tr -d ' ')"
echo "==> staging eboot.bin ($SIZE bytes)"
{ printf 'stage %s\n' "$SIZE"; cat "$WORK/eboot.bin"; } \
  | nc -4 -w 300 "$HOST" "$LDR" | grep -q OK || {
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
       | nc -4 -w 180 "$HOST" "$LDR" | grep -q OK; then
    printf '%s %s\n' "$want" "$rel" >> "$NEXT"
    pushed=$((pushed + 1))
  else
    echo "    !! push failed: $rel" >&2
  fi
done < "$LIST"
printf '    %d pushed, %d already there\n' "$pushed" "$skipped"

# pic0.png, the picture the system shows while it loads the app, is read from
# ur0:appmeta/<id> and not from ux0:app. A promote copies it there, also over
# an installed title (measured 2026-10-29); this route does not promote, so it
# writes it there itself. Without a splash the old one goes, or it would show.
if [ -f "$WORK/sce_sys/pic0.png" ]; then
  fsize="$(wc -c < "$WORK/sce_sys/pic0.png" | tr -d ' ')"
  { printf 'put %s ur0:appmeta/%s/pic0.png\n' "$fsize" "$TITLEID"; cat "$WORK/sce_sys/pic0.png"; } \
    | nc -4 -w 60 "$HOST" "$LDR" | grep -q OK || echo "    !! push failed: pic0.png" >&2
else
  say "$LDR" "rm ur0:appmeta/$TITLEID/pic0.png" 10 >/dev/null || true
fi

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
no_rm=0
while read -r rel; do
  [ -n "$rel" ] || continue
  if [ "$no_rm" -eq 1 ]; then
    # The bridge has no `rm`; it said so for the first file and would say so
    # for every one. Asking again per file cost a hung connection and the
    # whole time budget on 2026-09-13.
    awk -v r="$rel" '$2 == r { print; exit }' "$HAVE" >> "$NEXT"
    rmfail=$((rmfail + 1))
    continue
  fi
  printf '    removing %s\n' "$rel"
  reply="$(say "$LDR" "rm ux0:app/$TITLEID/$rel" 20)"
  case "$reply" in
    OK*) removed=$((removed + 1)) ;;
    *)
      echo "    !! rm $rel: ${reply:-no reply} — retried next deploy" >&2
      case "$reply" in *"not served here"*) no_rm=1 ;; esac
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
  # The likeliest reason, and the fix. A bridge built before `rm` existed
  # refuses the line rather than failing at it, and says so every deploy.
  echo "    (a bridge without \`rm\` answers ERR here — ./tools/selfupdate-bridge.sh)" >&2
fi

# Written last, and only naming files the device confirmed. A push that failed
# is absent from it and is retried next run.
#
# Retried, like the install and unlike the first version of this. The write is
# small and idempotent, and the bridge's listener is non-blocking and single
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
      | nc -4 -w 60 "$HOST" "$LDR" | grep -q OK && { ok=1; break; }
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
