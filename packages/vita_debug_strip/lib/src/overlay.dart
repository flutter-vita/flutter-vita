import 'dart:async';

import 'package:flutter/widgets.dart';

import 'pad.dart';
import 'strip.dart';

/// The strip over any app, shown and hidden with a button chord.
///
/// Wrap the app once:
///
///     runApp(VitaDebugOverlay(child: MyApp()));
///
/// or, to keep it inside the app's theme and MediaQuery:
///
///     MaterialApp(builder: (context, child) => VitaDebugOverlay(child: child!))
///
/// L + R + TRIANGLE toggles it (the [hotkey]). Not L + R + SELECT: that is
/// the engine's own debug HUD, the box every debug build draws in the
/// top-right corner, which this package starts hidden (its C half defines
/// `flutter_vita_debug_overlay = 2`) so the two do not overlap. The chord is
/// watched by one thread on the console (`vita/pad`, the package's C half),
/// not by a Dart timer, so a hidden strip costs the app nothing.
///
/// [inset] lays the app out under the strip instead of drawing the strip
/// over its top 34 px; the app relayouts on each toggle.
class VitaDebugOverlay extends StatefulWidget {
  const VitaDebugOverlay({
    super.key,
    required this.child,
    this.hotkey = VitaButtons.l | VitaButtons.r | VitaButtons.triangle,
    this.visible = false,
    this.inset = false,
  });

  final Widget child;
  final int hotkey;

  /// Shown from the start; the chord still hides it.
  final bool visible;
  final bool inset;

  @override
  State<VitaDebugOverlay> createState() => _VitaDebugOverlayState();
}

class _VitaDebugOverlayState extends State<VitaDebugOverlay> {
  late bool _visible = widget.visible;
  StreamSubscription<void>? _chord;

  @override
  void initState() {
    super.initState();
    if (widget.hotkey != 0) {
      _chord = VitaPad.chord(widget.hotkey).listen((_) {
        if (mounted) setState(() => _visible = !_visible);
      });
    }
  }

  @override
  void dispose() {
    _chord?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return widget.child;
    if (widget.inset) {
      return Column(
        children: [
          const VitaStrip(),
          Expanded(child: widget.child),
        ],
      );
    }
    return Stack(
      children: [
        widget.child,
        const Positioned(left: 0, right: 0, top: 0, child: VitaStrip()),
      ],
    );
  }
}
