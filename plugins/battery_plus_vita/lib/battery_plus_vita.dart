import 'dart:async';

import 'package:battery_plus_platform_interface/battery_plus_platform_interface.dart';
import 'package:flutter/services.dart';

/// The Vita implementation of [BatteryPlatform].
///
/// Non-endorsed: `battery_plus` does not know Vita exists, so an app depends
/// on this package alongside it and calls `BatteryPlusVita.registerWith()`.
///
/// The C half (`vita/battery.c`, compiled into the app by
/// tools/build-vita-app.sh) answers one method, `status`, from ScePower. The
/// console has no battery-state notification, so [onBatteryStateChanged]
/// polls every two seconds while someone listens.
class BatteryPlusVita extends BatteryPlatform {
  static void registerWith() {
    BatteryPlatform.instance = BatteryPlusVita();
  }

  static const MethodChannel _channel =
      MethodChannel('vita/battery', JSONMethodCodec());

  /// Everything the console says: `level` (0..100), `charging`, `online`
  /// (external power), `low`, `minutes` left, `temp_c`, `volt_mv`.
  static Future<Map<String, Object?>> status() async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('status');
    return r!.cast<String, Object?>();
  }

  @override
  Future<int> get batteryLevel async => (await status())['level'] as int;

  @override
  Future<bool> get isInBatterySaveMode async => false;

  @override
  Future<BatteryState> get batteryState async => _state(await status());

  static BatteryState _state(Map<String, Object?> s) {
    final online = s['online'] == true;
    final charging = s['charging'] == true;
    final level = s['level'] as int;
    if (charging) return BatteryState.charging;
    if (online && level >= 100) return BatteryState.full;
    if (online) return BatteryState.connectedNotCharging;
    return BatteryState.discharging;
  }

  Stream<BatteryState>? _changes;

  @override
  Stream<BatteryState> get onBatteryStateChanged {
    return _changes ??= () {
      late final StreamController<BatteryState> c;
      Timer? timer;
      BatteryState? last;
      Future<void> tick() async {
        final s = _state(await status());
        if (s != last) {
          last = s;
          c.add(s);
        }
      }

      c = StreamController<BatteryState>.broadcast(
        onListen: () {
          tick();
          timer = Timer.periodic(const Duration(seconds: 2), (_) => tick());
        },
        onCancel: () {
          timer?.cancel();
          timer = null;
          last = null;
        },
      );
      return c.stream;
    }();
  }
}
