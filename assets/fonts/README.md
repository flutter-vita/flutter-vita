# Fonts the port ships that the engine does not

These are in the repository rather than in `third_party/` because that
directory is a gclient checkout and gitignored. A font we chose has to be
tracked.

Every `.vpk` gets what is here in `app0:/fonts`. Nothing else. `SkFontMgr_New_Custom_Directory` indexes
that directory by the family name inside each file, so what goes in it is a
deliberate choice and each file is a candidate for every codepoint.

## Roboto-Regular.ttf

`Roboto`, SIL Open Font License 1.1. 171 KB.

The default family, and the only reason any text appears at all: this platform
has no system font manager, and `GetDefaultFontFamilies()` answers "Roboto".

It is tracked here rather than taken from the engine checkout, where it lives
under `txt/third_party/fonts` and `txt/BUILD.gn` lists it in `test_fixtures`
inside `if (enable_unittests)`. It is upstream's unit-test asset. That is why
`LICENSE.engine` never mentions Roboto: upstream's licence tooling excludes
fixtures, correctly, because upstream does not ship them.

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
each family's own `OFL.txt`. The licence is not in doubt; the copyright line
shipped beside it is currently the wrong one.

## No emoji font, and that is the application's business

There was one, `NotoEmoji-Regular.ttf`, 1.9 MB in the repository and 1.9 MB in
every `.vpk`. It went in for one test application and came out on 2026-09-09.

Emoji coverage is an application's choice, the same as any other font it needs.
An app declares one under `fonts:` in its `pubspec.yaml` and the asset font
provider picks it up. Roboto covers 896 codepoints and stops at U+FFFD, so an
app that declares nothing draws tofu where emoji would be. Every Flutter target
works this way; none of them promise a glyph the app did not ask for.
