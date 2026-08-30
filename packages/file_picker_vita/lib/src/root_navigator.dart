import 'package:flutter/widgets.dart';

/// Finds the application's root [NavigatorState] without being handed one.
///
/// A picker that draws itself needs somewhere to draw. Every other
/// `file_picker` implementation calls a system dialog and needs no context at
/// all, which is why [FilePickerPlatform] passes none: the interface was shaped
/// by platforms where the picker is not part of the app.
///
/// The alternative was a static `navigatorKey` for the app to set. That is one
/// more line every app must add correctly, silently broken if forgotten, and
/// ADR-0009 already spends the app's goodwill on `registerWith()`. Walking the
/// tree costs a traversal per pick and asks nothing.
///
/// The first navigator found in a breadth-first walk is the root one, which is
/// the right target: a picker pushed into a nested navigator would be trapped
/// inside whatever tab or sheet owns it.
NavigatorState? findRootNavigator() {
  final Element? root = WidgetsBinding.instance.rootElement;
  if (root == null) {
    return null;
  }

  final List<Element> frontier = [root];
  while (frontier.isNotEmpty) {
    final List<Element> next = [];
    for (final Element element in frontier) {
      if (element is StatefulElement && element.state is NavigatorState) {
        return element.state as NavigatorState;
      }
      element.visitChildren(next.add);
    }
    frontier
      ..clear()
      ..addAll(next);
  }
  return null;
}
