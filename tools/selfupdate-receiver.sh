#!/usr/bin/env bash
# Replace the receiver with a new build, using the receiver itself.
#
#   ./tools/selfupdate-receiver.sh                    build and install
#   ./tools/selfupdate-receiver.sh path/to.vpk        install a built one
#
#   --title-id ID   which receiver to replace (default FVTA00001)
#   --updater ID    the updater's title id    (default FVTA00009)
#   --keep-updater    leave the updater installed (the default)
#   --remove-updater  delete it afterwards, at the cost of a visible restart
#   --port N        the port to talk to       (default 1341)
#   --build-port N  the port to build for     (default: build-receiver.sh's)
#   --no-build      require the vpk argument
#
# A running title cannot write its own directory, so the receiver is the one
# thing the receiver cannot install. Three steps around it:
#
#   1. put the new build into ux0:data/flutter-vita/receiver-update
#   2. launch FVTA00009, a 50 KB app with no engine whose only job is to copy
#      that tree over ux0:app/<target> and launch the target back
#   3. wait for the new receiver, then take FVTA00009 back off the card
#
# The updater keeps the eboot it replaces in receiver-backup. If the new build
# boots into nothing, launch "Flutter Receiver Updater" holding L to restore it.
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
VPK=""
# The port to reach the running receiver on and the port to compile into the new
# one are different numbers whenever a scratch receiver is doing the install.
# They were one option for about ten minutes, which built FVTA00001 to listen
# on the scratch receiver's port.
BUILD_PORT=""
UPDATER_VPK="$ROOT/receiver/updater/build/flutter_vita_updater.vpk"

# The updater stays installed unless asked otherwise.
#
# Deleting it works: the receiver removes it, restarts, and answers again about
# nine seconds later. Those nine seconds put the LiveArea home screen on the
# television on every update, and the thing being avoided is a 50 KB bubble.
#
# It is also the rescue path, and it works when the receiver does not.
#
# --remove-updater when you actually want it gone.
KEEP_UPDATER=1

while [ $# -gt 0 ]; do
  case "$1" in
    --title-id) TITLE_ID="$2"; shift 2 ;;
    --updater)  UPDATER="$2"; shift 2 ;;
    --keep-updater) KEEP_UPDATER=1; shift ;;
    --remove-updater) KEEP_UPDATER=0; shift ;;
    --port)       PORT="$2"; shift 2 ;;
    --build-port) BUILD_PORT="$2"; shift 2 ;;
    --host)     HOST="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    -h|--help)  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  VPK="$1"; BUILD=0; shift ;;
  esac
done

STAGE="ux0:data/flutter-vita/receiver-update"

say() { printf '%s\n' "$2" | nc -w "${3:-30}" "$HOST" "$1"; }

