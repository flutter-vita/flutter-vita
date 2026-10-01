// Frame capture for the benchmark. ADR-0017.
//
// Ordinary Flutter: SchedulerBinding hands Dart a FrameTiming per frame with
// buildDuration and rasterDuration already separated. No embedder change, so
// the benchmark is not pinned to an engine artifact.

import 'dart:math' as math;

import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';

/// The vsync period this console runs at, and the line the stall rule is
/// drawn from. A frame that misses one deadline presents one period late.
const double kVsyncMs = 1000.0 / 60.0;

/// Two vsyncs. A frame period at or above this reads as 30 fps or worse --
/// see [SceneStats.stallMs] for why a single one is not yet a stall.
const double kSlowFrameMs = kVsyncMs * 2;

/// One frame, split into the four things that can make it late.
///
/// Medians say a transition runs at 60 fps; they cannot say what the three
/// frames that took 150 ms were doing. Each part points somewhere different:
/// [gapMs] at the platform or IO thread, [buildMs] at Dart, [waitMs] at a
/// raster thread still busy, [rasterMs] at the renderer.
class FrameSample {
  const FrameSample({
    required this.index,
    required this.periodMs,
    required this.gapMs,
    required this.buildMs,
    required this.waitMs,
    required this.rasterMs,
  });

  /// Position in the scene, so an experiment can be located -- first frame of every
  /// repeat reads very differently from three scattered frames.
  final int index;

  final double periodMs;

  /// vsync to build start. Time the frame existed but nothing had begun.
  final double gapMs;
  final double buildMs;

  /// Build finish to raster start. The handoff, and the queue in front of it.
  final double waitMs;
  final double rasterMs;

  Map<String, Object> toJson() => {
        'i': index,
        'period_ms': SceneStats._r(periodMs),
        'gap_ms': SceneStats._r(gapMs),
        'build_ms': SceneStats._r(buildMs),
        'wait_ms': SceneStats._r(waitMs),
        'raster_ms': SceneStats._r(rasterMs),
      };
}

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
    required this.buildMaxMs,
    this.worstFrames = const <FrameSample>[],
    this.heaviestBuilds = const <FrameSample>[],
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
  /// The "two or more" is the whole rule. At 60 Hz a frame that misses a single
  /// deadline already presents at 33.3 ms and reads as exactly 30 fps, and on
  /// this console nearly every scene drops one. Two in a row is a 66.7 ms
  /// interruption, about the shortest a person reliably sees.
  ///
  /// Zero means the scene passed.
  final double stallMs;
  final int stallFrames;

  /// Median UI-thread and raster-thread time. The split is the point: this
  /// port is UI-bound almost everywhere, and a scene reporting only "slow"
  /// cannot say whether the GPU could help it.
  final double buildMs;
  final double rasterMs;

  /// The slowest single build in the scene.
  ///
  /// [buildMs] is a median, which is wrong for a route scene: most frames are
  /// the transition coasting, so the median reads 1.2 ms while the frame that
  /// builds the incoming page takes 46. Steadier than [worstMs], which is
  /// quantised to a vsync.
  final double buildMaxMs;

  /// The few frames with the largest *build*, largest first.
  ///
  /// Distinct from [worstFrames], which ranks by period. They coincide when a
  /// scene's heavy frames dominate and diverge when they do not: at 12 ms a
  /// build is close enough to vsync quantisation that the five worst periods
  /// need not be the five heaviest builds. route_boxes read 11.6 and 29.4 on
  /// one binary that way.
  final List<FrameSample> heaviestBuilds;

  /// The slowest few frames, split by phase, slowest first.
  ///
  /// Kept because the aggregate above hides exactly the frames worth looking
  /// at: a scene with a 16.67 ms median and a 150 ms worst frame is not a slow
  /// scene, it is a fast scene with a defect, and the defect is in here.
  final List<FrameSample> worstFrames;

  bool get passed => stallMs == 0;

  /// Frames divided by the time they took, which is not 1000 / [medianMs].
  /// The median hides a scene that holds 60 fps and then drops ten frames;
  /// this does not.
  double get avgFps => spanMs <= 0 ? 0 : frames * 1000 / spanMs;

  Map<String, Object> toJson() => {
        'frames': frames,
        'span_ms': _r(spanMs),
        'worst_ms': _r(worstMs),
        'p95_ms': _r(p95Ms),
        'median_ms': _r(medianMs),
        'stall_ms': _r(stallMs),
        'stall_frames': stallFrames,
        'build_ms': _r(buildMs),
        'build_max_ms': _r(buildMaxMs),
        'raster_ms': _r(rasterMs),
        'worst_frames': worstFrames.map((f) => f.toJson()).toList(),
        'heaviest_builds': heaviestBuilds.map((f) => f.toJson()).toList(),
      };

  static double _r(double v) => (v * 100).roundToDouble() / 100;

  /// The same rounding, for a caller outside this file writing the same JSON.
  static double round(double v) => _r(v);
}

