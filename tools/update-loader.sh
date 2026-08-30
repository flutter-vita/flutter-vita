#!/usr/bin/env bash
# Install a new loader from the running loader.
#
#   ./tools/update-loader.sh [--host IP] [--vpk PATH] [--port N]
#
# The loader installs the app under test; until now nothing installed the
# loader. That meant VitaShell and a card swap for every loader change, which
# is why the loader accumulated fixes slowly and why the background supervisor
# sat broken for five days.
#
# It cannot write its own directory. The loader can write ux0:app/FVTA00002
# freely -- that is the whole point of it being an UNSAFE self -- but
# `touch ux0:app/FVTA00003/x` comes back 0x8001000D, EACCES: an app's own
# install directory is the read-only app0: mount, and no amount of unsafe-ness
# changes that. So a self-update cannot be a file copy.
#
# It goes through the promoter instead, the same system service `promote` uses
# for everything else: stage an extracted vpk under ux0:data, then ask the
# promoter to install it. The promoter is not the app and is not confined by
# the app's mounts, so it can write a directory the app cannot.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# flutter-vita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often. VITA_HOST still overrides
# it, and an IP is still the right answer when the name will not resolve.
HOST="${VITA_HOST:-flutter-vita.local}"
# The port of the loader *doing* the installing, which is not necessarily the
# port of the one being installed: a scratch loader (ADR-0016) is promoted by
# the working one and then answers somewhere else.
PORT=1341
STAGE="ux0:data/flutter-vita/loader-pkg"
VPK="$HERE/../loader/app/build/vita/flutter_vita_loader.vpk"

while [ $# -gt 0 ]; do
  case "$1" in
    --host)    HOST="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --vpk)     VPK="$2"; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -f "$VPK" ] || { echo "!! no $VPK — build loader first" >&2; exit 1; }

say() { printf '%s\n' "$2" | nc -w "${3:-30}" "$HOST" "$PORT"; }

# A real command, not `nc -z`. The loader's listener is non-blocking and a bare
# connect races with its accept loop -- during this script's first run `nc -z`
# reported the port closed while `ls` on the same port answered fine.
alive=0
for _ in 1 2 3; do
  # Either spelling: the C loader answers "loader", the Flutter one answers
  # "pong loader <slot> <port>". Both identify themselves, which is the point
  # -- an app's dev server answers a bare "pong" and must not be promoted onto.
  if say $PORT ping 8 2>/dev/null | grep -qE '^(loader|pong loader)'; then
    alive=1; break
  fi
  sleep 2
done
[ "$alive" -eq 1 ] || {
  echo "!! no loader on $HOST:$PORT — open Flutter Vita Loader" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$VPK" -d "$WORK"

# Every file, before anything is sent, because a promote of a half-staged
# package succeeds and leaves a loader that does not start. eboot2.bin is
# checked only when the vpk has one: the Flutter loader ships no supervisor
# (ADR-0016 decision 8), and requiring one here would refuse the very package
# this script now exists to install.
for f in eboot.bin sce_sys/param.sfo; do
  [ -s "$WORK/$f" ] || { echo "!! $f missing or empty in the vpk" >&2; exit 1; }
done
if [ -e "$WORK/eboot2.bin" ] || [ -e "$WORK/sce_sys/param2.sfo" ]; then
  for f in eboot2.bin sce_sys/param2.sfo; do
    [ -s "$WORK/$f" ] || { echo "!! $f missing or empty in the vpk" >&2; exit 1; }
  done
fi

TARGET_ID="$(strings "$WORK/sce_sys/param.sfo" | grep -m1 -E '^[A-Z]{4}[0-9]{5}$' || echo '?????????')"
SIZE="$(du -h "$VPK" | cut -f1)"
echo "==> installing $(basename "$VPK") [$TARGET_ID], $SIZE, via the loader on :$PORT"

put() {  # <local> <device path>
  local size; size=$(wc -c <"$1" | tr -d ' ')
  [ "${size:-0}" -gt 0 ] || { echo "!! refusing to put an empty $1" >&2; return 1; }
  { printf 'put %s %s\n' "$size" "$2"; cat "$1"; } | nc -w 120 "$HOST" "$PORT" \
    | grep -q OK || { echo "!! put failed: $2" >&2; return 1; }
  printf '  %-24s %8s B\n' "$(basename "$2")" "$size"
}

echo "==> staging into $STAGE"
( cd "$WORK" && find . -type f | sed 's|^\./||' ) | while read -r rel; do
  put "$WORK/$rel" "$STAGE/$rel"
done

echo "==> promoting"
say $PORT "promote $STAGE" 120 | tee "$WORK/promote.out" | sed 's/^/  /'
grep -q '^OK' "$WORK/promote.out" || {
  echo "!! promote failed — the installed loader is whatever it was before" >&2
  exit 1; }

echo
echo "Installed as $TARGET_ID. The running process is unchanged; the new build"
echo "starts on the next launch of that title."
