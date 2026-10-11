# Flutter for the PlayStation Vita

Flutter apps on the PS Vita. This is the Flutter engine and the Flutter
framework, compiled for `arm-vita-eabi` and drawing through the console's
GPU. Your `main.dart` does not change.

| | |
| --- | --- |
| ![Wonderous on a PS Vita, with the debug strip across the top](docs/images/wonderous.png) | ![LocalSend on a PS Vita](docs/images/localsend.png) |
| **Wonderous**, an app we did not write, at 60 fps. The debug strip across the top shows the live numbers. | **LocalSend**, file transfer over the local network. We did not write it either. |
| ![The gallery's widget panel on a PS Vita](docs/images/gallery.png) | ![The bridge's list of installed apps on a PS Vita](docs/images/bridge.png) |
| **The gallery**: widgets, tests and hardware checks. | **The bridge** installs your app over Wi-Fi and keeps its logs. |

*PlayStation and PS Vita are trademarks of Sony Interactive Entertainment.
This project is not affiliated with or endorsed by Sony.*

## Quick start

You need:

- A PS Vita with HENkaku or h-encore², firmware 3.60 to 3.74, and Sony's
  shader compiler on the card ([Console setup](docs/configure-console.md)).
- A Mac with Apple silicon. On Linux you build the engine one time,
  because the prebuilt engine has `gen_snapshot` for macOS only
  ([Linux](docs/install-linux.md)).
- VitaSDK, CMake, and Python 3 with Pillow
  ([Install on macOS](docs/install-macos.md)).
