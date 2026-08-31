// The panel's palette and the three widgets every tab builds out of.
//
// No Material. The loader links the blessed engine and runs on the CPU
// rasteriser (ADR-0016 decisions 2 and 7), and Material's ink, shadows and
// implicit animations are all things this rasteriser pays for on a screen
// nobody is looking at for longer than a deploy takes.

import 'package:flutter/widgets.dart';

const bg = Color(0xFF0B1420);
const sunken = Color(0xFF08101A);
const line = Color(0xFF1C2C3D);
const fg = Color(0xFFE8F1FA);
const dim = Color(0xFF8FA3B5);
const muted = Color(0xFF7E93A6);
const faint = Color(0xFF3E5163);

const accent = Color(0xFF4B8FD6);
const danger = Color(0xFFE05A4F);
const warn = Color(0xFFE0A03A);
const good = Color(0xFF4CAF7D);

const mono = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35,
    color: muted);
const label = TextStyle(fontSize: 13, height: 1.2, color: dim);
const heading = TextStyle(fontSize: 15, height: 1.2, color: fg,
    fontWeight: FontWeight.w600);

/// A bordered well. Everything scrollable in this app sits in one.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = 10});

  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          color: sunken,
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      );
}

/// A tap target with a visible edge.
///
/// Sized for a thumb rather than a cursor: the whole rectangle is opaque to
/// hit testing, which is the difference between a button you press and a
/// button you aim at.
class Btn extends StatelessWidget {
  const Btn({
    super.key,
    required this.text,
    required this.onTap,
    this.colour = accent,
    this.enabled = true,
  });

  final String text;
  final VoidCallback onTap;
  final Color colour;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = enabled ? colour : faint;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: c.withValues(alpha: enabled ? 0.14 : 0.06),
          border: Border.all(color: c),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            height: 1.0,
            letterSpacing: 1.0,
            fontWeight: FontWeight.w700,
            color: c,
          ),
        ),
      ),
    );
  }
}

/// A row that reads as one item in a list and answers a tap anywhere on it.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.children,
    this.onTap,
    this.selected = false,
  });

  final List<Widget> children;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.14) : bg,
            border: Border.all(color: selected ? accent : line),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(children: children),
        ),
      );
}

/// What a tab shows when there is nothing to show.
class Empty extends StatelessWidget {
  const Empty(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Text(text,
            style: const TextStyle(
                fontSize: 13, fontFamily: 'monospace', color: faint)),
      );
}
