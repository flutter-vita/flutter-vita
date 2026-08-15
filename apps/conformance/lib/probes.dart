import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One thing we want to know about this port, and what happened when we asked.
class Probe {
  Probe(this.group, this.name, this.run);

  final String group;
  final String name;

  /// Returns a short human-readable detail on success. Throwing is a failure;
  /// returning is a pass. A probe that wants to report "correctly refused"
  /// catches its own expected exception and returns.
  final Future<String> Function() run;
}

/// `skipped` is a resumed run's memory of the previous ones: the probe ran in
/// an earlier attempt that the crash ended, and is not being run again.
enum Outcome { pending, pass, fail, skipped }

class ProbeResult {
  ProbeResult(this.probe) : outcome = Outcome.pending, detail = '';
  final Probe probe;
  Outcome outcome;
  String detail;
}

/// Where per-app writable data goes. `app0:` is the read-only install
/// directory; anything the app writes has to live under `ux0:data/`.
const _dataDir = 'ux0:data/flutter-vita';


/// Append a progress line to the run journal from inside a probe.
///
/// The journal normally records one line per probe, which is too coarse for a
/// probe whose whole purpose is to find out *how many* of something can exist
/// before the process dies. Same file, same synchronous flush, for the same
/// reason: it has to survive the crash it is measuring.
void _mark(String s) {
  try {
    File('ux0:data/flutter-vita/conformance.txt')
        .writeAsStringSync('     $s\n', mode: FileMode.append, flush: true);
  } on Object {
    // Best effort, exactly like the journal it writes to.
  }
}

