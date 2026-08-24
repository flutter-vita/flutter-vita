# ADR-0017: The gallery becomes the benchmark, and a scene is the unit

**Status:** Accepted
**Date:** 2026-08-24

## Context

The port renders. It is stable enough that the open question stopped being
"does this work" and became "why does it feel slow", stated directly:

> now bottleneck is performance
> we need to upgrade gallery and you need to run some tests there
> you need to indicate much problematic transitions and animations
> we need also have a option to compare software and gpu BE

Everything measured so far has been measured badly, and the failures are all
the same shape.

- [ADR-0014](0014-gpu-backend-via-vitagl.md) records manga_reader going from
  45 to 60 fps under GL. On 2026-08-24 that app turned out to be showing a
  loading spinner and then its own error page, because the content never
  arrives over the network. The figure is unverified, not disproven, and
  nobody can currently reproduce it.
- A software-versus-GL comparison run the same day compared a spinner against
  an error screen and had to be retracted within the hour.
- The 444 MHz clock landed *after* the numbers it invalidates, and nothing
  noticed.
- A `.vpk` built 56 minutes before the engine was repackaged ran the GPU while
  reporting `gl.on = 0`, so a binary's own claim about its renderer was wrong.

None of these were analysis mistakes. They were the absence of a repeatable
measurement: every number came from a human driving an app by hand, once, on
whatever binary happened to be installed. **The instrument is the deliverable
here, not the numbers it produces first.**

## Decision

**The gallery grows a benchmark section that drives a fixed list of scenes
itself, and a host tool runs it on both renderers and diffs the result against
a committed baseline.**

### The ten decisions, and what each rejected

**1. Scripted scenes, not a human with a stopwatch.** The app pushes its own
routes and runs its own controllers on a timer, with no input. Rejected
driving it by hand and reading the HUD, which measures exactly what annoys you
and can never tell a regression from a different swipe. The cost is real and
accepted: **the suite measures the scenes I chose**, so a transition that is
slow in a way no scene reproduces stays invisible.

**2. A scene is one animation, run to completion, repeated.** Measurement
starts when the transition starts and stops when it ends. Rejected a fixed
wall-clock window, which is the mistake that makes everything look fine: a
300 ms page push sampled over two seconds is three-quarters idle, and idle
drags every average toward 60. Rejected a fixed frame count too — equal sample
sizes are tidier, but a stalling scene then takes unbounded wall time.

**3. Problematic means two or more consecutive frames at or below 30 fps.**
The floor is 30, which was chosen directly; the *consecutive* part is this
ADR's contribution and it matters. At 60 Hz every frame period is a multiple
of 16.67 ms, so a frame that misses one deadline presents at 33.3 ms — which
already reads as 30 fps. A literal "any frame below 30" therefore fires on
every single dropped frame, and on this console that is nearly every scene.
Requiring two in a row means the flag marks a stall of 66.7 ms or longer,
which is the shortest interruption a person reliably sees. The report names
the longest such stall per scene.

**4. Every scene reports the UI/raster split, not just the frame period.**
This port's central finding is that the UI thread dominates — localsend spent
144 ms of a 159 ms frame there — so a red scene reporting only "slow" says
nothing about whether the GPU could possibly help it. Rejected period-only as
too cheap to act on.

**And this is much cheaper than it sounds, which is worth recording because I
priced it wrong during the interview.** I described it as wiring frame timings
through the embedder. It is not: `SchedulerBinding.addTimingsCallback` hands
Dart a `FrameTiming` per frame with `buildDuration` and `rasterDuration`
already separated, plus a frame number to correlate against. The measurement
lives entirely in the gallery's own Dart. **No engine change, so no engine
rebuild, so the benchmark is not pinned to an artifact.**

**5. Each scene is tagged with the renderer primitive it stresses.** Not a
measurement — my labelling — and marked as such in the output. It exists so a
red row points at `saveLayer` or `clip` or `image scale` and lands next to
ADR-0014's per-op numbers, instead of pointing at a scene name.

**6. The overlay is forced off during a run.** The debug HUD costs about
300 us a frame and is drawn into the same frame it is measuring. This is not
hypothetical caution: on 2026-08-22 I attributed a 45-versus-60 fps difference
to the HUD, then disproved it myself with a repeat A/B. An instrument that
perturbs its own subject produces exactly that kind of retraction.

**7. The host tool runs both renderers; the app never compares.** The renderer
switch is read once at startup, so a comparison is always two runs and a
relaunch.
One command deploys, runs, flips the switch, relaunches, runs again, pulls
both result files and prints a table. Rejected having the app remember its
last run per backend and draw both on screen: it demos well and it drifts out
of sync the moment only one side is re-run, and nothing can diff two builds.
Rejected "just write a file and compare by eye", which is precisely how
today's bad numbers happened.

