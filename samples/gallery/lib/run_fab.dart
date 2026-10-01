import 'package:flutter/material.dart';

/// The one action of a tab that has one: run everything on it.
///
/// Bottom right, over the list, so the tab's header keeps its width for the
/// status. A list under it needs [RunFab.clearance] of bottom padding, or the
/// last row sits behind it.
///
/// No spinner while a run is going. A CircularProgressIndicator draws a frame
/// every vsync, and the Tests tab's timer probes and the hardware checks would
/// measure it. A still hourglass and a disabled button say the same thing.
class RunFab extends StatelessWidget {
  const RunFab({super.key, required this.running, required this.onRun});

  final bool running;
  final VoidCallback onRun;

  /// Bottom padding for a list the button floats over.
  static const double clearance = 72;

  /// Where the button goes in a Stack over the tab.
  static Widget over(Widget child,
          {required bool running, required VoidCallback onRun}) =>
      Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            right: 16,
            bottom: 16,
            child: RunFab(running: running, onRun: onRun),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) => FloatingActionButton.extended(
        // Every tab stays built in the gallery's IndexedStack, so several of
        // these share one route. The default tag would collide in a Hero
        // flight the moment anything pushed a page.
        heroTag: null,
        onPressed: running ? null : onRun,
        icon: Icon(running ? Icons.hourglass_empty : Icons.play_arrow),
        label: Text(running ? 'Running' : 'Run'),
      );
}
