# Writing Flutter that runs on a Vita

Everything here is measured on hardware by
[the benchmark](https://github.com/flutter-vita/flutter-vita-bench/blob/master/lib), on the GPU path, and
every claim names the scene it came from so you can re-run it. See
[ADR-0017](https://github.com/flutter-vita/flutter-vita-bench/blob/master/docs/adr/0017-the-gallery-becomes-the-benchmark.md) for how the suite
works and [ADR-0019](adr/0019-gles2-over-gxm-written-here.md) for the renderer.

The frame budget is **16.67 ms**. The console is a 444 MHz Cortex-A9.

## 1. Count your `Text` widgets. That is your frame time.

**A `Text` widget costs about 1 ms.** Not a line of text, not a glyph — the
widget. The cost is building and laying out a `ui.Paragraph`, and that is
dominated by fixed per-paragraph work rather than by how much text is in it: a
`Text` holding one character and a `Text` holding forty-eight cost the same.

Not *completely* flat, though. The engine's own paragraph counter reports
~260 us for the short single-line strings the route scenes use and ~580 us
during `list_churn`, whose tiles carry a subtitle long enough to wrap. So
wrapping, multi-line text is roughly twice a short label — still far closer to
flat than to proportional, and still the wrong axis to optimise along.

So a screen with forty pieces of text on it costs about 40 ms to build, and
misses two frames doing it, before it has drawn anything.

| scene | what it builds | UI-thread time |
|---|---|---|
| `route_text_uniq` | 48 `Text` widgets | **46.7 ms** |
| `route_wrap` | the same 48 boxes without the text | 10.0 ms |

### The fix: one `RichText`, many `TextSpan`s

`TextSpan`s inside one `RichText` are runs in a single paragraph, and runs are
nearly free. The same 48 numbers on screen:

| scene | | UI-thread time |
|---|---|---|
| `route_text_uniq` | 48 `Text` widgets | 46.7 ms |
| `route_spans` | 1 `RichText`, 48 `TextSpan`s | **4.8 ms** |

**Roughly 10x, for the same pixels**, and it takes the screen from missing two
frames to fitting inside one. This is the single largest thing you can do.

It is not always possible — spans cannot be laid out independently, so a grid
of labels stays a grid of `Text`s. But a row of label-and-value pairs, a
sentence with an emphasised word, a list tile's title and subtitle: those are
spans, and most codebases write them as separate widgets out of habit.

### What does not help

- **Shortening the strings.** 48 one-character `Text`s cost the same as 48
  long ones — see the caveat above for wrapping text, which is about 2x a
  short label and still not proportional to its length.
- **Reusing the same string.** 48 identical strings cost
  the same as 48 unique ones — measured before that control was retired. There
  is no content cache to hit.
- **A simpler `TextStyle`** — mostly. A style whose values all match the
  defaults costs ~400 us instead of ~750, but `DefaultTextStyle` in any
  Material app sets a colour and a family, so you are on the expensive side
  already and cannot easily get off it. Setting a field to the value it
  already had is free. Why the step exists is unknown; see ADR-0017.

## 2. A `GridView`'s per-child wrappers cost more than the children

`SliverChildListDelegate` wraps every child in a `RepaintBoundary`, an
`IndexedSemantics` and an `AutomaticKeepAlive`. For 48 cells:

| scene | | UI-thread time | per cell |
|---|---|---|---|
| `route_wrap` | 48 boxes in a `Wrap`, no Scrollable | 10.0 ms | ~208 us |
| `route_grid_bare` | ~32 visible cells, three wrappers off | **6.0 ms** | ~187 us |
| `route_boxes` | ~32 visible cells, stock | 12.6 ms | ~394 us |

A `Wrap` builds all 48; a `GridView` builds only what fits on screen, which is
why it can come out cheaper than the `Wrap` despite the extra machinery. Per
cell the picture is consistent: **a box costs ~200 us, and the three wrappers
cost another ~200 us on top of it.**

```dart
GridView.count(
  addRepaintBoundaries: false,
  addAutomaticKeepAlives: false,
  addSemanticIndexes: false,
  ...
)
```

**Halves the build, and raster did not move** — around 1 ms either way in this
scene.

Read that caveat carefully, though: this scene does not scroll and repaints
everything every frame, which is precisely the case where a `RepaintBoundary`
has nothing to save. On a list where a few rows change and the rest do not, the
boundaries are what stop the whole viewport re-rastering. **Measure it on your
own screen** rather than switching them off everywhere.

Semantics indexes are free to drop: this port registers no accessibility
client, so nothing consumes them.

## 3. Do not build a page during a transition

A pushed route builds on the first frame of its animation, so the whole page's
build lands inside the transition. That is why a transition stutters even
though the transition itself is free:

| scene | | build | result |
|---|---|---|---|
| `route_bare` | pushes an empty page | 4.2 ms | **no stall** |
| `route_wrap` | pushes 48 boxes | 10.0 ms | **no stall** |
| `route_spans` | pushes 48 spans in one `RichText` | 4.8 ms | **no stall** |
| `route_push` | pushes 48 boxes + 48 `Text`s | 77.7 ms | stalls |

Ten milliseconds of build fits inside a frame and nobody sees it. Forty-seven
does not.

The transition machinery costs nothing. What stutters is whatever you pushed.

## 4. The GPU is the default, and it is not your problem any more

Since 2026-08-24 the GPU path is on unless `ux0:data/flutter-vita/software.on`
says otherwise. Raster is under 8 ms on every scene above; on the software path
the same transitions were 17-20x slower.

**If a screen is slow now, it is slow on the UI thread**, and nothing about
painting, opacity, clipping or transforms will fix it. Look at what you are
building.

## 5. Things that are still slow and are not your fault

- **`blur_backdrop`** — a backdrop blur costs ~43 ms of raster even on the GPU.
- **`list_churn`** — a scrolling `ListView` of `ListTile`s is the worst scene
  in the suite at ~127 ms. Three `Text` widgets per tile, tiles recycled
  constantly; section 1 explains it entirely.
- **Text input** — the inline keyboard (`SceIme`, libime) composites after
  the frame is presented and asks nothing of the renderer; it ran under vitaGL
  and the software path (ADR-0014). Nobody has driven it on `fvita_gles2` yet
  (2026-09-14).

## 6. Ship the fonts your app needs

`app0:/fonts` holds Roboto and Roboto Mono, and that is the whole set. There is
no system font manager on this platform, so those two are what
`SkFontMgr_New_Custom_Directory` has to work with.

Generic family names resolve. `monospace`, `Courier New`, `Menlo`, `Consolas`
and `SF Mono` reach Roboto Mono; `sans-serif`, `Arial`, `Helvetica` and
`Segoe UI` reach Roboto. The serif names reach Roboto too, which is the wrong
shape and is what they resolved to before, silently.

**Everything else is yours to ship.** Declare it under `fonts:` in
`pubspec.yaml` and the asset font provider picks it up, exactly as on Android
and iOS. Roboto covers 896 codepoints and stops at U+FFFD, so an app that
renders an emoji and declares no font for it draws an empty box. That is not a
gap in the port. No Flutter target promises a glyph the app did not ask for,
and an emoji font is 1.9 MB that most apps have no use for.

## 7. Your icon is an 8-bit indexed PNG, or the console refuses the vpk

The shell installs `sce_sys/icon0.png` (128x128), `bg0.png` (840x500) and
`startup.png` (280x158) only as 8-bit indexed PNGs. A 32-bit RGBA icon, which
is what every image editor exports by default, fails the install with
`0x8010113D`, from VitaShell and from `install-vpk.sh` alike, and the code says
nothing about images. The bridge's own first install on a fresh console
failed this way on 2026-09-11; re-encoding the three files was the whole fix.

The build checks the art at configure time (`tools/check-livearea-art.dart`)
and refuses to produce a vpk it knows the console will refuse, with the
one-line re-encode in the message. `pngquant` does it, and so does Pillow's
`quantize(256)`.

## Two of these numbers moved on 2026-08-25, and why

An earlier version of this page said spans were **38x** cheaper than `Text`
widgets and that 48 boxes in a `Wrap` cost 1.2 ms. Both came from a statistic
that ranked a scene's frames by **period** — how late the frame was — and took
the build times of the worst five.

That is blind to any build that fits inside a frame. A 10 ms build makes no
long period at all, so period-ranking could never find it and reported the
scene's idle frames instead. Ranking by build time found them: `route_wrap` is
10.0 ms and not 1.2, and `route_spans` is 4.8 and not 1.2.

The advice does not change — spans are still the largest single win available —
but it is 10x and not 38x, and a screen that "costs nothing" may simply have
been costing less than one frame.

**`route_boxes` and `route_push` are still not steady** (12.6 and 30.8 on one
binary; 52.3 and 77.7). Treat the `GridView` numbers in section 2 as an
order of magnitude. The text numbers repeat to within a millisecond across
every run.

## Where these numbers come from, and where they stop

Every figure above is from the benchmark's scenes, which are synthetic
by design (ADR-0017 decision 1): they isolate one cost each, which is what
makes them attributable and also what makes them unrepresentative.

**The test apps check on a real app is still outstanding.** `keklist` — 242 `Text`
call sites, "long lists" its axis in the test apps — was deployed on 2026-08-25
and holds **60 fps under GL**, but on a main screen whose notes list is empty.
It never exercised the cost. Its startup windows report 1852–2607 us per
paragraph against the gallery's 260, and those are **not** quotable as a
contradiction: a startup window includes first-use font resolution and asset
loading, and the same run's later window reads 362 us.

So: the mitigations in sections 1 and 2 are measured and real, the per-widget
millisecond is measured on short strings and reasonable, and none of it has yet
been confirmed on a text-dense screen of a production app. Confirming it needs
app state the dev server cannot create — the `tap` command can navigate, but
not populate a journal.
