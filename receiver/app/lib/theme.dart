// The panel's palette and the three widgets every tab builds out of.
//
// No Material. The receiver links the blessed engine and runs on the CPU
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

/// The four glyphs the navigation rail draws.
///
/// Painted rather than set in a font. MaterialIcons is 1.6 MB and shipping it
/// would mean either `uses-material-design: true` for four shapes, or dropping
/// the file into app0:/fonts -- where the embedder treats every face as a
/// fallback for every codepoint, and body text starts rendering as icons.
enum Glyph { deploy, logs, crashes, apps, tests }

class GlyphIcon extends StatelessWidget {
  const GlyphIcon(this.glyph, {super.key, required this.colour, this.size = 22});

  final Glyph glyph;
  final Color colour;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _GlyphPainter(glyph, colour)),
      );
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.colour);

  final Glyph glyph;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 24.0; // the glyphs are drawn in a 24 x 24 box
    final fill = Paint()..color = colour;
    final stroke = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset p(double x, double y) => Offset(x * u, y * u);

    switch (glyph) {
      // An arrow into a tray: what this screen is waiting for.
      case Glyph.deploy:
        canvas.drawLine(p(12, 3), p(12, 14), stroke);
        canvas.drawPath(
            Path()
              ..moveTo(7 * u, 10 * u)
              ..lineTo(12 * u, 15 * u)
              ..lineTo(17 * u, 10 * u),
            stroke);
        canvas.drawPath(
            Path()
              ..moveTo(4 * u, 17 * u)
              ..lineTo(4 * u, 20 * u)
              ..lineTo(20 * u, 20 * u)
              ..lineTo(20 * u, 17 * u),
            stroke);
      // Lines of text, one short, the way a log looks from across the room.
      case Glyph.logs:
        for (var i = 0; i < 4; i++) {
          final y = 5.0 + i * 4.6;
          canvas.drawLine(p(4, y), p(i == 3 ? 14 : 20, y), stroke);
        }
      // A warning triangle. The bang is two fills rather than a stroke so it
      // stays legible at 22 px.
      case Glyph.crashes:
        canvas.drawPath(
            Path()
              ..moveTo(12 * u, 3.5 * u)
              ..lineTo(22 * u, 20.5 * u)
              ..lineTo(2 * u, 20.5 * u)
              ..close(),
            stroke);
        canvas.drawRRect(
            RRect.fromLTRBR(11 * u, 9 * u, 13 * u, 15 * u, Radius.circular(u)),
            fill);
        canvas.drawCircle(p(12, 17.6), 1.2 * u, fill);
      // Four tiles.
      case Glyph.apps:
        for (final dx in const [0.0, 10.0]) {
          for (final dy in const [0.0, 10.0]) {
            canvas.drawRRect(
                RRect.fromLTRBR((3 + dx) * u, (3 + dy) * u, (11 + dx) * u,
                    (11 + dy) * u, Radius.circular(1.5 * u)),
                fill);
          }
        }
      // A bar chart. Three columns of different heights on a baseline, which
      // is what a benchmark looks like from across the room.
      case Glyph.tests:
        canvas.drawLine(p(3, 20), p(21, 20), stroke);
        canvas.drawLine(p(7, 20), p(7, 13), stroke);
        canvas.drawLine(p(12, 20), p(12, 6), stroke);
        canvas.drawLine(p(17, 20), p(17, 10), stroke);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.colour != colour;
}
