import 'dart:convert';
import 'dart:io';

import 'package:flutter_vita_cli/src/device.dart';
import 'package:flutter_vita_cli/src/paths.dart';
import 'package:flutter_vita_cli/src/discovery.dart';
import 'package:flutter_vita_cli/src/png.dart';
import 'package:flutter_vita_cli/src/precache.dart';

/// One entry point for building, installing and driving Flutter on a Vita.
///
/// Build orchestration stays as subprocesses, because it genuinely is cmake,
/// gen_snapshot and flutter. Everything that talks to the device lives here,
/// which is where the hardcoded addresses used to be.
const usage = '''
flutter-vita — build and run Flutter apps on a PlayStation Vita

  doctor                    check the toolchain and find a device
  version                   this tool's release, and what it builds against
  precache                  download the engine named in versions.json
  devices                   sweep the subnet for Vitas
  build <app>               app directory -> .vpk
  install <app|vpk>         build if needed, install, launch
  run <app>                 install, then follow the log
  logs                      dump the running app's log
  screenshot [file]         capture the panel, with its descriptor
  tap <x> <y>               inject a pointer event

Options
  --host IP                 skip discovery
  --subnet 192.168.1        sweep a different /24
  --name "App Name"         LiveArea name (build)
  --title-id FVTA00002      target slot (build)
  --debug                   the default: dev server, debug strip, bailout
  --release                 none of those; the build you ship
''';

// Dart drops what main returns; only exitCode reaches the shell.
Future<void> main(List<String> argv) async => exitCode = await _run(argv);

Future<int> _run(List<String> argv) async {
  final args = <String>[];
  final opts = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      final key = argv[i].substring(2);
      if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
        opts[key] = argv[++i];
      } else {
        opts[key] = 'true';
      }
    } else {
      args.add(argv[i]);
    }
  }

  if (opts.containsKey('version')) {
    return _version();
  }
  if (args.isEmpty || opts.containsKey('help')) {
    stdout.write(usage);
    return args.isEmpty ? 2 : 0;
  }

  try {
    switch (args.first) {
      case 'version':
        return _version();
      case 'doctor':
        return await _doctor(opts);
      case 'precache':
        return await precache(
            force: opts['force'] == 'true', host: '${_hostOs()}-${_arch()}');
      case 'devices':
        return await _devices(opts);
      case 'build':
        return await _build(args, opts) == null ? 1 : 0;
      case 'install':
        return await _install(args, opts, follow: false);
      case 'run':
        return await _install(args, opts, follow: true);
      case 'logs':
        return await _logs(opts);
      case 'screenshot':
        return await _screenshot(args, opts);
      case 'tap':
        return await _tap(args, opts);
      default:
        stderr.writeln('unknown command: ${args.first}\n');
        stdout.write(usage);
        return 2;
    }
  } on MissingDependency catch (e) {
    // Printed as written: it carries the paths tried and the fix, which is the
    // whole point of the type. A stack trace here would bury both.
    stderr.writeln(e);
    return 1;
  } on VitaException catch (e) {
    stderr.writeln('!! $e');
    return 1;
  }
}

