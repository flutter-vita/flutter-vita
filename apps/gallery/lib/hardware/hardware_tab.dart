// The Hardware tab: does each piece of the console answer, and with what.
//
// The checks go through the pub packages an app author would use, each
// with its Vita implementation from packages/ registered in main:
// device_info_plus, battery_plus, connectivity_plus, sensors_plus,
// audioplayers, record, camera. What no package covers (storage, the
// clock, the controls, the touch panels, the console's volume) is a method
// on the `vita/hardware` channel, answered by templates/vita-app/hardware.c;
// the HTTP GET and the keyboard need no C at all. A check ends in one of
// four states: pass and fail where the numbers decide, `eye` where a person
// has to judge (a picture, a sound, a press nobody made), and `off` when
// the console has no such part.
//
// Three groups on three tabs. The automatic checks ask the console and read
// the answer; the cameras do the same and show their frames; the checks
// that need a person want a press, a touch or a typed line, and no script
// can supply those. Each tab has its own Run; one suite holds every row.
//
// Unattended: the host writes hardware.on and relaunches; the suite runs the
// automatic and camera groups and writes hardware-result.json and
// hardware-done. The checks that need a person are written as `skipped`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:battery_plus_vita/battery_plus_vita.dart';
import 'package:camera/camera.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:connectivity_plus_vita/connectivity_plus_vita.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:record_vita/record_vita.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../bench/runner.dart'
    show
        engineStamp,
        kDataDir,
        kHardwareDonePath,
        kHardwareResultPath,
        writeAtomic;
import 'loopback.dart';
import 'tone.dart';

enum CheckState { pending, running, pass, fail, eye, off, skipped }

/// Which tab a check lives on. `auto` and `camera` need nobody; `person`
/// needs something pressed, touched or typed.
enum HardwareGroup { auto, camera, person }

class HardwareCheck {
  HardwareCheck({
    required this.id,
    required this.title,
    required this.run,
    this.hint,
    this.group = HardwareGroup.auto,
  });

  final String id;
  final String title;
  final HardwareGroup group;

  /// Needs a person: something pressed, touched or typed.
  bool get manual => group == HardwareGroup.person;

  /// What a person should do while it runs, if anything.
  final String? hint;

  /// Runs the check; returns the state and one line of detail.
  final Future<(CheckState, String, Map<String, Object?>?)> Function() run;

  CheckState state = CheckState.pending;
  String detail = '';
  Map<String, Object?>? result;
}

class Hardware {
  static const _channel = MethodChannel('vita/hardware', JSONMethodCodec());

  /// One call; throws PlatformException with the C side's reason on failure.
  static Future<Map<String, Object?>> call(String method,
      [Map<String, Object?>? args]) async {
    final r = await _channel.invokeMethod<Object?>(method, args);
    if (r is Map) return r.map((k, v) => MapEntry(k.toString(), v));
    return {'value': r};
  }
}

/// Every check, its state, and the two things checks leave behind for the
/// screen (camera frames, the typed text). One per app, made by the Shell
/// and shown by three tabs, one per group, so the result file has every
/// check whichever tab ran last.
class HardwareSuite extends ChangeNotifier {
  HardwareSuite({bool autoRun = false}) {
    typed.addListener(notifyListeners);
    if (autoRun) {
      // Unattended: the groups that need nobody, then the file.
      unawaited(runGroups(const [HardwareGroup.auto, HardwareGroup.camera],
          writeFile: true));
    }
  }

  late final List<HardwareCheck> checks = _build();
  final typed = TextEditingController();
  ui.Image? front;
  ui.Image? back;
  var running = false;
  var status = '';

  /// The microphone's recording started by the tone check, read by the
  /// microphone check that follows it: one capture serves both.
  Future<String>? _micDuringTone;

  /// The console's volume before the tone check raised it, to put back.
  int? _volumeWas;

  @override
  void dispose() {
    typed.dispose();
    super.dispose();
  }

  Iterable<HardwareCheck> of(HardwareGroup g) =>
      checks.where((c) => c.group == g);

  // ---- the checks ----------------------------------------------------------

  static String _n(Object? v, [int digits = 1]) =>
      v is num ? v.toStringAsFixed(digits) : '$v';

