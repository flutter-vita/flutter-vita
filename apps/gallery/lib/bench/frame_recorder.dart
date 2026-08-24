// Frame capture for the benchmark. ADR-0017.
//
// Everything here is ordinary Flutter: SchedulerBinding hands Dart a
// FrameTiming per frame with buildDuration and rasterDuration already
// separated. No embedder change, which is why the benchmark is not pinned to
// an engine artifact and can be fixed without a repackage.

import 'dart:math' as math;

import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';

/// The vsync period this console runs at, and the line the stall rule is
/// drawn from. A frame that misses one deadline presents one period late.
const double kVsyncMs = 1000.0 / 60.0;

/// Two vsyncs. A frame period at or above this reads as 30 fps or worse --
/// see [SceneStats.stallMs] for why a single one is not yet a stall.
const double kSlowFrameMs = kVsyncMs * 2;

/// What one scene produced, reduced to the numbers the report and the gate
/// are made of.
class SceneStats {
  const SceneStats({
    required this.frames,
    required this.spanMs,
    required this.worstMs,
    required this.p95Ms,
    required this.medianMs,
    required this.stallMs,
    required this.stallFrames,
    required this.buildMs,
    required this.rasterMs,
  });

  /// How many frames the window covered. A scene with very few frames is not
  /// a scene whose percentiles mean anything, so the report prints it.
  final int frames;

  /// Wall time the window covered. The report gates on this rather than on
  /// frame count: a scene running at four frames a second produces very few
  /// frames precisely because it is terrible, and refusing to grade it for
  /// that reason would hide the worst results in the suite.
  final double spanMs;

  /// Slowest single frame period. What the baseline gate compares, because it
  /// is the number the stall rule is made of.
  final double worstMs;
  final double p95Ms;
  final double medianMs;

  /// Longest uninterrupted run of frames at or below 30 fps, in milliseconds,
  /// counting only runs of two or more.
  ///
  /// The "two or more" is the whole rule. At 60 Hz every frame period is a
  /// multiple of 16.67 ms, so a frame that misses a single deadline already
  /// presents at 33.3 ms and reads as exactly 30 fps -- a literal "below
  /// 30 fps" test fires on every dropped frame, and on this console nearly
  /// every scene drops one. Two in a row is a 66.7 ms interruption, which is
  /// about the shortest a person reliably sees.
  ///
  /// Zero means the scene passed.
  final double stallMs;
  final int stallFrames;

  /// Median UI-thread and raster-thread time. The split is the point: this
  /// port is UI-bound almost everywhere, and a scene reporting only "slow"
  /// cannot say whether the GPU could help it.
  final double buildMs;
  final double rasterMs;

  bool get passed => stallMs == 0;

  Map<String, Object> toJson() => {
        'frames': frames,
        'span_ms': _r(spanMs),
        'worst_ms': _r(worstMs),
        'p95_ms': _r(p95Ms),
        'median_ms': _r(medianMs),
        'stall_ms': _r(stallMs),
        'stall_frames': stallFrames,
        'build_ms': _r(buildMs),
        'raster_ms': _r(rasterMs),
      };

  static double _r(double v) => (v * 100).roundToDouble() / 100;
}

/// Collects [FrameTiming]s continuously and slices them per scene.
///
/// Continuously, rather than starting and stopping around each scene, because
/// timings are delivered asynchronously and in batches: a callback registered
/// at scene start would miss frames belonging to the scene, and one removed at
/// scene end would drop the last few. Slicing an always-on buffer by index has
/// neither problem.
class FrameRecorder {
  final List<FrameTiming> _all = <FrameTiming>[];
  bool _attached = false;

  void attach() {
    if (_attached) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _attached = true;
  }

  void detach() {
    if (!_attached) return;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _attached = false;
  }

  void _onTimings(List<FrameTiming> timings) => _all.addAll(timings);

  /// Index to hand back to [take] when the scene is over.
  int mark() => _all.length;

  /// Everything recorded since [mark], minus [dropTrailing] entries.
  ///
  /// The caller forces a fixed number of frames after the animation ends so
  /// the batched timings for its final frames arrive. Those forced frames are
  /// idle and fast, so leaving them in would quietly soften every percentile;
  /// dropping exactly as many as were forced is deterministic, because an
  /// idle frame does not itself drop.
  SceneStats take(int from, {int dropTrailing = 0}) {
    final end = math.max(from, _all.length - dropTrailing);
    final window = _all.sublist(math.min(from, end), end);
    return _reduce(window);
  }

