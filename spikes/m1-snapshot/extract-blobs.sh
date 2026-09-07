#!/usr/bin/env bash
# Split an app-aot-elf snapshot into the four blobs Dart_CreateIsolateGroup wants.
#
# Why not load the ELF on device? Dart ships Dart_LoadELF_Memory, but
# runtime/bin/elf_receiver.cc pulls in bin/file.h, bin/mappable.h,
# bin/virtual_memory.h and <sys/mman.h> -- the dart:io layer this port
# deliberately excludes, plus an mmap the Vita does not have. Writing an ELF
# parser for the device instead would be a few hundred lines of untested C
# running before any logging exists.
#
# Doing it at build time is strictly better: the work happens on a machine with
# real tools, the device just reads four files, and the sizes are verifiable
# here rather than guessed at on hardware.
#
# The two _data blobs go in ordinary memory. The two _instructions blobs are
# machine code and must land in a VM-domain block -- ADR-0005.
set -euo pipefail

cd "$(dirname "$0")"
: "${VITASDK:=$HOME/vitasdk}"; export PATH="$VITASDK/bin:$PATH"
ELF="${1:-out/hello-vita.elf}"
OUT=out/blobs

[[ -f "$ELF" ]] || { echo "error: no snapshot at $ELF -- run ./build.sh first" >&2; exit 1; }
mkdir -p "$OUT"

# Section bounds and symbol addresses, via python since BSD awk has no strtonum.
eval "$(python3 - "$ELF" <<'PYEOF'
import subprocess, sys, shlex
elf = sys.argv[1]
def run(*a): return subprocess.run(list(a), capture_output=True, text=True).stdout

sec = {}
for line in run("arm-vita-eabi-objdump", "-h", elf).splitlines():
    f = line.split()
    if len(f) >= 7 and f[1] in (".rodata", ".text"):
        sec[f[1]] = {"size": int(f[2], 16), "vma": int(f[3], 16), "off": int(f[5], 16)}

for name, d in sec.items():
    if d["vma"] != d["off"]:
        sys.exit(f"echo 'error: {name} VMA 0x{d[chr(34)+chr(34)]:x} != file offset'; exit 1")

syms = {}
for line in run("arm-vita-eabi-nm", elf).splitlines():
    f = line.split()
    if len(f) == 3 and f[2].startswith("_kDart"):
        syms[f[2]] = int(f[0], 16)

need = ["_kDartVmSnapshotData", "_kDartIsolateSnapshotData",
        "_kDartVmSnapshotInstructions", "_kDartIsolateSnapshotInstructions"]
missing = [n for n in need if n not in syms]
if missing:
    sys.exit(f"echo 'error: missing symbols: {missing}'; exit 1")

print(f'VMD={syms["_kDartVmSnapshotData"]}')
print(f'ISD={syms["_kDartIsolateSnapshotData"]}')
print(f'VMI={syms["_kDartVmSnapshotInstructions"]}')
print(f'ISI={syms["_kDartIsolateSnapshotInstructions"]}')
print(f'RO_END={sec[".rodata"]["off"] + sec[".rodata"]["size"]}')
print(f'TX_END={sec[".text"]["off"] + sec[".text"]["size"]}')
PYEOF
)"

# Each blob runs from its symbol to the next one, or to the end of its section.
slice() { # name start end
  local n=$1 start=$2 end=$3 len=$(( $3 - $2 ))
  dd if="$ELF" of="$OUT/$n.bin" bs=1 skip="$start" count="$len" status=none
  printf "  %-36s %9d B  (offset 0x%06x)\n" "$n.bin" "$len" "$start"
}

echo "==> extracting from $ELF"
slice vm_snapshot_data              "$VMD" "$ISD"
slice isolate_snapshot_data         "$ISD" "$RO_END"
slice vm_snapshot_instructions      "$VMI" "$ISI"
slice isolate_snapshot_instructions "$ISI" "$TX_END"

echo
echo "==> instructions total (must fit a 16 MiB VM block, 1 MiB minimum granularity)"
ins=$(( $(stat -f%z "$OUT/vm_snapshot_instructions.bin") + $(stat -f%z "$OUT/isolate_snapshot_instructions.bin") ))
printf "  %d B = %.2f MiB\n" "$ins" "$(echo "scale=4; $ins/1048576" | bc)"
