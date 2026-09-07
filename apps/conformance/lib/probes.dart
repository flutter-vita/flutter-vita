import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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
  /// the wrong ceiling for one deliberately moving megabytes, where a timeout
  /// reports "slower than 25 seconds" and hides the number being measured.
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
/// One line per probe is too coarse for a probe whose purpose is to find out
/// how many of something can exist before the process dies. Same file, same
/// synchronous flush: it has to survive the crash it is measuring.
void _mark(String s) {
  try {
    File('ux0:data/flutter-vita/conformance.txt')
        .writeAsStringSync('     $s\n', mode: FileMode.append, flush: true);
  } on Object {
    // Best effort, exactly like the journal it writes to.
  }
}

/// The machine running tools/benchserver.py. See the throughput probes.
///
/// Read from the memory card rather than compiled in, because the host's lease
/// moves and a compiled-in address means a 15 MB rebuild to chase it. Fifteen
/// probes failed a whole run with `errno = 61`, ECONNREFUSED, because the bench
/// machine came back on .26 instead of .30 -- which reads like a broken socket
/// layer and is a DHCP lease.
///
/// The dev server writes it without a rebuild:
///
///   printf 'put 12 ux0:data/flutter-vita/bench.host\n192.168.0.26' \
///     | nc <vita> 1339
///
/// The constant stays as the fallback so a card with no file still runs.
final String _benchHost = _readBenchHost();

String _readBenchHost() {
  try {
    final file = File('ux0:data/flutter-vita/bench.host');
    if (file.existsSync()) {
      final text = file.readAsStringSync().trim();
      if (text.isNotEmpty) return text;
    }
  } on Object {
    // A missing or unreadable file is the normal case on a fresh card.
  }
  return '192.168.0.30';
}

/// Bytes and elapsed time as a rate, in the one format every throughput probe
/// reports so the numbers can be read down the column.
String _rate(int bytes, Stopwatch sw) {
  final ms = sw.elapsedMilliseconds;
  final kbs = ms == 0 ? 0 : (bytes / 1024) * 1000 / ms;
  return '$bytes B in $ms ms = ${kbs.toStringAsFixed(0)} KB/s';
}

/// Reads a URL to the end and reports what arrived and how long it took.
///
/// The self-signed bench certificate is accepted for this host only: the probe
/// measures BoringSSL's throughput, not the trust store, and narrowing it keeps
/// the exception off everything else the app does.
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

/// A distribution rather than a mean, because a mean hides the shape.
///
/// 3731 us per zero-duration timer could have been 200 timers each costing
/// 3.7 ms, or 196 costing 200 us and four stalling for most of a second. Those
/// are different bugs with different fixes. It turned out to be the first. The
/// count over 20 ms stays because this console has a known ~100-200 ms network
/// tick (t1-timers E, G and H), and four of those would smear a mean as far.
String _dist(List<int> us) {
  final sorted = List<int>.of(us)..sort();
  final sum = sorted.fold<int>(0, (a, b) => a + b);
  var slow = 0;
  for (final v in sorted) {
    if (v > 20000) slow++;
  }
  return 'mean ${(sum / sorted.length).round()} '
      'p50 ${sorted[sorted.length ~/ 2]} '
      'p90 ${sorted[(sorted.length * 9) ~/ 10]} '
      'max ${sorted.last} us, $slow over 20 ms';
}

/// One zero-duration timer at a time, timed individually.
Future<String> _timerDist(int n) async {
  final sw = Stopwatch()..start();
  final us = <int>[];
  for (var i = 0; i < n; i++) {
    final t0 = sw.elapsedMicroseconds;
    final completer = Completer<void>();
    Timer(Duration.zero, completer.complete);
    await completer.future;
    us.add(sw.elapsedMicroseconds - t0);
  }
  return _dist(us);
}

/// The in-isolate control for _timerDist: a microtask never reaches a port, a
/// thread or the platform, so whatever it costs is the isolate's own doing.
Future<String> _microtaskDist(int n) async {
  final sw = Stopwatch()..start();
  final us = <int>[];
  for (var i = 0; i < n; i++) {
    final t0 = sw.elapsedMicroseconds;
    await Future<void>.microtask(() {});
    us.add(sw.elapsedMicroseconds - t0);
  }
  return _dist(us);
}

