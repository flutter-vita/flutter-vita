# Limitations

What this port does not do, and whether that is a decision or a gap.

## No hot reload

Permanent. Hot reload needs a JIT and this port is AOT only. The console
can make pages executable without a kernel plugin, so that is not the
reason; memory is. The console has 512 MB shared with the operating
system, an app gets 256 MB of it, and a JIT-mode engine with the Dart
compiler in it does not fit beside an app worth reloading.
[ADR-0001](adr/0001-aot-only-no-jit.md) has the numbers.

What you get instead: a rebuild after a one-line change takes about six
seconds plus the install, and the console comes back to your app on its
own. The loop is `flutter-vita run`, look, edit, `flutter-vita run`.

## Fonts

The console has no system fonts an app can reach. `Roboto` and `Roboto
Mono` are in every app; anything else, emoji included, is declared under
`fonts:` in `pubspec.yaml`, as on every other Flutter target. Roboto stops
at U+FFFD, so an emoji without a font draws an empty box.

Name an emoji font in `fontFamilyFallback`. If you give `ThemeData` your own
`textTheme`, name it there too, with `textTheme.apply(fontFamilyFallback:
[...])`. The console reports its OS as `linux`, and Flutter's Linux text
styles bring their own fallback list, which replaces yours
([details](roadmap-capabilities.md#fonts-what-the-console-has-and-how-an-app-gets-emoji)).

## Plugins

A plugin with native code needs a Vita implementation. The ones in
[`plugins/`](../plugins) cover `path_provider`, `shared_preferences`,
`url_launcher`, `battery_plus`, `sensors_plus`, `device_info_plus`,
`connectivity_plus`, `audioplayers`, `record`, `camera`, `file_picker` and
`file_selector`. Any other plugin with native code fails at link time or
at its first call; [Develop a plugin](develop-plugin.md) says what writing
one costs (a C file, usually short). Pure-Dart packages work as they are.

There is no `dlopen`, so a plugin cannot arrive as a shared library and
`dart:ffi` reaches only what is linked into the app
([ADR-0013](adr/0013-ffi-needs-static-linking.md)).

## Memory

- 256 MB of main memory for the app, and 112 MB of GPU memory. The Dart
  heap, the C heap (160 MB reserved at start) and the engine's own use all
  come out of the 256. The debug strip shows both budgets live.
- 32-bit ARM. Code that needs 64-bit pointers, or more address space than
  that, does not run.

## Platform

- **Windows** as a host is not supported. macOS is where the port is built;
  Linux should work and is untested end to end.
- **Vita3K**, the emulator, is not a target
  ([why](vita3k-as-a-target.md)). Real hardware only.
- **Vita TV (PS TV)** is untested.
- The app sees itself as Linux (`Platform.isLinux`, `TargetPlatform.linux`).
  Code that branches on the platform gets the desktop branch; an app that
  refuses to run on desktop needs a patch
  ([ADR-0008](adr/0008-app-visible-platform-identity.md) and
  [the measurement behind it](platform-identity-options.md)).

## Rendering

- Skia on GLES2, through this project's own GLES2 layer over the console's
  `sceGxm`. The layer covers what Skia asks for; a call it does not have yet
  is logged as `unimplemented:` and the app carries on without it.
  [gles2-progress.md](gles2-progress.md) tracks the coverage.
- Impeller is not available ([ADR-0002](adr/0002-skia-not-impeller.md)).
- Video has no picture yet: the engine has no external-texture route, so a
  video player plays the sound and shows nothing.
- A screen that renders every frame at 960x544 with a backdrop blur costs
  about 100 ms a frame. [Writing Flutter that runs on a
  Vita](writing-flutter-that-runs-on-a-vita.md) lists what the benchmarks
  found and what to do instead.

## Tooling

- No DevTools, no observatory, no CPU profiler
  ([why](the-profiler-we-do-not-have.md)). The debug strip, the log's
  `FRAMES` and `JANK` lines, and crash dumps with symbols are the
  instruments ([Debug an app](debug-app.md)).
- No `flutter test` on the device. Tests run on the host as usual.
- The CLI runs from a checkout; `pub global activate` is planned.
