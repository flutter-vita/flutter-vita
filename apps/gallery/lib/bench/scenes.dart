// The scene list. ADR-0017 decision 5.
//
// Stock Flutter transitions and animations, each tagged with the renderer
// primitive it leans on. The accepted cost, stated in the ADR: this measures
// the scenes chosen here, so a transition that is slow in a way none of these
// reproduces stays invisible. A green suite over a console that still feels
// slow means a scene is missing, not that the console is fine.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'scene.dart';

/// A busy but cheap subtree, used as the content most scenes animate.
///
/// Deliberately not a solid rectangle: a single colour composites at a cost
/// unrelated to anything real, and every scene would then measure the same
/// fill. Fifty-odd tiles with text is closer to what a screen actually is.
/// Coloured cells, optionally with a numeral in each.
///
/// [text] exists so `route_boxes` and `route_push` differ by exactly one
/// thing: whether 48 glyph runs have to be laid out. [cells] exists so
/// `route_boxes12` and `route_boxes` differ by exactly one thing: how many
/// there are. A cost that is four times larger for four times the cells is a
/// per-widget cost and nothing to chase; one that barely moves is overhead.
Widget _content({double seed = 0, bool text = true, int cells = 48}) {
  return GridView.count(
    physics: const NeverScrollableScrollPhysics(),
    crossAxisCount: 8,
    children: List<Widget>.generate(cells, (i) {
      final h = ((i * 37 + seed * 90) % 360) / 360.0;
      return Container(
        margin: const EdgeInsets.all(2),
        color: HSVColor.fromAHSV(1, h * 360, 0.55, 0.75).toColor(),
        child: text
            ? Center(
                child: Text('$i', style: const TextStyle(fontSize: 12)),
              )
            : null,
      );
    }),
  );
}

/// A procedurally generated image, so the image-scaling scene measures real
/// filtering rather than a decode. Built once, on first use.
ui.Image? _image;

/// Held across rebuilds on purpose -- see the note in `list_churn`.
final ScrollController _listScroll = ScrollController();
const double _listScrollExtent = 400 * 56 - 500;

Future<void> prepareAssets() async {
  if (_image != null) return;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = 512.0;
  for (var y = 0; y < 16; y++) {
    for (var x = 0; x < 16; x++) {
      final paint = Paint()
        ..color = HSVColor.fromAHSV(1, ((x * 16 + y) * 1.4) % 360, 0.7, 0.9)
            .toColor();
      canvas.drawRect(
        Rect.fromLTWH(x * size / 16, y * size / 16, size / 16, size / 16),
        paint,
      );
    }
  }
  _image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
}

