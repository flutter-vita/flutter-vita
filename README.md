<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/readme-banner-dark.png">
    <img src="docs/images/readme-banner-light.png" alt="flutter-vita" width="420">
  </picture>
</p>

# Flutter for the PlayStation Vita

An unofficial port of Flutter to the PS Vita. It adds the PS Vita to Flutter
as a new platform. Flutter draws each frame with Skia on the console's GPU.

## Installation

### macOS

On a Mac with Apple silicon:

1. Install the tool with Homebrew. The cask also installs CMake.

   ```sh
   brew install --cask flutter-vita/tap/flutter-vita
   ```

2. Install VitaSDK. Homebrew does not have it.

   ```sh
   git clone https://github.com/vitasdk/vdpm ~/vdpm
   cd ~/vdpm
   export VITASDK="$HOME/vitasdk"
   export PATH="$VITASDK/bin:$PATH"
   export CMAKE_POLICY_VERSION_MINIMUM=3.5
   ./bootstrap-vitasdk.sh
   ./install-all.sh
   ```

   Add the `VITASDK` and `PATH` lines to your shell profile.

3. Check the setup. The first run downloads Flutter 3.47.7 for the tool's
   own use (2.1 GB).

   ```sh
   flutter-vita doctor
   ```

To change the tool, clone the repository as on Linux. All steps:
[Install on macOS](docs/install-macos.md).

### Linux

1. Install CMake, Git and VitaSDK:

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

   Add the `VITASDK` and `PATH` lines to your shell profile.

2. Clone the tool:

   ```sh
   git clone --recurse-submodules https://github.com/flutter-vita/flutter-vita
   cd flutter-vita
   export PATH="$PWD/cli:$PATH"
   ```

3. Build the engine one time, because the prebuilt engine has
   `gen_snapshot` for macOS only ([Engine build](docs/dev-environment.md)).

4. Check the setup. The first run downloads Flutter 3.47.7 for the tool's
   own use (1.5 GB).

   ```sh
   flutter-vita doctor
   ```

All steps: [Install on Linux](docs/install-linux.md).

### Windows

Windows is not supported yet.

## Add the PS Vita to your app

1. Add a `vita:` block to `pubspec.yaml`:

   ```yaml
   vita:
     title_id: MYAP00001
     name: My App
   ```

   The title id is four capital letters and five digits. Each app needs its
   own id. Do not use `FVTA`: the tool uses it for its own titles.

2. For each plugin with native code, add its Vita package. Set `ref` to the
   release of your tool, which `flutter-vita --version` shows:

   ```yaml
   dependencies:
     path_provider: ^2.1.0
     path_provider_vita:
       git:
         url: https://github.com/flutter-vita/flutter-vita.git
         path: plugins/path_provider_vita
         ref: 3.47.7-vita.1.0.3
   ```

   [plugins/](plugins/README.md) lists the Vita packages. A package with
   only Dart code needs nothing.

3. Optional: connect the D-pad and the rear touch panel. Add `flutter_vita`,
   and call `FlutterVita.configure` before `runApp`. On other platforms the
   call does nothing.

   ```yaml
   dependencies:
     flutter_vita:
       git:
         url: https://github.com/flutter-vita/flutter-vita-packages.git
         path: flutter_vita
   ```

   ```dart
   import 'package:flutter_vita/flutter_vita.dart';

   void main() async {
     WidgetsFlutterBinding.ensureInitialized();
     await FlutterVita.configure(pad: PadMode.focus, rearTouch: RearTouch.scroll);
     runApp(const MyApp());
   }
   ```

4. Add your fonts under `fonts:` in `pubspec.yaml`. The console has no
   system fonts, and the tool adds only Roboto and Roboto Mono. If no font
   has a character, for example an emoji, the app shows an empty box.

