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

- **The text pair does not move.** `route_text_uniq` sits at 45–47 ms and
  `route_spans` at 1.2. That 38x gap is the most reproducible thing in the
  suite.
- **The grid and wrap scenes move a lot.** `route_boxes` has read 11.6 and
  29.4 on the same build; `route_wrap` has read 1.2 and 6.1. Treat a single
  reading of those as an order of magnitude, not a number.

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
