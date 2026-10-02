// The bridge's screen.
//
// A header saying where the console is and what it is doing, four tabs, and a
// footer of versions. The header is what justifies the screen: when Wi-Fi
// drops and returns on a different address, the bridge is the only thing
// that knows where it went.
//
// The address shown is the mDNS name, not the number. Every tool defaults to
// fluttervita.local, so the number is a fallback and lives in the footer.
//
// bridge_dev.c owns the port and republishes bridge-state.txt on every
// change; polling a file is what keeps that half free of a platform channel.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'build_info.dart';
import 'device.dart';
import 'files.dart';
import 'psp2dmp.dart';
import 'tests.dart';
import 'theme.dart';

/// The name every tool in tools/ resolves, answered by the dev server's mDNS.
const _hostname = 'fluttervita.local';

void main() {
  // The FILES tab plays through audioplayers. Its Vita half registers itself:
  // build-vita-app.sh generates the plugin registrant from the packages'
  // pubspecs (ADR-0009).
  runApp(const BridgeApp());
}

enum Tab { deploy, logs, crashes, apps, tests, files }

class BridgeApp extends StatefulWidget {
  const BridgeApp({super.key});

  @override
  State<BridgeApp> createState() => _BridgeAppState();
}

class _BridgeAppState extends State<BridgeApp> {
  BridgeState _state = const BridgeState();
  List<String> _console = const [];
  Tab _tab = Tab.deploy;
  PanelCommand? _cmd;
  int _cmdSeq = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _console = readDeployLog();
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

  MdnsStatus _mdns = MdnsStatus.unknown;

  void _poll() {
    final cmd = readPanelRequest(_cmdSeq + 1);
    if (cmd != null) {
      _cmdSeq = cmd.seq;
      setState(() {
        if (cmd.verb == 'tab') {
          _tab = Tab.values.firstWhere(
            (t) => t.name == cmd.arg,
            orElse: () => _tab,
          );
          // A tab switch is handled here and not forwarded: the tab widget
          // being asked for may not be built yet.
          _cmd = null;
        } else {
          _cmd = cmd;
        }
      });
    }

    final next = BridgeState.read();
    if (next == null) return;
    // The sequence number exists so an unchanged file costs one comparison
    // rather than a rebuild of the whole tree twice a second.
    if (next.seq == _state.seq) return;
    // The console is re-read here rather than on the tick: the file only grows
    // when the C side publishes, and that is exactly what the sequence number
    // reports.
    setState(() {
      _state = next;
      _console = readDeployLog();
      // Re-read with the state, not on the tick. The C side republishes every
      // ten seconds whether or not anything happened, which is exactly the
      // cadence these numbers move at.
      _mdns = MdnsStatus.read();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: bg,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Rail(current: _tab, onPick: (t) => setState(() => _tab = t)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(state: s, mdns: _mdns),
                    const SizedBox(height: 10),
                    Expanded(child: _body(s)),
                    const SizedBox(height: 6),
                    _Footer(state: s),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BridgeState s) => switch (_tab) {
    Tab.deploy => _DeployTab(
      state: s,
      console: _console,
      onClear: () {
        clearDeployLog();
        setState(() => _console = const []);
      },
    ),
    Tab.logs => _LogsTab(command: _cmd),
    Tab.crashes => _CrashesTab(command: _cmd),
    Tab.apps => _AppsTab(self: s.self, command: _cmd),
    Tab.tests => _TestsTab(command: _cmd),
    Tab.files => const FilesTab(),
  };
}

// ---------------------------------------------------------------- header

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.mdns});

  final BridgeState state;
  final MdnsStatus mdns;

  /// What the badge should say, which is not always what C published.
  ///
  /// C reports what this process is doing, and "Waiting" is correct even when
  /// nothing can reach the console. The gap it cannot see is the name: if
  /// nothing is announcing fluttervita.local, the console is unreachable while
  /// looking healthy from here.
  ///
  /// Only "Waiting" is overridden. A transfer in flight says what it is doing.
  String get _badge {
    if (state.status != 'Waiting') return state.status;
    if (state.ip.isEmpty) return 'No network';
    if (mdns.announced == 0 || (mdns.announced > 0 && !mdns.joined)) {
      return 'Name off';
    }
    return 'Waiting';
  }

