// The Hardware tab: does each piece of the console answer, and with what.
//
// Every check is one method on the `vita/hardware` channel, answered by
// templates/vita-app/hardware.c, plus two that need no C (an HTTP GET, the
// keyboard). A check ends in one of four states: pass and fail where the
// numbers decide, `eye` where a person has to judge (a picture, a sound, a
// press nobody made), and `off` when this build has no hardware.c.
//
// Two groups. The automatic checks ask the console and read the answer. The
// checks that need a person want a press, a touch, a word, an ear or a
// typed line, and no script can supply those. Each group has its own Run.
//
// Unattended: the host writes hardware.on and relaunches; the tab runs the
// automatic group and writes hardware-result.json and hardware-done. The
// checks that need a person are written as `skipped` in such a run.

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

enum CheckState { pending, running, pass, fail, eye, off, skipped }

class HardwareCheck {
  HardwareCheck({
    required this.id,
    required this.title,
    required this.run,
    this.hint,
    this.manual = false,
  });

  final String id;
  final String title;

  /// Needs a person: something pressed, touched, said, heard or typed.
  final bool manual;

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

class HardwareTab extends StatefulWidget {
  const HardwareTab({super.key, this.autoRun = false});
  final bool autoRun;

  @override
  State<HardwareTab> createState() => _HardwareTabState();
}

class _HardwareTabState extends State<HardwareTab> {
  late final List<HardwareCheck> _checks = _build();
  final _typed = TextEditingController();
  ui.Image? _front;
  ui.Image? _back;
  var _running = false;
  var _status = '';

