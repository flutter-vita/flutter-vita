import 'package:flutter/services.dart';

/// One window of frames, as the framework timed them.
class FrameWindow {
  int frames = 0;
  double buildMs = 0;
  double rasterMs = 0;
}

/// What the embedder knows about the console this second, over `vita/stats`.
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
        for (final v in (m['cpu_idle'] as List? ?? const []))
          (v as num).toInt(),
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

/// Reads the embedder's stats channel.
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
