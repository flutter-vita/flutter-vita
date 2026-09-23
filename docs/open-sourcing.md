# Open-sourcing this repository

This repository can go public in two to three days of work. One item carries
real risk; the rest is tidying. I checked each claim below against the tree on
2026-08-29 instead of recalling it.

## What is already in place

| | |
|---|---|
| **Licence** | `LICENSE`, BSD-3-Clause. |
| **Attribution** | `NOTICE`, which explains why it exists: a `.vpk` links Flutter, Skia, the Dart runtime, ICU and HarfBuzz into `eboot.bin` at build time, so every build distributes BSD-3 software and clause 2 travels with it. |
| **Documentation** | 20 documents and 18 ADRs behind [an index](README.md) that names a starting point. Decisions carry their reasoning, including the ones I got wrong. See the corrections in [ADR-0014](adr/0014-gpu-backend-via-vitagl.md). |
| **No secrets** | I grepped every tracked file. One hit is credential-shaped: `samples/test-apps/patches/keklist-0001-dotenv-placeholders.patch`, which holds dummies and says so in a comment. The rest are the word "token" in prose. |
| **Size** | 240 tracked files, 17 MB of history. The 12 GB engine checkout stays gitignored; it is the fork's branch, so a clone rebuilds it. |
| **Reproducible vendoring** | Every change this port makes is a commit in the repository that owns the file: 16 on the engine fork's branch, and one fork for each of the five dependencies that change, named in `DEPS`. There are no patch files. `tools/engine-tree.sh --verify` checks all six. |
| **Reproducible test apps** | Third-party apps stay out of the tree. `apps/test-apps/manifest.txt` pins each one to a URL and a commit SHA, so anyone can regression-test a bug found in it. |
| **Third-party assets** | `assets/fonts/` carries Noto Emoji with its OFL and a README recording where it came from. |

## What is missing

Ordered by how much each one costs the first person who clones this.

### 1. No root `README.md`. About an hour.

GitHub would show an empty front page. [`docs/README.md`](README.md) can seed
the root one: what this is, what runs today, a screenshot, and a way into
`docs/`. Put the [capability table](roadmap-capabilities.md) near the top, since
it answers the first question anyone asks.

### 2. Two tracked paths that should not be. Minutes.

- `temp_for_logs/dart.log` and `temp_for_logs/m1.log`. Stale logs.

Two others are done. `out/bench/` went on 2026-08-29: benchmark output sat in
git, so every measurement left the tree dirty.
`apps/conformance/.flutter-plugins-dependencies` went on 2026-08-30, along with
a second copy that had appeared under `packages/file_picker_vita/` the same
day. Both embedded `/Users/<user>/.pub-cache/...`, so both leaked a home
directory. `.gitignore` now covers the name, which is what stops the third one:
the file appears in any package directory after `flutter pub get`, and `git add`
on that directory picks it up without comment.

### 3. No CI. Half a day.

Nothing proves a clean checkout still carries the port, and the project rests
on it. Start with `tools/engine-tree.sh --verify`,
which needs no VitaSDK and no engine build. Running `flutter analyze` over
`apps/` and `packages/` costs almost nothing on top. Leave the engine build out
of CI at 12 GB and half an hour.

### 4. Nobody has built this from scratch. About a day, and the risk lives here.

[`dev-environment.md`](dev-environment.md) documents the setup on my machine. No
one has built this project from a clean checkout anywhere else, and that first
build is where local assumptions surface. Two surfaced by accident on
2026-08-29, during ordinary work:

- `tools/package-engine.sh` honours `${VITASDK:-/usr/local/vitasdk}`, but the
  working install lives at `$HOME/vitasdk`. Under the default it produced an
  artifact with no engine archive inside and said nothing.
- `tools/build-vita-app.sh --engine` needs an absolute path. CMake resolves a
  relative one against the build directory, then fails naming a file that does
  exist.

Neither takes long to fix. I found both by accident, and you would meet them in
your first hour. Do the cold start in a container, which also produces the
Docker image `dev-environment.md` already contemplates.

### 5. The tree sits mid-investigation. Current work.

This need not block a release. Public projects ship with open issues and the
ADRs already record worse. Two are live and unexplained:

- Hinting is off across the port and `text_slide` regressed 2.31x, from 216.67
  to 500.00 ms on the worst frame. Emoji evidence justified turning hinting off.
  Nothing has justified it for text.
- The GL benchmark half stalls at `route_grid_bare` with the app alive and the
  UI thread idle. That is the second grid to wedge layout. The first was
  keklist's emoji picker, laying out 533 to 754 paragraphs in one pass.

Explain the 2.31x before publishing it.

## The history question, which has a deadline

Untracking `apps/conformance/.flutter-plugins-dependencies` stops the leak. It
leaves the path in history.

`git filter-repo` costs little against 240 files, 17 MB, one author and no
forks. It costs more once somebody clones. Make the call before the first push.
Check the author email in commit metadata during the same pass.

## What does not block a release

- **The engine build cost.** Building Flutter takes 12 GB and half an hour.
  [`tools/package-engine.sh`](../tools/package-engine.sh) already spares app
  developers that: they unpack a 23 MB artifact and link against it.
- **`libshacccg.suprx`.** The GPU path wants a module the user installs. Vita
  homebrew already depends on it. See [ADR-0014](adr/0014-gpu-backend-via-vitagl.md).
- **Test apps licences.** Nothing redistributes those apps. The tree carries
  patches against pinned SHAs, which is ordinary practice.
- **Incompleteness.** Audio has not started, controls are designed and unbuilt,
  and an ADR blocks Bluetooth. [`roadmap-capabilities.md`](roadmap-capabilities.md)
  says all of that outright, which is how an unfinished port should ship.

## Exit criteria

1. A root `README.md` you can read in two minutes.
2. No generated files, logs or absolute paths tracked, and the history decision
   made and carried out.
3. CI green on `engine-tree.sh --verify` from a clean checkout.
4. One documented build from scratch on a machine that has never built this,
   with every failed step folded back into `dev-environment.md`.
5. No live performance regression without an explanation.
