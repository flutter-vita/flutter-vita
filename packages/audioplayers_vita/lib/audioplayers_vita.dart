import 'dart:async';
import 'dart:convert';

import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/services.dart';

/// The Vita implementation of [AudioplayersPlatformInterface] and
/// [GlobalAudioplayersPlatformInterface].
///
/// Non-endorsed: `audioplayers` does not know Vita exists, so an app depends
/// on this package alongside it and calls `AudioplayersVita.registerWith()`.
///
/// The C half (`vita/audioplayers.c`) plays two kinds of source: WAV, from
/// bytes or a file, through a MAIN port (eight players at once); and AAC in
/// an MP4 or M4A box through the console's own player and the one BGM port
/// (one at a time). MP3 the console's player refuses; there is no network
/// source. `UrlSource` takes a device path (`app0:/...`, `ux0:...`);
/// `AssetSource` and `BytesSource` work as on any platform.
///
/// The console has no event channel, so each player is polled four times a
/// second for its state, position and event counters, and the counters'
/// increments become [AudioEvent]s.
class AudioplayersVita extends AudioplayersPlatformInterface {
  static void registerWith() {
    AudioplayersPlatformInterface.instance = AudioplayersVita();
    GlobalAudioplayersPlatformInterface.instance = GlobalAudioplayersVita();
  }

  static const MethodChannel channel =
      MethodChannel('vita/audioplayers', JSONMethodCodec());

  final _players = <String, _Player>{};

  Future<T?> _call<T>(String method, String id, [Map<String, Object?>? args]) {
    return channel.invokeMethod<T>(method, {'id': id, ...?args});
  }

  _Player _player(String id) =>
      _players.putIfAbsent(id, () => _Player(this, id));

  @override
  Future<void> create(String playerId) async {
    await _call<void>('create', playerId);
    _player(playerId).start();
  }

  @override
  Future<void> dispose(String playerId) async {
    await _players.remove(playerId)?.close();
    await _call<void>('dispose', playerId);
  }

  @override
  Future<void> pause(String playerId) => _call<void>('pause', playerId);

  @override
  Future<void> stop(String playerId) => _call<void>('stop', playerId);

  @override
  Future<void> resume(String playerId) => _call<void>('resume', playerId);

  @override
  Future<void> release(String playerId) => _call<void>('release', playerId);

  @override
  Future<void> seek(String playerId, Duration position) =>
      _call<void>('seek', playerId, {'ms': position.inMilliseconds});

  @override
  Future<void> setBalance(String playerId, double balance) =>
      _call<void>('setBalance', playerId, {'balance': balance});

  @override
  Future<void> setVolume(String playerId, double volume) =>
      _call<void>('setVolume', playerId, {'volume': volume});

  @override
  Future<void> setReleaseMode(String playerId, ReleaseMode releaseMode) =>
      _call<void>('setReleaseMode', playerId, {'mode': releaseMode.index});

  @override
  Future<void> setPlaybackRate(String playerId, double playbackRate) async {
    // Neither port resamples on the way out; the rate stays 1.
    _player(playerId).log('setPlaybackRate: the console plays at 1.0 only');
  }

  @override
  Future<void> setSourceUrl(
    String playerId,
    String url, {
    bool? isLocal,
    String? mimeType,
  }) async {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      throw PlatformException(
        code: 'source',
        message: 'audioplayers_vita plays device files, not URLs: $url',
      );
    }
    await _setSource(playerId, {'url': url, 'mime': mimeType ?? ''});
  }

  @override
  Future<void> setSourceBytes(
    String playerId,
    Uint8List bytes, {
    String? mimeType,
  }) =>
      _setSource(playerId, {
        'bytes': base64Encode(bytes),
        'mime': mimeType ?? '',
      });

  Future<void> _setSource(String id, Map<String, Object?> args) async {
    await _call<Map<Object?, Object?>>('setSource', id, args);
    // The periodic poll would see `prepared` and the duration too; this
    // way the events precede the returned future, as audioplayers expects.
    await _player(id).poll(force: true);
  }

  @override
  Future<void> setAudioContext(
      String playerId, AudioContext audioContext) async {}

  @override
  Future<void> setPlayerMode(String playerId, PlayerMode playerMode) async {}

  // audioplayers asks for the position once a frame while playing. A poll
  // is a channel call and a thread on the console, so one answers for
  // 100 ms: the position moves in 16 ms grains anyway.
  @override
  Future<int?> getDuration(String playerId) async =>
      (await _player(playerId).poll())?['dur'] as int?;

  @override
  Future<int?> getCurrentPosition(String playerId) async =>
      (await _player(playerId).poll())?['pos'] as int?;

  @override
  Future<void> emitLog(String playerId, String message) async =>
      _player(playerId).log(message);

  @override
  Future<void> emitError(String playerId, String code, String message) async =>
      _player(playerId).error(code, message);

  @override
  Stream<AudioEvent> getEventStream(String playerId) =>
      _player(playerId).events.stream;
}

