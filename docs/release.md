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
| **Tool release** | [flutter-vita/flutter-vita](https://github.com/flutter-vita/flutter-vita/releases) | `<flutter>-vita.<X.Y.Z>`, for example `3.47.7-vita.1.0.0` | `flutter-vita-bridge-<tag>.vpk` and `flutter-vita-<tag>.tar.gz` | `publish-release.sh` |
| Embedder tag | [flutter-vita/flutter-vita-embedder](https://github.com/flutter-vita/flutter-vita-embedder/releases) | The same tag as the tool release | None. Apps compile the embedder from source | `publish-release.sh`, only when the submodule moved |
| Packages | [flutter-vita/flutter-vita-packages](https://github.com/flutter-vita/flutter-vita-packages) | `<name>-v<semver>`, for example `flutter_vita-v0.1.1` | The package on pub.dev | None. `dart pub publish`, see [A package release](#a-package-release) |
| Homebrew cask | [flutter-vita/homebrew-tap](https://github.com/flutter-vita/homebrew-tap) | None. A commit sets the version and the sha256 | `Casks/flutter-vita.rb` | `publish-release.sh`, after each tool release that is not a pre-release |

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
5. It packs `flutter-vita-<tag>.tar.gz`: the tool, the embedder and the
   packages at the tag, without `.git`. Then it unpacks the archive and runs
   `flutter-vita --version` from it. The command must show the tag and write
   nothing.
6. It tags the embedder, if the submodule moved since the embedder's last
   tag, and pushes that tag.
7. It pushes `master` and the tag together, in one atomic push.
8. It makes the GitHub releases: the embedder release, then the tool release
   with `flutter-vita-bridge-<tag>.vpk` and `flutter-vita-<tag>.tar.gz`. With
   `--prerelease`, both releases get the pre-release mark.
9. It sets the tag and the sha256 of the archive in the cask, removes a
   `python@` dependency if one is still there, and pushes
   flutter-vita/homebrew-tap. It does not do this step for a pre-release, or
   when the repository does not exist. See [The Homebrew cask](#the-homebrew-cask).

The dry run also packs `HEAD` and runs the same check on that archive.

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

## After a tool release

The checks before a release use your local builds. This test uses only the
published files: the Bridge `.vpk` from the GitHub release, a new clone at the
tag, and the engine that `precache` downloads. Do it after each tool release.
The examples use `3.47.7-vita.1.0.0`.

1. Start the Bridge on the console. If an app is open, send it `handoff`:

   ```sh
   echo handoff | nc -4 -w 5 fluttervita.local 1339
   ```

2. Install the published Bridge:

   ```sh
   D="$(mktemp -d)"
   gh release download 3.47.7-vita.1.0.0 --repo flutter-vita/flutter-vita --pattern '*.vpk' --dir "$D"
   ./tools/selfupdate-bridge.sh "$D/flutter-vita-bridge-3.47.7-vita.1.0.0.vpk" --no-build
   ./tools/panel.sh shot "$D/bridge.png"
   ```

3. Clone the tag into an empty folder, then download the engine and install
   the gallery from that clone:

   ```sh
   git clone --branch 3.47.7-vita.1.0.0 --recurse-submodules https://github.com/flutter-vita/flutter-vita "$D/clone"
   cd "$D/clone"
   ./cli/flutter-vita --version
   ./cli/flutter-vita precache
   ./cli/flutter-vita install samples/gallery
   ./cli/flutter-vita screenshot "$D/gallery.png"
   echo log | nc -4 -w 5 fluttervita.local 1339 | grep -E 'refused|link failed' | grep -v -E 'regs refused|tiled render targets refused'
   ```

   `git clone --branch` shows the warning "is not a commit" for an annotated
   tag. You can ignore it if `git describe --tags` shows the tag.

4. If the script updated the cask, install the tool with Homebrew too:

   ```sh
   brew install --cask flutter-vita/tap/flutter-vita
   flutter-vita --version
   brew uninstall --cask flutter-vita
   ```

The test passes when all of these are true:

| Check | Pass |
|---|---|
| The Bridge footer (`bridge.png`) | `flutter-vita <tag>`, and the engine that `versions.json` names |
| `--version` in the clone | `flutter-vita <tag>`, with the engine release and the embedder tag |
| `precache` in the clone | The download completes and the sha256 is `ok` |
| `install samples/gallery` | The gallery builds, installs and opens on the console |
| `gallery.png` | The gallery draws, and the strip shows 60 fps |
| The last command, the log search | No output: no shader was refused |
| `flutter-vita --version` from Homebrew | `flutter-vita <tag>` |

If one check fails, make a fix release with a higher `Z`. Do not change the
published release.

## A package release

Two packages are on pub.dev: [flutter_vita](https://pub.dev/packages/flutter_vita)
and [vita_file_browser](https://pub.dev/packages/vita_file_browser). The
other packages and the plugins in `plugins/` are not published. Publish a
package only when the owner asks for that package and that version.

1. Sign in to pub.dev one time on this computer:

   ```sh
   dart pub login
   ```

   The browser opens the Google sign-in. The uploader is that Google
   account.

2. In `packages/` (flutter-vita-packages), set the new version in
   `<name>/pubspec.yaml`, and add a section to `<name>/CHANGELOG.md`.
   Increase Z for a fix or a text change, and Y for a new API. Commit and
   push.

3. Do a dry run from a clean tree. It must show 0 warnings:

   ```sh
   cd packages/flutter_vita
   dart pub publish --dry-run
   ```

4. Publish. Then tag the commit, and push the tag:

   ```sh
   dart pub publish
   git tag -a flutter_vita-v0.1.1 -m "flutter_vita 0.1.1"
   git push origin flutter_vita-v0.1.1
   ```

5. In this repository, commit the new submodule commit, for example
   `packages: flutter_vita 0.1.1`.

`flutter_vita` takes `vita_file_browser` from pub.dev. If a change in
`flutter_vita` needs a new `vita_file_browser`, publish `vita_file_browser`
first. Then raise the constraint in `flutter_vita`.

pub.dev does not delete a version. You can only mark a package as
discontinued, or retract a version in its first seven days. Thus do the dry
run first, and read its file list.

In this tree, the gallery takes `vita_file_browser` from `packages/` with
`dependency_overrides`, so it tests the local copy. `flutter_vita`,
`file_picker_vita` and `file_selector_vita` take it from pub.dev.

## The Homebrew cask

A user on a Mac can install the tool with one command:

```sh
brew install --cask flutter-vita/tap/flutter-vita
```

The cask is `Casks/flutter-vita.rb` in
[flutter-vita/homebrew-tap](https://github.com/flutter-vita/homebrew-tap). It
downloads `flutter-vita-<tag>.tar.gz` from the tool release, and it links
`flutter-vita/cli/flutter-vita` into Homebrew's `bin`. It depends on
`cmake`. Release 3.47.7-vita.1.0.2 also needed `python@3.15`. The tool needs
no Python since `99cc13a`, and the cask has no Python dependency since
3.47.7-vita.1.0.3. VitaSDK is not in Homebrew, so the cask tells the user to
install it.

Homebrew 7 loads a cask from a tap only when you trust the cask. An install by
the full name `flutter-vita/tap/flutter-vita` adds the cask to the trusted
list, so a later `brew upgrade` finds it. We tested this on 2026-10-22 with
Homebrew 7.0.10.

It is a cask, not a formula. Homebrew does not install a formula without a
prebuilt bottle while the selected Xcode is older than the current one. Our
tool compiles nothing, but Homebrew does that check for each formula. A cask
has no build step and no Xcode check. We tested both on 2026-10-16: the
formula stopped at the Xcode check, and the cask installed and built an app.

The archive has no `.git`, so the installed tool writes into
`~/.flutter-vita` and never into Homebrew's folder. A git checkout writes into
`out/`, as before.

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
| `publish-release.sh`, after the GitHub release, before the cask push | The script prints the version and the sha256. Set them in `Casks/flutter-vita.rb` in flutter-vita/homebrew-tap |

Do not move or delete a tag after you push it. If a release has a fault, make
a new release with a higher number.
