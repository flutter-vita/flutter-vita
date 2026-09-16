#!/usr/bin/env bash
# Replace the receiver with a new build, using the receiver itself.
#
#   ./tools/selfupdate-receiver.sh                    build and install
#   ./tools/selfupdate-receiver.sh path/to.vpk        install a built one
#
#   --title-id ID     which receiver to replace (default FVTA00001)
#   --updater ID      the updater's title id    (default FVTA00009)
#   --keep-updater    leave the updater installed (the default)
#   --remove-updater  delete it afterwards, at the cost of 45 s of LiveArea
#   --full            stage every file, not only the ones that changed
#   --port N          the port to talk to       (default 1341)
#   --host NAME       the console               (default flutter-vita.local)
#   --build-port N    the port to build for     (default: build-receiver.sh's)
#   --no-build        require the vpk argument
#
# A running title cannot write its own directory. ux0:app/<self> is the
# read-only app0: mount, and that covers the whole slot: `put 6
# ux0:app/FVTA00001/wtest.txt` answers ERR open, so it is not only eboot.bin
# that is protected. The receiver is therefore the one thing the receiver
# cannot install, and four steps go around it:
#
#   1. put the files that changed into ux0:data/flutter-vita/receiver-update
#   2. launch FVTA00009, a 50 KB app with no engine whose only job is to copy
#      that tree over ux0:app/<target> and launch the target back
#   3. wait for the new receiver
#
# The updater keeps the eboot it replaces in receiver-backup. If the new build
# boots into nothing, launch "Flutter Receiver Updater" holding L to restore
# it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# flutter-vita.local, not an address. The dev server answers mDNS for that name
# and this console's address changes whenever its Wi-Fi does.
HOST="${VITA_HOST:-flutter-vita.local}"
PORT="${RECEIVER_PORT:-1341}"
TITLE_ID="FVTA00001"
UPDATER="FVTA00009"
BUILD=1
FULL=0
VPK=""
# The port to reach the running receiver on and the port to compile into the new
# one are different numbers whenever a scratch receiver is doing the install.
# They were one option for about ten minutes, which built FVTA00001 to listen
# on the scratch receiver's port.
BUILD_PORT=""
UPDATER_VPK="$ROOT/receiver/updater/build/flutter_vita_updater.vpk"

# The updater stays installed.
#
# It used to be deleted after every update, and the delete is what put the
# console on the LiveArea for the last three quarters of a minute of every
# deploy. Measured 2026-09-09: scePromoterUtilityDeletePkg returned in one
# second, and the 46 seconds after that were the shell rebuilding its title
# list -- which takes the screen and blocks the card, so the receiver's own
# 1 KB write of installed.txt sat there for the whole of it. The receiver never
# died and always came back, but the last thing you saw was the home screen.
#
# Nothing this script does can make the shell quiet about a package being
# removed. So it does not remove one. The cost is a 50 KB bubble that is always
# there, which also means hold-L rollback is always available.
#
# --remove-updater if you want it gone and can spend the 45 seconds.
KEEP_UPDATER=1

while [ $# -gt 0 ]; do
  case "$1" in
    --title-id) TITLE_ID="$2"; shift 2 ;;
    --updater)  UPDATER="$2"; shift 2 ;;
    --keep-updater) KEEP_UPDATER=1; shift ;;
    --remove-updater) KEEP_UPDATER=0; shift ;;
    --full)     FULL=1; shift ;;
    --port)       PORT="$2"; shift 2 ;;
    --build-port) BUILD_PORT="$2"; shift 2 ;;
    --host)     HOST="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  VPK="$1"; BUILD=0; shift ;;
  esac
done

STAGE="ux0:data/flutter-vita/receiver-update"
# Not inside ux0:app/$TITLE_ID. That is the running receiver's own slot, the
# read-only app0: mount this whole script exists to work around, and putting
# the manifest there failed with ERR open on the first run that tried it.
# ux0:data is ordinary storage the receiver writes freely.
MANIFEST_PATH="ux0:data/flutter-vita/$TITLE_ID.payload.sha"