final List<AnimatedScene> animatedScenes = <AnimatedScene>[
  // The baseline. Everything else is read against this: if a solid fill
  // stalls, the problem is not the scene.
  AnimatedScene(
    name: 'fill_lerp',
    stresses: Stresses.fill,
    builder: (context, t) => ColoredBox(
      color: Color.lerp(Colors.indigo, Colors.orange, t)!,
      child: const SizedBox.expand(),
    ),
  ),
  AnimatedScene(
    name: 'opacity_fade',
    stresses: Stresses.opacity,
    builder: (context, t) => Opacity(opacity: t, child: _content()),
  ),
  // Opacity plus a colour filter forces a real offscreen. ADR-0014 measured
  // saveLayer at 0.6x on this GPU -- slower than the CPU -- because every
  // render-target switch on a tile-based deferred renderer is a full
  // framebuffer round trip. If any scene inverts the GPU's advantage, this one.
  AnimatedScene(
    name: 'save_layer_tint',
    stresses: Stresses.saveLayer,
    builder: (context, t) => Opacity(
      opacity: 0.4 + 0.6 * t,
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(
          Colors.cyan.withValues(alpha: t * 0.5),
          BlendMode.srcATop,
        ),
        child: _content(),
      ),
    ),
  ),
  AnimatedScene(
    name: 'clip_rrect',
    stresses: Stresses.clip,
    builder: (context, t) => Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8 + 180 * t),
        child: SizedBox(width: 520, height: 460, child: _content()),
      ),
    ),
  ),
  AnimatedScene(
    name: 'transform_rotate',
    stresses: Stresses.transform,
    builder: (context, t) => Center(
      child: Transform.rotate(
        angle: t * 3.14159,
        child: SizedBox(width: 460, height: 460, child: _content()),
      ),
    ),
  ),
  AnimatedScene(
    name: 'transform_scale',
    stresses: Stresses.transform,
    builder: (context, t) => Center(
      child: Transform.scale(
        scale: 0.35 + t * 1.1,
        child: SizedBox(width: 460, height: 460, child: _content()),
      ),
    ),
  ),
  AnimatedScene(
    name: 'image_scale',
    stresses: Stresses.imageScale,
    builder: (context, t) {
      final img = _image;
      if (img == null) return const SizedBox.expand();
      return Center(
        child: SizedBox(
          width: 120 + 800 * t,
          height: 120 + 400 * t,
          child: RawImage(
            image: img,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.low,
          ),
        ),
      );
    },
  ),
  // Blur is the other reliable way to force an offscreen, and it is the effect
  // most likely to appear in a real app's sheet or dialog.
  AnimatedScene(
    name: 'blur_backdrop',
    stresses: Stresses.saveLayer,
    builder: (context, t) => Stack(
      children: [
        _content(),
        Positioned.fill(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: t * 8, sigmaY: t * 8),
            child: const ColoredBox(color: Color(0x11000000)),
          ),
        ),
      ],
    ),
  ),
  // Text layout and glyph raster are CPU work on both paths, so this is the
  // scene where the GPU should help least. It is here to prove that.
  AnimatedScene(
    name: 'text_slide',
    stresses: Stresses.text,
    builder: (context, t) => ClipRect(
      child: Transform.translate(
        offset: Offset(0, -t * 400),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List<Widget>.generate(
            40,
            (i) => Text(
              'line $i — the quick brown fox jumps over the lazy dog',
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ),
      ),
    ),
  ),
  // Not a paint scene: the cost here is widget build and layout as rows come
  // and go. On a UI-bound port this is the shape that should hurt most.
  AnimatedScene(
    name: 'list_churn',
    stresses: Stresses.listChurn,
    duration: const Duration(milliseconds: 600),
    builder: (context, t) {
      // The controller is built once and driven after the frame. Constructing
      // a ScrollController inside build attaches a second position to the same
      // controller on the next rebuild, which throws before anything is
      // measured; and jumping during build is illegal outright.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_listScroll.hasClients) {
          _listScroll.jumpTo(t * _listScrollExtent);
        }
      });
      return ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        controller: _listScroll,
        itemCount: 400,
        itemExtent: 56,
        itemBuilder: (context, i) => ListTile(
          leading: CircleAvatar(child: Text('$i')),
          title: Text('item $i'),
          subtitle: const Text('subtitle that forces a second text layout'),
        ),
      );
    },
  ),
];

/// The same cells as [_content], without a Scrollable anywhere.
///
/// A Wrap inside a Column lays out 48 fixed-size boxes with no Viewport, no
/// SliverGrid and no ScrollPosition, which is the difference this exists to
/// price.
Widget _wrapped({bool text = true, bool sameText = false, int cells = 48}) {
  return Column(
    children: <Widget>[
      Wrap(
        children: List<Widget>.generate(cells, (i) {
          final h = ((i * 37 + 180) % 360) / 360.0;
          return Container(
            width: 116,
            height: 62,
            margin: const EdgeInsets.all(2),
            color: HSVColor.fromAHSV(1, h * 360, 0.55, 0.75).toColor(),
            child: text
                ? Center(
                    child: Text(sameText ? '8' : '$i',
                        style: const TextStyle(fontSize: 12)),
                  )
                : null,
          );
        }),
      ),
    ],
  );
}

