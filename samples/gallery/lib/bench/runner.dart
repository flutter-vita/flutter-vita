// Drives the scenes and writes the result file. ADR-0017.
//
// The host starts a run by writing ux0:data/flutter-vita/bench.on and
// relaunching; this writes bench-result.json and a bench-done marker. Two files
// because the host has to tell "still running" from "wrote a truncated file",
// and a rename is the only atomic operation available.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_vita/flutter_vita.dart';

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

/// The other two suites of this app, same shape: a '1' starts an unattended
/// run on that tab, the run writes `<suite>-result.json` and `<suite>-done`.
const String kConformanceSwitchPath = '$kDataDir/conformance.on';
const String kHardwareSwitchPath = '$kDataDir/hardware.on';
const String kConformanceResultPath = '$kDataDir/conformance-result.json';
const String kConformanceDonePath = '$kDataDir/conformance-done';
const String kHardwareResultPath = '$kDataDir/hardware-result.json';
const String kHardwareDonePath = '$kDataDir/hardware-done';

/// Where suites write results now that more than one app has them.
///
/// bench-result.json stays as well: the host tools read it, and a suite that
/// silently stops writing the file its tooling reads is a suite whose results
/// vanish.
const String kBenchDir = '$kDataDir/bench';

/// Written by the receiver's TESTS tab before it launches this app, and by
/// nothing else. Its presence is the only way to tell a run the TESTS tab asked for
/// from one a host script started: both write bench.on.
const String kFromReceiverPath = '$kDataDir/bench.from-receiver';

/// Asking the dev server to give the console back. See HANDOFF_REQUEST in
/// devserver.c -- Dart cannot launch a title itself.
const String kHandoffPath = '$kDataDir/handoff.request';

/// Which scene is running, as `i/n name`, rewritten at every scene start.
///
/// The host polls it to print progress, and reads it after a restart to know
/// which scene the app was inside when it stopped. `-` between runs.
const String kScenePath = '$kDataDir/bench-scene';

/// The results so far, rewritten after every scene.
///
/// A run that the watchdog or a crash cuts short used to report nothing: the
/// result file is written once, at the end. Now the app comes back, reads
/// this, skips what it already measured and the scene it died in, and the
/// final file carries every scene with the one that broke marked as such.
/// `[]` between runs.
const String kPartialPath = '$kDataDir/bench-partial.json';

/// The engine receipt, shipped inside the vpk by templates/vita-app.
const String kEngineManifest = 'app0:/engine.txt';

/// Which engine build this binary links, or null if it cannot tell.
///
/// `built at` rather than the git revision: the revision is identical across
/// rebuilds, so it cannot separate two engines that differ by a patch.
String? engineStamp() {
  try {
    final f = File(kEngineManifest);
    if (!f.existsSync()) return null;
    String? rev;
    String? built;
    for (final line in f.readAsLinesSync()) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      if (parts[0] == 'engine' && rev == null) rev = parts[1];
      if (parts[0] == 'built' && parts[1] == 'at' && parts.length > 2) {
        built = parts[2];
      }
    }
    if (rev == null && built == null) return null;
    final short = rev == null ? '?' : rev.substring(0, 10);
    return built == null ? short : '$short $built';
  } catch (_) {
    // A receipt that cannot be read is a run without a stamp, which the receiver
    // already shows as not comparable. It is not a reason to lose the numbers.
    return null;
  }
}

/// Comma-separated scene names. Empty or absent means run everything.
///
/// Added 2026-09-01, after a full run wedged: `route_wrap` and `route_spans`
/// grew the heap from 8 MB to the 159 MB ceiling in twelve seconds, and every
/// scene after them ran on a full heap. Anything scheduled behind a leak is
/// measuring the leak.
const String kOnlyPath = '$kDataDir/bench.only';

