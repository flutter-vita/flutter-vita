# Fonts the port ships that the engine does not

One file so far, and it is here rather than in `third_party/` because that
directory is a gclient checkout and gitignored — a font we chose has to be
tracked.

## NotoEmoji-Regular.ttf

`Noto Emoji` v3.002, from
[google/fonts `ofl/notoemoji`](https://github.com/google/fonts/tree/main/ofl/notoemoji),
under the SIL Open Font License (`OFL.txt` beside it).

**Monochrome, and that is the point.** The engine checkout already carries a
`NotoColorEmoji.ttf` next to the Roboto this port ships, and it was tried first.
Two things ruled it out on 2026-08-28:

- **It is from May 2017.** `Version 1.39;GOOG;noto-emoji:20170518`, 1189
  codepoints, Unicode 9.0. Everything added since — 🤩 (U10), 🥰 (U11), 🥲 (U13),
  🫠 (U14), 🫨 (U15) — has no glyph, so keklist's picker rendered a field of
  `.notdef` rectangles between the faces that did work. This one has 1489
  codepoints and covers through Unicode 15.
- **CBDT/CBLC is PNG bitmaps, not outlines.** Emoji paragraphs laid out at
  4550 us against 424 us for ordinary text, and single frames stalled 6-7
  seconds on the emoji grid. Outline glyphs cost what any other glyph costs.

It is a variable font (`fvar`, weight axis); FreeType renders the default
instance and nothing here asks for another. 1.9 MB against the colour font's
4.7 MB, and it lands in every `.vpk` — see `tools/package-engine.sh`.

The trade is colour. Emoji render as monochrome outlines, which is what the
Vita's own system font does for symbols anyway.