say() { printf '%s\n' "$2" | nc -4 -w "${3:-30}" "$HOST" "$1"; }
# The console is addressed by name, always, everywhere.
#
# An earlier version of this resolved the name once and used the address for
# the rest of the run, to avoid paying mDNS on each of about sixty connections.
# That is gone. An address held anywhere is an address that goes stale, and on
# 2026-09-09 a stale one cost a bench run: the laptop changed network, the
# address in hand pointed at nothing, and a console that was awake and well
# read as asleep for half an hour. The name would have said so at once.
#
# If resolving the name is slow, that is a fault in the responder and it is
# visible in ux0:data/flutter-vita/mdns.txt. Read that instead of caching
# around it.


# The elapsed column is not decoration. It is what found the mDNS cost above:
# a 1.4 KB manifest took the same five seconds as a 12 MB eboot, which is not
# a shape that transfer time can produce.
put() {  # <local> <device path>
  local size; size=$(wc -c <"$1" | tr -d ' ')
  # `put 0` is refused by the dev server, and this is the second guard on the
  # same mistake: a blank shell expansion once truncated a 12 MB eboot to
  # nothing, and the console then had a receiver that could not start.
  [ "${size:-0}" -gt 0 ] || { echo "!! refusing to put an empty $1" >&2; return 1; }
  local t0; t0=$(date +%s)
  { printf 'put %s %s\n' "$size" "$2"; cat "$1"; } | nc -4 -w 300 "$HOST" "$PORT" \
    | grep -q OK || { echo "!! put failed: $2" >&2; return 1; }
  printf '    %-52s %9s B  %3ss\n' "${2#"$STAGE"/files/}" "$size" \
    "$(( $(date +%s) - t0 ))"
}

if [ "$BUILD" -eq 1 ]; then
  set -- --title-id "$TITLE_ID"
  if [ -n "$BUILD_PORT" ]; then set -- "$@" --port "$BUILD_PORT"; fi
  "$HERE/build-receiver.sh" "$@"
  VPK="$ROOT/receiver/app/build/vita/flutter_vita_receiver.vpk"
fi
[ -f "$VPK" ] || { echo "no vpk at ${VPK:-<none>}" >&2; exit 1; }

# The far end has to be a receiver, not an app that happens to hold the port.
# Its pong names itself; anything else and this would be putting a receiver's
# eboot into whatever answered.
PONG="$(say "$PORT" ping 15 || true)"
case "$PONG" in
  pong\ receiver*) ;;
  *) echo "!! no receiver on $HOST:$PORT (got '${PONG:-nothing}')" >&2
     echo "   open the receiver, or pass --port" >&2; exit 1 ;;
esac

WORK="$(mktemp -d)"
SHA="$WORK.sha"
OLDSHA="$WORK.old"
trap 'rm -rf "$WORK" "$SHA" "$OLDSHA"' EXIT
unzip -q "$VPK" -d "$WORK"
[ -s "$WORK/eboot.bin" ] || { echo "!! no eboot.bin in $VPK" >&2; exit 1; }

# sce_sys/param.sfo and sce_sys/package/ are the *installed* title's identity:
# its id, its name, the package header the promoter wrote. The payload is a
# build of the receiver, which may have been built for a different slot, and
# writing its param.sfo over FVTA00001's is how a title stops being itself.
# The LiveArea art is not identity and is copied.
PAYLOAD="$( cd "$WORK" && find . -type f \
    ! -name param.sfo ! -path './sce_sys/package/*' \
    | sed 's|^\./||' | sort )"
( cd "$WORK" && printf '%s\n' "$PAYLOAD" | xargs shasum -a 256 ) > "$SHA"

# ------------------------------------------------------------- changed only
#
# The payload is about 15 MB and roughly 3 of those are icudtl.dat and the
# fonts, which change when the pinned engine changes and never otherwise. The
# updater copies what the manifest lists and nothing else, so staging only the
# files that differ shortens both halves of the update at once.
#
# What the console already holds is recorded in a manifest this script writes,
# last, and only after the update has been confirmed. No manifest, or a run
# that died halfway, and the next one stages everything.
: > "$OLDSHA"
if [ "$FULL" -eq 0 ]; then
  case "$(say "$PORT" "stat $MANIFEST_PATH" 20 || true)" in
    ERR*|'') echo "==> no manifest for $TITLE_ID; staging everything" ;;
    *) say "$PORT" "get $MANIFEST_PATH" 60 > "$OLDSHA" || : > "$OLDSHA" ;;
  esac
