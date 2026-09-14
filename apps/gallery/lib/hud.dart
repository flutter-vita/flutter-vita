// The strip above every tab: what the console is doing this second.
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
// The strip stays on screen while a benchmark scene runs, and holds still.
// Live, its once-a-second frame cost the scenes: run 35 of the gallery, with
// the strip ticking through the scenes, had 23 stalled scenes and a stall
// sum of 7.9 s; run 36, same build with the strip frozen (hud.off), had 16
// and 5.6 s, the best on record. So the tick pauses while a scene owns the
// stage and the numbers shown are the last second before it began; the
// title above them stays live and names the scene.

import 'dart:async';

import 'package:flutter/foundation.dart';
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
    required this.heapMb,
    required this.armMhz,
    required this.gpuMhz,
  });

  final List<int> cpuIdle;
  final int gpuPct;
  final int gpuUs;
  final double battC;
  final int battPct;
  final bool charging;
  final int memUserK;
  final int memCdramK;
  final int heapMb;
  final int armMhz;
  final int gpuMhz;

  static VitaStats? fromMap(Object? m) {
    if (m is! Map) return null;
    int i(String k) => (m[k] as num?)?.toInt() ?? 0;
    return VitaStats(
      cpuIdle: [
        for (final v in (m['cpu_idle'] as List? ?? const [])) (v as num).toInt()
      ],
      gpuPct: i('gpu_pct'),
      gpuUs: i('gpu_us'),
      battC: (m['batt_c'] as num?)?.toDouble() ?? 0,
      battPct: i('batt_pct'),
      charging: m['charging'] == true,
      memUserK: i('mem_user_k'),
      memCdramK: i('mem_cdram_k'),
      heapMb: i('heap_mb'),
      armMhz: i('arm_mhz'),
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
    required this.paused,
    this.frozen = false,
  });

  /// Drawn at the left of the strip: the title.
  final Widget leading;

  /// While true the tick does nothing: no channel read, no rebuild. The
  /// Shell hands in "a scene owns the stage".
  final ValueListenable<bool> paused;

  /// No timer, no channel: the strip shows dashes and costs nothing. A
  /// switch on the card (hud.off) sets it, so a bench run can say what the
  /// live strip costs a scene without a rebuild.
  final bool frozen;

  @override
  State<HudStrip> createState() => _HudStripState();
}

class _HudStripState extends State<HudStrip> {
  final _window = FrameWindow();
  FrameWindow _shown = FrameWindow();
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
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _second());
  }

  Future<void> _second() async {
    if (widget.paused.value) {
      // Not counted either: a window that spans a scene would show the
      // scene's frame rate for a second after it, as if it were the tab's.
      _window
        ..frames = 0
        ..buildMs = 0
        ..rasterMs = 0;
      return;
    }
    final sw = Stopwatch()..start();
    final stats = await VitaStatsChannel.read();
    _readUs = sw.elapsedMicroseconds;
    if (!mounted) return;
    _tickPending = true;
    setState(() {
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

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final fps = _shown.frames;
    final cpu = s == null
        ? '- - - -'
        : s.cpuIdle.map((i) => '${100 - i}'.padLeft(2)).join(' ');
    final gpu = s == null
        ? '-'
        : '${s.gpuPct}% ${(s.gpuUs / 1000).toStringAsFixed(1)}ms';
    final batt = s == null
        ? '-'
        : '${s.battC.toStringAsFixed(1)}°C batt ${s.battPct}%${s.charging ? '+' : ''}';
    final mem = s == null
        ? ''
        : ' | ram ${s.memUserK ~/ 1024}M cdram ${s.memCdramK ~/ 1024}M';
    const style = TextStyle(
        fontSize: 10, fontFamily: 'monospace', color: Color(0xFF9AA4B8));
    return Container(
      height: 30,
      color: const Color(0xFF161A23),
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        children: [
          Expanded(child: widget.leading),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$fps fps  ui ${_shown.buildMs.toStringAsFixed(1)}  '
                'ras ${_shown.rasterMs.toStringAsFixed(1)} ms | gpu $gpu',
                style: style,
              ),
              Text('cpu $cpu % | $batt$mem', style: style),
            ],
          ),
        ],
      ),
    );
  }
}
