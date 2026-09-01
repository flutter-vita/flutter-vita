// The scene list. ADR-0017 decision 5.
//
// Stock Flutter transitions and animations, each tagged with the renderer
// primitive it leans on. The accepted cost, stated in the ADR: this measures
// the scenes chosen here, so a transition that is slow in a way none of these
// reproduces stays invisible. A green suite over a console that still feels
// slow means a scene is missing, not that the console is fine.

import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/gestures.dart';
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
/// thing: whether 48 glyph runs have to be laid out.
Widget _content({double seed = 0, bool text = true}) {
  return GridView.count(
    physics: const NeverScrollableScrollPhysics(),
    crossAxisCount: 8,
    children: List<Widget>.generate(48, (i) {
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
Widget _wrapped({bool text = true}) {
  return Column(
    children: <Widget>[
      Wrap(
        children: List<Widget>.generate(48, (i) {
          final h = ((i * 37 + 180) % 360) / 360.0;
          return Container(
            width: 116,
            height: 62,
            margin: const EdgeInsets.all(2),
            color: HSVColor.fromAHSV(1, h * 360, 0.55, 0.75).toColor(),
            child: text
                ? Center(
                    child: Text('$i',
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
  // The same 48 numbers as route_text_uniq, as 48 TextSpans inside ONE
  // RichText instead of 48 Text widgets. One paragraph, 48 styled runs.
  //
  // The pair that carries the whole finding, and the reason both stay in the
  // suite: 1.2 ms here against route_text_uniq's 45.5 for the same 48 numbers
  // on screen. If that gap ever closes, the advice in
  // docs/writing-flutter-that-runs-on-a-vita.md is wrong.
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

// ---------------------------------------------------------------- transitions
//
// Everything above this line was written before it was clear which stock
// transition this port even uses. It uses ZoomPageTransitionsBuilder, because
// the port reports TargetPlatform.linux (ADR-0008) and that is Material's
// Linux default -- so all eight route scenes above are Zoom measurements that
// nobody chose.
//
// The scenes below push *one* page through five different transitions. Same
// widgets, same first build, same settle: the only thing that varies is the
// animation wrapped around it. `route_tx_none` is the control -- no transition
// at all -- so the build cost can be subtracted from the other four rather
// than guessed at.

/// A route whose transition is whatever it was handed.
///
/// [PageTransitionsBuilder.buildTransitions] takes a non-nullable [PageRoute],
/// so a PageRouteBuilder cannot delegate to one; it needs a real route to hand
/// over. This is the smallest thing that is one.
class _TxRoute<T> extends PageRoute<T> {
  _TxRoute({required this.page, required this.transitions});

  final WidgetBuilder page;
  final PageTransitionsBuilder transitions;

  @override
  Duration get transitionDuration => transitions.transitionDuration;
  @override
  Duration get reverseTransitionDuration => transitions.reverseTransitionDuration;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation) =>
      page(context);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      transitions.buildTransitions<T>(
          this, context, animation, secondaryAnimation, child);
}

/// The control: pushed and popped with no animation whatsoever.
class _NoTxRoute<T> extends PageRoute<T> {
  _NoTxRoute({required this.page});

  final WidgetBuilder page;

  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Duration get reverseTransitionDuration => Duration.zero;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation) =>
      page(context);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      child;
}

/// The one page all five transition scenes push.
///
/// Deliberately the same shape as `route_boxes`, which is already baselined, so
/// the transition comparison can be read against a scene that has history.
Widget _txPage(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('tx')),
      body: _content(seed: 4, text: false),
    );

final List<RouteScene> transitionScenes = <RouteScene>[
  RouteScene(
    name: 'route_tx_none',
    stresses: Stresses.fill,
    page: _txPage,
    route: (context, page) => _NoTxRoute<void>(page: page),
    settle: const Duration(milliseconds: 250),
  ),
  // The port's current default, named so it is obvious that it is one option
  // among several rather than the way things are.
  RouteScene(
    name: 'route_tx_zoom',
    stresses: Stresses.saveLayer,
    page: _txPage,
    route: (context, page) => _TxRoute<void>(
      page: page,
      transitions: const ZoomPageTransitionsBuilder(),
    ),
  ),
  // The same Zoom with its snapshotting turned off.
  //
  // Zoom rasterises the entering and exiting routes into offscreen images and
  // animates those instead of the live widgets, which is meant to be the fast
  // path. On this port it is where the memory goes: with snapshotting on, nine
  // push-and-pop cycles took the heap from 6 MB to 46 MB and a full suite run
  // reached the 159 MB ceiling and wedged. Every other transition measured
  // holds flat.
  RouteScene(
    name: 'route_tx_zoom_nosnap',
    stresses: Stresses.saveLayer,
    page: _txPage,
    route: (context, page) => _TxRoute<void>(
      page: page,
      transitions: const ZoomPageTransitionsBuilder(allowSnapshotting: false),
    ),
  ),
  RouteScene(
    name: 'route_tx_fade_fwd',
    stresses: Stresses.opacity,
    page: _txPage,
    route: (context, page) => _TxRoute<void>(
      page: page,
      transitions: const FadeForwardsPageTransitionsBuilder(),
    ),
  ),
  RouteScene(
    name: 'route_tx_fade_up',
    stresses: Stresses.opacity,
    page: _txPage,
    route: (context, page) => _TxRoute<void>(
      page: page,
      transitions: const FadeUpwardsPageTransitionsBuilder(),
    ),
  ),
  // A pure slide with a parallax on the outgoing route: no offscreen, no
  // alpha. If the GPU is going to win a transition anywhere, here.
  RouteScene(
    name: 'route_tx_cupertino',
    stresses: Stresses.transform,
    page: _txPage,
    route: (context, page) => _TxRoute<void>(
      page: page,
      transitions: const CupertinoPageTransitionsBuilder(),
    ),
  ),
];

// --------------------------------------------------------------------- modals
//
// A dialog and a bottom sheet are route pushes too, so they reuse the same
// driver -- but both draw a scrim over the whole screen for the length of the
// animation, which is a full-viewport alpha composite that no page transition
// does.

final List<RouteScene> modalScenes = <RouteScene>[
  RouteScene(
    name: 'modal_dialog',
    stresses: Stresses.opacity,
    page: (context) => AlertDialog(
      title: const Text('dialog'),
      content: const Text('a scrim over the whole screen, and a scaled fade'),
      actions: [TextButton(onPressed: () {}, child: const Text('ok'))],
    ),
    route: (context, page) => DialogRoute<void>(context: context, builder: page),
  ),
  RouteScene(
    name: 'modal_sheet',
    stresses: Stresses.opacity,
    page: (context) => SizedBox(
      height: 260,
      child: _content(seed: 5, text: false),
    ),
    route: (context, page) => ModalBottomSheetRoute<void>(
      builder: page,
      isScrollControlled: false,
    ),
    // Longer than a page push: the sheet's own animation is 250 ms in and
    // 200 ms out, and the scrim keeps compositing until it is gone.
    settle: const Duration(milliseconds: 600),
  ),
];

// --------------------------------------------------------------------- motion
//
// Animations that are not transitions. Each one is a thing a real screen does
// every day and none of them was measured before 2026-09-01.

/// Two children an AnimatedSwitcher crossfades between.
Widget _switcherChild(int i) => KeyedSubtree(
      key: ValueKey<int>(i),
      child: _content(seed: i * 7.0, text: false),
    );

final List<AnimatedScene> motionScenes = <AnimatedScene>[
  // A crossfade between two subtrees. Both are alive and both are painted for
  // the whole transition, each inside its own FadeTransition -- so this is two
  // full-screen alpha composites at once, which is more than any single
  // route transition asks for.
  AnimatedScene(
    name: 'switch_fade',
    stresses: Stresses.saveLayer,
    duration: const Duration(milliseconds: 600),
    repeats: 3,
    builder: (context, t) => AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: _switcherChild(t < 0.5 ? 0 : 1),
    ),
  ),
  // Relayout every frame, and nothing else: no alpha, no offscreen, no
  // transform. The control for every complaint that "the animation is smooth
  // until the box changes size".
  AnimatedScene(
    name: 'layout_resize',
    stresses: Stresses.layout,
    builder: (context, t) => Center(
      child: SizedBox(
        width: 120 + 700 * t,
        height: 100 + 380 * t,
        child: _content(seed: 6, text: false),
      ),
    ),
  ),
  // Text whose size changes every frame, which throws away the paragraph and
  // lays it out again. Common in collapsing headers and hero titles, and the
  // most expensive thing a phone-shaped app does that looks free.
  AnimatedScene(
    name: 'text_resize',
    stresses: Stresses.text,
    builder: (context, t) => Center(
      child: Text(
        'resizing headline',
        style: TextStyle(fontSize: 14 + 34 * t),
      ),
    ),
  ),
  // A runtime fragment shader over the whole viewport. Worth having for the
  // first time now that Skia's programs actually compile
  // (patches/vitagl/0004); before that this scene would have measured the
  // fallback, silently.
  AnimatedScene(
    name: 'shader_mask',
    stresses: Stresses.shader,
    builder: (context, t) => ShaderMask(
      blendMode: BlendMode.modulate,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment(-1 + 2 * t, -1),
        end: Alignment(1 + 2 * t, 1),
        colors: const [Color(0xFFFFFFFF), Color(0x22FFFFFF), Color(0xFFFFFFFF)],
      ).createShader(rect),
      child: _content(seed: 7, text: false),
    ),
  ),
  // The cheapest thing that animates forever. Here as a floor: if a spinner
  // alone cannot hold 60 fps, nothing measured above it means anything.
  AnimatedScene(
    name: 'spinner',
    stresses: Stresses.fill,
    duration: const Duration(milliseconds: 900),
    builder: (context, t) => const Center(
      child: SizedBox(
        width: 48,
        height: 48,
        child: CircularProgressIndicator(),
      ),
    ),
  ),
];

// --------------------------------------------------------------------- driven
//
// Started by calling something rather than by advancing a controller.

final GlobalKey<ScaffoldState> _drawerKey = GlobalKey<ScaffoldState>();
final PageController _pageCtl = PageController();
final ScrollController _flingScroll = ScrollController();

Future<void> _settle(int ms) =>
    Future<void>.delayed(Duration(milliseconds: ms));

final List<DrivenScene> drivenScenes = <DrivenScene>[
  // A drawer is a slide plus a scrim over everything behind it, and the scrim
  // animates its alpha the whole way. Closest thing in the suite to what a
  // navigation drawer costs on a screen that is already busy.
  DrivenScene(
    name: 'drawer_open',
    stresses: Stresses.opacity,
    stage: () => Scaffold(
      key: _drawerKey,
      drawer: Drawer(
        child: ListView(
          children: List<Widget>.generate(
            12,
            (i) => ListTile(title: Text('item $i')),
          ),
        ),
      ),
      body: _content(seed: 8, text: false),
    ),
    drive: () async {
      _drawerKey.currentState?.openDrawer();
      await _settle(500);
      _drawerKey.currentState?.closeDrawer();
      await _settle(500);
    },
  ),
  // What TabBarView does, without the tab bar: two full-screen pages, one
  // sliding out while the other slides in, both built and both painted.
  DrivenScene(
    name: 'page_swipe',
    stresses: Stresses.fill,
    stage: () => PageView(
      controller: _pageCtl,
      children: [
        _content(seed: 9, text: false),
        _content(seed: 10, text: true),
      ],
    ),
    drive: () async {
      await _pageCtl.animateToPage(1,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      await _settle(150);
      await _pageCtl.animateToPage(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      await _settle(150);
    },
  ),
  // A real fling, not an animateTo. goBallistic runs the platform scroll
  // simulation, so the frame rate is whatever the physics asks for rather than
  // whatever curve the bench picked -- and it overscrolls at the end, which is
  // the only thing in the suite that reaches the stretch effect.
  //
  // This is the gesture behind the standing complaint: scrolling a list on
  // this console runs at 29 fps with the raster thread at 8%, so the cost is
  // the UI thread rebuilding rows.
  DrivenScene(
    name: 'scroll_fling',
    stresses: Stresses.listChurn,
    stage: () => ListView.builder(
      controller: _flingScroll,
      itemCount: 400,
      itemBuilder: (context, i) => ListTile(
        dense: true,
        leading: CircleAvatar(child: Text('$i')),
        title: Text('row $i'),
        subtitle: Text('subtitle for row $i'),
      ),
    ),
    drive: () async {
      final p = _flingScroll.position;
      if (p is ScrollPositionWithSingleContext) {
        p.goBallistic(-6000);
        await _settle(900);
        p.goBallistic(6000);
        await _settle(900);
      } else {
        await _settle(100);
      }
    },
  ),
  // An ink splash, driven by synthetic pointer events rather than by calling
  // onTap -- onTap does not produce a splash, and the splash is the thing
  // being measured. It also means the hit test and the gesture arena are in
  // the window, which is where a tap that feels late actually goes.
  DrivenScene(
    name: 'ripple_tap',
    stresses: Stresses.shader,
    stage: () => Material(
      color: const Color(0xFF203040),
      child: InkWell(
        onTap: () {},
        child: const SizedBox.expand(),
      ),
    ),
    drive: () async {
      const id = 7;
      const at = Offset(300, 200);
      GestureBinding.instance
          .handlePointerEvent(const PointerDownEvent(pointer: id, position: at));
      await _settle(60);
      GestureBinding.instance
          .handlePointerEvent(const PointerUpEvent(pointer: id, position: at));
      // The splash keeps expanding after the pointer is gone; cutting the
      // window at the up event measures the first 60 ms of it and nothing
      // else.
      await _settle(700);
    },
  ),
];
