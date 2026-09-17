import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

/// The Vita implementation of [RecordPlatform].
///
/// Non-endorsed: `record` does not know Vita exists, so an app depends on
/// this package alongside it and calls `RecordVita.registerWith()`.
///
/// The C half (`vita/record.c`) reads the console's microphone: 16 kHz,
/// mono, PCM16, whatever [RecordConfig] asks for; the WAV header says what
/// the file holds. Two encoders: [AudioEncoder.wav] and
/// [AudioEncoder.pcm16bits]. A stream ([startStream]) is polled from the
/// C side every 100 ms, in chunks of up to a second.
///
/// The console has no microphone permission; it has a switch in the quick
/// menu, and a recording made with the switch off is silence. [muted]
/// reads the switch.
class RecordVita extends RecordPlatform {
  static void registerWith() {
    RecordPlatform.instance = RecordVita();
  }

  static const MethodChannel _channel =
      MethodChannel('vita/record', JSONMethodCodec());

  /// The sample rate the console records at.
  static const int sampleRate = 16000;

  /// The console's own microphone switch (the quick menu, and Settings).
  /// With it off the port opens and every sample is zero.
  static Future<bool> muted() async =>
      (await _channel.invokeMethod<bool>('muted')) ?? false;

  final _state = <String, StreamController<RecordState>>{};
  final _streams = <String, _PcmStream>{};

  Future<T?> _call<T>(String method, String id, [Map<String, Object?>? args]) {
    return _channel.invokeMethod<T>(method, {'id': id, ...?args});
  }

  void _emit(String id, RecordState s) => _state[id]?.add(s);

  @override
  Future<void> create(String recorderId) async {
    _state.putIfAbsent(recorderId, StreamController<RecordState>.broadcast);
    await _call<void>('create', recorderId);
  }

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    if (!_supported(config.encoder)) {
      throw PlatformException(
        code: 'encoder',
        message: 'record_vita records WAV or raw PCM16, not ${config.encoder}',
      );
    }
    await _call<void>('start', recorderId, {
      'path': path,
      'wav': config.encoder == AudioEncoder.wav,
      'stream': false,
    });
    _emit(recorderId, RecordState.record);
  }

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    await _streams.remove(recorderId)?.close();
    await _call<void>('start', recorderId, {
      'path': '',
      'wav': false,
      'stream': true,
    });
    final s = _PcmStream(this, recorderId);
    _streams[recorderId] = s;
    _emit(recorderId, RecordState.record);
    return s.controller.stream;
  }

  Future<Uint8List?> _read(String id) async {
    final r = await _call<Map<Object?, Object?>>('read', id);
    final n = r?['samples'] as int? ?? 0;
    if (n == 0) return null;
    return base64Decode(r!['pcm'] as String);
  }

  @override
  Future<String?> stop(String recorderId) async {
    final r = await _call<Map<Object?, Object?>>('stop', recorderId);
    await _streams.remove(recorderId)?.close();
    _emit(recorderId, RecordState.stop);
    return r?['path'] as String?;
  }

  @override
  Future<void> pause(String recorderId) async {
    await _call<void>('pause', recorderId);
    _emit(recorderId, RecordState.pause);
  }

  @override
  Future<void> resume(String recorderId) async {
    await _call<void>('resume', recorderId);
    _emit(recorderId, RecordState.record);
  }

  Future<int> _stateOf(String id) async {
    final r = await _call<Map<Object?, Object?>>('state', id);
    return r?['state'] as int? ?? 0;
  }

  @override
  Future<bool> isRecording(String recorderId) async =>
      await _stateOf(recorderId) == 1;

  @override
  Future<bool> isPaused(String recorderId) async =>
      await _stateOf(recorderId) == 2;

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;

  @override
  Future<void> dispose(String recorderId) async {
    await _streams.remove(recorderId)?.close();
    await _call<void>('dispose', recorderId);
    await _state.remove(recorderId)?.close();
  }

  @override
  Future<Amplitude> getAmplitude(String recorderId) async {
    final r = await _call<Map<Object?, Object?>>('amplitude', recorderId);
    return Amplitude(
      current: (r?['current'] as num?)?.toDouble() ?? -160,
      max: (r?['max'] as num?)?.toDouble() ?? -160,
    );
  }

  static bool _supported(AudioEncoder e) =>
      e == AudioEncoder.wav || e == AudioEncoder.pcm16bits;

  @override
  Future<bool> isEncoderSupported(
          String recorderId, AudioEncoder encoder) async =>
      _supported(encoder);

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async => const [
        InputDevice(id: 'mic', label: 'Built-in microphone'),
      ];

  @override
  Future<void> cancel(String recorderId) async {
    await _streams.remove(recorderId)?.close();
    await _call<void>('cancel', recorderId);
    _emit(recorderId, RecordState.stop);
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) => _state
      .putIfAbsent(recorderId, StreamController<RecordState>.broadcast)
      .stream;
}

class _PcmStream {
  _PcmStream(this.owner, this.id) {
    controller = StreamController<Uint8List>(
      // The listener let go: the recording ends. Not on our own close,
      // which follows a stop already made.
      onCancel: () => _closing ? null : owner.stop(id),
    );
    timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _poll());
  }

  final RecordVita owner;
  final String id;
  late final StreamController<Uint8List> controller;
  late final Timer timer;
  bool _busy = false;
  bool _closing = false;

  Future<void> _poll() async {
    if (_busy || controller.isClosed) return;
    _busy = true;
    try {
      final bytes = await owner._read(id);
      if (bytes != null && !controller.isClosed) controller.add(bytes);
    } catch (e) {
      if (!controller.isClosed) controller.addError(e);
    } finally {
      _busy = false;
    }
  }

  Future<void> close() async {
    _closing = true;
    timer.cancel();
    if (!controller.isClosed) await controller.close();
  }
}
