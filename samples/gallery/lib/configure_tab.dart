import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vita/flutter_vita.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Every knob `flutter_vita` has, live. main() applies [GalleryConfig.initial]
/// before runApp; each control here sends one delta and the info card shows
/// what the console says afterwards (the clocks, the pixel ratio, the strip).
///
/// The three buttons at the bottom call the phone plugins the gallery does
/// not have a Vita implementation for (share_plus, url_launcher,
/// image_picker): with the fallbacks on, `flutter_vita` answers them in Dart
/// through the embedder's bounce; with them off, the calls fail the way they
/// would in any app that forgot the package.
class GalleryConfig {
  /// What the gallery starts with. Pad and rear touch stay off so the other
  /// tabs behave as before this tab existed.
  static const initial = (
    debugStrip: DebugStrip.shortcut,
    pad: PadMode.none,
    rearTouch: RearTouch.none,
    cpuClock: CpuClock.normal,
    pixelRatio: 1.0,
    onExit: ExitBehaviour.auto,
    psButton: PsButton.system,
    fallbacks: {Fallback.share, Fallback.urlLauncher, Fallback.imagePicker},
  );

  static Future<void> apply() => FlutterVita.configure(
        debugStrip: initial.debugStrip,
        pad: initial.pad,
        rearTouch: initial.rearTouch,
        cpuClock: initial.cpuClock,
        pixelRatio: initial.pixelRatio,
        onExit: initial.onExit,
        psButton: initial.psButton,
        fallbacks: initial.fallbacks,
      );
}

class ConfigureTab extends StatefulWidget {
  const ConfigureTab({super.key});

  @override
  State<ConfigureTab> createState() => _ConfigureTabState();
}

class _ConfigureTabState extends State<ConfigureTab> {
  DebugStrip _strip = GalleryConfig.initial.debugStrip;
  PadMode _pad = GalleryConfig.initial.pad;
  RearTouch _rear = GalleryConfig.initial.rearTouch;
  CpuClock _clock = GalleryConfig.initial.cpuClock;
  double _ratio = GalleryConfig.initial.pixelRatio;
  ExitBehaviour _exit = GalleryConfig.initial.onExit;
  PsButton _ps = GalleryConfig.initial.psButton;
  bool _keepAwake = true;
  bool _watchdog = true;
  final Set<Fallback> _fallbacks = {...GalleryConfig.initial.fallbacks};

