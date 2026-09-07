# ADR-0009: `pubspec.yaml` is the opt-in surface — build config and non-endorsed plugin implementations

**Status:** Accepted
**Date:** 2026-08-14

## Context

The goal as refined on 2026-08-14: a developer takes their existing app, adds
Vita metadata to `pubspec.yaml`, optionally depends on `psvita`, and runs it.
Not "unmodified" — a deliberate, small, declared opt-in.

That leaves an unanswered question the opt-in does not by itself solve. A
federated plugin with no Vita implementation throws `MissingPluginException` at
its first call, so an app depending on one does not run regardless of how it
opted in. Nobody had measured how often that happens.

## The measurement

`tools/plugin-survey` resolves each app's full transitive dependency tree
through pub.dev and counts packages whose pubspec declares `flutter.plugin` —
the same signal the Flutter tool uses to decide a package needs native
registration, so the definition rather than a proxy for it. 26 real apps, from
Google's own samples through to Immich, AppFlowy, Spotube and Ente.

```
CLEAN      5 / 26   (19%)  — no plugin anywhere in the tree
BLOCKED   21 / 26

Greedy cover — apps reachable after implementing each, in order:
  1. path_provider        →  10/26  (38%)
  2. url_launcher         →  12/26  (46%)
  3. shared_preferences   →  13/26  (50%)
  4..12  (nine more)      →  14/26  (54%)
```

**Three plugins move the reachable fraction from 19% to 50%. The next nine buy
one app.** A sharp knee and a long, worthless tail.

Two properties of the measurement worth keeping in view. The sample skews
toward findable, popular, polished apps, which use *more* plugins than average
— so 19% is pessimistic, not typical. And federated families are collapsed:
`path_provider_windows` is not a thing we would write, it is another platform's
implementation sitting inert in the tree. An earlier run that failed to collapse
them inflated the blocker list roughly sixfold and ranked `url_launcher_ios` as
work we had to do.

## Decision

**`pubspec.yaml` is the single opt-in surface**, for two distinct things.

### 1. Build configuration

A `vita:` block carrying title ID, display name, LiveArea asset paths, and
orientation. This replaces the hard-coded `FVTA00002` in
[`tools/build-vita-app.sh`](../../tools/build-vita-app.sh), under which any two
flutter-vita apps installed on one device overwrite each other — a bug that only
becomes visible with more than one user, which is to say exactly when it is
most expensive.

Configuration that belongs to the app belongs in the app, not in CLI flags the
developer has to remember and cannot commit.

### 2. Non-endorsed Vita plugin implementations

Ship `path_provider_vita`, `url_launcher_vita`, and `shared_preferences_vita`.
Stop there — the data says the fourth through twelfth are worth one app between
them.

These are **non-endorsed federated implementations**: the developer adds them
to `pubspec.yaml` alongside the plugin they implement. That is not a workaround.
It is the mechanism Flutter provides for exactly this case — a platform the
plugin's author does not know about — and it is what Samsung ships for Tizen:

> "This package is not an *endorsed* implementation of `camera`. Therefore, you
> have to include `camera_tizen` alongside `camera` as dependencies in your
> `pubspec.yaml` file."
> — [camera_tizen](https://pub.dev/packages/camera_tizen)

It also fits the opt-in model exactly. The developer is already editing
`pubspec.yaml`; adding `path_provider_vita: ^0.1.0` is the same edit, not a new
kind of demand.

All three are shallow on Vita: `sceIo` paths for `path_provider`, a JSON file
under `ux0:data/` for `shared_preferences`, and a `url_launcher` that can fail
honestly, since the Vita's browser is not reliably reachable from a homebrew
title.

## Consequences

- **Half of real apps remain unreachable, and we say so.** The survey is
  committed and rerunnable; the number is published rather than estimated.
- Endorsement would remove the extra dependency line, but requires a PR to each
  upstream plugin adding `vita:` to its platforms map. Not attempted — Samsung
  did not get it either, on a far better-resourced platform.
- The pinned set is a maintenance commitment. Three packages tracking three
  upstreams across Flutter releases, on top of the engine artifact.
- Title IDs need an allocation story once more than one app exists. Deriving one
  from a hash of the package name is deterministic, collision-unlikely, and
  never asks the developer to pick — but it is not decided here.
- `tools/plugin-survey` is committed as a tool, not a one-off: the number moves
  as the ecosystem does, and the greedy cover should be re-derived before any
  future decision to extend the pinned set.

## Revisit trigger

Re-run the survey and extend the set if the knee moves — if some fourth plugin
starts appearing in a third or more of blocked apps. Nine implementations for
one app is never the right trade; three for a 31-point jump is.

## Related

- [ADR-0004](0004-static-single-binary.md) — why a general plugin system is hard here
- [ADR-0008](0008-app-visible-platform-identity.md) — the same opt-in model, applied to platform identity