  @override
  void initState() {
    super.initState();
    _typed.addListener(() => setState(() {}));
    if (widget.autoRun) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(_runGroup(manual: false, writeFile: true)));
    }
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

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
          manual: true,
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
          manual: true,
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
              'accel ${a.map((v) => _n(v, 2)).join(' ')} (|a| ${_n(mag, 2)} g²) gyro ${g.map((v) => _n(v, 2)).join(' ')}',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'audio_tone',
          manual: true,
          title: 'speaker: a tone',
          hint: 'listen: one second at 440 Hz',
          run: () async {
            final r = await Hardware.call('audioTone');
            return (
              CheckState.eye,
              'played ${r['grains']} grains at ${r['rate']} Hz in ${r['took_ms']} ms',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'audio_file',
          manual: true,
          title: 'speaker: an mp3 (sceAvPlayer)',
          hint: 'listen: three notes',
          run: () async {
            final r = await Hardware.call('audioFile', {'max_ms': 5000});
            return (
              CheckState.eye,
              'decoded ${r['frames']} frames, ${r['channels']} ch ${r['rate']} Hz, ${r['bytes']} B in ${r['took_ms']} ms',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'mic',
          manual: true,
          title: 'microphone',
          hint: 'say something',
          run: () async {
            final r = await Hardware.call('mic');
            final peak = (r['peak'] as num?)?.toInt() ?? 0;
            if (r['muted'] == true) {
              // The console's own switch, in the quick menu (hold PS):
              // nothing this app can flip, and the port is open all the same.
              return (
                CheckState.eye,
                'muted by the console (PS button menu)',
                r
              );
            }
            return (
              peak > 800 ? CheckState.pass : CheckState.eye,
              'peak $peak rms ${r['rms']} over ${r['samples']} samples${peak > 800 ? '' : ' (quiet)'}',
              r
            );
          },
        ),
        HardwareCheck(
          id: 'camera_front',
          title: 'front camera',
          run: () => _camera(0),
        ),
        HardwareCheck(
          id: 'camera_back',
          title: 'back camera',
          run: () => _camera(1),
        ),
        HardwareCheck(
          id: 'keyboard',
          manual: true,
          title: 'keyboard',
          hint: 'tap the field on the right and type (20 s)',
          run: () async {
            // Whatever is in the field counts, typed before or during.
            for (var i = 0; i < 80 && _typed.text.isEmpty; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
            final t = _typed.text;
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
    if (mounted) {
      setState(() {
        if (which == 0) {
          _front = image;
        } else {
          _back = image;
        }
      });
    }
    final sd = (r['stddev'] as num?)?.toDouble() ?? 0;
    return (
      sd > 5 ? CheckState.pass : CheckState.eye,
      'frame ${r['frame']} ${w}x$h in ${r['took_ms']} ms, mean ${_n(r['mean'])} sd ${_n(sd)}'
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

  Future<void> _runOne(HardwareCheck c) async {
    setState(() {
      c.state = CheckState.running;
      c.detail = c.hint ?? '';
      _status = c.title;
    });
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
    if (mounted) setState(() => _status = '');
  }

  /// One group. The other group's rows keep whatever state they have; a
  /// check never run in this session is written as `skipped`.
  Future<void> _runGroup(
      {required bool manual, required bool writeFile}) async {
    if (_running) return;
    setState(() => _running = true);
    for (final c in _checks.where((c) => c.manual == manual)) {
      await _runOne(c);
    }
    for (final c in _checks) {
      if (c.state == CheckState.pending) {
        c.state = CheckState.skipped;
        c.detail = c.manual ? 'needs a person; not run' : 'not run';
      }
    }
    if (writeFile) _writeResult();
    if (mounted) setState(() => _running = false);
  }

  void _writeResult() {
    try {
      final payload = <String, Object?>{
        'schema': 1,
        'suite': 'hardware',
        'taken': DateTime.now().toIso8601String(),
        if (engineStamp() case final String e) 'engine': e,
        for (final s in CheckState.values)
          s.name: _checks.where((c) => c.state == s).length,
        'checks': [
          for (final c in _checks)
            {
              'id': c.id,
              'group': c.manual ? 'person' : 'auto',
              'title': c.title,
              'state': c.state.name,
              'detail': c.detail,
              'result': c.result
            },
        ],
      };
      Directory(kDataDir).createSync(recursive: true);
      writeAtomic(kHardwareResultPath,
          const JsonEncoder.withIndent('  ').convert(payload));
      File(kHardwareDonePath).writeAsStringSync('1', flush: true);
    } on Object {
      // The screen still has every row.
    }
  }

  // ---- the panel -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final auto = _checks.where((c) => !c.manual).toList();
    final person = _checks.where((c) => c.manual).toList();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 2, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _running ? 'running: $_status' : _summary(),
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF9AA4B8)),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFF262B36)),
              Expanded(
                child: ListView(
                  children: [
                    _GroupHead(
                      title: 'AUTOMATIC',
                      hint: 'the console answers; nothing to do',
                      count: auto.length,
                      onRun: _running
                          ? null
                          : () => _runGroup(manual: false, writeFile: true),
                    ),
                    for (final c in auto)
                      _CheckRow(c, onRun: _running ? null : () => _runOne(c)),
                    _GroupHead(
                      title: 'NEEDS A PERSON',
                      hint: 'press, touch, speak, listen, type',
                      count: person.length,
                      onRun: _running
                          ? null
                          : () => _runGroup(manual: true, writeFile: true),
                    ),
                    for (final c in person)
                      _CheckRow(c, onRun: _running ? null : () => _runOne(c)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 250,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _frame('front', _front),
                const SizedBox(height: 6),
                _frame('back', _back),
                const SizedBox(height: 10),
                TextField(
                  controller: _typed,
                  decoration: const InputDecoration(
                    labelText: 'keyboard check',
                    hintText: 'type here',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _summary() {
    int n(CheckState st) => _checks.where((c) => c.state == st).length;
    final parts = <String>[
      if (n(CheckState.pass) > 0) '${n(CheckState.pass)} pass',
      if (n(CheckState.fail) > 0) '${n(CheckState.fail)} fail',
      if (n(CheckState.eye) > 0) '${n(CheckState.eye)} by eye',
      if (n(CheckState.off) > 0) '${n(CheckState.off)} off',
      if (n(CheckState.skipped) > 0) '${n(CheckState.skipped)} not run',
    ];
    return parts.isEmpty ? '${_checks.length} checks' : parts.join('  ·  ');
  }

  Widget _frame(String label, ui.Image? image) => Container(
        height: 120,
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
