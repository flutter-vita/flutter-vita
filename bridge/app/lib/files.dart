// The FILES tab: the memory card, and what a file on it does when opened.
//
// A browser on the left (the mounts, then directories, then files, with
// vita_file_browser's path rules) and a preview on the right that depends
// on the kind of file:
//
//   image      drawn with Image.file, the engine's own codecs
//   audio      played through audioplayers_vita: WAV through a MAIN port,
//              AAC through sceAvPlayer, MP3 through sceAudiodec, the
//              console's own decoder
//   video      not drawn: a video frame needs a texture route the
//              embedder does not have yet. The sound track plays.
//   vpk        installed by the bridge's own C: unpacked into
//              ux0:data/pkg, a package header written for its title id,
//              promoted, the LiveArea art copied in. Progress comes back
//              through a file (device.dart, InstallProgress). VitaShell
//              stays on offer as the second route, and closes the bridge.
//   text       the first 64 KB, monospace
//   anything   name, size, modified
//
// Nothing here deletes, moves or writes. No Material and no ink: rows are
// GestureDetectors 40 px tall, drawn once, like the rest of the panel.

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:vita_file_browser/vita_file_browser.dart';

import 'device.dart';
import 'theme.dart';

enum FileKind { directory, image, audio, video, vpk, text, other }

FileKind kindOf(FileSystemEntity e) {
  if (e is Directory) return FileKind.directory;
  final ext = VitaPaths.extensionOf(VitaPaths.basename(e.path));
  return switch (ext) {
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => FileKind.image,
    'wav' || 'm4a' || 'aac' || 'mp3' || 'ogg' || 'flac' => FileKind.audio,
    'mp4' || 'm4v' || 'mov' || 'mkv' || 'avi' || 'webm' => FileKind.video,
    'vpk' => FileKind.vpk,
    'txt' ||
    'md' ||
    'json' ||
    'log' ||
    'yaml' ||
    'yml' ||
    'ini' ||
    'cfg' ||
    'csv' ||
    'xml' ||
    'dart' ||
    'c' ||
    'h' ||
    'sh' => FileKind.text,
    _ => FileKind.other,
  };
}

String sizeOf(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

class FilesTab extends StatefulWidget {
  const FilesTab({super.key});

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  /// Null is the list of mounts.
  String? _dir;
  List<FileSystemEntity> _entries = const [];
  String? _error;
  String? _selected;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _open(String path) {
    List<FileSystemEntity> listed;
    try {
      listed = Directory(path).listSync(followLinks: false);
    } catch (e) {
      setState(() {
        _dir = path;
        _entries = const [];
        _error = '$e';
        _selected = null;
      });
      return;
    }
    listed.sort((a, b) {
      final ad = a is Directory, bd = b is Directory;
      if (ad != bd) return ad ? -1 : 1;
      return VitaPaths.basename(
        a.path,
      ).toLowerCase().compareTo(VitaPaths.basename(b.path).toLowerCase());
    });
    setState(() {
      _dir = path;
      _entries = listed;
      _error = null;
      _selected = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _up() {
    final here = _dir;
    if (here == null) return;
    final parent = VitaPaths.parentOf(here);
    if (parent == null) {
      setState(() {
        _dir = null;
        _entries = const [];
        _error = null;
        _selected = null;
      });
    } else {
      _open(parent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dir = _dir;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Head(
                path: dir ?? 'Mounts',
                onUp: dir == null ? null : _up,
                count: dir == null ? null : _entries.length,
              ),
              Container(height: 1, color: line),
              Expanded(child: dir == null ? _roots() : _list()),
            ],
          ),
        ),
        Container(width: 1, color: line),
        SizedBox(
          width: 360,
          child: _selected == null
              ? const _Hint()
              : _Preview(key: ValueKey(_selected), path: _selected!),
        ),
      ],
    );
  }

  Widget _roots() {
    final rows = <(String, String, FileKind)>[
      for (final (path, label) in VitaPaths.roots())
        (path, label, FileKind.directory),
      ('app0:', 'this app, read-only', FileKind.directory),
    ];
    return ListView(
      controller: _scroll,
      children: [
        for (final (path, label, kind) in rows)
          _Row(
            kind: kind,
            name: '$path  $label',
            trailing: '',
            selected: false,
            onTap: () => _open(path),
          ),
      ],
    );
  }

  Widget _list() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(_error!, style: mono),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('empty', style: mono));
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: _entries.length,
      itemExtent: _Row.height,
      itemBuilder: (context, i) {
        final e = _entries[i];
        String trailing = '';
        if (e is File) {
          try {
            trailing = sizeOf(e.lengthSync());
          } catch (_) {
            trailing = '?';
          }
        }
        return _Row(
          kind: kindOf(e),
          name: VitaPaths.basename(e.path),
          trailing: trailing,
          selected: e.path == _selected,
          onTap: () {
            if (e is Directory) {
              _open(e.path);
            } else {
              setState(() => _selected = e.path);
            }
          },
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.kind,
    required this.name,
    required this.trailing,
    required this.selected,
    required this.onTap,
  });

  static const double height = 40;

  final FileKind kind;
  final String name;
  final String trailing;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      height: height,
      color: selected ? accent.withValues(alpha: 0.14) : null,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          FileGlyph(kind, colour: kind == FileKind.directory ? accent : dim),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: mono.copyWith(color: fg),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(trailing, style: mono.copyWith(fontSize: 12, color: faint)),
        ],
      ),
    ),
  );
}

