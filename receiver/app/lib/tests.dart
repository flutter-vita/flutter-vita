// The benchmark TESTS tab. One place to start a suite and one place to read what it
// said, in the only process on this console that is always up.
//
// Every suite lives inside the app it measures, because a benchmark that does
// not run in the real binary measures something else. That makes them fragile:
// a suite that wedges takes its app down, and the app is usually the only
// thing on the console answering a socket.
//
// The receiver survives that. It starts a run by launching the app and getting
// out of the way, the same as the APPS tab. Nothing runs inside the receiver.
//
// Nothing here may throw. Every file this reads is written by something else,
// some of it while a process was dying, and a receiver that crashes on a
// truncated JSON file is worse than no TESTS tab. Every read is guarded and every
// parse falls back to "unknown".

import 'dart:convert';
import 'dart:io';

import 'device.dart';

/// Where suites write their results, one file per app per suite.
///
/// A single shared filename was fine while gallery was the only suite. It
/// stops being fine the moment two apps write one, which is the point of this
/// tab.
const benchDir = '$dataDir/bench';

/// What gallery has always written. Read as well as the directory above, so the
/// the TESTS tab is useful before any app has been changed.
const legacyResultPath = '$dataDir/bench-result.json';

/// The list of suites, on the memory card rather than compiled in here.
///
/// Adding a benchmark must not mean rebuilding the receiver. Reflashing it is the
/// riskiest routine operation in this project -- there is a pin-and-promote
/// flow around it precisely because a bad receiver strands the console -- and
/// "we added a scene" is not worth paying that.
const manifestPath = '$dataDir/benchmarks.txt';

/// A suite the TESTS tab can start.
class BenchEntry {
  const BenchEntry({
    required this.titleId,
    required this.suite,
    required this.switchPath,
    required this.label,
  });

  final String titleId;
  final String suite;

  /// The file the app watches to know the host wants an unattended run. Written
  /// with a '1' before the launch.
  final String switchPath;

  final String label;

  /// Whether the app is actually installed. A RUN button on a title that is not
  /// there hands the console to nothing: sceAppMgrLaunchAppByUri fails quietly
  /// and the receiver has already exited, so you land on the LiveArea home
  /// screen. That stranded this console twice on 2026-08-31.
  bool get present => Directory('ux0:app/$titleId').existsSync();
}

/// The default manifest, used when the card has none.
///
/// Gallery is the only real suite today. Conformance reports pass and fail
/// rather than timings, and localsend's throughput bench lives in host tooling,
/// so neither has a row yet. Being honest about that is better than listing
/// three entries when there is one.
const _builtIn = <BenchEntry>[
  BenchEntry(
    titleId: 'FVTA00002',
    suite: 'gallery',
    switchPath: '$dataDir/bench.on',
    label: 'gallery scenes — transitions, motion, routes',
  ),
];

/// Read the manifest, falling back to [_builtIn].
///
/// Format is one entry per line, pipe-separated, `#` for comments:
///
///     FVTA00002|gallery|ux0:data/flutter-vita/bench.on|gallery scenes
List<BenchEntry> readManifest() {
  try {
    final f = File(manifestPath);
    if (!f.existsSync()) return _builtIn;
    final out = <BenchEntry>[];
    for (final raw in f.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split('|');
      if (parts.length < 3) continue;
      out.add(
        BenchEntry(
          titleId: parts[0].trim(),
          suite: parts[1].trim(),
          switchPath: parts[2].trim(),
          label: parts.length > 3 ? parts[3].trim() : parts[1].trim(),
        ),
      );
    }
    return out.isEmpty ? _builtIn : out;
  } on FileSystemException {
    return _builtIn;
  }
}

/// The headline of one result file.
class BenchResult {
  BenchResult({
    required this.source,
    required this.suite,
    required this.scenes,
    required this.stalled,
    required this.worstMs,
    required this.renderer,
    required this.engine,
    required this.when,
  });

  final String source;
  final String suite;
  final int scenes;
  final int stalled;
  final double worstMs;
  final String renderer;

  /// The engine that produced it, or null when the file does not say.
  ///
  /// Decides whether two rows may be read against each other. Numbers from
  /// different engine builds shown side by side are how a confident wrong answer
  /// gets made, so rows without a stamp are marked rather than quietly compared.
  final String? engine;

  final DateTime? when;

  bool get comparable => engine != null;
}