/// Every failure this pipeline has, checked up front.
///
/// Each of these has cost real time by surfacing as something else: a missing
/// patched SDK as a frontend_server crash, a wrong-host gen_snapshot as an
/// exec format error, a missing engine artifact as a cmake error about a path
/// nobody recognises.
Future<int> _doctor(Map<String, String> opts) async {
  var ok = true;
  void check(String label, bool passed, [String? hint]) {
    stdout.writeln('${passed ? "  ok  " : "  --  "} $label');
    if (!passed && hint != null) stdout.writeln('       $hint');
    ok = ok && passed;
  }

  final vitasdk = Platform.environment['VITASDK'];
  check('VITASDK', vitasdk != null && Directory(vitasdk).existsSync(),
      'export VITASDK=\$HOME/vitasdk — see docs/dev-environment.md');

  final engine = _engineDir();
  check(
      'engine artifact',
      File('$engine/lib/libflutter_engine_vita.a').existsSync(),
      'run: flutter-vita precache  (or build one: tools/package-engine.sh)');

  // The embedder is a submodule, and a plain clone leaves it empty; the
  // build's own error for that is a CMake message three steps in.
  final root = devRoot;
  if (root != null) {
    check(
        'embedder submodule',
        File('$root/embedder/CMakeLists.txt').existsSync(),
        'embedder is empty: git submodule update --init');
  }

  final host = '${_hostOs()}-${_arch()}';
  check(
      'gen_snapshot for $host',
      File('$engine/host-$host/gen_snapshot_armv7').existsSync(),
      'the artifact was built on another host; build one here');

  final flutter = _flutterDir();
  check('flutter sdk', Directory(flutter).existsSync(),
      'looked in $flutter; run tools/flutter-sdk.sh, or set FLUTTER_ROOT');
  check(
      'flutter_patched_sdk_product',
      Directory(
              '$flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk_product')
          .existsSync(),
      'run: $flutter/bin/flutter precache');

  // build-vita-app.sh refuses a mismatch, so this is not the enforcement point
  // -- it is the one that reports it before a build rather than during one.
  final engineRev = _manifestValue(engine, 'framework_rev');
  final sdkRev = _sdkRevision(flutter);
  if (engineRev == null) {
    stdout.writeln('  --   engine/sdk lockstep');
    stdout.writeln(
        '       artifact predates framework_rev; repackage to make it checkable');
  } else {
    check('engine/sdk lockstep', engineRev == sdkRev);
    if (engineRev != sdkRev) {
      stdout.writeln('       artifact: $engineRev');
      stdout.writeln('       your sdk: ${sdkRev ?? "unknown"}');
      stdout.writeln(
          '       dart:ui and the engine are one source tree cut in half.');
    }
  }

  final device = await _findDevice(opts, quiet: true);
  check('device', device != null,
      'power on the Vita and open the bridge, or pass --host');
  if (device != null) {
    stdout.writeln('       $device');
  } else if (await _localNetworkBlocked()) {
    // Worth separating from "no device", because it looks identical and is
    // not the same problem at all.
    stdout.writeln();
    stdout.writeln('  !!   macOS is blocking local network access for dart');
    stdout.writeln(
        '       Connections to other hosts on the LAN fail instantly with');
    stdout.writeln(
        '       "No route to host" while the internet works. That is the');
    stdout.writeln('       Local Network privacy control, granted per binary.');
    stdout.writeln();
    stdout.writeln(
        '       System Settings > Privacy & Security > Local Network,');
    stdout.writeln('       and enable the terminal you are running from.');
    stdout.writeln();
    stdout.writeln(
        '       The shell tools work meanwhile: they use nc, which is');
    stdout.writeln(
        '       already permitted. tools/install-vpk.sh, tools/deploy.sh');
    ok = false;
  }

  return ok ? 0 : 1;
}

Future<int> _devices(Map<String, String> opts) async {
  stdout.writeln(
      'sweeping${opts['subnet'] != null ? " ${opts['subnet']}.0/24" : ""}…');
  final found = await discover(subnet: opts['subnet']);
  if (found.isEmpty) {
    stdout.writeln('no devices found');
    stdout.writeln(
        '  the Vita must be awake with the bridge or an app running');
    return 1;
  }
  for (final device in found) {
    stdout.writeln('  $device');
  }
  return 0;
}

Future<String?> _build(List<String> args, Map<String, String> opts) async {
  if (args.length < 2) {
    stderr.writeln('usage: flutter-vita build <app-dir>');
    return null;
  }
  final app = args[1];

  // Already a .vpk: nothing to build.
  if (app.endsWith('.vpk')) return app;

  // The first build on a fresh checkout: fetch the engine rather than fail
  // three steps in with a cmake message about a path nobody recognises.
  if (!File('${_engineDir()}/lib/libflutter_engine_vita.a').existsSync()) {
    stdout.writeln('==> no engine artifact yet; fetching it');
    if (await precache(host: '${_hostOs()}-${_arch()}') != 0) return null;
  }

  final cmd = [
    requireScript('build-vita-app.sh'),
    app,
    if (opts['name'] != null) ...['--name', opts['name']!],
    if (opts['title-id'] != null) ...['--title-id', opts['title-id']!],
    if (opts['release'] == 'true') '--release',
    if (opts['debug'] == 'true') '--debug',
  ];
  final result = await Process.start(cmd.first, cmd.skip(1).toList(),
      environment: scriptEnvironment(), mode: ProcessStartMode.inheritStdio);
  if (await result.exitCode != 0) return null;

  final out = Directory('$app/build/vita');
  final vpk = out
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.vpk'))
      .toList();
  if (vpk.isEmpty) {
    stderr.writeln('!! build reported success but produced no .vpk');
    return null;
  }
  return vpk.first.path;
}