/// True when the host has asked for an unattended run.
///
/// Same shape as gl.on: a '1' in the first byte, not merely the file existing,
/// because the receiver can `put` a file and cannot delete one -- a switch
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

  /// Results carried over from before a restart, already as JSON. See
  /// kPartialPath.
  final List<Map<String, Object?>> carried = <Map<String, Object?>>[];

  /// Scenes not to run again: carried, or the one the app restarted inside.
  final Set<String> _skip = <String>{};

  /// Every scene the suite has, in run order, for the `i/n` in bench-scene.
  /// The three scene classes share no base type; name and label are all this
  /// needs of them.
  List<({String name, String label})> get _allScenes => [
        for (final s in animatedScenes) (name: s.name, label: s.stresses.label),
        for (final s in motionScenes) (name: s.name, label: s.stresses.label),
        for (final s in drivenScenes) (name: s.name, label: s.stresses.label),
        for (final s in routeScenes) (name: s.name, label: s.stresses.label),
        for (final s in transitionScenes)
          (name: s.name, label: s.stresses.label),
        for (final s in modalScenes) (name: s.name, label: s.stresses.label),
      ];

  /// Pick up where a restarted run left off.
  void _resume() {
    final partial = _readJsonList(kPartialPath);
    for (final m in partial) {
      final name = m['name'];
      if (name is String) {
        carried.add(m);
        _skip.add(name);
      }
    }
    // `i/n name`, or `-`.
    String inside = '';
    try {
      final f = File(kScenePath);
      if (f.existsSync()) {
        final parts = f.readAsStringSync().trim().split(' ');
        if (parts.length == 2) inside = parts[1];
      }
    } on FileSystemException {
      // Nothing to resume from.
    }
    if (inside.isNotEmpty && !_skip.contains(inside)) {
      final scene = _allScenes.where((s) => s.name == inside).firstOrNull;
      if (scene != null) {
        carried.add(SceneResult.failed(
          scene.name,
          scene.label,
          'interrupted: the app restarted inside this scene',
        ).toJson());
        _skip.add(inside);
      }
    }
    if (_skip.isNotEmpty) {
      print('bench: resuming after a restart, ${carried.length} carried'
          '${inside.isNotEmpty ? ", $inside was interrupted" : ""}');
    }
  }

  static List<Map<String, Object?>> _readJsonList(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return const [];
      final v = jsonDecode(f.readAsStringSync());
      if (v is List) return v.whereType<Map<String, Object?>>().toList();
    } on FileSystemException {
      // As if absent.
    } on FormatException {
      // A half-written file is a file with nothing in it.
    }
    return const [];
  }

  void _noteScene(String name) {
    final all = _allScenes;
    final i = all.indexWhere((s) => s.name == name) + 1;
    _writeAtomic(kScenePath, '$i/${all.length} $name');
  }

  void _savePartial() {
    final all = <Map<String, Object?>>[
      ...carried,
      ...results.map((r) => r.toJson()),
    ];
    _writeAtomic(kPartialPath, jsonEncode(all));
  }

  /// Frames forced after each scene so the batched timings for its final
  /// frames arrive. Dropped from the window afterwards -- see
  /// FrameRecorder.take.
  static const int _flushFrames = 5;

  /// Quiet wall-clock time before a scene is measured.
  ///
  /// Not politeness. Until 2026-08-25 every Dart timer on this port fired on a
  /// 200 ms grid, so the benchmark got this recovery by accident. Fixing the
  /// timers took it away and two scenes moved: opacity_fade 83 -> 200 ms and
  /// route_boxes 33 -> 133, both with the UI thread at 1.2 ms and the raster
  /// thread at 1.1, which is what a collection looks like from here.
  ///
  /// A scene measured immediately after another measures its garbage.
  static Future<void> _quiet() =>
      Future<void>.delayed(const Duration(milliseconds: 500));

  Future<void> _flush() async {
    for (var i = 0; i < _flushFrames; i++) {
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  Future<void> runAnimated(AnimatedScene scene) async {
    final controller =
        AnimationController(vsync: vsync, duration: scene.duration);
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

  /// The route scenes' own Navigator, mounted on the stage for the length
  /// of the route section.
  ///
  /// Not the app's. A push rebuilds the route underneath (everything that
  /// depends on ModalRoute.of, and in the combined app that was the rail and
  /// five tabs) and snapshots it for the Zoom transition; with the app's
  /// Navigator that put 15 ms of build and a 133 ms first frame on every
  /// push in run 34 that run 30 did not have. Here the route underneath is
  /// one empty Material and the Hero the route_hero scene flies from.
  final GlobalKey<NavigatorState> _routeHost = GlobalKey<NavigatorState>();

  Widget _routeHostWidget() => Navigator(
        key: _routeHost,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (context) => Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            // The source the route_hero scene flies from. Without a Hero of
            // the same tag under the route there is nothing to animate
            // between, and the scene silently measures a plain push.
            child: const Align(
              alignment: Alignment.topLeft,
              child: Hero(
                tag: 'bench-hero',
                child: SizedBox(width: 1, height: 1),
              ),
            ),
          ),
        ),
      );

  Future<void> runRoute(RouteScene scene) async {
    final navigator = _routeHost.currentState!;
    final context = _routeHost.currentContext!;

    // Never await Navigator.push. Its Future completes when the route is
    // *popped*, so awaiting it before the matching pop is a deadlock that looks
    // like a slow transition. The first run on hardware sat on a pushed page
    // until the host gave up.
    //
    // MaterialPageRoute animates for 300 ms of wall clock whether or not frames
    // are dropped, so a fixed settle longer than that is sound.
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
  /// The stage stays up across repeats. Remounting would charge the widget
  /// tree's first build to every repetition: a fling is 900 ms of scrolling, a
  /// rebuilt ListView is one 240 ms frame.
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

  /// The clocks the console ran at, read once before the first scene.
  ///
  /// The CONFIGURE tab can raise them, and a relaunch puts them back, so two
  /// runs of the same binary are not comparable without this. On 2026-09-23 a
  /// whole run was spent finding that out.
  String? _clocks;

  Future<void> runAll(BuildContext context,
      {void Function(String)? onProgress}) async {
    recorder.attach();
    try {
      final i = await FlutterVita.info();
      if (i != null) _clocks = 'arm ${i.armMhz} MHz, gpu ${i.gpuMhz} MHz';
    } catch (_) {
      // An engine that does not answer the channel is still worth measuring.
    }
    _resume();
    final only = onlyScenes();
    bool wanted(String name) =>
        (only.isEmpty || only.contains(name)) && !_skip.contains(name);
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
    // all succeed, the first byte never comes back, and the 30 s timeout never
    // fires either, because the thread that would deliver it is the stuck one.
    // Left in the tree because it is the measurement the event-handler fix has
    // to pass. See socket_probe.dart.
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
        _noteScene(scene.name);
        await _quiet();
        try {
          await runAnimated(scene);
        } catch (e, st) {
          print('bench: scene ${scene.name} threw: $e');
          print('$st');
          results
              .add(SceneResult.failed(scene.name, scene.stresses.label, '$e'));
          setStage(null);
        }
        _savePartial();
      }
      for (final scene in drivenScenes) {
        if (!wanted(scene.name)) continue;
        onProgress?.call(scene.name);
        print('bench: scene ${scene.name}');
        _noteScene(scene.name);
        await _quiet();
        try {
          await runDriven(scene);
        } catch (e, st) {
          print('bench: scene ${scene.name} threw: $e');
          print('$st');
          results
              .add(SceneResult.failed(scene.name, scene.stresses.label, '$e'));
          setStage(null);
        }
        _savePartial();
      }
      final routeSection = [...routeScenes, ...transitionScenes, ...modalScenes]
          .where((s) => wanted(s.name))
          .toList();
      if (routeSection.isNotEmpty) {
        setStage(_routeHostWidget());
        await SchedulerBinding.instance.endOfFrame;
        await SchedulerBinding.instance.endOfFrame;
      }
      for (final scene in routeSection) {
        onProgress?.call(scene.name);
        print('bench: scene ${scene.name}');
        _noteScene(scene.name);
        await _quiet();
        if (_routeHost.currentState == null) break;
        try {
          await runRoute(scene);
        } catch (e, st) {
          print('bench: scene ${scene.name} threw: $e');
          print('$st');
          results
              .add(SceneResult.failed(scene.name, scene.stresses.label, '$e'));
          // A modal that threw mid-push can leave its route on the stack, and
          // the next scene would then measure a transition on top of it.
          final nav = _routeHost.currentState;
          while (nav != null && nav.canPop()) {
            nav.pop();
          }
        }
        _savePartial();
      }
      if (routeSection.isNotEmpty) {
        setStage(null);
        await SchedulerBinding.instance.endOfFrame;
      }
    } finally {
      recorder.detach();
      // Whatever went wrong, clear the stage. A run that ends on a pushed
      // page leaves the console looking hung and the next run starting from
      // somewhere it does not expect; the route host goes with the stage.
      setStage(null);
    }
  }

  /// The result file, plus a marker written strictly afterwards.
  ///
  /// The renderer recorded here is what software.on *asked for*, and the field
  /// is named to say so. A binary built against an older engine artifact ignores
  /// that switch -- one did, on 2026-08-22. Only the host can settle it, with
  /// `shotinfo`, so only the host writes `renderer`.
  void write() {
    final payload = <String, Object>{
      'schema': 1,
      'suite': 'gallery',
      'software_on_requested': switchOn(kSoftwareSwitchPath),
      'dart_version': Platform.version.split(' ').first,
      // When, and by which engine. Both absent until today, which is why the
      // receiver's TESTS tab shows the one result on this card as "no engine
      // stamp, not comparable" -- it was right to.
      'taken': DateTime.now().toIso8601String(),
      if (engineStamp() case final String e) 'engine': e,
      if (_clocks case final String c) 'clocks': c,
      'scenes': <Map<String, Object?>>[
        ...carried,
        ...results.map((r) => r.toJson()),
      ],
    };
    final text = const JsonEncoder.withIndent('  ').convert(payload);
    Directory(kDataDir).createSync(recursive: true);
    _writeAtomic(kResultPath, text);
    // Also under bench/, one file per app per suite, which is what the
    // receiver lists. The legacy path stays for the host tools.
    try {
      Directory(kBenchDir).createSync(recursive: true);
      _writeAtomic('$kBenchDir/FVTA00002-gallery.json', text);
    } catch (_) {
      // The TESTS-tab copy is a convenience. Losing it must not lose the run.
    }
    // Fresh for the next run, before the done marker: a host that arms the
    // next run without touching these would otherwise resume into this one.
    _writeAtomic(kPartialPath, '[]');
    _writeAtomic(kScenePath, '-');
    File(kDonePath).writeAsStringSync('1', flush: true);
    _handBackIfAsked();
  }

  /// Give the console back to the receiver, if the receiver started this.
  ///
  /// A run launched from the TESTS tab used to end with the app sitting on its
  /// results and the receiver gone. Host-started runs are left alone:
  /// tools/bench.sh wants the app alive afterwards.
  void _handBackIfAsked() {
    try {
      final marker = File(kFromReceiverPath);
      if (!marker.existsSync()) return;
      marker.deleteSync();
      // Last, and after bench-done: the dev server acts on this within half a
      // second, and anything written afterwards would not be written.
      File(kHandoffPath).writeAsStringSync('', flush: true);
    } catch (_) {
      // Staying in the app is a worse ending, not a broken one. The results
      // are already on the card.
    }
  }

  void _writeAtomic(String path, String text) => writeAtomic(path, text);
}

/// Write via a .part file and a rename, the only atomic operation here.
///
/// A reader that catches a half-written result must not be able to parse it
/// as a short one: the receiver would show a run that lost most of its scenes
/// as a run that measured three. Shared with the conformance and hardware
/// suites since they moved into this app.
void writeAtomic(String path, String text) {
  final tmp = File('$path.part');
  tmp.writeAsStringSync(text, flush: true);
  final target = File(path);
  if (target.existsSync()) target.deleteSync();
  tmp.renameSync(path);
}
