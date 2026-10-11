# Install the toolchain on macOS

What you need on the Mac: VitaSDK (the `arm-vita-eabi` compiler and the
Vita's headers and stubs), CMake, Python 3 with Pillow, and this repository.
Flutter 3.47.7 is not on the list: the tool downloads its own. Rebuilding the Flutter engine
itself is not part of this page; the engine comes prebuilt.

## 1. VitaSDK

Install with `vdpm`, into your home directory. A home install needs no
`sudo`.

```sh
brew install cmake
git clone https://github.com/vitasdk/vdpm ~/vdpm
cd ~/vdpm
export VITASDK="$HOME/vitasdk"
export PATH="$VITASDK/bin:$PATH"
export CMAKE_POLICY_VERSION_MINIMUM=3.5
./bootstrap-vitasdk.sh
./install-all.sh
```

Add the two `export` lines for `VITASDK` and `PATH` to your shell profile.
`CMAKE_POLICY_VERSION_MINIMUM` is for `install-all.sh` only: CMake 4 refuses
several of the library ports without it.

Check:

```sh
arm-vita-eabi-gcc --version
```

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
prebuilt (step 5). An app build uses the Flutter SDK on the Mac only:
`flutter pub get`, `flutter build bundle` for the assets, and the Dart
compiler front end.

To use a Flutter 3.47.7 that you already have, export `FLUTTER_ROOT`. The
build refuses an SDK at another revision.

## 3. Python

`python3` with Pillow, for the LiveArea art check and the screenshot
converter:

```sh
python3 -m pip install pillow
```

## 4. This repository

```sh
git clone --recurse-submodules https://github.com/flutter-vita/flutter-vita
cd flutter-vita
```

`--recurse-submodules` brings the embedder, `embedder`, which every
app build compiles; after a plain clone, `git submodule update --init`
does the same. Building apps needs no engine checkout. Only an engine
rebuild does; `./tools/engine-tree.sh --apply` puts the fork's branch
into `third_party/flutter`, and `--verify` checks the port is in place.

## 5. The engine artifact

```sh
./cli/flutter-vita precache
```

The prebuilt engine is a release of the fork,
[flutter-vita/flutter](https://github.com/flutter-vita/flutter/releases).
`precache` reads [`versions.json`](../versions.json), downloads the
tarball it names (25 MB), checks its sha256 and unpacks it to
`out/artifacts/flutter-engine-vita-3.47.7/`: the engine archive,
`gen_snapshot` for this host, the headers the embedder includes and the
data files. The first `flutter-vita build` does the same on its own when
the artifact is missing.

The release carries `gen_snapshot` for `darwin-arm64`. Another host builds
the engine once with [dev-environment.md](dev-environment.md) (a 12 GB
checkout and about thirty minutes). `FLUTTER_VITA_ENGINE` points the tools
at an artifact somewhere else.

## 6. Check

```sh
./cli/flutter-vita doctor
```

`doctor` checks `VITASDK`, the engine artifact, the embedder submodule,
`gen_snapshot` for this host, the Flutter SDK and its patched product SDK,
and then looks for a console on the network. Every line it prints as `--` comes with the fix.

Put `cli/` on your `PATH` to call it as `flutter-vita`. Installation with
`pub global activate` is planned and not there yet.

Next: [Console setup](configure-console.md).
