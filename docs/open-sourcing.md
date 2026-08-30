# Open-sourcing this repository

What stands between the current tree and a public one, audited on 2026-08-29.
Every claim below was checked against the repository rather than remembered.

The short version: **the hard parts are done and the remaining work is two to
three days**, of which only one item carries real risk.

## What is already in place

| | |
|---|---|
| **Licence** | `LICENSE`, BSD-3-Clause. |
| **Attribution** | `NOTICE` — and it does the unusual thing of explaining *why* it exists: a `.vpk` statically links Flutter, Skia, the Dart runtime, ICU and HarfBuzz into `eboot.bin`, which makes every build a binary distribution of BSD-3 software, so clause 2 travels with it. |
| **Documentation** | 20 documents and 18 ADRs, with [an index](README.md) and an explicit "start here". The reasoning behind decisions is written down, including the ones that turned out wrong — see the corrections in [ADR-0014](adr/0014-gpu-backend-via-vitagl.md). |
| **No secrets** | Audited by grep over every tracked file. The only credential-shaped thing is `patches/corpus/keklist-0001-dotenv-placeholders.patch`, which is explicit dummies with a comment saying the real file is gitignored. Other hits are the word "token" in prose. |
| **Size** | 240 tracked files, 17 MB of history. The ~12 GB vendored engine is gitignored and reconstructed from the patch series. |
| **Reproducible vendoring** | 46 patches across six trees, verified by `tools/apply-patches.sh --verify`, which checks that each file is owned by exactly one patch and that every patch reverses cleanly out of its tree. |
| **Reproducible corpus** | Third-party apps are not vendored. `apps/corpus/manifest.txt` pins each by URL and commit SHA, so a result found in one can be regression-tested by anyone. |
| **Third-party assets** | `assets/fonts/` carries Noto Emoji with its OFL and a README recording where it came from and why it was chosen. |

## What is missing

Ordered by how much each one blocks a stranger.

### 1. There is no root `README.md` — ~1 hour

GitHub's front page would be empty. [`docs/README.md`](README.md) is good and
can seed it, but the root needs its own: what this is, what works today, a
screenshot, the one-paragraph "why", and a pointer into `docs/`.

The [capability table](roadmap-capabilities.md) is the honest answer to "does it
work", and belongs near the top.

### 2. Three tracked paths that should not be — minutes

- `apps/conformance/.flutter-plugins-dependencies` — machine-generated, its own
  first line reads "do not edit or check into version control", and it embeds
  `/Users/<user>/.pub-cache/...`. **This one leaks a home directory.**
- `temp_for_logs/dart.log`, `temp_for_logs/m1.log` — stale logs.

`out/bench/` was a fourth and was fixed on 2026-08-29; benchmark output had been
tracked, so every measurement dirtied the tree.

### 3. No CI — half a day

Nothing proves the patch series still applies to a clean checkout, and that
series is the mechanism the whole project rests on. The cheapest useful job is
`tools/apply-patches.sh --verify`, which needs no VitaSDK and no engine build.

A second job that runs `flutter analyze` over `apps/` and `packages/` is nearly
free. A job that builds the engine is not: ~12 GB and ~30 minutes.

### 4. Cold start has never been validated — ~1 day, and this is the risk

[`dev-environment.md`](dev-environment.md) documents "the installed setup on
this machine". Nobody has built this project from scratch anywhere else, and a
from-scratch build is exactly where undocumented local assumptions surface. Two
turned up on 2026-08-29 alone, in ordinary use:

- `tools/package-engine.sh` honours `${VITASDK:-/usr/local/vitasdk}`, but the
  working install is at `$HOME/vitasdk`. With the default, it silently produced
  an artifact with no engine archive in it.
- `tools/build-vita-app.sh --engine` resolves relative paths against the CMake
  build directory, so a relative argument fails with a CMake error naming a
  file that does exist.

Neither is hard to fix; the point is that they were found by accident, and a
newcomer would meet them on their first hour. The fix is to do the cold start —
ideally in a container, which also produces the Docker image
`dev-environment.md` already contemplates.

### 5. The tree is mid-investigation — current work

Not a blocker in principle. A public project may ship with known open issues,
and the ADRs already document worse. But two are live and unexplained:

- Hinting is off port-wide and `text_slide` regressed 2.31× (216.67 → 500.00 ms
  worst frame). Turning hinting off was justified on emoji evidence and has not
  been justified for text.
- The GL benchmark half stalls at `route_grid_bare`, with the app alive and the
  UI thread idle. Second sighting of a grid wedging layout; the first was
  keklist's emoji picker laying out 533–754 paragraphs in a single pass.

Publishing an unexplained 2.31× regression on the thing every app does is worse
than publishing a documented one.

## The history question, which has a deadline

Untracking `apps/conformance/.flutter-plugins-dependencies` stops the leak going
forward. It does not remove the path from history.

A rewrite (`git filter-repo`) is cheap on a 240-file, 17 MB repository with one
author and no forks. It becomes awkward the moment anyone clones. **Decide
before the first push, not after.**

The same pass is the moment to check whether the author email in commit
metadata is the one intended for a public repository.

## What is deliberately not a blocker

- **The engine build cost.** 12 GB and ~30 minutes is inherent to building
  Flutter, and [`tools/package-engine.sh`](../tools/package-engine.sh) already
  exists so that app developers never pay it — they unpack a 23 MB artifact and
  link against it.
- **`libshacccg.suprx`.** The GPU path needs a user-installed module. The
  homebrew community already depends on it; see [ADR-0014](adr/0014-gpu-backend-via-vitagl.md).
- **Corpus app licences.** The apps are not redistributed. Only patches against
  pinned SHAs are, which is ordinary practice.
- **Incompleteness.** Audio is not started, controls are designed and not built,
  and Bluetooth is blocked by an ADR. [`roadmap-capabilities.md`](roadmap-capabilities.md)
  says so plainly, which is the correct way to ship an unfinished port.

## Exit criteria

1. `README.md` at the root that a stranger can read in two minutes.
2. No generated files, logs, or absolute paths tracked; history decision made
   and executed.
3. CI green on `apply-patches.sh --verify` from a clean checkout.
4. One documented from-scratch build on a machine that has never built this,
   with every step that failed folded back into `dev-environment.md`.
5. No live, unexplained performance regression — either fixed or written up.
