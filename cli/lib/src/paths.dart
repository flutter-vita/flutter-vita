// Where the CLI finds the things it needs, when there is no repo.
//
// Deriving every path by walking up from Platform.script to a repo root works
// only from a source checkout. Installed through `pub global activate` the
// script lives in the pub cache, four parents up is somebody's home directory,
// and every lookup silently resolves to a path that does not exist.
//
// So: an explicit override wins, then a source checkout if we are in one, then
// the user's own flutter-vita home. Failing that, an error that says what to do
// rather than a path that is quietly wrong.
import 'dart:convert';
import 'dart:io';

/// Raised when something the CLI needs is genuinely not on this machine.
///
/// Carries remediation rather than just a path, because "no such file or
/// directory" for a path the user has never heard of is not an error message.
class MissingDependency implements Exception {
  MissingDependency(this.what, this.tried, this.fix);
  final String what;
  final List<String> tried;
  final String fix;

  @override
  String toString() => [
        '!! $what not found.',
        '',
        ...tried.map((t) => '   looked in  $t'),
        '',
        '   $fix',
      ].join('\n');
}

String? _env(String key) {
  final v = Platform.environment[key];
  return (v == null || v.isEmpty) ? null : v;
}

String get _home =>
    _env('HOME') ?? _env('USERPROFILE') ?? Directory.current.path;

/// Artifacts, templates and scripts the CLI has fetched for itself.
///
/// This is what an installed CLI owns. Nothing here is in the repo, and
/// nothing in the repo is required for it to work.
String get flutterVitaHome =>
    _env('FLUTTER_VITA_HOME') ?? '$_home/.flutter-vita';

/// The repo root when running from a source checkout, else null.
///
/// Detected by marker rather than by a fixed number of `..`, so moving the CLI
/// between folders does not silently break it -- which is the failure this
/// whole file exists to prevent, and it would be poor to reintroduce it here.
late final String? devRoot = () {
  final explicit = _env('FLUTTER_VITA_ROOT');
  if (explicit != null) return Directory(explicit).existsSync() ? explicit : null;

  var dir = File.fromUri(Platform.script).parent;
  for (var i = 0; i < 8; i++) {
    final marker = File('${dir.path}/tools/build-vita-app.sh');
    if (marker.existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}();

/// The Flutter SDK the developer is building with.
String flutterDir() =>
    _env('FLUTTER_ROOT') ?? '$_home/fvm/versions/${flutterPin()}';

/// The Flutter version to match an engine artifact against.
///
/// Read from the developer's SDK first, which is the only correct source for an
/// installed CLI: they build with the Flutter they have, and the artifact has to
/// match it. VERSIONS.md is a maintainer's file answering a different question.
late final String Function() flutterPin = () {
  String? cached;
  return () {
    if (cached != null) return cached!;

    final sdk = _env('FLUTTER_ROOT');
    if (sdk != null) {
      final v = _sdkVersion(sdk);
      if (v != null) return cached = v;
    }

    final root = devRoot;
    if (root != null) {
      final versions = File('$root/VERSIONS.md');
      if (versions.existsSync()) {
        final m = RegExp(r'3\.\d+\.\d+').firstMatch(versions.readAsStringSync());
        if (m != null) return cached = m.group(0)!;
      }
    }

    return cached = '3.44.8';
  };
}();

String? _sdkVersion(String flutterDir) {
  final file = File('$flutterDir/bin/cache/flutter.version.json');
  if (!file.existsSync()) return null;
  try {
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return json['frameworkVersion'] as String?;
  } on Object {
    return null;
  }
}

String get _artifactName => 'flutter-engine-vita-${flutterPin()}';

/// The unpacked engine artifact for the developer's Flutter revision.
String engineDir() {
  final override = _env('FLUTTER_VITA_ENGINE');
  if (override != null) return override;

  final candidates = <String>[
    if (devRoot != null) '$devRoot/out/artifacts/$_artifactName',
    '$flutterVitaHome/engines/$_artifactName',
  ];
  for (final c in candidates) {
    if (Directory(c).existsSync()) return c;
  }
  // The first candidate is returned unresolved so callers that only report on
  // it -- doctor -- can still name the path they expected.
  return candidates.first;
}

/// Same as [engineDir], but refuses rather than returning a hopeful path.
String requireEngineDir() {
  final dir = engineDir();
  if (Directory(dir).existsSync()) return dir;
  throw MissingDependency(
    'The Flutter Vita engine for ${flutterPin()}',
    [dir],
    'Run  flutter-vita doctor  for setup, or set FLUTTER_VITA_ENGINE\n'
        '   to an unpacked $_artifactName directory.',
  );
}

/// The CMake app template the build wraps around a Dart snapshot.
String requireTemplateDir() {
  final override = _env('FLUTTER_VITA_TEMPLATE');
  if (override != null) return override;

  final candidates = <String>[
    if (devRoot != null) '$devRoot/templates/vita-app',
    '$flutterVitaHome/templates/vita-app',
  ];
  for (final c in candidates) {
    if (Directory(c).existsSync()) return c;
  }
  throw MissingDependency(
    'The Vita app template',
    candidates,
    'Set FLUTTER_VITA_TEMPLATE, or run from a source checkout.',
  );
}

/// A helper script the CLI shells out to.
///
/// These are still bash. ADR-0015 defers porting them into this CLI until
/// after the first release, so until then any command that needs one requires
/// a checkout -- and says so plainly instead of failing on a missing file.
String requireScript(String name) {
  final candidates = <String>[
    if (devRoot != null) '$devRoot/tools/$name',
    '$flutterVitaHome/tools/$name',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  throw MissingDependency(
    'The helper script $name',
    candidates,
    'This command still needs a flutter-vita source checkout.\n'
        '   Set FLUTTER_VITA_ROOT to one. See ADR-0015.',
  );
}

/// Environment passed to the bash helpers so they stop deriving these
/// themselves. Every one has a $ROOT-derived fallback on the bash side, so a
/// checkout keeps working exactly as before.
Map<String, String> scriptEnvironment() => {
      'FLUTTER_VITA_ENGINE': engineDir(),
      'FLUTTER_VITA_TEMPLATE':
          _env('FLUTTER_VITA_TEMPLATE') ?? '${devRoot ?? flutterVitaHome}/templates/vita-app',
      'FLUTTER_VITA_PIN': flutterPin(),
    };
