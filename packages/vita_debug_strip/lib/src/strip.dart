import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'stats.dart';

/// The strip: what the console is doing this second.
///
/// Two rows of one monospace table: captions over values, nine cells.
///
///   fps         frames the framework built in the last half second
///   ui thread   build+layout+paint on the UI (Dart) thread, per frame
///   raster      the raster thread turning the frame into GL, per frame
///   gpu busy    GPU time over wall time, and per frame
///   cpu cores   busy share of each of the four cores
///   ram         user memory used / the process budget, in MiB
///   cdram       video memory used / its budget
///   heap        the C heap used / the cap set for it at launch
///   battery     charge (+ while charging) and the battery's temperature
///
/// Two sources. Frame times come from the framework's own FrameTiming,
/// which sees every frame the engine produced and costs nothing to read.
/// The cores, the GPU, the battery and the memory come from the embedder
/// over `vita/stats`, twice a second; the embedder computes each as a rate
/// over the interval since the previous read.
///
/// The tick costs a frame. The gallery measured it: with the strip ticking
/// through its benchmark scenes, 23 stalled scenes and a 7.9 s stall sum;
/// frozen, 16 and 5.6 s. A benchmark freezes it or hides it.
class VitaStrip extends StatefulWidget {
  const VitaStrip({
    super.key,
    this.leading,
    this.frozen = false,
    this.background = const Color(0xFF161A23),
  });

  /// Drawn at the left of the strip: a title, or nothing.
  final Widget? leading;

  /// No timer, no channel: the strip shows a note and costs nothing.
  final bool frozen;

  final Color background;

  /// Twice a second. Once was too slow to read as live; the tick's frame
  /// is the cost, so it stays well under the frame rate.
  static const Duration period = Duration(milliseconds: 500);

  /// The strip's height, for an app that lays out under it.
  static const double height = 34;

  @override
  State<VitaStrip> createState() => _VitaStripState();
}

class _VitaStripState extends State<VitaStrip> {
  final _window = FrameWindow();
  final _since = Stopwatch()..start();
  FrameWindow _shown = FrameWindow();
  int _fps = 0;
  VitaStats? _stats;
  Timer? _tick;
  late final TimingsCallback _onTimings;
  int _built = 0;

  @override
  void initState() {
    super.initState();
    _onTimings = (timings) {
      for (final t in timings) {
        _window.frames++;
        _window.buildMs += t.buildDuration.inMicroseconds / 1000;
        _window.rasterMs += t.rasterDuration.inMicroseconds / 1000;
      }
    };
    if (widget.frozen) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // Frames are counted as they are built, not as their timings arrive:
    // the engine reports timings in batches, and a half-second window that
    // caught two batches once read 122 fps.
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    _tick = Timer.periodic(VitaStrip.period, (_) => _tickNow());
  }

  void _onFrame(Duration _) => _built++;

  Future<void> _tickNow() async {
    final stats = await VitaStatsChannel.read();
    if (!mounted) return;
    final elapsedUs = _since.elapsedMicroseconds;
    _since.reset();
    setState(() {
      _fps = elapsedUs == 0 ? 0 : (_built * 1e6 / elapsedUs).round();
      _built = 0;
      _shown = FrameWindow()
        ..frames = _window.frames
        ..buildMs = _window.frames == 0 ? 0 : _window.buildMs / _window.frames
        ..rasterMs =
            _window.frames == 0 ? 0 : _window.rasterMs / _window.frames;
      _window
        ..frames = 0
        ..buildMs = 0
        ..rasterMs = 0;
      if (stats != null) _stats = stats;
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (!widget.frozen) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    }
    super.dispose();
  }

  /// One cell: a caption over a value, both right-aligned in `width`
  /// columns of the monospace font, so the two rows line up as a table.
  /// One paragraph per row, not per cell: this console prices a paragraph
  /// at 0.7 to 1 ms of layout.
  static String _cell(String s, int width) =>
      s.length > width ? s.substring(0, width) : s.padLeft(width);

  static const _gap = '  ';

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    String ms(double v) => '${v.toStringAsFixed(1)} ms';
    String mem(int freeK, int totalK) {
      if (freeK < 0) return '-';
      if (totalK < 0) return '${freeK ~/ 1024} free';
      return '${(totalK - freeK) ~/ 1024} / ${totalK ~/ 1024}';
    }

    final cpu = s == null
        ? '-'
        : s.cpuIdle
            .map((i) => '${(100 - i).clamp(0, 99)}'.padLeft(2))
            .join(' ');
    final gpu = s == null
        ? '-'
        : '${s.gpuPct}% ${(s.gpuUs / 1000).toStringAsFixed(1)}ms';
    final batt = s == null
        ? '-'
        : '${s.battPct}%${s.charging ? '+' : ''} '
            '${s.battC.toStringAsFixed(1)}°C';
    // caption, value, width: the widest value each cell can show, so the
    // columns hold still from one second to the next.
    final cells = <(String, String, int)>[
      ('fps', '$_fps', 3),
      ('ui thread', ms(_shown.buildMs), 9),
      ('raster', ms(_shown.rasterMs), 8),
      ('gpu busy', gpu, 11),
      ('cpu cores %', cpu, 11),
      ('ram MB', s == null ? '-' : mem(s.memUserK, s.totalUserK), 9),
      ('cdram MB', s == null ? '-' : mem(s.memCdramK, s.totalCdramK), 9),
      (
        'heap MB',
        s == null
            ? '-'
            : '${s.heapMb} / ${s.heapCapMb < 0 ? s.heapArenaMb : s.heapCapMb}',
        9,
      ),
      ('battery', batt, 12),
    ];
    final captions = cells.map((c) => _cell(c.$1, c.$3)).join(_gap);
    final values = widget.frozen
        ? 'held: the strip is frozen (hud.off on the card, or the app asked)'
        : cells.map((c) => _cell(c.$2, c.$3)).join(_gap);
    const caption = TextStyle(
      fontSize: 12,
      height: 1.15,
      fontFamily: 'monospace',
      color: Color(0xFF6B7488),
    );
    const value = TextStyle(
      fontSize: 12,
      height: 1.15,
      fontFamily: 'monospace',
      color: Color(0xFFDDE3EE),
    );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        height: VitaStrip.height,
        color: widget.background,
        padding: const EdgeInsets.only(right: 8),
        child: Row(
          children: [
            Expanded(child: widget.leading ?? const SizedBox()),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(captions, maxLines: 1, softWrap: false, style: caption),
                Text(values, maxLines: 1, softWrap: false, style: value),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
