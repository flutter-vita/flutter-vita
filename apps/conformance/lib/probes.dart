import 'dart:async';
import 'dart:io';

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

enum Outcome { pending, pass, fail }

class ProbeResult {
  ProbeResult(this.probe) : outcome = Outcome.pending, detail = '';
  final Probe probe;
  Outcome outcome;
  String detail;
}

/// Where per-app writable data goes. `app0:` is the read-only install
/// directory; anything the app writes has to live under `ux0:data/`.
const _dataDir = 'ux0:data/flutter-vita';

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
  Probe('io', 'print to log', () async {
    print('flutter-vita conformance: print reached stdout');
    stderr.writeln('flutter-vita conformance: write reached stderr');
    return 'emitted, check m3.log';
  }),
];