**8. Report, and fail against a committed baseline.** The results file goes in
the repo. A scene regressing more than **10% on its worst-frame time** fails
the run. Worst-frame rather than mean, because that is the number the 30 fps
rule is made of. Rejected failing on any measurable slowdown — this console
has thermal and Wi-Fi noise, and a gate that cries wolf gets bypassed — and
rejected failing against an absolute 60 fps budget, which would be red from
day one and learned-around by the end of the week.

**9. The baseline records the conditions it was taken under.** Clocks,
renderer, engine revision, and the app's own build. The 444 MHz change moved
every number in the project and nothing caught it; a baseline that does not
say what it was measured on is a baseline that silently becomes a lie. A run
whose conditions differ from the baseline's reports the difference rather than
failing.

**10. Under two minutes for a full run, both renderers.** So it costs about
what a build costs and nobody has to decide to skip it. That budget is the
real constraint on the suite: roughly a dozen scenes at a few repeats, with
two relaunches at about three seconds each.

## What a scene is, concretely

| Field | Meaning |
|---|---|
| `name` | Stable identifier; the baseline is keyed on it |
| `stresses` | The renderer primitive it leans on. A label, not a measurement |
| `repeats` | How many times the animation runs |
| `worst_ms` | Slowest single frame across all repeats — what the gate uses |
| `p95_ms` | 95th percentile frame period |
| `stall_ms` | Longest run of consecutive frames at or below 30 fps; 0 is a pass |
| `build_ms` / `raster_ms` | Median UI and raster time, from `FrameTiming` |

## Consequences

- **The gallery stops being only an eye-check.** Its own header calls it "what
  this port looks like, judged by eye"; it now also produces numbers, and the
  two purposes have to coexist in one app. Accepted over a fifth product
  against [ADR-0015](0015-four-products-one-audience.md)'s four, and over a
  hidden bench mode behind a file switch.
- **A committed baseline is a file that will be wrong and have to be updated**,
  and every update is a judgement about whether a change was an improvement or
  a regression that got normalised. That judgement is the point.
- **Scenes are not real apps.** A suite that is green while localsend still
  feels bad means the suite is missing a scene, not that localsend is fine.
- **The GPU baseline can only be taken when GL is safe to run.** A hard crash
  under GL wedges the console (ADR-0014), so an unattended GL run is a
  different risk from an unattended software run.

## What the run says

Taken 2026-08-24 on the pinned engine, both renderers, warm shader cache, with
vitaGL built per [patches/vitagl/README.md](../../patches/vitagl/README.md);
`apps/gallery/bench/{sw,gl}.json` is this run.

**The GPU wins every scene.** Worst-frame, software over GL: 20.33× on a
backdrop blur, 18.38× / 17.00× / 16.89× on the three route transitions, 7.25×
on a saveLayer tint, 3.25× on image scaling. The narrowest are `clip_rrect`,
`opacity_fade` and `transform_rotate` at 1.00× and `list_churn` at 1.06×.
Nothing is below 1.00. An earlier reading of this table had GL losing two
scenes; both losses were measurement, not rendering — see below.

**Three of fourteen scenes hold 60 fps**: `fill_lerp`, `image_scale`, and
`route_bare`, all on GL only. Eleven still stall, where a stall is two
consecutive frames at or below 30 fps. That is a statement about the port
rather than about the suite.

**The route scenes settle what a transition costs.** `route_bare`,
`route_boxes` and `route_push` push the same page with progressively more in
it, and the UI-thread time goes 1.2 ms → 32 ms → 45 ms while raster stays at
7 ms on every one of them; `route_hero` reaches 116 ms. So the transition
machinery is not the cost and neither is the renderer. Building the destination
page is, and text is about 14 ms of it. That decomposition is the reason the
suite has three pushes instead of one.

Three things the suite got wrong about itself, all worth keeping written down:

**A cold shader cache is a different machine.** vitaGL compiles each shader on
first use and keeps it under `ux0:data/shader_cache/<TITLEID>`, at 200–400 ms
apiece. The first committed GL baseline was taken on a fresh install, which
charged that compilation to whichever frame happened to need the shader and put
`blur_backdrop` at 0.95× — read at the time as "the GPU cannot help a blur".
Warm, it is 133 ms against software's 2017 ms. **Any GL number taken on a fresh
install is a number about compilation, not about rastering**, and a baseline
must say which it is.

**A slow renderer can be slow enough to stop being measurable.** Software
`route_bare` produces three frames in 2.3 seconds and is graded "too short to
grade" while GL holds 60 fps on the same scene — the honest report of a 40×
gap, but only because decision 5's floor refuses to turn it into a number.