  /// One line of everything a host needs to reach this console.
  String get _line {
    final bits = <String>[];
    bits.add(state.ip.isEmpty ? 'no address' : '${state.ip}:${state.port}');
    bits.add(state.self);
    if (mdns.announced < 0) {
      bits.add('name unknown');
    } else if (mdns.announced == 0) {
      bits.add('name not announced');
    } else {
      bits.add(
        'name announced ${mdns.announced}x'
        '${mdns.joined ? "" : ", group not joined"}',
      );
    }
    bits.add(switch (state.lastCmdAge) {
      < 0 => 'no host yet',
      < 60 => 'host ${state.lastCmdAge}s ago',
      _ => 'host ${state.lastCmdAge ~/ 60}m ago',
    });
    return bits.join('   ·   ');
  }

  @override
  Widget build(BuildContext context) {
    final badge = _badge;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                _hostname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 20,
                  height: 1.1,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: state.ip.isEmpty ? const Color(0xFF5A6B7C) : fg,
                ),
              ),
            ),
            const SizedBox(width: 12),
            _Status(status: badge),
            // Only with no network: the one state where the console cannot be
            // fixed from the host, and the fix is three taps deep in Settings.
            if (badge == 'No network') ...[
              const SizedBox(width: 12),
              const Btn(
                text: 'WI-FI',
                onTap: requestWifiSettings,
                colour: danger,
              ),
            ],
          ],
        ),
        Text(
          _line,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, height: 1.6, color: dim),
        ),
        if (state.detail.isNotEmpty)
          Text(
            state.detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.5, color: dim),
          ),
      ],
    );
  }
}

/// The five states of ADR-0016's status model, plus the moment before the
/// first publish. Colour carries the same information as the word.
///
/// It was 26pt and alone on the right for one build. Beside the address it
/// reads as a property of the address, which is what it is, and the tab strip
/// it used to compete with is a rail now.
class _Status extends StatelessWidget {
  const _Status({required this.status});

  final String status;

  static const _colours = <String, Color>{
    'No network': danger,
    // Amber, not red: the console is up and the socket is listening, but
    // nothing is publishing the name, so a host that types fluttervita.local
    // will not find it.
    'Name off': warn,
    'Waiting': accent,
    'Receiving': warn,
    'Installing': warn,
    'Launching': good,
  };

  @override
  Widget build(BuildContext context) {
    final colour = _colours[status] ?? const Color(0xFF5A6B7C);
    return Outlined(
      colour: colour,
      fill: colour.withValues(alpha: 0.16),
      radius: 6,
      width: 1.5,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          fontSize: 14,
          height: 1.0,
          letterSpacing: 1.6,
          fontWeight: FontWeight.w700,
          color: colour,
        ),
      ),
    );
  }
}

/// The navigation rail, extended, as LocalSend draws it above 950 logical
/// pixels (pages/home_page.dart). At 960 x 544 the Vita is on the far side of
/// that threshold, and a rail is the right shape for the screen twice over: a
/// landscape panel has width to spare and no height to spare, and a 60 px row
/// is a target a thumb hits without aiming, which a 32 px tab strip is not.
class _Rail extends StatelessWidget {
  const _Rail({required this.current, required this.onPick});

  final Tab current;
  final ValueChanged<Tab> onPick;

  static const _names = {
    Tab.deploy: 'DEPLOY',
    Tab.logs: 'LOGS',
    Tab.crashes: 'CRASHES',
    Tab.apps: 'APPS',
    Tab.tests: 'TESTS',
    Tab.files: 'FILES',
  };

  static const _glyphs = {
    Tab.deploy: Glyph.deploy,
    Tab.logs: Glyph.logs,
    Tab.crashes: Glyph.crashes,
    Tab.apps: Glyph.apps,
    Tab.tests: Glyph.tests,
    Tab.files: Glyph.files,
  };

