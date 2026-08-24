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
