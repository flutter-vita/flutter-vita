#!/usr/bin/env bash
# Compile a GLSL ES pair on the console and say whether libshacccg took it.
#
#   ./tools/shader-probe.sh out/shaderprobe/v.glsl out/shaderprobe/f.glsl
#   ./tools/shader-probe.sh --opt 1 v.glsl f.glsl     0=O0 1=O1 2=O2 3=O3 4=Ofast
#
# libshacccg is a Vita module. There is no host copy, so a shader it refuses can
# only be bisected against the real thing -- which is what this is for: the app
# picks the pair up on its next present, compiles it, and writes the answer
# back.
#
# The app must be running and built with the probe (RunShaderProbe in
# vita_embedder.cc). Any app on the GL path will do; the shader compiler is not
# app-specific.
set -euo pipefail

HOST="${VITA_HOST:-flutter-vita.local}"
PORT="${DEV_PORT:-1339}"
DIR="ux0:data/flutter-vita/shadertest"

OPT=""
if [ "${1:-}" = "--opt" ]; then OPT="$2"; shift 2; fi

V="${1:?vertex shader}"
F="${2:?fragment shader}"

put() {
  local src="$1" dst="$2" n
  n=$(wc -c < "$src" | tr -d ' ')
  { printf 'put %s %s\n' "$n" "$dst"; cat "$src"; } | nc -w 30 "$HOST" "$PORT" \
    | grep -q OK || { echo "!! put $dst failed" >&2; exit 1; }
}

# Delete the previous answer first. Without this the poll below reads the file
# from the last run and reports it as this one -- which produced two identical
# timings to the microsecond and nearly cost a wrong conclusion.
printf 'rm %s/result.txt\n' "$DIR" | nc -w 20 "$HOST" "$PORT" >/dev/null || true
if [ -n "$OPT" ]; then
  printf 'put %s %s/opt\n%s\n' "$(( ${#OPT} + 1 ))" "$DIR" "$OPT" \
    | nc -w 20 "$HOST" "$PORT" >/dev/null
else
  printf 'rm %s/opt\n' "$DIR" | nc -w 20 "$HOST" "$PORT" >/dev/null || true
fi

# Every probe gets a unique comment appended.
#
# Both of this port's shader caches key on a hash of the source: the on-disk
# .gxp cache for successes, and the in-memory refusal list for failures. Probe
# the same text twice and the second run answers from one of them in nine
# milliseconds instead of compiling -- which produced a "LINK OK" for a shader
# that does not link, and very nearly a wrong conclusion.
NONCE="$(date +%s)-$RANDOM"
VN="$(mktemp)"; FN="$(mktemp)"
trap 'rm -f "$VN" "$FN"' EXIT
{ cat "$V"; printf '\n// probe %s\n' "$NONCE"; } > "$VN"
{ cat "$F"; printf '\n// probe %s\n' "$NONCE"; } > "$FN"
V="$VN"; F="$FN"

put "$V" "$DIR/v.glsl"
put "$F" "$DIR/f.glsl"
printf 'put 2 %s/go\n1\n' "$DIR" | nc -w 20 "$HOST" "$PORT" | grep -q OK \
  || { echo "!! could not arm the probe" >&2; exit 1; }

# A present every ~33 ms and a check every 60 of them: two seconds is generous,
# and a compile that fails can take another second on top.
for _ in $(seq 1 20); do
  sleep 1
  OUT="$(printf 'get %s/result.txt\n' "$DIR" | nc -w 20 "$HOST" "$PORT" || true)"
  case "$OUT" in
    LINK*|MISSING*) printf '%s\n' "$OUT"; exit 0 ;;
  esac
done
echo "!! no result -- is the app running and built with the probe?" >&2
exit 1
