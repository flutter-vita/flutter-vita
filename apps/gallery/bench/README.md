# Committed baselines

What `tools/bench-report.py` ratchets against. A run fails when a scene's worst
frame grows by more than **both** 10% and one vsync — see
[ADR-0017](../../../docs/adr/0017-the-gallery-becomes-the-benchmark.md)
decision 8, and the note there on why a flat percentage alone flags a
single-vsync step as a regression.

| file | scenes | taken | tracks the current build? |
|---|---|---|---|
| `gl.json` | 20 | 2026-08-25 | **yes** |
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

## Adding a scene

A scene with no row here is **not graded**. The report says so by name now, but
it used to skip it in silence, and six scenes went ungraded for a day that way.
After adding one:

```bash
./tools/bench.sh --only gl --baseline
```
