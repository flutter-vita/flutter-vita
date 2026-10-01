#!/usr/bin/env bash
# Put the bridge on a console that has never had one.
#
#   ./tools/bootstrap-bridge.sh <address>[:port]        VitaShell's FTP, port 1337 by default
#
# Everything else in tools/ talks to the bridge by name. A fresh console has
# no bridge, so nothing answers fluttervita.local and nothing can promote a
# title. This is the one step that needs an address and it needs it once: the
# .vpk goes over VitaShell's FTP, you install it from VitaShell, and from then
# on the name works and this script is never run again.
#
# The address is typed by you, from VitaShell's own screen, for this one run.
# It is not stored, not defaulted, and not read from any file.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VPK="$ROOT/bridge/app/build/vita/flutter_vita_bridge.vpk"
NAME="fluttervita.local"

TARGET="${1:?address VitaShell shows for its FTP server, with or without :1337}"
case "$TARGET" in *:*) ;; *) TARGET="$TARGET:1337" ;; esac

[ -f "$VPK" ] || { echo "no bridge vpk at $VPK; run tools/build-bridge.sh first" >&2; exit 1; }

echo "==> $TARGET"
if ! curl -s --connect-timeout 8 "ftp://$TARGET/" >/dev/null; then
  echo "!! nothing answers FTP at $TARGET." >&2
  echo "   In VitaShell press SELECT: it starts the server and shows the address." >&2
  exit 1
fi

# The shader compiler is the user's to install and every GPU-path app needs it.
# Say so now rather than after the first app shows a blank screen.
if ! curl -s --connect-timeout 8 "ftp://$TARGET/ur0:/data/" | grep -q "libshacccg.suprx"; then
  echo "    note: ur0:data/libshacccg.suprx is not on this console."
  echo "          The bridge runs without it. Apps on the GPU path do not."
fi

SIZE=$(wc -c <"$VPK" | tr -d ' ')
echo "==> sending flutter_vita_bridge.vpk ($SIZE B) to ux0:/"
curl --connect-timeout 8 -T "$VPK" "ftp://$TARGET/ux0:/flutter_vita_bridge.vpk" \
  --progress-bar 2>&1 | tail -1

cat <<MSG

    On the console, in VitaShell:
      1. go to ux0:/
      2. open flutter_vita_bridge.vpk and confirm the install
      3. open Flutter Vita Bridge from the LiveArea

==> waiting for $NAME to answer on 1341
MSG

for _ in $(seq 1 90); do
  sleep 4
  if printf 'ping\n' | nc -4 -w 4 "$NAME" 1341 2>/dev/null | grep -q -E '^pong (bridge|receiver)'; then
    echo "    $NAME is up. Everything from here on is by name."
    exit 0
  fi
done
echo "!! $NAME did not answer in six minutes. Is the bridge open on the console?" >&2
exit 1
