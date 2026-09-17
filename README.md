# Flutter for the PlayStation Vita

Flutter apps on the PS Vita. This is the Flutter engine and the Flutter
framework, compiled for `arm-vita-eabi` and drawing through the console's
GPU. Your `main.dart` does not change.

```
Flutter framework (Dart AOT)
        v
Flutter engine + Skia          flutter-vita/flutter, branch vita-3.44.8
        v
Vita embedder                  flutter-vita/flutter-vita-embedder
        v
GLES2 -> fvita_gles2 -> sceGxm engine/gles2/, this repo
        v
PowerVR SGX543MP4+
```

*PlayStation and PS Vita are trademarks of Sony Interactive Entertainment.
This project is not affiliated with or endorsed by Sony.*

## Supported devices

- PS Vita 1000 and PS Vita 2000 with a homebrew enabler (HENkaku or
  h-encore²), firmware 3.60 to 3.74.
- The console needs Sony's shader compiler, `ur0:data/libshacccg.suprx`.
  [Console setup](docs/configure-console.md) says how to check for it.
- Flutter 3.44.8, pinned. The engine is prebuilt for this version and the
  framework must match it ([VERSIONS.md](VERSIONS.md)).
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

| Repository | What it is |
| --- | --- |
| [flutter-vita](https://github.com/flutter-vita/flutter-vita) (this one) | The `flutter-vita` command, the app template, the receiver, the GLES2 layer, the samples and the docs. |
| [flutter](https://github.com/flutter-vita/flutter) | The fork of Flutter, branch `vita-3.44.8`: the engine's Vita changes as commits on the `3.44.8` tag. Its releases carry the prebuilt engine archive; [`versions.json`](versions.json) names the one this tool uses. |
| [flutter-vita-embedder](https://github.com/flutter-vita/flutter-vita-embedder) | The embedder, the `main()` of every app. A submodule here at `engine/embedder`, compiled from source into each build. |
| [plugins](https://github.com/flutter-vita/plugins) | The Vita implementations of pub packages, `packages/<name>_vita`. A submodule here at `plugins/`, path dependencies for the samples until they reach pub.dev. |

Clone with `--recurse-submodules`, or run `git submodule update --init`
after a plain clone.

## Docs

### Vita basics

- [Console setup](docs/configure-console.md): homebrew, the network, the
  shader compiler, and the receiver that stays on the console.
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
- [Limitations](docs/limitations.md): no hot reload, fonts, plugins, memory.
- [Release an app](docs/release-app.md): the release build, LiveArea art,
  what to hand your users.

### Platform integration

- [Develop a plugin](docs/develop-plugin.md): a C half beside a Dart package,
  compiled into the app.
- [Available plugins](https://github.com/flutter-vita/plugins): Vita implementations of `path_provider`,
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
  for widgets, benchmark scenes, conformance probes, hardware checks.
- [`samples/test-apps`](samples/test-apps): apps we did not write, run as found:
  Wonderous, LocalSend, a manga reader and a journal, pinned by commit in
  [`manifest.txt`](samples/test-apps/manifest.txt).
  [The run](docs/results/test-apps-fvita-gles2-2026-09-13.md).
- [`receiver/`](receiver): the deploy target on the console is itself a
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
