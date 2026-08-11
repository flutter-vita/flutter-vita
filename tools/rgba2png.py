#!/usr/bin/env python3
"""Turn a raw Vita framebuffer dump into a PNG.

The `shot` command on m3's dev server streams the display memory verbatim:
960x544, four bytes per pixel, no header and no compression. That is the
easiest thing for the device to produce -- it is a single write of the buffer
the display controller is already scanning out -- and it means what arrives
here is exactly what is on the panel, not a re-render of what should be.

    APP=m3 ./spikes/m1-vpk/dev.sh shot out/screen.png

Pixel order is SCE_DISPLAY_PIXELFORMAT_A8B8G8R8, which on a little-endian
target is R,G,B,A in memory order -- byte-identical to PNG's RGBA. So there is
no swizzle here, and if the colours come out wrong that is a real finding about
the present path rather than a bug in this script.

Written against zlib and struct rather than Pillow, so the dev loop does not
gain a dependency for one debugging tool.
"""

import struct
import sys
import zlib

WIDTH = 960
HEIGHT = 544
BYTES_PER_PIXEL = 4


def chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <raw> <png>", file=sys.stderr)
        return 2

    raw = open(sys.argv[1], "rb").read()

    expected = WIDTH * HEIGHT * BYTES_PER_PIXEL
    if len(raw) != expected:
        # Worth failing loudly rather than rendering a skewed image. A short
        # read means the transfer was cut off, and a skewed picture invites
        # hours spent debugging the present path instead of the socket.
        print(
            f"expected {expected} bytes ({WIDTH}x{HEIGHT}x{BYTES_PER_PIXEL}), "
            f"got {len(raw)}",
            file=sys.stderr,
        )
        return 1

    # PNG wants each scanline prefixed with a filter byte; 0 means "none".
    stride = WIDTH * BYTES_PER_PIXEL
    scanlines = b"".join(
        b"\x00" + raw[y * stride : (y + 1) * stride] for y in range(HEIGHT)
    )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(scanlines, 6))
    png += chunk(b"IEND", b"")

    open(sys.argv[2], "wb").write(png)
    print(f"{sys.argv[2]}  {WIDTH}x{HEIGHT}  {len(png)} B")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
