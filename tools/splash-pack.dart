// Pack a PNG into splash.bin, the picture the embedder puts on the panel from
// the first lines of main() to the first frame.
//
//     dart tools/splash-pack.dart <splash.png> <splash.bin>
//
// Nothing on the console decodes a PNG before the engine is up, so the picture
// goes into the package at the panel's size and pixel format, as runs of equal
// pixels: a flat picture packs to a few kilobytes, a photograph to about the
// 2 MB of the raw panel. A picture smaller than 960x544 is centred on the
// colour of its top-left pixel; a larger one is refused. Transparent pixels
// take that colour too, or black when the corner itself is transparent.
//
// The format is the embedder's (ShowSplash in embedder/src/vita_embedder.cc):
// "FVSPLSH1", the width and height as u16, the payload size as u32, all
// little-endian, then runs over 32-bit R,G,B,A pixels. A control byte c below
// 128 is followed by c + 1 literal pixels; one of 128 or more by one pixel
// that repeats c - 126 times.
//
// Runs at build time from templates/vita-app/CMakeLists.txt, with the Dart of
// the Flutter SDK the build already uses, like check-livearea-art.dart.
import 'dart:io';
import 'dart:typed_data';

const panelWidth = 960;
const panelHeight = 544;
const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

class Picture {
  Picture(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba; // 4 bytes per pixel, rows top to bottom
}

Never fail(String path, String why) {
  stderr.writeln('$path: $why');
  exit(1);
}

int u32(Uint8List b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

Picture decodePng(String path) {
  final data = File(path).readAsBytesSync();
  if (data.length < 8 ||
      !List.generate(8, (i) => data[i] == signature[i]).every((b) => b)) {
    fail(path, 'is not a PNG');
  }
  var width = 0, height = 0, depth = 0, type = -1, interlace = 0;
  Uint8List? palette;
  Uint8List? paletteAlpha;
  final idat = BytesBuilder(copy: false);
  var at = 8;
  while (at + 8 <= data.length) {
    final length = u32(data, at);
    final name = String.fromCharCodes(data.sublist(at + 4, at + 8));
    if (at + 12 + length > data.length) fail(path, 'is cut short');
    final body = Uint8List.sublistView(data, at + 8, at + 8 + length);
    switch (name) {
      case 'IHDR':
        width = u32(body, 0);
        height = u32(body, 4);
        depth = body[8];
        type = body[9];
        interlace = body[12];
      case 'PLTE':
        palette = body;
      case 'tRNS':
        if (type == 3) paletteAlpha = body;
      case 'IDAT':
        idat.add(body);
    }
    at += 12 + length;
    if (name == 'IEND') break;
  }

  final channels = switch (type) {
    0 => 1, // grey
    2 => 3, // RGB
    3 => 1, // indexed
    4 => 2, // grey and alpha
    6 => 4, // RGBA
    _ => fail(path, 'has an unknown colour type $type'),
  };
  if (interlace != 0) fail(path, 'is interlaced; save it without interlacing');
  if (depth == 16) fail(path, 'has 16 bits per channel; save it with 8');
  if (depth != 8 && type != 3 && type != 0) {
    fail(path, 'has $depth bits per channel; save it with 8');
  }
  if (type == 3 && palette == null) fail(path, 'is indexed and has no palette');

  final raw = Uint8List.fromList(ZLibDecoder().convert(idat.takeBytes()));
  final stride = (width * channels * depth + 7) ~/ 8;
  final bpp = ((channels * depth) / 8).ceil();
  if (raw.length < height * (stride + 1)) fail(path, 'has too little image data');

  // Undo the per-row filters (PNG specification, section 9).
  final rows = Uint8List(height * stride);
  for (var y = 0; y < height; y++) {
    final filter = raw[y * (stride + 1)];
    final src = y * (stride + 1) + 1;
    final row = y * stride;
    for (var x = 0; x < stride; x++) {
      final a = x >= bpp ? rows[row + x - bpp] : 0;
      final b = y > 0 ? rows[row - stride + x] : 0;
      final c = x >= bpp && y > 0 ? rows[row - stride + x - bpp] : 0;
      final v = raw[src + x];
      rows[row + x] = switch (filter) {
        0 => v,
        1 => v + a,
        2 => v + b,
        3 => v + ((a + b) >> 1),
        4 => v + paeth(a, b, c),
        _ => fail(path, 'has an unknown row filter $filter'),
      } & 0xFF;
    }
  }

  final rgba = Uint8List(width * height * 4);
  int sample(int y, int x) {
    // One sample of depth bits; only grey and indexed come in under 8.
    if (depth == 8) return rows[y * stride + x];
    final bit = x * depth;
    final byte = rows[y * stride + (bit >> 3)];
    return (byte >> (8 - depth - (bit & 7))) & ((1 << depth) - 1);
  }

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 4;
      switch (type) {
        case 0:
          final g = sample(y, x) * 255 ~/ ((1 << depth) - 1);
          rgba.setAll(o, [g, g, g, 255]);
        case 2:
          final i = y * stride + x * 3;
          rgba.setAll(o, [rows[i], rows[i + 1], rows[i + 2], 255]);
        case 3:
          final p = sample(y, x);
          if (p * 3 + 2 >= palette!.length) fail(path, 'uses colour $p past its palette');
          final alpha = paletteAlpha != null && p < paletteAlpha.length ? paletteAlpha[p] : 255;
          rgba.setAll(o, [palette[p * 3], palette[p * 3 + 1], palette[p * 3 + 2], alpha]);
        case 4:
          final i = y * stride + x * 2;
          rgba.setAll(o, [rows[i], rows[i], rows[i], rows[i + 1]]);
        case 6:
          final i = y * stride + x * 4;
          rgba.setAll(o, rows.sublist(i, i + 4));
      }
    }
  }
  return Picture(width, height, rgba);
}

int paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

/// The panel as 32-bit pixels: R in the low byte, as A8B8G8R8 lies in memory.
Uint32List compose(Picture pic) {
  // The background is the top-left pixel over black.
  final a0 = pic.rgba[3];
  int over(int fg, int alpha, int bg) => (fg * alpha + bg * (255 - alpha)) ~/ 255;
  final bg = [for (var i = 0; i < 3; i++) over(pic.rgba[i], a0, 0)];
  final panel = Uint32List(panelWidth * panelHeight)
    ..fillRange(0, panelWidth * panelHeight, bg[0] | bg[1] << 8 | bg[2] << 16 | 0xFF << 24);
  final ox = (panelWidth - pic.width) ~/ 2, oy = (panelHeight - pic.height) ~/ 2;
  for (var y = 0; y < pic.height; y++) {
    for (var x = 0; x < pic.width; x++) {
      final i = (y * pic.width + x) * 4;
      final alpha = pic.rgba[i + 3];
      final r = over(pic.rgba[i], alpha, bg[0]);
      final g = over(pic.rgba[i + 1], alpha, bg[1]);
      final b = over(pic.rgba[i + 2], alpha, bg[2]);
      panel[(oy + y) * panelWidth + ox + x] = r | g << 8 | b << 16 | 0xFF << 24;
    }
  }
  return panel;
}

Uint8List runs(Uint32List px) {
  final out = BytesBuilder();
  final word = ByteData(4);
  void pixel(int v) {
    word.setUint32(0, v, Endian.little);
    out.add(word.buffer.asUint8List());
  }

  var i = 0;
  while (i < px.length) {
    var run = 1;
    while (i + run < px.length && run < 129 && px[i + run] == px[i]) {
      run++;
    }
    if (run >= 2) {
      out.addByte(run + 126);
      pixel(px[i]);
      i += run;
      continue;
    }
    // Literals until two equal pixels start a run, or 128 of them.
    final start = i;
    while (i < px.length &&
        i - start < 128 &&
        !(i + 1 < px.length && px[i + 1] == px[i])) {
      i++;
    }
    out.addByte(i - start - 1);
    for (var k = start; k < i; k++) {
      pixel(px[k]);
    }
  }
  return out.takeBytes();
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart tools/splash-pack.dart <splash.png> <splash.bin>');
    exit(2);
  }
  final pic = decodePng(args[0]);
  if (pic.width > panelWidth || pic.height > panelHeight) {
    fail(args[0], 'is ${pic.width}x${pic.height}; the panel is '
        '${panelWidth}x$panelHeight, so make it that size or smaller');
  }
  final payload = runs(compose(pic));
  final header = ByteData(16);
  header.buffer.asUint8List().setAll(0, 'FVSPLSH1'.codeUnits);
  header.setUint16(8, panelWidth, Endian.little);
  header.setUint16(10, panelHeight, Endian.little);
  header.setUint32(12, payload.length, Endian.little);
  File(args[1]).writeAsBytesSync([...header.buffer.asUint8List(), ...payload]);
  stdout.writeln('splash ${args[0].split('/').last} ${pic.width}x${pic.height} '
      '-> ${(payload.length + 16 + 1023) ~/ 1024} KB');
}
