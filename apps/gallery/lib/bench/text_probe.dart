// Where the 950 us in a Text widget goes, timed from Dart.
//
// The engine side is instrumented and accounts for only ~260 us: a
// ui.Paragraph's construction, build and layout. The other ~690 us is above
// dart:ui, in the framework, where no engine counter can see it.
//
// TextPainter is ordinary Dart calling ordinary dart:ui, so the same work runs
// here with a Stopwatch around each layer. The difference between the last two
// is the framework's share, measured rather than inferred.

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
    required this.blockUs,
    required this.stepUs,
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

  /// Direct dart:ui variants that vary the paragraph style and the pushed
  /// style independently, to find out whether the ~350 us step is the cost of
  /// *having* a pushed style block or of what is *in* it.
  final Map<String, double> blockUs;

  /// TextPainter's own sequence, hand-rolled and timed a call at a time.
  ///
  /// `getParagraphStyle` and `getTextStyle` are public on TextStyle, so the
  /// framework's path can be reproduced here exactly and bisected without
  /// patching the framework. Keys are `<variant>.<call>`.
  final Map<String, double> stepUs;

  /// What TextPainter adds over driving dart:ui directly.
  double get frameworkUs => painterUs - (styleUs + buildUs + layoutUs);

  @override
  String toString() => 'probe n=$n style=${styleUs.toStringAsFixed(0)}us '
      'build=${buildUs.toStringAsFixed(0)}us '
      'layout=${layoutUs.toStringAsFixed(0)}us '
      '= ${(styleUs + buildUs + layoutUs).toStringAsFixed(0)}us direct | '
      'TextPainter bare=${painterUs.toStringAsFixed(0)}us '
      'themed=${themedUs.toStringAsFixed(0)}us | '
      '${fieldUs.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(0)}').join(' ')} | '
      '${blockUs.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(0)}').join(' ')} | '
      '${stepUs.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(0)}').join(' ')}';

  Map<String, Object> toJson() => {
        'n': n,
        'style_us': _r(styleUs),
        'build_us': _r(buildUs),
        'layout_us': _r(layoutUs),
        'painter_us': _r(painterUs),
        'themed_us': _r(themedUs),
        'field_us': fieldUs.map((k, v) => MapEntry(k, _r(v))),
        'block_us': blockUs.map((k, v) => MapEntry(k, _r(v))),
        'step_us': stepUs.map((k, v) => MapEntry(k, _r(v))),
        'framework_us': _r(frameworkUs),
      };

  static double _r(double v) => (v * 10).roundToDouble() / 10;
}

const double _kWidth = 120;

