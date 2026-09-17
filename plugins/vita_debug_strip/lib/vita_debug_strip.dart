/// The strip of live console numbers above the gallery's tabs, as a widget
/// any app can carry, and a button chord that shows and hides it.
///
/// Three pieces:
///
///   [VitaStrip]         the two-row table: fps, UI and raster time, GPU
///                       busy, the cores, memory, heap, battery
///   [VitaDebugOverlay]  the strip over an app, toggled by L + R + TRIANGLE
///   [VitaPad]           the controller, read once or waited on for a chord
///
/// The numbers come from the embedder's `vita/stats` channel, which every
/// app has; the chord from `vita/pad`, this package's C half, compiled
/// into the app because the package is in its pubspec (ADR-0020).
///
/// Every debug build already has a HUD without this package: the engine's
/// box in the top-right corner, L + R + SELECT. What this strip adds is
/// what only Dart can see, the UI thread's build time per frame, and a
/// place in the app's own layout.
library;

export 'src/overlay.dart';
export 'src/pad.dart';
export 'src/stats.dart';
export 'src/strip.dart';