fi

# Whole lines, so a file counts as unchanged only when its sha and its path
# both match.
#
# The old manifest is read in BEGIN rather than as awk's first argument. The
# NR==FNR idiom for "am I still on the first file" is a lie when that file is
# empty: awk reads no records from it, NR never gets ahead of FNR, and every
# line of the *second* file is treated as a line of the first. The symptom is
# a run with no manifest at all reporting that the console already holds the
# build, which is precisely backwards.
FILES="$(awk -v old="$OLDSHA" '
  BEGIN { while ((getline line < old) > 0) seen[line] = 1 }
  !($0 in seen) { print $2 }' "$SHA")"

# The manifest lives beside the slot rather than in it, so nothing stops
# something else replacing the receiver and leaving a manifest that describes a
# build no longer there -- install-vpk.sh --replace, or one VitaShell install.
# The eboot's size is the cheapest disagreement to notice, and it is the file
# whose staleness matters.
if [ -s "$OLDSHA" ] && ! printf '%s\n' "$FILES" | grep -qx 'eboot.bin'; then
  WANT="$(wc -c <"$WORK/eboot.bin" | tr -d ' ')"
  GOT="$(say "$PORT" "stat ux0:app/$TITLE_ID/eboot.bin" 20 | awk '{ print $1 }')"
  if [ "$WANT" != "$GOT" ]; then
    echo "==> the manifest says eboot.bin is current, but $TITLE_ID has" \
         "${GOT:-nothing} B and this build is $WANT B; staging everything"
    FILES="$PAYLOAD"
  fi
fi

if [ -z "$FILES" ]; then
  echo "==> $TITLE_ID already holds this build; nothing to do"
  exit 0
fi

echo "==> $(basename "$VPK") -> $TITLE_ID via $UPDATER"
echo "    $(printf '%s\n' "$FILES" | wc -l | tr -d ' ') of" \
     "$(printf '%s\n' "$PAYLOAD" | wc -l | tr -d ' ') files changed"

# The updater has to exist before the receiver is asked to hand over to it. A
# launch of a title that is not installed is a silent no-op, and the console
# would sit on the receiver with a staged update it never applies.
#
# It also has to be *this* updater. It is permanent now, so nothing reinstalls
# it as a side effect, and an updater older than the code that stages for it is
# the failure this script exists to make loud: on 2026-09-08 one built before
# the loader/receiver rename looked in a directory that no longer got written,
# printed "nothing staged", relaunched the receiver, and three deploys in a row
# reported success and changed no bytes. Comparing eboot sizes is one round
# trip and catches every rebuild of it.
NEED_UPDATER=""
if ! say "$PORT" "exist $UPDATER" 20 | grep -q "res=3"; then
  NEED_UPDATER="it is not installed"
else
  [ -f "$UPDATER_VPK" ] || {
    echo "!! no updater vpk at $UPDATER_VPK" >&2
    echo "   cmake --build receiver/updater/build" >&2; exit 1; }
  UWANT="$(unzip -p "$UPDATER_VPK" eboot.bin | wc -c | tr -d ' ')"
  UGOT="$(say "$PORT" "stat ux0:app/$UPDATER/eboot.bin" 20 | awk '{ print $1 }')"
  [ "$UWANT" = "$UGOT" ] || NEED_UPDATER="the installed one is ${UGOT:-?} B, this one is $UWANT B"
fi
if [ -n "$NEED_UPDATER" ]; then
  echo "==> installing $UPDATER: $NEED_UPDATER"
  [ -f "$UPDATER_VPK" ] || {
    echo "!! no updater vpk at $UPDATER_VPK" >&2
    echo "   cmake --build receiver/updater/build" >&2; exit 1; }
  "$HERE/install-vpk.sh" "$UPDATER_VPK" --host "$HOST" --port "$PORT" \
    --no-launch | sed 's/^/    /'