- No Flutter install. The first `flutter-vita` command downloads Flutter
  3.47.7 for the tool's own use, one time (2.1 GB), and does not touch the
  Flutter you use for other projects
  ([details](docs/install-macos.md#2-flutter-3477)).

Get the tool and the prebuilt engine, then check the setup:

```sh
git clone --recurse-submodules https://github.com/flutter-vita/flutter-vita
cd flutter-vita
export PATH="$PWD/cli:$PATH"
flutter-vita precache
flutter-vita doctor
```

Install the bridge on the console. You do this one time, with VitaShell
([Console setup, step 4](docs/configure-console.md#4-install-the-bridge)).
After that, all installs go over Wi-Fi.

Run the gallery, then your own app:

```sh
flutter-vita run samples/gallery
flutter-vita run ~/projects/my_app
```

`run` builds a `.vpk`, installs it, starts it and shows its log. The first
build takes about a minute. Before you run your own app, read the three
notes in [Get started](docs/get-started.md#2-run-your-own-app): the title
id, fonts and plugins.

## How it works

![The layers of a Flutter app on the PS Vita, from your app down to the GPU. Each layer shows where it comes from.](docs/images/layers.svg)

On your Mac, `gen_snapshot` compiles your app and the Flutter framework to
ARMv7 machine code. The build links that code with the prebuilt engine, the
embedder and the GLES2 layer into one `eboot.bin`, and packs it into a
`.vpk`. The bridge on the console installs the `.vpk` and starts it.

A plugin with native code has a Vita implementation in C. The build
compiles it into the same `eboot.bin` ([Available plugins](plugins/)).

## Supported devices

- PS Vita 1000 and PS Vita 2000 with a homebrew enabler (HENkaku or
  h-encore²), firmware 3.60 to 3.74.
- The console needs Sony's shader compiler, `ur0:data/libshacccg.suprx`.
  [Console setup](docs/configure-console.md) says how to check for it.
- Flutter 3.47.7, pinned. The engine is prebuilt for this version and the
  framework must match it ([docs/versions.md](docs/versions.md)). The tool downloads it
  for itself.
- The Vita3K emulator is not a supported target
  ([why](docs/vita3k-as-a-target.md)).

## Installation

- [macOS](docs/install-macos.md)
- [Linux](docs/install-linux.md)
- Windows is not supported yet.

## Usage

`flutter-vita` is the command for building, installing and driving apps.
Point it at any Flutter app directory.

```sh
# Check the toolchain and find the console.
flutter-vita doctor

# Download the prebuilt engine (once; build does it too).
flutter-vita precache

# Build, install and run an app; the log follows.
flutter-vita run samples/gallery

# Build a .vpk without the dev server and the debug strip.
flutter-vita build my_app --release

# While an app runs.
flutter-vita logs
flutter-vita screenshot out.png
flutter-vita tap 480 272
```

See [Commands](docs/commands.md) for the full list, and
[Get started](docs/get-started.md) for the first run.

## Repositories

| Repository | What it is | Why it exists |
| --- | --- | --- |
| [flutter-vita](https://github.com/flutter-vita/flutter-vita) (this one) | The `flutter-vita` command, the app template, the bridge, the GLES2 layer, the Vita implementations of twelve plugins (`plugins/`), the samples and the docs. | This is the part you use. You build, install, run and debug your app from here. |
| [flutter](https://github.com/flutter-vita/flutter) | Our fork of Flutter, branch `vita-3.47.7`. The engine's Vita changes are commits on the `3.47.7` tag. Its releases carry the prebuilt engine; [`versions.json`](versions.json) names the one this tool uses. | The engine does not run on the console without these changes. The prebuilt engine saves you a 12 GB checkout and a long build. |
| [flutter-vita-embedder](https://github.com/flutter-vita/flutter-vita-embedder) | The embedder, the `main()` of every app. It starts the engine, reads touch and buttons, and puts each frame on the screen. A submodule here at `embedder`. | Each Flutter platform has an embedder, and this is the one for the Vita. Every app build compiles it from source, so a fix in it needs no new engine. |
| [flutter-vita-packages](https://github.com/flutter-vita/flutter-vita-packages) | Our pub packages: `flutter_vita`, `vita_debug_strip`, `vita_file_browser`. A submodule here at `packages/`. | Your app adds them to `pubspec.yaml` like any other package. `flutter_vita` sets up the app for the console with one call in `main()`. |
| [flutter-vita-bench](https://github.com/flutter-vita/flutter-vita-bench) | The benchmark: a Flutter app with 36 scenes, and a script that compares each run with a baseline. Not a submodule. | When you change the engine, the GLES2 layer or the embedder, it tells you which scenes got slower. It builds with `flutter-vita` like any other app. |

Clone with `--recurse-submodules`, or run `git submodule update --init`
after a plain clone. The folders of this repository:

```text
cli/         the flutter-vita command
embedder/    submodule: flutter-vita-embedder
packages/    submodule: flutter-vita-packages
gles2/       the GLES2 layer (fvita_gles2)
plugins/     the Vita implementations of twelve plugins
bridge/    the bridge, FVTA00001
templates/   the app template, and the fonts every app gets
samples/     the gallery, and the list of test apps
tools/       the scripts that the command runs
docs/        guides, decisions (ADRs) and records
```

### The changes this port makes to other projects

Every one is a commit in a fork of the project it changes, on branch
`vita-3.47.7`. There are no patch files anywhere
([ADR-0021](docs/adr/0021-the-port-is-commits-not-patches.md)).

| Fork | Of | What we change |
| --- | --- | --- |
| [dart-sdk](https://github.com/flutter-vita/dart-sdk) | `dart-lang/sdk` | The Vita OS layer for the Dart VM: the platform, the toolchain, `dart:vita`, emulated TLS, `dart:io`, the TLS record layer, the root certificates |
| [skia](https://github.com/flutter-vita/skia) | `google/skia` | Platform detection, and a file reader in place of `mmap` |
| [abseil-cpp](https://github.com/flutter-vita/abseil-cpp) | `abseil/abseil-cpp` | No ELF introspection, no `tm_gmtoff`, `memalign` in place of `mmap` |
| [boringssl](https://github.com/flutter-vita/boringssl) | `google/boringssl` | An entropy source on the console's kernel RNG |
| [zlib](https://github.com/flutter-vita/zlib) | nothing to fork | No ARMv8 code paths on this ARMv7. Flutter takes zlib from Chromium, which GitHub does not carry, so this one is a copy rather than a fork |

`DEPS` in the engine fork names each of them by commit, so `gclient sync`
needs nothing else.

The test apps work the same way, pinned by
[`samples/test-apps/manifest.txt`](samples/test-apps/manifest.txt):
[localsend](https://github.com/flutter-vita/localsend),
[keklist_flutter](https://github.com/flutter-vita/keklist_flutter),
[flutter-wonderous-app](https://github.com/flutter-vita/flutter-wonderous-app)
and [flutter_manga_reader](https://github.com/flutter-vita/flutter_manga_reader).

## Docs

### Vita basics

- [Console setup](docs/configure-console.md): homebrew, the network, the
  shader compiler, and the bridge that stays on the console.
- [Install the toolchain on macOS](docs/install-macos.md) or
  [on Linux](docs/install-linux.md)
- [Glossary](docs/glossary.md): the words the Vita side and the Flutter side
  use for the same things.

### App development

- [Get started](docs/get-started.md)
- [Commands](docs/commands.md)
- [Debug an app](docs/debug-app.md): the debug strip, the log, screenshots,
  crash dumps.
- [Writing Flutter that runs on a Vita](docs/writing-flutter-that-runs-on-a-vita.md):
  what the benchmarks found, and what to do about it in app code.
- [Configure the app for the console](docs/configure-app.md): one call in
  `main()` for the pad, the rear panel, the pixel ratio and the plugins a
  console cannot serve.
- [Limitations](docs/limitations.md): no hot reload, fonts, plugins, memory.
- [Release an app](docs/release-app.md): the release build, LiveArea art,
  what to hand your users.

### Platform integration

- [Develop a plugin](docs/develop-plugin.md): a C half beside a Dart package,
  compiled into the app.
- [Available plugins](plugins/): Vita implementations of `path_provider`,
  `shared_preferences`, `url_launcher`, `battery_plus`, `sensors_plus`,
  `device_info_plus`, `connectivity_plus`, `audioplayers`, `record`,
  `camera`, `file_picker`, `file_selector`.
- [Architecture decisions](docs/adr/README.md): why each part is the way it
  is, and what would change it.

### Miscellaneous

- [Measurements](docs/results/): every run that changed a decision, with
  numbers and screenshots.
- [The GLES2 layer's progress](docs/gles2-progress.md)
- [Roadmap](docs/roadmap-capabilities.md)
- [Development environment](docs/dev-environment.md), for people who rebuild
  the engine or the patched SDKs.

## Showcases

- [`samples/gallery`](samples/gallery): the panel this port is measured with. Tabs
  for widgets, tests, hardware checks and the settings of `flutter_vita`.
- [`samples/test-apps`](samples/test-apps): apps we did not write, run as found:
  Wonderous, LocalSend, a manga reader and a journal, pinned by commit in
  [`manifest.txt`](samples/test-apps/manifest.txt).
  [The run](docs/results/test-apps-fvita-gles2-2026-09-13.md).
- [`bridge/`](bridge): the deploy target on the console is itself a
  Flutter app.

## Issues

Open an issue on GitHub. The most useful report is an app we did not write
that fails: its name, its commit, and the log, screenshot or crash dump.
[CONTRIBUTING.md](CONTRIBUTING.md) says what to attach for each kind of
failure.

## Contribution

Read [CONTRIBUTING.md](CONTRIBUTING.md). Decisions live in
[docs/adr/](docs/adr/README.md); a change that reverses one comes with a new
record.

## License

BSD 3-Clause, see [LICENSE](LICENSE). [NOTICE](NOTICE) lists the components
that come from other projects and their licenses.
