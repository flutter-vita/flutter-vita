// The files the gallery's two suites share with the host.
//
// The host starts an unattended run by writing a '1' to `<suite>.on` and
// relaunching; the run writes `<suite>-result.json` and then `<suite>-done`.
// Two files because the host has to tell "still running" from "wrote a
// truncated file", and a rename is the only atomic operation available.
// tools/suite.sh is the host's side.
//
// These lived in the benchmark's runner until 2026-10-01, when the scenes
// moved to github.com/flutter-vita/flutter-vita-bench.

import 'dart:io';

const String kDataDir = 'ux0:data/flutter-vita';

// The Tests tab was the Conformance tab until 2026-10-01, and its files were
// conformance.on, conformance-result.json and conformance-done.
const String kTestsSwitchPath = '$kDataDir/tests.on';
const String kTestsResultPath = '$kDataDir/tests-result.json';
const String kTestsDonePath = '$kDataDir/tests-done';
const String kHardwareSwitchPath = '$kDataDir/hardware.on';
const String kHardwareResultPath = '$kDataDir/hardware-result.json';
const String kHardwareDonePath = '$kDataDir/hardware-done';

/// The engine receipt, shipped inside the vpk by templates/vita-app.
const String kEngineManifest = 'app0:/engine.txt';

/// Which engine build this binary links, or null if it cannot tell.
///
/// `built at` rather than the git revision: the revision is identical across
/// rebuilds, so it cannot separate two engines that differ by a commit.
String? engineStamp() {
  try {
    final f = File(kEngineManifest);
    if (!f.existsSync()) return null;
    String? rev;
    String? built;
    for (final line in f.readAsLinesSync()) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      if (parts[0] == 'engine' && rev == null) rev = parts[1];
      if (parts[0] == 'built' && parts[1] == 'at' && parts.length > 2) {
        built = parts[2];
      }
    }
    if (rev == null && built == null) return null;
    final short = rev == null ? '?' : rev.substring(0, 10);
    return built == null ? short : '$short $built';
  } catch (_) {
    // A receipt that cannot be read is a run without a stamp. It is not a
    // reason to lose the result.
    return null;
  }
}

/// True when the host has asked for an unattended run.
///
/// A '1' in the first byte, not merely the file existing, because the
/// receiver can `put` a file and cannot delete one -- a switch keyed on
/// existence is a switch that cannot be turned off remotely.
bool switchOn(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return false;
    final bytes = f.readAsBytesSync();
    return bytes.isNotEmpty && bytes.first == 0x31;
  } on FileSystemException {
    return false;
  }
}

/// Write via a .part file and a rename, the only atomic operation here.
///
/// A reader that catches a half-written result must not be able to parse it
/// as a short one.
void writeAtomic(String path, String text) {
  final tmp = File('$path.part');
  tmp.writeAsStringSync(text, flush: true);
  final target = File(path);
  if (target.existsSync()) target.deleteSync();
  tmp.renameSync(path);
}
