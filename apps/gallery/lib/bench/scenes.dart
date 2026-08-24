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
Widget _content({double seed = 0}) {
  return GridView.count(
    physics: const NeverScrollableScrollPhysics(),
    crossAxisCount: 8,
    children: List<Widget>.generate(48, (i) {
      final h = ((i * 37 + seed * 90) % 360) / 360.0;
      return Container(
        margin: const EdgeInsets.all(2),
        color: HSVColor.fromAHSV(1, h * 360, 0.55, 0.75).toColor(),
        child: Center(
          child: Text('$i', style: const TextStyle(fontSize: 12)),
        ),
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

final List<RouteScene> routeScenes = <RouteScene>[
  // A real Navigator push, which includes building the incoming route for the
  // first time -- the part a controller-driven scene skips, and the part that
  // stutters.
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
