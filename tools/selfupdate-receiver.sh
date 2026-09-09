#!/usr/bin/env bash
# Replace the receiver with a new build, using the receiver itself.
#
#   ./tools/selfupdate-receiver.sh                    build and install
#   ./tools/selfupdate-receiver.sh path/to.vpk        install a built one
#
#   --slot a|b      force the destination slot (default: the one not running)
#   --full          promote the whole vpk instead of copying changed files
#   --port N        the port to talk to      (default 1341)
#   --host NAME     the console              (default flutter-vita.local)
#   --no-build      require the vpk argument
#
# ## Two slots
#
# A running title cannot write its own directory. ux0:app/<self> is the
# read-only app0: mount, and that covers the whole slot: a `put` of a new file
# into it returns ERR open, not just a refusal to overwrite eboot.bin. So a
# receiver can never install itself, and something else has to do the write.
#
# That something else is the other receiver's slot. FVTA00001 and FVTA00005
# both hold a receiver, both listen on 1341, and they take turns:
#
#   A running  ->  write the build into B  ->  launch B  ->  B running
#   B running  ->  write the build into A  ->  launch A  ->  A running
#
# The two slots run the same eboot.bin; the receiver reads its own title id at
# startup rather than having it compiled in. So switching slots regenerates
# param.sfo instead of relinking the engine (9 seconds, not three minutes), and
# a deploy of an unchanged build transfers nothing at all.
#
# One change of application per update, which is the least the shell can do:
# new code needs a new process. About five seconds, most of it the receiver's
# own start.
#
# ## What this replaces
#
# FVTA00009, a 50 KB application whose only job was to copy a staged payload
# over ux0:app/FVTA00001 while the receiver was not running. It cost two
# changes of application and a full 15 MB copy on the card, about thirteen
# seconds of LiveArea, and it was one stale binary away from silently applying
# nothing -- which it did, three deploys in a row, on 2026-09-08.
#
# ## Rescue
#
# The slot that is not running is the rescue, and it is a complete receiver
# that worked rather than a saved eboot. If a new build boots into nothing,
# open the other bubble from the LiveArea: "Flutter Vita Receiver A" or
# "Flutter Vita Receiver B". The panel's title line says which one is up.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# flutter-vita.local, not an address. The dev server answers mDNS for that name
# and this console's address changes whenever its Wi-Fi does.
HOST="${VITA_HOST:-flutter-vita.local}"
PORT="${RECEIVER_PORT:-1341}"
SLOT_A="FVTA00001"
SLOT_B="FVTA00005"
DEST=""
BUILD=1
FULL=0
VPK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slot)
      case "$2" in
        a|A) DEST="$SLOT_A" ;;
        b|B) DEST="$SLOT_B" ;;
        *) echo "--slot takes a or b" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --full)     FULL=1; shift ;;
    --port)     PORT="$2"; shift 2 ;;
    --host)     HOST="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    -h|--help)  sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  VPK="$1"; BUILD=0; shift ;;
  esac
done

say() { printf '%s\n' "$2" | nc -w "${3:-30}" "$HOST" "$1"; }

# ----------------------------------------------------------- which slot is up
#
# The far end has to be a receiver, not an app that happens to hold the port.
# Its pong names itself; anything else and this would be putting a receiver's
# eboot into whatever answered.
PONG="$(say "$PORT" ping 15 || true)"
case "$PONG" in
  pong\ receiver*) ;;
  *) echo "!! no receiver on $HOST:$PORT (got '${PONG:-nothing}')" >&2
     echo "   open a receiver bubble, or pass --port" >&2; exit 1 ;;
esac

# "pong receiver <app slot> <port> <own slot>". The fourth field arrived with
# A/B; a receiver built before it answers three, and every receiver built
# before it lives in A.
RUNNING="$(printf '%s\n' "$PONG" | awk '/^pong receiver/ { print $5 }')"
[ -n "$RUNNING" ] || RUNNING="$SLOT_A"

if [ -z "$DEST" ]; then
  case "$RUNNING" in
    "$SLOT_A") DEST="$SLOT_B" ;;
    "$SLOT_B") DEST="$SLOT_A" ;;
    *) echo "!! $RUNNING is neither $SLOT_A nor $SLOT_B." >&2
       echo "   That is a scratch or hand-built receiver. Pass --slot a or b" >&2
       echo "   to say where the new build should go." >&2; exit 1 ;;
  esac
