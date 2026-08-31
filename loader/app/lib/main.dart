// The loader's screen. ADR-0016.
//
// A header that says where the console is and what it is doing, four tabs, and
// a footer of versions. The header is the line that justifies the screen --
// when this console's Wi-Fi drops and returns on a different address, the
// loader is the only thing that knows where it went.
//
// The address shown is the mDNS name, not the number. Every tool in tools/
// defaults to flutter-vita.local and the dev server answers for it, so the
// number is a fallback and belongs in the footer where a fallback belongs.
//
// The reliability-critical half (loader_dev.c) owns the port and republishes
// ux0:data/flutter-vita/loader-state.txt on every change; polling a file is
// what lets that half stay free of a platform channel. If the engine never
// starts, only this is lost. See device.dart for the one request that travels
// the other way.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'build_info.dart';
import 'device.dart';
import 'psp2dmp.dart';
import 'theme.dart';

/// The name every tool in tools/ resolves, answered by the dev server's mDNS.
const _hostname = 'flutter-vita.local';

void main() => runApp(const LoaderApp());

enum Tab { deploy, logs, crashes, apps }

class LoaderApp extends StatefulWidget {
  const LoaderApp({super.key});

  @override
  State<LoaderApp> createState() => _LoaderAppState();
}

class _LoaderAppState extends State<LoaderApp> {
  LoaderState _state = const LoaderState();
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

  void _poll() {
    final cmd = readPanelRequest(_cmdSeq + 1);
    if (cmd != null) {
      _cmdSeq = cmd.seq;
      setState(() {
        if (cmd.verb == 'tab') {
          _tab = Tab.values.firstWhere((t) => t.name == cmd.arg,
              orElse: () => _tab);
          // A tab switch is handled here and not forwarded: the tab widget
          // being asked for may not be built yet.
          _cmd = null;
        } else {
          _cmd = cmd;
        }
      });
    }

    final next = LoaderState.read();
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
                    _Header(state: s),
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

  Widget _body(LoaderState s) => switch (_tab) {
        Tab.deploy => _DeployTab(state: s, console: _console),
        Tab.logs => _LogsTab(command: _cmd),
        Tab.crashes => _CrashesTab(command: _cmd),
        Tab.apps => _AppsTab(self: s.self, command: _cmd),
      };
}

// ---------------------------------------------------------------- header

class _Header extends StatelessWidget {
  const _Header({required this.state});

  final LoaderState state;

  @override
  Widget build(BuildContext context) {
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
            _Status(status: state.status),
          ],
        ),
        if (state.detail.isNotEmpty)
          Text(state.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, height: 1.5, color: dim)),
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
    'Waiting': accent,
    'Receiving': warn,
    'Installing': warn,
    'Launching': good,
  };

  @override
  Widget build(BuildContext context) {
    final colour = _colours[status] ?? const Color(0xFF5A6B7C);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.16),
        border: Border.all(color: colour, width: 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
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
  };

  static const _glyphs = {
    Tab.deploy: Glyph.deploy,
    Tab.logs: Glyph.logs,
    Tab.crashes: Glyph.crashes,
    Tab.apps: Glyph.apps,
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
              child: Row(children: [
                FlutterLogo(size: 26),
                SizedBox(width: 10),
                Text('LOADER',
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.0,
                      letterSpacing: 2.0,
                      fontWeight: FontWeight.w700,
                      color: fg,
                    )),
              ]),
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

  final LoaderState state;

  @override
  Widget build(BuildContext context) {
    // Platform.version is the whole banner; the leading token is the version.
    final dart = Platform.version.split(' ').first;
    final where = state.ip.isEmpty ? 'no address' : '${state.ip}:${state.port}';
    return Text(
      '$where   ·   loader $kLoaderVersion   ·   flutter $kFlutterVersion'
      '   ·   engine ${kEngineRevision.substring(0, 10)}   ·   dart $dart',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
          fontSize: 11, height: 1.0, fontFamily: 'monospace', color: faint),
    );
  }
}

// ---------------------------------------------------------------- deploy

class _DeployTab extends StatelessWidget {
  const _DeployTab({required this.state, required this.console});

