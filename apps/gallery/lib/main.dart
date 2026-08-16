import 'package:flutter/material.dart';

/// What this port looks like, judged by eye.
///
/// A separate app from the conformance suite, and the split is about how each
/// one produces a verdict. Conformance computes a boolean about itself and
/// reports 45/45 with no human involved; that is what makes it runnable on
/// every deploy. A widget either looks right or it does not, and no app can
/// assess that about itself — the verdict is a screenshot or a pair of eyes.
///
/// Folding the two together would cost the conformance run its automation,
/// which is the whole reason it survived the crash investigation.
void main() => runApp(const GalleryApp());

class GalleryApp extends StatelessWidget {
  const GalleryApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF4C8DFF),
          scaffoldBackgroundColor: const Color(0xFF10131A),
        ),
        home: const Gallery(),
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
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text('flutter-vita gallery',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
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
