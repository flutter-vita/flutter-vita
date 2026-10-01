# ADR-0022: The bench gate grades each scene inside its own measured spread

**Status:** Accepted. Supersedes decision 8 of [ADR-0017](0017-the-gallery-becomes-the-benchmark.md).
**Date:** 2026-10-01. Three repetitions per scene, and noisy scenes not
graded, were decided on 2026-09-24.

## Context

ADR-0017 decision 8 failed a run when a scene's worst frame grew by more than
10% (later: 10% and one vsync), or its raster or stall by more than 25%. Three
runs on 2026-09-24, two of them on the same code, showed that the gate could
not hold still. Across the 31 scenes all three produced, the run-to-run spread
was:

| metric | median | p90 | max |
|---|---|---|---|
| build (UI thread) | 1.0% | 8.3% | 14.3% |
| raster | 9.2% | 67.4% | 77.8% |
| worst frame | 0.0% | 80.0% | 83.3% |
| stall | 36.6% | 100% | 100% |

15 scenes moved more than 10% on worst frame between runs of the same code, 12
more than 25% on raster, and 9 more than 25% on stall. Two regressions were
almost reported that the layer did not cause, and the A/B in the same sitting
was the only thing that caught them.

Four faults in the measurement made it worse, and were found while fixing it:

1. **The engine reports frame timings about thirty frames late.** A boundary
   read off the recorder when a repetition returned sat inside that
   repetition. Repetition 1 of `fill_lerp` came out 25 frames long against 60,
   and the last repetition of `alpha_probe` 121.
2. **Animated scenes had no warm-up round.** Repetition 1 of `alpha_probe`
   rastered in 12.9 ms against 1.4 for repetitions 2 and 3.
3. **The warm-up round of route scenes was not drained.** Repetition 1 of
   `route_grid_bare` rastered in 8.5 ms against 1.9 and 2.1.
4. **Some scenes change between launches, not within one.** `route_push`
   rastered at about 4.5 ms in one launch and 13 ms in the next, with the
   repetitions of each launch close together.

## Decision

1. **Each repetition is measured on its own.** Its window is cut in frames the
   app produced (`FrameRecorder.produced`), not in timings received, and the
   flush after it waits until those timings arrive. The scene's own numbers
   come from its repetitions joined together.
2. **Every scene runs one untimed round first,** then drains and stays quiet
   for 500 ms before the first measured repetition.
3. **Three metrics are graded:** the median frame period, the median build
   time and the median raster time. Each is the median across the scene's
   repetitions, compared with the same median from the baseline.
4. **The band is the scene's own.** A metric fails when it is outside
   `max(spread now, spread in the baseline)`, never tighter than 10%, and
   larger than its absolute floor: 1 ms for the period, 0.5 ms for build,
   1 ms for raster. The spread is `(max - min) / max(median, floor)`.
5. **A metric whose repetitions spread more than 35% is not graded.** The
   report lists it with its spread. Three samples cannot tell a ramp from
   noise, and a band drawn from a ramp does not contain the next run.
6. **Worst frame and stall are printed and never graded.** A maximum quantised
   to whole vsyncs and a count of rare events cannot resolve a change.
7. **A window too short to measure** (under 1200 ms or 5 frames) is listed and
   not graded. It does not fail the run.
8. **The baseline covers three launches:** one `tools/bench.sh --baseline`,
   then two `--baseline-add`. The baseline keeps the newest 12 repetitions per
   scene, and refuses to add a run with another method, engine or clocks.
9. **The method id carries a measurement version** (`v2`), so a result from
   before this record is refused as another method.

## Evidence

The same gallery binary, built with the tools' own Flutter, on 2026-10-01:

| comparison | regressions |
|---|---|
| run 1 against the baseline of 2026-09-25 (another day, another build) | 0 |
| run 2 against run 1 (a baseline of one launch) | 0. The exit code was 1 only because of two short windows; decision 7 |
| run 3 against run 1 | 1: `route_push` raster 4.4 to 12.8 ms (+191%, band 34%); decision 8 |
| run 4 against runs 1 and 3 (two launches) | 0. `route_push` raster listed, spread 118% |

With runs 1, 3 and 4 as the baseline, 88 of the 108 graded metrics are
measurable. 20 are not: 18 of them raster, mostly on route scenes and on scenes
whose raster is near 1 ms, one median (`scroll_fling`) and one build
(`route_grid_bare`).

## Consequences

- **A raster change on 18 scenes goes unseen by the gate.** For those scenes,
  the method stays an A/B of the old and the new build in the same sitting.
  The report names them on every run, so the gap is visible.
- **A run takes longer:** about 4 min 15 s for the 36 scenes, against about
  2 min 45 s before. The warm-up rounds and the flush after each repetition cost it.
- **A baseline takes three runs,** about 15 minutes on the console.
- **Every stored result from before `v2` is refused.** The first run after this
  record needs a new baseline.
- **A green run means something.** In the evidence above, unchanged code
  passed three comparisons of four, one of them against a baseline from six
  days earlier. The fourth is the case that decision 8 now covers.

## Revisit trigger

- **Unchanged code fails the gate again.** Then three launches are not enough
  to cover the scene, and the baseline needs more launches or the metric needs
  a wider limit.
- **An A/B finds a real regression in a metric the gate does not grade.** Then
  three repetitions are too few for that scene, and decision 3 of 2026-09-24
  ("keep three") is the thing to reopen.
- **Raster on route scenes stops jumping between launches.** Then the
  not-graded list gets shorter on its own, and nothing needs to change.

## Related

- [ADR-0017](0017-the-gallery-becomes-the-benchmark.md): the benchmark, whose decision 8 this replaces
- `tools/bench-report.py`: `GRADED`, `MIN_BAND`, `MAX_GRADEABLE_SPREAD`, `merge_into_baseline`
- `samples/gallery/lib/bench/runner.dart`: `_repeat`, the warm-up rounds, `_measurementVersion`
