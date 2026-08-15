import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:path_provider_vita/path_provider_vita.dart';
import 'package:shared_preferences_vita/shared_preferences_vita.dart';

import 'probes.dart';

/// The conformance app: what this port can actually do, shown on the panel.
///
/// Results go to two places, because the first run proved one is not enough.
///
/// The screen was the original channel — files, sockets and `print` are all
/// things under test, so reporting through them is circular, while rendering
/// and `shot` were already proved by M3. What that reasoning missed is that a
/// crash takes the app down *and the screen with it*: after the first run died
/// partway through, `shot` had nothing left to capture and the only record was
/// what the user happened to have seen.
///
/// So results are also appended to a file as they complete. That is circular
/// for the filesystem probes and honest about it: if the file exists at all,
/// the filesystem works, and the rows inside it speak for everything after.
void main() {
  // The second half of the opt-in. A non-endorsed implementation is not found
  // automatically -- that is what non-endorsed means -- so the app registers
  // it. Two lines, and the same two `camera_tizen` asks Tizen apps for.
  PathProviderVita.registerWith();
  SharedPreferencesVita.registerWith();
  runApp(const ConformanceApp());
}

class ConformanceApp extends StatelessWidget {
  const ConformanceApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF10131A),
        ),
        home: const ProbeRunner(),
      );
}

class ProbeRunner extends StatefulWidget {
  const ProbeRunner({super.key});
  @override
  State<ProbeRunner> createState() => _ProbeRunnerState();
}

class _ProbeRunnerState extends State<ProbeRunner> {
  late final List<ProbeResult> _results =
      buildProbes().map(ProbeResult.new).toList();
  var _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_runAll());
  }

  Future<void> _runAll() async {
    _journalStart();
    for (final result in _results) {
      // Written *before* the probe runs, so the crashing probe names itself.
      // The first run left no evidence of which one killed it, and the whole
      // point of a journal is to still be there when the app is not.
      _journal('.... ${result.probe.group}/${result.probe.name}');
      try {
        // A probe that hangs would stall every one after it and the run would
        // report nothing at all, so each gets its own ceiling on top of any
        // timeout it sets internally.
        result.detail = await result.probe
            .run()
            .timeout(const Duration(seconds: 25));
        result.outcome = Outcome.pass;
      } on Object catch (e) {
        result.outcome = Outcome.fail;
        result.detail = _short(e);
      }
      _journal('${result.outcome == Outcome.pass ? "PASS" : "FAIL"} '
          '${result.probe.group}/${result.probe.name}  ${result.detail}');
      // Bracketing the repaint, because a run died between a PASS line and the
      // next probe's own marker -- which is not inside any probe at all. These
      // two lines say whether the frame or the gap after it is what dies.
      _journal('     paint>');
      if (mounted) setState(() {});
      await Future<void>.delayed(const Duration(milliseconds: 16));
      _journal('     <paint');
    }
    _journal('== run complete ==');
    if (mounted) setState(() => _done = true);
  }

  /// Append-only record that survives the process.
  ///
  /// Best-effort by design: this is the reporting channel *and* partly the
  /// thing under test, so it must never be the reason a run fails. A throw here
  /// means the filesystem is broken, which the absent file already says.
  static const _journalPath = 'ux0:data/flutter-vita/conformance.txt';

  void _journalStart() {
    try {
      Directory('ux0:data/flutter-vita').createSync(recursive: true);
      File(_journalPath).writeAsStringSync(
          'flutter-vita conformance ${DateTime.now()}\n');
    } on Object {
      // Nothing to do. The screen is still a channel while the app lives.
    }
  }

  void _journal(String line) {
    try {
      // Synchronous and unbuffered: an async write scheduled just before a
      // native crash is a write that never happens.
      File(_journalPath)
          .writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } on Object {
      // Deliberately silent, see above.
    }
  }

  /// Exception text is often long and the useful part is at the front.
  static String _short(Object e) {
    var s = e.toString().replaceAll('\n', ' ');
    if (s.startsWith('SocketException: ')) s = s.substring(17);
    if (s.startsWith('FileSystemException: ')) s = s.substring(21);
    return s.length > 68 ? '${s.substring(0, 67)}…' : s;
  }

  @override
  Widget build(BuildContext context) {
    final passed = _results.where((r) => r.outcome == Outcome.pass).length;
    final failed = _results.where((r) => r.outcome == Outcome.fail).length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              child: Row(
                children: [
                  const Text('flutter-vita conformance',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFE6EAF2))),
                  const SizedBox(width: 10),
                  // The logical size and device pixel ratio, because the first
                  // run overflowed the panel and nothing recorded whether the
                  // surface was 960x544 or 480x272 at DPR 2.
                  Builder(builder: (context) {
                    final mq = MediaQuery.of(context);
                    return Text(
                      '${mq.size.width.toStringAsFixed(0)}'
                      'x${mq.size.height.toStringAsFixed(0)} '
                      '@${mq.devicePixelRatio}',
                      style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Color(0xFF6B7488)),
                    );
                  }),
                  const Spacer(),
                  Text(
                    _done
                        ? '$passed pass  ·  $failed fail'
                        : 'running ${passed + failed}/${_results.length}…',
                    style: TextStyle(
                      fontSize: 13,
                      color: _done && failed > 0
                          ? const Color(0xFFFF8A80)
                          : const Color(0xFF9AA4B8),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF262B36)),
            // Two columns and a computed row height, because the first run
            // ran off the bottom of the panel with no way to scroll it: there
            // is no pointer to drag and no keyboard to page with, so anything
            // below the fold is simply lost. Fitting is not cosmetic here, it
            // is whether the result is readable at all.
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final perColumn = (_results.length / 2).ceil();
                  final rowHeight =
                      (box.maxHeight / perColumn).clamp(9.0, 16.0);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _Column(
                            _results.take(perColumn).toList(), rowHeight),
                      ),
                      const VerticalDivider(
                          width: 1, color: Color(0xFF262B36)),
                      Expanded(
                        child: _Column(
                            _results.skip(perColumn).toList(), rowHeight),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Column extends StatelessWidget {
  const _Column(this.results, this.rowHeight);
  final List<ProbeResult> results;
  final double rowHeight;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in results) SizedBox(height: rowHeight, child: _Row(r)),
        ],
      );
}

class _Row extends StatelessWidget {
  const _Row(this.result);
  final ProbeResult result;

  @override
  Widget build(BuildContext context) {
    final (label, colour) = switch (result.outcome) {
      Outcome.pass => ('PASS', const Color(0xFF7BD88F)),
      Outcome.fail => ('FAIL', const Color(0xFFFF8A80)),
      Outcome.pending => ('  · ', const Color(0xFF5A6478)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(result.probe.group,
                style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFF6B7488))),
          ),
          SizedBox(
            width: 124,
            child: Text(result.probe.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFFC7CEDB))),
          ),
          SizedBox(
            width: 32,
            child: Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: colour)),
          ),
          Expanded(
            child: Text(result.detail,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFF8B94A7))),
          ),
        ],
      ),
    );
  }
}
