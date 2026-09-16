// The Hardware tab: does each piece of the console answer, and with what.
//
// Every check is one method on the `vita/hardware` channel, answered by
// templates/vita-app/hardware.c, plus two that need no C (an HTTP GET, the
// keyboard). A check ends in one of four states: pass and fail where the
// numbers decide, `eye` where a person has to judge (a picture, a sound, a
// press nobody made), and `off` when this build has no hardware.c.
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
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bench/runner.dart'
    show
        engineStamp,
        kDataDir,
        kHardwareDonePath,
        kHardwareResultPath,
        writeAtomic;
import 'loopback.dart';

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
  Future<Map<String, Object?>>? _micDuringTone;

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
          title: 'console',
          run: () async {
            final r = await Hardware.call('model');
            final model = (r['model'] as num?)?.toInt() ?? 0;
            final name = model == 0x10000
                ? 'Vita'
                : model == 0x20000
                    ? 'PS TV'
                    : 'model 0x${model.toRadixString(16)}';
            return (
              model > 0 ? CheckState.pass : CheckState.fail,
              '$name, firmware ${r['firmware']}',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'battery',
          title: 'battery and clocks',
          run: () async {
            final r = await Hardware.call('battery');
            return (
              CheckState.pass,
              '${r['pct']}% ${_n(r['temp_c'])}°C ${_n((r['volt_mv'] as num) / 1000, 2)} V'
                  '${r['charging'] == true ? ' charging' : ''}, ${r['remaining_min']} min left; '
                  'arm ${r['arm_mhz']} bus ${r['bus_mhz']} gpu ${r['gpu_mhz']} MHz',
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
          title: 'wi-fi',
          run: () async {
            final r = await Hardware.call('network');
            final up = r['connected'] == true;
            return (
              up ? CheckState.pass : CheckState.fail,
              up
                  ? '${r['ssid']} ${r['ip']} signal ${r['rssi_pct']}%'
                  : 'not connected (state ${r['state']})',
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
            if (back > 0)
              return (
                CheckState.pass,
                'back panel: $back contact samples, front $front',
                r
              );
            return (
              CheckState.eye,
              'both panels answer; no back contact in 5 s (front $front)',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'motion',
          title: 'gyro and accelerometer',
          run: () async {
            final r = await Hardware.call('motion');
            final a = (r['accel'] as List).cast<num>();
            final g = (r['gyro'] as List).cast<num>();
            final mag = a.fold<double>(0, (s, v) => s + v * v);
            final ok =
                mag > 0.6 && mag < 1.6; // about one g, in any orientation
            return (
              ok ? CheckState.pass : CheckState.fail,
              'accel ${a.map((v) => _n(v, 2)).join(' ')} (|a| ${_n(mag, 2)} g) gyro ${g.map((v) => _n(v, 2)).join(' ')}',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'audio_tone',
          title: 'speaker: a tone',
          hint: 'one second of 1 kHz at 48 kHz through the main port',
          run: () async {
            // The microphone records the same two seconds, for the check
            // after this one; the tone starts half a second in.
            _micDuringTone = Hardware.call('mic', {'ms': 2000});
            await Future<void>.delayed(const Duration(milliseconds: 500));
            final r =
                await Hardware.call('audioTone', {'hz': 1000, 'ms': 1000});
            // The port clocks the samples: 50 grains of 20 ms take 1000 ms
            // when the DAC is pulling them, and a port nobody drives would
            // return at once or fail. That is this check's verdict; the
            // microphone check after it says whether the sound came out.
            final took = (r['took_ms'] as num?)?.toInt() ?? 0;
            final vol = (r['console_vol'] as num?)?.toInt() ?? -1;
            final clocked = took >= 900 && took <= 1200;
            return (
              clocked && vol != 0 ? CheckState.pass : CheckState.fail,
              'port ${r['port']} clocked ${r['grains']} grains in $took ms at console volume $vol/30'
                  '${r['raised'] == true ? ' (12 for the tone)' : ''}'
                  '${clocked ? '' : '; the port did not clock the samples'}',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'mic',
          title: 'microphone',
          hint: 'two seconds from the RAW port while the tone plays',
          run: () async {
            final m =
                await (_micDuringTone ?? Hardware.call('mic', {'ms': 2000}));
            _micDuringTone = null;
            final wav = File('${m['path']}').readAsBytesSync();
            final a = analyzeLoopback(wav, hz: 1000);
            final r = <String, Object?>{
              ...m,
              'blocks': a.blocks,
              'tone_blocks': a.toneBlocks,
              'snr_db': double.parse(a.snrDb.toStringAsFixed(1)),
              'tone_share': double.parse(a.toneShare.toStringAsFixed(2)),
            };
            if (a.silent) {
              return (
                CheckState.fail,
                'every one of ${a.samples} samples is zero (mute status ${m['status']}): '
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
                    'peak ${a.peak}; room noise rms ${m['rms']}',
                r
              );
            }
            return (
              CheckState.fail,
              'alive (peak ${a.peak}, rms ${m['rms']}) but the tone is not in the recording '
                  '(+${_n(a.snrDb)} dB at 1 kHz): the speaker is silent, or the console is muted or turned down',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'audio_file',
          title: 'an AAC file through sceAvPlayer',
          hint: 'three notes, decoded by the console and recorded',
          run: () async {
            // The decoder is the verdict; the microphone says whether the
            // room heard it, as a level rise in dB, for the record.
            final mic = Hardware.call('mic', {'ms': 4000});
            await Future<void>.delayed(const Duration(milliseconds: 400));
            // AAC in MP4: the container the console's player is for. The
            // same sound as MP3 got 0x806A0002 from AddSource on every
            // path (build 48); the player does not open that container.
            Map<String, Object?> r;
            try {
              r = await Hardware.call(
                  'audioFile', {'max_ms': 5000, 'file': 'tone.m4a'});
              r['file'] = 'tone.m4a';
            } on PlatformException catch (e) {
              // The same sound under a black video track, in case the
              // player wants one.
              r = await Hardware.call(
                  'audioFile', {'max_ms': 5000, 'file': 'tone.mp4'});
              r['file'] = 'tone.mp4';
              r['m4a_error'] = e.message;
            }
            final m = await mic;
            var rise = 0.0;
            try {
              rise = levelRiseDb(File('${m['path']}').readAsBytesSync());
            } on Object {
              // No recording is no verdict on the decoder.
            }
            r['mic_rise_db'] = double.parse(rise.toStringAsFixed(1));
            r['mic_peak'] = m['peak'];
            final frames = (r['frames'] as num?)?.toInt() ?? 0;
            return (
              frames > 0 ? CheckState.pass : CheckState.fail,
              '${r['file']}: decoded $frames frames, ${r['channels']} ch ${r['rate']} Hz, ${r['bytes']} B in ${r['took_ms']} ms; '
                  'the microphone heard +${_n(rise)} dB${(m['peak'] as num? ?? 0) == 0 ? ' (mic off)' : ''}',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'camera_front',
          group: HardwareGroup.camera,
          title: 'front camera',
          run: () => _camera(0),
        ),
        HardwareCheck(
          id: 'camera_back',
          group: HardwareGroup.camera,
          title: 'back camera',
          run: () => _camera(1),
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

  Future<(CheckState, String, Map<String, Object?>?)> _camera(int which) async {
    final r = await Hardware.call('camera', {'which': which});
    final path = '${r['path']}';
    final w = (r['width'] as num).toInt();
    final h = (r['height'] as num).toInt();
    final bytes = File(path).readAsBytesSync();
    final image = await _decode(bytes, w, h);
    if (which == 0) {
      front = image;
    } else {
      back = image;
    }
    notifyListeners();
    final sd = (r['stddev'] as num?)?.toDouble() ?? 0;
    return (
      sd > 5 ? CheckState.pass : CheckState.eye,
      'frame ${r['frame']} of ${r['frames'] ?? '?'} ${w}x$h in ${r['took_ms']} ms, '
          'mean ${_n(r['mean'])} sd ${_n(sd)}'
          '${sd > 5 ? '' : ' (flat: covered, or dark)'}',
      r
    );
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