fi
[ "$DEST" != "$RUNNING" ] || {
  echo "!! $DEST is the slot that is running, and it cannot write itself." >&2
  echo "   Drop --slot and let it pick the other one." >&2; exit 1; }

case "$DEST" in
  "$SLOT_A") SLOT_ARG="a" ;;
  *)         SLOT_ARG="b" ;;
esac

echo "==> $RUNNING is up; the new build goes to $DEST"

if [ "$BUILD" -eq 1 ]; then
  "$HERE/build-receiver.sh" --slot "$SLOT_ARG"
  VPK="$ROOT/receiver/app/build/vita/flutter_vita_receiver.vpk"
fi
[ -f "$VPK" ] || { echo "no vpk at ${VPK:-<none>}" >&2; exit 1; }

WORK="$(mktemp -d)"
SHA="$WORK.sha"
OLDSHA="$WORK.old"
trap 'rm -rf "$WORK" "$SHA" "$OLDSHA"' EXIT
unzip -q "$VPK" -d "$WORK"
[ -s "$WORK/eboot.bin" ] || { echo "!! no eboot.bin in $VPK" >&2; exit 1; }

# eboot.bin is the same file for both slots -- the receiver reads its own title
# id at startup -- so what makes this vpk slot-specific is param.sfo, and
# param.sfo is exactly what a promote writes. Sending the wrong one produces a
# title whose id, name and bubble belong to the other slot.
BUILT_FOR="$(strings "$WORK/sce_sys/param.sfo" 2>/dev/null \
  | grep -m1 -oE '^[A-Z]{4}[0-9]{5}$' || true)"
[ "$BUILT_FOR" = "$DEST" ] || {
  echo "!! $(basename "$VPK") was built for ${BUILT_FOR:-nothing}, and this" >&2
  echo "   update goes to $DEST. Rebuild it:" >&2
  echo "     ./tools/build-receiver.sh --slot $SLOT_ARG" >&2; exit 1; }

put() {  # <local> <device path>
  local size; size=$(wc -c <"$1" | tr -d ' ')
  # `put 0` is refused by the dev server, and this is the second guard on the
  # same mistake: a blank shell expansion once truncated a 12 MB eboot to
  # nothing, and the console then had a receiver that could not start.
  [ "${size:-0}" -gt 0 ] || { echo "!! refusing to put an empty $1" >&2; return 1; }
  { printf 'put %s %s\n' "$size" "$2"; cat "$1"; } | nc -w 300 "$HOST" "$PORT" \
    | grep -q OK || { echo "!! put failed: $2" >&2; return 1; }
  printf '    %-52s %9s B\n' "$2" "$size"
}

# What belongs to the *build*, and so gets copied.
#
# sce_sys/param.sfo and sce_sys/package/ are the installed title's identity:
# its id, its name, the package header the promoter wrote. Writing a build's
# param.sfo over a slot's is how a title stops being itself. A promote is the
# only thing allowed to touch them, which is also why --full is the way to
# change a bubble's name.
PAYLOAD="$( cd "$WORK" && find . -type f \
    ! -name param.sfo ! -path './sce_sys/package/*' \
    | sed 's|^\./||' | sort )"
( cd "$WORK" && printf '%s\n' "$PAYLOAD" | xargs shasum -a 256 ) > "$SHA"
MANIFEST="ux0:app/$DEST/.payload.sha"

# ------------------------------------------------------- promote or copy over
#
# A slot that does not exist has to be promoted: `put` writes files and cannot
# register a title with the shell. Promoting also rewrites param.sfo, which is
# the only way the bubble's name changes, so --full is the way to rename one.
EXISTS=0
case "$(say "$PORT" "stat ux0:app/$DEST/eboot.bin" 20 || true)" in
  ERR*|'') ;;
  *) EXISTS=1 ;;
esac

