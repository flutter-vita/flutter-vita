import 'dart:async';

import 'package:flutter/material.dart';

import 'probes.dart';

/// The conformance app: what this port can actually do, shown on the panel.
///
/// The screen is the reporting channel, deliberately. Every other way of
/// getting results off the device is one of the things being tested — files,
/// sockets, and `print` are all probes here, so reporting through them would be
/// circular. Rendering and `shot` are what M3 already proved, so they are the
/// only honest place to put the answers.
void main() => runApp(const ConformanceApp());

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
    for (final result in _results) {
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
      // Repainted after every probe: a native crash later in the run still
      // leaves everything up to that point on the panel, where a screenshot
      // can reach it.
      if (mounted) setState(() {});
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (mounted) setState(() => _done = true);
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
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _results.length,
                itemBuilder: (_, i) => _Row(_results[i]),
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
      Outcome.pending => ('  · ', const Color(0xFF5A6478)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(result.probe.group,
                style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFF6B7488))),
          ),
          SizedBox(
            width: 168,
            child: Text(result.probe.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFFC7CEDB))),
          ),
          SizedBox(
            width: 38,
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
