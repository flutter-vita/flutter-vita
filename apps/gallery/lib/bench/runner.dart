// Drives the scenes and writes the result file. ADR-0017.
//
// The host tool starts a run by writing ux0:data/flutter-vita/bench.on and
// relaunching; this writes ux0:data/flutter-vita/bench-result.json and a
// bench-done marker when it finishes. Two files rather than one because the
// host has to know the difference between "still running" and "wrote a
// truncated file", and a rename is the only atomic operation available.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'frame_recorder.dart';
import 'scene.dart';
import 'text_probe.dart';
// ignore: unused_import
import 'socket_probe.dart';
import 'timer_probe.dart';
import 'scenes.dart';

const String kDataDir = 'ux0:data/flutter-vita';
const String kResultPath = '$kDataDir/bench-result.json';
const String kDonePath = '$kDataDir/bench-done';
const String kSwitchPath = '$kDataDir/bench.on';
const String kSoftwareSwitchPath = '$kDataDir/software.on';

/// Comma-separated scene names. Empty or absent means run everything.
///
/// Added 2026-09-01, after a full run wedged: `route_wrap` and `route_spans`
/// between them grew the heap from 8 MB to the 159 MB ceiling in twelve
/// seconds, and every scene after them ran on a full heap until the UI thread
/// blocked inside a FreeType allocation. Anything scheduled behind a leak is
/// measuring the leak, so a subset has to be runnable on a fresh heap.
const String kOnlyPath = '$kDataDir/bench.only';

/// True when the host has asked for an unattended run.
///
/// Same shape as gl.on: a '1' in the first byte, not merely the file existing,
/// because the loader can `put` a file and cannot delete one -- a switch
/// keyed on existence is a switch that cannot be turned off remotely.
bool switchOn(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return false;
    final bytes = f.readAsBytesSync();
    return bytes.isNotEmpty && bytes.first == 0x31;
  } on FileSystemException {
    return false;
  }
}

/// The scene names this run is restricted to, or an empty set for all of them.
Set<String> onlyScenes() {
  try {
    final f = File(kOnlyPath);
    if (!f.existsSync()) return const <String>{};
    return f
        .readAsStringSync()
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  } on FileSystemException {
    return const <String>{};
  }
}

class SceneResult {
  SceneResult(this.name, this.stresses, this.stats) : error = null;
  SceneResult.failed(this.name, this.stresses, this.error)
      : stats = const SceneStats(
          frames: 0,
          spanMs: 0,
          worstMs: 0,
          p95Ms: 0,
          medianMs: 0,
          stallMs: 0,
          stallFrames: 0,
          buildMs: 0,
          buildMaxMs: 0,
          rasterMs: 0,
        );

  final String name;
  final String stresses;
  final SceneStats stats;

  /// Set when the scene threw. A scene that did not run is not a scene that
  /// passed, and the report has to be able to tell those apart.
  final String? error;

  Map<String, Object> toJson() => {
        'name': name,
        // Marked as a label so nobody reads it as something that was measured.
        'stresses_label': stresses,
        ...stats.toJson(),
        'passed': error == null && stats.passed,
        if (error != null) 'error': error!,
      };
}

/// Runs every scene once and reports as it goes.
class BenchRunner {
  BenchRunner({required this.vsync, required this.setStage});

  final TickerProvider vsync;

  /// Mounts a scene's widget. Passing null clears the stage.
  final void Function(Widget? stage) setStage;

  final FrameRecorder recorder = FrameRecorder();
  final List<SceneResult> results = <SceneResult>[];

  /// Frames forced after each scene so the batched timings for its final
  /// frames arrive. Dropped from the window afterwards -- see
  /// FrameRecorder.take.
  static const int _flushFrames = 5;

  /// Quiet wall-clock time before a scene is measured.
  ///
  /// Not politeness. Until 2026-08-25 every Dart timer on this port fired on a
  /// 200 ms grid, which meant the two probes above spent ~25 seconds mostly
  /// idle before the first scene and the route scenes settled for ~600 ms
  /// rather than the 450 they asked for. Fixing the timers took that away, and
  /// two scenes moved: opacity_fade 83 -> 200 ms and route_boxes 33 -> 133,
  /// both reproducing three runs running, both with the UI thread at 1.2 ms
  /// and the raster thread at 1.1 -- a pause with nothing running, which is
  /// what a collection looks like from here.
  ///
  /// So the recovery the benchmark used to get by accident is now asked for on
  /// purpose. A scene measured immediately after another one is measuring the
  /// previous scene's garbage.
  static Future<void> _quiet() =>
      Future<void>.delayed(const Duration(milliseconds: 500));