class _Head extends StatelessWidget {
  const _Head({required this.path, required this.onUp, required this.count});
  final String path;
  final VoidCallback? onUp;
  final int? count;

  @override
  Widget build(BuildContext context) => Container(
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Row(
      children: [
        Btn(text: '↑ UP', onTap: onUp ?? () {}, enabled: onUp != null),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            path,
            style: mono.copyWith(color: fg),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (count != null) Text('$count entries', style: label),
      ],
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(16),
    child: Text(
      'Tap a file. Images are drawn here; WAV and AAC play; a vpk installs; '
      'text is read. Video has no picture yet, only its sound.',
      style: label,
    ),
  );
}

class _Preview extends StatelessWidget {
  const _Preview({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    final kind = kindOf(file);
    int size = 0;
    DateTime? modified;
    try {
      final st = file.statSync();
      size = st.size;
      modified = st.modified;
    } catch (_) {}
    final facts =
        '${sizeOf(size)}${modified == null ? '' : '  ${modified.toString().substring(0, 16)}'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Text(
            VitaPaths.basename(path),
            style: heading,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(facts, style: label),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: switch (kind) {
            FileKind.image => _ImageView(path: path),
            FileKind.audio => _AudioView(path: path),
            FileKind.video => _AudioView(path: path, video: true),
            FileKind.vpk => _VpkView(path: path),
            FileKind.text => _TextView(path: path),
            _ => const SizedBox(),
          },
        ),
      ],
    );
  }
}

class _ImageView extends StatelessWidget {
  const _ImageView({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xFF000000),
    margin: const EdgeInsets.all(10),
    child: Image.file(
      File(path),
      fit: BoxFit.contain,
      errorBuilder: (context, e, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: Text('cannot decode: $e', style: label),
      ),
    ),
  );
}

class _TextView extends StatelessWidget {
  const _TextView({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    String text;
    try {
      final f = File(path);
      final n = f.lengthSync();
      final raf = f.openSync();
      final bytes = raf.readSync(n < 65536 ? n : 65536);
      raf.closeSync();
      text = String.fromCharCodes(bytes);
      if (n > 65536) text += '\n… ${sizeOf(n - 65536)} more';
    } catch (e) {
      text = '$e';
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Text(text, style: mono.copyWith(fontSize: 11, height: 1.3)),
    );
  }
}

/// A vpk: the bridge installs it, or VitaShell does.
///
/// INSTALL writes `install <path>` to the request file; the C side's
/// install thread reports through the progress file, polled here three
/// times a second until it says done or failed. VitaShell is the other
/// route: the embedder's `vita/shell` channel writes VitaShell's lastdir and
/// launches it in the file's folder, which closes the bridge.
class _VpkView extends StatefulWidget {
  const _VpkView({required this.path});
  final String path;

