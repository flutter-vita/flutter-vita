# Writing Flutter that runs on a Vita

Everything here is measured on hardware by
[the gallery's benchmark](../apps/gallery/lib/bench), on the GPU path, and
every claim names the scene it came from so you can re-run it. See
[ADR-0017](adr/0017-the-gallery-becomes-the-benchmark.md) for how the suite
works and [ADR-0014](adr/0014-gpu-backend-via-vitagl.md) for the renderer.

The frame budget is **16.67 ms**. The console is a 444 MHz Cortex-A9.

## 1. Count your `Text` widgets. That is your frame time.

**A `Text` widget costs about 1 ms.** Not a line of text, not a glyph — the
widget. The cost is building and laying out a `ui.Paragraph`, and that is
dominated by fixed per-paragraph work rather than by how much text is in it: a
`Text` holding one character and a `Text` holding forty-eight cost the same
1.2 ms.

Not *completely* flat, though. The engine's own paragraph counter reports
~260 us for the short single-line strings the route scenes use and ~580 us
during `list_churn`, whose tiles carry a subtitle long enough to wrap. So
wrapping, multi-line text is roughly twice a short label — still far closer to
flat than to proportional, and still the wrong axis to optimise along.

So a screen with forty pieces of text on it costs about 40 ms to build, and
misses two frames doing it, before it has drawn anything.

| scene | what it builds | UI-thread time |
|---|---|---|
| `route_text_uniq` | 48 `Text` widgets | **45.5 ms** |
| `route_text_one` | 1 `Text`, same 48 glyphs | **1.2 ms** |

### The fix: one `RichText`, many `TextSpan`s

`TextSpan`s inside one `RichText` are runs in a single paragraph, and runs are
nearly free. The same 48 numbers on screen:

| scene | | UI-thread time |
|---|---|---|
| `route_text_uniq` | 48 `Text` widgets | 45.5 ms |
| `route_spans` | 1 `RichText`, 48 `TextSpan`s | **1.2 ms** |

**38x, for the same pixels.** This is the single largest thing you can do.

It is not always possible — spans cannot be laid out independently, so a grid
of labels stays a grid of `Text`s. But a row of label-and-value pairs, a
sentence with an emphasised word, a list tile's title and subtitle: those are
spans, and most codebases write them as separate widgets out of habit.

### What does not help

- **Shortening the strings.** 48 one-character `Text`s cost the same as 48
  long ones — see the caveat above for wrapping text, which is about 2x a
  short label and still not proportional to its length.
- **Reusing the same string.** `route_text_same` (48 identical strings) costs
  45.1 ms against `route_text_uniq`'s 45.5. There is no content cache to hit.
- **A simpler `TextStyle`** — mostly. A style whose values all match the
  defaults costs ~400 us instead of ~750, but `DefaultTextStyle` in any
  Material app sets a colour and a family, so you are on the expensive side
  already and cannot easily get off it. Setting a field to the value it
  already had is free. Why the step exists is unknown; see ADR-0017.

## 2. A `GridView`'s per-child wrappers cost more than the children

`SliverChildListDelegate` wraps every child in a `RepaintBoundary`, an
`IndexedSemantics` and an `AutomaticKeepAlive`. For 48 cells:

| scene | | UI-thread time |
|---|---|---|
| `route_wrap` | 48 boxes in a `Wrap`, no Scrollable | **1.2 ms** |
| `route_grid_bare` | 48 boxes, `GridView`, three wrappers off | 5.8 ms |
| `route_boxes` | 48 boxes, `GridView`, stock | 11.6 ms |

```dart
GridView.count(
  addRepaintBoundaries: false,
  addAutomaticKeepAlives: false,
  addSemanticIndexes: false,
  ...
)
```

**Halves the build, and raster did not move** — 1.0 ms either way in this
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

| scene | | worst frame |
|---|---|---|
| `route_bare` | pushes an empty page | **66.7 ms, no stall** |
| `route_wrap` | pushes 48 boxes | **16.7 ms, no stall** |
| `route_push` | pushes 48 boxes + 48 `Text`s | 150 ms, stalls |

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
- **Text input** — the IME cannot composite over vitaGL, so an app that needs
  a keyboard needs `software.on` for now (ADR-0014).

## Where these numbers come from, and where they stop

Every figure above is from the gallery's benchmark scenes, which are synthetic
by design (ADR-0017 decision 1): they isolate one cost each, which is what
makes them attributable and also what makes them unrepresentative.

**The corpus check on a real app is still outstanding.** `keklist` — 242 `Text`
call sites, "long lists" its axis in the corpus — was deployed on 2026-08-25
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