/// Ordered safest-first, deliberately.
///
/// A native crash takes the whole app down and loses every result, since the
/// screen is the reporting channel. Ordering by risk turns that failure into
/// information: whatever is on screen passed, and the first thing missing is
/// the one that killed it.
List<Probe> buildProbes() => [
  // -- pure Dart, no platform surface at all. If these fail, nothing else
  //    that follows means anything.
  Probe('dart', 'async/Future', () async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return 'ok';
  }),
  Probe('dart', 'Timer', () async {
    final c = Completer<void>();
    Timer(const Duration(milliseconds: 1), c.complete);
    await c.future;
    return 'ok';
  }),
  Probe('dart', 'DateTime.now', () async => DateTime.now().toIso8601String().substring(0, 19)),

  // -- How many timers can exist before the process dies?
  //
  // Every run so far has died at probe 32 regardless of what probe 32 is, and
  // the per-probe constant is two timers: a .timeout() around the probe and a
  // Future.delayed() after it. That puts the wall near the 64th timer, which is
  // round enough to be worth measuring rather than reasoning about.
  //
  // Two shapes, because they fail differently. Sequential answers "is anything
  // leaked per timer created"; concurrent answers "is there a fixed-size table
  // of live timers". A leak dies at a total count no matter the overlap; a
  // table only dies when enough are alive at once.
  Probe('limits', 'sequential timers', () async {
    for (var i = 1; i <= 400; i++) {
      final c = Completer<void>();
      Timer(Duration.zero, c.complete);
      await c.future;
      if (i % 8 == 0) _mark('sequential timers: $i');
    }
    return '400 created one at a time';
  }),
  Probe('limits', 'concurrent timers', () async {
    for (final n in [16, 32, 48, 64, 96, 128, 192]) {
      _mark('concurrent timers: trying $n');
      await Future.wait([
        for (var i = 0; i < n; i++)
          Future<void>.delayed(const Duration(milliseconds: 30)),
      ]);
    }
    return '192 alive at once';
  }),

  // -- Platform. Cheap, read-only, and it tells us what the runtime believes
  //    about itself. ADR-0008 says operatingSystem should read "linux".
  Probe('platform', 'operatingSystem', () async => Platform.operatingSystem),
  Probe('platform', 'version', () async => Platform.version.split(' ').first),
  Probe('platform', 'numberOfProcessors', () async => '${Platform.numberOfProcessors}'),
  Probe('platform', 'pathSeparator', () async => '"${Platform.pathSeparator}"'),
  Probe('platform', 'localHostname', () async => Platform.localHostname),
  Probe('platform', 'environment', () async => '${Platform.environment.length} vars'),
  Probe('platform', 'resolvedExecutable', () async => Platform.resolvedExecutable),
  Probe('platform', 'script', () async => Platform.script.toString()),

  // -- Filesystem, read side first. app0: is where the .vpk was installed, so
  //    something is definitely there to find.
  Probe('fs', 'Directory.current', () async => Directory.current.path),
  Probe('fs', 'app0 exists', () async =>
      Directory('app0:').existsSync() ? 'yes' : throw 'existsSync false'),
  Probe('fs', 'app0 list', () async {
    final entries = Directory('app0:').listSync();
    return '${entries.length} entries';
  }),
  Probe('fs', 'read app0 file', () async {
    // icudtl.dat is shipped by the template and is always present.
    final f = File('app0:/icudtl.dat');
    final len = await f.length();
    final head = await f.openRead(0, 4).first;
    return '$len B, starts ${head.length}B';
  }),
  Probe('fs', 'stat app0 file', () async {
    final s = await File('app0:/icudtl.dat').stat();
    return '${s.type}, ${s.size} B';
  }),

  // -- Filesystem, write side. This is what path_provider and
  //    shared_preferences need, and the top plugin blocker by measurement.
  Probe('fs', 'mkdir ux0:data', () async {
    final d = Directory(_dataDir);
    if (!d.existsSync()) await d.create(recursive: true);
    return d.existsSync() ? 'exists' : throw 'create returned but absent';
  }),
  Probe('fs', 'write file', () async {
    final f = File('$_dataDir/probe.txt');
    await f.writeAsString('written at ${DateTime.now()}');
    return '${await f.length()} B';
  }),
  Probe('fs', 'read back', () async {
    final s = await File('$_dataDir/probe.txt').readAsString();
    return s.length > 24 ? '${s.substring(0, 24)}…' : s;
  }),
  Probe('fs', 'append', () async {
    final f = File('$_dataDir/probe.txt');
    await f.writeAsString('more\n', mode: FileMode.append);
    return '${await f.length()} B';
  }),
  Probe('fs', 'list ux0:data', () async =>
      '${Directory(_dataDir).listSync().length} entries'),
  Probe('fs', 'rename', () async {
    final f = File('$_dataDir/probe.txt');
    final r = await f.rename('$_dataDir/probe2.txt');
    return r.existsSync() ? 'ok' : throw 'renamed but absent';
  }),
  Probe('fs', 'delete', () async {
    await File('$_dataDir/probe2.txt').delete();
    return File('$_dataDir/probe2.txt').existsSync() ? throw 'still there' : 'ok';
  }),
  Probe('fs', 'systemTemp', () async => Directory.systemTemp.path),
  Probe('fs', 'createTempSync', () async {
    final d = Directory.systemTemp.createTempSync('probe');
    final path = d.path;
    try {
      d.deleteSync(recursive: true);
    } on Object {
      // Reporting the path matters more than cleaning it up.
    }
    return path;
  }),

  // -- Network. eventhandler_vita.cc sits on sceNetEpoll and has never run.
  Probe('net', 'ServerSocket.bind', () async {
    final s = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final port = s.port;
    await s.close();
    return 'port $port';
  }),
  Probe('net', 'DNS lookup', () async {
    final r = await InternetAddress.lookup('example.com')
        .timeout(const Duration(seconds: 10));
    return r.isEmpty ? throw 'empty' : r.first.address;
  }),
  Probe('net', 'TCP connect (no DNS)', () async {
    // Raw TCP to a literal address, so a failure here is sockets rather than
    // name resolution.
    final s = await Socket.connect('1.1.1.1', 80,
        timeout: const Duration(seconds: 10));
    final peer = '${s.remoteAddress.address}:${s.remotePort}';
    s.destroy();
    return peer;
  }),
  Probe('net', 'HTTP GET', () async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final req = await c.getUrl(Uri.parse('http://example.com/'));
    final res = await req.close().timeout(const Duration(seconds: 15));
    await res.drain<void>();
    c.close();
    return 'HTTP ${res.statusCode}';
  }),
  // -- The two blessed plugins. Not a test of the packages so much as of the
  //    claim in ADR-0009 that they are shallow: if the filesystem works, these
  //    should be constants and a mkdir, and anything else here is a surprise.
  Probe('plugin', 'path_provider docs', () async {
    final d = await getApplicationDocumentsDirectory();
    return d.path;
  }),
  Probe('plugin', 'path_provider temp', () async {
    final d = await getTemporaryDirectory();
    return d.path;
  }),
  Probe('plugin', 'path_provider support', () async {
    final d = await getApplicationSupportDirectory();
    return d.path;
  }),
  Probe('plugin', 'prefs write+read', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('probe', 'hello');
    await prefs.setInt('count', 42);
    await prefs.setStringList('list', ['a', 'b']);
    final s = prefs.getString('probe');
    final n = prefs.getInt('count');
    final l = prefs.getStringList('list');
    if (s != 'hello' || n != 42 || l?.length != 2) {
      throw 'round trip mismatch: $s $n $l';
    }
    return 'string+int+list ok';
  }),
  // Proves the JSON file is real rather than an in-memory map that would
  // evaporate on restart -- the failure mode a naive implementation has.
  Probe('plugin', 'prefs persisted', () async {
    final support = await getApplicationSupportDirectory();
    final f = File('${support.path}/shared_preferences.json');
    if (!f.existsSync()) throw 'no store file at ${f.path}';
    return '${await f.length()} B on disk';
  }),

  // -- Deliberately unsupported. A clean throw is the pass condition; a crash
  //    or a hang is the failure. process_vita.cc says it refuses on purpose.
  Probe('process', 'Process.run refuses', () async {
    try {
      await Process.run('ls', const []);
      return throw 'unexpectedly succeeded';
    } on ProcessException catch (e) {
      return 'ProcessException: ${e.message}';
    } on UnsupportedError {
      return 'UnsupportedError';
    }
  }),

  // -- Does print() reach the log file? Cannot be answered from inside the
  //    app; it is checked afterwards by reading m3.log. Recorded here so the
  //    marker is in the log at a known point in the sequence.
  // Three separate channels that all get called "printing", reported
  // separately because they fail separately.
  //
  // The combined version threw on the first one that broke and said nothing
  // about the rest, so "print is broken" was recorded for a run in which
  // `print` itself was very likely fine -- it is `dart:io`'s stderr that
  // raises, and merely *constructing* it is enough.
  Probe('io', 'print to log', () async {
    final results = <String>[];
    for (final (name, emit) in <(String, void Function())>[
      ('print', () => print('flutter-vita: print')),
      ('stdout', () => stdout.writeln('flutter-vita: stdout')),
      ('stderr', () => stderr.writeln('flutter-vita: stderr')),
    ]) {
      try {
        emit();
        results.add('$name ok');
      } on Object catch (e) {
        results.add('$name ${e.runtimeType}');
      }
    }
    return results.join(', ');
  }),

  // -- TLS last, because it is parked and it kills the process.
  //
  // Phase 7 eliminated entropy, certificate verification, stack, memory and
  // assembly by measurement and still crashes here. Until that is understood,
  // anything ordered after these probes simply never runs -- which is exactly
  // what happened to the two plugin probes above on their first outing.
  // TLS is split into four, smallest first, because the single combined probe
  // took the whole process down and a hard fault names nothing. Each of these
  // is a different suspect, and the journal records which one was running:
  //
  //   1. does BoringSSL initialise at all
  //   2. does parsing ~240 KB of compiled-in PEM into an X509 store survive
  //   3. does a handshake survive
  //   4. does the HTTP layer on top of it survive
  //
  // Splitting it costs one app rebuild and replaces a guess about stack sizes
  // with an answer.
  Probe('tls', 'empty SecurityContext', () async {
    final ctx = SecurityContext(withTrustedRoots: false);
    return ctx.runtimeType.toString();
  }),
  Probe('tls', 'built-in roots', () async {
    // Triggers TrustBuiltinRoots -> AddCompiledInCerts -> PEM parse of the
    // whole Mozilla bundle. The heaviest allocation in the TLS path, and the
    // part that is newly present in this build.
    final ctx = SecurityContext(withTrustedRoots: true);
    return ctx.runtimeType.toString();
  }),
  // Splits the handshake from the chain verification that follows it.
  //
  // An empty context with onBadCertificate accepting everything still does the
  // full key exchange and cipher negotiation, but skips building and walking
  // the trust chain -- which is the recursive, allocation-heavy half. If this
  // passes and the verifying one below dies, the problem is verification, not
  // TLS; if both die, it is the handshake itself.
  //
  // Not a configuration anything should ship: it accepts any certificate, so
  // it proves reachability, never security.
  Probe('tls', 'handshake, no verify', () async {
    final s = await SecureSocket.connect(
      'example.com',
      443,
      context: SecurityContext(withTrustedRoots: false),
      onBadCertificate: (_) => true,
      timeout: const Duration(seconds: 20),
    );
    final proto = s.selectedProtocol ?? 'connected';
    s.destroy();
    return proto;
  }),
  Probe('tls', 'SecureSocket handshake', () async {
    final s = await SecureSocket.connect('example.com', 443,
        timeout: const Duration(seconds: 20));
    final proto = s.selectedProtocol ?? 'negotiated';
    final peer = s.peerCertificate?.subject ?? 'no cert';
    s.destroy();
    return '$proto, $peer';
  }),
  Probe('tls', 'HTTPS GET', () async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final req = await c.getUrl(Uri.parse('https://example.com/'));
    final res = await req.close().timeout(const Duration(seconds: 20));
    await res.drain<void>();
    c.close();
    return 'HTTPS ${res.statusCode}';
  }),
];