**A ratio needs frames on both sides.** Software `route_push` produces *one*
frame in six seconds — 2500 ms of raster in it — so its "worst frame" is its
only frame, and dividing by it reported 1.22× for a scene the GPU wins by two
orders of magnitude. The report now prints `n/a` for the ratio when either side
fails decision 5's soundness floor, rather than a number that reads as a
measurement.

## What the route scenes found: a Text costs 950 us

Eleven pushes of the same transition onto pages that differ by one thing each,
GL. The column that matters is **bad build** — the UI-thread time in a typical
slow frame, taken as the median of the five slowest. `build_ms` is a median
over *every* frame and reads 1.2 ms on a route scene, because most of its
frames are the transition coasting; the frame that builds the incoming page is
the one being measured here.

| pushed page | bad build | worst frame |
|---|---|---|
| `route_text_one` — one Text, 48 glyphs | **1.0** | 133.3 |
| `route_wrap` — 48 boxes, no Scrollable | **1.2** | 33.3 |
| `route_boxes12` — 12 boxes in a GridView | **1.2** | 50.0 |
| `route_bare` — empty | 1.7 | 83.3 |
| `route_grid_bare` — 48 boxes, GridView, wrappers off | 7.1 | 133.3 |
| `route_boxes` — 48 boxes in a GridView | 12.7 | 133.3 |
| `route_text_uniq` — 48 unique Text | **46.9** | 150.0 |
| `route_text_same` — 48 identical Text | 55.1 | 150.0 |
| `route_hero` — hero flight | 61.4 | 150.0 |
| `route_push` — 48 boxes + 48 Text | **65.8** | 150.0 |
| `list_churn` — for comparison | 134.2 | 316.7 |

Raster is under 8 ms on all of them. **The renderer is not involved**, which is
the first thing the table settles: after the GPU became the default, a
transition's remaining cost is entirely UI-thread.

The rest of it decomposes, and the parts add up:

| what | cost | per item |
|---|---|---|
| the transition itself | 1.2 ms | — |
| 48 boxes, no Scrollable | ~0 | ~0 |
| a GridView's sliver machinery | 5.9 ms | — |
| its per-child RepaintBoundary, semantics and keep-alive | 5.6 ms | 117 us |
| **48 `Text` widgets** | **45.7 ms** | **950 us** |

`route_push` is 65.8 and those parts sum to about 59, with the remainder in the
`Center` wrapping each glyph. **Text is 69% of what a route push costs.**

Three controls make the text number hard to argue with. One `Text` holding the
same 48 glyphs costs 1.0 ms, so it is not the amount of text. Forty-eight
*identical* strings cost the same as forty-eight unique ones, so it is not
shaping cache misses. And the spikes land at frames 5, 43, 81, 119 and 267 of
291 — one per push, every push — so it is not a warm-up.

For scale, a `Container` in `route_wrap` costs about 25 us. A `Text` is
**38x** a `Container`.

### Where the 950 us goes, measured

[patches/flutter-engine/0010](../../patches/flutter-engine/0010-paragraph-timing.patch)
times the three phases of a `ui.Paragraph` and the embedder prints them:

```
flutter-vita: PARAGRAPHS 304 | ctor 18270 us | build 27486 us | layout 30746 us | 251 us each
```

**No single phase dominates.** Construction is ~22% of a paragraph, build 33%,
layout 40%, and the per-paragraph total sits near **260 us** in every scene
that makes paragraphs — `route_text_same` 251 us, `route_text_one` 267 us,
`route_boxes12` 254 us. That the per-paragraph cost is identical between a
scene making 48 paragraphs and one making 1 is the same finding from the other
side: `route_text_one` is fast because it makes fewer, not cheaper, paragraphs.

And **the engine is only about a quarter of it**. 48 paragraphs at 260 us is
12.5 ms of the 45.7 ms that 48 `Text` widgets cost. The other ~33 ms is the Dart side of `TextPainter` —
encoding a `ui.ParagraphStyle` and a `ui.TextStyle` into typed lists, building
the `RenderParagraph` — which this instrument does not see.

So the honest verdict is narrower than "a defect": there is no hot spot to fix.
Text costs about 950 us per widget, spread roughly 70/30 between framework and
engine and spread evenly *within* the engine. The remedy is architectural —
fewer paragraphs on a screen — until someone profiles the Dart side.

It also explains the rest of the suite. `list_churn` is the worst scene in it,
and one of its windows reports **1195 paragraphs with 506 ms of layout**: three
`Text` widgets per `ListTile`, hundreds of tiles recycled while scrolling.
`text_slide`, `route_push` and `route_hero` are the same story. Every scene the
GPU could not rescue is paragraph-bound.

The `GridView` step is a smaller second finding: 48 cells in a `GridView` cost
26.9 ms where the same 48 in a `Wrap` cost 1.0 ms. 12 cells in a `GridView` are
free, so unlike the text cost this one does scale, just very steeply.