  Future<void> _flush() async {
    for (var i = 0; i < _flushFrames; i++) {
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  Future<void> runAnimated(AnimatedScene scene) async {
    final controller = AnimationController(vsync: vsync, duration: scene.duration);
    // Mounted and given one frame to settle before measurement starts, so the
    // scene's first build -- widget creation, image decode, text layout that
    // will be cached -- is not charged to the animation.
    setStage(
      AnimatedBuilder(
        animation: controller,
        builder: (context, _) => scene.builder(context, controller.value),
      ),
    );
    await SchedulerBinding.instance.endOfFrame;
    await SchedulerBinding.instance.endOfFrame;

    final mark = recorder.mark();
    for (var i = 0; i < scene.repeats; i++) {
      // Forward then reverse, rather than forward then jump back to zero. The
      // jump is a repaint belonging to nothing, and it would land in the
      // window as a frame the scene never really produces.
      await controller.forward();
      await controller.reverse();
    }
    await _flush();
    results.add(SceneResult(
      scene.name,
      scene.stresses.label,
      recorder.take(mark, dropTrailing: _flushFrames, keep: scene.repeats),
    ));

    setStage(null);
    controller.dispose();
    await SchedulerBinding.instance.endOfFrame;
  }

  Future<void> runRoute(RouteScene scene, BuildContext context) async {
    final navigator = Navigator.of(context, rootNavigator: true);

    // Never await Navigator.push. Its Future completes when the route is
    // *popped*, not when the transition finishes -- so awaiting it before the
    // matching pop is a deadlock, and it is one that looks like a slow
    // transition rather than a hang. The first run of this benchmark on
    // hardware sat on a pushed page until the host gave up.
    //
    // The transition itself is time-based: MaterialPageRoute animates for
    // 300 ms of wall clock whether or not frames are dropped, so a fixed
    // settle longer than that is sound. Dropped frames make it look worse,
    // which is the thing being measured, not longer.
    final settle = scene.settle;

    // A scene with no route factory is pushed the way every scene was pushed
    // before 2026-09-01: MaterialPageRoute, which on this port means
    // ZoomPageTransitionsBuilder. The factory exists so the transition can be
    // the variable rather than an unstated constant -- see RouteScene.route.
    Route<void> makeRoute() => scene.route == null
        ? MaterialPageRoute<void>(builder: scene.page)
        : scene.route!(context, scene.page);

    Future<void> pushAndPop() async {
      unawaited(navigator.push(makeRoute()));
      await Future<void>.delayed(settle);
      if (navigator.canPop()) navigator.pop();
      await Future<void>.delayed(settle);
    }

    // One untimed round first: the very first build of a route pays for
    // everything it touches for the first time, and charging that to the
    // transition measures the app's cold start rather than its animation.
    await pushAndPop();

    final mark = recorder.mark();
    for (var i = 0; i < scene.repeats; i++) {
      await pushAndPop();
    }
    await _flush();
    results.add(SceneResult(
      scene.name,
      scene.stresses.label,
      recorder.take(mark, dropTrailing: _flushFrames, keep: scene.repeats),
    ));
  }

  /// Mount, settle, then call the scene's driver [DrivenScene.repeats] times.
  ///
  /// The stage stays up across repeats. Remounting between them would charge
  /// the widget tree's first build to every repetition and drown the thing
  /// being measured -- a fling is 900 ms of scrolling, a rebuilt ListView is
  /// one 240 ms frame.
  Future<void> runDriven(DrivenScene scene) async {
    setStage(scene.stage());
    await SchedulerBinding.instance.endOfFrame;
    await SchedulerBinding.instance.endOfFrame;

    // One untimed repetition, same reason a route scene gets one: the first
    // drawer open builds the drawer, the first fling builds every row it
    // passes, and neither is what the scene is about.
    await scene.drive();
    await _quiet();

    final mark = recorder.mark();
    for (var i = 0; i < scene.repeats; i++) {
      await scene.drive();
    }
    await _flush();
    results.add(SceneResult(
      scene.name,
      scene.stresses.label,
      recorder.take(mark, dropTrailing: _flushFrames, keep: scene.repeats),
    ));

    setStage(null);
    await SchedulerBinding.instance.endOfFrame;
  }

  Future<void> runAll(BuildContext context, {void Function(String)? onProgress}) async {
    recorder.attach();
    final only = onlyScenes();
    bool wanted(String name) => only.isEmpty || only.contains(name);
    if (only.isNotEmpty) {
      print('bench: restricted to ${only.length} scenes: ${only.join(', ')}');
    }
    await prepareAssets();
    // Before any scene, because it is a measurement of the machine rather than
    // of a scene, and because a scene that has already run has warmed caches
    // this wants cold-ish. See text_probe.dart.
    final probe = probeText();
    print('bench: $probe');
    print('bench: ${await probeTimers()}');
    print('bench: ${await probeTimers(pumpFrames: true)}');
    // Not called. probeSockets() wedges the isolate: bind, connect and accept
    // all succeed, the first byte never comes back, and the 30 s timeout
    // guarding it never fires either -- because that timeout is a timer, and
    // the thread that would deliver it is the one that is stuck. Every scene
    // after it is lost. Left in the tree because it is the measurement the
    // event-handler fix has to pass; run it deliberately, not as part of a
    // benchmark. See socket_probe.dart.
    // print('bench: ${await probeSockets()}');
    try {
      // Each scene is isolated. An unattended run that hangs because one
      // scene threw reports nothing at all, which is strictly worse than
      // reporting eleven scenes and a failure -- and that is exactly what the
      // first run on hardware did.
      for (final scene in [...animatedScenes, ...motionScenes]) {
        if (!wanted(scene.name)) continue;
        onProgress?.call(scene.name);
        // Into the engine log, not just the on-screen label. A run that stops
        // finishing tells the host only that it stopped -- on 2026-08-24 that
        // left no way to say which of fifteen scenes was the one hanging, and
        // the whole cost of finding out was a rebuild.
        print('bench: scene ${scene.name}');
        await _quiet();
        try {
          await runAnimated(scene);
        } catch (e, st) {
          print('bench: scene ${scene.name} threw: $e');
          print('$st');
          results.add(SceneResult.failed(scene.name, scene.stresses.label, '$e'));
          setStage(null);
        }
      }
      for (final scene in drivenScenes) {
        if (!wanted(scene.name)) continue;
        onProgress?.call(scene.name);
        print('bench: scene ${scene.name}');
        await _quiet();
        try {
          await runDriven(scene);
        } catch (e, st) {
          print('bench: scene ${scene.name} threw: $e');
          print('$st');
          results.add(SceneResult.failed(scene.name, scene.stresses.label, '$e'));
          setStage(null);
        }
      }
      for (final scene in [...routeScenes, ...transitionScenes, ...modalScenes]) {
        if (!wanted(scene.name)) continue;
        onProgress?.call(scene.name);
        print('bench: scene ${scene.name}');
        await _quiet();
        if (!context.mounted) break;
        try {
          await runRoute(scene, context);
        } catch (e, st) {
          print('bench: scene ${scene.name} threw: $e');
          print('$st');
          results.add(SceneResult.failed(scene.name, scene.stresses.label, '$e'));
          // A modal that threw mid-push can leave its route on the stack, and
          // the next scene would then measure a transition on top of it.
          final nav = Navigator.of(context, rootNavigator: true);
          while (nav.canPop()) {
            nav.pop();
          }
        }
      }
    } finally {
      recorder.detach();
      // Whatever went wrong, come back to the root. A run that ends on a
      // pushed page leaves the console looking hung and the next run starting
      // from somewhere it does not expect.
      if (context.mounted) {
        final nav = Navigator.of(context, rootNavigator: true);
        while (nav.canPop()) {
          nav.pop();
        }
      }
    }
  }

  /// The result file, plus a marker written strictly afterwards.
  ///
  /// The renderer recorded here is what software.on *asked for*, and the
  /// field is named to say so. A binary built against an older engine artifact ignores
  /// that switch entirely -- one did, on 2026-08-22, and reported a GPU frame
  /// while the file said 0. Only the host can settle it, with `shotinfo`, so
  /// only the host writes `renderer`.
  void write() {
    final payload = <String, Object>{
      'schema': 1,
      'software_on_requested': switchOn(kSoftwareSwitchPath),
      'dart_version': Platform.version.split(' ').first,
      'scenes': results.map((r) => r.toJson()).toList(),
    };
    Directory(kDataDir).createSync(recursive: true);
    final tmp = File('$kResultPath.part');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload),
        flush: true);
    final target = File(kResultPath);
    if (target.existsSync()) target.deleteSync();
    tmp.renameSync(kResultPath);
    File(kDonePath).writeAsStringSync('1', flush: true);
  }
}
