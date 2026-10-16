# Install the toolchain on Linux

The same pieces as on macOS: VitaSDK, CMake, and
this repository with the engine artifact. The tool downloads its own Flutter
3.47.7. The maintainer
builds on macOS; the scripts are plain bash and CMake and have nothing
macOS-specific in them, but a Linux run has not been done end to end. If a
step fails for you, open an issue with the output.

## 1. VitaSDK

```sh
sudo apt install cmake git curl   # or your distribution's names
git clone https://github.com/vitasdk/vdpm ~/vdpm
cd ~/vdpm
export VITASDK="$HOME/vitasdk"
export PATH="$VITASDK/bin:$PATH"
export CMAKE_POLICY_VERSION_MINIMUM=3.5
./bootstrap-vitasdk.sh
./install-all.sh
```

Add the `VITASDK` and `PATH` exports to your shell profile.

## 2. Flutter 3.47.7

Nothing to install. The first `flutter-vita` command downloads Google's
Linux archive of Flutter 3.47.7 (1.5 GB, one time), checks its sha256 and
unpacks it to `~/.flutter-vita/flutter/3.47.7`
([details](install-macos.md#2-flutter-3477)). `FLUTTER_ROOT` names a Flutter
3.47.7 you already have.

## 3. This repository and the engine

```sh
git clone --recurse-submodules https://github.com/flutter-vita/flutter-vita
cd flutter-vita
```

`./cli/flutter-vita precache` downloads the engine release named in
[`versions.json`](../versions.json) and unpacks it to
`out/artifacts/flutter-engine-vita-3.47.7/`. The artifact carries a
`gen_snapshot` per host under `host-<os>-<arch>/`, and a release
has it for `darwin-arm64` only; `doctor` says whether one
exists for yours. Without one, [dev-environment.md](dev-environment.md)
describes the engine build, which produces it.

## 4. Check

```sh
./cli/flutter-vita doctor
```

Next: [Console setup](configure-console.md).
