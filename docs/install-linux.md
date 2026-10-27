# Install the toolchain on Linux

The same pieces as on macOS: CMake and
this repository with the engine artifact. The tool downloads its own VitaSDK
and Flutter 3.47.7. The maintainer
builds on macOS; the scripts are plain bash and CMake and have nothing
macOS-specific in them, but a Linux run has not been done end to end. If a
step fails for you, open an issue with the output.

## 1. VitaSDK

```sh
sudo apt install cmake git curl bzip2   # or your distribution's names
```

Nothing else to install. The first `flutter-vita` build or `doctor`
downloads VitaSDK's Linux archive (100 MB, one time), checks its sha256 and
unpacks it to `~/.flutter-vita/vitasdk/<release>`
([details](install-macos.md#1-vitasdk)). `VITASDK` names a VitaSDK that you
have already; `~/vitasdk` is found without it.

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