  VitaInfo? _info;
  String _last = '';
  final _clip = TextEditingController(text: 'copied on the console');

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _clip.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final i = await FlutterVita.info(refresh: true);
    if (mounted) setState(() => _info = i);
  }

  /// Runs one action, shows what came of it on the card and in the log. A
  /// callback that returns a string has more to say than its name.
  Future<void> _send(String what, Future<Object?> Function() f) async {
    try {
      final r = await f();
      _last = r is String ? r : what;
    } on PlatformException catch (e) {
      _last = '$what failed: ${e.code} ${e.message}';
    } on MissingPluginException {
      _last = '$what: no vita/config on this platform';
    } on Object catch (e) {
      _last = '$what threw: $e';
    }
    await FlutterVita.log('gallery configure: $_last');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        children: [
          _InfoCard(info: _info, last: _last, onRefresh: _refresh),
          const SizedBox(height: 8),
          _Row(
            'Debug strip',
            _seg<DebugStrip>(DebugStrip.values, _strip, (v) {
              setState(() => _strip = v);
              _send('strip ${v.name}',
                  () => FlutterVita.configure(debugStrip: v));
            }),
          ),
          _Row(
            'Pad',
            _seg<PadMode>(PadMode.values, _pad, (v) {
              setState(() => _pad = v);
              _send('pad ${v.name}', () => FlutterVita.configure(pad: v));
            }),
          ),
          _Row(
            'Rear touch',
            _seg<RearTouch>(RearTouch.values, _rear, (v) {
              setState(() => _rear = v);
              _send('rear ${v.name}',
                  () => FlutterVita.configure(rearTouch: v));
            }),
          ),
          _Row(
            'CPU clock',
            _seg<CpuClock>(CpuClock.values, _clock, (v) {
              setState(() => _clock = v);
              _send('clock ${v.name}',
                  () => FlutterVita.configure(cpuClock: v));
            }),
          ),
          _Row(
            'Pixel ratio ${_ratio.toStringAsFixed(2)}',
            Slider(
              value: _ratio,
              min: 0.5,
              max: 2.0,
              divisions: 6,
              label: _ratio.toStringAsFixed(2),
              onChanged: (v) => setState(() => _ratio = v),
              onChangeEnd: (v) => _send('ratio ${v.toStringAsFixed(2)}',
                  () => FlutterVita.configure(pixelRatio: v)),
            ),
          ),
          _Row(
            'Keep awake',
            Switch(
              value: _keepAwake,
              onChanged: (v) {
                setState(() => _keepAwake = v);
                _send('keepAwake $v',
                    () => FlutterVita.configure(keepAwake: v));
              },
            ),
          ),
          _Row(
            'Watchdog',
            Switch(
              value: _watchdog,
              onChanged: (v) {
                setState(() => _watchdog = v);
                _send('watchdog $v', () => FlutterVita.configure(watchdog: v));
              },
            ),
          ),
          _Row(
            'On exit',
            Row(children: [
              _seg<ExitBehaviour>(ExitBehaviour.values, _exit, (v) {
                setState(() => _exit = v);
                _send('exit ${v.name}', () => FlutterVita.configure(onExit: v));
              }),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => SystemNavigator.pop(),
                child: const Text('SystemNavigator.pop()'),
              ),
            ]),
          ),
          _Row(
            'PS button',
            _seg<PsButton>(PsButton.values, _ps, (v) {
              setState(() => _ps = v);
              _send('psButton ${v.name}',
                  () => FlutterVita.configure(psButton: v));
            }),
          ),
          _Row(
            'Clipboard',
            Row(children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _clip,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _send('clipboard set',
                    () => Clipboard.setData(ClipboardData(text: _clip.text))),
                child: const Text('Copy'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _send('clipboard get', () async {
                  final d = await Clipboard.getData(Clipboard.kTextPlain);
                  _clip.text = d?.text ?? '';
                  return 'clipboard get: "${d?.text}"';
                }),
                child: const Text('Paste'),
              ),
            ]),
          ),
          _Row(
            'Fallbacks',
            Wrap(spacing: 4, children: [
              for (final f in Fallback.values)
                FilterChip(
                  label: Text(f.name),
                  selected: _fallbacks.contains(f),
                  onSelected: (on) {
                    setState(() => on ? _fallbacks.add(f) : _fallbacks.remove(f));
                    _send('fallbacks ${_fallbacks.map((e) => e.name).join(',')}',
                        () => FlutterVita.configure(fallbacks: {..._fallbacks}));
                  },
                ),
            ]),
          ),
          _Row(
            'Phone plugins',
            Wrap(spacing: 8, runSpacing: 4, children: [
              OutlinedButton(
                onPressed: () => _send('share_plus', () async {
                  final r = await SharePlus.instance.share(ShareParams(
                    text: 'Hello from the gallery, ${DateTime.now()}',
                    subject: 'gallery',
                  ));
                  return 'share_plus: ${r.status.name} ${r.raw}';
                }),
                child: const Text('Share text'),
              ),
              OutlinedButton(
                onPressed: () => _send('url_launcher mailto', () async {
                  final ok = await launchUrl(
                      Uri.parse('mailto:dev@fluttervita.local?subject=hi'));
                  return 'url_launcher mailto: $ok';
                }),
                child: const Text('mailto:'),
              ),
              OutlinedButton(
                onPressed: () => _send('url_launcher https', () async {
                  final ok = await launchUrl(Uri.parse('https://flutter.dev'));
                  return 'url_launcher https: $ok';
                }),
                child: const Text('https://'),
              ),
              OutlinedButton(
                onPressed: () => _send('image_picker', () async {
                  final x = await ImagePicker()
                      .pickImage(source: ImageSource.gallery);
                  return 'image_picker: ${x?.path ?? '(cancelled)'}';
                }),
                child: const Text('Pick image'),
              ),
            ]),
          ),
        ],
      );

  Widget _seg<T extends Enum>(
    List<T> values,
    T current,
    ValueChanged<T> onPick,
  ) =>
      SegmentedButton<T>(
        segments: [
          for (final v in values) ButtonSegment(value: v, label: Text(v.name)),
        ],
        selected: {current},
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onSelectionChanged: (s) => onPick(s.first),
      );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.control);
  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 150,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFFB8C0D0))),
            ),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: control)),
          ],
        ),
      );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.info,
    required this.last,
    required this.onRefresh,
  });
  final VitaInfo? info;
  final String last;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final i = info;
    final text = i == null
        ? 'FlutterVita.info(): null (not a Vita, or no vita/config)'
        : '${i.titleId}  engine ${i.engineRevision}  flutter ${i.flutterVersion}'
            '  embedder ${i.embedderVersion}${i.release ? '  release' : ''}\n'
            '${i.backend}  ratio ${i.pixelRatio.toStringAsFixed(2)}'
            '  arm ${i.armMhz} MHz  gpu ${i.gpuMhz} MHz'
            '  battery ${i.batteryPercent}%${i.charging ? ' charging' : ''}'
            '  free ${i.freeMemoryK ~/ 1024} MB / cdram ${i.freeCdramK ~/ 1024} MB';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF161A23),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace', height: 1.4)),
                if (last.isNotEmpty)
                  Text('last: $last',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF8FB3FF))),
              ],
            ),
          ),
          IconButton(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'info again',
          ),
        ],
      ),
    );
  }
}
