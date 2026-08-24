// Where the 950 us in a Text widget goes, timed from Dart. ADR-0017.
//
// The engine side is already instrumented (patches/flutter-engine/0010) and
// accounts for only ~260 us of it: a ui.Paragraph's construction, build and
// layout. The other ~690 us is above dart:ui, in the framework, and no engine
// counter can see it.
//
// It does not need one. TextPainter is ordinary Dart calling ordinary dart:ui,
// so the same work can be performed here with a Stopwatch around each layer:
// building the two style objects, building the paragraph, laying it out, and
// -- separately -- the whole thing through TextPainter as a widget would. The
// difference between the last two is the framework's share, measured rather
// than inferred.

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// One timed pass over [n] single-glyph paragraphs, in microseconds per item.
class TextProbe {
  const TextProbe({
    required this.n,
    required this.styleUs,
    required this.buildUs,
    required this.layoutUs,
    required this.painterUs,
    required this.themedUs,
    required this.fieldUs,
  });

  final int n;

  /// Constructing ui.ParagraphStyle and ui.TextStyle. Pure Dart allocation
  /// plus the typed-list encoding dart:ui does on the way across.
  final double styleUs;

  /// ParagraphBuilder, pushStyle, addText, build.
  final double buildUs;

  /// Paragraph.layout.
  final double layoutUs;

  /// The same glyph through TextPainter, which is what a Text widget's
  /// RenderParagraph actually calls. Everything above plus the framework.
  ///
  /// With a bare `TextStyle(fontSize: 12)`.
  final double painterUs;

  /// TextPainter again, with the style a `Text` in a Material app actually
  /// gets: `const TextStyle(fontSize: 12)` merged onto the theme's
  /// DefaultTextStyle, so a family, a colour, a weight, a height and letter
  /// spacing are all set. This is the realistic number; [painterUs] is the
  /// floor.
  final double themedUs;

  /// The bare style plus one field, per field. Says which of the theme's
  /// fields is buying the difference between [painterUs] and [themedUs].
  final Map<String, double> fieldUs;

  /// What TextPainter adds over driving dart:ui directly.
  double get frameworkUs => painterUs - (styleUs + buildUs + layoutUs);

  @override
  String toString() => 'probe n=$n style=${styleUs.toStringAsFixed(0)}us '
      'build=${buildUs.toStringAsFixed(0)}us '
      'layout=${layoutUs.toStringAsFixed(0)}us '
      '= ${(styleUs + buildUs + layoutUs).toStringAsFixed(0)}us direct | '
      'TextPainter bare=${painterUs.toStringAsFixed(0)}us '
      'themed=${themedUs.toStringAsFixed(0)}us | '
      '${fieldUs.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(0)}').join(' ')}';

  Map<String, Object> toJson() => {
        'n': n,
        'style_us': _r(styleUs),
        'build_us': _r(buildUs),
        'layout_us': _r(layoutUs),
        'painter_us': _r(painterUs),
        'themed_us': _r(themedUs),
        'field_us': fieldUs.map((k, v) => MapEntry(k, _r(v))),
        'framework_us': _r(frameworkUs),
      };

  static double _r(double v) => (v * 10).roundToDouble() / 10;
}

const double _kWidth = 120;

/// Runs the probe. [warm] passes are discarded first, because the very first
/// paragraph of a process pays for font resolution that the rest do not.
TextProbe probeText({int n = 48, int warm = 8}) {
  final fields = <String, double>{};
  for (var i = 0; i < warm; i++) {
    _direct('w$i');
    _painter('w$i');
  }

  final style = Stopwatch();
  final build = Stopwatch();
  final layout = Stopwatch();
  for (var i = 0; i < n; i++) {
    _direct('$i', style: style, build: build, layout: layout);
  }

  final painter = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    _painter('$i');
  }
  painter.stop();

  for (var i = 0; i < warm; i++) {
    _painter('w$i', style: _themed);
  }
  final themed = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    _painter('$i', style: _themed);
  }
  themed.stop();

  // Which field costs. One at a time onto the bare style, same harness.
  for (final entry in _fields.entries) {
    for (var i = 0; i < warm; i++) {
      _painter('w$i', style: entry.value);
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      _painter('$i', style: entry.value);
    }
    sw.stop();
    fields[entry.key] = sw.elapsedMicroseconds / n;
  }

  double per(Stopwatch s) => s.elapsedMicroseconds / n;
  return TextProbe(
    n: n,
    styleUs: per(style),
    buildUs: per(build),
    layoutUs: per(layout),
    painterUs: per(painter),
    themedUs: per(themed),
    fieldUs: fields,
  );
}

void _direct(String text,
    {Stopwatch? style, Stopwatch? build, Stopwatch? layout}) {
  style?.start();
  final ps = ui.ParagraphStyle(fontSize: 12);
  final ts = ui.TextStyle(fontSize: 12, color: const Color(0xFF000000));
  style?.stop();

  build?.start();
  final b = ui.ParagraphBuilder(ps)
    ..pushStyle(ts)
    ..addText(text);
  final p = b.build();
  build?.stop();

  layout?.start();
  p.layout(const ui.ParagraphConstraints(width: _kWidth));
  layout?.stop();

  p.dispose();
}

// What DefaultTextStyle hands a Text inside a Material Scaffold: every field
// the theme sets, not just the one the call site names.
const TextStyle _themed = TextStyle(
  fontSize: 12,
  color: Color(0xDD000000),
  fontFamily: 'Roboto',
  fontWeight: FontWeight.w400,
  letterSpacing: 0.25,
  height: 1.43,
  decoration: TextDecoration.none,
  textBaseline: TextBaseline.alphabetic,
);

const Map<String, TextStyle> _fields = <String, TextStyle>{
  '+family': TextStyle(fontSize: 12, fontFamily: 'Roboto'),
  '+color': TextStyle(fontSize: 12, color: Color(0xDD000000)),
  '+weight': TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
  '+height': TextStyle(fontSize: 12, height: 1.43),
  '+spacing': TextStyle(fontSize: 12, letterSpacing: 0.25),
};

void _painter(String text, {TextStyle style = const TextStyle(fontSize: 12)}) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: _kWidth);
  tp.dispose();
}