/// Runs the probe. [warm] passes are discarded first, because the very first
/// paragraph of a process pays for font resolution that the rest do not.
TextProbe probeText({int n = 48, int warm = 8}) {
  final fields = <String, double>{};
  final blocks = <String, double>{};
  final steps = <String, double>{};
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

  // Is the step the cost of having a pushed style block at all, or of what is
  // in it? These vary the two independently.
  //
  //   nopush     paragraph style only, no pushStyle
  //   pushempty  an empty ui.TextStyle pushed -- a second block, same content
  //   pushsame   a pushed style whose values match the paragraph style
  //   pushdiff   a pushed style that diverges by one field
  //
  // nopush ~= pushempty << pushdiff says the content is the cost.
  // nopush << pushempty ~= pushdiff says the block itself is.
  const variants = <String, List<Object?>>{
    'nopush': <Object?>[null],
    'pushempty': <Object?>['empty'],
    'pushsame': <Object?>['same'],
    'pushdiff': <Object?>['diff'],
  };
  for (final entry in variants.entries) {
    final kind = entry.value.first as String?;
    for (var i = 0; i < warm; i++) {
      _block(kind, 'w$i');
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      _block(kind, '$i');
    }
    sw.stop();
    blocks[entry.key] = sw.elapsedMicroseconds / n;
  }

  // TextPainter's sequence, priced by cumulative passes rather than by
  // stopwatches inside the loop.
  //
  // Four stopwatches around four calls reported 719 us for a sequence
  // TextPainter completes in 410: eight clock reads an iteration are not free
  // here, and `clock` below is what they cost. So each pass does strictly more
  // work than the last and the differences are the per-call costs.
  {
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      Stopwatch()
        ..start()
        ..stop();
    }
    sw.stop();
    steps['clock'] = sw.elapsedMicroseconds / n;
  }
  // TextPainter's own argument set, and its builder.pop(). _upto stubbed
  // getParagraphStyle down to textDirection alone; TextPainter passes eight
  // arguments and pops the style it pushed. If that is the difference, this
  // lands near the TextPainter number rather than near the hand-rolled one.
  for (final v in <String, TextStyle>{
    'fullbare': const TextStyle(fontSize: 12),
    'fulldiff': const TextStyle(fontSize: 12, height: 1.43),
  }.entries) {
    for (var i = 0; i < warm; i++) {
      _full(v.value, 'w$i');
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      _full(v.value, '$i');
    }
    sw.stop();
    steps[v.key] = sw.elapsedMicroseconds / n;
  }

  for (final v in <String, TextStyle>{
    'bare': const TextStyle(fontSize: 12),
    'diff': const TextStyle(fontSize: 12, height: 1.43),
  }.entries) {
    for (var depth = 1; depth <= 4; depth++) {
      for (var i = 0; i < warm; i++) {
        _upto(depth, v.value, 'w$i');
      }
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        _upto(depth, v.value, '$i');
      }
      sw.stop();
      steps['${v.key}.$depth'] = sw.elapsedMicroseconds / n;
    }
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
    blockUs: blocks,
    stepUs: steps,
  );
}

// Everything _upto does, plus the arguments TextPainter actually passes and
// the pop it actually makes.
void _full(TextStyle style, String text) {
  final paraStyle = style.getParagraphStyle(
    textAlign: TextAlign.start,
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    maxLines: null,
    textHeightBehavior: null,
    ellipsis: null,
    locale: null,
    strutStyle: null,
  );
  final b = ui.ParagraphBuilder(paraStyle)
    ..pushStyle(style.getTextStyle(textScaler: TextScaler.noScaling))
    ..addText(text)
    ..pop();
  final p = b.build()
    ..layout(const ui.ParagraphConstraints(width: _kWidth));
  p.dispose();
}

// TextPainter's sequence, truncated after [depth] calls:
//   1  getParagraphStyle
//   2  + getTextStyle
//   3  + ParagraphBuilder, pushStyle, addText, build
//   4  + layout
void _upto(int depth, TextStyle style, String text) {
  final paraStyle = style.getParagraphStyle(textDirection: TextDirection.ltr);
  if (depth == 1) return;

  final textStyle = style.getTextStyle(textScaler: TextScaler.noScaling);
  if (depth == 2) return;

  final p = (ui.ParagraphBuilder(paraStyle)
        ..pushStyle(textStyle)
        ..addText(text))
      .build();
  if (depth == 3) {
    p.dispose();
    return;
  }

  p.layout(const ui.ParagraphConstraints(width: _kWidth));
  p.dispose();
}

// The paragraph style every variant starts from: a family and a size, which
// is what TextPainter derives from the root TextStyle.
ui.ParagraphStyle _paraStyle() =>
    ui.ParagraphStyle(fontFamily: 'Roboto', fontSize: 12);

void _block(String? kind, String text) {
  final b = ui.ParagraphBuilder(_paraStyle());
  switch (kind) {
    case null:
      break;
    case 'empty':
      b.pushStyle(ui.TextStyle());
      break;
    case 'same':
      b.pushStyle(ui.TextStyle(fontFamily: 'Roboto', fontSize: 12));
      break;
    case 'diff':
      b.pushStyle(ui.TextStyle(fontFamily: 'Roboto', fontSize: 12, height: 1.43));
      break;
  }
  b.addText(text);
  final p = b.build()
    ..layout(const ui.ParagraphConstraints(width: _kWidth));
  p.dispose();
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
