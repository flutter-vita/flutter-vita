// The Tests tab: what this port can actually do, probe by probe.
//
// Called Conformance until 2026-10-01, and its own application
// (apps/conformance) until 2026-09-14. It kept
// its two files: the journal, appended as probes complete so a crash leaves
// evidence, and the resume file, so the next attempt skips the probe that
// killed the last one. It gained what the Scenes tab had: a Run button, an
// unattended run when the host writes tests.on, and a result file with
// a done marker the host can wait for.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../run_fab.dart';
import '../suites.dart'
    show
        engineStamp,
        kTestsDonePath,
        kTestsResultPath,
        kDataDir,
        writeAtomic;
import 'probes.dart';

class TestsTab extends StatefulWidget {
  const TestsTab({super.key, this.autoRun = false});

  /// Started by the host: run at once, write the result file and the marker.
  final bool autoRun;

  @override
  State<TestsTab> createState() => _TestsTabState();
}

class _TestsTabState extends State<TestsTab> {
  late List<ProbeResult> _results = buildProbes().map(ProbeResult.new).toList();
  var _running = false;
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
    if (widget.autoRun) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => unawaited(_runAll(writeFile: true)));
    }
  }

  @override
  void dispose() {
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

  Future<void> _runAll({required bool writeFile}) async {
    if (_running) return;
    setState(() {
      _running = true;
      _done = false;
      _results = buildProbes().map(ProbeResult.new).toList();
    });
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
      _journal('.... ${result.probe.group}/${result.probe.name}');
      // Also to app.log, where the engine's own logging goes. The journal and
      // app.log are separate files with no shared clock, so engine-side
      // instrumentation cannot be attributed to a probe without a marker in
      // the engine's own log.
      print('PROBE ${result.probe.group}/${result.probe.name}');
      try {
        // A probe that hangs would stall every one after it and the run would
        // report nothing at all, so each gets its own ceiling on top of any
        // timeout it sets internally.
        result.detail = await result.probe.run().timeout(result.probe.timeout);
        result.outcome = Outcome.pass;
      } on Object catch (e) {
        result.outcome = Outcome.fail;
        result.detail = _short(e);
      }
      _journal('${result.outcome == Outcome.pass ? "PASS" : "FAIL"} '
          '${result.probe.group}/${result.probe.name}  ${result.detail}');
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
    if (writeFile) _writeResult();
    if (mounted) {
      setState(() {
        _done = true;
        _running = false;
      });
    }
  }

  /// One file the host and the Results tab read, and a marker after it.
  void _writeResult() {
    try {
      final payload = <String, Object?>{
        'schema': 1,
        'suite': 'tests',
        'taken': DateTime.now().toIso8601String(),
        if (engineStamp() case final String e) 'engine': e,
        'pass': _results.where((r) => r.outcome == Outcome.pass).length,
        'fail': _results.where((r) => r.outcome == Outcome.fail).length,
        'skip': _results.where((r) => r.outcome == Outcome.skipped).length,
        'probes': [
          for (final r in _results)
            {
              'group': r.probe.group,
              'name': r.probe.name,
              'outcome': r.outcome.name,
              'detail': r.detail,
            },
        ],
      };
      Directory(kDataDir).createSync(recursive: true);
      writeAtomic(kTestsResultPath,
          const JsonEncoder.withIndent('  ').convert(payload));
      File(kTestsDonePath).writeAsStringSync('1', flush: true);
    } on Object {
      // The journal already has every line; the result file is the summary.
    }
  }

  /// Append-only record that survives the process.
  ///
  /// Best-effort by design: this is the reporting channel *and* partly the
  /// thing under test, so it must never be the reason a run fails.
  static const _journalPath = '$kDataDir/tests.txt';

  /// Where the next attempt should pick up. One integer, separate from the
  /// journal on purpose; delete it or write a non-number to force a fresh run.
  static const _resumePath = '$kDataDir/resume.txt';

  int? _journalStart() {
    int? resumeAt;
    try {
      Directory(kDataDir).createSync(recursive: true);
      final f = File(_resumePath);
      if (f.existsSync()) {
        final n = int.tryParse(f.readAsStringSync().trim());
        if (n != null && n >= 0 && n <= _results.length) resumeAt = n;
      }
      File(_journalPath).writeAsStringSync(
        '\n=== flutter-vita tests ${DateTime.now()} '
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
      // Losing the resume point costs a repeat, not a result.
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
    final ran = passed + failed + skipped;

    final tab = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Row(
            children: [
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
                    : _running
                        ? 'running $ran/${_results.length}…'
                        : '${_results.length} probes',
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
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: ListView.builder(
              controller: _scroll,
              // Fixed extent so the list does not measure seventy-eight
              // children to know how tall it is, and so _follow can work
              // out where a row lives by multiplying.
              itemExtent: _rowHeight,
              itemCount: _results.length,
              itemBuilder: (context, i) => _Row(_results[i]),
              padding: const EdgeInsets.only(bottom: RunFab.clearance),
            ),
          ),
        ),
      ],
    );
    return RunFab.over(tab,
        running: _running, onRun: () => _runAll(writeFile: true));
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
    const mono = TextStyle(fontSize: 11, fontFamily: 'monospace');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(result.probe.group,
                style: mono.copyWith(color: const Color(0xFF6B7488))),
          ),
          SizedBox(
            width: 260,
            child: Text(result.probe.name,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(color: const Color(0xFFC7CEDB))),
          ),
          SizedBox(
            width: 36,
            child: Text(label,
                style:
                    mono.copyWith(fontWeight: FontWeight.bold, color: colour)),
          ),
          Expanded(
            child: Text(result.detail,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(color: const Color(0xFF8B94A7))),
          ),
        ],
      ),
    );
  }
}
