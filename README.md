# flutter-vita

Flutter, running on a PlayStation Vita.

Not an emulator layer and not a reimplementation: the real Flutter engine and
the real framework, compiled for `arm-vita-eabi` and drawing through the Vita's
GPU. Your `main.dart` is the one Flutter compiles anywhere else.

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

Flutter apps run on real hardware. Route transitions hold 60 fps. There is no
hot reload and there will not be, and a list rebuilding every frame will not
keep up.

| | |
|---|---|
| Flutter | 3.44.8, pinned |
| Runs on | PS Vita 1000 and 2000, firmware with HENkaku |
| Needs a kernel plugin | **No.** No taiHEN, no card swap, no VitaShell in the loop |
| Hot reload | No. AOT only — see [why](#no-hot-reload) |
| Renderer | Skia on GLES2 via vitaGL. Software fallback exists and is 6-18x slower |

This is a port under construction by one person, and it is being opened up
because that is the wrong number of people for it. Expect sharp edges and
expect them to be documented rather than hidden.

## What you need

- A PS Vita with HENkaku, on the same network as your machine
- [VitaSDK](https://vitasdk.org), on `$VITASDK`
- Flutter 3.44.8 exactly. Other versions will not link — the engine is pinned
  to prebuilt 32-bit ARM binaries and the framework has to match
- macOS or Linux. Windows is intended and not yet done

## Getting started

```bash
git clone https://github.com/resashkin/flutter-vita
cd flutter-vita
./tools/apply-patches.sh --apply
```

Then install the receiver on the console once, and after that everything goes
over the network:

```bash
./tools/build-receiver.sh
./tools/install-vpk.sh receiver/app/build/vita/flutter_vita_receiver.vpk
```

From there:

```bash
flutter-vita doctor              # check the toolchain, find the console
flutter-vita run apps/gallery    # build, install, launch, follow the log
flutter-vita screenshot out.png  # what is on the screen right now
flutter-vita tap 480 272         # inject a pointer event
```

The CLI runs from a checkout today. `pub global activate` is the intended
distribution and is not there yet.

## How the loop works

There is no debugger cable and no file server. The **receiver** is a small
Flutter app that sits on the console holding a TCP port, and everything —
installing, launching, log pulling, screenshots, crash dumps, touch injection —
goes through it.

Installing a title needs `ScePromoterUtil`, a system service, so a fresh title
id costs no manual step and no VitaShell. Replacing the *receiver* is the one
thing the receiver cannot do, because a running title's own directory is a
read-only mount; a 50 KB **updater** app does that write and hands the console
back.

A full deploy of a 15 MB app takes about 35 seconds. A one-line change takes
about six.

## What is fast and what is not

Measured on hardware, 18 scenes, `tools/bench.sh`.

| | |
|---|---|
| Route transitions | 60 fps, median 16.67 ms |
| Backdrop blur | 100 ms per frame. The rasteriser is the constraint |
| A list rebuilding every frame | 92.5 ms of Dart build against 8.7 ms of raster |
| GPU against software | 18x on blur, 15x on route transitions, never slower |

The pattern: the GPU path is fast enough that Dart build cost is usually what
you feel. Profile the build, not the paint.

## What is missing

- **Hot reload**, permanently. See below
- **Windows** host support
- Plugins, mostly. `path_provider`, `shared_preferences`, `url_launcher` and a
  file picker have Vita implementations in `packages/`; anything else that
  touches native code needs static linking, because this platform has no
  `dlopen` at all
- Audio
- Anything assuming 64-bit, or more than 512 MB of RAM

### No hot reload

Hot reload needs a JIT, and this is an AOT-only port. The Vita can in fact map
executable pages without a kernel plugin, so the usual reason given is wrong —
the real reasons are memory and the size of a JIT-mode engine on a console with
512 MB of RAM shared with the OS.

What you get instead is a fast deploy: about six seconds for a code-only change,
and the console returns to your app on its own.

## Repository layout

| | |
|---|---|
| `cli/` | The `flutter-vita` command |
| `receiver/` | The on-device receiver, and the updater that replaces it |
| `templates/vita-app/` | The C entrypoint, crash supervisor and CMake every app is built from |
| `packages/` | Vita implementations of federated plugins |
| `apps/` | `conformance` measures what works; `gallery` is what it looks like |
| `patches/` | The Vita patch series against Dart, Skia, the engine and vitaGL |
| `tools/` | Build, deploy, benchmark, crash analysis |

## Contributing

Yes, please. See [CONTRIBUTING.md](CONTRIBUTING.md). The most useful thing you
can do is run a Flutter app that is not ours and tell us what broke.

## Licence

BSD 3-Clause. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for the vendored
components.