Future<int> _install(
  List<String> args,
  Map<String, String> opts, {
  required bool follow,
}) async {
  final vpk = await _build(args, opts);
  if (vpk == null) return 1;

  // The bridge is what installs, so hand off if the app is what is running.
  var device = await _findDevice(opts);
  if (device == null) return 1;
  if (device.role == VitaRole.app) {
    stdout.writeln('==> handing off to the bridge');
    await device.handoff();
    final bridge = await VitaDevice.waitFor(device.host, VitaRole.bridge);
    if (bridge == null) {
      stderr.writeln('!! the bridge never came up — tap it on the device');
      return 1;
    }
    device = bridge;
  }

  final result = await Process.start(
    requireScript('install-vpk.sh'),
    [
      vpk,
      '--host',
      device.host,
      if (opts['title-id'] != null) ...['--title-id', opts['title-id']!]
    ],
    environment: scriptEnvironment(),
    mode: ProcessStartMode.inheritStdio,
  );
  if (await result.exitCode != 0) return 1;

  final app = await VitaDevice.waitFor(device.host, VitaRole.app);
  if (app == null) {
    stderr.writeln('!! the app never opened its port — it may have crashed');
    stderr.writeln('   open the bridge and run: flutter-vita logs');
    return 1;
  }
  stdout.writeln('==> running on ${app.host}');

  if (follow) {
    stdout.writeln('--- log ---');
    stdout.write(await app.log());
  }
  return 0;
}

Future<int> _logs(Map<String, String> opts) async {
  final device = await _findDevice(opts, role: VitaRole.app);
  if (device == null) return 1;
  stdout.write(await device.log());
  return 0;
}

Future<int> _screenshot(List<String> args, Map<String, String> opts) async {
  final device = await _findDevice(opts, role: VitaRole.app);
  if (device == null) return 1;

  // The descriptor first, and printed whether or not the capture works. It is
  // what says the pixels are on the panel rather than merely in memory we own.
  stdout.write('  ${await device.shotInfo()}');

  final path = args.length > 1 ? args[1] : 'vita-screen.png';
  final png = encodePng(await device.screenshot());
  File(path).writeAsBytesSync(png);
  stdout.writeln('  $path  ${png.length} B');
  return 0;
}

Future<int> _tap(List<String> args, Map<String, String> opts) async {
  if (args.length < 3) {
    stderr.writeln('usage: flutter-vita tap <x> <y>');
    return 2;
  }
  final device = await _findDevice(opts, role: VitaRole.app);
  if (device == null) return 1;
  stdout.write(await device.tap(int.parse(args[1]), int.parse(args[2])));
  return 0;
}

/// The tool's release (versions.json), the git description when this is a
/// checkout with commits after the tag, and the pins it builds against.
int _version() {
  final v = loadVersions();
  if (v == null) {
    stderr.writeln('no versions.json: not a checkout, and nothing in the '
        'flutter-vita home');
    return 1;
  }
  final release = v['release'] as String? ?? 'unreleased';
  var described = '';
  final root = devRoot;
  if (root != null) {
    try {
      final r = Process.runSync(
          'git', ['describe', '--tags', '--always', '--dirty'],
          workingDirectory: root);
      final out = (r.stdout as String).trim();
      if (r.exitCode == 0 && out.isNotEmpty && out != release) {
        described = ' ($out)';
      }
    } on ProcessException {
      // No git: the release string is all there is.
    }
  }
  final engine = v['engine'] as Map<String, dynamic>? ?? const {};
  final embedder = v['embedder'] as Map<String, dynamic>? ?? const {};
  stdout.writeln('flutter-vita $release$described');
  final engineRelease = engine['release'] as String? ?? '';
  stdout.writeln('  flutter ${v['flutter']}'
      '  engine ${engineRelease.isEmpty ? 'unreleased' : engineRelease}'
      '  embedder ${embedder['release']}');
  return 0;
}

