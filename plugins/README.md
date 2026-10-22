# Plugins

Vita implementations of pub packages, one directory each. A package here
has a Dart half and a C half under `vita/`. `tools/build-vita-app.sh`
compiles the C half into each app that depends on the package
([ADR-0020](../docs/adr/0020-native-halves-inside-vita-packages.md)). An
app adds the `_vita` package beside the plugin in `pubspec.yaml`. The build
generates the plugin registrant from the package's
`platforms.vita.dartPluginClass`; the app calls nothing
([ADR-0009](../docs/adr/0009-plugins-via-non-endorsed-vita-implementations.md)).
[Develop a plugin](../docs/develop-plugin.md) shows how to write one.

| Package | Implements | Console API |
|---|---|---|
| `audioplayers_vita` | `audioplayers` | WAV on the main port, AAC through sceAvPlayer, MP3 through sceAudiodec, on the BGM port |
| `battery_plus_vita` | `battery_plus` | ScePower |
| `camera_vita` | `camera` | SceCamera |
| `connectivity_plus_vita` | `connectivity_plus` | SceNetCtl |
| `device_info_plus_vita` | `device_info_plus` | ScePower, SceKernel, SceAppMgr |
| `file_picker_vita` | `file_picker` | A browser drawn in Flutter (`vita_file_browser`, from [flutter-vita/flutter-vita-packages](https://github.com/flutter-vita/flutter-vita-packages)); the console has no file dialog |
| `file_selector_vita` | `file_selector` | The same browser |
| `path_provider_vita` | `path_provider` | Dart only: `ux0:data/<title id>/` and the app's own directories |
| `record_vita` | `record` | SceAudioIn, to a WAV file |
| `sensors_plus_vita` | `sensors_plus` | SceMotion |
| `shared_preferences_vita` | `shared_preferences` | Dart only: a file under the app's data directory |
| `url_launcher_vita` | `url_launcher` | The embedder's `vita/browser` channel: the console's browser |

An app outside this repository takes a package from git, with the tool's
release as `ref`. See
[Add the PS Vita to your app](../README.md#add-the-ps-vita-to-your-app). The
samples use path dependencies, `../../plugins/<name>`.

Two limits apply to `ref: 3.47.7-vita.1.0.3`. Later releases do not have
them:

- `file_picker_vita` and `file_selector_vita` do not resolve from git. They
  take `vita_file_browser` from the `packages/` submodule, and pub does not
  get submodules. Later releases take it from pub.dev.
- Do not add `path_provider_vita` beside `shared_preferences_vita`.
  `shared_preferences_vita` brings it, and pub refuses the second copy.

Publication to pub.dev is planned. The names stay.

The project's own packages, with an API of their own, are in
[flutter-vita/flutter-vita-packages](https://github.com/flutter-vita/flutter-vita-packages),
the `packages/` submodule: `flutter_vita` (the configurator, with Dart
fallbacks for `share_plus`, `url_launcher` and `image_picker`),
`vita_debug_strip` and `vita_file_browser`.