class _Player {
  _Player(this.owner, this.id);

  final AudioplayersVita owner;
  final String id;
  final events = StreamController<AudioEvent>.broadcast();
  Timer? _timer;
  Future<Map<Object?, Object?>?>? _inFlight;
  Map<Object?, Object?>? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _prepared = 0, _complete = 0, _seek = 0, _err = 0;
  int? _duration;

  void start() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 250), (_) => poll());
  }

  void emit(AudioEvent e) {
    if (!events.isClosed) events.add(e);
  }

  void log(String message) =>
      emit(AudioEvent(eventType: AudioEventType.log, logMessage: message));

  void error(String code, String message) {
    if (!events.isClosed) {
      events.addError(PlatformException(code: code, message: message));
    }
  }

  /// The player's state now, or the answer of the last 100 ms unless
  /// [force]; one call in flight at a time.
  Future<Map<Object?, Object?>?> poll({bool force = false}) {
    if (events.isClosed) return Future.value(_last);
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    if (!force &&
        _last != null &&
        DateTime.now().difference(_lastAt) <
            const Duration(milliseconds: 100)) {
      return Future.value(_last);
    }
    return _inFlight = _poll().whenComplete(() => _inFlight = null);
  }

  Future<Map<Object?, Object?>?> _poll() async {
    try {
      final r = await owner._call<Map<Object?, Object?>>('poll', id);
      if (r == null) return null;
      _last = r;
      _lastAt = DateTime.now();
      final prepared = r['prepared'] as int;
      final complete = r['complete'] as int;
      final seek = r['seek'] as int;
      final err = r['err'] as int;
      final dur = r['dur'] as int?;
      if (dur != null && dur != _duration) {
        _duration = dur;
        emit(
          AudioEvent(
            eventType: AudioEventType.duration,
            duration: Duration(milliseconds: dur),
          ),
        );
      }
      if (prepared != _prepared) {
        _prepared = prepared;
        emit(const AudioEvent(
            eventType: AudioEventType.prepared, isPrepared: true));
      }
      if (seek != _seek) {
        _seek = seek;
        emit(const AudioEvent(eventType: AudioEventType.seekComplete));
      }
      if (complete != _complete) {
        _complete = complete;
        emit(const AudioEvent(eventType: AudioEventType.complete));
      }
      if (err != 0 && err != _err) {
        _err = err;
        error('VitaAudioError',
            '${r['err_what']}: 0x${(err & 0xffffffff).toRadixString(16)}');
      }
      return r;
    } catch (e) {
      if (!events.isClosed) events.addError(e);
      return null;
    }
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await events.close();
  }
}

/// The global half: nothing to initialise on the console, and no global
/// audio context to set.
class GlobalAudioplayersVita extends GlobalAudioplayersPlatformInterface {
  final _events = StreamController<GlobalAudioEvent>.broadcast();

  @override
  Future<void> init() async {}

  @override
  Future<void> setGlobalAudioContext(AudioContext ctx) async {}

  @override
  Future<void> emitGlobalLog(String message) async => _events.add(
        GlobalAudioEvent(
            eventType: GlobalAudioEventType.log, logMessage: message),
      );

  @override
  Future<void> emitGlobalError(String code, String message) async =>
      _events.addError(PlatformException(code: code, message: message));

  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => _events.stream;
}
