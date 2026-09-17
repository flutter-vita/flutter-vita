import 'dart:async';

import 'package:flutter/services.dart';
import 'package:sensors_plus_platform_interface/sensors_plus_platform_interface.dart';

/// The Vita implementation of [SensorsPlatform].
///
/// Non-endorsed: `sensors_plus` does not know Vita exists, so an app depends
/// on this package alongside it and calls `SensorsPlusVita.registerWith()`.
///
/// The C half (`vita/sensors.c`) reads SceMotion's raw accelerometer and
/// gyroscope on demand. One poller serves every open stream, at the
/// shortest period asked for (16 ms at the least); each tick is one channel
/// call. The console has no magnetometer or barometer an app can read, so
/// those streams throw [UnsupportedError].
class SensorsPlusVita extends SensorsPlatform {
  static void registerWith() {
    SensorsPlatform.instance = SensorsPlusVita();
  }

  static const MethodChannel _channel =
      MethodChannel('vita/sensors', JSONMethodCodec());

  /// Standard gravity; the console reports the accelerometer in g.
  static const double g = 9.80665;

  final _accel = _Feed<AccelerometerEvent>();
  final _gyro = _Feed<GyroscopeEvent>();
  final _user = _Feed<UserAccelerometerEvent>();

  Timer? _timer;
  Duration _period = SensorInterval.normalInterval;
  bool _started = false;
  bool _reading = false;

  // Gravity as seen by the accelerometer, low-passed, for the user
  // accelerometer (Android's own recipe, alpha 0.8).
  double _gx = 0, _gy = 0, _gz = 0;

  @override
  Stream<AccelerometerEvent> accelerometerEventStream({
    Duration samplingPeriod = SensorInterval.normalInterval,
  }) =>
      _accel.stream(this, samplingPeriod);

  @override
  Stream<GyroscopeEvent> gyroscopeEventStream({
    Duration samplingPeriod = SensorInterval.normalInterval,
  }) =>
      _gyro.stream(this, samplingPeriod);

  @override
  Stream<UserAccelerometerEvent> userAccelerometerEventStream({
    Duration samplingPeriod = SensorInterval.normalInterval,
  }) =>
      _user.stream(this, samplingPeriod);

  @override
  Stream<MagnetometerEvent> magnetometerEventStream({
    Duration samplingPeriod = SensorInterval.normalInterval,
  }) =>
      throw UnsupportedError(
        'the console has no magnetometer an app can read as a vector',
      );

  @override
  Stream<BarometerEvent> barometerEventStream({
    Duration samplingPeriod = SensorInterval.normalInterval,
  }) =>
      throw UnsupportedError('the console has no barometer');

  void _listeners() {
    final wanted = [_accel, _gyro, _user].where((f) => f.listening).toList();
    if (wanted.isEmpty) {
      _timer?.cancel();
      _timer = null;
      if (_started) {
        _started = false;
        _channel.invokeMethod<void>('stop');
      }
      return;
    }
    var period = wanted.map((f) => f.period).reduce((a, b) => a < b ? a : b);
    if (period < const Duration(milliseconds: 16)) {
      period = const Duration(milliseconds: 16);
    }
    if (_timer != null && period == _period) return;
    _period = period;
    _timer?.cancel();
    _timer = Timer.periodic(period, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_reading) return; // the previous read is still on its way
    _reading = true;
    try {
      if (!_started) {
        await _channel.invokeMethod<void>('start');
        _started = true;
      }
      final r = (await _channel.invokeMethod<Map<Object?, Object?>>('read'))!;
      final now = DateTime.now();
      final ax = (r['ax'] as num).toDouble() * g;
      final ay = (r['ay'] as num).toDouble() * g;
      final az = (r['az'] as num).toDouble() * g;
      if (_accel.listening) _accel.add(AccelerometerEvent(ax, ay, az, now));
      if (_gyro.listening) {
        _gyro.add(
          GyroscopeEvent(
            (r['gx'] as num).toDouble(),
            (r['gy'] as num).toDouble(),
            (r['gz'] as num).toDouble(),
            now,
          ),
        );
      }
      if (_user.listening) {
        const alpha = 0.8;
        _gx = alpha * _gx + (1 - alpha) * ax;
        _gy = alpha * _gy + (1 - alpha) * ay;
        _gz = alpha * _gz + (1 - alpha) * az;
        _user.add(UserAccelerometerEvent(ax - _gx, ay - _gy, az - _gz, now));
      }
    } catch (e) {
      for (final f in [_accel, _gyro, _user]) {
        if (f.listening) f.addError(e);
      }
    } finally {
      _reading = false;
    }
  }
}

class _Feed<T> {
  StreamController<T>? _controller;
  Duration period = SensorInterval.normalInterval;

  bool get listening => _controller?.hasListener ?? false;

  Stream<T> stream(SensorsPlusVita owner, Duration samplingPeriod) {
    period = samplingPeriod;
    _controller ??= StreamController<T>.broadcast(
      onListen: owner._listeners,
      onCancel: owner._listeners,
    );
    return _controller!.stream;
  }

  void add(T event) => _controller?.add(event);
  void addError(Object e) => _controller?.addError(e);
}