  List<HardwareCheck> _build() => [
        HardwareCheck(
          id: 'model',
          title: 'console (device_info_plus)',
          run: () async {
            final info = await DeviceInfoPlugin().deviceInfo;
            final r = info.data;
            final code = (r['model_code'] as num?)?.toInt() ?? 0;
            return (
              code > 0 ? CheckState.pass : CheckState.fail,
              '${r['model']}, firmware ${r['firmware']}, ${r['title_id']}; '
                  'arm ${r['arm_mhz']} bus ${r['bus_mhz']} gpu ${r['gpu_mhz']} MHz',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'battery',
          title: 'battery (battery_plus)',
          run: () async {
            final battery = Battery();
            final level = await battery.batteryLevel;
            final state = await battery.batteryState;
            final s = await BatteryPlusVita.status();
            final r = <String, Object?>{
              ...s,
              'plugin_level': level,
              'plugin_state': state.name
            };
            return (
              level > 0 && level <= 100 ? CheckState.pass : CheckState.fail,
              '$level% ${state.name}, ${_n(s['temp_c'])}°C ${_n((s['volt_mv'] as num) / 1000, 2)} V, '
                  '${s['minutes']} min left',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'storage',
          title: 'storage',
          run: () async {
            final r = await Hardware.call('storage');
            final parts = <String>[];
            for (final e in r.entries) {
              final v = e.value;
              if (v is Map) {
                parts.add(
                    '${e.key} ${_n((v['free_mb'] as num) / 1024)} of ${_n((v['total_mb'] as num) / 1024)} GB free');
              }
            }
            return (
              r.containsKey('ux0:') ? CheckState.pass : CheckState.fail,
              parts.join(', '),
              r
            );
          },
        ),
        HardwareCheck(
          id: 'clock',
          title: 'clock',
          run: () async {
            final r = await Hardware.call('clock');
            final local = '${r['local']}';
            final year = int.tryParse(local.split('-').first) ?? 0;
            return (
              year >= 2020 ? CheckState.pass : CheckState.fail,
              '$local local, network time ${r['network_tick_ok'] == true ? 'known' : 'unknown'}, up ${r['uptime_s']} s',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'wifi',
          title: 'wi-fi (connectivity_plus)',
          run: () async {
            final results = await Connectivity().checkConnectivity();
            final s = await ConnectivityPlusVita.status();
            final r = <String, Object?>{
              ...s,
              'plugin_results': results.map((e) => e.name).toList()
            };
            final up = !results.contains(ConnectivityResult.none);
            return (
              up ? CheckState.pass : CheckState.fail,
              up
                  ? '${results.map((e) => e.name).join('+')}: ${s['ssid']} ${s['ip']} signal ${s['rssi_pct']}%'
                  : 'none (SceNetCtl state ${s['state']})',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'http',
          title: 'http over tls',
          run: () async {
            final sw = Stopwatch()..start();
            final client = HttpClient()
              ..connectionTimeout = const Duration(seconds: 10);
            try {
              final req = await client
                  .getUrl(Uri.parse('https://www.google.com/generate_204'));
              final res =
                  await req.close().timeout(const Duration(seconds: 15));
              await res.drain<void>();
              sw.stop();
              final ok = res.statusCode >= 200 && res.statusCode < 400;
              return (
                ok ? CheckState.pass : CheckState.fail,
                'GET generate_204 -> ${res.statusCode} in ${sw.elapsedMilliseconds} ms',
                {'status': res.statusCode, 'ms': sw.elapsedMilliseconds}
              );
            } finally {
              client.close(force: true);
            }
          },
        ),
        HardwareCheck(
          id: 'controls',
          group: HardwareGroup.person,
          title: 'buttons and sticks',
          hint: 'press any button or move a stick (5 s)',
          run: () async {
            var seen = 0;
            var sticks = false;
            Map<String, Object?> last = {};
            for (var i = 0; i < 50 && seen == 0 && !sticks; i++) {
              last = await Hardware.call('controls');
              final b = (last['buttons'] as num?)?.toInt() ?? 0;
              if (b != 0) seen |= b;
              for (final k in ['lx', 'ly', 'rx', 'ry']) {
                final v = (last[k] as num?)?.toInt() ?? 128;
                if ((v - 128).abs() > 40) sticks = true;
              }
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            final r = {...last, 'seen_buttons': seen, 'sticks_moved': sticks};
            if (seen != 0 || sticks) {
              return (
                CheckState.pass,
                'buttons 0x${seen.toRadixString(16)}${sticks ? ', sticks moved' : ''}',
                r
              );
            }
            return (CheckState.eye, 'answers; no press seen in 5 s', r);
          },
        ),
        HardwareCheck(
          id: 'touch',
          group: HardwareGroup.person,
          title: 'touch panels',
          hint: 'touch the back panel (5 s)',
          run: () async {
            var front = 0;
            var back = 0;
            Map<String, Object?> last = {};
            for (var i = 0; i < 50 && back == 0; i++) {
              last = await Hardware.call('touch');
              front += (last['front'] as num?)?.toInt() ?? 0;
              back += (last['back'] as num?)?.toInt() ?? 0;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            final r = {...last, 'front_samples': front, 'back_samples': back};
            if (back > 0) {
              return (
                CheckState.pass,
                'back panel: $back contact samples, front $front',
                r
              );
            }
            return (
              CheckState.eye,
              'both panels answer; no back contact in 5 s (front $front)',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'motion',
          title: 'gyro and accelerometer (sensors_plus)',
          run: () async {
            // The first samples come a moment after sampling starts; the
            // streams are asked for ten and the last one counts.
            const period = Duration(milliseconds: 50);
            final accel = await accelerometerEventStream(samplingPeriod: period)
                .take(10)
                .last
                .timeout(const Duration(seconds: 3));
            final gyro = await gyroscopeEventStream(samplingPeriod: period)
                .first
                .timeout(const Duration(seconds: 3));
            final mag = math.sqrt(
                accel.x * accel.x + accel.y * accel.y + accel.z * accel.z);
            final ok = mag > 6 && mag < 16; // about one g, in any orientation
            final r = <String, Object?>{
              'accel_ms2': [accel.x, accel.y, accel.z],
              'gyro': [gyro.x, gyro.y, gyro.z],
              'magnitude_ms2': mag,
            };
            return (
              ok ? CheckState.pass : CheckState.fail,
              'accel ${_n(accel.x, 2)} ${_n(accel.y, 2)} ${_n(accel.z, 2)} m/s² (|a| ${_n(mag / 9.80665, 2)} g) '
                  'gyro ${_n(gyro.x, 2)} ${_n(gyro.y, 2)} ${_n(gyro.z, 2)}',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'audio_tone',
          title: 'speaker: a tone (audioplayers)',
          hint: 'one second of 1 kHz, a WAV made here, through BytesSource',
          run: () async {
            // A console turned down cannot be tested: raised to 12 for the
            // two audio checks and put back by the microphone check.
            final v = await Hardware.call('volume');
            final was = (v['vol'] as num?)?.toInt() ?? -1;
            _volumeWas = null;
            if (was >= 0 && was < 5) {
              await Hardware.call('volume', {'set': 12});
              _volumeWas = was;
            }
            // The microphone records the same three seconds, for the check
            // after this one; the tone starts about a second in.
            _micDuringTone = _record(const Duration(seconds: 3));
            await Future<void>.delayed(const Duration(milliseconds: 500));
            final player = AudioPlayer();
            final errors = <Object>[];
            final sub = player.eventStream.listen((_) {}, onError: errors.add);
            final done = player.onPlayerComplete.first
                .timeout(const Duration(seconds: 3));
            // The source first (192 KB of WAV as base64 through the
            // channel), then the clock starts with the playback.
            await player.setSource(
                BytesSource(makeToneWav(1000, 1000), mimeType: 'audio/wav'));
            final sw = Stopwatch()..start();
            await player.resume();
            var completed = true;
            try {
              await done;
            } on TimeoutException {
              completed = false;
            }
            sw.stop();
            await sub.cancel();
            await player.dispose();
            // The port clocks the samples: a second of them takes a second
            // when the DAC is pulling them, plus up to 250 ms until the
            // poll sees the end. That is this check's verdict; the
            // microphone check after it says whether the sound came out.
            final took = sw.elapsedMilliseconds;
            final clocked = completed && took >= 900 && took <= 1400;
            final r = <String, Object?>{
              'took_ms': took,
              'completed': completed,
              'console_vol': _volumeWas == null ? was : 12,
              'raised': _volumeWas != null,
              'errors': errors.map((e) => '$e').toList(),
            };
            return (
              clocked && was != 0 && errors.isEmpty
                  ? CheckState.pass
                  : CheckState.fail,
              '${completed ? 'complete' : 'no complete event'} after $took ms at console volume '
                  '${_volumeWas == null ? was : '12 (was $was)'}/30'
                  '${errors.isEmpty ? '' : '; ${errors.first}'}',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'mic',
          title: 'microphone (record)',
          hint: 'three seconds of WAV while the tone plays',
          run: () async {
            final path =
                await (_micDuringTone ?? _record(const Duration(seconds: 3)));
            _micDuringTone = null;
            if (_volumeWas != null) {
              await Hardware.call('volume', {'set': _volumeWas});
              _volumeWas = null;
            }
            final wav = File(path).readAsBytesSync();
            final a = analyzeLoopback(wav, hz: 1000);
            final muted = await RecordVita.muted();
            final r = <String, Object?>{
              'path': path,
              'rate': a.sampleRate,
              'samples': a.samples,
              'peak': a.peak,
              'muted': muted,
              'blocks': a.blocks,
              'tone_blocks': a.toneBlocks,
              'snr_db': double.parse(a.snrDb.toStringAsFixed(1)),
              'tone_share': double.parse(a.toneShare.toStringAsFixed(2)),
            };
            if (a.silent) {
              return (
                CheckState.fail,
                'every one of ${a.samples} samples is zero (switch ${muted ? 'off' : 'on'}): '
                    'switch the microphone on in the quick menu (hold PS)',
                r
              );
            }
            // The loopback: the tone check played one second of 1 kHz
            // while this recording ran, and it is in the recording when the
            // speaker and the microphone both work (build 56: +70 dB at
            // 1 kHz over the room). A live microphone that hears the room
            // and not the tone points at the speaker.
            if (a.heard) {
              return (
                CheckState.pass,
                'the tone came through at +${_n(a.snrDb)} dB over the room, ${a.toneBlocks * 100} ms, '
                    'peak ${a.peak} of ${a.samples} samples at ${a.sampleRate} Hz',
                r
              );
            }
            return (
              CheckState.fail,
              'alive (peak ${a.peak}) but the tone is not in the recording '
                  '(+${_n(a.snrDb)} dB at 1 kHz): the speaker is silent, or the console is muted or turned down',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'audio_file',
          title: 'an AAC asset (audioplayers)',
          hint: 'three notes through AssetSource, decoded by the console',
          run: () async {
            // The decoder is the verdict; the microphone says whether the
            // room heard it, as a level rise in dB, for the record.
            final mic = _record(const Duration(seconds: 4));
            await Future<void>.delayed(const Duration(milliseconds: 400));
            // AAC in MP4: the container the console's player is for. The
            // same sound as MP3 got 0x806A0002 from AddSource on every
            // path (build 48); the player does not open that container.
            // AssetSource goes through AudioCache: the asset is copied to
            // the temp directory path_provider_vita names, and the copy
            // is what the player opens.
            final r = <String, Object?>{};
            var completed = false;
            var took = 0;
            for (final file in ['tone.m4a', 'tone.mp4']) {
              final player = AudioPlayer();
              final errors = <Object>[];
              final sub =
                  player.eventStream.listen((_) {}, onError: errors.add);
              final done = player.onPlayerComplete.first
                  .timeout(const Duration(seconds: 6));
              final sw = Stopwatch()..start();
              try {
                await player.play(AssetSource('hardware/$file'));
                await done;
                completed = true;
              } on Object catch (e) {
                errors.add(e);
              }
              sw.stop();
              took = sw.elapsedMilliseconds;
              r['file'] = file;
              r['duration_ms'] = (await player.getDuration())?.inMilliseconds;
              r['errors'] = errors.map((e) => '$e').toList();
              await sub.cancel();
              await player.dispose();
              if (completed) break;
              r['${file.split('.').last}_error'] =
                  errors.isEmpty ? 'no complete event' : '${errors.first}';
            }
            final path = await mic;
            var rise = 0.0;
            try {
              rise = levelRiseDb(File(path).readAsBytesSync());
            } on Object {
              // No recording is no verdict on the decoder.
            }
            r['took_ms'] = took;
            r['completed'] = completed;
            r['mic_rise_db'] = double.parse(rise.toStringAsFixed(1));
            return (
              completed ? CheckState.pass : CheckState.fail,
              '${r['file']}: ${completed ? 'played to the end' : 'did not complete'} in $took ms'
                  '${r['duration_ms'] != null ? ' (duration ${r['duration_ms']} ms)' : ''}; '
                  'the microphone heard +${_n(rise)} dB'
                  '${completed ? '' : '; ${(r['errors'] as List).join('; ')}'}',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'camera_front',
          group: HardwareGroup.camera,
          title: 'front camera (camera)',
          run: () => _camera(CameraLensDirection.front),
        ),
        HardwareCheck(
          id: 'camera_back',
          group: HardwareGroup.camera,
          title: 'back camera (camera)',
          run: () => _camera(CameraLensDirection.back),
        ),
        HardwareCheck(
          id: 'keyboard',
          group: HardwareGroup.person,
          title: 'keyboard',
          hint: 'tap the field on the right and type (20 s)',
          run: () async {
            // Whatever is in the field counts, typed before or during.
            for (var i = 0; i < 80 && typed.text.isEmpty; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
            final t = typed.text;
            if (t.isNotEmpty) {
              return (
                CheckState.pass,
                'typed ${t.length} characters',
                {'text': t}
              );
            }
            return (CheckState.eye, 'nothing typed in 20 s', null);
          },
        ),
      ];

  /// [d] of the microphone through `record`, as a WAV under the data
  /// directory; returns the path.
  static Future<String> _record(Duration d) async {
    final rec = AudioRecorder();
    try {
      await rec.start(const RecordConfig(encoder: AudioEncoder.wav),
          path: '$kDataDir/mic.wav');
      await Future<void>.delayed(d);
      return (await rec.stop())!;
    } finally {
      await rec.dispose();
    }
  }

  /// One camera through `camera`: a controller at the low preset, an
  /// image stream until thirty frames or 1.5 s, the last frame shown.
  Future<(CheckState, String, Map<String, Object?>?)> _camera(
      CameraLensDirection lens) async {
    final cameras = await availableCameras();
    final desc = cameras.where((c) => c.lensDirection == lens).firstOrNull;
    if (desc == null) {
      return (CheckState.off, 'no ${lens.name} camera on this console', null);
    }
    final controller =
        CameraController(desc, ResolutionPreset.low, enableAudio: false);
    final sw = Stopwatch()..start();
    try {
      await controller.initialize();
      final size = controller.value.previewSize!;
      // The sensor's exposure takes most of a second to settle from the
      // black it starts at (build 42 read frame 4 at 78 ms, and it was
      // black). Frames are taken until thirty have come or 1.5 s passed,
      // and the brightness along the way goes into the result.
      final means = <double>[];
      CameraImage? last;
      final done = Completer<void>();
      await controller.startImageStream((img) {
        last = img;
        means.add(_mean(img.planes.first.bytes, img.width, img.height));
        if (means.length >= 30 || sw.elapsedMilliseconds > 1500) {
          if (!done.isCompleted) done.complete();
        }
      });
      await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
      await controller.stopImageStream();
      sw.stop();
      final img = last;
      if (img == null) {
        return (
          CheckState.fail,
          'no frame in ${sw.elapsedMilliseconds} ms',
          null
        );
      }
      final bytes = img.planes.first.bytes;
      final image = await _decode(bytes, img.width, img.height);
      if (lens == CameraLensDirection.front) {
        front = image;
      } else {
        back = image;
      }
      notifyListeners();
      final (mean, sd) = _stats(bytes, img.width, img.height);
      final r = <String, Object?>{
        'width': img.width,
        'height': img.height,
        'preview': '${size.width.toInt()}x${size.height.toInt()}',
        'frames': means.length,
        'took_ms': sw.elapsedMilliseconds,
        'mean': double.parse(mean.toStringAsFixed(1)),
        'stddev': double.parse(sd.toStringAsFixed(1)),
        'mean_by_frame': [
          for (final m in means) double.parse(m.toStringAsFixed(1))
        ],
      };
      return (
        sd > 5 ? CheckState.pass : CheckState.eye,
        '${means.length} frames ${img.width}x${img.height} in ${sw.elapsedMilliseconds} ms, '
            'mean ${_n(mean)} sd ${_n(sd)}'
            '${sd > 5 ? '' : ' (flat: covered, or dark)'}',
        r
      );
    } finally {
      await controller.dispose();
    }
  }

  /// Mean of the green channel over a coarse grid.
  static double _mean(Uint8List rgba, int w, int h) => _stats(rgba, w, h).$1;

  /// Mean and standard deviation of the green channel over a 32x30 grid:
  /// a covered lens is under 5, a room in the hundreds.
  static (double, double) _stats(Uint8List rgba, int w, int h) {
    var sum = 0.0, sq = 0.0;
    var n = 0;
    for (var y = 0; y < h; y += 8) {
      for (var x = 0; x < w; x += 10) {
        final g = rgba[(y * w + x) * 4 + 1].toDouble();
        sum += g;
        sq += g * g;
        n++;
      }
    }
    if (n == 0) return (0, 0);
    final mean = sum / n;
    final v = sq / n - mean * mean;
    return (mean, math.sqrt(v < 0 ? 0 : v));
  }

  static Future<ui.Image> _decode(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  // ---- running -------------------------------------------------------------

  Future<void> runOne(HardwareCheck c) async {
    c.state = CheckState.running;
    c.detail = c.hint ?? '';
    status = c.title;
    notifyListeners();
    try {
      final (state, detail, result) =
          await c.run().timeout(const Duration(seconds: 30));
      c.state = state;
      c.detail = detail;
      c.result = result;
    } on PlatformException catch (e) {
      c.state = e.code == 'unavailable' ? CheckState.off : CheckState.fail;
      c.detail = e.message ?? e.code;
    } on Object catch (e) {
      c.state = CheckState.fail;
      c.detail = e.toString().replaceAll('\n', ' ');
      if (c.detail.length > 90) c.detail = '${c.detail.substring(0, 89)}…';
    }
    status = '';
    notifyListeners();
  }

  /// One or more groups, in order. The other groups' rows keep whatever
  /// state they have; a check never run in this session is written as
  /// `skipped`.
  Future<void> runGroups(List<HardwareGroup> groups,
      {required bool writeFile}) async {
    if (running) return;
    running = true;
    notifyListeners();
    for (final g in groups) {
      for (final c in of(g)) {
        await runOne(c);
      }
    }
    for (final c in checks) {
      if (c.state == CheckState.pending) {
        c.state = CheckState.skipped;
        c.detail = c.manual ? 'needs a person; not run' : 'not run';
      }
    }
    if (writeFile) writeResult();
    running = false;
    notifyListeners();
  }

  void writeResult() {
    try {
      final payload = <String, Object?>{
        'schema': 1,
        'suite': 'hardware',
        'taken': DateTime.now().toIso8601String(),
        if (engineStamp() case final String e) 'engine': e,
        for (final s in CheckState.values)
          s.name: checks.where((c) => c.state == s).length,
        'checks': [
          for (final c in checks)
            {
              'id': c.id,
              'group': c.group.name,
              'title': c.title,
              'state': c.state.name,
              'detail': c.detail,
              'result': c.result
            },
        ],
      };
      Directory(kDataDir).createSync(recursive: true);
      // A check's result map may carry what a number cannot be in JSON
      // (an infinite dB); the file is worth more than that one figure.
      writeAtomic(
          kHardwareResultPath,
          JsonEncoder.withIndent(
                  '  ', (o) => o is double && !o.isFinite ? null : o.toString())
              .convert(payload));
      File(kHardwareDonePath).writeAsStringSync('1', flush: true);
    } on Object catch (e) {
      // The screen still has every row; the log says why the file has not.
      print('hardware: result file not written: $e');
    }
  }

  String summary(HardwareGroup g) {
    final rows = of(g).toList();
    int n(CheckState st) => rows.where((c) => c.state == st).length;
    final parts = <String>[
      if (n(CheckState.pass) > 0) '${n(CheckState.pass)} pass',
      if (n(CheckState.fail) > 0) '${n(CheckState.fail)} fail',
      if (n(CheckState.eye) > 0) '${n(CheckState.eye)} by eye',
      if (n(CheckState.off) > 0) '${n(CheckState.off)} off',
      if (n(CheckState.skipped) > 0) '${n(CheckState.skipped)} not run',
    ];
    return parts.isEmpty ? '${rows.length} checks' : parts.join('  ·  ');
  }
}

/// One group of the suite on one tab: HARDWARE (the console answers),
/// CAMERAS (two frames, shown), MANUAL (a person presses, touches, types).
class HardwareTab extends StatelessWidget {
  const HardwareTab({super.key, required this.suite, required this.group});
  final HardwareSuite suite;
  final HardwareGroup group;

  static const _titles = {
    HardwareGroup.auto: ('AUTOMATIC', 'the console answers; nothing to do'),
    HardwareGroup.camera: (
      'CAMERAS',
      'a frame from each, after the exposure settles'
    ),
    HardwareGroup.person: ('NEEDS A PERSON', 'press, touch, type'),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: suite,
        builder: (context, _) {
          final rows = suite.of(group).toList();
          final (title, hint) = _titles[group]!;
          final busy = suite.running;
          final list = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 2, 4, 0),
                child: Text(
                  busy ? 'running: ${suite.status}' : suite.summary(group),
                  style:
                      const TextStyle(fontSize: 13, color: Color(0xFF9AA4B8)),
                ),
              ),
              const Divider(height: 1, color: Color(0xFF262B36)),
              Expanded(
                child: ListView(
                  children: [
                    _GroupHead(
                      title: title,
                      hint: hint,
                      count: rows.length,
                      onRun: busy
                          ? null
                          : () => suite.runGroups([group], writeFile: true),
                    ),
                    for (final c in rows)
                      _CheckRow(c, onRun: busy ? null : () => suite.runOne(c)),
                  ],
                ),
              ),
            ],
          );
          final side = switch (group) {
            HardwareGroup.auto => null,
            HardwareGroup.camera => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _frame('front', suite.front),
                  const SizedBox(height: 6),
                  _frame('back', suite.back),
                ],
              ),
            HardwareGroup.person => TextField(
                controller: suite.typed,
                decoration: const InputDecoration(
                  labelText: 'keyboard check',
                  hintText: 'type here',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
          };
          if (side == null) return list;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: list),
              const VerticalDivider(width: 1),
              SizedBox(
                width: group == HardwareGroup.camera ? 330 : 250,
                child: Padding(padding: const EdgeInsets.all(8), child: side),
              ),
            ],
          );
        },
      );

  static Widget _frame(String label, ui.Image? image) => Container(
        height: 236,
        color: const Color(0xFF0B0E14),
        child: image == null
            ? Center(
                child: Text('$label camera',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF5A6478))))
            : RawImage(image: image, fit: BoxFit.contain),
      );
}

class _GroupHead extends StatelessWidget {
  const _GroupHead({
    required this.title,
    required this.hint,
    required this.count,
    required this.onRun,
  });
  final String title;
  final String hint;
  final int count;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFF161A23),
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFC7CEDB))),
            const SizedBox(width: 10),
            Expanded(
              child: Text('$count checks  ·  $hint',
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF6B7488))),
            ),
            TextButton(
              onPressed: onRun,
              child: Text(onRun == null ? '…' : 'Run'),
            ),
          ],
        ),
      );
}

class _CheckRow extends StatelessWidget {
  const _CheckRow(this.check, {this.onRun});
  final HardwareCheck check;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    final (label, colour) = switch (check.state) {
      CheckState.pass => ('PASS', const Color(0xFF7BD88F)),
      CheckState.fail => ('FAIL', const Color(0xFFFF8A80)),
      CheckState.eye => ('EYE', const Color(0xFFFFD27F)),
      CheckState.off => ('OFF', const Color(0xFF5A6478)),
      CheckState.running => (' ...', const Color(0xFF9AA4B8)),
      CheckState.pending => ('  ·', const Color(0xFF5A6478)),
      CheckState.skipped => ('skip', const Color(0xFF5A6478)),
    };
    const mono = TextStyle(fontSize: 11, fontFamily: 'monospace');
    return InkWell(
      onTap: onRun,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 40,
                child: Text(label,
                    style: mono.copyWith(
                        fontWeight: FontWeight.bold, color: colour))),
            SizedBox(
                width: 190,
                child: Text(check.title,
                    style: mono.copyWith(color: const Color(0xFFC7CEDB)))),
            Expanded(
              child: Text(check.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(color: const Color(0xFF8B94A7))),
            ),
          ],
        ),
      ),
    );
  }
}