/// The same shape as _timerDist for a timer that really does reach the
/// platform. A zero-duration timer never leaves the isolate; a 1 ms one is
/// registered with the event handler and delivered from its thread, so the two
/// together say whether a cost attaches to port round trips in general or to
/// the platform timer path in particular.
Future<String> _delayedDist(int n, [Duration d = const Duration(milliseconds: 1)]) async {
  final sw = Stopwatch()..start();
  final us = <int>[];
  for (var i = 0; i < n; i++) {
    final t0 = sw.elapsedMicroseconds;
    await Future<void>.delayed(d);
    us.add(sw.elapsedMicroseconds - t0);
  }
  return _dist(us);
}

/// A `Timer` at an arbitrary duration, with no Future.delayed around it.
///
/// Future.delayed allocates a Completer and a Future on top of the timer, and
/// nothing so far separates that allocation from the wait. This does: run it at
/// 1 ms beside _delayedDist and the difference is Future.delayed's own cost.
Future<String> _timerAtDist(int n, Duration d) async {
  final sw = Stopwatch()..start();
  final us = <int>[];
  for (var i = 0; i < n; i++) {
    final t0 = sw.elapsedMicroseconds;
    final completer = Completer<void>();
    Timer(d, completer.complete);
    await completer.future;
    us.add(sw.elapsedMicroseconds - t0);
  }
  return _dist(us);
}

/// A ladder of durations, reported as `asked -> measured` pairs.
///
/// The number that has resisted explanation since the POLLOUT fix is
/// Future.delayed(1 ms) at ~2,500 us against Timer(0) at ~210 us. A single
/// duration cannot say why; a ladder can, because the three candidates each
/// have a different shape:
///
///   a constant offset      thread wake plus message delivery
///   a floor                everything below some duration costs the same,
///                          which is a granularity
///   proportional error     the deadline arithmetic is wrong
///
/// eventhandler_vita.cc computes its wait as `CurrentTimeout() -
/// GetCurrentMonotonicMillis()`, both in milliseconds, so a timer armed
/// part-way through a millisecond rounds up by nearly one. That predicts a
/// constant offset of about 0.5 ms, and the ladder confirms or kills it.
Future<String> _delayLadder(int n, List<int> millis) async {
  final parts = <String>[];
  for (final ms in millis) {
    final sw = Stopwatch()..start();
    var total = 0;
    for (var i = 0; i < n; i++) {
      final t0 = sw.elapsedMicroseconds;
      await Future<void>.delayed(Duration(milliseconds: ms));
      total += sw.elapsedMicroseconds - t0;
    }
    parts.add('${ms}ms->${(total / n).round()}');
  }
  return parts.join(' ');
}

