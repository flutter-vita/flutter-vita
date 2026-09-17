# Develop a plugin

A plugin with native code needs a Vita half. This page is how one is
written: a Dart package with a `vita/` directory holding a C file and a
CMake fragment, compiled into every app that depends on the package. The
model is [ADR-0009](adr/0009-plugins-via-non-endorsed-vita-implementations.md)
(a non-endorsed platform implementation, the way `foo_linux` sits beside
`foo`) and [ADR-0020](adr/0020-native-halves-inside-vita-packages.md) (the
C half inside the package). Every package in [`plugins/`](../plugins) is
an example; `battery_plus_vita` is the smallest. A new implementation of
an upstream plugin goes there; a package with an API of its own goes to
[flutter-vita/packages](https://github.com/flutter-vita/packages).

## Why not FFI or a shared library

The console has no `dlopen`. Every app is one statically linked ELF, so a
plugin's native code has to be compiled into the app at build time
([ADR-0013](adr/0013-ffi-needs-static-linking.md)). `dart:ffi` works for
symbols already in the binary, but the platform-channel route below is
what the packages use: one C function per plugin, no bindings to generate.

## The layout

```
my_plugin_vita/
  pubspec.yaml
  lib/
    my_plugin_vita.dart      the Dart half: a MethodChannel and registerWith()
  vita/
    plugin.cmake             names the C sources and the Sony stubs to link
    my_plugin.c              the C half: one handler, registered from a constructor
```

`tools/build-vita-app.sh` reads the app's `.dart_tool/package_config.json`,
finds every resolved package with a `vita/plugin.cmake`, and includes it
into the app's CMake project. The build prints the list.

## The C half

`vita/plugin.cmake`:

```cmake
list(APPEND PLUGIN_SOURCES ${CMAKE_CURRENT_LIST_DIR}/my_plugin.c)
list(APPEND PLUGIN_LIBS ScePower_stub)     # the Sony stubs the C calls
```

`vita/my_plugin.c`:

```c
#include <fvita_plugin.h>
#include <psp2/power.h>
#include <string.h>

static int handle(const char* method, const char* body, size_t len,
                  char* out, size_t cap) {
  if (strcmp(method, "status") != 0) {
    return fvita_reply_err(out, cap, "unknown", method, 0);
  }
  return fvita_reply_ok(out, cap, "{\"level\":%d,\"charging\":%s}",
                        scePowerGetBatteryLifePercent(),
                        scePowerIsBatteryCharging() ? "true" : "false");
}

__attribute__((constructor)) static void reg(void) {
  fvita_channel_register("vita/my_plugin", handle);
}
```

That is the whole of it. The rules:

- **One channel per plugin, named `vita/<name>`.** The embedder hands every
  `vita/...` channel it does not answer itself to the registry, which finds
  your handler. At most 32 channels in an app.
- **The codec is JSON.** `body` is the JSON the Dart side sent as arguments;
  `fvita_json_int`, `fvita_json_num` and `fvita_json_str` pull a value by
  key. The reply is JSONMethodCodec's envelope: `fvita_reply_ok` writes
  `[result]`, `fvita_reply_err` writes `[code, message, details]`, which
  Dart sees as a `PlatformException`.
- **A handler runs on its own thread with a 15 s deadline**, so it may
  block (a camera frame, a second of audio); two calls asked for together
  run together. A call that outlives the deadline is answered with an error
  and abandoned.
- **The reply buffer is 256 KB.** A plugin that needs more (a camera frame
  in base64) asks with `fvita_channel_reply_cap` from its constructor.
- **A thread you create, you delete.** `fvita_thread_delete` and
  `fvita_thread_exit_delete` in `fvita_plugin.h`; a thread that only ends
  stays allocated, and the kernel's limit arrives within minutes.

`templates/vita-app/fvita_plugin.h` documents each function.

## The Dart half

```dart
import 'package:flutter/services.dart';
import 'package:my_plugin_platform_interface/my_plugin_platform_interface.dart';

class MyPluginVita extends MyPluginPlatform {
  static void registerWith() {
    MyPluginPlatform.instance = MyPluginVita();
  }

  static const _channel = MethodChannel('vita/my_plugin', JSONMethodCodec());

  @override
  Future<int> level() async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('status');
    return r!['level'] as int;
  }
}
```

The app depends on both packages and calls `MyPluginVita.registerWith()`
before `runApp`. The federated plugin's `pubspec.yaml` does not know the
Vita exists, so there is no `implements:` entry to make and nothing to
send upstream; the `_vita` package sits beside the plugin the way the app
author's other platform packages do.

## Trying it

```sh
flutter-vita run samples/gallery
```

The gallery's HARDWARE tab drives the packages in `plugins/` through the
pub API an app author would use, and reports what each answered. Add your
plugin to its `pubspec.yaml` and a row to the tab, and the console tells
you whether the C half links, registers and answers. The log shows the
first ten messages on each `vita/...` channel and one in a hundred after.

## What the console offers

The `psp2/` headers in VitaSDK are the surface: `scePower`, `sceCtrl`,
`sceTouch`, `sceMotion`, `sceCamera`, `sceAudioOut` and `sceAudiodec`,
`sceAvPlayer`, `sceNet`, `sceIo`, the common dialogs. Two things a plugin
author meets early:

- **Audio** has one main port at 48 kHz and one BGM port at any rate;
  `audioplayers_vita` owns both and is the place to add a format.
- **Anything that needs the kernel** (CPU temperature, other processes,
  plugins under taiHEN) is out: this port runs as an ordinary user-mode
  app ([ADR-0011](adr/0011-crash-recovery-without-taihen.md)).
