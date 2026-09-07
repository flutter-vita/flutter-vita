#!/usr/bin/env bash
# Turn a Vita crash dump into a symbolicated backtrace.
#
# The Vita writes psp2core-*.psp2dmp to ux0:data/ whenever an app faults, and
# xyzz/vita-parse-core resolves the addresses in one against our unstripped ELF.
# That is a far better tool than the trace-point bisection M1 has been using:
# a hard fault with no diagnostic becomes a stack with function names.
#
# Needs the .elf from build/, not eboot.bin or the .velf -- eboot.bin is a SELF
# with the symbol information stripped out. The build already carries full DWARF
# because the Dart objects are compiled -g3.
#
# Usage:
#   ./analyse-crash.sh <psp2core-file>
#
# Get the dump off the device with VitaShell's FTP (SELECT), e.g.
#   curl -sO "ftp://$VITA_IP:1337/data/psp2core-1234567890-0x00000000-eboot.bin.psp2dmp"
set -euo pipefail
cd "$(dirname "$0")"

: "${VITASDK:=$HOME/vitasdk}"; export PATH="$VITASDK/bin:$PATH"
DUMP="${1:?usage: ./analyse-crash.sh <psp2core-file.psp2dmp>}"
ELF="build/flutter_vita_m1"
TOOL="${VPC_DIR:-out/vita-parse-core}"

[[ -f "$ELF" ]] || { echo "error: no $ELF -- run ./build.sh first" >&2; exit 1; }
[[ -f "$DUMP" ]] || { echo "error: no dump at $DUMP" >&2; exit 1; }

if [[ ! -d "$TOOL" ]]; then
  echo "==> fetching vita-parse-core"
  mkdir -p "$(dirname "$TOOL")"
  git clone -q --depth 1 https://github.com/xyzz/vita-parse-core "$TOOL"
fi

# The README says python2; the sources are simple enough that python3 generally
# works. Fall back with a clear message rather than a traceback.
echo "==> parsing $(basename "$DUMP")"
python3 "$TOOL/main.py" "$DUMP" "$ELF" || {
  echo
  echo "If that failed on syntax, the tool is python2-era. Either run it under" >&2
  echo "python2, or use 2to3 on $TOOL." >&2
  exit 1
}
