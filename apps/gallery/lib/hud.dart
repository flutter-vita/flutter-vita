// The strip above every tab: what the console is doing this second.
//
// Two rows of one monospace table: captions over values, nine cells.
//
//   fps         frames the framework timed in the last second
//   ui thread   build+layout+paint on the UI (Dart) thread, per frame
//   raster      the raster thread turning the frame into GL, per frame
//   gpu busy    GPU time over wall time, and per frame
//   cpu cores   busy share of each of the four cores
//   ram         user memory used / the process budget, in MiB
//   cdram       video memory used / its budget
//   heap        the C heap used / the arena carved for it at launch
//   battery     charge (+ while charging) and the battery's temperature
//
// Two sources. Frame times come from the framework's own FrameTiming, which
// sees every frame the engine produced and costs nothing to read. The cores,
// the GPU, the battery and the memory come from the embedder over
// `vita/stats`, read once a second; the embedder computes each as a rate over
// the interval since the previous read.
//
// GPU busy is GPU time over wall time, where GPU time is what the layer's
// meter thread reads off the completion notification: from a frame's first
// scene to the GPU finishing it. The ms figure is that per frame. The
// temperature is the battery's: the SoC's needs the kernel, which this
// project does not touch.
//
// The strip stays on screen and live while a benchmark scene runs. Its
// tick costs the scenes: run 35 of the gallery, with the strip ticking once
// a second through the scenes, had 23 stalled scenes and a stall sum of
// 7.9 s; run 36, same build with the strip frozen (hud.off), had 16 and
// 5.6 s, the best on record. A run from the receiver's TESTS tab pays that
// and shows the numbers; tools/bench.sh freezes the strip (hud.off) so the
// host's runs stay comparable with the ones before the strip.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// One second of frames, as the framework timed them.
class FrameWindow {
  int frames = 0;
  double buildMs = 0;
  double rasterMs = 0;
}

class VitaStats {
  VitaStats({
    required this.cpuIdle,
    required this.gpuPct,
    required this.gpuUs,
    required this.battC,
    required this.battPct,
    required this.charging,
    required this.memUserK,
    required this.memCdramK,
    required this.memPhycontK,
    required this.totalUserK,
    required this.totalCdramK,
    required this.totalPhycontK,
    required this.heapMb,
    required this.heapArenaMb,
    required this.heapCapMb,
    required this.armMhz,
    required this.busMhz,
    required this.gpuMhz,
  });

  final List<int> cpuIdle;
  final int gpuPct;
  final int gpuUs;
  final double battC;
  final int battPct;
  final bool charging;

  /// Free, in KiB, as `sceKernelGetFreeMemorySize` counts it; -1 unknown.
  final int memUserK;
  final int memCdramK;
  final int memPhycontK;

  /// The process budgets those are out of (`sceAppMgrGetBudgetInfo`), in
  /// KiB; -1 when the engine could not read them.
  final int totalUserK;
  final int totalCdramK;
  final int totalPhycontK;

  /// The C heap in MiB: used, what malloc has taken so far, and the cap the
  /// app set before main (160 MB in the template). The cap is carved out of
  /// the user budget above at launch, used or not.
  final int heapMb;
  final int heapArenaMb;
  final int heapCapMb;
  final int armMhz;
  final int busMhz;
  final int gpuMhz;

  static VitaStats? fromMap(Object? m) {
    if (m is! Map) return null;
    int i(String k, [int missing = 0]) => (m[k] as num?)?.toInt() ?? missing;
    return VitaStats(
      cpuIdle: [
        for (final v in (m['cpu_idle'] as List? ?? const [])) (v as num).toInt()
      ],
      gpuPct: i('gpu_pct'),
      gpuUs: i('gpu_us'),
      battC: (m['batt_c'] as num?)?.toDouble() ?? 0,
      battPct: i('batt_pct'),
      charging: m['charging'] == true,
      memUserK: i('mem_user_k', -1),
      memCdramK: i('mem_cdram_k', -1),
      memPhycontK: i('mem_phycont_k', -1),
      totalUserK: i('total_user_k', -1),
      totalCdramK: i('total_cdram_k', -1),
      totalPhycontK: i('total_phycont_k', -1),
      heapMb: i('heap_mb'),
      heapArenaMb: i('heap_arena_mb', -1),
      heapCapMb: i('heap_cap_mb', -1),
      armMhz: i('arm_mhz'),
      busMhz: i('bus_mhz'),
      gpuMhz: i('gpu_mhz'),
    );
  }
}

