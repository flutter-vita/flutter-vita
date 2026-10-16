// The engine artifact, fetched from the fork's release.
//
// Building the engine costs a 12 GB checkout and half an hour; the fork
// (flutter-vita/flutter) publishes the result as a tarball on each release.
// versions.json at the repository root names the release, its URL and its
// sha256, and this downloads it, checks it and unpacks it where engineDir()
// looks: out/artifacts/ in a checkout, ~/.flutter-vita/engines/ otherwise.
//
// No package for the hash or the tar: shasum and tar are on every macOS and
// Linux the toolchain itself supports, and the CLI stays dependency-free.
import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// versions.json as a map, from the checkout or the flutter-vita home.
Map<String, dynamic>? loadVersions() {
  final root = devRoot;
  for (final c in <String>[
    if (root != null) '$root/versions.json',
    '$flutterVitaHome/versions.json',
  ]) {
    final file = File(c);
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  return null;
}

/// The `engine` block of versions.json.
class EngineRelease {
  EngineRelease(
      this.release, this.url, this.sha256, this.unpacksTo, this.hosts);
  final String release;
  final String url;
  final String sha256;
  final String unpacksTo;
  final List<String> hosts;

  static EngineRelease load() {
    final root = devRoot;
    final candidates = <String>[
      if (root != null) '$root/versions.json',
      '$flutterVitaHome/versions.json',
    ];
    for (final c in candidates) {
      final file = File(c);
      if (!file.existsSync()) continue;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final engine = json['engine'] as Map<String, dynamic>;
      return EngineRelease(
        engine['release'] as String,
        engine['url'] as String,
        engine['sha256'] as String,
        engine['unpacksTo'] as String? ??
            engine['unpacks_to'] as String? ??
            'flutter-engine-vita-${json['flutter']}',
        (engine['hosts'] as List<dynamic>? ?? const []).cast<String>(),
      );
    }
    throw MissingDependency('versions.json', candidates,
        'It names the engine release. Run from a source checkout.');
  }
}

/// Where the artifact goes: beside a git checkout's other outputs, else in the
/// user's flutter-vita home.
String artifactsDir() =>
    isCheckout ? '$devRoot/out/artifacts' : '$flutterVitaHome/engines';

/// Download, verify and unpack the engine named by versions.json.
///
/// Returns 0 on success, and prints progress as it goes: a 25 MB download
/// over a slow link is long enough to look stuck. `force` re-fetches an
/// artifact that is already there.
Future<int> precache({bool force = false, String? host}) async {
  final release = EngineRelease.load();
  final dir = artifactsDir();
  final target = Directory('$dir/${release.unpacksTo}');
  final manifest = File('${target.path}/MANIFEST.txt');

  if (manifest.existsSync() && !force) {
    final line = manifest
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('release '), orElse: () => '');
    final have =
        line.isEmpty ? 'an unreleased build' : line.split(RegExp(r'\s+')).last;
    stdout.writeln('  engine ${release.unpacksTo} is already there ($have)');
    stdout.writeln('  ${target.path}');
    if (release.release.isNotEmpty &&
        have != release.release &&
        have != 'an unreleased build') {
      stdout.writeln('  versions.json names ${release.release}; '
          'run  flutter-vita precache --force  to replace it');
    }
    return 0;
  }

  // Between a Flutter upgrade and its first release, master pins a Flutter
  // that no published engine matches.
  if (release.url.isEmpty) {
    stderr.writeln('!! No engine release for Flutter ${flutterPin()} yet.');
    stderr.writeln('   Build the engine and package it (docs/engine.md):');
    stderr.writeln('   tools/package-engine.sh puts it in ${target.path}');
    return 1;
  }

  if (host != null &&
      release.hosts.isNotEmpty &&
      !release.hosts.contains(host)) {
    stdout
        .writeln('  note: release ${release.release} carries gen_snapshot for '
            '${release.hosts.join(", ")}, not $host.');
    stdout
        .writeln('  The engine links all the same; gen_snapshot for this host '
            'needs an engine build (docs/dev-environment.md).');
  }

  Directory(dir).createSync(recursive: true);
  final tarball = File('$dir/${release.url.split('/').last}');
  final part = File('${tarball.path}.part');

  stdout.writeln('==> engine ${release.release}');
  stdout.writeln('    ${release.url}');
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(release.url));
    final response = await request.close();
    if (response.statusCode != 200) {
      stderr.writeln('!! HTTP ${response.statusCode} for ${release.url}');
      return 1;
    }
    final total = response.contentLength;
    var received = 0;
    var lastTick = -1;
    final sink = part.openWrite();
    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      final tick = total > 0 ? (received * 10 ~/ total) : received ~/ (5 << 20);
      if (tick != lastTick) {
        lastTick = tick;
        final mb = (received / (1 << 20)).toStringAsFixed(1);
        stdout.writeln(total > 0
            ? '    $mb MB  ${received * 100 ~/ total}%'
            : '    $mb MB');
      }
    }
    await sink.close();
  } finally {
    client.close();
  }

  stdout.writeln('==> sha256');
  final sum = await Process.run('shasum', ['-a', '256', part.path]);
  final got = (sum.stdout as String).split(' ').first.trim();
  if (got != release.sha256) {
    stderr.writeln('!! sha256 mismatch');
    stderr.writeln('   versions.json  ${release.sha256}');
    stderr.writeln('   downloaded     $got');
    stderr.writeln('   Kept as ${part.path} for inspection; nothing unpacked.');
    return 1;
  }
  part.renameSync(tarball.path);
  stdout.writeln('    ok');

  stdout.writeln('==> unpacking to $dir');
  if (target.existsSync()) target.deleteSync(recursive: true);
  final tar = await Process.run('tar', ['-xzf', tarball.path, '-C', dir]);
  if (tar.exitCode != 0) {
    stderr.writeln('!! tar failed: ${tar.stderr}');
    return 1;
  }
  if (!manifest.existsSync()) {
    stderr.writeln(
        '!! the tarball did not contain ${release.unpacksTo}/MANIFEST.txt');
    return 1;
  }
  tarball.deleteSync();
  for (final line in manifest.readAsLinesSync().skip(2).take(6)) {
    stdout.writeln('    $line');
  }
  stdout.writeln('==> ${target.path}');
  return 0;
}
