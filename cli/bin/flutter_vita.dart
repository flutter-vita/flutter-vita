import 'dart:convert';
import 'dart:io';

import 'package:flutter_vita_cli/src/device.dart';
import 'package:flutter_vita_cli/src/paths.dart';
import 'package:flutter_vita_cli/src/discovery.dart';
import 'package:flutter_vita_cli/src/doctor.dart';
import 'package:flutter_vita_cli/src/png.dart';
import 'package:flutter_vita_cli/src/precache.dart';

/// One entry point for building, installing and driving Flutter on a Vita.
///
/// Build orchestration stays as subprocesses, because it genuinely is cmake,
/// gen_snapshot and flutter. Everything that talks to the device lives here,
/// which is where the hardcoded addresses used to be.
const usage = '''
flutter-vita — build and run Flutter apps on a PlayStation Vita

  doctor [-v]               check the toolchain and the console; -v for details
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

  if (args.isEmpty || opts.containsKey('help')) {
    stdout.write(usage);
    return args.isEmpty ? 2 : 0;
  }

  try {
    switch (args.first) {
      case 'doctor':
        return await _doctor(args, opts);
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

/// Every failure this pipeline has, checked up front, in the shape of
/// `flutter doctor`: a line per part of the toolchain, what was found of it,
/// and the fix for what was not. `-v` shows what was found of the parts that
/// are fine, too.
///
/// Each of these has cost real time by surfacing as something else: a missing
/// patched SDK as a frontend_server crash, a wrong-host gen_snapshot as an
/// exec format error, a missing engine artifact as a cmake error about a path
/// nobody recognises.
Future<int> _doctor(List<String> args, Map<String, String> opts) async {
  final verbose = args.contains('-v') || opts.containsKey('verbose');
  final root = devRoot;
  final versions = _versions(root);
  final host = '${_hostOs()}-${_arch()}';

  // The tool itself: which release, where, and the embedder that every app
  // build compiles. A plain clone leaves the embedder empty, and the build's
  // own error for that is a CMake message three steps in.
  final tool = Category('flutter-vita');
  final release = versions['release'] as String? ?? 'unreleased';
  if (root == null) {
    tool.fail('The tool\'s own files are not found.',
        'Install it again: brew reinstall --cask flutter-vita');
  } else {
    tool.summary = (isCheckout ? await _describe(root) : null) ?? release;
    tool.info(isCheckout
        ? 'Git checkout at $root'
        : root.contains('/Caskroom/')
            ? 'Installed with Homebrew at $root'
            : 'Installed at $root');
    if (File('$root/embedder/CMakeLists.txt').existsSync()) {
      // A checkout's submodule can be past the last release.
      final embedder = (isCheckout ? await _describe('$root/embedder') : null) ??
          (versions['embedder'] as Map?)?['release'] ??
          '';
      tool.info('Embedder $embedder at $root/embedder');
    } else {
      tool.fail('The embedder folder is empty.',
          'Run: git -C $root submodule update --init');
    }
  }

  // VITASDK, or the VitaSDK that tools/vitasdk.sh finds. On the first run it
  // installs the release in versions.json, as the launcher does with Flutter.
  final sdk = Category('VitaSDK');
  final vitasdk = await _vitasdk();
  final vitasdkEnv = Platform.environment['VITASDK'];
  if (vitasdk == null) {
    sdk.fail(
        'No VitaSDK that works.',
        vitasdkEnv != null && vitasdkEnv.isNotEmpty
            ? 'VITASDK=$vitasdkEnv has no compiler. Unset VITASDK, and the tool finds or installs VitaSDK.'
            : 'Check the network, and run flutter-vita doctor again.\n'
                'Or install VitaSDK from https://vitasdk.org, and set VITASDK to its folder.');
  } else {
    final gcc =
        await _firstLine('$vitasdk/bin/arm-vita-eabi-gcc', ['--version']);
    if (gcc == null) {
      sdk.fail('$vitasdk/bin/arm-vita-eabi-gcc does not run on this computer.',
          'Unset VITASDK, and the tool installs the VitaSDK for this computer.');
    } else {
      sdk.summary = 'arm-vita-eabi-gcc ${gcc.split(' ').last}';
    }
    final pinned = (versions['vitasdk'] as Map?)?['release'];
    sdk.info(vitasdkEnv != null && vitasdkEnv.isNotEmpty
        ? 'At $vitasdk, from VITASDK'
        : vitasdk.startsWith('$flutterVitaHome/vitasdk/')
            ? 'At $vitasdk, installed by flutter-vita ($pinned)'
            : 'At $vitasdk');
    final info = File('$vitasdk/version_info.txt');
    if (info.existsSync()) {
      final built = info.readAsLinesSync().firstOrNull;
      if (built != null && built.isNotEmpty) sdk.info(built);
    }
  }

  // The Flutter the tool builds with: its own copy, or FLUTTER_ROOT.
  final flutter = _flutterDir();
  final fl = Category('Flutter');
  final fv = _flutterVersion(flutter);
  if (fv == null) {
    fl.fail('No Flutter SDK at $flutter.',
        'Run: ${root ?? '<flutter-vita>'}/tools/flutter-sdk.sh\nOr set FLUTTER_ROOT to a Flutter ${flutterPin()}.');
  } else {
    fl.summary = '${fv['frameworkVersion']}';
    fl.info(flutter.startsWith('$flutterVitaHome/flutter/')
        ? 'At $flutter, downloaded by flutter-vita'
        : 'At $flutter, from FLUTTER_ROOT');
    fl.info(
        'The tool\'s own copy. Your own Flutter is not used and not changed.');
    final rev = fv['frameworkRevision'] as String? ?? '';
    fl.info(
        'Framework revision ${rev.length > 10 ? rev.substring(0, 10) : rev}, '
        'Dart ${fv['dartSdkVersion'] ?? 'unknown'}');
    if (!Directory(
            '$flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk_product')
        .existsSync()) {
      fl.fail('flutter_patched_sdk_product is missing.',
          'Run: $flutter/bin/flutter precache');
    }
  }

  // The prebuilt engine, and gen_snapshot for this computer.
  final engine = _engineDir();
  final en = Category('Flutter engine for PS Vita');
  if (!File('$engine/lib/libflutter_engine_vita.a').existsSync()) {
    en.fail('No engine at $engine.',
        'Run: flutter-vita precache\nThe first flutter-vita build does it, too.');
  } else {
    final engineFlutter = _manifestValue(engine, 'flutter');
    en.summary = [
      _manifestValue(engine, 'release') ?? 'unreleased',
      if (engineFlutter != null) 'for Flutter $engineFlutter',
    ].join(', ');
    en.info('At $engine');
    final built = _manifestValue(engine, 'built at');
    if (built != null) en.info('Built at $built');
    if (File('$engine/host-$host/gen_snapshot_armv7').existsSync()) {
      en.info('gen_snapshot for $host');
    } else {
      final hosts = Directory(engine)
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .where((n) => n.startsWith('host-'))
          .map((n) => n.substring(5));
      en.fail(
          'No gen_snapshot for $host. This engine has it for: '
              '${hosts.isEmpty ? 'no host' : hosts.join(', ')}.',
          'Build the engine on this computer: docs/dev-environment.md');
    }

    // build-vita-app.sh refuses a mismatch, so this is not the enforcement
    // point -- it is the one that reports it before a build, not during one.
    final engineRev = _manifestValue(engine, 'framework_rev');
    final sdkRev = fv?['frameworkRevision'] as String?;
    if (engineRev == null) {
      en.warn('The engine does not say which Flutter it is for.',
          'Run: flutter-vita precache --force');
    } else if (sdkRev != null && engineRev != sdkRev) {
      en.fail(
          'The engine is for framework ${engineRev.substring(0, 10)}, '
              'the Flutter above is ${sdkRev.substring(0, 10)}.',
          'dart:ui and the engine are one source tree cut in half.\n'
              'Unset FLUTTER_ROOT, or set it to Flutter ${engineFlutter ?? ''}.');
    } else if (sdkRev != null) {
      en.info('Matches the Flutter above');
    }
  }

  // CMake links each app. The Homebrew cask installs it.
  final cm = Category('CMake');
  final cmake = await _firstLine('cmake', ['--version']);
  if (cmake == null) {
    cm.fail(
        'CMake is not on PATH.',
        Platform.isMacOS
            ? 'Run: brew install cmake'
            : 'Install it, for example: sudo apt install cmake');
  } else {
    final v = cmake.split(' ').last;
    cm.summary = v;
    final which = await _firstLine('which', ['cmake']);
    if (which != null) cm.info('At $which');
    final parts = v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    if (parts[0] < 3 || (parts[0] == 3 && parts.length > 1 && parts[1] < 16)) {
      cm.fail(
          'CMake $v is too old. The template needs 3.16 or later.',
          Platform.isMacOS
              ? 'Run: brew upgrade cmake'
              : 'Install a newer CMake.');
    }
  }

  // The console: by name only (or --host), so a console that sleeps costs
  // seconds, not the minute that a sweep of the subnet takes.
  final vita = Category('PS Vita');
  final where =
      opts['host'] ?? Platform.environment['VITA_HOST'] ?? kVitaHostName;
  if (stderr.hasTerminal) stderr.write('Looking for the console at $where…');
  VitaDevice? device;
  InternetAddress? address;
  try {
    address = await VitaDevice.resolve(where);
    for (final role in VitaRole.values) {
      device = await VitaDevice.probe(address.address, role,
          timeout: const Duration(seconds: 3));
      if (device != null) break;
    }
  } on Exception {
    // A name that does not resolve: nothing announces it.
  }
  if (stderr.hasTerminal) stderr.write('\r\x1B[K');
  if (device == null) {
    if (await _localNetworkBlocked()) {
      // Worth separating from "no device", because it looks identical and is
      // not the same problem at all.
      vita.warn(
          'macOS blocks local network access for this terminal.',
          'System Settings > Privacy & Security > Local Network: turn it on for the terminal.\n'
              'Connections to the LAN fail at once with "No route to host", while the internet works.');
    } else {
      vita.warn(
          'No console answers at $where.',
          'Power on the Vita and open Flutter Bridge, or pass --host <address>.\n'
              'flutter-vita devices looks for it on the whole local network.\n'
              'flutter-vita build works without the console.');
    }
  } else {
    // The address goes on a line of its own: in the summary it would put
    // brackets inside the brackets of the category line.
    final named = where != address!.address;
    if (device.role == VitaRole.bridge) {
      vita.summary = 'Flutter Bridge at $where';
      if (named) vita.info('$where is ${address.address}');
      vita.info(
          'The bridge answers on port ${VitaRole.bridge.port}: install and launch work.');
      // The shader compiler is the user's to install, and every app on the GPU
      // path needs it. Only the bridge can look; an app on screen cannot.
      try {
        final reply = await VitaDevice(address.address, VitaRole.bridge)
            .ask('stat ur0:data/libshacccg.suprx');
        if (reply.startsWith('ERR')) {
          vita.warn(
              'ur0:data/libshacccg.suprx is not on the console.',
              'An app on the GPU path shows a black screen without it.\n'
                  'See docs/configure-console.md, "The shader compiler".');
        } else {
          vita.info('The shader compiler is there: ur0:data/libshacccg.suprx');
        }
      } on Exception {
        // No answer in time: say nothing rather than guess.
      }
    } else {
      vita.summary = 'an app at $where';
      if (named) vita.info('$where is ${address.address}');
      vita.info(
          'The app answers on port ${VitaRole.app.port}: logs, screenshot and tap work.');
      vita.info('install and run give the console back to the bridge first.');
    }
  }

  return report([tool, sdk, fl, en, cm, vita], verbose: verbose);
}

/// versions.json of the tool, or an empty map.
Map<String, dynamic> _versions(String? root) {
  if (root == null) return const {};
  try {
    return jsonDecode(File('$root/versions.json').readAsStringSync())
        as Map<String, dynamic>;
  } on Object {
    return const {};
  }
}

/// `git describe` of a checkout: the last release, and how far past it.
Future<String?> _describe(String root) async {
  try {
    final r = await Process.run(
        'git', ['-C', root, 'describe', '--tags', '--always', '--dirty']);
    final out = (r.stdout as String).trim();
    return r.exitCode == 0 && out.isNotEmpty ? out : null;
  } on ProcessException {
    return null;
  }
}

/// The first line a program prints, or null when it does not run.
Future<String?> _firstLine(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args);
    if (r.exitCode != 0) return null;
    return (r.stdout as String).split('\n').first.trim();
  } on ProcessException {
    return null;
  }
}

/// The SDK's own flutter.version.json, or null.
Map<String, dynamic>? _flutterVersion(String flutterDir) {
  final file = File('$flutterDir/bin/cache/flutter.version.json');
  if (!file.existsSync()) return null;
  try {
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } on Object {
    return null;
  }
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

/// VitaSDK's folder from tools/vitasdk.sh, which installs it when no VitaSDK
/// is found. Its progress goes straight to the terminal.
Future<String?> _vitasdk() async {
  final String script;
  try {
    script = requireScript('vitasdk.sh');
  } on MissingDependency {
    return null;
  }
  final p = await Process.start('bash', [script]);
  final done = p.stderr.listen(stderr.add).asFuture<void>();
  final out = (await p.stdout.transform(utf8.decoder).join()).trim();
  await done;
  return await p.exitCode == 0 && out.isNotEmpty ? out : null;
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
