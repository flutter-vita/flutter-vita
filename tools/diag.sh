#!/usr/bin/env bash
# Ask a running app why nothing is moving, and resolve the answer.
#
#   ./tools/diag.sh                       two samples, five seconds apart
#   ./tools/diag.sh --once                one sample
#   ./tools/diag.sh --gap 15              a longer window between them
#   ./tools/diag.sh --port 1341           the receiver instead of an app
#   ./tools/diag.sh --elf path/to/elf     symbolicate the stack scans
#   ./tools/diag.sh --resolve report.txt --elf path/to/elf
#                                         no sampling: resolve a saved report
#                                         (a STALL block from app.log, the
#                                         watchdog's stall.txt, bench.sh's
#                                         stuck file)
#
# Two samples, not one, and that is the whole reason this script exists rather
# than a bare `printf 'diag\n' | nc`. Every per-thread figure in the report is
# a delta against the previous sample, so a single call reports a window of
# unknown length and tells you almost nothing; a pair reports the seconds
# between them, and the difference between a thread that is parked and a thread
# that is spinning only exists in that difference.
#
# The first sample is printed too, because its *absolute* columns -- status,
# what each thread is waiting on, the raster phase, free memory -- are already
# worth reading.
#
# `at` lines are a scan of each thread's live stack for things that look like
# Thumb return addresses. They are a heuristic and they include stale frames.
# With --elf they are resolved through the anchor the report prints: the module
# loads somewhere other than its ELF vaddr, so every address is shifted by a
# constant, and one known symbol is enough to recover it.
#
# **The ELF must be the one running on the console.** Every build relocates.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${VITA_HOST:-flutter-vita.local}"
PORT="${DEV_PORT:-1339}"
ELF=""
GAP=5
ONCE=0
RESOLVE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --once)    ONCE=1; shift ;;
    --gap)     GAP="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --host)    HOST="$2"; shift 2 ;;
    --elf)     ELF="$2"; shift 2 ;;
    --resolve) RESOLVE="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$RESOLVE" ]; then
  [ -n "$ELF" ] || { echo "!! --resolve needs --elf" >&2; exit 2; }
  [ -f "$RESOLVE" ] || { echo "!! no such report: $RESOLVE" >&2; exit 2; }
  RAW="$RESOLVE"
else
  RAW="$(mktemp)"
  trap 'rm -f "$RAW"' EXIT
fi

sample() {
  printf 'diag\n' | nc -w 25 "$HOST" "$PORT" \
    || { echo "!! no answer from $HOST:$PORT" >&2; exit 1; }
}

[ -n "$RESOLVE" ] || {
  echo "== sample 1"
  sample
  if [ "$ONCE" != "1" ]; then
    sleep "$GAP"
    echo
    echo "== sample 2 (deltas are over the last ${GAP}s)"
    sample
  fi
} | tee "$RAW"

[ -n "$ELF" ] || exit 0

echo
echo "== resolved"
NM="${VITASDK:-$HOME/vitasdk}/bin/arm-vita-eabi-nm"
A2L="${VITASDK:-$HOME/vitasdk}/bin/arm-vita-eabi-addr2line"
ELF_ANCHOR="$("$NM" "$ELF" | grep -i 'BuildDiag' | head -1 | awk '{print $1}')"
[ -n "$ELF_ANCHOR" ] || { echo "!! no BuildDiag in $ELF -- wrong binary?" >&2; exit 1; }

python3 - "$RAW" "$ELF" "$ELF_ANCHOR" "$A2L" <<'PY'
import re, subprocess, sys
raw, elf, elf_anchor, a2l = sys.argv[1], sys.argv[2], int(sys.argv[3], 16), sys.argv[4]
text = open(raw).read()
m = re.search(r'anchor BuildDiag=0x([0-9A-Fa-f]+)', text)
if not m:
    sys.exit("no anchor in the report")
# The reported anchor has the Thumb bit; nm gives the same symbol without it.
shift = (int(m.group(1), 16) | 1) - (elf_anchor | 1)
print("load shift 0x%08X" % (shift & 0xffffffff))

cache = {}
def resolve(a):
    e = (a - shift) & ~1
    if e not in cache:
        out = subprocess.run([a2l, '-f', '-C', '-e', elf, hex(e)],
                             capture_output=True, text=True).stdout.split('\n')
        fn = out[0] if out else '??'
        loc = out[1] if len(out) > 1 else '??'
        loc = re.sub(r'^.*/(flutter/|third_party/|src/)', '', loc)
        cache[e] = (fn, loc)
    return cache[e]

thread = None
for line in text.splitlines():
    if line.startswith('=='):
        print("\n%s" % line)
        continue
    t = re.search(r'thr (.+?)\s+0x([0-9A-Fa-f]{8})\s+(\S+)\s+(\S+)\s+ran \+(\d+) us \((\d+)%\)', line)
    if t:
        thread = "%s 0x%s %s %s ran %s us (%s%%)" % t.groups()
        continue
    # The wait notes a dev build's wrappers leave (templates/vita-app/waits.c):
    # each `from` is the return address of a wrapped wait, exact by
    # construction. Outermost first, so the first name is the reason.
    w = re.match(r'\s*flutter-vita:\s+(in|last) (.*)$', line)
    if w and 'from' in line:
        print("\n%s" % thread)
        thread = None
        body = w.group(2)
        print("  %s %s" % (w.group(1), re.sub(r'from [0-9A-Fa-f]{8}', '', body).strip()))
        for a in re.findall(r'from ([0-9A-Fa-f]{8})', body):
            a = int(a, 16)
            fn, loc = resolve(a)
            print("  from %08X  %-44s %s" % (a, fn[:44], loc))
        continue
    # The registers, when the kernel gave them: pc is the wait itself, lr the
    # caller, and both are exact where the scan below is a heuristic.
    r = re.match(r'\s*flutter-vita:\s+pc ([0-9A-Fa-f]+) lr ([0-9A-Fa-f]+) sp ([0-9A-Fa-f]+)', line)
    if r:
        print("\n%s" % thread)
        for name, a in (('pc', int(r.group(1), 16)), ('lr', int(r.group(2), 16))):
            if 0x81000000 <= a < 0x88000000:
                fn, loc = resolve(a)
                print("  %s %08X  %-44s %s" % (name, a, fn[:44], loc))
            else:
                print("  %s %08X  (system module)" % (name, a))
        thread = None  # the `at` line that follows belongs to the same header
        continue
    f = re.match(r'\s*flutter-vita:\s+at\s+(.*)$', line)
    if not f:
        continue
    addrs = [int(a, 16) for a in f.group(1).split()]
    if thread is not None:
        print("\n%s" % thread)
    for a in addrs:
        fn, loc = resolve(a)
        print("  %08X  %-44s %s" % (a, fn[:44], loc))
PY
