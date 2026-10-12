#!/usr/bin/env bash
# Copy one file from the console, and make sure all of it arrived.
#
#   ./tools/pull.sh <port> <device path> <local file> [--host NAME] [--tries N] [--wait S]
#
# `get` streams a file and closes, and the close looks the same whether the file
# ended or the Wi-Fi did. So this asks `stat` for the size first and compares:
# a shorter copy is pulled again, up to --tries times (default 5), and the exit
# status is 1 when no copy was whole. On 2026-10-12 four pulls of one 81 KB
# result stopped at four different lengths.
#
# <port> is whichever server holds the console: the app's (1339) or the
# bridge's (1341). Both answer `stat`, except an app built before 2026-10-12;
# from one of those the copy is taken once and unchecked, with a warning.
# --wait is nc's idle timeout per pull (default 60 s), not a total.
set -euo pipefail

HOST="fluttervita.local"
TRIES=5
WAIT=60
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --host)  HOST="$2"; shift 2 ;;
    --tries) TRIES="$2"; shift 2 ;;
    --wait)  WAIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ "${#ARGS[@]}" -eq 3 ] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
PORT="${ARGS[0]}" DEV="${ARGS[1]}" OUT="${ARGS[2]}"

# stat leaves the connection open for another command, so nc ends on its idle
# timeout: three seconds, the whole cost of the check.
reply="$(printf 'stat %s\n' "$DEV" | nc -4 -w 3 "$HOST" "$PORT" 2>/dev/null | head -1 | tr -d '\r' || true)"
SIZE=""
case "$reply" in
  *" file") SIZE="${reply%% *}" ;;
  *" dir")  echo "!! $DEV is a directory" >&2; exit 1 ;;
  "ERR stat "*) echo "!! $DEV: $reply" >&2; exit 1 ;;
  "") echo "!! nothing answered on $HOST:$PORT" >&2; exit 1 ;;
  *) echo "    note: the server on $PORT has no stat (built before 2026-10-12); $DEV is copied unchecked" >&2 ;;
esac

part="$OUT.part"
for try in $(seq 1 "$TRIES"); do
  printf 'get %s\n' "$DEV" | nc -4 -w "$WAIT" "$HOST" "$PORT" > "$part" 2>/dev/null || true
  got="$(wc -c < "$part" | tr -d ' ')"
  # Without stat, a missing file comes back as get's error line, not as data.
  if [ -z "$SIZE" ] && head -c 64 "$part" | grep -q '^ERR open 0x'; then
    echo "!! $DEV: $(head -1 "$part")" >&2
    rm -f "$part"
    exit 1
  fi
  if [ -z "$SIZE" ] || [ "$got" = "$SIZE" ]; then
    mv "$part" "$OUT"
    exit 0
  fi
  [ "$try" -lt "$TRIES" ] && echo "    pull $try of $DEV stopped at $got of $SIZE bytes; pulling again" >&2
done
echo "!! no whole copy of $DEV in $TRIES pulls (last: $got of $SIZE bytes, kept as $part)" >&2
exit 1
