// The loader's screen. ADR-0016.
//
// Top to bottom: the Flutter logo, the address, the status, a log of recent
// actions, and the versions. The address is the line that justifies the
// screen -- when this console's Wi-Fi drops and returns on a different
// address, the loader is the only thing that knows where it went, and until
// now it had no way to say so.
//
// This reads state and never writes it. The C layer under it (loader_dev.c)
// owns the port and republishes ux0:data/flutter-vita/loader-state.txt on
// every change; polling a file is what lets the reliability-critical half
// stay free of a platform channel. If the engine never starts, that half is
// unaffected and only this is lost.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'build_info.dart';

const _statePath = 'ux0:data/flutter-vita/loader-state.txt';

void main() => runApp(const LoaderApp());

/// Everything the C layer publishes, as one immutable snapshot.
class LoaderState {
  const LoaderState({
    this.seq = 0,
    this.ip = '',
    this.port = 0,
    this.status = 'Starting',
    this.detail = '',
    this.log = const [],
  });

  final int seq;
  final String ip;
  final int port;
  final String status;
  final String detail;
  final List<String> log;

  /// `key value` per line, oldest log line first. Deliberately not JSON: the
  /// writer is 300 lines of C with no allocator to spare, and every field
  /// here is a single token or the rest of the line.
  static LoaderState parse(String text) {
    var seq = 0, port = 0;
    var ip = '', status = 'Starting', detail = '';
    final log = <String>[];
    for (final line in text.split('\n')) {
      final space = line.indexOf(' ');
      if (space < 0) continue;
      final key = line.substring(0, space);
      final value = line.substring(space + 1);
      switch (key) {
        case 'seq':
          seq = int.tryParse(value) ?? 0;
        case 'ip':
          ip = value == '-' ? '' : value;
        case 'port':
          port = int.tryParse(value) ?? 0;
        case 'status':
          status = value;
        case 'detail':
          detail = value;
        case 'log':
          log.add(value);
      }
    }
    return LoaderState(
      seq: seq,
      ip: ip,
      port: port,
      status: status,
      detail: detail,
      log: log,
    );
  }
}

class LoaderApp extends StatefulWidget {
  const LoaderApp({super.key});

  @override
  State<LoaderApp> createState() => _LoaderAppState();
}

class _LoaderAppState extends State<LoaderApp> {
  LoaderState _state = const LoaderState();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    // Twice a second. The states worth watching live are a transfer's byte
    // count and a Wi-Fi drop, and neither needs a frame's worth of latency --
    // this is the CPU rasteriser (decision 7) and the panel is the only thing
    // it has to keep up with.
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _poll() {
    try {
      final file = File(_statePath);
      if (!file.existsSync()) return;
      final next = LoaderState.parse(file.readAsStringSync());
      // The sequence number exists so an unchanged file costs one comparison
      // rather than a rebuild of the whole tree twice a second.
      if (next.seq == _state.seq) return;
      setState(() => _state = next);
    } on FileSystemException {
      // The writer renames into place, so a read can lose the race exactly
      // once per publish. Next tick.
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: const Color(0xFF0B1420),
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const FlutterLogo(size: 84),
            const SizedBox(height: 18),
            _Address(ip: s.ip, port: s.port),
            const SizedBox(height: 16),
            _Status(status: s.status, detail: s.detail),
            const SizedBox(height: 16),
            Expanded(child: _Log(lines: s.log)),
            const SizedBox(height: 10),
            const _Versions(),
          ],
        ),
      ),
    );
  }
}

class _Address extends StatelessWidget {
  const _Address({required this.ip, required this.port});

  final String ip;
  final int port;

  @override
  Widget build(BuildContext context) {
    final known = ip.isNotEmpty;
    return Text(
      known ? '$ip:$port' : 'no address',
      style: TextStyle(
        fontSize: 30,
        height: 1.0,
        fontFamily: 'monospace',
        fontWeight: FontWeight.w600,
        letterSpacing: 1.5,
        color: known ? const Color(0xFFE8F1FA) : const Color(0xFF5A6B7C),
      ),
    );
  }
}

/// The five states of ADR-0016's status model, plus the moment before the
/// first publish. Colour carries the same information as the word, because
/// the thing this screen is read for is answered from across a desk.
class _Status extends StatelessWidget {
  const _Status({required this.status, required this.detail});

  final String status;
  final String detail;

  static const _colours = <String, Color>{
    'No network': Color(0xFFE05A4F),
    'Waiting': Color(0xFF4B8FD6),
    'Receiving': Color(0xFFE0A03A),
    'Installing': Color(0xFFE0A03A),
    'Launching': Color(0xFF4CAF7D),
  };

  @override
  Widget build(BuildContext context) {
    final colour = _colours[status] ?? const Color(0xFF5A6B7C);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.16),
            border: Border.all(color: colour, width: 1.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            status.toUpperCase(),
            style: TextStyle(
              fontSize: 15,
              height: 1.0,
              letterSpacing: 2.0,
              fontWeight: FontWeight.w700,
              color: colour,
            ),
          ),
        ),
        if (detail.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            detail,
            style: const TextStyle(
              fontSize: 14,
              height: 1.0,
              color: Color(0xFF8FA3B5),
            ),
          ),
        ],
      ],
    );
  }
}

/// Recent actions, oldest at the top.
///
/// Empty at every launch and that is by design, not a bug: `launch` ends this
/// process, so the loader's whole life is boot, serve a few commands, hand
/// over. ADR-0016 decision 5 records the trade -- the field's job is to show
/// a deploy happening live, and the CLI already pulls history on demand.
class _Log extends StatelessWidget {
  const _Log({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF08101A),
        border: Border.all(color: const Color(0xFF1C2C3D)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: lines.isEmpty
          ? const Center(
              child: Text(
                'no activity yet',
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: Color(0xFF3E5163),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final line in lines)
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      fontFamily: 'monospace',
                      color: Color(0xFF7E93A6),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Versions extends StatelessWidget {
  const _Versions();

  @override
  Widget build(BuildContext context) {
    // Platform.version is the whole banner; the leading token is the version.
    final dart = Platform.version.split(' ').first;
    return Text(
      'loader $kLoaderVersion   ·   flutter $kFlutterVersion   ·   '
      'engine ${kEngineRevision.substring(0, 10)}   ·   dart $dart',
      style: const TextStyle(
        fontSize: 11,
        height: 1.0,
        fontFamily: 'monospace',
        color: Color(0xFF3E5163),
      ),
    );
  }
}
