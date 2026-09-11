#!/usr/bin/env python3
"""Refuse LiveArea art the console's promoter will refuse.

    ./tools/check-livearea-art.py <dir with icon0.png, bg0.png, startup.png>

The shell accepts these three PNGs only as 8-bit indexed (palette) images at
their fixed sizes. Anything else, a 32-bit RGBA icon most of all, installs
with 0x8010113D from VitaShell and from our own promoter path alike. Measured
2026-09-11 on a fresh console: the same vpk failed with RGBA art and installed
once the three files were re-encoded, nothing else changed.

Runs at configure time from templates/vita-app/CMakeLists.txt, so the message
lands in the build log and not on the console's screen as a hex code.
"""
import struct
import sys
from pathlib import Path

EXPECTED = {
    "icon0.png": (128, 128),
    "bg0.png": (840, 500),
    "startup.png": (280, 158),
}
COLOUR = {0: "greyscale", 2: "RGB", 3: "indexed", 4: "greyscale+alpha", 6: "RGBA"}


def check(path: Path, size):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return "is not a PNG"
    w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", data[16:29])
    if (w, h) != size:
        return f"is {w}x{h}, must be {size[0]}x{size[1]}"
    if ctype != 3:
        return f"is {depth}-bit {COLOUR.get(ctype, ctype)}, must be 8-bit indexed (palette)"
    if depth > 8:
        return f"has {depth}-bit palette entries, must be 8 or fewer"
    if interlace:
        return "is interlaced, must not be"
    return None


def main() -> int:
    where = Path(sys.argv[1])
    bad = []
    for name, size in EXPECTED.items():
        p = where / name
        if not p.exists():
            bad.append(f"{p}: missing")
            continue
        why = check(p, size)
        if why:
            bad.append(f"{p}: {why}")
    if not bad:
        return 0
    print("LiveArea art the console will not install (0x8010113D):", file=sys.stderr)
    for b in bad:
        print(f"  {b}", file=sys.stderr)
    print(
        "\nRe-encode as 8-bit indexed PNG, for example:\n"
        "  python3 -c \"from PIL import Image; im=Image.open('icon0.png');"
        " im.convert('RGBA').quantize(256, method=Image.Quantize.FASTOCTREE)"
        ".save('icon0.png', optimize=True)\"\n"
        "or: pngquant --force --output icon0.png 256 icon0.png",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
