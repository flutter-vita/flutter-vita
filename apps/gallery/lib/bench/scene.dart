// What a scene is. ADR-0017.
//
// One animation, driven by the app, run to completion and repeated. Never a
// wall-clock window: a 300 ms page push sampled over two seconds is
// three-quarters idle, and the idle drags every average toward 60 fps.

import 'package:flutter/widgets.dart';

/// The renderer primitive a scene leans on.
///
/// A label, not a measurement, and the report says so. It exists so a red row
/// points at something actionable -- ADR-0014 measured these operations
/// individually, and a scene tagged `saveLayer` lands next to the finding that
/// saveLayer is *slower* on this GPU than on the CPU, because every
/// render-target switch on a tile-based deferred renderer is a full
/// framebuffer round trip.
enum Stresses {
  /// Plain fills and blits. The baseline every other tag is read against.
  fill,

  /// An offscreen render target. 0.6x on the GPU, per ADR-0014.
  saveLayer,

  /// Rect and rounded-rect clipping.
  clip,

  /// Rotation, scale, translation of already-rasterised content.
  transform,

  /// Whole-subtree alpha, which usually implies an offscreen.
  opacity,

  /// Image scaling and filtering.
  imageScale,

  /// Text layout and glyph raster, which is CPU work on both paths.
  text,

  /// Long lists: build and layout cost dominated by widget churn.
  listChurn;

  String get label => switch (this) {
        Stresses.fill => 'fill',
        Stresses.saveLayer => 'saveLayer',
        Stresses.clip => 'clip',
        Stresses.transform => 'transform',
        Stresses.opacity => 'opacity',
        Stresses.imageScale => 'imageScale',
        Stresses.text => 'text',
        Stresses.listChurn => 'listChurn',
      };
}

/// A scene the runner can drive from 0 to 1 and back.
///
/// Deliberately not a route push. Route transitions are measured too, by
/// [RouteScene] below, but most of what makes a screen feel slow is an
/// animation rebuilding a subtree -- and driving a controller directly is
/// repeatable to the frame in a way that Navigator timing is not.
class AnimatedScene {
  const AnimatedScene({
    required this.name,
    required this.stresses,
    required this.builder,
    this.duration = const Duration(milliseconds: 500),
    this.repeats = 3,
  });

  final String name;
  final Stresses stresses;

  /// `t` runs 0 -> 1 over [duration]. Rebuild whatever the scene is about.
  final Widget Function(BuildContext context, double t) builder;

  final Duration duration;
  final int repeats;
}

/// A real Navigator transition, measured push and pop together.
///
/// Separate from [AnimatedScene] because the cost being measured includes
/// building the incoming route for the first time, which is exactly the part
/// a controller-driven scene skips and exactly the part that stutters.
class RouteScene {
  const RouteScene({
    required this.name,
    required this.stresses,
    required this.page,
    this.repeats = 8,
  });

  final String name;
  final Stresses stresses;
  final WidgetBuilder page;

  /// More than an animated scene gets, and for a measurable reason: a route
  /// transition is 300 ms of which only the animating part produces frames,
  /// and on this console that is a handful. Three repeats of `route_hero`
  /// produced three frames in total on 2026-08-24 -- not a distribution, and
  /// the report now refuses to grade it.
  final int repeats;
}
