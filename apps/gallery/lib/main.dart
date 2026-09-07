import 'package:flutter/material.dart';

import 'bench/bench_page.dart';
import 'bench/runner.dart';

/// What this port looks like, judged by eye.
///
/// Separate from the conformance suite because of how each produces a verdict.
/// Conformance computes a boolean about itself, which is what makes it runnable
/// on every deploy. A widget either looks right or it does not, and no app can
/// assess that about itself.
///
/// Folding them together would cost the conformance run its automation.
void main() {
  // A positive control for the engine's log_message_callback. Dart print had
  // no destination on this port until 2026-08-24 -- it went to a stdout the
  // device does not own -- so the conformance app writes its results to a file
  // by hand. If this line does not appear in m3.log, that is still true and
  // nothing else in the log about Dart can be trusted to be complete.
  print('gallery: dart print reaches the engine log');
  FlutterError.onError = (details) {
    print('gallery: FlutterError ${details.exceptionAsString()}');
    FlutterError.presentError(details);
  };
  // Started by the host rather than by a person: tools/bench.sh writes
  // bench.on and relaunches, and the app goes straight to the benchmark and
  // runs it unattended. A person opening the gallery normally never sees this
  // branch. ADR-0017.
  runApp(GalleryApp(autoBench: switchOn(kSwitchPath)));
}

class GalleryApp extends StatelessWidget {
  const GalleryApp({super.key, this.autoBench = false});

  final bool autoBench;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF4C8DFF),
          scaffoldBackgroundColor: const Color(0xFF10131A),
        ),
        home: autoBench ? const BenchPage(autoRun: true) : const Gallery(),
      );
}

class Gallery extends StatefulWidget {
  const Gallery({super.key});
  @override
  State<Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<Gallery> {
  final _single = TextEditingController(text: 'tap to edit');
  final _multi = TextEditingController();
  final _obscured = TextEditingController();
  var _checked = true;
  var _slider = 0.4;
  var _choice = 0;
  var _taps = 0;

  @override
  void initState() {
    super.initState();
    // The readback line below is the point of this column -- it shows what the
    // *controllers* hold, which is what proves the IME result reached the
    // framework rather than being painted into the field by the dialog. A
    // TextField repaints itself when its controller changes; the summary is a
    // sibling and does not, so without these it reported the value from before
    // the edit and looked like the round trip had failed.
    for (final c in [_single, _multi, _obscured]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _single.dispose();
    _multi.dispose();
    _obscured.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('flutter-vita gallery',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                  // The gallery's stated job is "what this port looks like,
                  // judged by eye"; this is the other half, added by ADR-0017,
                  // and it produces numbers instead of impressions.
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const BenchPage()),
                    ),
                    child: const Text('benchmark'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Two columns, because 960x544 is wide and short: a single
                  // scrolling column would put half of this below the fold on
                  // a panel with no scrollbar and no keyboard to page with.
                  Expanded(child: _textColumn()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _widgetColumn()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Everything that needs the IME. This is the half that Phase 8 is about:
  /// tapping any of these should raise the system keyboard and the typed text
  /// should come back into the field.
  Widget _textColumn() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('text input', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _single,
            decoration: const InputDecoration(
              labelText: 'single line',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _multi,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'multiline',
              hintText: 'several lines',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _obscured,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'obscured',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          // Reads back what the controllers hold, so a screenshot alone shows
          // whether the IME result actually reached the framework rather than
          // just being painted into the field by the dialog.
          Text(
            'single: "${_single.text}"\n'
            'multi: ${_multi.text.split('\n').length} line(s)\n'
            'obscured: ${_obscured.text.length} char(s)',
            style: const TextStyle(
                fontSize: 11, fontFamily: 'monospace', color: Color(0xFF8B94A7)),
          ),
        ],
      );

  /// Everything that does not. Proves the render path across the widget
  /// families an ordinary app is built from — and it is deliberately touch
  /// operable, because touch is the only input this port has until ADR-0010's
  /// layer 1 lands.
  Widget _widgetColumn() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('widgets', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Row(
            children: [
              FilledButton(
                onPressed: () => setState(() => _taps++),
                child: const Text('tap'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => setState(() => _taps = 0),
                child: const Text('reset'),
              ),
              const SizedBox(width: 10),
              Text('$_taps', style: const TextStyle(fontFamily: 'monospace')),
            ],
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('switch'),
            value: _checked,
            onChanged: (v) => setState(() => _checked = v),
          ),
          Slider(
            value: _slider,
            onChanged: (v) => setState(() => _slider = v),
          ),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('one')),
              ButtonSegment(value: 1, label: Text('two')),
            ],
            selected: {_choice},
            onSelectionChanged: (s) => setState(() => _choice = s.first),
          ),
          const SizedBox(height: 8),
          const LinearProgressIndicator(value: 0.6),
          const SizedBox(height: 10),
          Row(
            children: const [
              Icon(Icons.videogame_asset, size: 20),
              SizedBox(width: 8),
              Icon(Icons.wifi, size: 20),
              SizedBox(width: 8),
              Icon(Icons.folder, size: 20),
              SizedBox(width: 8),
              CircularProgressIndicator(strokeWidth: 2),
            ],
          ),
        ],
      );
}