/// How many slow frames a scene reports individually, when the caller does not
/// say. Five covers "one bad frame per repeat" without turning the result file
/// into a trace.
const int _kWorstKept = 5;

/// Collects [FrameTiming]s continuously and slices them per scene.
///
/// Continuously rather than starting and stopping around each scene, because
/// timings arrive asynchronously and in batches: a callback registered at scene
/// start would miss frames belonging to the scene, and one removed at scene end
/// would drop the last few.
class FrameRecorder {
  final List<FrameTiming> _all = <FrameTiming>[];
  int _produced = 0;
  bool _attached = false;
  bool _counting = false;

  void attach() {
    if (_attached) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // A persistent frame callback cannot be removed, so it is added once and
    // left. It costs an increment per frame.
    if (!_counting) {
      SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
      _counting = true;
    }
    _attached = true;
  }

  void detach() {
    if (!_attached) return;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _attached = false;
  }

  void _onTimings(List<FrameTiming> timings) => _all.addAll(timings);

  void _onFrame(Duration _) => _produced++;

  /// Frames the app has produced since the recorder attached.
  ///
  /// **This, and not [length], is a position in a scene.** The engine reports
  /// timings in batches and runs about thirty frames behind the screen on this
  /// console, so a boundary read off [length] the moment a repetition ends
  /// sits thirty frames inside that repetition. It did: repetition 1 of
  /// `alpha_probe` came out 24 frames long against 55 for repetitions 2 and 3,
  /// and the 31 missing frames were counted in repetition 2.
  ///
  /// Frames report in the order they were produced, so produced frame i is
  /// entry i. Cut every window in these indices and wait for the entries with
  /// [settled].
  int get produced => _produced;

  /// Whether the entries for every frame produced before [upTo] have arrived.
  bool settled(int upTo) => _all.length >= upTo;

  /// Entries recorded. Equal to [produced] once a run has settled; a gap
  /// between the two says a produced frame reported no timing, which would
  /// shift every window after it. The result file carries both.
  int get reported => _all.length;

  /// One repetition of a scene, between two marks.
  ///
  /// The whole-scene window says what a scene costs. This says how much the
  /// same work varies between one run of it and the next, which is the only
  /// thing that tells the report what it can resolve. Merged into one window,
  /// as they were until 2026-09-24, three repetitions of a scene cannot
  /// disagree, and the gate fired on scenes whose repetitions disagreed by
  /// more than the band it was testing.
  SceneStats takeRange(int from, int to, {int keep = _kWorstKept}) {
    final end = math.min(math.max(from, to), _all.length);
    return _reduce(
        <List<FrameTiming>>[_all.sublist(math.min(from, end), end)], keep);
  }

  /// Several windows reduced as one.
  ///
  /// A scene's repetitions are measured one at a time, each with its own
  /// flush, so the frames between them belong to no repetition. The scene's
  /// own numbers come from the repetitions joined back together rather than
  /// from one window over the lot, which would count those frames.
  SceneStats takeRanges(List<List<int>> ranges, {int keep = _kWorstKept}) {
    return _reduce(<List<FrameTiming>>[
      for (final r in ranges)
        _all.sublist(math.min(r[0], _all.length),
            math.min(math.max(r[0], r[1]), _all.length)),
    ], keep);
  }

  void clear() => _all.clear();