5. Start the Bridge on the console (see [Console setup](#console-setup)).
   Then run the app from its folder:

   ```sh
   flutter-vita run .
   ```

6. Build the release `.vpk`:

   ```sh
   flutter-vita build . --release
   ```

   The file is `build/vita/<package name>.vpk`. Users install it with
   VitaShell. For your own LiveArea art, see
   [Release an app](docs/release-app.md).

## Console setup

You do these steps one time. [Console setup](docs/configure-console.md)
tells more about each step.

1. Make the console ready for homebrew: HENkaku, Enso or h-encore², and
   VitaShell.
2. Install the shader compiler plugin, `libshacccg.suprx`. Each app draws
   through the GPU, and the GPU needs this Sony plugin to compile its
   shaders. The firmware does not have it, and this repository cannot
   include it. Without it, an app starts but shows nothing. To get it:
   - Install the PlayStation Mobile Runtime with its 2.01 update.
   - Install [ShaRKF00D](https://github.com/Rinnegatamante/ShaRKF00D) with
     VitaShell, and start it. It shows no screen, and it closes when it is
     done.
   - In VitaShell, make sure that `ur0:data/libshacccg.suprx` is there.

   The plugin is a user module. It is not a kernel plugin, and you do not
   change the taiHEN configuration.
3. Connect the console to the same Wi-Fi network as your computer. In
   **Settings > Power Save Settings**, turn off automatic standby.
4. Download `flutter-vita-bridge-<version>.vpk` from the
   [latest release](https://github.com/flutter-vita/flutter-vita/releases/latest).
   Copy it to the console with VitaShell (FTP or USB), and install it.
5. Start **Flutter Bridge**, and check the connection:

   ```sh
   flutter-vita doctor
   ```

After that, the tool installs each app over Wi-Fi, through the bridge.

## Usage

`flutter-vita` builds, installs and runs Flutter apps on the console. Point
it at any Flutter app directory.

```sh
# Check the toolchain and find the console.
flutter-vita doctor

# Download the prebuilt engine (once; build does it too).
flutter-vita precache

# Build, install and run an app; the log follows.
flutter-vita run samples/gallery
flutter-vita run ~/projects/my_app

# Build a .vpk without the dev server and the debug strip.
flutter-vita build my_app --release

# While an app runs.
flutter-vita logs
flutter-vita screenshot out.png
flutter-vita tap 480 272
```

- See [Commands](docs/commands.md) for all commands.
- See [Get started](docs/get-started.md) for the first run.
- The first build takes about a minute.

## How it works

![The layers of a Flutter app on the PS Vita, from your app down to the GPU. Each layer shows where it comes from.](docs/images/layers.svg)

On your Mac, `gen_snapshot` compiles your app and the Flutter framework to
ARMv7 machine code. The build links that code with the prebuilt engine, the
embedder and the GLES2 layer into one `eboot.bin`, and packs it into a
`.vpk`. The bridge on the console installs the `.vpk` and starts it.

A plugin with native code has a Vita implementation in C. The build
compiles it into the same `eboot.bin` ([Available plugins](plugins/)).

The parts are in five repositories, which the
[organisation page](https://github.com/flutter-vita) lists.
[docs/engine.md](docs/engine.md) lists the forks of the engine and its
libraries.

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

| | |
| --- | --- |
| ![Wonderous on a PS Vita, with the debug strip across the top](docs/images/wonderous.png) | ![LocalSend on a PS Vita](docs/images/localsend.png) |
| **Wonderous**, an app we did not write, at 60 fps. The debug strip across the top shows the live numbers. | **LocalSend**, file transfer over the local network. We did not write it either. |
| ![The gallery's widget panel on a PS Vita](docs/images/gallery.png) | ![The bridge's list of installed apps on a PS Vita](docs/images/bridge.png) |
| **The gallery**: widgets, tests and hardware checks. | **The bridge** installs your app over Wi-Fi and keeps its logs. |

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
failure. If the problem also happens with the normal `flutter` command,
report it at [flutter/flutter](https://github.com/flutter/flutter/issues).

## Contribution

Read [CONTRIBUTING.md](CONTRIBUTING.md). Decisions live in
[docs/adr/](docs/adr/README.md); a change that reverses one comes with a new
record.

## License

zlib, see [LICENSE](LICENSE). An app that you build with flutter-vita does
not have to carry our notice. [NOTICE](NOTICE) lists the components that come
from other projects and their licenses.

*PlayStation and PS Vita are trademarks of Sony Interactive Entertainment.
This project is not affiliated with or endorsed by Sony.*
