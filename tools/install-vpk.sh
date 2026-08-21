#!/usr/bin/env bash
# Install a .vpk onto a running Vita and launch it.
#
#   ./tools/install-vpk.sh <vpk> [--host IP] [--title-id ID] [--no-launch]
#
# Talks to the loader from loader over TCP. No FTP, no card
# swapping, no taps in the normal case.
#
# This does *not* install the way VitaShell does. The loader replaces
# eboot.bin in an already-installed slot and pushes the data files alongside
# it, which is right for the edit-run loop and wrong for first-time setup: a
# slot has to exist before anything here works. Installing a .vpk from scratch
# is still VitaShell's job.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VPK=""
HOST="${VITA_HOST:-192.168.0.32}"
LOADER_PORT=1341
TITLE_ID="FVTA00002"
LAUNCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --host)      HOST="$2"; shift 2 ;;
    --title-id)  TITLE_ID="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help)   sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           VPK="$1"; shift ;;
  esac
done

[ -n "$VPK" ] && [ -f "$VPK" ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
VPK="$(cd "$(dirname "$VPK")" && pwd)/$(basename "$VPK")"

say() { printf '%s\n' "$2" | nc -w "${3:-30}" "$HOST" "$1"; }

# The loader hard-codes the slot it installs into, so a .vpk built for a
# different title id would land in the wrong place and launch the wrong app.
# Cheaper to catch here than to wonder why the old build keeps starting.
SFO_ID="$(unzip -p "$VPK" sce_sys/param.sfo 2>/dev/null | strings | grep -oE '^[A-Z]{4}[0-9]{5}$' | head -1 || true)"
if [ -n "$SFO_ID" ] && [ "$SFO_ID" != "$TITLE_ID" ]; then
  echo "!! .vpk is built for $SFO_ID but the loader installs into $TITLE_ID" >&2
  echo "   Rebuild with --title-id $TITLE_ID, or pass --title-id $SFO_ID if the" >&2
  echo "   loader was changed to match." >&2
  exit 1
fi

# Retried, because one connect is not evidence. The loader's listener is
# non-blocking and a single ping races with its accept loop: it reported "no
# loader" three times in a row on 2026-08-15 against a loader that answered
# `ls` on the same port a second later.
alive=0
for _ in 1 2 3; do
  if say $LOADER_PORT ping 8 2>/dev/null | grep -q loader; then alive=1; break; fi
  sleep 2
done
[ "$alive" -eq 1 ] || {
  echo "!! no loader on $HOST:$LOADER_PORT — open Flutter Vita Loader" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$VPK" -d "$WORK"

EBOOT="$WORK/eboot.bin"
[ -f "$EBOOT" ] || { echo "!! no eboot.bin in $VPK" >&2; exit 1; }
SIZE="$(wc -c < "$EBOOT" | tr -d ' ')"

echo "==> staging eboot.bin ($SIZE bytes)"
{ printf 'stage %s\n' "$SIZE"; cat "$EBOOT"; } | nc -w 180 "$HOST" "$LOADER_PORT" | grep -q OK || {
  echo "!! stage failed — wifi drop mid-transfer?" >&2; exit 1; }

echo "==> installing"
say $LOADER_PORT install 60 | grep -q OK || { echo "!! install failed" >&2; exit 1; }

# Everything except the executable and the Sony metadata. `install` replaces
# eboot.bin only, so without this the app runs against whatever data files the
# last install left behind -- which is how an engine with no icudtl.dat and an
# unreachable flutter_assets got debugged for an hour.
echo "==> data files"
( cd "$WORK" && find . -type f ! -name eboot.bin \
    \( -not -path "./sce_sys/*" -o -path "./sce_sys/param2.sfo" \) | sed 's|^\./||' ) \
| while read -r rel; do
    fsize="$(wc -c < "$WORK/$rel" | tr -d ' ')"
    printf '  %s (%s B)\n' "$rel" "$fsize"
    { printf 'put %s ux0:app/%s/%s\n' "$fsize" "$TITLE_ID" "$rel"; cat "$WORK/$rel"; } \
      | nc -w 120 "$HOST" "$LOADER_PORT" | grep -q OK || {
        echo "!! push failed: $rel" >&2; exit 1; }
  done

if [ "$LAUNCH" -eq 1 ]; then
  echo "==> launching $TITLE_ID"
  say $LOADER_PORT launch 20 || true
fi
