// The gallery's Scenes tab.
//
// Two ways in. A person opens it and taps Run, which is what makes a red row
// worth looking at; or the host writes bench.on and relaunches, and the tab
// runs itself and writes a result file.
//
// While a scene runs it takes the content area: the tab hands the scene
// widget to the Shell through `stage`, and the Shell draws it there, under
// the strip, with the rail gone. The tab itself stays mounted behind it, so
// the run it owns keeps its ticker and its context.

import 'dart:async';

import 'package:flutter/material.dart';

import 'runner.dart';
import 'scenes.dart';

class BenchPage extends StatefulWidget {
  const BenchPage({
    super.key,
    required this.stage,
    required this.scene,
    required this.vsync,
    this.autoRun = false,
  });

  /// The scene being measured, or null. Owned by the Shell, which shows it
  /// in the content area.
  final ValueNotifier<Widget?> stage;

  /// The running scene's name, for the strip. Owned by the Shell.
  final ValueNotifier<String?> scene;

  /// The Shell's. Not this tab's own: the tabs sit in an IndexedStack, which
  /// mutes the tickers of the tabs it is not showing, and a run must go on
  /// while the person looks at another tab.
  final TickerProvider vsync;

  /// Started by the host rather than by a person: run immediately, write the
  /// result file, and say so on screen.
  final bool autoRun;

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> {
  BenchRunner? _runner;
  String _status = 'idle';
  String? _current;
  bool _running = false;

  /// The window the host uses to turn the debug overlay off before anything is
  /// measured.
  ///
  /// The HUD costs about 300 us a frame and is drawn into the frame it is
  /// measuring; a 45-versus-60 fps difference was once attributed to it and then
  /// disproved. Dart cannot switch it off, so the run waits and
  /// `tools/bench.sh` sends `overlay off` during the wait.
  static const Duration _hostWindow = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    if (widget.autoRun) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        setState(() => _status = 'waiting for host');
        await Future<void>.delayed(_hostWindow);
        await _run(writeFile: true);
      });
    }
  }

  Future<void> _run({required bool writeFile}) async {
    if (_running) return;
    setState(() {
      _running = true;
      _status = 'running';
    });
    final runner = BenchRunner(
      vsync: widget.vsync,
      setStage: (w) => widget.stage.value = w,
    );
    _runner = runner;
    await runner.runAll(context, onProgress: (name) {
      widget.scene.value = name;
      if (mounted) setState(() => _current = name);
    });
    if (writeFile) runner.write();
    widget.scene.value = null;
    if (!mounted) return;
    widget.stage.value = null;
    setState(() {
      _running = false;
      _current = null;
      final failed = runner.results.where((r) => !r.stats.passed).length;
      _status = failed == 0
          ? 'done — no stalls in ${runner.results.length} scenes'
          : 'done — $failed of ${runner.results.length} scenes stalled';
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = _runner?.results ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _current == null ? _status : '$_status — $_current',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _running ? null : () => _run(writeFile: true),
                child: Text(_running ? '…' : 'Run'),
              ),
            ],
          ),
        ),
        // Four ways of asking for the same 16%-opaque blue.
        //
        // On the page rather than in a scene because a scene lasts about five
        // seconds and one `shot` moves two megabytes, so every capture landed
        // on the results screen instead.
        //
        // The receiver's panel is unreadable under GL, its pills and buttons
        // rendering at full opacity where 16% was asked for. Software draws
        // them correctly.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: _AlphaProbeRow(),
        ),
        if (results.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                '${animatedScenes.length + motionScenes.length + drivenScenes.length + routeScenes.length + transitionScenes.length + modalScenes.length} scenes\n'
                'a stall is 2+ consecutive frames at or below 30 fps',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.white54),
              ),
            ),
          )
        else
          Expanded(
            child: ListView(
              children: [
                for (final r in results)
                  ListTile(
                    dense: true,
                    title: Text(
                        '${r.stats.avgFps.toStringAsFixed(1)} fps  ·  '
                        '${r.name}  ·  ${r.stresses}',
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      'worst ${r.stats.worstMs}ms  p95 ${r.stats.p95Ms}ms  '
                      'stall ${r.stats.stallMs}ms  '
                      'ui ${r.stats.buildMs} / ras ${r.stats.rasterMs}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// See the note at its use site.
class _AlphaProbeRow extends StatelessWidget {
  const _AlphaProbeRow();

  static const _base = Color(0xFF4B8FD6);

  Widget _swatch(String label, Widget box) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 92, height: 26, child: box),
          Text(label,
              style: const TextStyle(fontSize: 9, color: Colors.white70)),
        ],
      );

  @override
  Widget build(BuildContext context) => Row(
        children: [
          _swatch('fromARGB(41)',
              const ColoredBox(color: Color.fromARGB(41, 75, 143, 214))),
          const SizedBox(width: 8),
          _swatch('withValues(.16)',
              ColoredBox(color: _base.withValues(alpha: 0.16))),
          const SizedBox(width: 8),
          _swatch('Opacity(.16)',
              const Opacity(opacity: 0.16, child: ColoredBox(color: _base))),
          const SizedBox(width: 8),
          _swatch('opaque', const ColoredBox(color: _base)),
        ],
      );
}
