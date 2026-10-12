# Releasing flutter-vita

This page is for maintainers. It tells you how to publish an engine artifact
and a release of the tool. Two scripts do the work:

- [`tools/publish-engine.sh`](../tools/publish-engine.sh) publishes the
  engine.
- [`tools/publish-release.sh`](../tools/publish-release.sh) publishes the
  tool and the Bridge.

Each script has a `--dry-run` option. It does the checks and prints the plan
and the release notes, and it publishes nothing. Use it first, each time.

You need the GitHub CLI (`gh`), signed in with write access to the
`flutter-vita` repositories.

## Two kinds of release

| Release | Repository | Tag | File | Script |
|---|---|---|---|---|
| **Engine release** | [flutter-vita/flutter](https://github.com/flutter-vita/flutter/releases) | The first eight characters of the engine commit, for example `059e1168` | `flutter-engine-vita-<flutter>-<tag>.tar.gz` | `publish-engine.sh` |
| **Tool release** | [flutter-vita/flutter-vita](https://github.com/flutter-vita/flutter-vita/releases) | `<flutter>-vita.<X.Y.Z>`, for example `3.47.7-vita.1.0.0` | `flutter-vita-bridge-<tag>.vpk` | `publish-release.sh` |
| Embedder tag | [flutter-vita/flutter-vita-embedder](https://github.com/flutter-vita/flutter-vita-embedder/releases) | The same tag as the tool release | None. Apps compile the embedder from source | `publish-release.sh`, only when the submodule moved |
| Packages | [flutter-vita/flutter-vita-packages](https://github.com/flutter-vita/flutter-vita-packages) | `<name>-v<semver>` | Published on pub.dev | None. Each package goes to pub.dev on its own |

**The engine release always comes first.** `versions.json` names an engine
release only after that release exists. Thus a clone of `master` can always
download its engine with `flutter-vita precache`.

flutter-tizen uses the same model. Their CI publishes one engine release for
each engine commit, and the tool repository pins the commit in
`bin/internal/engine.version`. We have no CI, so you run
`publish-engine.sh` on the Mac that built the engine.

## Version numbers

- **An engine release has no version number.** Its tag is the commit. You can
  have many engine releases for one Flutter version.
- **A tool release has the tag `<flutter>-vita.<X.Y.Z>`.** `<flutter>` is the
  `flutter` value in `versions.json`. The script refuses a tag of another
  form.
- **`X.Y.Z` starts at `1.0.0` for each Flutter version**, as in flutter-tizen.
  The first release on Flutter 3.47.7 is `3.47.7-vita.1.0.0`, and the first
  release on the next Flutter version is `<flutter>-vita.1.0.0` again.
- Increase `Z` for a fix (`1.0.1`) and `Y` for a new feature (`1.1.0`).
  Increase `X` only for a change that stops existing apps or CLI commands from
  working.
- **`1.0.0` does not mean stable.** It means the first release on that Flutter
  version. A release that is not ready for general use gets the GitHub
  pre-release mark: run `publish-release.sh` with `--prerelease`.
- Release 0.1.0 used an older form: `3.44.8_0.1.0`, on all three
  repositories. The first release in the current form is `3.47.7-vita.1.0.0`.

## When the engine changes

1. Commit the change on the fork branch `vita-<flutter>` in
   `third_party/flutter`, and push it:

   ```sh
   git -C third_party/flutter push --no-verify fork vita-3.47.7
   ```

   If you changed a dependency fork (Dart, Skia, BoringSSL, abseil, zlib),
   push that fork too. `tools/engine-tree.sh --verify` must show
   `0 failed`.

2. Build the engine:

   ```sh
   cd third_party/flutter/engine/src
   PATH="$HOME/depot_tools:$PATH" ninja -C out/vita_release phony/flutter/shell/platform/embedder/vita_runtime
   ```

3. Do the checks on the console. See [Checks on the console](#checks-on-the-console).

4. Publish:

   ```sh
   ./tools/publish-engine.sh --dry-run
   ./tools/publish-engine.sh
   ```

The script does these steps:

1. It makes sure that the fork's `HEAD` is on `fork/vita-<flutter>`, that
   `engine-tree.sh --verify` passes, and that `master` is pushed.
2. It packages the engine with `tools/package-engine.sh --release <tag>`.
   That script refuses a build that has steps pending.
3. It makes sure that the archive's `MANIFEST.txt` names the fork's `HEAD`.
4. It publishes the archive as the release `<tag>` on flutter-vita/flutter,
   at that commit.
5. It writes the tag, the URL and the sha256 into `versions.json`. Then it
   commits `versions: engine <tag>` and pushes `master`.
6. It downloads the engine again through `flutter-vita precache` into an empty
   folder. The download, the sha256 and the unpacked tree must be correct.

An engine release does not change the Bridge. The Bridge links its own
pinned engine. See [The Bridge and its engine](#the-bridge-and-its-engine).

## A tool release

1. Do the checks on the console. See [Checks on the console](#checks-on-the-console).

2. Publish:

   ```sh
   ./tools/publish-release.sh 3.47.7-vita.1.0.1 --dry-run
   ./tools/publish-release.sh 3.47.7-vita.1.0.1
   ```

   Add `--prerelease` to both commands for a release that is not ready for
   general use.

Read the plan and the release notes from the dry run before you publish.

The script does these steps:

1. It makes sure that `master` is clean and pushed, that the tag does not
   exist, and that `embedder` and `packages` are clean and pushed.
2. It downloads the engine that `versions.json` names, with
   `publish-engine.sh --check`. If no engine release exists, it stops. Run
   `publish-engine.sh` first.
3. It writes the tag into `versions.json` (`release`, and `embedder.release`
   when the embedder gets the tag), commits `release: <tag>` and adds the tag.
4. It builds the Bridge. The Bridge shows the tag in its footer.
5. It tags the embedder, if the submodule moved since the embedder's last
   tag, and pushes that tag.
6. It pushes `master` and the tag together, in one atomic push.
7. It makes the GitHub releases: the embedder release, then the tool release
   with `flutter-vita-bridge-<tag>.vpk`. With `--prerelease`, both releases
   get the pre-release mark.

The release notes list the parts with links, the install pages at the tag,
and the commit subjects since the last tag, in groups by their `area:`
prefix. Thus write commit subjects that a toolchain user can read.

## Checks on the console

Do these checks before a release. The scripts do not do them.

| Check | Command | Pass |
|---|---|---|
| The probes of the Tests tab | `./tools/suite.sh tests` | All probes pass |
| The hardware checks | `./tools/suite.sh hardware` | All checks pass |
| The shaders | Put `1` in `ux0:data/flutter-vita/gles2-capture.on`, open the gallery and the test apps, then pull `ux0:data/flutter-vita/gles2-shaders.glsl` | No shader is `refused`. Add the new shaders to `gles2/corpus` |
| The GPU pixel test | `gles2/test/build.sh`, then install `gles2/test/build/fvita_gles2_test.vpk` and start it from the Bridge | M0 to M6 pass in `ux0:data/flutter-vita/gles2-test.txt` |
| The benchmark | `tool/bench.sh` in [flutter-vita-bench](https://github.com/flutter-vita/flutter-vita-bench) | No regressions against the baseline |
| The Bridge | `echo ping \| nc -4 fluttervita.local 1341` | `pong bridge` |

The Tests tab and the hardware checks do not draw. Only the shader capture
and the GPU pixel test find a shader that does not compile.

If the engine changed, take a new benchmark baseline after the release (three
launches, see the baseline README in flutter-vita-bench). Before that, the
benchmark compares the new engine with the old baseline.

## The Bridge and its engine

The Bridge links a pinned engine, not the engine in the tree
([ADR-0016](adr/0016-the-bridge-becomes-a-flutter-app.md)). The pin is
`bridge/engine-pin.txt`. Change it only with `tools/pin-bridge-engine.sh`,
and never as part of a release. When the Bridge engine and the tool engine
are different, the release plan shows a note. That is permitted.

## When a script stops

| Where it stopped | What to do |
|---|---|
| `publish-engine.sh`, before the release is published | Nothing is published. Repair the cause and run it again |
| `publish-engine.sh`, after the release, before the pin | Run it again. It finds the release and pins it |
| `publish-release.sh`, before the push | The script removes its local commit and tag. Repair the cause and run it again |
| `publish-release.sh`, after the embedder tag, before the tool push | Run it again. It accepts the embedder tag when the tag is on the same commit |
| `publish-release.sh`, after the push, before the GitHub release | The script prints the `gh release create` command that makes the release |

Do not move or delete a tag after you push it. If a release has a fault, make
a new release with a higher number.
