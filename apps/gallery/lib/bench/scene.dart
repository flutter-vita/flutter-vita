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
  listChurn,

  /// A runtime fragment shader -- ShaderMask, ink_sparkle, the overscroll
  /// stretch. Untested territory until 2026-09-01, because until then a whole
  /// class of Skia program would not compile at all
  /// (patches/vitagl/0004).
  shader,

  /// Relayout every frame. Distinct from `fill` because the cost is in the
  /// layout walk rather than in painting, and distinct from `transform`
  /// because a transform reuses the layout it already has.
  layout;

  String get label => switch (this) {
        Stresses.fill => 'fill',
        Stresses.saveLayer => 'saveLayer',
        Stresses.clip => 'clip',
        Stresses.transform => 'transform',
        Stresses.opacity => 'opacity',
        Stresses.imageScale => 'imageScale',
        Stresses.text => 'text',
        Stresses.listChurn => 'listChurn',
        Stresses.shader => 'shader',
        Stresses.layout => 'layout',
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
    this.route,
    this.settle = const Duration(milliseconds: 450),
    this.repeats = 8,
  });

  final String name;
  final Stresses stresses;
  final WidgetBuilder page;

  /// How the page is pushed. Null means [MaterialPageRoute], which is what
  /// every scene used before 2026-09-01.
  ///
  /// It exists because the transition is a variable worth isolating. This port
  /// reports `TargetPlatform.linux` (ADR-0008), and Material's default for
  /// Linux is [ZoomPageTransitionsBuilder] -- the most expensive stock
  /// transition there is, built out of offscreen layers that a tile-based
  /// deferred GPU pays a full framebuffer round trip for (ADR-0014). Every
  /// route number this suite ever produced was a Zoom number, with no way to
  /// tell what belonged to the transition and what belonged to the page.
  ///
  /// The scenes that use it push the *same page* through different builders,
  /// so the difference between them is the transition and nothing else.
  final Route<void> Function(BuildContext context, WidgetBuilder page)? route;

  /// How long to hold after the push, and again after the pop.
  ///
  /// Longer than the transition on purpose. A dropped frame makes a 300 ms
  /// animation take longer in frames, not in wall clock, so a fixed settle
  /// past the end is sound -- but a modal sheet animates for longer than a
  /// page does, and cutting it off measures half a transition.
  final Duration settle;

  /// More than an animated scene gets, and for a measurable reason: a route
  /// transition is 300 ms of which only the animating part produces frames,
  /// and on this console that is a handful. Three repeats of `route_hero`
  /// produced three frames in total on 2026-08-24 -- not a distribution, and
  /// the report now refuses to grade it.
  final int repeats;
}

/// A scene the runner cannot drive with a controller or a push.
///
/// Drawer, tab swipe, ballistic fling, ink splash: each is started by calling
/// something and then waiting, and none of them exposes an [Animation] the
/// bench can hold. They are the ones a person actually complains about, so
/// leaving them out because they do not fit the other two shapes was the wrong
/// trade.
///
/// [stage] is mounted once and left up for the whole scene, so the widget
/// tree's first build is not charged to the measurement -- same reason
/// [AnimatedScene] settles for two frames first.
class DrivenScene {
  const DrivenScene({
    required this.name,
    required this.stresses,
    required this.stage,
    required this.drive,
    this.repeats = 4,
  });

  final String name;
  final Stresses stresses;

  /// Built once. Hold whatever keys or controllers [drive] needs at the top
  /// level of scenes.dart, the way `list_churn` already holds its
  /// ScrollController.
  final Widget Function() stage;

  /// One repetition. Awaited; the recorder is running throughout.
  final Future<void> Function() drive;

  final int repeats;
}
