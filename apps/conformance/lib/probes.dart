import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One thing we want to know about this port, and what happened when we asked.
class Probe {
  Probe(this.group, this.name, this.run, {this.timeout = const Duration(seconds: 25)});

  final String group;
  final String name;

  /// How long the harness gives this probe before calling it hung.
  ///
  /// 25 seconds suits a probe that either answers at once or is broken. It is
  /// the wrong ceiling for one that is deliberately moving megabytes, where a
  /// timeout reports "slower than 25 seconds" and hides the number that is the
  /// entire point of running it.
  final Duration timeout;

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

/// The machine running tools/benchserver.py. See the throughput probes.
const _benchHost = '192.168.0.30';

/// Bytes and elapsed time as a rate, in the one format every throughput probe
/// reports so the numbers can be read down the column.
String _rate(int bytes, Stopwatch sw) {
  final ms = sw.elapsedMilliseconds;
  final kbs = ms == 0 ? 0 : (bytes / 1024) * 1000 / ms;
  return '$bytes B in $ms ms = ${kbs.toStringAsFixed(0)} KB/s';
}

/// Reads a URL to the end and reports what arrived and how long it took.
///
/// The self-signed bench certificate is accepted for this host only. That is
/// the whole point of the probe -- it measures BoringSSL's throughput, not the
/// trust store -- and narrowing it to the bench host keeps the exception from
/// applying to anything else the app does.
Future<(int, Stopwatch)> _drain(String url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..badCertificateCallback = (cert, host, port) => host == _benchHost;
  final sw = Stopwatch()..start();
  final response = await (await client.getUrl(Uri.parse(url))).close();
  int bytes = 0;
  await for (final chunk in response) {
    bytes += chunk.length;
  }
  sw.stop();
  client.close();
  return (bytes, sw);
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
  Probe('net', 'NetworkInterface.list', () async {
    // Prints the address *count* next to the addresses themselves, which is
    // not redundant: a list holding one empty string renders identically to an
    // empty list, and that is exactly how this bug hid. localsend logged
    // `ip: []` for an interface whose single address had been stringified by a
    // getnameinfo call that failed, and the report read as "no addresses" for
    // long enough to send me after the wrong cause.
    final ifs = await NetworkInterface.list();
    if (ifs.isEmpty) return throw 'no interfaces';
    return ifs
        .map((i) =>
            '${i.name}#${i.index} ${i.addresses.length} addr [${i.addresses.map((a) => a.address).join(',')}]')
        .join(' ');
  }),
  Probe('net', 'NetworkInterface.list (loopback+linklocal)', () async {
    // The same call with both filters off. If this one has addresses and the
    // plain one does not, the address is being filtered rather than missing.
    final ifs = await NetworkInterface.list(
        includeLoopback: true, includeLinkLocal: true);
    if (ifs.isEmpty) return throw 'no interfaces';
    return ifs
        .map((i) =>
            '${i.name} ${i.addresses.length} addr [${i.addresses.map((a) => a.address).join(',')}]')
        .join(' ');
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
  // -- IOService round-trip latency.
  //
  // Every TLS filter cycle is an `_IOService._dispatch(sslProcessFilter, ...)`:
  // a message to the IO service's native port, handled off the isolate, and
  // awaited back. 1 MB of HTTPS is roughly 128 of those, and it takes 7.9 s,
  // which puts about 62 ms on each one. Plain HTTP does not use IOService at
  // all, which is why it runs 9x faster over the same socket.
  //
  // So the question is no longer about TLS. It is how long one IOService round
  // trip costs on this port. Any async dart:io filesystem call is the same
  // mechanism with none of the crypto, so it can be timed on its own -- and the
  // sync sibling next to it does the identical work on the calling thread,
  // which separates the round trip from the syscall underneath it.
  Probe('async', 'File.lengthSync x200', () async {
    final file = File('$_dataDir/rtt.bin')..writeAsBytesSync(const [1, 2, 3]);
    final sw = Stopwatch()..start();
    for (int i = 0; i < 200; i++) {
      file.lengthSync();
    }
    sw.stop();
    file.deleteSync();
    return '${sw.elapsedMilliseconds} ms total, '
        '${(sw.elapsedMicroseconds / 200).toStringAsFixed(0)} us each';
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'File.length x200 (IOService)', () async {
    final file = File('$_dataDir/rtt.bin')..writeAsBytesSync(const [1, 2, 3]);
    final sw = Stopwatch()..start();
    for (int i = 0; i < 200; i++) {
      await file.length();
    }
    sw.stop();
    file.deleteSync();
    return '${sw.elapsedMilliseconds} ms total, '
        '${(sw.elapsedMicroseconds / 200).toStringAsFixed(0)} us each';
  }, timeout: const Duration(seconds: 120)),

  Probe('async', 'File.length x200 concurrent', () async {
    // The same 200 dispatches with all of them in flight at once.
    //
    // This is the discriminator the sequential pair cannot give. If the 5.8 ms
    // is latency -- a wait, with everything idle through it -- then overlapping
    // them collapses the total to roughly one round trip. If it is work, the
    // total stays put and something is burning 5.8 ms of CPU per dispatch.
    //
    // It matters because it decides what a fix would even look like. TLS is
    // sequential by construction: the record layer cannot start the next cycle
    // until this one is decrypted, so it can never overlap its way out of a
    // latency problem, and pipelining is not available to it.
    final file = File('$_dataDir/rtt.bin')..writeAsBytesSync(const [1, 2, 3]);
    final sw = Stopwatch()..start();
    await Future.wait<int>(<Future<int>>[
      for (int i = 0; i < 200; i++) file.length(),
    ]);
    sw.stop();
    file.deleteSync();
    return '${sw.elapsedMilliseconds} ms total, '
        '${(sw.elapsedMicroseconds / 200).toStringAsFixed(0)} us each';
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200', () async {
    // A timer is the other way a native thread wakes this isolate: the event
    // handler posts to the isolate's port, exactly as the IO service does, but
    // without the VM thread pool in between. If this is fast and the IOService
    // pair is slow, the cost is the pool rather than the wake.
    final sw = Stopwatch()..start();
    for (int i = 0; i < 200; i++) {
      final completer = Completer<void>();
      Timer(Duration.zero, completer.complete);
      await completer.future;
    }
    sw.stop();
    return '${sw.elapsedMilliseconds} ms total, '
        '${(sw.elapsedMicroseconds / 200).toStringAsFixed(0)} us each';
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200 with a socket open', () async {
    // The same timers, with one socket open.
    //
    // 517 us each with no socket and 3731 us with one. Seven times worse, on a
    // port where a networked app holds a socket for its whole life, and it is
    // what limits TLS now that the filter yields once per cycle.
    //
    // What it is *not*, both checked: the event handler's poll wait, and the
    // event handler at all. dart:isolate posts _ZERO_EVENT to the isolate's own
    // port for a zero-duration timer rather than asking the platform -- see the
    // note on getEventHandlerSendData in sdk/lib/vita/vita.dart -- so no part of
    // eventhandler_vita.cc is on this path. Instrumenting its timer queue
    // produced no output at all, and moving kInterruptSliceUs from 8 ms to 1
    // moved the number to 3691.
    //
    // So this measures delivering a port message to the root isolate, and it
    // agrees with the other measurement of the same thing: Dart_PostCObject
    // timed 3234 us inside IOServiceCallback, also with a socket open. Why a
    // registered socket triples the cost of waking this isolate is unfound.
    // Note that a socket is also the first thing that starts the event handler
    // thread, so "socket open" and "that thread running" are not yet
    // distinguished.
    final socket = await Socket.connect(_benchHost, 5302,
        timeout: const Duration(seconds: 10));
    try {
      final sw = Stopwatch()..start();
      for (int i = 0; i < 200; i++) {
        final completer = Completer<void>();
        Timer(Duration.zero, completer.complete);
        await completer.future;
      }
      sw.stop();
      return '${sw.elapsedMilliseconds} ms total, '
          '${(sw.elapsedMicroseconds / 200).toStringAsFixed(0)} us each';
    } finally {
      socket.destroy();
    }
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'microtask x200', () async {
    // Pure in-isolate baseline. Whatever this costs is not the platform's fault.
    final sw = Stopwatch()..start();
    for (int i = 0; i < 200; i++) {
      await Future<void>.microtask(() {});
    }
    sw.stop();
    return '${sw.elapsedMilliseconds} ms total, '
        '${(sw.elapsedMicroseconds / 200).toStringAsFixed(0)} us each';
  }, timeout: const Duration(seconds: 120)),

  // -- Throughput, layer by layer.
  //
  // localsend receives a 5 MB file over HTTPS in 62 seconds: 84 KB/s, against
  // 852 KB/s pushing the same file over the same Wi-Fi to the same memory card
  // from C. Every explanation offered for that gap so far has been a guess that
  // did not survive being built, so these probes move the same bytes through
  // one more layer each and let the cost land in whichever gap opens up.
  //
  // The first run answered most of it: plain HTTP reads 5 MB at 2377 KB/s and
  // writes it to the card at 544 KB/s, so sockets, the HTTP parser and the
  // filesystem are all fine. HTTPS did not finish inside the old 25-second
  // ceiling. These probes are the follow-up, and they split TLS in two:
  //
  //   handshake   asymmetric crypto and certificate parsing, paid once
  //   1MB vs 4MB  if both take the same time it is the handshake; if the time
  //               scales with the bytes it is the record layer
  //
  // The bench server is benchserver.py on a machine on the same network.
  Probe('throughput', 'raw TCP 4MB', () async {
    // Counts to the expected length rather than waiting for the stream to end.
    // The first version awaited the close and hung: the peer does close, and
    // this port did not deliver the event. That is worth its own probe and is
    // not what this one is measuring.
    final sw = Stopwatch()..start();
    final socket = await Socket.connect(_benchHost, 5301,
        timeout: const Duration(seconds: 10));
    int bytes = 0;
    await for (final chunk in socket) {
      bytes += chunk.length;
      if (bytes >= 4 * 1024 * 1024) break;
    }
    sw.stop();
    socket.destroy();
    return _rate(bytes, sw);
  }, timeout: const Duration(seconds: 180)),
  Probe('throughput', 'TLS handshake x3', () async {
    // No payload at all, so this is the asymmetric half on its own. Three
    // handshakes because the first also builds the certificate store.
    final times = <int>[];
    for (int i = 0; i < 3; i++) {
      final sw = Stopwatch()..start();
      final socket = await SecureSocket.connect(_benchHost, 5303,
          onBadCertificate: (_) => true,
          timeout: const Duration(seconds: 30));
      sw.stop();
      times.add(sw.elapsedMilliseconds);
      socket.destroy();
    }
    return '${times.join(" / ")} ms';
  }, timeout: const Duration(seconds: 180)),
  Probe('throughput', 'HTTP 1MB', () async {
    final (bytes, sw) = await _drain('http://$_benchHost:5302/blob/1048576');
    return _rate(bytes, sw);
  }, timeout: const Duration(seconds: 180)),
  Probe('throughput', 'HTTPS 1MB', () async {
    final (bytes, sw) = await _drain('https://$_benchHost:5303/blob/1048576');
    return _rate(bytes, sw);
  }, timeout: const Duration(seconds: 180)),
  Probe('throughput', 'HTTPS 4MB', () async {
    final (bytes, sw) = await _drain('https://$_benchHost:5303/blob/4194304');
    return _rate(bytes, sw);
  }, timeout: const Duration(seconds: 300)),
  Probe('throughput', 'file write 4MB', () async {
    final chunk = Uint8List(64 * 1024);
    final file = File('$_dataDir/bench.bin');
    final sw = Stopwatch()..start();
    final sink = file.openWrite();
    for (int i = 0; i < 64; i++) {
      sink.add(chunk);
    }
    await sink.close();
    sw.stop();
    final bytes = file.lengthSync();
    file.deleteSync();
    return _rate(bytes, sw);
  }, timeout: const Duration(seconds: 180)),
  Probe('throughput', 'HTTP 4MB to file', () async {
    final file = File('$_dataDir/bench.bin');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final sw = Stopwatch()..start();
    final response = await (await client
            .getUrl(Uri.parse('http://$_benchHost:5302/blob/4194304')))
        .close();
    final sink = file.openWrite();
    await response.forEach(sink.add);
    await sink.close();
    sw.stop();
    client.close();
    final bytes = file.lengthSync();
    file.deleteSync();
    return _rate(bytes, sw);
  }, timeout: const Duration(seconds: 180)),

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
        // "accepted", not "ok". IOSink.writeln is buffered and asynchronous:
        // the call returning proves only that the sink was constructed and the
        // bytes queued. On 2026-08-15 all three reported ok here while the
        // engine log carried `writeFrom failed ... Bad file number` twice, as
        // an unhandled async exception nobody was watching. A synchronous probe
        // cannot see that, so it must not claim to.
        results.add('$name accepted');
      } on Object catch (e) {
        results.add('$name ${e.runtimeType}');
      }
    }
    return results.join(', ');
  }),

  // Phase 8, step one: does a platform channel reach the embedder at all?
  //
  // Deliberately not a TextField. A widget would drag in focus, layout and the
  // IME all at once, and a failure anywhere in that chain would look the same.
  // This sends a real message on the real channel with the real codec --
  // `flutter/textinput` is a JSONMethodCodec channel, so what lands in the
  // embedder is readable JSON -- and asks only whether the plumbing exists.
  //
  // Passing means the message left Dart and the engine accepted a reply. It
  // does **not** mean the embedder understood it: `flutter/textinput` is an
  // OptionalMethodChannel, so "not implemented" comes back as null rather than
  // as an error, which is what makes a partial implementation viable at all.
  // The evidence of what actually arrived is in m3.log.
  Probe('channel', 'textinput reaches embedder', () async {
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    return 'sent, see m3.log';
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

  // Last on purpose: it puts a modal dialog over the app for six seconds, and
  // anything after it would run behind a keyboard.
  //
  // What this can prove without a person: the IME initialises, the shell
  // composites it over a software-rendered framebuffer, and it tears down
  // cleanly. That middle one is the whole risk of Phase 8 --
  // sceCommonDialogUpdate wants a GXM colour surface and ADR-0003 says we do
  // not have one, only CDRAM we wrote pixels into. The evidence is a
  // screenshot taken from the host while this probe holds the dialog open, so
  // the six-second wait is the test window and not a delay.
  //
  // What it cannot prove is typing. That needs thumbs.
  Probe('ime', 'dialog opens', () async {
    const ch = SystemChannels.textInput;
    await ch.invokeMethod<void>('TextInput.setClient', <Object>[
      1,
      <String, Object?>{
        'inputType': <String, Object?>{'name': 'TextInputType.text'},
        'obscureText': false,
        'inputAction': 'TextInputAction.done',
      },
    ]);
    await ch.invokeMethod<void>('TextInput.setEditingState', <String, Object?>{
      'text': 'flutter-vita',
      'selectionBase': 12,
      'selectionExtent': 12,
    });
    await ch.invokeMethod<void>('TextInput.show');
    await Future<void>.delayed(const Duration(seconds: 6));
    await ch.invokeMethod<void>('TextInput.hide');
    await ch.invokeMethod<void>('TextInput.clearClient');
    return 'opened, held 6s, closed';
  }),
];