  /// The numbers for one or more windows.
  ///
  /// Several windows are reduced as one set of frames, but no measurement
  /// crosses from one window to the next. A period is the gap between two
  /// frames that followed each other on the screen, and the last frame of one
  /// window and the first frame of the next did not: between them the scene
  /// was flushed and stood still. A stall does not cross a seam either, for
  /// the same reason.
  static SceneStats _reduce(List<List<FrameTiming>> windows, int keep) {
    final window = <FrameTiming>[for (final w in windows) ...w];
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
        buildMaxMs: 0,
      );
    }

    // Frame *period*, not frame cost: the gap between one frame reaching the
    // screen and the next. A frame whose work takes 20 ms is not a 20 ms
    // frame, it is a 33.3 ms frame, because it misses its vsync and waits for
    // the following one. Only the period says what was actually seen.
    final periods = <double>[];
    final runs = <List<double>>[];
    final samples = <FrameSample>[];
    var base = 0;
    for (final w in windows) {
      final run = <double>[];
      runs.add(run);
      for (var i = 1; i < w.length; i++) {
        final prev = w[i - 1].timestampInMicroseconds(FramePhase.vsyncStart);
        final next = w[i].timestampInMicroseconds(FramePhase.vsyncStart);
        final ms = (next - prev) / 1000.0;
        if (ms <= 0 || ms >= 5000) continue;

        // Drop idle gaps. A route scene waits between repeats and nothing is
        // scheduled during the wait, so the next frame's period spans the whole
        // pause and arrives looking like a 2.5 second stall. route_hero reported
        // exactly that on 2026-08-24.
        //
        // The test is whether the frame did work. Anything under 100 ms is kept
        // regardless, because at that scale the ratio is noise.
        //
        // What this hides: a stall from outside the frame -- a long GC pause, a
        // blocking read -- also shows as a long period with no work. The suite
        // runs no IO during a scene, and a GC pause long enough to matter would
        // raise the median across the whole scene rather than vanish.
        final work = (w[i].buildDuration.inMicroseconds +
                w[i].rasterDuration.inMicroseconds) /
            1000.0;
        if (ms > 100 && work < ms * 0.25) continue;

        periods.add(ms);
        run.add(ms);

        // Same frame, split by phase. Recorded for every kept frame and sorted
        // at the end rather than tracked as a running maximum, because the
        // interesting question is usually "are the slow frames in the same
        // place" and that needs more than one of them.
        final t = w[i];
        double at(FramePhase phase) =>
            t.timestampInMicroseconds(phase) / 1000.0;
        samples.add(FrameSample(
          index: base + i,
          periodMs: ms,
          gapMs: at(FramePhase.buildStart) - at(FramePhase.vsyncStart),
          buildMs: at(FramePhase.buildFinish) - at(FramePhase.buildStart),
          waitMs: at(FramePhase.rasterStart) - at(FramePhase.buildFinish),
          rasterMs: at(FramePhase.rasterFinish) - at(FramePhase.rasterStart),
        ));
      }
      base += w.length;
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
        buildMaxMs: 0,
      );
    }

    double longestStall = 0;
    var longestStallFrames = 0;
    var runMs = 0.0;
    var runFrames = 0;
    for (final run in runs) {
      runMs = 0;
      runFrames = 0;
      for (final p in run) {
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

    final worst = List<FrameSample>.from(samples)
      ..sort((a, b) => b.periodMs.compareTo(a.periodMs));
    final heaviest = List<FrameSample>.from(samples)
      ..sort((a, b) => b.buildMs.compareTo(a.buildMs));

    return SceneStats(
      frames: periods.length,
      spanMs: periods.fold<double>(0, (a, b) => a + b),
      worstMs: sorted.last,
      p95Ms: _percentile(sorted, 0.95),
      medianMs: _percentile(sorted, 0.50),
      stallMs: longestStall,
      stallFrames: longestStallFrames,
      buildMs: _percentile(builds, 0.50),
      buildMaxMs: builds.isEmpty ? 0 : builds.last,
      rasterMs: _percentile(rasters, 0.50),
      worstFrames: worst.take(keep).toList(),
      heaviestBuilds: heaviest.take(keep).toList(),
    );
  }

  static double _percentile(List<double> sorted, double q) {
    if (sorted.isEmpty) return 0;
    final i = ((sorted.length - 1) * q).round();
    return sorted[i];
  }
}