put() {  # <local> <device path>
  local size; size=$(wc -c <"$1" | tr -d ' ')
  [ "${size:-0}" -gt 0 ] || { echo "!! refusing to put an empty $1" >&2; return 1; }
  { printf 'put %s %s\n' "$size" "$2"; cat "$1"; } | nc -w 300 "$HOST" "$PORT" \
    | grep -q OK || { echo "!! put failed: $2" >&2; return 1; }
  printf '    %-52s %9s B\n' "${2#"$STAGE"/files/}" "$size"
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

# The updater has to exist before the receiver is asked to hand over to it. A
# launch of a title that is not installed is a silent no-op, and the console
# would sit on the receiver with a staged update it never applies.
#
# Installing it here rather than telling you to go and do it: the updater is
# scaffolding, and asking a human to put scaffolding up by hand before every
# receiver change is how the receiver stops getting changed.
if ! say "$PORT" "exist $UPDATER" 20 | grep -q "res=3"; then
  echo "==> installing $UPDATER"
  [ -f "$UPDATER_VPK" ] || {
    echo "!! no updater vpk at $UPDATER_VPK" >&2
    echo "   cmake --build receiver/updater/build" >&2; exit 1; }
  "$HERE/install-vpk.sh" "$UPDATER_VPK" --host "$HOST" --port "$PORT" \
    --no-launch | sed 's/^/    /'
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$VPK" -d "$WORK"

# sce_sys/param.sfo and sce_sys/package/ are the *installed* title's identity:
# its id, its name, the package header the promoter wrote. The payload is a
# build of the receiver, which may have been built for a different slot, and
# writing its param.sfo over FVTA00001's is how a title stops being itself.
# The LiveArea art is not identity and is copied.
FILES="$( cd "$WORK" && find . -type f \
    ! -name param.sfo ! -path './sce_sys/package/*' \
    | sed 's|^\./||' | sort )"

echo "==> $(basename "$VPK") -> $TITLE_ID via $UPDATER"
say "$PORT" "rmtree $STAGE" 120 | sed 's/^/    /'

echo "==> staging"
printf '%s\n' "$FILES" \
  | while read -r rel; do put "$WORK/$rel" "$STAGE/files/$rel"; done

# Written last, on purpose. The updater does nothing without it, so a transfer
# that dies halfway leaves a half-copied payload that is never applied.
MANIFEST="$WORK/manifest.txt"
{ printf 'target %s\n' "$TITLE_ID"
  printf '%s\n' "$FILES" | sed 's/^/file /'; } > "$MANIFEST"
put "$MANIFEST" "$STAGE/manifest.txt"

echo "==> handing over to $UPDATER"
say "$PORT" "launch $UPDATER" 20 | sed 's/^/    /' || true

echo "==> waiting for $TITLE_ID on $HOST:$PORT"
for _ in $(seq 1 40); do
  sleep 3
  PONG="$(say "$PORT" ping 5 2>/dev/null || true)"
  case "$PONG" in
    pong\ receiver*)
      echo "    $PONG"
      # A receiver answering is not proof the update was applied.
      #
      # The updater removes the manifest as its last act, and only after every
      # copy has succeeded. If the manifest survives, the updater ran and
      # decided there was nothing to do -- which is exactly what a stale updater
      # does. On 2026-09-08 one built before the loader/receiver rename kept
      # looking in ux0:data/flutter-vita/loader-update, found nothing, printed
      # "nothing staged" and launched the receiver straight back. Three updates
      # in a row reported success and changed no bytes.
      if say "$PORT" "ls $STAGE" 20 | grep -q manifest.txt; then
        echo "!! the updater did not apply the payload: $STAGE/manifest.txt" >&2
        echo "   is still there, and it is removed only on success." >&2
        echo "   Most likely $UPDATER is older than the staging paths:" >&2
        echo "     rm -rf receiver/updater/build" >&2
        echo "     cmake -S receiver/updater -B receiver/updater/build \\" >&2
        echo "       -DCMAKE_TOOLCHAIN_FILE=\$VITASDK/share/vita.toolchain.cmake" >&2
        echo "     cmake --build receiver/updater/build" >&2
        exit 1
      fi
      # The updater is scaffolding and comes back down. It is a bubble on the
      # LiveArea that does exactly one thing and does it destructively, and
      # every one of these left behind is a way to overwrite the receiver by
      # accident. --keep-updater is for chasing a failing update, when the
      # cost of reinstalling it between attempts is the thing you are paying.
      if [ "$KEEP_UPDATER" -eq 0 ]; then
        echo "==> removing $UPDATER"
        say "$PORT" "delete $UPDATER" 60 | sed 's/^/    /' || true
        # The receiver stays up through a delete now -- see after_delete in
        # receiver/src/receiver_dev.c. It used to relaunch itself here, which on
        # 2026-09-08 left the console on LiveArea with nothing answering. This
        # still waits, because the delete goes through the promoter and the
        # reply can arrive before the worker has finished.
        echo "==> confirming the receiver is still there"
        for _ in $(seq 1 20); do
          sleep 3
          BACK="$(say "$PORT" ping 5 2>/dev/null || true)"
          case "$BACK" in pong\ receiver*) echo "    $BACK"; exit 0 ;; esac
        done
        echo "!! it did not come back after the delete." >&2
        echo "   $UPDATER is gone, so hold-L rescue is not available." >&2
        exit 1
      fi
      exit 0 ;;
  esac
done

echo "!! it never came back." >&2
echo "   Launch 'Flutter Receiver Updater' from the LiveArea holding L to" >&2
echo "   restore the eboot that was running." >&2
exit 1
