#!/usr/bin/env bash
# Install a new loader from the running loader.
#
#   ./tools/update-loader.sh [--host IP]
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
HOST="${VITA_HOST:-192.168.0.32}"
PORT=1341
STAGE="ux0:data/flutter-vita/loader-pkg"
VPK="$HERE/../spikes/vita-loader/build/flutter_vita_loader.vpk"

while [ $# -gt 0 ]; do
  case "$1" in
    --host)    HOST="$2"; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -f "$VPK" ] || { echo "!! no $VPK — build spikes/vita-loader first" >&2; exit 1; }

say() { printf '%s\n' "$2" | nc -w "${3:-30}" "$HOST" "$PORT"; }

# A real command, not `nc -z`. The loader's listener is non-blocking and a bare
# connect races with its accept loop -- during this script's first run `nc -z`
# reported the port closed while `ls` on the same port answered fine.
alive=0
for _ in 1 2 3; do
  if say $PORT ping 8 2>/dev/null | grep -q loader; then alive=1; break; fi
  sleep 2
done
[ "$alive" -eq 1 ] || {
  echo "!! no loader on $HOST:$PORT — open Flutter Vita Loader" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$VPK" -d "$WORK"

# Every file, before anything is sent. `put` refuses an empty payload now, but
# a vpk missing eboot2.bin would otherwise promote a loader whose supervisor
# does not exist and report success.
for f in eboot.bin eboot2.bin sce_sys/param.sfo sce_sys/param2.sfo; do
  [ -s "$WORK/$f" ] || { echo "!! $f missing or empty in the vpk" >&2; exit 1; }
done

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
echo "Installed. The running process is still the old loader; it is replaced by"
echo "the next launch of FVTA00003."
