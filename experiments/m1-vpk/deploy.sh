#!/usr/bin/env bash
# Build, push, launch, and collect logs -- without touching the device.
#
# Nine manual deploy cycles into M1, the loop is the bottleneck: FTP upload,
# VitaShell install, LiveArea launch, read screen, copy logs back. This does all
# of it from the shell.
#
# Two ideas make it work:
#
#   1. vitacompanion (https://github.com/devnoname120/vitacompanion) runs an FTP
#      server on 1337 and a command server on 1338 that accepts `launch TITLEID`
#      and `kill`. That is the piece VitaSDK does not ship and USB cannot do --
#      mass storage moves files but cannot start anything.
#
#   2. Skip the vpk. Once a title is installed its files live in
#      ux0:app/<TITLEID>/, and overwriting eboot.bin there is enough. The vpk
#      only needs installing once, to register the title.
#
# One-time setup on the Vita:
#   - copy vitacompanion.suprx to ur0:tai/
#   - add `*main` then `ur0:tai/vitacompanion.suprx` to ur0:tai/config.txt
#   - reboot
#   - install flutter_vita_m1.vpk once via VitaShell
#
# Usage:  VITA_IP=192.168.1.42 ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${VITA_IP:?set VITA_IP to the address of your Vita, e.g. VITA_IP=192.168.1.42}"
TITLEID=FVTA00002
FTP="ftp://$VITA_IP:1337"
CMD_PORT=1338
# vitacompanion is optional. Without it this still skips the vpk install --
# which is most of the saving -- and you launch from the LiveArea by hand.
# Set VITA_FTP_PORT=1337 for vitacompanion, or 1337 for VitaShell's FTP too
# (VitaShell also serves on 1337; press SELECT to start it).
USE_COMPANION="${USE_COMPANION:-1}"
APPDIR="ux0:/app/$TITLEID"
LOGDIR=out/logs

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
cmd() {
  [[ "$USE_COMPANION" == "1" ]] || return 0
  echo "$1" | nc -w 5 "$VITA_IP" "$CMD_PORT" >/dev/null 2>&1 || true
}

say "building"
./build.sh >/dev/null

say "stopping any running copy"
# Without this the old process keeps eboot.bin open and the upload silently
# writes a file the launcher will not use.
cmd "kill"
sleep 2

say "uploading to $APPDIR"
BLOBS=../m1-snapshot/out/blobs
upload() { # local remote
  curl -sS -T "$1" "$FTP/${APPDIR#ux0:}/$2" && printf '  %s\n' "$2"
}
# eboot.bin comes out of the vpk rather than the build tree: vita_create_vpk
# packages the SELF, and that is the form the receiver wants.
mkdir -p out/staging && (cd out/staging && rm -f eboot.bin && unzip -o -q ../../build/flutter_vita_m1.vpk eboot.bin)
upload out/staging/eboot.bin eboot.bin
for b in vm_snapshot_data isolate_snapshot_data \
         vm_snapshot_instructions isolate_snapshot_instructions; do
  upload "$BLOBS/$b.bin" "$b.bin"
done

if [[ "$USE_COMPANION" == "1" ]]; then
  say "launching $TITLEID"
  cmd "launch $TITLEID"
else
  say "launch 'Flutter Vita M1' from the LiveArea now"
  read -r -p "    press return once it has finished... " _
fi

say "waiting for the run to finish"
# The harness waits on START, so give it time to reach that point rather than
# guessing at completion. Adjust if a run gets slower.
[[ "$USE_COMPANION" == "1" ]] && sleep "${RUN_SECONDS:-15}"

say "collecting logs"
mkdir -p "$LOGDIR"
for f in m1.log dart.log; do
  if curl -sS -o "$LOGDIR/$f" "$FTP/data/flutter-vita/$f" 2>/dev/null; then
    printf '  %s (%s bytes)\n' "$f" "$(wc -c < "$LOGDIR/$f" | tr -d ' ')"
  else
    printf '  %s -- not present\n' "$f"
  fi
done

say "m1.log"
cat "$LOGDIR/m1.log" 2>/dev/null || echo "  (none)"
say "dart.log"
cat "$LOGDIR/dart.log" 2>/dev/null || echo "  (none)"