### And the Dart side, timed without touching the framework

`TextPainter` is ordinary Dart calling ordinary `dart:ui`, so the same work can
be done in the app with a `Stopwatch` around each layer — no framework patch,
no engine patch. [text_probe.dart](../../apps/gallery/lib/bench/text_probe.dart)
does that, 48 single-glyph paragraphs with 8 warm-up passes discarded.

One single-glyph `TextPainter.layout` costs **416 us** with a bare
`TextStyle(fontSize: 12)` and **759 us** with the style a `Text` in a Material
app actually receives. Against ~260 us of engine time and ~950 us at the widget
level, that places roughly 500 us in Dart and ~190 us in widget and
render-object inflation.

Then the field bisect, one field at a time onto the bare style:

| style | us | delta |
|---|---|---|
| bare `TextStyle(fontSize: 12)` | 416 | — |
| `+fontWeight: w400` | 409 | **0** |
| `+letterSpacing: 0.25` | 766 | +350 |
| `+color` | 770 | +354 |
| `+height: 1.43` | 774 | +358 |
| `+fontFamily: 'Roboto'` | 813 | +397 |
| all five | 759 | +343 |

**It is not per-field, it is a step.** Any one field costs the same ~350 us as
all five together, and `fontWeight: w400` — which sets a field to the value it
already had — costs nothing. So the trigger is not "a field was named", it is
"a value differs from the default", and paying it once pays it for everything.

A `TextStyle` that differs from the default at all is therefore **1.8x** one
that does not, and **every `Text` in a Material app is on the expensive side**,
because `DefaultTextStyle` always sets at least a colour and a family.

### The style-block hypothesis, tested and wrong

The shape suggested a second style block: `pushStyle` with a style matching the
paragraph default leaving one run where anything else creates two. Driving
`dart:ui` directly, varying the paragraph style and the pushed style
independently:

| variant | us |
|---|---|
| `nopush` — paragraph style only, no `pushStyle` | 698 |
| `pushempty` — an empty `ui.TextStyle` pushed | 413 |
| `pushsame` — pushed style matching the paragraph style | 417 |
| `pushdiff` — same plus `height: 1.43` | 770 |

Not the block. Pushing *nothing* is the expensive case and pushing an empty
style is the cheap one, which is the opposite of what the hypothesis predicted.

### Where it actually is, and where it is not

`getParagraphStyle` and `getTextStyle` are public on `TextStyle`, so
TextPainter's sequence can be reproduced call by call. Cumulative passes, each
doing strictly more than the last:

| through | bare | +height |
|---|---|---|
| `getParagraphStyle` | 2 | 2 |
| `+ getTextStyle` | 4 | 3 |
| `+ builder, pushStyle, addText, build` | 305 | 305 |
| `+ layout` | 756 | 753 |

**The Dart style encoding is free** — 4 us of a 950 us widget. That retracts the
"~500 us is Dart above dart:ui" in the section above, which was inferred rather
than measured. The cost is `ParagraphBuilder.build` (~300 us) and
`Paragraph.layout` (~450 us), both of which are `dart:ui` calling the engine.

It also leaves a sharper question than the one it answered. Hand-rolled, **bare
and themed cost the same** — 756 and 753. Through `TextPainter` they do not:
418 and 766. So the ~350 us step is not a penalty the themed style pays; it is
a **discount the bare style gets, and only through TextPainter**. 766 is simply
what a paragraph costs, and something in the framework's bare path is half
that.

Whatever that path is, it is a 2x win that already exists and is already
reachable. Finding what triggers it is the open question. It is worth finding:
every `Text` in a Material app is on the wrong side of it.

An instrument note, because it nearly produced a wrong answer. The first
version of this bisect put four `Stopwatch`es inside the loop and reported
719 us for a sequence `TextPainter` completes in 410 — a decomposition larger
than the thing it decomposes, which is the tell that the instrument is in the
measurement. A `Stopwatch` start/stop pair costs 3 us here and there were eight
per iteration; the rewrite uses one stopwatch per cumulative pass.

## Revisit trigger

- **A scene goes red and nobody can act on it.** Then decision 4 or 5 is not
  carrying enough information and the report needs the cause, not the symptom.
- **The suite is green while the console still feels slow.** Decision 1's
  accepted cost has come due, and the scene list is the thing to fix.
- **The baseline is updated more often than it catches anything.** Then the
  10% margin in decision 8 is under the noise floor and should widen, or the
  run should average more repeats.

## Related

- [ADR-0014](0014-gpu-backend-via-vitagl.md) — the GPU path, and the numbers this exists to stop retracting
- [ADR-0015](0015-four-products-one-audience.md) — the four products the gallery is one of
- [ADR-0006](0006-performance-bar-set-from-measurement.md) — the performance bar this measures against
