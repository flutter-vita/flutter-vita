# The UI thread costs twice what it did, and the engine is not why

**2026-09-23.** Every small scene builds about twice as slowly as it did on
2026-09-14. The engine from the six forks is not the cause. Five candidates
are closed, and the one measurement that decides it needs a console.

## The number

`alpha_probe` builds one small widget, so its UI time is close to a clock.

| When | UI thread | Runs |
|---|---|---|
| 2026-09-01 to 2026-09-14 | 0.28–0.30 ms | 25 |
| the afternoon of 2026-09-13 | 0.42–0.48 ms | 5, an experiment series |
| 2026-09-23 | 0.60, 0.60, 0.61 ms | 3 |

`clip_rrect` says the same: 9.5–10.5 ms in almost every stored run, 13.27 and
13.28 today.

`list_churn` does not. Its UI time moves between 96 and 217 ms across the same
runs and reads 150 today, which is inside its own spread. It was called a
regression first and it is not one.

The reference runs are in `out/bench/before-2026-09-23/`.

## What is closed

**The CPU clock.** `bench.sh` starts the app again before every run, and a new
start is always 333 MHz and 111 MHz. Both runs used those. Setting 444 MHz by
hand does not survive the restart, and the numbers did not move when it was
set. The report now records the clocks, which is how this was settled.

**The repeat counts.** Route scenes went from eight repeats to three today,
and driven scenes from four to three. `alpha_probe`, `fill_lerp` and
`clip_rrect` are `AnimatedScene`s: three repeats before, three now, same
duration. `alpha_probe` also runs first, so nothing before it warms a cache.
The report now carries a `method` id for exactly this class of doubt.

**The metric.** `frame_recorder.dart` changed by formatting and one added
getter between the two dates. `build_ms` means what it meant.

**The measurement window.** The runner's `take`, `keep`, `dropTrailing`,
settle and quiet times are unchanged.

**The strip, and offstage animation.** `bench.sh` writes `hud.off` before
every run, and a frozen `VitaStrip` registers no timings callback, no
persistent frame callback and no timer — it returns from `initState` before
all three. The hidden tabs are inside `TickerMode(enabled: i == _tab)`, so
they do not animate behind a scene.

## What is left

The engine's Dart is byte-identical to 2026-09-14: the eleven Dart changes are
the same, now as commits in `flutter-vita/dart-sdk` instead of patch files. A
Dart build cost cannot come from a Skia change. So the cause is the app, or
how the app is compiled.

The leading candidate is the **generated plugin registrant**. Since 2026-09-18
`build-vita-app.sh` passes `--source` for a generated
`dart_plugin_registrant.dart` and the engine calls it at isolate start, so ten
plugin implementations are now roots of the AOT program. That changes what the
compiler can prove about a call site, and this port is AOT only.

The second is the shell. On 2026-09-14 a running scene owned the screen:
`bench_page.dart` returned `Material(child: stage)` and nothing else. Today
the stage is a `Stack` child under a `Navigator`, a `Divider`, a strip and a
`Column`, with eight tabs still in the tree behind `Offstage`. The tabs have
to stay: unmounting the Scenes tab mid-run took build 30 down with a null
check on `State.context`. A deeper static tree should not cost a rebuild
anything, which is why this is second and not first.

## The measurement that decides it

Build the gallery of 2026-09-14 against today's engine and read `alpha_probe`.
It separates the app from the engine in one run.

That build is not free: the 2026-09-14 tree expects the embedder sources
inside the engine artifact, and today's artifact does not carry them, so the
old tree does not build against it unchanged. The cheaper form of the same
question is to bisect the gallery's own commits between the two dates, which
needs a console and about six builds.
