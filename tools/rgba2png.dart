// Turn a raw Vita framebuffer dump into a PNG.
//
//     dart tools/rgba2png.dart <raw> <png>
//
// The `shot` command of the bridge and of an app streams the display memory
// verbatim: 960x544, four bytes per pixel, no header and no compression. That
// is the easiest thing for the device to produce -- it is a single write of
// the buffer the display controller is already scanning out -- and it means
// what arrives here is exactly what is on the panel, not a re-render of what
// should be. tools/panel.sh runs this; `flutter-vita screenshot` uses the same
// encoder, cli/lib/src/png.dart, directly.
//
// Until 2026-10-16 this was rgba2png.py. A relative import of the CLI's file,
// which imports only dart: libraries, so this runs without a package config.
import 'dart:io';

import '../cli/lib/src/png.dart';

void main(List<String> argv) {
  if (argv.length != 2) {
    stderr.writeln('usage: rgba2png.dart <raw> <png>');
    exit(2);
  }
  final List<int> png;
  try {
    png = encodePng(File(argv[0]).readAsBytesSync());
  } on FormatException catch (e) {
    // A short read means the transfer was cut off, and a skewed picture
    // invites hours spent debugging the present path instead of the socket.
    stderr.writeln(e.message);
    exit(1);
  }
  File(argv[1]).writeAsBytesSync(png);
  stdout.writeln('${argv[1]}  960x544  ${png.length} B');
}
