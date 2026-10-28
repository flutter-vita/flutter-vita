# Install the toolchain on macOS

What you need on the Mac: CMake and the tool. The Homebrew cask (step 3)
installs both with one command. VitaSDK and Flutter 3.47.7 are not on the
list: the tool downloads its own. The tool needs no Python: its scripts are
bash and Dart, and Dart comes with the Flutter SDK of step 2. Rebuilding the
Flutter engine itself is not part of this page; the engine comes prebuilt.

## 1. VitaSDK

Nothing to install. VitaSDK is the `arm-vita-eabi` compiler and the Vita's
headers and stub libraries. When the tool finds no VitaSDK, the first
`flutter-vita` build or `doctor` downloads VitaSDK's own release archive for
this computer (100 MB, one time). It checks the archive against the sha256 in
[`versions.json`](../versions.json) and unpacks it to
`~/.flutter-vita/vitasdk/<release>`. `tools/vitasdk.sh` does this, and you
can run it on its own.

The tool uses the first VitaSDK that it finds:

1. the folder in `VITASDK`, when you set it;
2. the VitaSDK that the tool installed;
3. `~/vitasdk` or `/usr/local/vitasdk`, where VitaSDK's own install puts it.

An app build needs only the base archive: the compiler and the stub
libraries. The vdpm packages (`install-all.sh`) are not necessary. The
Khronos GLES 2.0 headers are in [`gles2/include`](../gles2/include).

## 2. Flutter 3.47.7

Nothing to install. The first `flutter-vita` command downloads Google's
release archive of Flutter 3.47.7 (2.1 GB, one time), checks it against the
sha256 in [`versions.json`](../versions.json), and unpacks it to
`~/.flutter-vita/flutter/3.47.7`. `tools/flutter-sdk.sh` does this, and you
can run it on its own. The Flutter you use for other projects is not read
and not changed.

The prebuilt engine is compiled for exactly 3.47.7, so the framework must be
the same version. The tool owns its copy so that nobody has to manage that
by hand.

**Why not our fork of Flutter?** The fork,
[flutter-vita/flutter](https://github.com/flutter-vita/flutter), changes
only the engine: `engine/src` and `DEPS`. Its framework and its `flutter`
command are the same as in the 3.47.7 release, and the engine comes
prebuilt (step 4). An app build uses the Flutter SDK on the Mac only:
`flutter pub get`, `flutter build bundle` for the assets, and the Dart
compiler front end.

To use a Flutter 3.47.7 that you already have, export `FLUTTER_ROOT`. The
build refuses an SDK at another revision.

## 3. The tool

With Homebrew:

```sh
brew install --cask flutter-vita/tap/flutter-vita
```

The cask puts `flutter-vita` on your `PATH`. The tool keeps the engine, the
Flutter SDK and its other files in `~/.flutter-vita`. `brew upgrade --cask
flutter-vita` installs the next release.

To change the tool, clone the repository:

```sh
git clone --recurse-submodules https://github.com/flutter-vita/flutter-vita
cd flutter-vita
```

`--recurse-submodules` brings the embedder, `embedder`, which every
app build compiles; after a plain clone, `git submodule update --init`
does the same. Building apps needs no engine checkout. Only an engine
rebuild does; `./tools/engine-tree.sh --apply` puts the fork's branch
into `third_party/flutter`, and `--verify` checks the port is in place.

## 4. The engine artifact

```sh
./cli/flutter-vita precache
```

The prebuilt engine is a release of the fork,
[flutter-vita/flutter](https://github.com/flutter-vita/flutter/releases).
With Homebrew, the command is `flutter-vita precache`.

`precache` reads [`versions.json`](../versions.json), downloads the
tarball it names (25 MB), checks its sha256 and unpacks it to
`out/artifacts/flutter-engine-vita-3.47.7/` in a clone, or to
`~/.flutter-vita/engines/flutter-engine-vita-3.47.7/` with Homebrew: the engine archive,
`gen_snapshot` for this host, the headers the embedder includes and the
data files. The first `flutter-vita build` does the same on its own when
the artifact is missing.

The release carries `gen_snapshot` for `darwin-arm64`. Another host builds
the engine once with [dev-environment.md](dev-environment.md) (a 12 GB
checkout and about thirty minutes). `FLUTTER_VITA_ENGINE` points the tools
at an artifact somewhere else.

## 5. Check

```sh
./cli/flutter-vita doctor
```

`doctor` works as `flutter doctor` does. It shows one line for each part:
the tool and its embedder, VitaSDK, Flutter, the engine, CMake and the
console. It installs VitaSDK when it finds none.

```text
Doctor summary (to see all details, run flutter-vita doctor -v):
[✓] flutter-vita (3.47.7-vita.1.0.4)
[✓] VitaSDK (arm-vita-eabi-gcc 15.2.0)
[✓] Flutter (3.47.7)
[✓] Flutter engine for PS Vita (059e1168, for Flutter 3.47.7)
[✓] CMake (4.4.4)
[!] PS Vita
    ! No console answers at fluttervita.local.
      Power on the Vita and open Flutter Bridge, or pass --host <address>.
      flutter-vita devices looks for it on the whole local network.
      flutter-vita build works without the console.

! Doctor found issues in 1 category.
```

`[✓]` is ready. `[!]` is a warning: a build works, a later step does not.
`[✗]` stops a build. Each problem comes with its fix. `doctor -v` also shows
what it found for each line that is ready: the folders, the revisions, the
host of `gen_snapshot`. The exit code is 1 only when a line shows `[✗]`.

In a clone, put `cli/` on your `PATH` to call it as `flutter-vita`. With
Homebrew, it is on your `PATH` already. Installation with
`pub global activate` is planned and not there yet.

Next: [Console setup](configure-console.md).
