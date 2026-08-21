import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Wrap a raw Vita framebuffer in a PNG.
///
/// `SCE_DISPLAY_PIXELFORMAT_A8B8G8R8` is R,G,B,A in memory order on a
/// little-endian target, which is byte-identical to PNG's RGBA — so there is
/// no channel swizzle here. If a capture ever comes out with wrong colours
/// that is a finding about the present path, not a bug in this file.
Uint8List encodePng(Uint8List rgba, {int width = 960, int height = 544}) {
  final expected = width * height * 4;
  if (rgba.length != expected) {
    // Loud, because a short read renders as a plausible-looking skewed image
    // and invites hours spent debugging the wrong layer.
    throw FormatException(
      'expected $expected bytes (${width}x$height RGBA), got ${rgba.length}',
    );
  }

  // Each scanline is prefixed with a filter byte; 0 means "none".
  final stride = width * 4;
  final raw = Uint8List(height * (stride + 1));
  for (var y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    raw.setRange(
      y * (stride + 1) + 1,
      y * (stride + 1) + 1 + stride,
      rgba,
      y * stride,
    );
  }

  final png = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk('IHDR', (BytesBuilder()
          ..add(_be32(width))
          ..add(_be32(height))
          ..add(const [8, 6, 0, 0, 0]))
        .takeBytes()))
    ..add(_chunk('IDAT', ZLibCodec(level: 6).encode(raw)))
    ..add(_chunk('IEND', Uint8List(0)));
  return png.takeBytes();
}

Uint8List _chunk(String tag, List<int> data) {
  final tagBytes = ascii.encode(tag);
  final body = Uint8List.fromList([...tagBytes, ...data]);
  return Uint8List.fromList([
    ..._be32(data.length),
    ...body,
    ..._be32(_crc32(body)),
  ]);
}

List<int> _be32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