if [ "$EXISTS" -eq 0 ] || [ "$FULL" -eq 1 ]; then
  [ "$EXISTS" -eq 1 ] || echo "==> $DEST does not exist yet"
  "$HERE/install-vpk.sh" "$VPK" --host "$HOST" --port "$PORT" \
    --title-id "$DEST" --no-launch | sed 's/^/    /'
  put "$SHA" "$MANIFEST"
else
  # ------------------------------------------------------------- changed only
  #
  # The payload is about 15 MB and roughly 12 of those are icudtl.dat and the
  # fonts, which change when the pinned engine changes and never otherwise.
  # Sending them on every deploy was most of the wait.
  #
  # What is on the card is recorded in the card's own copy of the manifest,
  # written last and only after every file has landed. No manifest, or a
  # transfer that died halfway, and the next run sends everything.
  : > "$OLDSHA"
  case "$(say "$PORT" "stat $MANIFEST" 20 || true)" in
    ERR*|'') echo "==> no manifest in $DEST; sending everything" ;;
    *) say "$PORT" "get $MANIFEST" 60 > "$OLDSHA" || : > "$OLDSHA" ;;
  esac

  # Whole lines, so a file counts as unchanged only when its sha and its path
  # both match.
  CHANGED="$(awk 'NR==FNR { seen[$0]=1; next } !($0 in seen) { print $2 }' \
      "$OLDSHA" "$SHA")"

  if [ -z "$CHANGED" ]; then
    echo "==> $DEST already holds this build"
  else
    echo "==> $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ') changed file(s) -> $DEST"
    # eboot.bin last. Everything else is an asset the old binary can also read,
    # so an interrupted run leaves a receiver that still starts, and the file
    # that decides which build runs is written when the transfer has already
    # proved itself over 3 MB of fonts.
    for rel in $(printf '%s\n' "$CHANGED" | grep -vx 'eboot.bin'); do
      put "$WORK/$rel" "ux0:app/$DEST/$rel"
    done
    if printf '%s\n' "$CHANGED" | grep -qx 'eboot.bin'; then
      put "$WORK/eboot.bin" "ux0:app/$DEST/eboot.bin"
    fi
  fi

  # Read the eboot back before believing any of it. `put` renames only after
  # the whole file lands, so a wrong size means the card wrote something other
  # than what was sent.
  WANT="$(wc -c <"$WORK/eboot.bin" | tr -d ' ')"
  GOT="$(say "$PORT" "stat ux0:app/$DEST/eboot.bin" 20 | awk '{ print $1 }')"
  [ "$WANT" = "$GOT" ] || {
    echo "!! ux0:app/$DEST/eboot.bin is ${GOT:-nothing} B, sent $WANT B" >&2
    echo "   $DEST is half written. Do not launch it; run with --full." >&2
    exit 1; }

  # Last, so that anything above going wrong leaves a manifest that no longer
  # describes the slot and the next run resends the lot.
  put "$SHA" "$MANIFEST"
fi

# ------------------------------------------------------------------ hand over
echo "==> handing over to $DEST"
say "$PORT" "launch $DEST" 20 | sed 's/^/    /' || true

echo "==> waiting for $DEST on $HOST:$PORT"
for _ in $(seq 1 30); do
  sleep 2
  BACK="$(say "$PORT" ping 5 2>/dev/null || true)"
  case "$BACK" in
    pong\ receiver*)
      UP="$(printf '%s\n' "$BACK" | awk '/^pong receiver/ { print $5 }')"
      [ -n "$UP" ] || UP="$SLOT_A"
      if [ "$UP" = "$DEST" ]; then
        echo "    $BACK"
        echo
        echo "$DEST is up. $RUNNING is the rescue: open its bubble if this build"
        echo "turns out to be broken."
        exit 0
      fi
      # The old one answering again means the launch was refused and the shell
      # put us back. hand_over retries four times before it gives up, so this
      # is a real refusal rather than the first-attempt race.
      echo "!! $UP answered, not $DEST: the launch was refused." >&2
      echo "   printf 'log\\n' | nc $HOST $PORT | tail -20" >&2
      exit 1 ;;
  esac
done

echo "!! nothing came back on $HOST:$PORT after 60s." >&2
echo "   The console is most likely on the LiveArea. Open the bubble for" >&2
echo "   $RUNNING; its slot was not touched and it still works." >&2
exit 1