  final LoaderState state;
  final List<String> console;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
            Text('${humanBytes(done)} of ${humanBytes(total)}',
                style: const TextStyle(
                    fontSize: 13, fontFamily: 'monospace', color: dim)),
            const Spacer(),
            Text('${(fraction * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    color: warn)),
          ],
        ),
        const SizedBox(height: 5),
        Container(
          height: 12,
          decoration: BoxDecoration(
            color: sunken,
            border: Border.all(color: line),
            borderRadius: BorderRadius.circular(6),
          ),
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
      ],
    );
  }
}

/// The deploy history, oldest at the top, newest pinned to the bottom.
///
/// It used to be the C side's in-memory ring, which meant it was empty at
/// every launch -- and since `launch` is the last thing the loader does, that
/// emptied it exactly when you wanted to read it. It reads a file now, so a
/// deploy is still on screen after the app it deployed has come and gone.
///
/// Reversed rather than bottom-aligned: a Column that runs past the panel
/// overflows, and two hundred lines is more than fits. Reverse puts the newest
/// line at the bottom and makes the rest scroll back under a thumb.
class _Console extends StatelessWidget {
  const _Console({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Panel(
        padding: 12,
        child: lines.isEmpty
            ? const Empty('no activity yet')
            : ListView.builder(
                reverse: true,
                itemCount: lines.length,
                itemExtent: 18,
                itemBuilder: (_, i) => Text(
                  lines[lines.length - 1 - i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono,
                ),
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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  // Listings are read on entry and on demand, never on the poll timer: this is
  // a memory card, and twenty stat calls twice a second to keep a list fresh
  // that changes once per deploy is a bad trade.
  void _refresh() => setState(() {
        _files = listLogs();
        _open = null;
      });

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
        Row(children: [
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
        ]),
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
                            child: Text(f.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: mono.copyWith(color: fg)),
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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() => setState(() {
        _files = listCrashes();
        _open = null;
        _dump = null;
        _confirmClear = false;
      });

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
            ? Text('could not read this dump: $_error',
                style: mono.copyWith(color: danger))
            : _CrashBody(dump: _dump!),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: Text(_note ?? '${_files.length} dumps in ux0:data',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: label),
          ),
          Btn(text: 'REFRESH', onTap: _refresh, colour: muted),
          const SizedBox(width: 8),
          // Two taps, like a title delete. Nothing else on this console
          // removes dumps, so this button is the only way they ever go -- and
          // a dump is evidence until someone has read it.
          if (_clearing)
            Text('deleting $_cleared of $_toClear',
                style: mono.copyWith(color: warn))
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
        ]),
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
                            child: Text(f.subject,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: mono.copyWith(color: fg)),
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
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: danger.withValues(alpha: 0.10),
              border: Border.all(color: danger),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(culprit.reasonText.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 17,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: danger)),
                const SizedBox(height: 4),
                Text('in ${culprit.name}', style: mono.copyWith(color: fg)),
                Text('pc ${hex8(culprit.pc)}  ${dump.locate(culprit.pc)}',
                    style: mono),
                Text('lr ${hex8(culprit.lr)}  ${dump.locate(culprit.lr)}',
                    style: mono),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: thread.faulted ? danger.withValues(alpha: 0.08) : bg,
        border: Border.all(color: thread.faulted ? danger : line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(thread.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(
                      color: thread.faulted ? danger : fg,
                      fontWeight: FontWeight.w600)),
            ),
            Text(thread.statusText, style: mono),
            const SizedBox(width: 10),
            Text('0x${thread.uid.toRadixString(16)}', style: mono),
          ]),
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: Text(_note ?? 'titles this loader installed',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: label),
          ),
          Btn(text: 'REFRESH', onTap: _refresh, colour: muted),
        ]),
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
                          _note = 'asked the loader to remove '
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
          SizedBox(
            width: 110,
            child: Text(app.titleId,
                style: mono.copyWith(color: fg, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text(
              app.present
                  ? 'data ${humanBytes(app.cacheBytes)}'
                  : 'not installed',
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
          Row(children: [
            Btn(text: '< BACK', onTap: onBack, colour: muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: heading),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono.copyWith(fontSize: 11, color: faint)),
                ],
              ),
            ),
            if (action case final a?) a,
          ]),
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
