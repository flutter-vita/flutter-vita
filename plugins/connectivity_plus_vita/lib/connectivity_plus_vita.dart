import 'dart:async';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/services.dart';

/// The Vita implementation of [ConnectivityPlatform].
///
/// Non-endorsed: `connectivity_plus` does not know Vita exists, so an app
/// depends on this package alongside it and calls
/// `ConnectivityPlusVita.registerWith()`.
///
/// The C half (`vita/connectivity.c`) asks SceNetCtl. The console has one
/// link: Wi-Fi, or the PS TV's Ethernet port. There is no change
/// notification an app can subscribe to, so [onConnectivityChanged] polls
/// every two seconds while someone listens.
class ConnectivityPlusVita extends ConnectivityPlatform {
  static void registerWith() {
    ConnectivityPlatform.instance = ConnectivityPlusVita();
  }

  static const MethodChannel _channel =
      MethodChannel('vita/connectivity', JSONMethodCodec());

  /// The raw answer: `state` (SceNetCtl's, 3 is connected), `connected`,
  /// `device` (0 wireless, 1 wired), `ip`, `ssid`, `rssi_pct`.
  static Future<Map<String, Object?>> status() async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('check');
    return r!.cast<String, Object?>();
  }

  static List<ConnectivityResult> _results(Map<String, Object?> s) {
    if (s['connected'] != true) return const [ConnectivityResult.none];
    return [
      s['device'] == 1 ? ConnectivityResult.ethernet : ConnectivityResult.wifi,
    ];
  }

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      _results(await status());

  Stream<List<ConnectivityResult>>? _changes;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    return _changes ??= () {
      late final StreamController<List<ConnectivityResult>> c;
      Timer? timer;
      List<ConnectivityResult>? last;
      Future<void> tick() async {
        final now = _results(await status());
        if (last == null || now.first != last!.first) {
          last = now;
          c.add(now);
        }
      }

      c = StreamController<List<ConnectivityResult>>.broadcast(
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
