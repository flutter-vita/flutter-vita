// The Results tab: the last run of each suite, read back from the card.
//
// The suites write their files for the host; this tab reads the same files,
// so what a person sees on the console and what tools/suite.sh pulls are
// one thing. Nothing here is computed: it is the result files, summarised.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'suites.dart' show kConformanceResultPath, kHardwareResultPath;

class ResultsTab extends StatefulWidget {
  const ResultsTab({super.key});
  @override
  State<ResultsTab> createState() => _ResultsTabState();
}

class _ResultsTabState extends State<ResultsTab> {
  Map<String, Object?>? _conformance;
  Map<String, Object?>? _hardware;

  static Map<String, Object?>? _read(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final v = jsonDecode(f.readAsStringSync());
      return v is Map ? v.map((k, val) => MapEntry(k.toString(), val)) : null;
    } on Object {
      return null;
    }
  }

  void _reload() => setState(() {
        _conformance = _read(kConformanceResultPath);
        _hardware = _read(kHardwareResultPath);
      });

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(
        fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFFE6EAF2));
    const mono = TextStyle(
        fontSize: 11, fontFamily: 'monospace', color: Color(0xFF9AA4B8));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 4, 0),
          child: Row(
            children: [
              const Expanded(
                  child: Text('what is on the card',
                      style:
                          TextStyle(fontSize: 13, color: Color(0xFF9AA4B8)))),
              TextButton(onPressed: _reload, child: const Text('Reload')),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF262B36)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(10),
            children: [
              Text('conformance  ${_stamp(_conformance)}', style: head),
              Text(_conformanceSummary(), style: mono),
              const SizedBox(height: 10),
              Text('hardware  ${_stamp(_hardware)}', style: head),
              Text(_hardwareSummary(), style: mono),
            ],
          ),
        ),
      ],
    );
  }

  static String _stamp(Map<String, Object?>? m) {
    if (m == null) return '(no result file)';
    final taken = '${m['taken'] ?? ''}'.replaceFirst('T', ' ');
    final engine =
        m['engine'] == null ? 'no engine stamp' : 'engine ${m['engine']}';
    return '${taken.length > 19 ? taken.substring(0, 19) : taken}  ·  $engine';
  }

  String _conformanceSummary() {
    final m = _conformance;
    if (m == null) return 'run the Conformance tab';
    final failed = (m['probes'] as List? ?? const [])
        .cast<Map>()
        .where((p) => p['outcome'] == 'fail')
        .map((p) => '${p['group']}/${p['name']}')
        .toList();
    return '${m['pass']} pass  ${m['fail']} fail  ${m['skip']} skip'
        '${failed.isEmpty ? '' : '\nfailed: ${failed.join(', ')}'}';
  }

  String _hardwareSummary() {
    final m = _hardware;
    if (m == null) return 'run the Hardware tab';
    final checks = (m['checks'] as List? ?? const []).cast<Map>();
    String names(String state) => checks
        .where((c) => c['state'] == state)
        .map((c) => '${c['title']}')
        .join(', ');
    return '${m['pass']} pass  ${m['fail']} fail  ${m['eye']} by eye  ${m['off']} off  ${m['skipped'] ?? 0} not run'
        '${(m['fail'] as num? ?? 0) > 0 ? '\nfailed: ${names('fail')}' : ''}'
        '${(m['eye'] as num? ?? 0) > 0 ? '\nby eye: ${names('eye')}' : ''}';
  }
}
