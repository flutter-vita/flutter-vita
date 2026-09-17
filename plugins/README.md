# Plugins

Vita implementations of pub packages, one directory each. A package here
has a Dart half and, under `vita/`, a C half that `tools/build-vita-app.sh`
compiles into every app that depends on it
([ADR-0020](../docs/adr/0020-native-halves-inside-vita-packages.md)). An app
adds the `_vita` package beside the plugin and calls its `registerWith()`
before `runApp` ([ADR-0009](../docs/adr/0009-plugins-via-non-endorsed-vita-implementations.md)).
[Develop a plugin](../docs/develop-plugin.md) is how to write one.

| Package | Implements | Console API |
|---|---|---|
| `audioplayers_vita` | `audioplayers` | WAV on the main port, AAC through sceAvPlayer, MP3 through sceAudiodec, on the BGM port |
| `battery_plus_vita` | `battery_plus` | ScePower |
| `camera_vita` | `camera` | SceCamera |
| `connectivity_plus_vita` | `connectivity_plus` | SceNetCtl |
| `device_info_plus_vita` | `device_info_plus` | ScePower, SceKernel, SceAppMgr |
| `file_picker_vita` | `file_picker` | A browser drawn in Flutter (`vita_file_browser`); the console has no file dialog |
| `file_selector_vita` | `file_selector` | The same browser |
| `path_provider_vita` | `path_provider` | Dart only: `ux0:data/<title id>/` and the app's own directories |
| `record_vita` | `record` | SceAudioIn, to a WAV file |
| `sensors_plus_vita` | `sensors_plus` | SceMotion |
| `shared_preferences_vita` | `shared_preferences` | Dart only: a file under the app's data directory |
| `url_launcher_vita` | `url_launcher` | The embedder's `vita/browser` channel: the console's browser |
| `vita_debug_strip` | (its own) | The strip of live numbers as a widget, for an app that wants the UI thread's time on screen |
| `vita_file_browser` | (its own) | The file browser the pickers use |

These are path dependencies today. Publishing them to pub.dev is planned;
the names stay.