fi

echo "==> staging"
say "$PORT" "rmtree $STAGE" 120 | sed 's/^/    /'
for rel in $FILES; do put "$WORK/$rel" "$STAGE/files/$rel"; done

# Written last, on purpose. The updater does nothing without it, so a transfer
# that dies halfway leaves a half-copied payload that is never applied.
MANIFEST="$WORK/manifest.txt"
{ printf 'target %s\n' "$TITLE_ID"
  printf '%s\n' "$FILES" | sed 's/^/file /'; } > "$MANIFEST"
put "$MANIFEST" "$STAGE/manifest.txt"

echo "==> handing over to $UPDATER"
say "$PORT" "launch $UPDATER" 20 | sed 's/^/    /' || true

# On the port the *new* receiver listens on, which is not $PORT when a scratch
# receiver did the staging: --port 1342 waited on 1342 for a receiver that was
# up on 1341 the whole time, and reported it as never having come back.
WAIT_PORT="${BUILD_PORT:-1341}"
echo "==> waiting for $TITLE_ID on $HOST:$WAIT_PORT"
BACK=""
for _ in $(seq 1 40); do
  sleep 2
  BACK="$(say "$WAIT_PORT" ping 5 2>/dev/null || true)"
  case "$BACK" in pong\ receiver*) break ;; *) BACK="" ;; esac
done
[ -n "$BACK" ] || {
  echo "!! it never came back." >&2
  echo "   Launch 'Flutter Receiver Updater' from the LiveArea holding L to" >&2
  echo "   restore the eboot that was running." >&2
  exit 1; }
echo "    $BACK"

# A receiver answering is not proof the update was applied.
#
# The updater removes the manifest as its last act, and only after every copy
# has succeeded. If the manifest survives, the updater ran and decided there
# was nothing to do -- which is exactly what a stale updater does. On
# 2026-09-08 one built before the loader/receiver rename kept looking in
# ux0:data/flutter-vita/loader-update, found nothing, printed "nothing staged"
# and launched the receiver straight back. Three updates in a row reported
# success and changed no bytes.
if say "$PORT" "ls $STAGE" 20 | grep -q manifest.txt; then
  echo "!! the updater did not apply the payload: $STAGE/manifest.txt is" >&2
  echo "   still there, and it is removed only on success." >&2
  echo "   Most likely $UPDATER is older than the staging paths:" >&2
  echo "     rm -rf receiver/updater/build" >&2
  echo "     cmake -S receiver/updater -B receiver/updater/build \\" >&2
  echo "       -DCMAKE_TOOLCHAIN_FILE=\$VITASDK/share/vita.toolchain.cmake" >&2
  echo "     cmake --build receiver/updater/build" >&2
  exit 1
fi

# Only now, because a manifest that describes the slot before the update has
# been confirmed is a manifest that makes the next run skip a file that never
# landed.
put "$SHA" "$MANIFEST_PATH"

if [ "$KEEP_UPDATER" -eq 1 ]; then
  echo
  echo "$TITLE_ID updated. Hold L on $UPDATER to put the old eboot back."
  exit 0
fi

echo "==> removing $UPDATER"
say "$PORT" "delete $UPDATER" 60 | sed 's/^/    /' || true
# The receiver stays up through a delete now -- see after_delete in
# receiver/src/receiver_dev.c. It used to relaunch itself here, which on
# 2026-09-08 left the console on the LiveArea with nothing answering. This
# still waits, because the delete goes through the promoter on its own thread
# and the reply arrives before the worker has finished.
for _ in $(seq 1 20); do
  sleep 2
  BACK="$(say "$PORT" ping 5 2>/dev/null || true)"
  case "$BACK" in
    pong\ receiver*)
      if say "$PORT" "exist $UPDATER" 20 | grep -q "res=3"; then continue; fi
      echo "    $BACK"
      echo
      echo "$TITLE_ID updated and $UPDATER removed."
      exit 0 ;;
  esac
done
echo "!! $UPDATER is still there, or the receiver stopped answering." >&2
echo "   printf 'log\\n' | nc -4 $HOST $PORT | tail -20" >&2
exit 1
