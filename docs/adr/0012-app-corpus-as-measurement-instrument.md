# ADR-0012: The app corpus is an instrument, and its output is a diff

**Status:** Accepted
**Date:** 2026-08-18

## Context

The [conformance app](../../apps/conformance) reports 45 probes, 45 pass. That
number is worth exactly as much as the imagination of the people who wrote it,
and those are the same people who wrote the engine. It cannot find a capability
nobody thought to probe.

Real third-party apps can, because nobody wrote them with this port in mind.
[The plugin survey](../../tools/plugin-survey/) already tells us which *packages*
real apps depend on. It cannot tell us what breaks behind the packages: fonts,
`intl`, asset bundle size, memory at 512 MB, scroll performance at ~12 fps,
isolates, the emutls table under a real thread load. Those only appear when
something large actually runs.

Three facts about this port shaped how the corpus had to be built, and two of
them were discovered by checking rather than assumed.

**Nothing here can run an app unmodified.** ADR-0009's non-endorsed mechanism
requires the app to call `PathProviderVita.registerWith()` in its own `main()`.
That is an app edit, so "unmodified" was never on the table for anything using
`path_provider`, and pass/fail is therefore the wrong output.

**Most real apps do reach the first frame.** The working assumption was that
they would die in `main()` on a `MissingPluginException` before `runApp` and
leave a black screen. Checked against five apps' actual `main()`: four call
`runApp` with nothing awaited before it, and the fifth wraps its one `await` in
a `try/catch` that renders an error screen. So the common case is a **running
app that fails visibly**, not a dead one — which makes observation far more
informative than the assumption predicted.

**Every new title id costs one manual VitaShell install**, because
`ScePromoterUtil` will not load for us. Five apps at five title ids would have
reintroduced by hand exactly the human step ADR-0011 removed.

> **Corrected 2026-08-31.** The promoter loads once PAF is loaded first, so a
> new title id costs nothing manual. This constraint no longer applies. The
> decision below still stands on its own merits — one app per axis, overlap
> rejected on sight, is about what the corpus measures, not about how many
> title ids we could afford — but "we cannot" was never true, and a future
> reader should not take the number five as forced. See
> [`spikes/promoter`](../../spikes/promoter/).

## Decision

**Five apps, one per axis**, pinned by commit in
[`apps/corpus/manifest.txt`](../../apps/corpus/manifest.txt): a plugin-free
control, animation-and-assets, storage-and-dependency-breadth, networking, and
remote-content-with-codegen. Overlap is rejected on sight — two apps that fail
the same way cost two deploys and teach one lesson.

**Real names, in the manifest and in commits.** Considered anonymising them as
`app0`…`app4`; rejected, because
[`tools/plugin-survey/apps.txt`](../../tools/plugin-survey/apps.txt) is already
committed and already names three of the five, so the mapping would be one
lookup away — the cost would be real and the privacy would not.

**A control is mandatory.** `material_3_demo` is plugin-free and pure framework.
It is the app that *must* pass. Without it, five failures cannot distinguish
"this port cannot run real apps" from "the corpus harness is broken", and the
whole exercise reports a number it has not earned.

**Boot and observe, not push-to-usable.** Build, deploy, screenshot, record the
first thing that breaks in the running app. Depth on a single app is a separate
decision to be taken *after* the breadth pass says which app deserves it.

**One title id, `FVTA00002`**, shared by all five and swapped in place by the
existing receiver path. A title id buys a separate LiveArea bubble and nothing
else, and the corpus does not need five bubbles. `FVTA00002` specifically
because it is **already registered** with the shell, so the corpus needs no new
title and never has to touch the installed-titles database
([the registration investigation](../results/title-registration-2026-08-18.md)
found that door open, and deliberately left it shut).

**The deliverable is a patch series** under `patches/corpus/`, and
**lines-changed-to-first-frame is the score.** No third-party source enters this
repository; the diff against a pinned upstream commit is a complete and
reproducible description of what had to change.

## Consequences

- The output is one table — app, how far it got, first blocker, lines patched —
  plus a ranked list of engine work items annotated with **how many of the five
  each one unblocks**. That ranking is the artifact that reorders the roadmap,
  and filling the table is the stopping condition. "Check what's missing" has
  none otherwise.
- Patch size is a real number and pass/fail is not. An app that boots after two
  lines and an app that boots after four hundred are both "boots".
- Five apps is not a sample. It is five anecdotes chosen to be maximally
  different from each other, and anything phrased as a percentage of real-world
  apps is unsupported by it. The survey is the instrument for population
  claims; this one is for existence claims.
- The control can fail. If it does, everything stops until it passes, and no
  other result from that run may be quoted.
- Sharing one title id means the corpus cannot have two apps installed at once.
  Comparing two apps means two deploys, which the receiver already makes cheap.

## Revisit trigger

If the breadth pass produces fewer than three actionable engine work items, the
corpus is not earning its deploys and the effort belongs in the survey instead.

If any app needs more than a few hundred patched lines to reach first frame,
that app is measuring our willingness to patch rather than the port, and it
should be dropped the way spotube was ([ADR-0013](0013-ffi-needs-static-linking.md)).

## Related

[ADR-0009](0009-plugins-via-non-endorsed-vita-implementations.md) — why every
corpus app needs at least a two-line edit.
[ADR-0011](0011-crash-recovery-without-taihen.md) — why one title id matters.
[ADR-0013](0013-ffi-needs-static-linking.md) — the admission test.
