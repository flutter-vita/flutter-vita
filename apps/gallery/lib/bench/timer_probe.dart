// What a Dart timer actually costs on this console. ADR-0017.
//
// localsend's Receive screen runs at exactly 5.00 fps -- 200.0 ms a frame,
// three windows running -- with raster at 4 ms, the raster thread idle 191 ms
// and the platform loop reporting zero tasks. Nothing is working. Its spinner
// is not an AnimationController either; it is a `while (true)` loop that does
// `await Future.delayed(33ms)` and calls setState, asking for 30 fps.
//
// The first run answered the first question: every delay takes 200 ms, whatever
// is asked for -- 1, 8, 16, 33 and 100 ms all landed on the same 5 Hz grid. So
// it is a port bug and not a localsend bug.
//
// This file now asks the second question, which is *where*. A Dart timer takes
// two hops to get back to Dart:
//
//   1. dart:io's event handler thread waits out the deadline (poll() over
//      sceNetEpoll, see eventhandler_vita.cc) and posts a null to the isolate's
//      port when it expires.
//   2. That message wakes the UI thread's fml message loop
//      (message_loop_vita.cc, an event flag and sceKernelWaitEventFlag), which
//      drains the isolate's queue and runs the callback.
//
// Hop 2 is also what a vsync uses. So: run the same probe a second time with
// frames being pumped continuously. If the loop is already awake 60 times a
// second and timers *still* land on the 5 Hz grid, hop 2 is fine and hop 1 is
// the problem. If timers snap to something near what was asked for, hop 2 is
// the problem -- the loop is not waking for its own deadlines and everything
// coalesces onto whatever else happens to tick.

import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Measured latency of one [Future.delayed], per requested duration.
class TimerProbe {
  const TimerProbe(this.actualMs, {required this.label, this.framePeriodMs});

  /// `idle` or `pumped` -- which of the two conditions above this ran under.
  final String label;

  /// Requested milliseconds to the mean actual milliseconds observed.
  final Map<int, double> actualMs;

  /// Mean interval between frames while the probe ran, when frames were being
  /// pumped. Null for the idle run, which produces no frames at all.
  ///
  /// This is the control: it says whether the pump actually did anything. A
  /// `pumped` row with no frame period is a run that proves nothing.
  final double? framePeriodMs;

  @override
  String toString() {
    final frames = framePeriodMs == null
        ? ''
        : ' (frame ${framePeriodMs!.toStringAsFixed(1)}ms)';
    return 'timers/$label$frames ' +
        actualMs.entries
            .map((e) => '${e.key}ms->${e.value.toStringAsFixed(1)}')
            .join(' ');
  }

  Map<String, Object> toJson() => {
        'label': label,
        'actual_ms': actualMs.map(
            (k, v) => MapEntry('$k', (v * 10).roundToDouble() / 10)),
        if (framePeriodMs != null)
          'frame_period_ms': (framePeriodMs! * 10).roundToDouble() / 10,
      };
}

/// Asks the engine for a frame, forever, until [stop] is called.
///
/// A persistent frame callback would not do: it runs when a frame happens
/// rather than causing one, and an idle app produces none. This re-arms both
/// the callback and the request each time, which is what keeps vsync flowing.
class _FramePump {
  int frames = 0;
  bool _stopped = false;
  final Stopwatch _sw = Stopwatch();

  void start() {
    _sw.start();
    _arm();
  }

  void _arm() {
    final binding = SchedulerBinding.instance;
    binding.scheduleFrameCallback((Duration _) {
      frames++;
      if (!_stopped) {
        _arm();
      }
    });
    binding.scheduleFrame();
  }

  /// Mean milliseconds between frames, or null if none arrived.
  double? stop() {
    _stopped = true;
    _sw.stop();
    if (frames == 0) {
      return null;
    }
    return _sw.elapsedMicroseconds / frames / 1000.0;
  }
}

/// Times [reps] sequential delays at each of [_requested].
///
/// Sequential, not concurrent, because that is the shape the spinner uses: a
/// loop that awaits, does a little work, and awaits again. Concurrent timers
/// would measure the queue instead.
const List<int> _requested = <int>[1, 8, 16, 33, 100];

Future<TimerProbe> probeTimers({int reps = 20, bool pumpFrames = false}) async {
  final pump = pumpFrames ? (_FramePump()..start()) : null;
  final out = <int, double>{};
  for (final ms in _requested) {
    // One warm-up delay, so the first iteration does not carry whatever the
    // loop was doing before this started.
    await Future<void>.delayed(Duration(milliseconds: ms));
    final sw = Stopwatch()..start();
    for (var i = 0; i < reps; i++) {
      await Future<void>.delayed(Duration(milliseconds: ms));
    }
    sw.stop();
    out[ms] = sw.elapsedMicroseconds / reps / 1000.0;
  }
  return TimerProbe(out,
      label: pumpFrames ? 'pumped' : 'idle', framePeriodMs: pump?.stop());
}
