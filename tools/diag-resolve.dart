// Resolve the addresses in a diag report through the app's ELF.
//
//     dart tools/diag-resolve.dart <report> <elf> <BuildDiag in the elf, hex> <addr2line>
//
// tools/diag.sh runs this with --elf; the header of diag.sh says what the
// report is. The module loads somewhere other than its ELF vaddr, so every
// address is shifted by a constant, and the one known symbol the report prints
// (`anchor BuildDiag=0x...`) is enough to recover it.
//
// Until 2026-10-16 this was Python inside diag.sh. Only dart: libraries, so it
// runs as a plain script without a package config.
import 'dart:io';

String hex8(int v) => v.toRadixString(16).toUpperCase().padLeft(8, '0');

/// Python's "%-44s" % s[:44].
String fn44(String s) => (s.length > 44 ? s.substring(0, 44) : s).padRight(44);

void main(List<String> argv) {
  if (argv.length != 4) {
    stderr.writeln('usage: diag-resolve.dart <report> <elf> <anchor hex> <addr2line>');
    exit(2);
  }
  final text = File(argv[0]).readAsStringSync();
  final elf = argv[1], a2l = argv[3];
  final elfAnchor = int.parse(argv[2], radix: 16);
  final m = RegExp(r'anchor BuildDiag=0x([0-9A-Fa-f]+)').firstMatch(text);
  if (m == null) {
    stderr.writeln('no anchor in the report');
    exit(1);
  }
  // The reported anchor has the Thumb bit; nm gives the same symbol without it.
  final shift = (int.parse(m[1]!, radix: 16) | 1) - (elfAnchor | 1);
  print('load shift 0x${hex8(shift & 0xFFFFFFFF)}');

  final cache = <int, (String, String)>{};
  (String, String) resolve(int a) => cache.putIfAbsent((a - shift) & ~1, () {
        final e = (a - shift) & ~1;
        final out = (Process.runSync(a2l, ['-f', '-C', '-e', elf, '0x${e.toRadixString(16)}'])
                .stdout as String)
            .split('\n');
        final fn = out.isNotEmpty ? out[0] : '??';
        var loc = out.length > 1 ? out[1] : '??';
        loc = loc.replaceFirst(RegExp(r'^.*/(flutter/|third_party/|src/)'), '');
        return (fn, loc);
      });

  final threadLine =
      RegExp(r'thr (.+?)\s+0x([0-9A-Fa-f]{8})\s+(\S+)\s+(\S+)\s+ran \+(\d+) us \((\d+)%\)');
  final waitLine = RegExp(r'^\s*flutter-vita:\s+(in|last) (.*)$');
  final regsLine = RegExp(r'^\s*flutter-vita:\s+pc ([0-9A-Fa-f]+) lr ([0-9A-Fa-f]+) sp ([0-9A-Fa-f]+)');
  final atLine = RegExp(r'^\s*flutter-vita:\s+at\s+(.*)$');
  final from = RegExp(r'from ([0-9A-Fa-f]{8})');

  String? thread;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    if (line.startsWith('==')) {
      print('\n$line');
      continue;
    }
    final t = threadLine.firstMatch(line);
    if (t != null) {
      thread = '${t[1]} 0x${t[2]} ${t[3]} ${t[4]} ran ${t[5]} us (${t[6]}%)';
      continue;
    }
    // The wait notes a dev build's wrappers leave (templates/vita-app/waits.c):
    // each `from` is the return address of a wrapped wait, exact by
    // construction. Outermost first, so the first name is the reason.
    final w = waitLine.firstMatch(line);
    if (w != null && line.contains('from')) {
      print('\n${thread ?? ''}');
      thread = null;
      final body = w[2]!;
      print('  ${w[1]} ${body.replaceAll(RegExp(r'from [0-9A-Fa-f]{8}'), '').trim()}');
      for (final f in from.allMatches(body)) {
        final a = int.parse(f[1]!, radix: 16);
        final (fn, loc) = resolve(a);
        print('  from ${hex8(a)}  ${fn44(fn)} $loc');
      }
      continue;
    }
    // The registers, when the kernel gave them: pc is the wait itself, lr the
    // caller, and both are exact where the scan below is a heuristic.
    final r = regsLine.firstMatch(line);
    if (r != null) {
      print('\n${thread ?? ''}');
      for (final (name, a) in [('pc', int.parse(r[1]!, radix: 16)), ('lr', int.parse(r[2]!, radix: 16))]) {
        if (0x81000000 <= a && a < 0x88000000) {
          final (fn, loc) = resolve(a);
          print('  $name ${hex8(a)}  ${fn44(fn)} $loc');
        } else {
          print('  $name ${hex8(a)}  (system module)');
        }
      }
      thread = null; // the `at` line that follows belongs to the same header
      continue;
    }
    final at = atLine.firstMatch(line);
    if (at == null) continue;
    final addrs = at[1]!.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    if (thread != null) print('\n$thread');
    for (final s in addrs) {
      final a = int.parse(s, radix: 16);
      final (fn, loc) = resolve(a);
      print('  ${hex8(a)}  ${fn44(fn)} $loc');
    }
  }
}