  void clear() => _all.clear();

  static SceneStats _reduce(List<FrameTiming> window) {
    if (window.length < 2) {
      return const SceneStats(
        frames: 0,
        spanMs: 0,
        worstMs: 0,
        p95Ms: 0,
        medianMs: 0,
        stallMs: 0,
        stallFrames: 0,
        buildMs: 0,
        rasterMs: 0,
      );
    }

    // Frame *period*, not frame cost: the gap between one frame reaching the
    // screen and the next. A frame whose work takes 20 ms is not a 20 ms
    // frame, it is a 33.3 ms frame, because it misses its vsync and waits for
    // the following one. Only the period says what was actually seen.
    final periods = <double>[];
    for (var i = 1; i < window.length; i++) {
      final prev =
          window[i - 1].timestampInMicroseconds(FramePhase.vsyncStart);
      final next = window[i].timestampInMicroseconds(FramePhase.vsyncStart);
      final ms = (next - prev) / 1000.0;
      if (ms <= 0 || ms >= 5000) continue;

      // Drop idle gaps. A route scene waits between repeats, and nothing is
      // scheduled during the wait -- so the next frame's period spans the
      // whole pause and arrives looking like a 2.5 second stall. It is not:
      // route_hero reported exactly that on 2026-08-24 and the time was spent
      // doing nothing at all.
      //
      // The test is whether the frame did work. A frame that is slow is slow
      // because it built or rastered something; a long period whose frame did
      // almost nothing is the scheduler resting. Anything under 100 ms is kept
      // regardless, because at that scale the ratio is noise.
      //
      // What this can hide, stated plainly: a stall caused by something
      // outside the frame -- a long GC pause, a blocking read -- also shows as
      // a long period with no work in it, and is dropped here. The suite runs
      // no IO during a scene, so on this port that leaves GC, and a GC pause
      // long enough to matter would show up as a raised median across the
      // whole scene rather than vanishing.
      final work = (window[i].buildDuration.inMicroseconds +
              window[i].rasterDuration.inMicroseconds) /
          1000.0;
      if (ms > 100 && work < ms * 0.25) continue;

      periods.add(ms);
    }
    if (periods.isEmpty) {
      return const SceneStats(
        frames: 0,
        spanMs: 0,
        worstMs: 0,
        p95Ms: 0,
        medianMs: 0,
        stallMs: 0,
        stallFrames: 0,
        buildMs: 0,
        rasterMs: 0,
      );
    }

    double longestStall = 0;
    var longestStallFrames = 0;
    var runMs = 0.0;
    var runFrames = 0;
    for (final p in periods) {
      if (p >= kSlowFrameMs - 0.5) {
        runMs += p;
        runFrames++;
      } else {
        if (runFrames >= 2 && runMs > longestStall) {
          longestStall = runMs;
          longestStallFrames = runFrames;
        }
        runMs = 0;
        runFrames = 0;
      }
    }
    if (runFrames >= 2 && runMs > longestStall) {
      longestStall = runMs;
      longestStallFrames = runFrames;
    }

    final sorted = List<double>.from(periods)..sort();
    final builds = window
        .map((t) => t.buildDuration.inMicroseconds / 1000.0)
        .toList()
      ..sort();
    final rasters = window
        .map((t) => t.rasterDuration.inMicroseconds / 1000.0)
        .toList()
      ..sort();

    return SceneStats(
      frames: periods.length,
      spanMs: periods.fold<double>(0, (a, b) => a + b),
      worstMs: sorted.last,
      p95Ms: _percentile(sorted, 0.95),
      medianMs: _percentile(sorted, 0.50),
      stallMs: longestStall,
      stallFrames: longestStallFrames,
      buildMs: _percentile(builds, 0.50),
      rasterMs: _percentile(rasters, 0.50),
    );
  }

  static double _percentile(List<double> sorted, double q) {
    if (sorted.isEmpty) return 0;
    final i = ((sorted.length - 1) * q).round();
    return sorted[i];
  }
}
