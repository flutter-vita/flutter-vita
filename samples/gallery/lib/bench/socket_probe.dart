// Is it only the timeout that is coarse, or the whole wait?
//
// Every Dart timer on this port fires on a 200 ms grid, and the frame-pumped
// run in timer_probe.dart cleared the UI thread's message loop. That puts the
// delay on dart:io's event-handler thread, which waits out deadlines with
// poll() -- and VitaSDK's poll() is sceNetEpollCreate + sceNetEpollWait +
// sceNetEpollDestroy, once per call.
//
// Two possibilities wanting different fixes:
//
//   a. sceNetEpollWait ignores short timeouts but returns promptly when a
//      socket becomes readable. Then the fix is a thread that sleeps out the
//      deadline and writes one byte to the interrupt socketpair.
//   b. sceNetEpollWait returns on a 5 Hz grid whatever the reason. Then dart:io
//      networking is also capped at 5 Hz and the event handler needs a wakeup
//      channel that is not a socket.
//
// A loopback TCP round-trip separates them: a few milliseconds is (a), ~400 ms
// is (b).
//
// It is neither. This prints bind, bound, connected, accepted and then nothing.
// The first byte never comes back, and the 30 s timeout wrapped around the
// function never fires either, because a timeout is a timer and the thread that
// would deliver it is the one that is stuck. Registering a real socket does not
// slow the event handler down, it stops it.
//
// Whatever replaces the event handler has to make this probe print a
// round-trip. Deliberately not wired into the benchmark; see runner.dart.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Loopback TCP round-trip latency, or the reason there is none.
class SocketProbe {
  const SocketProbe({this.rttMs, this.reps = 0, this.error});

  /// Mean milliseconds for one byte to go out and come back.
  final double? rttMs;

  /// How many round-trips that mean is over.
  final int reps;

  /// Set instead of [rttMs] when the probe could not run at all -- which is
  /// itself a result worth printing rather than swallowing.
  final String? error;

  @override
  String toString() => error != null
      ? 'socket rtt: failed ($error)'
      : 'socket rtt ${rttMs!.toStringAsFixed(1)}ms over $reps round-trips';

  Map<String, Object> toJson() => {
        if (rttMs != null) 'rtt_ms': (rttMs! * 10).roundToDouble() / 10,
        if (rttMs != null) 'reps': reps,
        if (error != null) 'error': error!,
      };
}

Future<SocketProbe> probeSockets({int reps = 20}) async {
  try {
    return await _run(reps).timeout(const Duration(seconds: 30));
  } catch (e) {
    // A probe that hangs must not take the whole benchmark with it: on this
    // console "the run never finished" is the least informative failure there
    // is, and it has already cost two rebuilds.
    return SocketProbe(error: '$e');
  }
}

// Each step announces itself before it runs. dart:io sockets have never been
// exercised on this port, the first attempt took the app down, and the receiver
// -- which is a Flutter app too, and writes the same m3.log -- erased the
// evidence when it came up. A marker per step means the next hard fault names
// the call that caused it in the log that survives.
Future<SocketProbe> _run(int reps) async {
  print('bench: socket 1 bind');
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  print('bench: socket 2 bound port ${server.port}');
  final acceptedFuture = server.first;
  final client =
      await Socket.connect(InternetAddress.loopbackIPv4, server.port);
  print('bench: socket 3 connected');
  final accepted = await acceptedFuture;
  print('bench: socket 4 accepted');

  // Without this Nagle would add its own delay and the measurement would be
  // about the TCP stack rather than about the event handler.
  client.setOption(SocketOption.tcpNoDelay, true);
  accepted.setOption(SocketOption.tcpNoDelay, true);

  accepted.listen(accepted.add);

  Completer<void>? pending;
  client.listen((_) {
    final c = pending;
    pending = null;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
  });

  // One untimed round-trip first: the first write on a fresh connection pays
  // for whatever the stack sets up lazily, and that is not what this measures.
  pending = Completer<void>();
  client.add(Uint8List.fromList(<int>[0]));
  await pending!.future;
  print('bench: socket 5 warm round-trip done');

  final sw = Stopwatch()..start();
  for (var i = 0; i < reps; i++) {
    pending = Completer<void>();
    client.add(Uint8List.fromList(<int>[i & 0xff]));
    await pending!.future;
  }
  sw.stop();

  print('bench: socket 6 measured');
  client.destroy();
  accepted.destroy();
  await server.close();

  return SocketProbe(rttMs: sw.elapsedMicroseconds / reps / 1000.0, reps: reps);
}