/// Ordered safest-first, deliberately.
///
/// A native crash takes the app down and loses every result, since the screen
/// is the reporting channel. Ordering by risk turns that into information:
/// whatever is on screen passed, and the first thing missing killed it.
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
  // the per-probe constant is two timers. That puts the wall near the 64th,
  // round enough to measure rather than reason about.
  //
  // Two shapes, because they fail differently. Sequential answers "is anything
  // leaked per timer created"; concurrent answers "is there a fixed-size table
  // of live timers".
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
    // Prints the address *count* next to the addresses, which is not
    // redundant: a list holding one empty string renders identically to an
    // empty list, and that is how this bug hid. localsend logged `ip: []` for
    // an interface whose single address had been stringified by a failed
    // getnameinfo call.
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
  // awaited back. 1 MB of HTTPS is roughly 128 of those and takes 7.9 s, about
  // 62 ms each. Plain HTTP does not use IOService at all, which is why it runs
  // 9x faster over the same socket.
  //
  // So the question is how long one IOService round trip costs here. Any async
  // dart:io filesystem call is the same mechanism without the crypto, and the
  // sync sibling does the identical work on the calling thread, which separates
  // the round trip from the syscall underneath it.
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
    // The discriminator the sequential pair cannot give. If the 5.8 ms is
    // latency, overlapping them collapses the total to roughly one round trip.
    // If it is work, the total stays put and something is burning 5.8 ms of CPU
    // per dispatch.
    //
    // It decides what a fix would look like. TLS is sequential by construction:
    // the record layer cannot start the next cycle until this one is decrypted,
    // so pipelining is not available to it.
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
  // -- Waking this isolate, and what a socket had to do with it.
  //
  // A zero-duration Dart timer used to cost the root isolate 215 us with
  // nothing open, 744 us with one TCP connection, and 43418 us with eight. That
  // was the ceiling on TLS and the source of the jank during a transfer.
  //
  // The cause was setListening in socket_patch.dart: it sent the event mask
  // once and always asked for both readEvent and writeEvent, whatever its
  // arguments said. Every other POSIX backend is edge-triggered, so an unwanted
  // POLLOUT fires once; this port polls, poll() is level-triggered, and an idle
  // connected socket is writable every time round. The event handler posted
  // 2255 write events per second per socket to the root isolate, each costing a
  // task on Flutter's UI thread. A spawned isolate, which drains its port queue
  // in one go, barely noticed, which is what pointed at the delivery path.
  //
  // These stay as the regression test. Each is the same 200 timers with one
  // thing different, and the interesting property is that they are now all the
  // same number:
  //
  //   none          the baseline
  //   TCP open      one established connection
  //   TCP closed    the socket gone, its event handler thread still running
  //   reads off     connected with Mask() == 0, so the fd is not polled at all.
  //                 Before the fix this was the slowest case, because turning
  //                 the Dart flags off never reached the event handler.
  //   UDP bound     a registered fd with no peer, always fast: never listened
  //                 to, so no mask was ever sent for it.
  //
  // Reported as a distribution because a mean cannot tell 200 slow timers from
  // four stalls. This one was 200 slow timers.
  Probe('async', 'Timer(0) x200', () async => _timerDist(200),
      timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200, TCP open', () async {
    final socket = await Socket.connect(_benchHost, 5302,
        timeout: const Duration(seconds: 10));
    try {
      return await _timerDist(200);
    } finally {
      socket.destroy();
    }
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200, TCP closed', () async {
    final socket = await Socket.connect(_benchHost, 5302,
        timeout: const Duration(seconds: 10));
    socket.destroy();
    // A turn for the close to reach the event handler and leave the poll array.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return _timerDist(200);
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200, reads off', () async {
    final raw = await RawSocket.connect(_benchHost, 5302,
        timeout: const Duration(seconds: 10));
    final sub = raw.listen((_) {});
    raw.readEventsEnabled = false;
    raw.writeEventsEnabled = false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      return await _timerDist(200);
    } finally {
      await sub.cancel();
      raw.close();
    }
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200, UDP bound', () async {
    final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      return await _timerDist(200);
    } finally {
      udp.close();
    }
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200, counting events', () async {
    // Does an idle socket deliver anything Dart can see?
    //
    // It does not, and that was the misleading part: the write event is
    // one-shot in Dart and every later one is discarded before it reaches a
    // listener, while the event handler was posting 1100 a second. Kept because
    // "write 1" is the correct answer, and a regression shows as a listener
    // seeing the storm.
    final raw = await RawSocket.connect(_benchHost, 5302,
        timeout: const Duration(seconds: 10));
    var read = 0, write = 0, closed = 0, other = 0;
    final sub = raw.listen((event) {
      switch (event) {
        case RawSocketEvent.read:
          read++;
        case RawSocketEvent.write:
          write++;
        case RawSocketEvent.readClosed:
        case RawSocketEvent.closed:
          closed++;
        default:
          other++;
      }
    });
    try {
      final dist = await _timerDist(200);
      return '$dist | read $read write $write closed $closed other $other';
    } finally {
      await sub.cancel();
      raw.close();
    }
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200, loopback TCP', () async {
    // The same connected TCP socket with the Mac, the radio and the access
    // point taken out of it. If this is slow, nothing outside the console is
    // involved and the cause is in the net stack or above it.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final client = await Socket.connect(server.address, server.port,
        timeout: const Duration(seconds: 10));
    final accepted = await server.first;
    try {
      return await _timerDist(200);
    } finally {
      client.destroy();
      accepted.destroy();
      await server.close();
    }
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Future.delayed(1ms) x200', () async => _delayedDist(200),
      timeout: const Duration(seconds: 120)),
  // The three probes that can separate Future.delayed's overhead from the
  // timer's, and both from the platform's granularity. See _delayLadder.
  Probe('async', 'Timer(1ms) x200', () async =>
      _timerAtDist(200, const Duration(milliseconds: 1)),
      timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) vs Timer(1ms) ladder', () async =>
      _delayLadder(50, const [0, 1, 2, 4, 8, 16]),
      timeout: const Duration(seconds: 180)),
  // Future.delayed at zero, against Timer(0) above: same wrapper, no wait to
  // pay for. Whatever separates these two is the wrapper alone.
  Probe('async', 'Future.delayed(0) x200', () async =>
      _delayedDist(200, Duration.zero),
      timeout: const Duration(seconds: 120)),
  Probe('async', 'Future.delayed(1ms) x200, TCP open', () async {
    final socket = await Socket.connect(_benchHost, 5302,
        timeout: const Duration(seconds: 10));
    try {
      return await _delayedDist(200);
    } finally {
      socket.destroy();
    }
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200 again', () async => _timerDist(200),
      timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200, 4 TCP open', () async {
    // Does the penalty scale with the number of connections?
    //
    // It did, steeply: 744 us at one connection, 16941 at four, 43418 at eight.
    // That said the cost was per socket per wake rather than a mode the console
    // entered. All three now sit at ~200 us.
    final sockets = <Socket>[];
    for (var i = 0; i < 4; i++) {
      sockets.add(await Socket.connect(_benchHost, 5302,
          timeout: const Duration(seconds: 10)));
    }
    try {
      return await _timerDist(200);
    } finally {
      for (final s in sockets) {
        s.destroy();
      }
    }
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200, 8 TCP open', () async {
    final sockets = <Socket>[];
    for (var i = 0; i < 8; i++) {
      sockets.add(await Socket.connect(_benchHost, 5302,
          timeout: const Duration(seconds: 10)));
    }
    try {
      return await _timerDist(200);
    } finally {
      for (final s in sockets) {
        s.destroy();
      }
    }
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'Timer(0) x200 at once, TCP open', () async {
    // The same 200 timers with all of them armed before any is awaited, which
    // asks whether the cost is per message or per trip round the message loop.
    // If the total collapses, the loop is the unit and TLS is stuck with it,
    // because the record layer cannot batch. If it holds, every message pays.
    final socket = await Socket.connect(_benchHost, 5302,
        timeout: const Duration(seconds: 10));
    try {
      final sw = Stopwatch()..start();
      await Future.wait<void>(<Future<void>>[
        for (var i = 0; i < 200; i++)
          () {
            final c = Completer<void>();
            Timer(Duration.zero, c.complete);
            return c.future;
          }(),
      ]);
      sw.stop();
      return '${sw.elapsedMilliseconds} ms total, '
          '${(sw.elapsedMicroseconds / 200).toStringAsFixed(0)} us each';
    } finally {
      socket.destroy();
    }
  }, timeout: const Duration(seconds: 120)),
  Probe('async', 'microtask x200', () async => _microtaskDist(200),
      timeout: const Duration(seconds: 120)),
  Probe('async', 'microtask x200, TCP open', () async {
    // The control that decides how wide the question is. A microtask is drained
    // inside the current turn and never reaches a port, so if this slows down
    // with a socket open then the isolate's own thread is being held up and the
    // timer path is a bystander.
    final socket = await Socket.connect(_benchHost, 5302,
        timeout: const Duration(seconds: 10));
    try {
      return await _microtaskDist(200);
    } finally {
      socket.destroy();
    }
  }, timeout: const Duration(seconds: 120)),

  // -- Throughput, layer by layer.
  //
  // localsend receives a 5 MB file over HTTPS in 62 seconds: 84 KB/s, against
  // 852 KB/s pushing the same file over the same Wi-Fi to the same card from C.
  // Every explanation for that gap has been a guess that did not survive being
  // built, so these probes move the same bytes through one more layer each.
  //
  // The first run answered most of it: plain HTTP reads 5 MB at 2377 KB/s and
  // writes it to the card at 544 KB/s, so sockets, the HTTP parser and the
  // filesystem are all fine. HTTPS did not finish inside the old 25-second
  // ceiling. These split TLS in two:
  //
  //   handshake   asymmetric crypto and certificate parsing, paid once
  //   1MB vs 4MB  same time means the handshake; time that scales with the
  //               bytes means the record layer
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

  // -- The two pinned plugins. Not a test of the packages so much as of the
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

  // Three separate channels that all get called "printing", reported separately
  // because they fail separately. The combined version threw on the first one
  // that broke and said nothing about the rest, so "print is broken" was
  // recorded for a run in which `print` was fine: it is dart:io's stderr that
  // raises, and merely constructing it is enough.
  Probe('io', 'print to log', () async {
    final results = <String>[];
    for (final (name, emit) in <(String, void Function())>[
      ('print', () => print('flutter-vita: print')),
      ('stdout', () => stdout.writeln('flutter-vita: stdout')),
      ('stderr', () => stderr.writeln('flutter-vita: stderr')),
    ]) {
      try {
        emit();
        // "accepted", not "ok". IOSink.writeln is buffered and asynchronous, so
        // the call returning proves only that the sink was constructed and the
        // bytes queued. On 2026-08-15 all three reported ok while the engine log
        // carried `writeFrom failed ... Bad file number` twice, as an unhandled
        // async exception. A synchronous probe cannot see that.
        results.add('$name accepted');
      } on Object catch (e) {
        results.add('$name ${e.runtimeType}');
      }
    }
    return results.join(', ');
  }),

  // Phase 8, step one: does a platform channel reach the embedder at all?
  //
  // Deliberately not a TextField, which would drag in focus, layout and the IME
  // at once, and a failure anywhere in that chain would look the same. This
  // sends a real message on the real channel with the real codec and asks only
  // whether the plumbing exists.
  //
  // Passing means the message left Dart and the engine accepted a reply. It does
  // not mean the embedder understood it: `flutter/textinput` is an
  // OptionalMethodChannel, so "not implemented" comes back as null. What
  // actually arrived is in m3.log.
  Probe('channel', 'textinput reaches embedder', () async {
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    return 'sent, see m3.log';
  }),

  // -- TLS last, because it is parked and it kills the process.
  //
  // Phase 7 eliminated entropy, certificate verification, stack, memory and
  // assembly by measurement and still crashes here. Until that is understood,
  // anything ordered after these probes never runs.

  // Split into four, smallest first, because the single combined probe took the
  // whole process down and a hard fault names nothing. Each is a different
  // suspect, and the journal records which one was running:
  //
  //   1. does BoringSSL initialise at all
  //   2. does parsing ~240 KB of compiled-in PEM into an X509 store survive
  //   3. does a handshake survive
  //   4. does the HTTP layer on top of it survive
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
  // full key exchange and cipher negotiation, but skips building and walking the
  // trust chain, which is the recursive, allocation-heavy half. If this passes
  // and the verifying one below dies, the problem is verification.
  //
  // Not a configuration anything should ship: it proves reachability, never
  // security.
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
  // What this proves without a person: the IME initialises, the shell composites
  // it over a software-rendered framebuffer, and it tears down cleanly. That
  // middle one is the whole risk of Phase 8 -- sceCommonDialogUpdate wants a GXM
  // colour surface and ADR-0003 says we have only CDRAM we wrote pixels into.
  // The evidence is a screenshot taken from the host while the dialog is open,
  // so the six-second wait is the test window.
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
  // -- Which thread's message loop is this?
  //
  // A zero-duration timer is a message to the isolate's own port. In the root
  // isolate that message is delivered by Flutter's UI task runner, fml's
  // MessageLoopVita; in a spawned isolate it is delivered by the VM's own thread
  // pool, with no engine near it. Same VM, same port machinery, different loop.
  //
  // So if a spawned isolate holding a socket pays the same 5x, the cost is in
  // the VM or below it. If not, it is in the engine's message loop.
  //
  // Last in the suite: Isolate.spawn has never been run on this port. If it
  // takes the process down, everything above it has already been reported.
  Probe('isolate', 'spawn', () async {
    final port = ReceivePort();
    await Isolate.spawn(_isolateTimers, [port.sendPort, false]);
    return await port.first as String;
  }, timeout: const Duration(seconds: 120)),
  Probe('isolate', 'Timer(0) x200, TCP open', () async {
    final port = ReceivePort();
    await Isolate.spawn(_isolateTimers, [port.sendPort, true]);
    return await port.first as String;
  }, timeout: const Duration(seconds: 120)),
];

/// Runs _timerDist inside a spawned isolate, optionally holding a socket.
Future<void> _isolateTimers(List<Object?> args) async {
  final send = args[0] as SendPort;
  final withSocket = args[1] as bool;
  try {
    Socket? socket;
    if (withSocket) {
      socket = await Socket.connect(_benchHost, 5302,
          timeout: const Duration(seconds: 10));
    }
    final result = await _timerDist(200);
    socket?.destroy();
    send.send(result);
  } on Object catch (e) {
    send.send('failed: $e');
  }
}
