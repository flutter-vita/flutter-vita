# The profiler we do not have

**Status: not started. This is a task specification, not a report.**

Three separate investigations stopped on 2026-08-25 at the same wall, and it is
the same wall: there is no way to ask this port where time goes inside a frame.
Everything measured so far has been measured by putting a counter next to the
thing and printing it, which works until the question is "which of the fifty
things inside this call is slow".

## What is blocked on it

| Question | Where it stopped |
|---|---|
| **Why does a `TextStyle` that differs from the default cost 1.8x one that does not?** ~750 us against ~400, and setting a field to the value it already had is free. A ~350 us step on **every `Text` in every Material app**. | [ADR-0017](adr/0017-the-gallery-becomes-the-benchmark.md). Two hypotheses tested and refuted; a third would be another day of guessing |
| **Why are some route scenes bimodal?** `route_wrap` costs 27 ms on three of eight pushes and 14.5 on the other five. Dart GC is the leading explanation because the effect tracks allocation, but **nothing has observed a collection** | [apps/gallery/bench/README.md](../apps/gallery/bench/README.md) |
| **Where does the ~190 us between `TextPainter.layout` and a `Text` widget go?** Widget inflation, element tree, render object — never separated | ADR-0017 |
| **Why does a paragraph in localsend cost 6.9 ms when one in the gallery costs 0.26 ms?** 26x, on a real app, on ordinary-looking text. Font fallback is the leading guess and nothing has tested it | [results/localsend-gl-2026-08-25.md](results/localsend-gl-2026-08-25.md) |

None of the four is exotic. All four are one flame chart away.

## The binary already has half of it

Checked 2026-08-25 against the shipping `flutter_vita_app`, and this is the
finding that reorders everything below.

```
$ arm-vita-eabi-nm flutter_vita_app | grep -ci TimelineEvent
201
$ arm-vita-eabi-nm flutter_vita_app | grep Dart_SetTimelineRecorderCallback
818eb410 T Dart_SetTimelineRecorderCallback
```

**The Dart VM timeline is compiled in and its recorder hook is exported.**
`out/vita_release/args.gn` says `dart_runtime_mode = "release"` — *release*,
not *product*, and Dart keeps `SUPPORT_TIMELINE` in release. The stream names
are in the binary too: `Dart`, `Embedder`, `Isolate`, `Compiler`.

What is *not* there is Flutter's own instrumentation, and for a reason that is
one line long — `fml/trace_event.h:66`:

```c
#if (FLUTTER_RELEASE && !defined(OS_FUCHSIA) && !defined(FML_OS_ANDROID))
#define FLUTTER_TIMELINE_ENABLED 0
```

Vita is neither Fuchsia nor Android, so every `TRACE_EVENT` in the engine —
`Frame`, `Build`, `Layout`, `Paint`, `Rasterize` — compiles to nothing.

So this is not one project. It is four, in increasing cost, and the first two
do not need a second engine build at all.

## Tier 1 — the Dart timeline, no sockets, no service isolate

**Cost: hours. Risk: low. Answers the GC question outright.**