  @override
  State<_VpkView> createState() => _VpkViewState();
}

class _VpkViewState extends State<_VpkView> {
  static const _shell = MethodChannel('vita/shell', JSONMethodCodec());
  bool? _available;
  String _note = '';
  InstallProgress? _progress;
  Timer? _poll;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    _shell
        .invokeMethod<bool>('available')
        .then(
          (v) {
            if (mounted) setState(() => _available = v ?? false);
          },
          onError: (Object e) {
            if (mounted) setState(() => _available = false);
          },
        );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _install() {
    requestInstall(widget.path);
    setState(() {
      _installing = true;
      _progress = null;
      _note = '';
    });
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final p = InstallProgress.read();
      if (p == null || !mounted) return;
      setState(() => _progress = p);
      if (p.finished) {
        _poll?.cancel();
        setState(() => _installing = false);
      }
    });
  }

  Future<void> _open() async {
    final i = widget.path.lastIndexOf('/');
    final folder = i <= 0 ? widget.path : widget.path.substring(0, i);
    setState(() => _note = 'handing over to VitaShell at $folder…');
    try {
      final ok = await _shell.invokeMethod<bool>('openFolder', {
        'path': folder,
      });
      if (ok != true && mounted) {
        setState(() => _note = 'VitaShell did not start');
      }
    } catch (e) {
      if (mounted) setState(() => _note = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final done = p != null && p.phase == 'done';
    final failed = p != null && p.phase == 'failed';
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'A package for the console. The bridge unpacks it, writes its '
            'package header and promotes it; the title then shows in APPS '
            'and on the home screen.',
            style: label,
          ),
          const SizedBox(height: 14),
          Btn(
            text: _installing ? 'INSTALLING…' : 'INSTALL',
            enabled: !_installing,
            onTap: _install,
          ),
          const SizedBox(height: 10),
          if (p != null) _InstallLine(progress: p),
          if (done) ...[
            const SizedBox(height: 10),
            Btn(
              text: 'RUN ${p.name} (CLOSES BRIDGE)',
              colour: good,
              onTap: () => requestLaunch(p.name),
            ),
          ],
          if (failed) ...[
            const SizedBox(height: 6),
            const Text('More in the DEPLOY tab\'s log.', style: label),
          ],
          const SizedBox(height: 18),
          const Text('Or hand it to VitaShell:', style: label),
          const SizedBox(height: 8),
          Btn(
            text: _available == null
                ? 'LOOKING FOR VITASHELL…'
                : _available!
                ? 'OPEN IN VITASHELL (CLOSES BRIDGE)'
                : 'VITASHELL IS NOT INSTALLED',
            colour: warn,
            enabled: _available == true && !_installing,
            onTap: _open,
          ),
          const SizedBox(height: 10),
          Text(_note, style: label),
        ],
      ),
    );
  }
}

/// One line of the install's progress, with a bar while it has a size.
class _InstallLine extends StatelessWidget {
  const _InstallLine({required this.progress});
  final InstallProgress progress;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final f = p.fraction;
    final colour = switch (p.phase) {
      'done' => good,
      'failed' => danger,
      _ => accent,
    };
    final text = switch (p.phase) {
      'unpacking' => 'unpacking ${p.name}',
      'header' => 'writing the package header for ${p.name}',
      'promoting' => 'promoting ${p.name}… the promoter takes a few seconds',
      'art' => 'copying the LiveArea art',
      'done' => 'installed ${p.name}',
      'failed' => 'failed: ${p.name}',
      _ => '${p.phase} ${p.name}',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: label.copyWith(color: colour)),
        if (f != null) ...[
          const SizedBox(height: 6),
          Stack(
            children: [
              Container(height: 6, color: sunken),
              FractionallySizedBox(
                widthFactor: f,
                child: Container(height: 6, color: colour),
              ),
            ],
          ),
          // The byte count belongs to the unpack; `done` carries 1 of 1 to
          // fill the bar and has nothing to say in bytes.
          if (!p.finished) ...[
            const SizedBox(height: 4),
            Text(
              '${humanBytes(p.done)} of ${humanBytes(p.total)}',
              style: label,
            ),
          ],
        ],
      ],
    );
  }
}

/// One audioplayers player for the file, with transport and a position bar.
class _AudioView extends StatefulWidget {
  const _AudioView({required this.path, this.video = false});
  final String path;
  final bool video;

  @override
  State<_AudioView> createState() => _AudioViewState();
}

class _AudioViewState extends State<_AudioView> {
  final _player = AudioPlayer();
  final _subs = <StreamSubscription<Object?>>[];
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration? _duration;
  String _log = '';

  @override
  void initState() {
    super.initState();
    _subs.add(
      _player.onPlayerStateChanged.listen((s) {
        if (mounted) setState(() => _state = s);
      }),
    );
    _subs.add(
      _player.onPositionChanged.listen((p) {
        if (mounted) setState(() => _position = p);
      }),
    );
    _subs.add(
      _player.onDurationChanged.listen((d) {
        if (mounted) setState(() => _duration = d);
      }),
    );
    _subs.add(
      _player.eventStream.listen(
        (_) {},
        onError: (Object e) {
          if (mounted) setState(() => _log = '$e');
        },
      ),
    );
    _play();
  }

