#!/usr/bin/env bash
# Build the module spike, then run it on the console.
#
#   ./experiments/vitagl-module/build.sh            build only
#   ./experiments/vitagl-module/build.sh --run      build, deploy, read the report
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VITASDK="${VITASDK:-$HOME/vitasdk}"
# vita-libs-gen-2 shells out to arm-vita-eabi-as by bare name, so the assembler
# has to be on PATH or the stub build fails at the first .o.
export VITASDK PATH="$VITASDK/bin:$PATH"
# By name. Never an address, not even to get unstuck: see tools/deploy.sh.
HOST="${VITA_HOST:-fluttervita.local}"
PORT="${RECEIVER_PORT:-1341}"

cmake -S "$HERE" -B "$HERE/build" >/dev/null
cmake --build "$HERE/build"

[ "${1:-}" = "--run" ] || exit 0

say() { printf '%s\n' "$2" | nc -w "${3:-30}" "$HOST" "$1"; }

# The module goes to ux0:data, not into the vpk. That is the point: one copy on
# the card that every application loads, which is what LGPL-3 section 4(d)(1)
# describes as a copy already present on the user's system.
SUPRX="$HERE/build/spike.suprx"
SIZE=$(wc -c <"$SUPRX" | tr -d ' ')
{ printf 'put %s ux0:data/flutter-vita/spike.suprx\n' "$SIZE"; cat "$SUPRX"; } \
  | nc -w 60 "$HOST" "$PORT" | sed 's/^/    /'

# FVTA00002 has to exist. On a console that has never had an app deployed it
# does not, and deploy.sh cannot create it -- `put` writes files and registers
# nothing. install-vpk.sh goes through the promoter, which can.
if ! say "$PORT" "exist FVTA00002" 20 | grep -q "res=3"; then
  "$ROOT/tools/install-vpk.sh" "$HERE/build/spike_app.vpk" \
    --host "$HOST" --port "$PORT" --no-launch | sed 's/^/    /'
else
  "$ROOT/tools/install-vpk.sh" "$HERE/build/spike_app.vpk" \
    --host "$HOST" --port "$PORT" --replace --no-launch | sed 's/^/    /'
fi

say "$PORT" "launch FVTA00002" 20 | sed 's/^/    /'
for _ in $(seq 1 20); do
  sleep 3
  case "$(say "$PORT" ping 4 2>/dev/null || true)" in pong*) break ;; esac
done
echo "--- report"
say "$PORT" "get ux0:data/flutter-vita/spike-module.txt" 20