`Dart_SetTimelineRecorderCallback` hands the embedder every timeline event as
it is recorded. Write them to a file; pull the file with the dev server's `get`;
convert to Chrome trace JSON on the host; open in [Perfetto](https://ui.perfetto.dev).
No VM service, no DDS, no DevTools connection, no listening port — which
matters, because every one of those is a thing that can fail to build here.

Two pieces of work:

1. **Plumb VM flags.** The embedder never sets
   `FlutterProjectArgs.command_line_argv` today — `grep command_line_arg
   vita_embedder.cc` finds nothing. It needs
   `--timeline_streams=Dart,GC,Embedder,Isolate` and whatever recorder flag
   selects the callback. Behind a switch file, like every other dev toggle
   here, so a shipping build pays nothing.
2. **Register the callback and write.** Same shape as `vgl_oom_count` and the
   `PARAGRAPHS` line: accumulate, then hand it to the host. Events are
   frequent, so this wants a ring buffer and a size cap, not a `sceIoWrite`
   per event.

**The `GC` stream is the whole point.** The bimodality question — three of
eight pushes at 27 ms, five at 14.5 — has "Dart GC landed on a build frame" as
its leading hypothesis and *no observation at all* behind it. A GC stream turns
that into a yes or a no in one run.

## Tier 2 — Flutter's own spans, one line

**Cost: a line plus a rebuild. Risk: low. Answers the widget-inflation
question.**

Exclude Vita from the compile-out at `fml/trace_event.h:66`, or set
`flutter_runtime_mode = "profile"`, and `Frame`, `Build`, `Layout`, `Paint` and
`Rasterize` spans appear on the same timeline Tier 1 is already collecting.

That is what splits a 46 ms `route_text_uniq` build frame into its parts —
where hand-rolled `Stopwatch`es failed twice, once by putting eight clock reads
in the loop and once by measuring position in a sequence rather than cost.

**Do not make it the default.** The macros cost real time in a shipping build,
and this project has already published numbers taken from an instrument that
perturbed its subject. A separate output directory, or a build flag, and the
benchmark keeps running against the uninstrumented one.

## Tier 3 — profile mode and a real CPU profiler

**Cost: a second 30-minute engine build and ~12 GB. Risk: unknown. Answers the
two "which function" questions.**

Tiers 1 and 2 give *spans* — they say a phase took 46 ms, and they can only
name phases somebody instrumented. Neither can say which function inside
`Paragraph::Layout` is the 350 us, and that is precisely what the two best
questions need:

- the `TextStyle` step: ~350 us on **every `Text` in every Material app**
- localsend's paragraphs: **6.9 ms each against the gallery's 0.26**

Those need a sampling profiler, which needs the VM service, which needs
`flutter_runtime_mode = "profile"` in an `out/vita_profile` alongside the
release build.

Where it will fail if it fails: **the patch series has only ever been applied
to a release build.** Profile mode pulls in the service isolate, the VM service
and DDS, none of which have been compiled for this platform.
[docs/m2-undefined-symbols.txt](m2-undefined-symbols.txt) is what that kind of
failure looked like the last time, and it is a long file.

If it does build: the VM service is a TCP server, this port has working sockets
and `dart:io` (localsend does real networking on it), and the host is a Mac on
the same LAN. Bind `0.0.0.0`, not localhost, and connect with
`dart devtools --vm-uri=ws://<vita-ip>:<port>/ws`.

## Tier 4 — the fallback, if profile mode will not build

A thread that wakes on a timer, reads the UI thread's PC, and appends it to a
buffer the dev server can `get`. Symbolicate on the host against the unstripped
ELF — [spikes/m1-vpk/analyse-crash.sh](../spikes/m1-vpk/analyse-crash.sh)
already does exactly that for crash dumps, so half of it exists.

Crude, and it answers both Tier 3 questions anyway, because both are "which
function is this time in".

## Which tier answers which question

| Question | Tier | Why that tier |
|---|---|---|
| Bimodal route scenes — is it GC? | **1** | The `GC` stream is a direct observation, not an inference |
| The ~190 us between `TextPainter.layout` and a `Text` widget | **2** | `Build` and `Layout` spans split it without new instrumentation |
| The 350 us `TextStyle` step | **3** or 4 | Needs function-level attribution inside Skia |
| localsend at 6.9 ms per paragraph | **3** or 4 | Same, and font fallback is a call chain not a phase |

**Start at Tier 1.** It is the cheapest, it answers a live question completely,
and it builds the plumbing — VM flags, a trace file, a host-side converter —
that every tier above it also needs.

## What this is not

- **Not taiHEN.** The user's constraint stands: no kernel plugins, no
  `config.txt`, nothing in SceShell. The VM service is in-process, so it does
  not need any of that.
- **Not a replacement for the counters.** `vgl_oom_count`, the `PARAGRAPHS`
  line and the frame recorder all measure a shipping release build. A profile
  build measures a different binary and its absolute numbers will not match.
  Use it to find *where*, then confirm *how much* with a counter in release.
- **Not free at Tier 3.** A second engine build is roughly 30 minutes and
  another 12 GB, and a second artifact to keep in step with the release one.
  [tools/pin-receiver-engine.sh](../tools/pin-receiver-engine.sh) exists
  because keeping *one* engine artifact honest already needed a mechanism.
  Tiers 1 and 2 avoid this entirely.
- **Not a thing to leave on.** Tier 2's macros cost time in the build that
  carries them, so the benchmark must keep running against an uninstrumented
  binary. An instrument inside the measurement is how this project got the
  45-versus-60 fps retraction on 2026-08-22 and two more this week.

## The honest argument against doing this at all

The actionable conclusions did not need it. "A screen costs roughly its `Text`
count times a millisecond" and "use one `RichText` instead of forty `Text`s"
are both measured, both correct, and both usable today. A profiler explains
*why* those are true. It does not change what an app should do.

So the reason to build it is not the four open questions. It is that the next
performance question will hit the same wall, and the one after that, and the
project has now spent two sessions placing counters by hand to answer things a
flame chart shows in a second.