  Future<void> _play() async {
    setState(() => _log = '');
    try {
      await _player.play(DeviceFileSource(widget.path));
    } catch (e) {
      if (mounted) setState(() => _log = '$e');
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  String _t(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final dur = _duration;
    final progress = dur == null || dur.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
    final playing = _state == PlayerState.playing;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.video)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                'No picture: a video frame needs a texture route the '
                'embedder does not have yet. The sound track plays.',
                style: label,
              ),
            ),
          Row(
            children: [
              Btn(
                text: playing ? 'PAUSE' : 'PLAY',
                colour: good,
                onTap: () => playing
                    ? _player.pause()
                    : _state == PlayerState.paused
                    ? _player.resume()
                    : _play(),
              ),
              const SizedBox(width: 8),
              Btn(text: 'STOP', onTap: () => _player.stop()),
              const SizedBox(width: 12),
              Text(
                '${_t(_position)}${dur == null ? '' : ' / ${_t(dur)}'}  ${_state.name}',
                style: mono.copyWith(color: fg),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // The position bar: two rectangles, no Material.
          Container(
            height: 4,
            color: line,
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: progress,
              child: Container(color: accent),
            ),
          ),
          const SizedBox(height: 10),
          Text(_log, style: label.copyWith(color: danger)),
        ],
      ),
    );
  }
}

/// The kinds a row can show, painted like the rail's glyphs: MaterialIcons
/// is not in this app.
class FileGlyph extends StatelessWidget {
  const FileGlyph(this.kind, {super.key, required this.colour, this.size = 18});

  final FileKind kind;
  final Color colour;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _FileGlyphPainter(kind, colour)),
  );
}

class _FileGlyphPainter extends CustomPainter {
  _FileGlyphPainter(this.kind, this.colour);

  final FileKind kind;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 24.0;
    final fill = Paint()..color = colour;
    final stroke = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset p(double x, double y) => Offset(x * u, y * u);
    // A sheet with a folded corner, under every kind but the folder.
    void sheet() {
      canvas.drawPath(
        Path()
          ..moveTo(5 * u, 3 * u)
          ..lineTo(14 * u, 3 * u)
          ..lineTo(19 * u, 8 * u)
          ..lineTo(19 * u, 21 * u)
          ..lineTo(5 * u, 21 * u)
          ..close(),
        stroke,
      );
    }

    switch (kind) {
      case FileKind.directory:
        canvas.drawPath(
          Path()
            ..moveTo(3 * u, 6 * u)
            ..lineTo(10 * u, 6 * u)
            ..lineTo(12 * u, 8 * u)
            ..lineTo(21 * u, 8 * u)
            ..lineTo(21 * u, 19 * u)
            ..lineTo(3 * u, 19 * u)
            ..close(),
          fill,
        );
      case FileKind.image:
        canvas.drawRect(Rect.fromLTRB(3 * u, 5 * u, 21 * u, 19 * u), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(5 * u, 17 * u)
            ..lineTo(10 * u, 11 * u)
            ..lineTo(13 * u, 14 * u)
            ..lineTo(16 * u, 12 * u)
            ..lineTo(19 * u, 17 * u),
          stroke,
        );
        canvas.drawCircle(p(16, 9), 1.5 * u, fill);
      case FileKind.audio:
        canvas.drawLine(p(10, 18), p(10, 5), stroke);
        canvas.drawLine(p(10, 5), p(19, 3), stroke);
        canvas.drawLine(p(19, 3), p(19, 15), stroke);
        canvas.drawCircle(p(7.5, 18), 2.5 * u, fill);
        canvas.drawCircle(p(16.5, 15), 2.5 * u, fill);
      case FileKind.video:
        canvas.drawRect(Rect.fromLTRB(3 * u, 5 * u, 21 * u, 19 * u), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(10 * u, 9 * u)
            ..lineTo(16 * u, 12 * u)
            ..lineTo(10 * u, 15 * u)
            ..close(),
          fill,
        );
      case FileKind.vpk:
        canvas.drawPath(
          Path()
            ..moveTo(4 * u, 16 * u)
            ..lineTo(4 * u, 20 * u)
            ..lineTo(20 * u, 20 * u)
            ..lineTo(20 * u, 16 * u),
          stroke,
        );
        canvas.drawLine(p(12, 3), p(12, 14), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(8 * u, 10 * u)
            ..lineTo(12 * u, 14 * u)
            ..lineTo(16 * u, 10 * u),
          stroke,
        );
      case FileKind.text:
        sheet();
        for (final y in const [10.0, 13.5, 17.0]) {
          canvas.drawLine(p(8, y), p(16, y), stroke);
        }
      case FileKind.other:
        sheet();
    }
  }

  @override
  bool shouldRepaint(_FileGlyphPainter old) =>
      old.kind != kind || old.colour != colour;
}
