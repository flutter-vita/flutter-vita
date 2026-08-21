# ADR-0015: The toolchain is four products with one audience

**Status:** Accepted — decided by interview, 2026-08-21
**Date:** 2026-08-21

## Context

Every tool in this repo was built for exactly one user, who is also its author.
`deploy.sh` assumes the engine artifact sits at a path relative to the repo
root. The loader installs into a hard-coded title id. The CLI locates its
dependencies by walking up from its own script:

```dart
// bin/ -> flutter_vita/ -> tools/ -> repo
var dir = File.fromUri(Platform.script).parent.parent.parent.parent;
```

None of that is wrong for a port under construction, and it made the port fast.
But it means **the CLI cannot currently be installed anywhere**, because
installed via any package manager there is no repo to walk up to. That is not a
packaging detail to solve later; it is the first thing in the way of anyone
else using this at all, and it was discovered only by asking who "anyone else"
actually is.

This ADR answers that question before the folder layout, because a layout built
on unexamined assumptions is harder to undo than one that does not exist yet.

## Two audiences, and only one of them is ours

| Persona | Wants | Gets from us |
|---|---|---|
| **The Flutter developer** | To build a Vita app | CLI, loader, runtime package, docs |
| **Their users** | To play the finished app | Nothing. A `.vpk` from the developer |

**The product boundary ends at the `.vpk`.** That single line settles several
questions that looked independent:

- The **loader never ships to players**. It exists to make the edit-run loop
  fast — crash recovery, redeploy into a fixed slot, log pulling — and someone
  who rebuilds nothing has no use for it. Its polish bar is "a Flutter
  developer who is not the author can install and run it", which is a real bar
  and a much lower one than a consumer application.
- `flutter-vita build <app> -> .vpk` is therefore **a product surface, not a dev
  convenience**: it emits the handoff artifact. The title-id derivation in
  [phase-4](../phase-4-distribution.md) already treats it that way.
- Documentation for *players* — how to install a `.vpk`, what HENkaku is — is
  the **developer's** responsibility, not ours. We may ship a README template
  for them to pass on, because otherwise every developer writes the same
  instructions badly, but we do not own that audience.

## The four products

| # | Product | Is | Ships as |
|---|---|---|---|
| 1 | **CLI** (`flutter-vita`) | Build, install, run, logs, screenshot, tap | `pub global activate` |
| 2 | **Loader** | On-device receiver: install, launch, log and dump retrieval, crash recovery | `.vpk`, developer-only |
| 3 | **Runtime package** | In-app Dart API — button mapping, suspend/resume, memory pressure | pub.dev, name deferred |
| 4 | **Docs** | Getting Started and API/tool reference | Repo, later a site |

Two clarifications that were live questions until this interview:

**The runtime package is a runtime API, not build configuration.** Build config
already exists and lives in `pubspec.yaml`'s `vita:` block, read by two parsers
and deliberately kept flat. Adding a second way to express the same thing would
be strictly worse than the one that works.

**The loader does not gain an FTP server.** The word "FTP" in the framing of
this interview meant the loader's existing `get`/`put` commands, not a new
service. `loader/src/main.c` says why this matters:

> `// This is what removes BGFTP from the loop entirely.`

That was won, not given. It stands.

## Distribution

**`pub global activate`, on all three host platforms.** The CLI is already
cross-platform Dart; Homebrew was the original proposal and cannot serve
Windows, which is required.

**The engine artifact is fetched on first use, not bundled.** It is 63 MB and
there is one per Flutter revision — bundling would force a CLI release per
Flutter release and a 63 MB download on people who never build.

The artifact splits along a line that turns out to be favourable:

| Part | Size | Host-specific? |
|---|---|---|
| `lib/libflutter_engine_vita.a` | 63 MB | **No** — ARM Vita code, 2940 objects |
| `include/`, `src/`, `data/` | small | No |
| `host-*/gen_snapshot_armv7` | small | **Yes** |

So supporting macOS, Linux and Windows costs a handful of small `gen_snapshot`
binaries per Flutter revision, **not** three copies of the 63 MB archive. The
expensive part of the artifact is target code and is written once.

It also cannot be patched after download. The 26 patches apply to engine
*source* before compiling; the artifact is the output. A Flutter revision the
developer wants is an artifact **we** build — the maintenance cost phase-4
already accepts, restated here because "can it be patched later" is the natural
thing to hope for and the answer is no.

**Published now: `darwin-arm64` and `linux-x64`. Windows later.** The barrier to
Windows is not the artifact — it is that `build-vita-app.sh` and `deploy.sh` are
bash. Moving them into the Dart CLI is deferred until after the first release.

## Layout: folders now, repos later

Only one thing genuinely forces separation, and it is publishing: nobody should
clone a repo carrying six vendored engine trees in `third_party/` in order to
depend on one plugin. Everything else is tidiness, and tidiness is not worth a
repo split while the CLI still reads `VERSIONS.md` and the engine artifact by
relative path.

So: **folders in this repo now, repo splits when something concrete forces
them.** The forcing functions to watch are named in the revisit trigger below.

## Consequences

- **The CLI's `repoRoot` path-walking must go.** It is the blocker on shipping
  the CLI anywhere, independent of channel, and it is now on the critical path
  rather than a cleanup item.
- **The loader graduates out of `spikes/`.** It is a product component with a
  named audience, and leaving it filed as a spike misrepresents what it is.
- **Two documentation audiences, kept apart.** The 14 ADRs and ~20 design docs
  are contributor-facing and stay that way. User docs are Getting Started and
  an API/tool reference — a manual, not an internals treatise.
- **No hot reload, and the loop is not being optimised for now.** ADR-0001
  makes AOT permanent, so `flutter-vita run` is a full build, install and
  launch. The cycle time is unmeasured; the decision is to measure it and
  publish it honestly rather than gate the design on a target. A developer
  choosing this toolchain deserves to know the number before they start.

## Revisit trigger

- **A pub package is ready to publish.** That is the one real forcing function
  for a repo split, and it fires per-package rather than all at once.
- **A second maintainer appears.** Shared ownership makes independent release
  cadences worth their cost; a solo project they are pure overhead.
- **Windows becomes committed rather than intended.** That is when the bash
  scripts have to move into the CLI, and it is a larger change than it looks.
- **The loader is asked to do something a player would need.** That would mean
  the product boundary has moved off the `.vpk`, and this ADR's central claim
  needs re-arguing rather than quietly widening.

## Related

- [ADR-0009](0009-plugins-via-non-endorsed-vita-implementations.md) — why
  configuration lives in the app
- [ADR-0011](0011-crash-recovery-without-taihen.md) — what the loader is for
- [phase-4-distribution.md](../phase-4-distribution.md) — the artifact, the
  `vita:` block, and engine/SDK lockstep
