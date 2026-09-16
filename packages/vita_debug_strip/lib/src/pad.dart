import 'dart:async';

import 'package:flutter/services.dart';

/// The console's buttons, as `SceCtrlButtons` numbers them.
abstract final class VitaButtons {
  static const int select = 0x000001;
  static const int l3 = 0x000002;
  static const int r3 = 0x000004;
  static const int start = 0x000008;
  static const int up = 0x000010;
  static const int right = 0x000020;
  static const int down = 0x000040;
  static const int left = 0x000080;
  static const int l = 0x000100;
  static const int r = 0x000200;
  static const int l1 = 0x000400;
  static const int r1 = 0x000800;
  static const int triangle = 0x001000;
  static const int circle = 0x002000;
  static const int cross = 0x004000;
  static const int square = 0x008000;

  static String describe(int mask) {
    const names = {
      select: 'SELECT',
      start: 'START',
      up: 'up',
      right: 'right',
      down: 'down',
      left: 'left',
      l: 'L',
      r: 'R',
      triangle: '△',
      circle: '○',
      cross: '✕',
      square: '□',
    };
    return [
      for (final e in names.entries)
        if (mask & e.key != 0) e.value,
    ].join('+');
  }
}

/// One reading of the controller.
class VitaPadState {
  const VitaPadState(this.buttons, this.lx, this.ly, this.rx, this.ry);
  final int buttons;
  final int lx, ly, rx, ry;
  bool pressed(int mask) => buttons & mask == mask;
}

/// The controller over `vita/pad` (the package's C half).
abstract final class VitaPad {
  static const _channel = MethodChannel('vita/pad', JSONMethodCodec());

  static Future<VitaPadState> read() async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('read');
    int i(String k) => (r?[k] as num?)?.toInt() ?? 0;
    return VitaPadState(i('buttons'), i('lx'), i('ly'), i('rx'), i('ry'));
  }

  /// Completes true when every button in [mask] is down after being up,
  /// false after [timeout]. One call parks one thread on the console.
  static Future<bool> waitChord(
    int mask, {
    Duration timeout = const Duration(seconds: 14),
  }) async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('waitChord', {
      'mask': mask,
      'ms': timeout.inMilliseconds,
    });
    return r?['pressed'] == true;
  }

  /// Every press of [mask], for as long as someone listens.
  static Stream<void> chord(int mask) {
    late final StreamController<void> c;
    var on = false;
    Future<void> loop() async {
      while (on) {
        try {
          if (await waitChord(mask) && on) c.add(null);
        } on MissingPluginException {
          // No C half in this build: nothing will ever press it.
          return;
        } on PlatformException {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }

    c = StreamController<void>.broadcast(
      onListen: () {
        on = true;
        loop();
      },
      onCancel: () => on = false,
    );
    return c.stream;
  }
}
