# Fonts the port ships that the engine does not

Each `.vpk` gets the files in this folder in `app0:/fonts`, and nothing else.
`templates/vita-app/CMakeLists.txt` copies them from here.
`SkFontMgr_New_Custom_Directory` reads that directory and finds each font by
the family name inside the file. Thus each file is a candidate for each
codepoint, and we choose each file carefully.

## Where the files come from

All four files come from [google/fonts](https://github.com/google/fonts) at
commit `e9678a5385322c63730122ba464765baad83cfd8` (2026-10-14), byte for byte.
Only the file names are different, because brackets in a file name cause
problems in shells and in CMake.

| File here | File in google/fonts | Size |
|---|---|---|
| `Roboto.ttf` | `ofl/roboto/Roboto[wdth,wght].ttf`, version 3.015 | 489 KB |
| `RobotoMono.ttf` | `ofl/robotomono/RobotoMono[wght].ttf`, version 3.001 | 184 KB |
| `Roboto-OFL.txt` | `ofl/roboto/OFL.txt` | 4 KB |
| `RobotoMono-OFL.txt` | `ofl/robotomono/OFL.txt` | 4 KB |

To check a file, compare its git blob hash with the hash on GitHub:

```sh
git hash-object templates/fonts/Roboto.ttf
gh api 'repos/google/fonts/contents/ofl/roboto/Roboto%5Bwdth,wght%5D.ttf?ref=e9678a5385322c63730122ba464765baad83cfd8' --jq .sha
```

Before 2026-10-14 the files had no clear source. Roboto was a Flutter
unit-test file, Roboto Mono came from the DevTools files in a Dart SDK
prebuilt, and the one `OFL.txt` had the copyright line of Noto Emoji.

## Roboto.ttf

The family `Roboto`, under the SIL Open Font License 1.1. 927 codepoints, up
to U+FFFD: Latin, Greek and Cyrillic.

It is the default family. This platform has no system font manager, and
`GetDefaultFontFamilies()` answers "Roboto". Without this file, no text
appears.

It is a variable font with two axes: weight (100 to 900) and width (75 to
100). Skia adds each of its 18 named instances to the family, from Thin to
Black, and the Condensed forms. Thus `FontWeight.bold` gets the real Bold
glyphs. With the old file, Skia made bold text by drawing the Regular glyphs
thicker.

## RobotoMono.ttf

The family `Roboto Mono`, under the SIL Open Font License 1.1. 876
codepoints.

It is here so that `fontFamily: 'monospace'` finds a font. No font file
declares the family "monospace", so the alias table in
`txt/src/txt/platform_vita.cc` points "monospace" and the other generic names
at "Roboto Mono". Without this file, the table points at nothing, and
skparagraph uses Roboto, which is not monospaced.

It is a variable font with one axis, weight (100 to 700), and 7 named
instances.

## Roboto-OFL.txt and RobotoMono-OFL.txt

The licence of each family, with the family's own copyright line. The OFL
says that the notice and the licence must go with each copy of the font, so
each `.vpk` carries both files beside the fonts. See [NOTICE](../../NOTICE).

## No emoji font: the app adds one when it needs it

There was one, `NotoEmoji-Regular.ttf`. It added 1.9 MB to the repository and
to each `.vpk`. It went in for one test app and came out on 2026-09-09.

Emoji coverage is the app's choice, the same as any other font that it needs.
An app declares a font under `fonts:` in its `pubspec.yaml`, and the asset
font provider finds it. Roboto has no emoji, so an app that declares no emoji
font draws empty boxes in place of emoji. Each Flutter target works this way.