/// Locate a device: an explicit --host, else the console's mDNS name, else a
/// sweep of the subnet (an app built before the name existed still answers).
///
/// [role] narrows it when the command only makes sense against one — `logs`
/// needs the app, and finding the bridge instead should say so rather than
/// failing on a refused connection.
Future<VitaDevice?> _findDevice(
  Map<String, String> opts, {
  VitaRole? role,
  bool quiet = false,
}) async {
  final host = opts['host'] ?? Platform.environment['VITA_HOST'];
  if (host != null) {
    for (final candidate in role != null ? [role] : VitaRole.values) {
      final device = await VitaDevice.probe(host, candidate,
          timeout: const Duration(seconds: 4));
      if (device != null) return device;
    }
    if (!quiet) stderr.writeln('!! nothing answering on $host');
    return null;
  }

  for (final candidate in role != null ? [role] : VitaRole.values) {
    final device = await VitaDevice.probe(kVitaHostName, candidate,
        timeout: const Duration(seconds: 3));
    if (device != null) return device;
  }

  final found = await discover(subnet: opts['subnet']);
  final match = role == null
      ? (found.isEmpty ? null : found.first)
      : found.where((d) => d.role == role).firstOrNull;

  if (match == null && !quiet) {
    if (found.isEmpty) {
      stderr.writeln('!! no Vita found — is it awake, with the bridge open?');
    } else {
      stderr
          .writeln('!! found ${found.first} but this needs the ${role!.label}');
      stderr.writeln(role == VitaRole.app
          ? '   launch the app first'
          : '   hand off to the bridge first');
    }
  }
  return match;
}

/// Distinguish "nothing on the network" from "macOS will not let us look".
///
/// The symptom is specific enough to test for: reaching a public address
/// succeeds while any other host on the LAN fails in about a millisecond,
/// with no round trip. A device that is merely absent takes the full connect
/// timeout instead.
Future<bool> _localNetworkBlocked() async {
  if (!Platform.isMacOS) return false;

  Future<bool> reachable(String host, int port) async {
    try {
      final socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      socket.destroy();
      return true;
    } on Exception {
      return false;
    }
  }

  // A public host proves the process has networking at all. Without this an
  // offline machine would be told to change a privacy setting.
  if (!await reachable('1.1.1.1', 80)) return false;

  final subnet = await localSubnet();
  if (subnet == null) return false;

  // The router is the one LAN host almost certain to exist and answer.
  return !await reachable('$subnet.1', 80) &&
      !await reachable('$subnet.1', 443);
}

String _engineDir() => engineDir();

String _flutterDir() => flutterDir();

/// A key from the engine artifact's `MANIFEST.txt`, or null.
String? _manifestValue(String engineDir, String key) {
  final manifest = File('$engineDir/MANIFEST.txt');
  if (!manifest.existsSync()) return null;
  for (final line in manifest.readAsLinesSync()) {
    if (line.startsWith('$key ')) {
      final value = line.substring(key.length).trim();
      if (value.isNotEmpty) return value;
    }
  }
  return null;
}

/// The developer's Flutter SDK revision, read the same way package-engine.sh
/// reads the one it records — same file, same key, so the comparison is
/// between like and like rather than between two different notions of version.
String? _sdkRevision(String flutterDir) {
  final file = File('$flutterDir/bin/cache/flutter.version.json');
  if (!file.existsSync()) return null;
  try {
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return json['frameworkRevision'] as String?;
  } on Object {
    return null;
  }
}

/// Matches `uname -s | tr '[:upper:]' '[:lower:]'`, which is what
/// package-engine.sh and build-vita-app.sh use to name the host bundle. Dart
/// says "macos" where uname says "darwin", and disagreeing here reports a
/// perfectly good gen_snapshot as missing.
String _hostOs() => Platform.isMacOS ? 'darwin' : Platform.operatingSystem;

String _arch() {
  final v = Platform.version;
  return v.contains('arm64') ? 'arm64' : 'x64';
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
