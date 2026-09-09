# Fonts the port ships that the engine does not

These are in the repository rather than in `third_party/` because that
directory is a gclient checkout and gitignored. A font we chose has to be
tracked.

Every `.vpk` gets what is here in `app0:/fonts`, plus `Roboto-Regular.ttf` out
of the engine checkout. Nothing else. `SkFontMgr_New_Custom_Directory` indexes
that directory by the family name inside each file, so what goes in it is a
deliberate choice and each file is a candidate for every codepoint.

## RobotoMono-Regular.ttf

`Roboto Mono`, SIL Open Font License 1.1.

Here so that `fontFamily: 'monospace'` resolves to something. It cannot resolve
by name on its own: no font file declares the family "monospace", so the
request returned nothing and skparagraph fell back to Roboto, which is
proportional. The alias table in `txt/src/txt/platform_vita.cc` maps the
generic names onto this file, and the table is useless without it.

109 KB.

## OFL.txt

The licence, shipped inside every `.vpk` beside the fonts, because the OFL
requires the notice and the licence to accompany every copy. See
[NOTICE](../../NOTICE).

**This copy carries Noto Emoji's copyright line and needs replacing.** Both
fonts want re-taking from `google/fonts` (`ofl/roboto`, `ofl/robotomono`) with
each family's own `OFL.txt`, which is also what fixes their provenance: the
Roboto we ship is Flutter's unit-test fixture and the Roboto Mono came out of a
DevTools bundle inside a Dart SDK prebuilt. Neither source ships a licence.

## No emoji font

There was one, `NotoEmoji-Regular.ttf`, 1.9 MB in the repository and in every
`.vpk`. It went in for one test application and came out on 2026-09-09.

Emoji coverage is an application's choice. An app that wants it declares a font
under `fonts:` in its `pubspec.yaml` and the asset font provider picks it up.
Roboto covers 896 codepoints and stops at U+FFFD, so an app that declares
nothing draws tofu where emoji would be. That is the application's answer to
give, not the platform's, and it does not cost 1.9 MB to every app that has no
emoji in it.
