# Install the toolchain on Linux

The same five pieces as on macOS: VitaSDK, Flutter 3.44.8, CMake, Python 3
with Pillow, and this repository with the engine artifact. The maintainer
builds on macOS; the scripts are plain bash and CMake and have nothing
macOS-specific in them, but a Linux run has not been done end to end. If a
step fails for you, open an issue with the output.

## 1. VitaSDK

```sh
sudo apt install cmake git python3 python3-pip curl   # or your distribution's names
git clone https://github.com/vitasdk/vdpm ~/vdpm
cd ~/vdpm
export VITASDK="$HOME/vitasdk"
export PATH="$VITASDK/bin:$PATH"
export CMAKE_POLICY_VERSION_MINIMUM=3.5
./bootstrap-vitasdk.sh
./install-all.sh
```

Add the `VITASDK` and `PATH` exports to your shell profile.

## 2. Flutter 3.44.8

```sh
dart pub global activate fvm
fvm install 3.44.8
```

The tools look in `$HOME/fvm/versions/3.44.8`; `FLUTTER_ROOT` or
`--flutter DIR` names another location.

## 3. Python

```sh
python3 -m pip install pillow
```

## 4. This repository and the engine

```sh
git clone --recurse-submodules https://github.com/flutter-vita/flutter-vita
cd flutter-vita
```

`./cli/flutter-vita precache` downloads the engine release named in
[`versions.json`](../versions.json) and unpacks it to
`out/artifacts/flutter-engine-vita-3.44.8/`. The artifact carries a
`gen_snapshot` per host under `host-<os>-<arch>/`, and release
`3.44.8_0.1.0` has it for `darwin-arm64` only; `doctor` says whether one
exists for yours. Without one, [dev-environment.md](dev-environment.md)
describes the engine build, which produces it.

## 5. Check

```sh
./cli/flutter-vita doctor
```

Next: [Console setup](configure-console.md).
