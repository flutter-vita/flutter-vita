#!/usr/bin/env bash
# Install a new receiver from a running app, by file copy.
#
#   ./tools/update-receiver.sh [--host IP] [--vpk PATH] [--port N] [--title-id ID]
#   ./tools/update-receiver.sh --backup /tmp/receiver-eboot.bak
#
# The receiver installs the app under test; for a long time nothing installed the
# receiver, which meant VitaShell and a card swap for every receiver change. That is
# why the receiver accumulated fixes slowly and why the background supervisor sat
# broken for five days.
#
# A receiver cannot install itself. `ux0:app/<self>` is the read-only `app0:`
# mount, so `put ux0:app/FVTA00004/eboot.bin` from the receiver in FVTA00004 comes
# back 0x8001000D, EACCES, and no amount of unsafe-ness changes it. Every *other*
# title's directory is ordinary storage that an UNSAFE self writes freely.
#
# So the update goes the other way round, and this is the whole trick: the
# receiver installs an app, and the app installs the receiver. Any app with the dev
# server in it will do. `spikes/m1-vpk` is the small one kept around for exactly
# this -- 2.5 MB, no engine, same dev server -- and the conformance or gallery
# app works just as well when one of those happens to be the thing installed.
#
#   ./tools/deploy.sh --vpk spikes/m1-vpk/build/flutter_vita_m1.vpk \
#       --receiver-port 1342          # receiver installs the app
#   ./tools/update-receiver.sh        # app installs the receiver
#
# This used to go through the promoter instead. The promoter turned out to be
# reachable after all (see spikes/promoter), but loading it takes the console
# down about ten seconds later, so nothing here uses it. Nothing here needs to:
# the promoter is required to register a *new* title id, and updating one that
# already exists is a file copy.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# flutter-vita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often. VITA_HOST still overrides
# it, and an IP is still the right answer when the name will not resolve.
HOST="${VITA_HOST:-flutter-vita.local}"
# The app's port, not a receiver's. This talks to the installer, and the installer
# is an ordinary app.
PORT=1339
TITLE_ID=""
BACKUP=""
VPK="$HERE/../receiver/app/build/vita/flutter_vita_receiver.vpk"

while [ $# -gt 0 ]; do
  case "$1" in
    --host)     HOST="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    --vpk)      VPK="$2"; shift 2 ;;
    --title-id) TITLE_ID="$2"; shift 2 ;;
    --backup)   BACKUP="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -f "$VPK" ] || { echo "!! no $VPK — build the receiver first" >&2; exit 1; }

say() { printf '%s\n' "$2" | nc -w "${3:-30}" "$HOST" "$1" 2>/dev/null; }

# A real command, not `nc -z`. The dev server's listener is non-blocking and a
# bare connect races its accept loop -- an early run of this script had `nc -z`
# report the port closed while `ls` on the same port answered fine.
alive=0
for _ in 1 2 3; do
  if say "$PORT" ping 8 | grep -q pong; then alive=1; break; fi
  sleep 2
done
[ "$alive" -eq 1 ] || {
  echo "!! nothing answers on $HOST:$PORT" >&2
  echo "   This needs an *app* running, not the receiver. Install one first:" >&2
  echo "     ./tools/deploy.sh --vpk spikes/m1-vpk/build/flutter_vita_m1.vpk \\" >&2
  echo "         --receiver-port 1342" >&2
  exit 1; }

# The receiver answers "pong receiver <slot> <port>" and an app answers a bare
# "pong". Refusing the receiver here is not pedantry: it is the one process on the
# console that cannot do this job, and its failure mode is a bare EACCES that
# reads like a full memory card.
if say "$PORT" ping 8 | grep -q '^pong receiver'; then
  echo "!! that is a receiver on $HOST:$PORT, and a receiver cannot install itself." >&2
  echo "   Deploy an app through it first, then run this again." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$VPK" -d "$WORK"

# Every file checked before anything is sent. A half-copied install starts and
# then fails somewhere less obvious than here.
for f in eboot.bin sce_sys/param.sfo; do
  [ -s "$WORK/$f" ] || { echo "!! $f missing or empty in the vpk" >&2; exit 1; }
done

[ -n "$TITLE_ID" ] || TITLE_ID="$(strings "$WORK/sce_sys/param.sfo" \
  | grep -m1 -E '^[A-Z]{4}[0-9]{5}$' || true)"
case "$TITLE_ID" in
  [A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "!! no title id in the vpk's param.sfo; pass --title-id" >&2; exit 1 ;;
esac
DEST="ux0:app/$TITLE_ID"

# This route updates a title that exists. It cannot create one -- `put` writes
# files, and nothing here registers a title with the shell -- so an empty listing
# means the wrong slot or a title that needs one manual VitaShell install first.
LISTING="$(say "$PORT" "ls $DEST" 20)"
printf '%s\n' "$LISTING" | grep -q 'eboot.bin' || {
  echo "!! $DEST has no eboot.bin, so there is no receiver there to update." >&2
  echo "   Registering a fresh title id needs the promoter (spikes/promoter)" >&2
  echo "   or one manual VitaShell install. This script only replaces files." >&2
  printf '%s\n' "$LISTING" | sed 's/^/   /' >&2
  exit 1; }

echo "==> installing $(basename "$VPK") into $DEST from the app on :$PORT"

if [ -n "$BACKUP" ]; then
  echo "==> backing up $DEST/eboot.bin to $BACKUP"
  say "$PORT" "get $DEST/eboot.bin" 300 > "$BACKUP"
  [ -s "$BACKUP" ] || { echo "!! backup is empty; refusing to overwrite" >&2; exit 1; }
  printf '    %s B\n' "$(wc -c <"$BACKUP" | tr -d ' ')"
fi

put() {  # <local> <device path>
  local size; size=$(wc -c <"$1" | tr -d ' ')
  # `put 0` is refused by the dev server, and this is the second guard on the
  # same mistake: a blank shell expansion once truncated a 12 MB eboot to
  # nothing, and the console then had a receiver that could not start.
  [ "${size:-0}" -gt 0 ] || { echo "!! refusing to put an empty $1" >&2; return 1; }
  { printf 'put %s %s\n' "$size" "$2"; cat "$1"; } | nc -w 300 "$HOST" "$PORT" \
    | grep -q OK || { echo "!! put failed: $2" >&2; return 1; }
  printf '    %-28s %9s B\n' "$2" "$size"
}

# eboot.bin last. Everything else is an asset the old binary can also read, so
# an interrupted run leaves a receiver that still starts -- and the file that
# decides which build runs is the one written when the transfer has already
# proved itself over 3 MB of fonts.
( cd "$WORK" && find . -type f ! -name eboot.bin | sed 's|^\./||' | sort ) \
  | while read -r rel; do put "$WORK/$rel" "$DEST/$rel"; done
put "$WORK/eboot.bin" "$DEST/eboot.bin"

# Read it back. `put` renames only after the whole file lands, so a wrong size
# here means the device wrote something other than what was sent.
WANT="$(wc -c <"$WORK/eboot.bin" | tr -d ' ')"
GOT="$(say "$PORT" "ls $DEST" 20 | awk '$3 == "eboot.bin" { print $2 }')"
[ "$WANT" = "$GOT" ] || {
  echo "!! $DEST/eboot.bin is $GOT B on the console, sent $WANT B" >&2; exit 1; }

echo
echo "Installed into $TITLE_ID, eboot.bin $GOT B verified."
echo "The running process is unchanged; the new build starts on the next launch."
echo "The app can hand the console over without a tap:"
echo "  printf 'handoff $TITLE_ID\\n' | nc $HOST $PORT"
