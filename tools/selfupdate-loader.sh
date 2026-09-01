#!/usr/bin/env bash
# Replace the loader with a new build, using the loader itself.
#
#   ./tools/selfupdate-loader.sh                    build and install
#   ./tools/selfupdate-loader.sh path/to.vpk        install a built one
#
#   --title-id ID   which loader to replace   (default FVTA00001)
#   --updater ID    the updater's title id    (default FVTA00009)
#   --keep-updater    leave the updater installed afterwards (the default)
#   --remove-updater  delete it -- see the note by KEEP_UPDATER first
#   --port N        the port to talk to       (default 1341)
#   --build-port N  the port to build for     (default: build-loader.sh's)
#   --no-build      require the vpk argument
#
# A running title cannot write its own directory -- app0: is the read-only
# mount of ux0:app/<own id>, so the loader is the one thing the loader cannot
# install. This drives the three-step way around it:
#
#   1. put the new build onto the card, into ux0:data/flutter-vita/loader-update
#   2. launch FVTA00009, a 50 KB app with no engine whose only job is to copy
#      that tree over ux0:app/<target> and launch the target back
#   3. wait for the new loader to answer on its port, then take FVTA00009
#      back off the card
#
# It replaced tools/update-loader.sh's route, which needed a working Flutter
# app with a dev server in FVTA00002 -- so a broken app slot used to take the
# loader's update path down with it.
#
# The updater keeps the eboot it replaces in ux0:data/flutter-vita/loader-backup
# and puts it back on a short write. If the new loader boots into nothing,
# launch "Flutter Loader Updater" from the LiveArea and hold L: it restores the
# backup and launches the loader that worked.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# flutter-vita.local, not an address. The dev server answers mDNS for that name
# and this console's address changes whenever its Wi-Fi does.
HOST="${VITA_HOST:-flutter-vita.local}"
PORT="${LOADER_PORT:-1341}"
TITLE_ID="FVTA00001"
UPDATER="FVTA00009"
BUILD=1
VPK=""
# The port to reach the running loader on and the port to compile into the new
# one are different numbers whenever a scratch loader is doing the install.
# They were one option for about ten minutes, which built FVTA00001 to listen
# on the scratch loader's port.
BUILD_PORT=""
UPDATER_VPK="$ROOT/loader/updater/build/flutter_vita_updater.vpk"
# Kept, until a delete stops taking the loader down with it. Removing the
# updater is the right end state -- it is a bubble whose only function is to
# overwrite the loader -- but on 2026-09-01 the delete dropped this console to
# the LiveArea home screen three times, and an update that ends there is worse
# than an updater left installed. --remove-updater asks for it anyway.
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

STAGE="ux0:data/flutter-vita/loader-update"

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
  "$HERE/build-loader.sh" "$@"
  VPK="$ROOT/loader/app/build/vita/flutter_vita_loader.vpk"
fi
[ -f "$VPK" ] || { echo "no vpk at ${VPK:-<none>}" >&2; exit 1; }

# The far end has to be a loader, not an app that happens to hold the port.
# Its pong names itself; anything else and this would be putting a loader's
# eboot into whatever answered.
PONG="$(say "$PORT" ping 15 || true)"
case "$PONG" in
  pong\ loader*) ;;
  *) echo "!! no loader on $HOST:$PORT (got '${PONG:-nothing}')" >&2
     echo "   open the loader, or pass --port" >&2; exit 1 ;;
esac

# The updater has to exist before the loader is asked to hand over to it. A
# launch of a title that is not installed is a silent no-op, and the console
# would sit on the loader with a staged update it never applies.
#
# Installing it here rather than telling you to go and do it: the updater is
# scaffolding, and asking a human to put scaffolding up by hand before every
# loader change is how the loader stops getting changed.
if ! say "$PORT" "exist $UPDATER" 20 | grep -q "res=3"; then
  echo "==> installing $UPDATER"
  [ -f "$UPDATER_VPK" ] || {
    echo "!! no updater vpk at $UPDATER_VPK" >&2
    echo "   cmake --build loader/updater/build" >&2; exit 1; }
  "$HERE/install-vpk.sh" "$UPDATER_VPK" --host "$HOST" --port "$PORT" \
    --no-launch | sed 's/^/    /'
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$VPK" -d "$WORK"

# sce_sys/param.sfo and sce_sys/package/ are the *installed* title's identity:
# its id, its name, the package header the promoter wrote. The payload is a
# build of the loader, which may have been built for a different slot, and
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
    pong\ loader*)
      echo "    $PONG"
      # The updater is scaffolding and comes back down. It is a bubble on the
      # LiveArea that does exactly one thing and does it destructively, and
      # every one of these left behind is a way to overwrite the loader by
      # accident. --keep-updater is for chasing a failing update, when the
      # cost of reinstalling it between attempts is the thing you are paying.
      if [ "$KEEP_UPDATER" -eq 0 ]; then
        echo "==> removing $UPDATER"
        say "$PORT" "delete $UPDATER" 60 | sed 's/^/    /' || true
        # The loader restarts itself after a delete -- see restart_after_delete
        # in loader/src/loader_dev.c. Waiting for it here so this script never
        # returns while the console is mid-handover and nothing answers.
        echo "==> waiting for the loader to come back"
        for _ in $(seq 1 20); do
          sleep 3
          BACK="$(say "$PORT" ping 5 2>/dev/null || true)"
          case "$BACK" in pong\ loader*) echo "    $BACK"; exit 0 ;; esac
        done
        echo "!! it did not come back after the delete." >&2
        echo "   $UPDATER is gone, so hold-L rescue is not available." >&2
        exit 1
      fi
      exit 0 ;;
  esac
done

echo "!! it never came back." >&2
echo "   Launch 'Flutter Loader Updater' from the LiveArea holding L to" >&2
echo "   restore the eboot that was running." >&2
exit 1
