# flutter-vita

Flutter applications run on the PlayStation Vita.

This is not an emulator, and it is not a new implementation. This is the Flutter
engine and the Flutter framework. They are compiled for `arm-vita-eabi`. They
draw with the GPU of the Vita. Your `main.dart` file does not change.

```
Flutter framework (Dart AOT)
        v
Flutter engine + Skia
        v
GLES2 -> vitaGL -> sceGxm
        v
PowerVR SGX543MP4+
```

## Status

Flutter applications run on real hardware. Route transitions run at 60 frames
each second. There is no hot reload, and there will be none. A list that builds
again in each frame is too slow.

| | |
|---|---|
| Flutter version | 3.44.8. This version is fixed. |
| Consoles | PS Vita 1000 and PS Vita 2000, with HENkaku |
| Kernel plugin | **Not necessary.** No taiHEN, no card change, no VitaShell. |
| Hot reload | No. This port uses AOT only. See [No hot reload](#no-hot-reload). |
| Renderer | Skia on GLES2, through vitaGL. A software renderer is also available, but it is 6 to 18 times more slow. |

One person made this port. That is the wrong number of people, and this is why
the repository is now open. There are sharp edges. We write them down. We do not
hide them.

## What you must have

- A PS Vita with HENkaku. Connect it to the same network as your computer.
- [VitaSDK](https://vitasdk.org). Put its location in `$VITASDK`.
- Flutter 3.44.8. Do not use a different version. The engine is fixed to
  prebuilt 32-bit ARM binaries, and the framework must agree with them.
- macOS or Linux. Windows is not available yet.

## How to start

Get the repository and apply the patches:

```bash
git clone https://github.com/resashkin/flutter-vita
cd flutter-vita
./tools/apply-patches.sh --apply
```

Install the receiver on the console one time. After this, the network does
everything:

```bash
./tools/build-receiver.sh
./tools/install-vpk.sh receiver/app/build/vita/flutter_vita_receiver.vpk
```

Then use these commands:

```bash
flutter-vita doctor              # examine the toolchain and find the console
flutter-vita run apps/gallery    # build, install, start, and show the log
flutter-vita screenshot out.png  # get an image of the screen
flutter-vita tap 480 272         # send a touch event
```

The CLI operates from a source checkout. Installation with
`pub global activate` is the plan, but it is not available yet.

## How the loop operates

There is no debug cable and no file server. The **receiver** is a small Flutter
application. It stays on the console and holds a TCP port. All of these
operations go through it: installation, start, log collection, screenshots,
crash dumps, and touch events.

To install a title, the receiver calls `ScePromoterUtil`. This is a system
service, so a new title identifier costs no manual step and does not need
VitaShell.

The receiver cannot replace itself. The directory of a title that operates is a
read-only mount. Thus a second application of 50 KB does that write. It is
called the **updater**. It writes the new receiver, and then it gives the
console back.

A full installation of an application of 15 MB takes approximately 35 seconds.
A change to one line takes approximately 6 seconds.

## What is quick and what is slow

These are measurements from real hardware. There are 18 scenes. Use
`tools/bench.sh` to do them again.

| | |
|---|---|
| Route transitions | 60 frames each second. The median frame is 16.67 ms. |
| Backdrop blur | 100 ms for each frame. The rasteriser is the limit. |
| A list that builds again in each frame | 92.5 ms of Dart build, against 8.7 ms of raster |
| GPU against software | 18 times more quick for blur, 15 times for route transitions. The GPU is never more slow. |

The pattern is the same in most scenes. The GPU is quick enough, so the Dart
build is usually what you feel. Examine the build first, not the paint.

## What is not available

- **Hot reload.** This is permanent. See below.
- **Windows** as a host.
- Most plugins. `path_provider`, `shared_preferences`, `url_launcher` and a file
  picker have Vita implementations in `packages/`. Other plugins that use native
  code must be linked statically, because this platform has no `dlopen`.
- Audio.
- Code that needs 64 bits, or more than 512 MB of RAM.

### No hot reload

Hot reload needs a JIT. This port uses AOT only.

The usual explanation is not correct: the Vita **can** make pages executable,
and it does this with no kernel plugin. The true reasons are memory, and the
size of an engine in JIT mode. The console has 512 MB of RAM, and it shares that
RAM with the operating system.

You get a quick installation in its place. A change to code only takes
approximately 6 seconds, and the console goes back to your application without
help.

## Structure of the repository

| | |
|---|---|
| `cli/` | The `flutter-vita` command |
| `receiver/` | The receiver for the console, and the updater that replaces it |
| `templates/vita-app/` | The C entry point, the crash supervisor, and the CMake files. Each application is built from these. |
| `packages/` | Vita implementations of federated plugins |
| `apps/` | `conformance` measures what operates. `gallery` shows how it looks. |
| `patches/` | The Vita patch series for Dart, Skia, the engine, and vitaGL |
| `tools/` | Build, install, measure, and examine crashes |

## How to help

Please help. Read [CONTRIBUTING.md](CONTRIBUTING.md).

The most useful help is this: operate a Flutter application that we did not
write, and tell us what failed.

## Licence

BSD 3-Clause. Read [LICENSE](LICENSE). Read [NOTICE](NOTICE) for the components
that come from other projects.
