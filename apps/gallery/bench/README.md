# Committed baselines

What `tools/bench-report.py` ratchets against. A run fails when a scene's worst
frame grows by more than **both** 10% and one vsync — see
[ADR-0017](../../../docs/adr/0017-the-gallery-becomes-the-benchmark.md)
decision 8, and the note there on why a flat percentage alone flags a
single-vsync step as a regression.

| file | scenes | taken | tracks the current build? |
|---|---|---|---|
| `gl.json` | 18 | 2026-08-25 | **yes** |
| `sw.json` | 14 | 2026-08-24 | **no — frozen, see below** |

## sw.json is frozen on purpose

Software rendering became opt-in on 2026-08-24
([ADR-0014](../../../docs/adr/0014-gpu-backend-via-vitagl.md)): the GPU wins
every scene, by 17–20× on the route transitions. Nothing is being optimised on
the software path, and a full software run costs about two and a half minutes
of console time per invocation.

So it is not re-taken every time the engine changes, and **it does not describe
the current binary**. It is kept because the software/GPU comparison in ADR-0017
was drawn from it and the two sides of that comparison have to come from the
same build to mean anything.

Re-take it — both sides, in one sitting — before making any new claim about the
ratio between the renderers. Do not compare a fresh GL run against this file.

## Which numbers are steady, and which are not

Worth knowing before reading a single run as a result. Across six consecutive
runs of the same binary:

- **The text pair does not move.** `route_text_uniq` sits at 46–47 ms and
  `route_spans` at 4.8. That ~10x gap is the most reproducible thing in the
  suite.
- **Some route scenes are bimodal, and no single number describes them.**
  `route_wrap`'s eight pushes on one run: **27.2 27.0 26.7 | 16.5 14.8 14.6
  14.5 14.4**. Three cost 27 ms and five cost 14.5, so a median lands between
  the modes and reports neither. The heavy frames sit at 144, 223 and 300 of
  300 — spaced about two repeats apart.

  The leading explanation is **Dart GC landing on a build frame**: the cost
  scales with how much a scene allocates. `route_push` builds the most and
  throws the largest outliers (110.6 and 85.7 over a tight cluster at 51);
  `route_grid_bare` builds the fewest and is flat at 5.8. **This is a
  hypothesis — nothing has measured a collection.** The port has no VM service.

  So read `bad bld` as a summary and use `--frames <scene>` when it matters;
  that prints the whole heavy-build distribution, which is where bimodality is
  visible and a median is not.
- **`bad bld` ranks by build time, not by frame period.** Ranking by period was
  blind to any build that fits inside a frame — a 10 ms build produces no long
  period — so it reported idle frames for `route_wrap` and `route_spans` and
  understated both by 8x. Changed 2026-08-25.

Which is why the gate compares worst-frame with a 10%-and-one-vsync margin
rather than comparing `bad bld` directly. It is the coarser statistic and the
steadier one.

## Adding a scene

A scene with no row here is **not graded**. The report says so by name now, but
it used to skip it in silence, and six scenes went ungraded for a day that way.
After adding one:

```bash
./tools/bench.sh --only gl --baseline
```