final List<RouteScene> routeScenes = <RouteScene>[
  // Three pushes of increasing weight, which is the point of having three.
  //
  // The 2026-08-24 GPU run showed both route scenes spending 47-179 ms in
  // *build* with raster at 7 ms -- one such frame per transition, the frame
  // that first builds the incoming route. Raster is not the problem and the
  // GPU cannot fix it. These three separate the transition machinery from what
  // is being transitioned to: an empty page, the same page with 48 boxes, and
  // the same 48 boxes with a glyph in each.
  RouteScene(
    name: 'route_bare',
    stresses: Stresses.fill,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('bare')),
      body: const ColoredBox(color: Color(0xFF204060)),
    ),
  ),
  // No Scrollable. Same 48 coloured boxes as route_boxes, laid out by a Wrap
  // inside a plain Column, so the only difference from route_boxes is the
  // GridView -- which is a Scrollable, a Viewport and a SliverGrid, and which
  // costs the same whether it holds 12 cells or 48.
  RouteScene(
    name: 'route_wrap',
    stresses: Stresses.fill,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('wrap')),
      body: _wrapped(text: false),
    ),
  ),
  // Same 48 glyph runs as route_push, but every one of them is the same
  // string. If a repeated glyph run is materially cheaper than a unique one,
  // the cost is shaping and cache misses rather than painting.
  RouteScene(
    name: 'route_text_same',
    stresses: Stresses.text,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('same')),
      body: _wrapped(text: true, sameText: true),
    ),
  ),
  // The same 48 glyphs as route_text_uniq, in ONE Text instead of 48. If this
  // is cheap, the cost is per-paragraph -- font resolution, TextPainter setup,
  // a ui.Paragraph built and laid out -- and not per-glyph.
  RouteScene(
    name: 'route_text_one',
    stresses: Stresses.text,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('one')),
      body: Center(
        child: Text('0123456789012345678901234567890123456789012345678',
            style: const TextStyle(fontSize: 12)),
      ),
    ),
  ),
  // The same 48 numbers as route_text_uniq, as 48 TextSpans inside ONE
  // RichText instead of 48 Text widgets. One paragraph, 48 styled runs.
  //
  // If the cost is per-paragraph this collapses to route_text_one's 1 ms and
  // "merge Texts into spans" is a real answer for an app. If it is per-run it
  // stays near 46 ms and merging buys nothing.
  RouteScene(
    name: 'route_spans',
    stresses: Stresses.text,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('spans')),
      body: Center(
        child: RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 12, color: Color(0xFF000000)),
            children: List<TextSpan>.generate(
              48,
              (i) => TextSpan(text: '$i '),
            ),
          ),
        ),
      ),
    ),
  ),
  RouteScene(
    name: 'route_text_uniq',
    stresses: Stresses.text,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('uniq')),
      body: _wrapped(text: true),
    ),
  ),
  // The same GridView as route_boxes with its three per-child wrappers turned
  // off. SliverChildListDelegate gives every child a RepaintBoundary, an
  // IndexedSemantics and an AutomaticKeepAlive by default; a Wrap gives it
  // none of those and costs 20 us a box where the grid costs 670.
  RouteScene(
    name: 'route_grid_bare',
    stresses: Stresses.fill,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('grid bare')),
      body: GridView.count(
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 8,
        addRepaintBoundaries: false,
        addAutomaticKeepAlives: false,
        addSemanticIndexes: false,
        children: List<Widget>.generate(48, (i) {
          final h = ((i * 37 + 270) % 360) / 360.0;
          return Container(
            margin: const EdgeInsets.all(2),
            color: HSVColor.fromAHSV(1, h * 360, 0.55, 0.75).toColor(),
          );
        }),
      ),
    ),
  ),
  RouteScene(
    name: 'route_boxes12',
    stresses: Stresses.fill,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('boxes12')),
      body: _content(seed: 4, text: false, cells: 12),
    ),
  ),
  RouteScene(
    name: 'route_boxes',
    stresses: Stresses.fill,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('boxes')),
      body: _content(seed: 3, text: false),
    ),
  ),
  RouteScene(
    name: 'route_push',
    stresses: Stresses.fill,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('pushed')),
      body: _content(seed: 1),
    ),
  ),
  RouteScene(
    name: 'route_hero',
    stresses: Stresses.transform,
    page: (context) => Scaffold(
      appBar: AppBar(title: const Text('hero')),
      body: Center(
        child: Hero(
          tag: 'bench-hero',
          child: SizedBox(width: 420, height: 420, child: _content(seed: 2)),
        ),
      ),
    ),
  ),
];
