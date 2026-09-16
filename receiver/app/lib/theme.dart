// The panel's palette and the three widgets every tab builds out of.
//
// No Material. The receiver links the pinned engine and runs on the CPU
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

const mono = TextStyle(
  fontFamily: 'monospace',
  fontSize: 13,
  height: 1.35,
  color: muted,
);
const label = TextStyle(fontSize: 13, height: 1.2, color: dim);
const heading = TextStyle(
  fontSize: 15,
  height: 1.2,
  color: fg,
  fontWeight: FontWeight.w600,
);

/// A rounded box with a visible edge, drawn as two filled rectangles rather
/// than one bordered one.
///
/// BoxDecoration paints a uniform border with Canvas.drawDRRect
/// (box_border.dart:298). On the GL path that call fills the whole shape with
/// the border colour once the box is short. Measured on this panel 2026-09-08:
/// the log Panel at 755x335 drew a correct 1 px edge, while the list row at
/// 755x62 and every button at ~90x26 came out as solid blocks with their text
/// buried in them. Two filled rounded rectangles use drawRRect only, which is
/// correct at every size here.
///
/// [fill] is composited against [under] rather than left translucent, because
/// the outer rectangle is the border colour and a translucent fill laid over it
/// would tint against that edge instead of against the page.
class Outlined extends StatelessWidget {
  const Outlined({
    super.key,
    required this.colour,
    required this.child,
    this.fill,
    this.under = bg,
    this.radius = 5,
    this.width = 1,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.expand = false,
  });

  final Color colour;
  final Widget child;

  /// Null means the inside is whatever the box sits on.
  final Color? fill;
  final Color under;
  final double radius;
  final double width;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Padding(
        padding: EdgeInsets.all(width),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color.alphaBlend(fill ?? under, under),
            borderRadius: BorderRadius.circular(
              (radius - width).clamp(0.0, radius),
            ),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    if (expand) box = SizedBox(width: double.infinity, child: box);
    if (margin != EdgeInsets.zero) box = Padding(padding: margin, child: box);
    return box;
  }
}

/// A bordered well. Everything scrollable in this app sits in one.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = 10});

  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) => Outlined(
    expand: true,
    colour: line,
    fill: sunken,
    radius: 6,
    padding: EdgeInsets.all(padding),
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
      child: Outlined(
        colour: c,
        fill: c.withValues(alpha: enabled ? 0.14 : 0.06),
        radius: 5,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
    child: Outlined(
      colour: selected ? accent : line,
      fill: selected ? accent.withValues(alpha: 0.14) : bg,
      radius: 5,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.only(bottom: 4),
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
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontFamily: 'monospace',
        color: faint,
      ),
    ),
  );
}

/// The glyphs the navigation rail draws.
///
/// Painted rather than set in a font. MaterialIcons is 1.6 MB and shipping it
/// would mean either `uses-material-design: true` for four shapes, or dropping
/// the file into app0:/fonts -- where the embedder treats every face as a
/// fallback for every codepoint, and body text starts rendering as icons.
enum Glyph { deploy, logs, crashes, apps, tests, files }

class GlyphIcon extends StatelessWidget {
  const GlyphIcon(
    this.glyph, {
    super.key,
    required this.colour,
    this.size = 22,
  });

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
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(4 * u, 17 * u)
            ..lineTo(4 * u, 20 * u)
            ..lineTo(20 * u, 20 * u)
            ..lineTo(20 * u, 17 * u),
          stroke,
        );
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
          stroke,
        );
        canvas.drawRRect(
          RRect.fromLTRBR(11 * u, 9 * u, 13 * u, 15 * u, Radius.circular(u)),
          fill,
        );
        canvas.drawCircle(p(12, 17.6), 1.2 * u, fill);
      // Four tiles.
      case Glyph.apps:
        for (final dx in const [0.0, 10.0]) {
          for (final dy in const [0.0, 10.0]) {
            canvas.drawRRect(
              RRect.fromLTRBR(
                (3 + dx) * u,
                (3 + dy) * u,
                (11 + dx) * u,
                (11 + dy) * u,
                Radius.circular(1.5 * u),
              ),
              fill,
            );
          }
        }
      // A bar chart. Three columns of different heights on a baseline, which
      // is what a benchmark looks like from across the room.
      case Glyph.tests:
        canvas.drawLine(p(3, 20), p(21, 20), stroke);
        canvas.drawLine(p(7, 20), p(7, 13), stroke);
        canvas.drawLine(p(12, 20), p(12, 6), stroke);
        canvas.drawLine(p(17, 20), p(17, 10), stroke);
      // A folder.
      case Glyph.files:
        canvas.drawPath(
          Path()
            ..moveTo(3 * u, 6 * u)
            ..lineTo(10 * u, 6 * u)
            ..lineTo(12 * u, 8.5 * u)
            ..lineTo(21 * u, 8.5 * u)
            ..lineTo(21 * u, 19 * u)
            ..lineTo(3 * u, 19 * u)
            ..close(),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.colour != colour;
}
