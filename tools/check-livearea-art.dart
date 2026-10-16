// Refuse LiveArea art the console's promoter will refuse.
//
//     dart tools/check-livearea-art.dart <dir with icon0.png, bg0.png, startup.png>
//
// The shell accepts these three PNGs only as 8-bit indexed (palette) images at
// their fixed sizes. Anything else, a 32-bit RGBA icon most of all, installs
// with 0x8010113D from VitaShell and from our own promoter path alike. Measured
// 2026-09-11 on a fresh console: the same vpk failed with RGBA art and
// installed once the three files were re-encoded, nothing else changed.
//
// Runs at configure time from templates/vita-app/CMakeLists.txt, so the
// message lands in the build log and not on the console's screen as a hex
// code. Until 2026-10-16 this was check-livearea-art.py; Dart comes with the
// Flutter SDK the build already uses, so the build needs no Python.
import 'dart:io';
import 'dart:typed_data';

const expected = {
  'icon0.png': (128, 128),
  'bg0.png': (840, 500),
  'startup.png': (280, 158),
};
const colour = {
  0: 'greyscale',
  2: 'RGB',
  3: 'indexed',
  4: 'greyscale+alpha',
  6: 'RGBA',
};
const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

String? check(File file, (int, int) size) {
  final data = file.readAsBytesSync();
  final isPng = data.length >= 29 &&
      List.generate(8, (i) => data[i] == signature[i]).every((b) => b) &&
      String.fromCharCodes(data.sublist(12, 16)) == 'IHDR';
  if (!isPng) return 'is not a PNG';
  final ihdr = ByteData.sublistView(data, 16, 29);
  final w = ihdr.getUint32(0), h = ihdr.getUint32(4);
  final depth = ihdr.getUint8(8), type = ihdr.getUint8(9);
  final interlace = ihdr.getUint8(12);
  if ((w, h) != size) return 'is ${w}x$h, must be ${size.$1}x${size.$2}';
  if (type != 3) {
    return 'is $depth-bit ${colour[type] ?? type}, must be 8-bit indexed (palette)';
  }
  if (depth > 8) return 'has $depth-bit palette entries, must be 8 or fewer';
  if (interlace != 0) return 'is interlaced, must not be';
  return null;
}

void main(List<String> argv) {
  if (argv.length != 1) {
    stderr.writeln('usage: check-livearea-art.dart <livearea dir>');
    exit(2);
  }
  final where = argv[0].length > 1 && argv[0].endsWith('/')
      ? argv[0].substring(0, argv[0].length - 1)
      : argv[0];
  final bad = <String>[];
  expected.forEach((name, size) {
    final file = File('$where/$name');
    if (!file.existsSync()) {
      bad.add('${file.path}: missing');
      return;
    }
    final why = check(file, size);
    if (why != null) bad.add('${file.path}: $why');
  });
  if (bad.isEmpty) exit(0);
  stderr.writeln('LiveArea art the console will not install (0x8010113D):');
  for (final b in bad) {
    stderr.writeln('  $b');
  }
  stderr.writeln('\nRe-encode as 8-bit indexed PNG, for example:\n'
      '  pngquant --force --output icon0.png 256 icon0.png');
  exit(1);
}
