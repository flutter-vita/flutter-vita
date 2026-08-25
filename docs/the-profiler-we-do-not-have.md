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

None of the three is exotic. All three are one flame chart away.

## Why the usual answer is unavailable, and why that may be wrong

`flutter_runtime_mode = "release"` in `out/vita_release/args.gn`. **Release
mode compiles the VM service out.** No Observatory, no DevTools, no
`dart:developer` timeline, no `Timeline.startSync`, no CPU profiler — which is
why every number in this project comes from a hand-placed counter.

Nothing has actually tested whether **profile mode** builds and runs here. That
is the first thing to try and it is plausibly the whole answer:

- profile mode keeps the VM service and the timeline while staying AOT, so it
  measures something close to what ships
- the VM service is a **TCP server**, and this port already has working
  networking with a dev server on a socket
- DevTools connects to it over that socket from the host, and the host is a
  Mac that already talks to the console constantly

If it works, all three questions above are answered in an afternoon, along with
every future one. If it does not, the reasons will be specific and worth
writing down.

## What to try, in order

**1. Build the engine in profile mode.** A second output directory —
`out/vita_profile` — with `flutter_runtime_mode = "profile"` and
`dart_runtime_mode = "profile"`. Expect the patch series to need work: the
series has only ever been applied to a release build, and profile mode pulls in
`vm_service`, the timeline recorder and the service isolate, none of which have
been compiled for this platform. **This is where it will fail if it fails**,
and the failures will be missing symbols of the kind
[docs/m2-undefined-symbols.txt](m2-undefined-symbols.txt) already catalogues
for another mode.

**2. Get the service isolate listening.** It wants a socket and a port. The
embedder passes `FlutterProjectArgs`; the VM service is configured through Dart
VM flags — `--enable-vm-service=<port>`, `--disable-service-auth-codes` for a
dev port on a LAN. It must bind `0.0.0.0` and not localhost, or the Mac cannot
reach it. Whether the service isolate can start at all depends on whether it
can spawn a thread and open a socket the way `dart:io` already does — both of
which this port has working.

**3. Connect DevTools from the host.** `dart devtools --vm-uri=ws://<vita-ip>:<port>/ws`.
The timeline view is the one that matters; the CPU profiler is the one that
answers the `TextStyle` question.

**4. Re-run the three questions.** They are already reduced to single scenes in
the benchmark: `route_text_uniq` versus `route_spans` for the style step,
`route_wrap` for the bimodality, and any route scene for widget inflation.

## What this is not

- **Not taiHEN.** The user's constraint stands: no kernel plugins, no
  `config.txt`, nothing in SceShell. The VM service is in-process, so it does
  not need any of that.
- **Not a replacement for the counters.** `vgl_oom_count`, the `PARAGRAPHS`
  line and the frame recorder all measure a shipping release build. A profile
  build measures a different binary and its absolute numbers will not match.
  Use it to find *where*, then confirm *how much* with a counter in release.
- **Not free.** Profile mode is a second engine build — roughly 30 minutes and
  another 12 GB — and a second artifact to keep in step with the release one.
  [tools/bless-loader-engine.sh](../tools/bless-loader-engine.sh) exists
  because keeping one engine artifact honest already needed a mechanism.

## The fallback, if profile mode will not build

Sampling by hand: a thread that wakes on a timer, reads the UI thread's PC, and
writes it to a buffer the dev server can `get`. Symbolicate on the host against
the unstripped ELF — [spikes/m1-vpk/analyse-crash.sh](../spikes/m1-vpk/analyse-crash.sh)
already does exactly that for crash dumps, so the symbolication half exists.

Crude, and it would answer all three questions anyway, because all three are
"which function is this 350 us in".

## The honest argument against doing this at all

The actionable conclusions did not need it. "A screen costs roughly its `Text`
count times a millisecond" and "use one `RichText` instead of forty `Text`s"
are both measured, both correct, and both usable today. A profiler explains
*why* those are true. It does not change what an app should do.

So the reason to build it is not the three open questions. It is that the next
performance question will hit the same wall, and the one after that, and the
project has now spent two sessions placing counters by hand to answer things a
flame chart shows in a second.
