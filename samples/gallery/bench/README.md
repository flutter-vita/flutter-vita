# Committed baselines

What `tools/bench-report.py` ratchets against. A run fails when a scene's worst
frame grows by more than **both** 10% and one vsync — see
[ADR-0017](../../../docs/adr/0017-the-gallery-becomes-the-benchmark.md)
decision 8, and the note there on why a flat percentage alone flags a
single-vsync step as a regression.

**There is no baseline right now.** `gl.json` and `sw.json` were deleted on
2026-09-23. Write new ones with `./tools/bench.sh --baseline`, both renderers
in one sitting.

## A baseline belongs to one method

Every report carries a `method` field: eight hex characters over each scene's
name, repeat count and duration, which the app computes from the scene list
itself. The gate compares two runs only when the field agrees, and says
"the baseline measured a different suite" when it does not.

The rule exists because on 2026-09-23 the route scenes went from eight repeats
to three and the driven scenes from four to three. Every stored result still
looked comparable, and one of them was read as a 30% regression for most of an
afternoon. A repeat count, a duration, a settle, an added scene or a removed
one all change what a number means.

So: **change the suite, delete the baseline, take a new one.** A baseline from
another method is not a conservative baseline, it is a wrong one. The files
deleted on 2026-09-23 were taken on 2026-08-25 and 2026-08-24, before the
suite grew from 18 scenes to 36 and before the renderer became our own GLES2,
and the gate had been reporting against them for a month.

`method` does not cover the recorder or the engine. A change there moves the
numbers without touching a scene; the `engine` stamp and `clocks` in the same
header are what cover those.

## sw.json was frozen on purpose

Software rendering became opt-in on 2026-08-24
([ADR-0014](../../../docs/adr/0014-gpu-backend-via-vitagl.md)): the GPU wins
every scene, by 17–20× on the route transitions. Nothing is being optimised on
the software path, and a full software run costs about two and a half minutes
of console time per invocation.

It was not re-taken when the engine changed, so it did not describe the
current binary. It was kept because the software/GPU comparison in ADR-0017 was
drawn from it, and the two sides of that comparison have to come from the same
build to mean anything.

That is still the rule for whatever replaces it: take both sides in one
sitting, before making any claim about the ratio between the renderers.

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
  300 — spaced about two repeats apart. (Eight pushes: that was the route
  scenes' repeat count until 2026-09-23. They repeat three times now, which is
  why those numbers belong to a different `method`.)

  The leading explanation used to be **Dart GC landing on a build frame**: the
  cost scales with how much a scene allocates. On 2026-09-01 a better one
  turned up -- the heap filling underneath the run. `ZoomPageTransitionsBuilder`
  is Material's default for `TargetPlatform.linux`, which is what this port
  reports, and after the first nine push-and-pop cycles it grows the native heap
  4-6 MB per cycle and never gives it back; `route_wrap` and `route_spans`
  between them reached the 159 MB ceiling in twelve seconds. `route_wrap` was
  scene 12 of 18 in the order these numbers were taken in, which puts it just
  past the threshold. See
  [page-transitions-2026-09-01.md](../../../docs/results/page-transitions-2026-09-01.md).

  The original wording follows, because the reasoning still applies to whatever
  is left after the leak is accounted for. `route_push` builds the most and
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

## What the suite covers, since 2026-09-01

Six groups, and the boundary between them is how the runner drives them, not
what they look like.

| group | scenes | driven by |
|---|---|---|
| animated | `fill_lerp` … `list_churn` | an AnimationController from 0 to 1 and back |
| motion | `switch_fade`, `layout_resize`, `text_resize`, `shader_mask`, `spinner` | the same, added 2026-09-01 |
| driven | `drawer_open`, `page_swipe`, `scroll_fling`, `ripple_tap` | calling something and waiting |
| route | `route_bare` … `route_hero` | `Navigator.push` of a `MaterialPageRoute` |
| transition | `route_tx_none`, `route_tx_zoom`, `route_tx_fade_fwd`, `route_tx_fade_up`, `route_tx_cupertino` | the same push, one page, five transitions |
| modal | `modal_dialog`, `modal_sheet` | a `DialogRoute` and a `ModalBottomSheetRoute` |

### Why the transition group exists

This port reports `TargetPlatform.linux` (ADR-0008), and Material's default
transition for Linux is `ZoomPageTransitionsBuilder`. So every `route_*` number
this project has ever published is a Zoom number that nobody chose, with the
transition and the page's first build mixed together and no way to separate
them.

The five transition scenes push **the same page** — the shape of
`route_boxes`, which already has history — through five different builders.
`route_tx_none` has no transition at all, which makes the page's build cost a
measured quantity rather than a guess, and the other four are that plus one
animation each.

### Why `scroll_fling` is not another list scene

`list_churn` drives a `ScrollController` along a curve the bench picked.
`scroll_fling` calls `goBallistic`, so the frame rate is whatever the platform
scroll simulation asks for, and it overscrolls at the end — the only thing in
the suite that reaches the stretch effect. It is the gesture behind the
standing complaint that scrolling holds 29 fps with the raster thread at 8%.

`ripple_tap` likewise uses synthetic pointer events rather than calling
`onTap`, because `onTap` produces no splash and the splash is the point. Hit
testing and the gesture arena are inside its window as a result.

## Adding a scene

A scene with no row here is **not graded**. The report says so by name now, but
it used to skip it in silence, and six scenes went ungraded for a day that way.
After adding one:

```bash
./tools/bench.sh --only gl --baseline
```

## Reading the report

`bench-report.py` prints the full table first and then a **what to fix first**
block: the same scenes ranked by `stall` — total time below 30 fps, the metric
that corresponds to something a person felt — with a `where` column naming the
thread the time went to.

`where` is worth more than the ranking. "UI thread" means no renderer change
will help that scene, which on this port has been almost all of them.
"neither" means both threads finished inside 8 ms and the frame was still late;
every scene that lands there has looked like a collection arriving on a build
frame, and nothing has measured one because the port has no VM service.