  @override
  Widget build(BuildContext context) => Container(
    width: 172,
    color: sunken,
    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 6, bottom: 16),
          child: Row(
            children: [
              FlutterLogo(size: 26),
              SizedBox(width: 10),
              Text(
                'BRIDGE',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.0,
                  letterSpacing: 2.0,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
        for (final t in Tab.values)
          _RailItem(
            glyph: _glyphs[t]!,
            label: _names[t]!,
            selected: t == current,
            onTap: () => onPick(t),
          ),
      ],
    ),
  );
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.glyph,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Glyph glyph;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = selected ? accent : muted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 56,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.16) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            GlyphIcon(glyph, colour: colour, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.0,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                  color: colour,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.state});

  final BridgeState state;

  @override
  Widget build(BuildContext context) {
    // Platform.version is the whole banner; the leading token is the version.
    final dart = Platform.version.split(' ').first;
    final where = state.ip.isEmpty ? 'no address' : '${state.ip}:${state.port}';
    return Text(
      // The tool build carries the Flutter version (3.44.8_0.1.0-13-g9a66045),
      // so the line has room for the engine and the Dart runtime.
      '$where   ·   flutter-vita $kToolBuild'
      '   ·   engine ${kEngineRevision.substring(0, 10)}   ·   dart $dart',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 11,
        height: 1.0,
        fontFamily: 'monospace',
        color: faint,
      ),
    );
  }
}

// ---------------------------------------------------------------- deploy

class _DeployTab extends StatelessWidget {
  const _DeployTab({
    required this.state,
    required this.console,
    required this.onClear,
  });

  final BridgeState state;
  final List<String> console;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Text('${console.length} lines', style: label),
          const Spacer(),
          Btn(
            text: 'CLEAR LOG',
            colour: danger,
            enabled: console.isNotEmpty,
            onTap: onClear,
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (state.receiving) ...[
        _Progress(done: state.recvDone, total: state.recvTotal),
        const SizedBox(height: 8),
      ],
      Expanded(child: _Console(lines: console)),
    ],
  );
}