/// Every result on the card, newest first. Never throws.
List<BenchResult> readResults() {
  final out = <BenchResult>[];
  _read(File(legacyResultPath), out);
  try {
    final dir = Directory(benchDir);
    if (dir.existsSync()) {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File && e.path.endsWith('.json')) _read(e, out);
      }
    }
  } on FileSystemException {
    // A directory that cannot be listed contributes nothing, which is the
    // correct amount.
  }
  out.sort((a, b) {
    final x = b.when, y = a.when;
    if (x == null && y == null) return a.source.compareTo(b.source);
    if (x == null) return -1;
    if (y == null) return 1;
    return x.compareTo(y);
  });
  return _dedupe(out);
}

/// Drop the legacy copy of a run that is also under bench/.
///
/// Suites write both: bench-result.json for the host tools and
/// bench/<title>-<suite>.json for this tab. Listing both showed one run twice,
/// which across a sweep of thirty-four scenes would make the panel unreadable.
/// Same suite and same `taken` is the same run; the bench/ copy wins because
/// it is the one that survives a second suite being added.
List<BenchResult> _dedupe(List<BenchResult> rows) {
  final seen = <String>{};
  final out = <BenchResult>[];
  for (final r in rows.where((r) => r.source != 'bench-result.json')) {
    seen.add('${r.suite}|${r.when?.toIso8601String()}');
    out.add(r);
  }
  for (final r in rows.where((r) => r.source == 'bench-result.json')) {
    if (seen.add('${r.suite}|${r.when?.toIso8601String()}')) out.add(r);
  }
  out.sort((a, b) {
    final x = b.when, y = a.when;
    if (x == null && y == null) return a.source.compareTo(b.source);
    if (x == null) return -1;
    if (y == null) return 1;
    return x.compareTo(y);
  });
  return out;
}

void _read(File f, List<BenchResult> out) {
  try {
    if (!f.existsSync()) return;
    final text = f.readAsStringSync();
    if (text.trim().isEmpty) return;
    final doc = jsonDecode(text);
    if (doc is! Map) return;
    final scenes = doc['scenes'];
    var count = 0;
    var stalled = 0;
    var worst = 0.0;
    if (scenes is List) {
      for (final s in scenes) {
        if (s is! Map) continue;
        count++;
        final st = s['stall_ms'];
        if (st is num && st > 0) stalled++;
        final w = s['worst_ms'];
        if (w is num && w > worst) worst = w.toDouble();
      }
    }
    DateTime? when;
    final ts = doc['taken'];
    if (ts is String) when = DateTime.tryParse(ts);
    when ??= _modified(f);

    final sw = doc['software_on_requested'];
    out.add(
      BenchResult(
        source: f.path.split('/').last,
        suite: doc['suite'] is String ? doc['suite'] as String : 'gallery',
        scenes: count,
        stalled: stalled,
        worstMs: worst,
        renderer: sw is bool ? (sw ? 'software' : 'gpu') : 'unknown',
        engine: doc['engine'] is String ? doc['engine'] as String : null,
        when: when,
      ),
    );
  } catch (_) {
    // Truncated, half-written, or not JSON at all. A result that cannot be read
    // is not a result, and it is certainly not a reason to take the receiver
    // down.
  }
}

DateTime? _modified(File f) {
  try {
    return f.lastModifiedSync();
  } on FileSystemException {
    return null;
  }
}

/// Arm a suite and hand the console to it.
///
/// Returns false without launching when the title is not installed, because
/// launching a title that is not there strands the console on the home screen
/// with the receiver already gone.
bool startRun(BenchEntry entry) {
  if (!entry.present) return false;
  try {
    File(entry.switchPath).writeAsStringSync('1', flush: true);
    // Tells the suite the TESTS tab is waiting for it, so it hands the console back
    // when it finishes. A host-started run writes the same bench.on and must
    // not hand back, which is why this is a separate file rather than a flag.
    File('$dataDir/bench.from-receiver').writeAsStringSync('1', flush: true);
    // Cleared so a marker left by the previous run cannot be mistaken for this
    // one finishing. Same reason tools/bench.sh clears it.
    File('$dataDir/bench-done').writeAsStringSync('0', flush: true);
    // Always written, even empty: the receiver can put a file and cannot delete
    // one, so a subset left from a host-driven run would silently restrict this
    // one.
    File('$dataDir/bench.only').writeAsStringSync('', flush: true);
  } on FileSystemException {
    return false;
  }
  requestLaunch(entry.titleId);
  return true;
}
