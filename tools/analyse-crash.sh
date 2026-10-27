#!/usr/bin/env bash
# Pull a crash dump off the console and symbolicate it.
#
#   ./tools/analyse-crash.sh <elf>                  newest dump on the device
#   ./tools/analyse-crash.sh <elf> --dump <file>    one already downloaded
#   ./tools/analyse-crash.sh --list                 what dumps are on the card
#
#   --port N    where to fetch from: an app's 1339, a bridge's 1341 or 1342
#   --keep N    delete all but the newest N dumps after fetching (default: off)
#
# The Vita writes psp2core-*.psp2dmp to ux0:data whenever a process faults, and
# xyzz/vita-parse-core resolves the addresses against the unstripped ELF. That
# turns a hard fault with no diagnostic into a thread list, a fault type and a
# register dump -- which on 2026-08-31 was the difference between "the console
# goes down about ten seconds after PAF loads" and "PAF's own thread takes a
# data abort at its entry point".
#
# **The ELF must be the one that produced the dump.** Every build relocates, so
# a rebuilt app symbolicates to confident nonsense rather than to an error. If
# you are hunting something intermittent, keep build/vita/cmake/flutter_vita_app
# somewhere before you go looking for the crash.
#
# experiments/m1-vpk/analyse-crash.sh (in git history at c91294a) is the
# ancestor of this.
# What is here that is not there: fetching over the dev server rather than FTP,
# and the pyelftools pin below.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Outputs go beside a git checkout, else into the flutter-vita home: a tree
# without .git is an install that its package manager deletes on upgrade.
OUT_BASE="$ROOT/out"
[ -e "$ROOT/.git" ] || OUT_BASE="${FLUTTER_VITA_HOME:-$HOME/.flutter-vita}/out"
HOST="${VITA_HOST:-fluttervita.local}"
PORT="${DEV_PORT:-1339}"
TOOL="$OUT_BASE/vita-parse-core"
# vita-parse-core imports elftools.common.py3compat, which pyelftools dropped.
# Pinned rather than patched: the tool is vendored from a third party and a
# local edit to it is a local edit nobody will remember making.
VENV="${VPC_VENV:-$OUT_BASE/vpc-venv}"
PYELFTOOLS=0.29

ELF=""
DUMP=""
LIST=0
KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)    LIST=1; shift ;;
    --dump)    DUMP="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --host)    HOST="$2"; shift 2 ;;
    --keep)    KEEP="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; exit 2 ;;
    *)         ELF="$1"; shift ;;
  esac
done

say() { printf '%s\n' "$2" | nc -4 -w "${3:-30}" "$HOST" "$1"; }

# Newest first, by the epoch second in the filename. `.tmp` names are dumps the
# console was still writing when it went down, and are not readable.
dumps() {
  say "$PORT" 'ls ux0:data' 30 \
    | awk '$NF ~ /psp2dmp$/ { print $NF }' \
    | sed -E 's/^(psp2core-([0-9]+)-.*)$/\2 \1/' \
    | sort -rn
}

if [ "$LIST" -eq 1 ]; then
  dumps | while read -r ts name; do
    printf '%s  %s\n' "$(date -r "$ts" '+%Y-%m-%d %H:%M:%S')" "$name"
  done
  exit 0
fi

[ -n "$ELF" ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ -f "$ELF" ] || { echo "!! no ELF at $ELF" >&2; exit 1; }

if [ -z "$DUMP" ]; then
  read -r TS NAME < <(dumps | head -1)
  [ -n "${NAME:-}" ] || { echo "!! no dumps on the card" >&2; exit 1; }
  mkdir -p "$OUT_BASE/dumps"
  DUMP="$OUT_BASE/dumps/$NAME"
  if [ -s "$DUMP" ]; then
    echo "==> $NAME already here"
  else
    echo "==> fetching $NAME  ($(date -r "$TS" '+%Y-%m-%d %H:%M:%S'))"
    # pull.sh, not a bare get: a Wi-Fi drop used to leave a dump with a hole in
    # it and no error, and the stacks read from it were wrong.
    "$HERE/pull.sh" "$PORT" "ux0:data/$NAME" "$DUMP" --host "$HOST" --wait 300 || exit 1
    [ -s "$DUMP" ] || { rm -f "$DUMP"; echo "!! empty transfer" >&2; exit 1; }
    printf '    %s B\n' "$(wc -c <"$DUMP" | tr -d ' ')"
  fi
fi

if [ ! -d "$TOOL" ]; then
  echo "==> fetching vita-parse-core"
  mkdir -p "$(dirname "$TOOL")"
  git clone -q --depth 1 https://github.com/xyzz/vita-parse-core "$TOOL"
fi

if [ ! -x "$VENV/bin/python" ]; then
  echo "==> venv with pyelftools $PYELFTOOLS"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install "pyelftools==$PYELFTOOLS"
fi

VITASDK="$("$(dirname "$0")/vitasdk.sh" --find)"; export PATH="$VITASDK/bin:$PATH"
echo "==> $(basename "$DUMP") against $(basename "$ELF")"
echo
"$VENV/bin/python" "$TOOL/main.py" "$DUMP" "$ELF"

# Only after a successful parse, and only when asked. A dump is the only record
# of a fault that has already happened.
if [ -n "$KEEP" ]; then
  echo
  echo "==> keeping the newest $KEEP"
  dumps | tail -n +"$((KEEP + 1))" | while read -r _ name; do
    say "$PORT" "rm ux0:data/$name" 20 | sed 's/^/    /'
  done
fi
