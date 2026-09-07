// The gallery's benchmark section. ADR-0017 decision 10 (it lives here rather
// than in a fifth product).
//
// Two ways in. A person opens it and taps Run, which is what makes a red row
// worth looking at; or the host writes bench.on and relaunches, and the page
// runs itself and writes a result file. The second is the one that produces
// numbers anyone can reproduce.

import 'dart:async';

import 'package:flutter/material.dart';

import 'runner.dart';
import 'scenes.dart';

class BenchPage extends StatefulWidget {
  const BenchPage({super.key, this.autoRun = false});

  /// Started by the host rather than by a person: run immediately, write the
  /// result file, and say so on screen.
  final bool autoRun;

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> with TickerProviderStateMixin {
  BenchRunner? _runner;
  Widget? _stage;
  String _status = 'idle';
  String? _current;
  bool _running = false;

  /// The window the host uses to turn the debug overlay off before anything is
  /// measured.
  ///
  /// The HUD costs about 300 us a frame and is drawn into the frame it is
  /// measuring. That is not hypothetical caution: on 2026-08-22 a 45-versus-60
  /// fps difference was attributed to the HUD and then disproved by a repeat
  /// A/B. Dart cannot switch it off -- it lives in the engine -- so the run
  /// waits, and `tools/bench.sh` sends `overlay off` during the wait.
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
      vsync: this,
      setStage: (w) => setState(() => _stage = w),
    );
    _runner = runner;
    await runner.runAll(context, onProgress: (name) {
      if (mounted) setState(() => _current = name);
    });
    if (writeFile) runner.write();
    if (!mounted) return;
    setState(() {
      _running = false;
      _current = null;
      _stage = null;
      final failed = runner.results.where((r) => !r.stats.passed).length;
      _status = failed == 0
          ? 'done — no stalls in ${runner.results.length} scenes'
          : 'done — $failed of ${runner.results.length} scenes stalled';
    });
  }

  @override
  Widget build(BuildContext context) {
    // While a scene is mounted it owns the whole screen. Anything else drawn
    // over it -- a progress bar, a label -- would be repainted every frame and
    // measured as part of the scene.
    final stage = _stage;
    if (stage != null) {
      // Wrapped in Material, not Scaffold. Mounting a scene replaces the whole
      // page, and ListTile and CircleAvatar reach for Material.of(context)!
      // -- which in release is a null check on nothing and takes the run down
      // with "Null check operator used on a null value" once per frame. A bare
      // Material is one background rect; a Scaffold would add furniture the
      // scene would then be measured painting.
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: stage,
      );
    }

    final results = _runner?.results ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('benchmark'),
        actions: [
          TextButton(
            onPressed: _running ? null : () => _run(writeFile: true),
            child: Text(_running ? '…' : 'Run'),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              _current == null ? _status : '$_status — $_current',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          // The source the route_hero scene flies from. Without a Hero of the
          // same tag on this page there is nothing to animate between, and
          // the "hero" scene silently measures a plain route push.
          const Hero(
            tag: 'bench-hero',
            child: SizedBox(width: 1, height: 1),
          ),
          // Four ways of asking for the same 16%-opaque blue, on the page
          // rather than in a scene.
          //
          // It started as the alpha_probe scene and could not be photographed:
          // a scene lasts about five seconds and one `shot` moves two
          // megabytes, so every capture landed on the results screen instead.
          // A diagnostic you cannot photograph is not a diagnostic. Here it
          // holds still.
          //
          // What it is for: on 2026-09-01 the receiver's panel was unreadable
          // under GL, its pills and buttons rendering at full opacity where
          // 16% was asked for. Software draws them correctly.
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
                      leading: Icon(
                        r.stats.passed ? Icons.check : Icons.warning,
                        size: 18,
                        color: r.stats.passed
                            ? Colors.greenAccent
                            : Colors.redAccent,
                      ),
                      title: Text('${r.name}  ·  ${r.stresses}',
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
      ),
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
