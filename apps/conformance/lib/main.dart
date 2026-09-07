import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:path_provider_vita/path_provider_vita.dart';
import 'package:shared_preferences_vita/shared_preferences_vita.dart';

import 'probes.dart';

/// The conformance app: what this port can actually do, shown on the panel.
///
/// Results go to two places. The screen alone is not enough, because a crash
/// takes the app down and the screen with it, leaving `shot` nothing to
/// capture.
///
/// So results are also appended to a file as they complete. That is circular
/// for the filesystem probes and honest about it: if the file exists at all,
/// the filesystem works.
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

class _ProbeRunnerState extends State<ProbeRunner>
    with SingleTickerProviderStateMixin {
  // Breaks the 1:1 between frames and probes, which is the whole experiment.
  //
  // Every run so far has died at the 32nd probe, and because this app repaints
  // once per probe that is also the 32nd frame -- the two cannot be told apart.
  // A continuous animation makes frames run far ahead of probes: if the app
  // dies about a second in, having painted ~32 times while barely starting the
  // probe list, the limit is frames. If it reaches probe 32 as usual after
  // hundreds of frames, the limit is probes and the present path is innocent.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  late final List<ProbeResult> _results =
      buildProbes().map(ProbeResult.new).toList();
  var _done = false;

  final ScrollController _scroll = ScrollController();

  /// Tall enough to read at this font, and fixed rather than fitted.
  ///
  /// The list used to divide the panel height by the probe count and shrink to
  /// suit, which worked at 40 probes and stopped working at 75: rows went to
  /// 9 px, and the columns were half the panel wide, so a name like
  /// "Timer(0) x200, counting events" and a detail like "mean 388 p50 214 p90
  /// 338 max 10173 us, 0 over 20 ms" were both ellipsised down to nothing. A
  /// result you cannot read is not a result.
  static const double _rowHeight = 15;

  @override
  void initState() {
    super.initState();
    unawaited(_runAll());
  }

  @override
  void dispose() {
    _spin.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Keeps the probe that just ran in the middle of the panel.
  ///
  /// There is no pointer to drag with while a run is going and no keyboard to
  /// page with, so a list that does not follow the run is a list whose
  /// interesting row is off the bottom for the whole run.
  ///
  /// jumpTo, not animateTo: an animation is another timer firing on every
  /// probe, and this app exists partly to measure what timers cost.
  void _follow(int index) {
    if (!_scroll.hasClients) return;
    final viewport = _scroll.position.viewportDimension;
    final target = (index * _rowHeight) - (viewport / 2) + (_rowHeight / 2);
    _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  Future<void> _runAll() async {
    // Null means no resume file, i.e. a genuinely fresh run, as distinct from
    // one resuming at probe 0.
    final resume = _journalStart();

    for (var i = 0; i < _results.length; i++) {
      final result = _results[i];
      if (i < (resume ?? 0)) {
        result.outcome = Outcome.skipped;
        result.detail = 'ran in an earlier attempt';
        continue;
      }
      // Written *before* the probe runs, and it is the index after this one:
      // a crash inside this probe must not send the next attempt back into it.
      _writeResume(i + 1);
      // Written *before* the probe runs, so the crashing probe names itself.
      // The first run left no evidence of which one killed it, and the whole
      // point of a journal is to still be there when the app is not.
      _journal('.... ${result.probe.group}/${result.probe.name}');
      // Also to app.log, where the engine's own logging goes. The journal and
      // app.log are separate files with no shared clock, so engine-side
      // instrumentation cannot be attributed to a probe without a marker in
      // the engine's own log. Cheap, and it makes app.log readable on its own.
      print('PROBE ${result.probe.group}/${result.probe.name}');
      try {
        // A probe that hangs would stall every one after it and the run would
        // report nothing at all, so each gets its own ceiling on top of any
        // timeout it sets internally.
        result.detail = await result.probe
            .run()
            .timeout(result.probe.timeout);
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
      if (mounted) {
        setState(() {});
        _follow(i);
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
      _journal('     <paint');
    }
    _journal('== run complete ==');
    // The list is finished, so the next launch is a fresh run rather than a
    // resume of a completed one.
    _clearResume();
    if (mounted) setState(() => _done = true);
  }

  /// Append-only record that survives the process.
  ///
  /// Best-effort by design: this is the reporting channel *and* partly the
  /// thing under test, so it must never be the reason a run fails. A throw here
  /// means the filesystem is broken, which the absent file already says.
  static const _journalPath = 'ux0:data/flutter-vita/conformance.txt';

  /// Where the next attempt should pick up.
  ///
  /// Separate from the journal on purpose: the journal is a narrative and this
  /// is one integer, and it must survive when the journal does not.
  ///
  /// Delete it to force a run from the top, or overwrite it with anything that
  /// is not a number, which works on a device whose receiver has no `rm`.
  static const _resumePath = 'ux0:data/flutter-vita/resume.txt';

  /// Opens the journal and returns the probe index to start from, or null if
  /// there is no resume file and this is therefore a fresh run.
  ///
  /// Appends rather than truncates, which the single-run version did. Across a
  /// resumed sequence the earlier attempts *are* the evidence -- throwing them
  /// away on each relaunch would leave only the last fragment, which is the
  /// position the crash investigation was already stuck in.
  int? _journalStart() {
    int? resumeAt;
    try {
      Directory('ux0:data/flutter-vita').createSync(recursive: true);
      final f = File(_resumePath);
      if (f.existsSync()) {
        // Anything that is not a probe index means "start over", including
        // garbage. That is the right reading of a corrupt file, and it is also
        // the only way to force a fresh run on a device whose receiver predates
        // `rm`: overwrite this with a byte that is not a number.
        final n = int.tryParse(f.readAsStringSync().trim());
        if (n != null && n >= 0 && n <= _results.length) resumeAt = n;
      }
      File(_journalPath).writeAsStringSync(
        '\n=== flutter-vita conformance ${DateTime.now()} '
        '${resumeAt == null ? "(fresh run)" : "(resuming at probe $resumeAt)"} ===\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // Nothing to do. The screen is still a channel while the app lives.
    }
    return resumeAt;
  }

  void _writeResume(int next) {
    try {
      File(_resumePath).writeAsStringSync('$next\n', flush: true);
    } on Object {
      // Best-effort, like the journal: losing the resume point costs a repeat,
      // not a result.
    }
  }

  void _clearResume() {
    try {
      final f = File(_resumePath);
      if (f.existsSync()) f.deleteSync();
    } on Object {
      // See above.
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
    final skipped = _results.where((r) => r.outcome == Outcome.skipped).length;

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
                  // Rebuilt every tick, so the frame counter in m3.log runs
                  // independently of probe progress.
                  AnimatedBuilder(
                    animation: _spin,
                    builder: (_, __) => Transform.rotate(
                      angle: _spin.value * 6.283,
                      child: const Icon(Icons.sync,
                          size: 12, color: Color(0xFF6B7488)),
                    ),
                  ),
                  const SizedBox(width: 8),
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
                          '${skipped > 0 ? "  ·  $skipped skip" : ""}'
                        : 'running ${passed + failed + skipped}'
                            '/${_results.length}…',
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
            // One column that scrolls, and _follow keeps the running probe in
            // the middle of it. The panel held every probe at once for as long
            // as there were forty of them; there are seventy-five now, and
            // their names and details have both grown, so fitting meant
            // ellipsising away the measurement itself.
            Expanded(
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: ListView.builder(
                  controller: _scroll,
                  // Fixed extent so the list does not measure seventy-five
                  // children to know how tall it is, and so _follow can work
                  // out where a row lives by multiplying.
                  itemExtent: _rowHeight,
                  itemCount: _results.length,
                  itemBuilder: (context, i) => _Row(_results[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.result);
  final ProbeResult result;

  @override
  Widget build(BuildContext context) {
    final (label, colour) = switch (result.outcome) {
      Outcome.pass => ('PASS', const Color(0xFF7BD88F)),
      Outcome.fail => ('FAIL', const Color(0xFFFF8A80)),
      Outcome.skipped => ('skip', const Color(0xFF5A6478)),
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
            width: 260,
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
