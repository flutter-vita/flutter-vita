#!/usr/bin/env python3
"""Recompute docs/gles2-progress.md from the source.

    ./tools/gles2-progress.py           rewrite the generated blocks
    ./tools/gles2-progress.py --check   exit 1 if the doc is stale

Two numbers, neither typed by hand:

  * the entry-point ledger: every name in engine/gles2/surface.txt is `real` when a
    GL_APIENTRY definition exists in engine/gles2/src, `stub` when it is declared
    through FVGL_STUB, `missing` otherwise;
  * the headline percentage: the weighted sum of the area table, whose `done`
    column is edited by hand and must cite its evidence.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOC = ROOT / "docs" / "gles2-progress.md"
SURFACE = ROOT / "engine" / "gles2" / "surface.txt"
SRC = ROOT / "engine" / "gles2" / "src"

DEF = re.compile(r"GL_APIENTRY\s+((?:gl|egl)[A-Za-z0-9_]+)\s*\(")
STUB = re.compile(r"FVGL_STUB\(\s*((?:gl|egl)[A-Za-z0-9_]+)")


def surface():
    rows = []
    for line in SURFACE.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        name, tag, peak = line.split("\t")
        rows.append((name, tag, int(peak)))
    return rows


def implemented():
    real, stub = set(), set()
    for c in sorted(SRC.glob("*.c")):
        text = c.read_text()
        stub.update(STUB.findall(text))
        for name in DEF.findall(text):
            if name not in stub:
                real.add(name)
    return real, stub


def areas(doc):
    block = doc.split("<!-- areas:begin -->")[1].split("<!-- areas:end -->")[0]
    rows = []
    for line in block.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 4 or not cells[1].isdigit():
            continue
        rows.append((cells[0], int(cells[1]), int(cells[2].rstrip("%")), cells[3]))
    return rows


def replace_block(doc, tag, body):
    begin, end = f"<!-- {tag}:begin -->", f"<!-- {tag}:end -->"
    head, rest = doc.split(begin)
    _, tail = rest.split(end)
    return f"{head}{begin}\n{body}\n{end}{tail}"


def main():
    doc = DOC.read_text()
    rows = surface()
    real, stub = implemented()
    table = areas(doc)
    weight = sum(w for _, w, _, _ in table)
    total = sum(w * d for _, w, d, _ in table) / weight if weight else 0

    called = [n for n, t, _ in rows if t == "called"]
    never = [n for n, t, _ in rows if t == "never"]
    real_called = [n for n in called if n in real]
    real_never = [n for n in never if n in real]
    stubbed = [n for n, _, _ in rows if n in stub]
    missing = [n for n, _, _ in rows if n not in real and n not in stub]

    headline = "\n".join([
        f"**{total:.0f}% complete** (weighted areas, weights sum to {weight}).",
        "",
        "| entry points | count |",
        "|---|---|",
        f"| bound by Skia (`engine/gles2/surface.txt`) | {len(rows)} |",
        f"| called in some run, implemented | {len(real_called)} of {len(called)} |",
        f"| never called, implemented anyway | {len(real_never)} of {len(never)} |",
        f"| recording stubs | {len(stubbed)} |",
        f"| missing | {len(missing)} |",
    ])
    ledger = ["| entry point | measured | peak calls | state |", "|---|---|---|---|"]
    for n, t, peak in rows:
        state = "real" if n in real else "stub" if n in stub else "missing"
        ledger.append(f"| `{n}` | {t} | {peak} | {state} |")
    new = replace_block(doc, "progress", headline)
    new = replace_block(new, "ledger", "\n".join(ledger))
    if "--check" in sys.argv:
        if new != doc:
            print("docs/gles2-progress.md is stale; run tools/gles2-progress.py", file=sys.stderr)
            return 1
        print(f"gles2 progress: {total:.0f}%")
        return 0
    DOC.write_text(new)
    print(f"gles2 progress: {total:.0f}%  real {len(real)}  stub {len(stub)}  missing {len(missing)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
