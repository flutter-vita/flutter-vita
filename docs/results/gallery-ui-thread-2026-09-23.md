# The gallery was turning its own clock down

**2026-09-23.** Every scene measured about a third slow from 2026-09-18 to
2026-09-23. The engine was not the cause and neither was Dart. The gallery
undid the embedder's clock at startup, and no report recorded enough to say
so.

## What happened

`vita_embedder.cc` sets 444/222/222/166 when an app starts. That is a decision
with a reason written beside it: the UI thread dominates a frame on this
console, so a third more clock is a third off the part that hurts. Every
Flutter app on this port gets it.

On 2026-09-18 the gallery gained the CONFIGURE tab. Its `main()` calls
`GalleryConfig.apply()` before `runApp`, and the initial record said
`cpuClock: CpuClock.normal`. On this port `normal` does not mean "leave it
alone". It means 333/111. So the gallery spent five days undoing the
embedder's decision in its own first frames, and every measurement after that
was taken on a slower console.

The fix is one word: the initial record says `CpuClock.high`, which is what
the embedder already did.

## The numbers

`alpha_probe` builds one small widget, so its UI time is close to a clock.

| Build | Clock | alpha_probe | fill_lerp | clip_rrect |
|---|---|---|---|---|
| 25 runs, 2026-09-01 to 09-14 | 444 | 0.28–0.30 | 0.69 | 9.5–10.5 |
| the gallery, 2026-09-23 | **333** | 0.60 | 1.00 | 13.47 |
| the gallery, after the fix | 444 | 0.45 | 0.77 | 10.22 |
| `bench_only.dart`, no shell | 444 | 0.29 | 0.69 | 9.77 |

The clock is most of it. `clip_rrect` returns to its two-week band on the
clock alone.

## The shell costs something, and it is small

The last two rows differ only in what the scene is mounted inside, at the same
clock. `bench_only.dart` is one `Stack`: the bench behind an `Offstage`, the
scene in front. `main.dart` adds a strip, a `Divider`, a `Navigator`, a rail
and an `IndexedStack` of eight tabs.

That costs 0.16 ms on `alpha_probe` and 0.08 ms on `fill_lerp`, and it does
not show on `clip_rrect` at all. It is a fixed cost per build, so it matters
only to scenes that build almost nothing. The tabs cannot be unmounted: a
`State` unmounted mid-run cannot make the next `AnimationController`, and
build 30 took the whole suite down that way.

`bench_only.dart` stays in the tree as the instrument that measures this.

## What was ruled out on the way

**The plugin registrant.** Built with `--no-registrant`, so the ten plugin
implementations are not roots of the AOT program: `alpha_probe` still read
0.60. The flag is now part of `build-vita-app.sh`.

**The metric and the window.** `frame_recorder.dart` changed by formatting and
one getter between the two dates, and the runner's `take`, `keep`,
`dropTrailing`, settle and quiet times did not change.

**The repeat counts.** Route scenes went from eight repeats to three today and
driven scenes from four to three. `alpha_probe`, `fill_lerp` and `clip_rrect`
are `AnimatedScene`s: three before, three now.

**The strip, and offstage animation.** A frozen `VitaStrip` registers no
callbacks at all, and `bench.sh` freezes it. Hidden tabs sit inside
`TickerMode(enabled: i == _tab)`.

**`list_churn` was never a regression.** Its UI time moves between 96 and
217 ms across the stored runs. It read 150 today. It was called a regression
first, and that was wrong.

## Why it took an afternoon

I tested the clock early and cleared it, wrongly. Setting 444 by hand through
the CONFIGURE tab worked, and then `bench.sh` restarted the app, and
`GalleryConfig.apply()` put it back to 333. The report said 333, which was
true, and I read it as "the clock is not the variable".

Two fields now carry what was missing. Each report records `clocks`, and the
gate refuses to compare two runs that disagree about them, exactly as it
refuses two runs with different `method` ids. Either one alone would have
turned five days of wrong numbers into one red line.

## What is left

The software baseline. `sw.json` was taken at 333 before the fix, so it is
deleted. `gl.json` is correct: 36 scenes at 444/222, method `b34de93c`,
engine `ff08f75c`. Take the software side when the console is charged, and
take it in the same sitting as a fresh GL run if the pair is going to be used
for the renderer ratio.