/// A bar, because the byte counts are already in the status line as prose and
/// prose is the wrong shape for "how much longer".
class _Progress extends StatelessWidget {
  const _Progress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final fraction = total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '${humanBytes(done)} of ${humanBytes(total)}',
              style: const TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: dim,
              ),
            ),
            const Spacer(),
            Text(
              '${(fraction * 100).toStringAsFixed(0)}%',
              style: const TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                color: warn,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 12,
          child: Outlined(
            colour: line,
            fill: sunken,
            radius: 6,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fraction,
                child: Container(
                  decoration: BoxDecoration(
                    color: warn,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The deploy history, oldest at the top, newest pinned to the bottom.
///
/// Reads a file rather than the C side's in-memory ring, which was empty at
/// every launch -- and since `launch` is the last thing the bridge does, that
/// emptied it exactly when you wanted to read it.
///
/// Reversed rather than bottom-aligned: a Column that runs past the panel
/// overflows, and two hundred lines is more than fits.
class _Console extends StatelessWidget {
  const _Console({required this.lines});

  final List<String> lines;

  /// The C side marks the two lines worth picking out of a wall of `put 1 KB`:
  /// an app starting and an app ending. Everything else is the same grey.
  ///
  /// Every line carries a fixed-width "MM-DD HH:MM:SS " ahead of the marker
  /// (STAMP_LEN in bridge_dev.c), so the marker is stepped over rather than
  /// found. A line shorter than the stamp is one this side did not write.
  static const _stampLen = 15;

  /// Checked with the stamp and without it. A log written before timestamps
  /// existed keeps its colours, and so does one written by something that is
  /// not this bridge -- blindly stepping over fifteen characters turned
  /// "+ opened FVTA00009" into "0009" and lost the line.
  static Color _colourOf(String line) {
    final body = line.length > _stampLen ? line.substring(_stampLen) : '';
    for (final candidate in [line, body]) {
      if (candidate.startsWith('+ ')) return good;
      if (candidate.startsWith('- ')) return danger;
    }
    return muted;
  }

  @override
  Widget build(BuildContext context) => Panel(
    padding: 12,
    child: lines.isEmpty
        ? const Empty('no activity yet')
        : ListView.builder(
            reverse: true,
            itemCount: lines.length,
            itemExtent: 18,
            itemBuilder: (_, i) {
              final line = lines[lines.length - 1 - i];
              return Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(color: _colourOf(line)),
              );
            },
          ),
  );
}

// ------------------------------------------------------------------ logs

class _LogsTab extends StatefulWidget {
  const _LogsTab({required this.command});

  final PanelCommand? command;

  @override
  State<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<_LogsTab> {
  List<LogFile> _files = const [];
  LogFile? _open;
  String _text = '';
  String? _note;
  Timer? _watch;

  @override
  void initState() {
    super.initState();
    _refresh();
    _watch = Timer.periodic(const Duration(seconds: 2), (_) => _recheck());
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }

  void _refresh() => setState(() {
    _files = listLogs();
    _open = null;
  });

  /// What the listing looked like, cheap enough to compare every two seconds.
  static String _signature(List<LogFile> files) =>
      files.map((f) => '${f.path}:${f.size}').join('|');

  // A listing read only on entry is a listing that is wrong whenever a file
  // lands while you are already looking at the tab, which is most of the time
  // here: the log of a run that just ended is archived a moment after the
  // bridge comes back and has already listed. So re-read, slowly, and
  // rebuild only when the answer changed.
  //
  // Twice a second was the wrong rate for this and still is -- twenty stat
  // calls at frame rate against a memory card buys nothing. Every two seconds,
  // with the setState skipped when nothing moved, costs a listing and usually
  // no frame.
  void _recheck() {
    if (!mounted) return;
    final now = listLogs();
    final open = _open;
    // A live log is being written while you read it. An archived one is not,
    // so re-reading it would be pure cost.
    if (open != null && open.live) {
      final grown = now.firstWhere(
        (f) => f.path == open.path,
        orElse: () => open,
      );
      if (grown.size != open.size) {
        setState(() {
          _files = now;
          _open = grown;
          _text = grown.read();
        });
        return;
      }
    }
    if (_signature(now) == _signature(_files)) return;
    setState(() => _files = now);
  }

  void _openFile(LogFile f) => setState(() {
    _open = f;
    _text = f.read();
  });

  @override
  void didUpdateWidget(_LogsTab old) {
    super.didUpdateWidget(old);
    final c = widget.command;
    if (c == null || c.seq == old.command?.seq) return;
    if (c.verb == 'back') {
      setState(() => _open = null);
    } else if (c.verb == 'select' && c.index >= 0 && c.index < _files.length) {
      _openFile(_files[c.index]);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_open case final f?) {
      return _Detail(
        title: f.label,
        subtitle: humanBytes(f.size),
        onBack: () => setState(() => _open = null),
        body: Text(_text.isEmpty ? '(empty)' : _text, style: mono),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(_note ?? '${_files.length} logs', style: label),
            const Spacer(),
            Btn(text: 'REFRESH', onTap: _refresh, colour: muted),
            const SizedBox(width: 8),
            Btn(
              text: 'CLEAR ARCHIVE',
              colour: danger,
              onTap: () {
                final n = clearLogs();
                setState(() {
                  _files = listLogs();
                  _note = 'removed $n';
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Panel(
            child: _files.isEmpty
                ? const Empty('no logs yet')
                : ListView.builder(
                    itemCount: _files.length,
                    itemExtent: 36,
                    itemBuilder: (_, i) {
                      final f = _files[i];
                      return ListRow(
                        onTap: () => _openFile(f),
                        children: [
                          if (f.live) ...[
                            const _Dot(good),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              f.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: mono.copyWith(color: fg),
                            ),
                          ),
                          Text(humanBytes(f.size), style: mono),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

// --------------------------------------------------------------- crashes

class _CrashesTab extends StatefulWidget {
  const _CrashesTab({required this.command});

  final PanelCommand? command;

  @override
  State<_CrashesTab> createState() => _CrashesTabState();
}

class _CrashesTabState extends State<_CrashesTab> {
  List<CrashFile> _files = const [];
  CrashFile? _open;
  CoreDump? _dump;
  String _error = '';
  bool _confirmClear = false;
  bool _clearing = false;
  int _cleared = 0;
  int _toClear = 0;
  String? _note;

  Timer? _watch;

  @override
  void initState() {
    super.initState();
    _refresh();
    _watch = Timer.periodic(const Duration(seconds: 2), (_) => _recheck());
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }

  void _refresh() => setState(() {
    _files = listCrashes();
    _open = null;
    _dump = null;
    _confirmClear = false;
  });

  static String _signature(List<CrashFile> files) =>
      files.map((f) => '${f.path}:${f.size}').join('|');

  // The dump lands after the panel has already asked.
  //
  // The shell writes psp2core-*.psp2dmp for a process that has just died while
  // the bridge is being brought back, and a 100 KB dump is not instant. The
  // listing on entry therefore runs against a card that does not have the file
  // yet, and the tab says "nothing has crashed" about the crash you are
  // holding the console to read. This is why a crash sometimes did not appear
  // until REFRESH was pressed.
  //
  // The size is in the signature as well as the name, so a dump that is still
  // being written is picked up again once it settles, rather than being parsed
  // once while truncated and left that way.
  void _recheck() {
    if (!mounted || _clearing || _confirmClear) return;
    final now = listCrashes();
    if (_signature(now) == _signature(_files)) return;
    // Whatever is open stays open. A listing changing under a report you are
    // reading must not close it.
    setState(() => _files = now);
  }

  void _openFile(CrashFile f) {
    CoreDump? dump;
    var error = '';
    try {
      dump = parseCore(f.readBytes());
    } on FormatException catch (e) {
      error = e.message;
    } on FileSystemException catch (e) {
      error = e.osError?.message ?? e.message;
    } catch (e) {
      // A truncated dump can fail in any number of ways inside the note
      // walker, and a panel that dies reading a crash report is worse than one
      // that says it could not read it.
      error = '$e';
    }
    setState(() {
      _open = f;
      _dump = dump;
      _error = error;
    });
  }

  Future<void> _clearAll() async {
    setState(() {
      _confirmClear = false;
      _clearing = true;
      _cleared = 0;
      _toClear = _files.length;
    });
    final removed = await clearCrashes((done, total) {
      if (!mounted) return;
      setState(() {
        _cleared = done;
        _toClear = total;
      });
    });
    if (!mounted) return;
    setState(() {
      _clearing = false;
      _files = listCrashes();
      _note = 'deleted $removed dumps';
    });
  }

  @override
  void didUpdateWidget(_CrashesTab old) {
    super.didUpdateWidget(old);
    final c = widget.command;
    if (c == null || c.seq == old.command?.seq) return;
    if (c.verb == 'back') {
      setState(() => _open = null);
    } else if (c.verb == 'select' && c.index >= 0 && c.index < _files.length) {
      _openFile(_files[c.index]);
    } else if (c.verb == 'action' && c.arg == 'deleteall' && !_clearing) {
      _clearAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_open case final f?) {
      return _Detail(
        title: f.subject,
        subtitle: '${humanBytes(f.size)}   ·   ${f.name}',
        onBack: () => setState(() => _open = null),
        action: Btn(
          text: 'DELETE DUMP',
          colour: danger,
          onTap: () {
            deleteCrash(f);
            _refresh();
          },
        ),
        body: _error.isNotEmpty
            ? Text(
                'could not read this dump: $_error',
                style: mono.copyWith(color: danger),
              )
            : _CrashBody(dump: _dump!),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _note ?? '${_files.length} dumps in ux0:data',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: label,
              ),
            ),
            Btn(text: 'REFRESH', onTap: _refresh, colour: muted),
            const SizedBox(width: 8),
            // Two taps, like a title delete. Nothing else on this console
            // removes dumps, so this button is the only way they ever go -- and
            // a dump is evidence until someone has read it.
            if (_clearing)
              Text(
                'deleting $_cleared of $_toClear',
                style: mono.copyWith(color: warn),
              )
            else if (_confirmClear) ...[
              Btn(
                text: 'YES, DELETE ${_files.length}',
                colour: danger,
                onTap: _clearAll,
              ),
              const SizedBox(width: 8),
              Btn(
                text: 'CANCEL',
                colour: muted,
                onTap: () => setState(() => _confirmClear = false),
              ),
            ] else
              Btn(
                text: 'DELETE ALL',
                colour: danger,
                enabled: _files.isNotEmpty,
                onTap: () => setState(() => _confirmClear = true),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Panel(
            child: _files.isEmpty
                ? const Empty('nothing has crashed')
                : ListView.builder(
                    itemCount: _files.length,
                    itemExtent: 36,
                    itemBuilder: (_, i) {
                      final f = _files[i];
                      return ListRow(
                        onTap: () => _openFile(f),
                        children: [
                          const _Dot(danger),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              f.subject,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: mono.copyWith(color: fg),
                            ),
                          ),
                          Text('${f.stamp}', style: mono),
                          const SizedBox(width: 12),
                          Text(humanBytes(f.size), style: mono),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// Threads, faulted one first, with the fault reason and where the PC landed.
///
/// No symbolication: that needs the ELF the app was built from, which lives on
/// the host. `module@segment + 0xoffset` is what this side can say, and it is
/// enough to tell an engine fault from an app fault without leaving the couch.
class _CrashBody extends StatelessWidget {
  const _CrashBody({required this.dump});

  final CoreDump dump;

  @override
  Widget build(BuildContext context) {
    final culprit = dump.culprit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (culprit == null)
          Text('no thread is marked as stopped', style: mono)
        else
          Outlined(
            expand: true,
            colour: danger,
            fill: danger.withValues(alpha: 0.10),
            radius: 5,
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  culprit.reasonText.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: danger,
                  ),
                ),
                const SizedBox(height: 4),
                Text('in ${culprit.name}', style: mono.copyWith(color: fg)),
                Text(
                  'pc ${hex8(culprit.pc)}  ${dump.locate(culprit.pc)}',
                  style: mono,
                ),
                Text(
                  'lr ${hex8(culprit.lr)}  ${dump.locate(culprit.lr)}',
                  style: mono,
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Text('${dump.threads.length} threads', style: heading),
        const SizedBox(height: 6),
        for (final t in dump.threads) _ThreadRow(thread: t, dump: dump),
        const SizedBox(height: 12),
        Text('${dump.modules.length} modules', style: heading),
        const SizedBox(height: 6),
        for (final m in dump.modules)
          Text(
            '${m.name}   ${m.segments.map((s) => '${s.kind} '
                '${hex8(s.start)}+0x${s.size.toRadixString(16)}').join('   ')}',
            style: mono,
          ),
      ],
    );
  }
}

class _ThreadRow extends StatelessWidget {
  const _ThreadRow({required this.thread, required this.dump});

  final CoreThread thread;
  final CoreDump dump;

  @override
  Widget build(BuildContext context) {
    final where = dump.locate(thread.pc);
    return Outlined(
      colour: thread.faulted ? danger : line,
      fill: thread.faulted ? danger.withValues(alpha: 0.08) : bg,
      radius: 4,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      margin: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  thread.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(
                    color: thread.faulted ? danger : fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(thread.statusText, style: mono),
              const SizedBox(width: 10),
              Text('0x${thread.uid.toRadixString(16)}', style: mono),
            ],
          ),
          Text(
            'pc ${hex8(thread.pc)}${where.isEmpty ? '' : '  $where'}'
            '${thread.faulted ? '   ${thread.reasonText}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: mono.copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ apps

class _AppsTab extends StatefulWidget {
  const _AppsTab({required this.self, required this.command});

  final String self;
  final PanelCommand? command;

  @override
  State<_AppsTab> createState() => _AppsTabState();
}

class _AppsTabState extends State<_AppsTab> {
  List<InstalledApp> _apps = const [];
  String? _note;
  String? _confirming;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() => setState(() {
    _apps = listInstalled(widget.self);
    _confirming = null;
  });

  @override
  void didUpdateWidget(_AppsTab old) {
    super.didUpdateWidget(old);
    final c = widget.command;
    if (c == null || c.seq == old.command?.seq) return;
    if (c.verb == 'back') {
      setState(() => _confirming = null);
    } else if (c.verb == 'select' && c.index >= 0 && c.index < _apps.length) {
      setState(() => _confirming = _apps[c.index].titleId);
    } else if (c.verb == 'action' && c.arg.startsWith('forget ')) {
      final i = int.tryParse(c.arg.substring(7)) ?? -1;
      if (i >= 0 && i < _apps.length) {
        forgetInstalled(_apps[i].titleId);
        setState(() {
          _note = 'forgot ${_apps[i].titleId}';
          _apps = listInstalled(widget.self);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _note ?? 'titles this bridge installed',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: label,
              ),
            ),
            Btn(text: 'REFRESH', onTap: _refresh, colour: muted),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Panel(
            child: _apps.isEmpty
                ? const Empty('nothing installed from here yet')
                : ListView.builder(
                    itemCount: _apps.length,
                    itemExtent: 54,
                    itemBuilder: (_, i) => _AppRow(
                      app: _apps[i],
                      confirming: _confirming == _apps[i].titleId,
                      onConfirm: () =>
                          setState(() => _confirming = _apps[i].titleId),
                      onCancel: () => setState(() => _confirming = null),
                      // Ends this process. The C side answers within two
                      // seconds, so the note is what the screen shows until
                      // the console is somewhere else.
                      onRun: () {
                        requestLaunch(_apps[i].titleId);
                        setState(() => _note = 'launching ${_apps[i].titleId}');
                      },
                      onDelete: () {
                        requestDelete(_apps[i].titleId);
                        setState(() {
                          _confirming = null;
                          _note =
                              'asked the bridge to remove '
                              '${_apps[i].titleId}; watch the DEPLOY log';
                        });
                      },
                      onClear: () {
                        final ok = clearAppCache(_apps[i].titleId);
                        setState(() {
                          _note = ok
                              ? 'cleared ux0:data/${_apps[i].titleId}'
                              : 'could not clear ux0:data/${_apps[i].titleId}';
                          _apps = listInstalled(widget.self);
                        });
                      },
                      onForget: () {
                        forgetInstalled(_apps[i].titleId);
                        setState(() {
                          _note = 'forgot ${_apps[i].titleId}';
                          _apps = listInstalled(widget.self);
                        });
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.confirming,
    required this.onConfirm,
    required this.onCancel,
    required this.onDelete,
    required this.onClear,
    required this.onRun,
    required this.onForget,
  });

  final InstalledApp app;
  final bool confirming;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  final VoidCallback onClear;
  final VoidCallback onRun;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) => ListRow(
    selected: confirming,
    children: [
      // The name leads. The title id is what the machine needs and the
      // name is what you are looking for, and a column of FVTA0000n does
      // not tell you which row is the gallery.
      Expanded(
        flex: 3,
        child: Text(
          app.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: mono.copyWith(color: fg, fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(width: 12),
      SizedBox(
        width: 110,
        child: Text(app.titleId, style: mono.copyWith(color: muted)),
      ),
      Expanded(
        flex: 2,
        child: Text(
          app.present ? 'data ${humanBytes(app.cacheBytes)}' : 'not installed',
          style: app.present ? mono : mono.copyWith(color: warn),
        ),
      ),
      if (confirming) ...[
        Btn(text: 'REALLY DELETE', colour: danger, onTap: onDelete),
        const SizedBox(width: 8),
        Btn(text: 'CANCEL', colour: muted, onTap: onCancel),
      ] else if (!app.present) ...[
        // ux0:app/<id> is gone. There is nothing to run and nothing to
        // delete, and offering either is how this console reached the
        // LiveArea home screen twice.
        Btn(text: 'FORGET', colour: muted, onTap: onForget),
      ] else ...[
        Btn(text: 'RUN', colour: good, onTap: onRun),
        const SizedBox(width: 8),
        Btn(
          text: 'CLEAR DATA',
          colour: warn,
          enabled: app.cacheBytes > 0,
          onTap: onClear,
        ),
        const SizedBox(width: 8),
        Btn(text: 'DELETE', colour: danger, onTap: onConfirm),
      ],
    ],
  );
}

// --------------------------------------------------------------- shared

/// The second level of every list tab: a title, a way back, and a scroller.
class _Detail extends StatelessWidget {
  const _Detail({
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.body,
    this.action,
  });

  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final Widget body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Btn(text: '< BACK', onTap: onBack, colour: muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: heading,
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(fontSize: 11, color: faint),
                ),
              ],
            ),
          ),
          if (action case final a?) a,
        ],
      ),
      const SizedBox(height: 8),
      Expanded(
        child: Panel(
          child: SingleChildScrollView(
            child: Align(alignment: Alignment.topLeft, child: body),
          ),
        ),
      ),
    ],
  );
}

class _Dot extends StatelessWidget {
  const _Dot(this.colour);

  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
  );
}

/// The TESTS tab.
///
/// Starting a run means launching the app that owns the suite and getting out
/// of the way -- see the note at the top of tests.dart for why nothing runs
/// inside the bridge. The bottom half is every result on the card, which is the
/// part that makes this a tab rather than a second RUN button.
class _TestsTab extends StatefulWidget {
  const _TestsTab({required this.command});

  final PanelCommand? command;

  @override
  State<_TestsTab> createState() => _TestsTabState();
}

class _TestsTabState extends State<_TestsTab> {
  List<BenchEntry> _entries = const [];
  List<BenchResult> _results = const [];
  String? _note;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() => setState(() {
    _entries = readManifest();
    _results = readResults();
  });

  @override
  void didUpdateWidget(_TestsTab old) {
    super.didUpdateWidget(old);
    final c = widget.command;
    if (c == null || c.seq == old.command?.seq) return;
    if (c.verb == 'select' && c.index >= 0 && c.index < _entries.length) {
      _start(_entries[c.index]);
    }
  }

  void _start(BenchEntry e) {
    final ok = startRun(e);
    setState(
      () => _note = ok
          ? 'launching ${e.titleId} — it will run ${e.suite} and come back here'
          : '${e.titleId} is not installed',
    );
  }

  @override
  Widget build(BuildContext context) {
    // Results without an engine stamp cannot honestly be read against each
    // other, and saying so once at the top is cheaper than a caveat per row.
    final unstamped = _results.where((r) => !r.comparable).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _note ?? 'suites this console can run',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: label,
              ),
            ),
            Btn(text: 'REFRESH', onTap: _refresh, colour: muted),
          ],
        ),
        const SizedBox(height: 8),
        Panel(
          child: _entries.isEmpty
              ? const Empty('no suites in benchmarks.txt')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final e in _entries)
                      _SuiteRow(entry: e, onRun: () => _start(e)),
                  ],
                ),
        ),
        const SizedBox(height: 10),
        Text(
          unstamped == 0
              ? 'results on this card'
              : 'results on this card — $unstamped with no engine stamp, '
                    'not comparable',
          style: label,
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Panel(
            child: _results.isEmpty
                ? const Empty('nothing has been run here yet')
                : ListView.builder(
                    itemCount: _results.length,
                    itemExtent: 52,
                    itemBuilder: (_, i) => _ResultRow(result: _results[i]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _SuiteRow extends StatelessWidget {
  const _SuiteRow({required this.entry, required this.onRun});

  final BenchEntry entry;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${entry.suite}  ·  ${entry.titleId}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: heading,
              ),
              Text(
                entry.present ? entry.label : 'not installed',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: entry.present ? muted : danger,
                ),
              ),
            ],
          ),
        ),
        Btn(text: 'RUN', colour: good, onTap: onRun, enabled: entry.present),
      ],
    ),
  );
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result});

  final BenchResult result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final when = r.when == null
        ? '—'
        : '${r.when!.month.toString().padLeft(2, '0')}-'
              '${r.when!.day.toString().padLeft(2, '0')} '
              '${r.when!.hour.toString().padLeft(2, '0')}:'
              '${r.when!.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${r.suite}  ·  ${r.renderer}  ·  $when',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: label,
                ),
                Text(
                  '${r.scenes} scenes, ${r.stalled} stalled, '
                  'worst ${r.worstMs.toStringAsFixed(1)} ms'
                  '${r.comparable ? '' : '  · no engine stamp'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: r.comparable
                        ? (r.stalled == 0 ? good : warn)
                        : muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
