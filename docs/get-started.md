# Get started

Before this page: the toolchain is installed
([macOS](install-macos.md), [Linux](install-linux.md)) and the receiver is on
the console ([Console setup](configure-console.md)). `flutter-vita doctor`
prints `ok` on every line and names the console.

## 1. Run the gallery

```sh
flutter-vita run samples/gallery
```

`run` builds the app into a `.vpk`, hands the console to the receiver if an
app is on screen, installs, launches, and prints the app's log as it comes.
The first build compiles the Dart of the app to an AOT snapshot and links it
with the engine; count on a minute. The install itself takes about 35
seconds for a 15 MB app.

The gallery is the port's own instrument: a strip of live numbers across
the top, tabs for widgets, tests, hardware checks and the settings of
`flutter_vita`. Tap around. When you are done, hold **L + R + START** for a
second: the console goes back to the receiver.

## 2. Run your own app

Any Flutter app directory works:

```sh
flutter-vita run ~/projects/my_app
```

Three things are worth knowing before the first run.

**The title id.** Every Vita title has a nine-character id. Without one in
`pubspec.yaml`, the app goes into the receiver's app slot, `FVTA00002`, and
replaces whatever was there. To give the app a slot of its own, add a
`vita:` block:

```yaml
vita:
  title_id: FVTA00003
  name: My App          # the LiveArea name; defaults to the package name
```

**Fonts.** The console has no system fonts your app can use. `Roboto` and
`Roboto Mono` ship with every app; anything else, emoji included, goes
under `fonts:` in `pubspec.yaml`, as on every other Flutter target. An app
that shows an emoji without a font for it draws an empty box.

**Plugins.** A plugin with native code needs a Vita implementation. The
ones in [`plugins/`](../plugins) cover `path_provider`,
`shared_preferences`, `url_launcher`, `battery_plus`, `sensors_plus`,
`device_info_plus`, `connectivity_plus`, `audioplayers`, `record`, `camera`
and file pickers; add the `_vita` package beside the plugin in
`pubspec.yaml`. The build registers it. Pure-Dart packages need nothing.
[Develop a plugin](develop-plugin.md) explains what a missing one costs.

## 3. Iterate

There is no hot reload on this port ([why](limitations.md#no-hot-reload)).
The loop is:

```sh
flutter-vita run ~/projects/my_app     # build, install, launch, log
flutter-vita screenshot out.png        # what the panel shows
flutter-vita tap 480 272               # press something from the host
flutter-vita logs                      # the log again, at any time
```

A rebuild after a one-line change takes about six seconds plus the
install. Every debug build carries a strip of live numbers over the top of
the screen, hidden and shown with **L + R + SELECT**; [Debug an
app](debug-app.md) explains each column, the log, and what to do with a
crash.

## 4. Ship

```sh
flutter-vita build ~/projects/my_app --release
```

The release build drops the dev server, the debug strip and the fallback
to the receiver. The `.vpk` under `build/vita/` is what your users install.
[Release an app](release-app.md) covers the LiveArea art and the notices.