/// Reads the embedder's stats channel. One per app; the Hardware tab's battery
/// check reads through it too.
class VitaStatsChannel {
  static const _channel = MethodChannel('vita/stats', JSONMethodCodec());

  static Future<VitaStats?> read() async {
    try {
      final r = await _channel.invokeMethod<Object?>('read');
      return VitaStats.fromMap(r);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

class HudStrip extends StatefulWidget {
  const HudStrip({
    super.key,
    required this.leading,
    this.frozen = false,
  });

  /// Drawn at the left of the strip: the title.
  final Widget leading;

  /// No timer, no channel: the strip shows dashes and costs nothing. A
  /// switch on the card (hud.off) sets it; tools/bench.sh sets it for the
  /// scenes suite, so a host run's stall counts are the scenes' own.
  final bool frozen;

  /// Twice a second. Once was too slow to read as live (the person's word
  /// on build 40: "static values"); the tick's frame is the cost, so it
  /// stays well under the frame rate.
  static const Duration period = Duration(milliseconds: 500);

  @override
  State<HudStrip> createState() => _HudStripState();
}

class _HudStripState extends State<HudStrip> {
  final _window = FrameWindow();
  final _since = Stopwatch()..start();
  FrameWindow _shown = FrameWindow();
  int _fps = 0;
  VitaStats? _stats;
  Timer? _tick;
  late final TimingsCallback _onTimings;

  /// Set by a tick, cleared by the next frame's timing: names the frame
  /// that carried the strip's rebuild, so a slow one can be told apart
  /// from the scene's own.
  bool _tickPending = false;
  int _readUs = 0;

  @override
  void initState() {
    super.initState();
    _onTimings = (timings) {
      for (final t in timings) {
        _window.frames++;
        _window.buildMs += t.buildDuration.inMicroseconds / 1000;
        _window.rasterMs += t.rasterDuration.inMicroseconds / 1000;
        if (_tickPending) {
          _tickPending = false;
          final b = t.buildDuration.inMicroseconds;
          final r = t.rasterDuration.inMicroseconds;
          // The read is 6..20 ms of platform-thread latency, routinely;
          // what matters is a tick frame that costs the UI or raster thread.
          if (b > 12000 || r > 12000) {
            print('hud: tick frame build $b us raster $r us, '
                'stats read took $_readUs us');
          }
        }
      }
    };
    if (widget.frozen) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // Frames are counted as they are built, not as their timings arrive:
    // the engine reports timings in batches, and a half-second window that
    // caught two batches read 122 fps (build 43).
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    _tick = Timer.periodic(HudStrip.period, (_) => _tickNow());
  }

  int _built = 0;
  void _onFrame(Duration _) => _built++;

  Future<void> _tickNow() async {
    final sw = Stopwatch()..start();
    final stats = await VitaStatsChannel.read();
    _readUs = sw.elapsedMicroseconds;
    if (!mounted) return;
    _tickPending = true;
    // Frames per second over the window that just closed, however long the
    // read made it; a still tab reads 0.
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

  /// One cell: a caption over a value, both right-aligned in `width` columns
  /// of the monospace font, so the two rows line up as a table. One
  /// paragraph per row, not per cell: this console prices a paragraph at
  /// 0.7 to 1 ms of layout, and the tick already lands in a 13 ms frame.
  static String _cell(String s, int width) =>
      s.length > width ? s.substring(0, width) : s.padLeft(width);

  static const _gap = '  ';

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final fps = _fps;
    String ms(double v) => '${v.toStringAsFixed(1)} ms';
    String pct(int v) => '$v%';
    // used / total, in MiB; the total is the process budget the embedder
    // read at launch. Without one (an older engine) the free figure shows.
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
        : '${pct(s.gpuPct)} ${(s.gpuUs / 1000).toStringAsFixed(1)}ms';
    final batt = s == null
        ? '-'
        : '${s.battPct}%${s.charging ? '+' : ''} '
            '${s.battC.toStringAsFixed(1)}°C';
    // caption, value, width. The widths are the widest value each cell
    // can show, so the columns hold still from one second to the next.
    final cells = <(String, String, int)>[
      ('fps', '$fps', 3),
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
        ? 'held: hud.off is set on the card (tools/bench.sh does that for '
            'a scenes run)'
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
    return Container(
      height: 34,
      color: const Color(0xFF161A23),
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        children: [
          Expanded(child: widget.leading),
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
    );
  }
}
