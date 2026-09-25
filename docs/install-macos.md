# Install the toolchain on macOS

What you need on the Mac: VitaSDK (the `arm-vita-eabi` compiler and the
Vita's headers and stubs), Flutter 3.44.8, CMake, Python 3 with Pillow, and
this repository with its patches applied. Rebuilding the Flutter engine
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

## 2. Flutter 3.44.8

You need a normal Flutter 3.44.8. The prebuilt engine is compiled for that
version, so the framework must be the same version.

**Why not our fork of Flutter?** The fork,
[flutter-vita/flutter](https://github.com/flutter-vita/flutter), changes
only the engine: `engine/src` and `DEPS`. Its framework and its `flutter`
command are the same as in the 3.44.8 release. The engine comes prebuilt
(step 5), so an app build does not read the fork. The build uses the Flutter
SDK on the Mac only: `flutter pub get`, `flutter build bundle` for the
assets, and the Dart compiler front end.

We recommend [fvm](https://fvm.app), because it keeps your other projects
on their own Flutter version:

```sh
dart pub global activate fvm
fvm install 3.44.8
```

The tools look for the SDK in `$HOME/fvm/versions/3.44.8`. If your Flutter
3.44.8 is in a different location, export `FLUTTER_ROOT`, or give
`--flutter DIR` to `tools/build-vita-app.sh`.

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

`--recurse-submodules` brings the embedder, `engine/embedder`, which every
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
`out/artifacts/flutter-engine-vita-3.44.8/`: the engine archive,
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
