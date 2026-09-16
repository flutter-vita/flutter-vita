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

The engine is prebuilt for 3.44.8 and the framework has to match it. Use
[fvm](https://fvm.app) so your other projects keep their own Flutter:

```sh
dart pub global activate fvm
fvm install 3.44.8
```

The tools look for the SDK in `$HOME/fvm/versions/3.44.8`. Another location
works with `--flutter DIR` on `tools/build-vita-app.sh`, or by exporting
`FLUTTER_ROOT`.

## 3. Python

`python3` with Pillow, for the LiveArea art check and the screenshot
converter:

```sh
python3 -m pip install pillow
```

## 4. This repository

```sh
git clone https://github.com/resashkin/flutter-vita
cd flutter-vita
```

Building apps needs nothing from the vendored Dart and Flutter trees. Only
an engine rebuild does; `./tools/apply-patches.sh --apply` puts the Vita
patch series into them, and `--verify` checks it is in place.

## 5. The engine artifact

The prebuilt engine is a tarball, `flutter-engine-vita-3.44.8.tar.gz`,
unpacked to `out/artifacts/flutter-engine-vita-3.44.8/`: the engine
archive, `gen_snapshot` for this host, the two headers and the dev server's
source. Take it from the project's releases once one is published; until
then, build it with [dev-environment.md](dev-environment.md) (a 12 GB
checkout and about thirty minutes). `FLUTTER_VITA_ENGINE` points the tools
at an artifact somewhere else.

## 6. Check

```sh
./cli/flutter-vita doctor
```

`doctor` checks `VITASDK`, the engine artifact, `gen_snapshot` for this
host, the Flutter SDK and its patched product SDK, and then looks for a
console on the network. Every line it prints as `--` comes with the fix.

Put `cli/` on your `PATH` to call it as `flutter-vita`. Installation with
`pub global activate` is planned and not there yet.

Next: [Console setup](configure-console.md).
