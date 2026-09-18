# Configure the app for the console

A phone app expects a touch screen and a share sheet. The console has a
D-pad, two sticks, a rear touch panel and no other app to share with. The
`flutter_vita` package closes that gap from one call in `main()`.

## The call

```yaml
# pubspec.yaml
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
  await FlutterVita.configure(
    pad: PadMode.focus,           // D-pad and left stick move the focus
    rearTouch: RearTouch.scroll,  // the rear panel scrolls
    pixelRatio: 1.5,              // larger text and buttons
    fallbacks: {Fallback.share, Fallback.urlLauncher, Fallback.imagePicker},
  );
  runApp(const MyApp());
}
```

The package README lists each argument and its values:
[flutter_vita/README.md](https://github.com/flutter-vita/flutter-vita-packages/blob/master/flutter_vita/README.md).

On a desktop or a phone the call does nothing. Keep one `main`.

## What the call controls, and what the build controls

| Decided by `FlutterVita.configure` at run time | Decided by the build |
|---|---|
| Debug strip: shortcut, always, hidden | `--release`: no dev server, no debug strip |
| Keep awake, watchdog | The title id, the app name, the LiveArea assets |
| Pixel ratio | The heap size |
| Pad mode: none, focus, cursor | Which plugins are compiled in |
| Rear touch: none, scroll | |
| CPU clock: normal, high | |
| What `SystemNavigator.pop()` does | |
| The PS button: system, locked | |
| Fallbacks for share_plus, url_launcher, image_picker | |

The build side is in [release-app.md](release-app.md).

## See it work

The gallery has a CONFIGURE tab. Each control on it sends one
`configure` call and the card at the top shows the console's answer to
`FlutterVita.info()`: the clocks, the pixel ratio, the strip mode.

```bash
./tools/deploy.sh samples/gallery
```

Open CONFIGURE on the rail. Move the pixel ratio slider: the whole app
relayouts. Set the pad to `focus`: the D-pad moves a focus ring over the
controls and X presses. Set the rear touch to `scroll` and move a finger on
the back of the console over a list.

The log shows each call:

```
flutter-vita: channel vita/config [48] {"method":"configure","args":{"pixelRatio":1.5}}
flutter-vita: pixel ratio 1.50 (640x362 logical)
flutter-vita: configured: strip 2 awake 1 watchdog -1 ratio 1.50 cursor 0 rear 0 exit 0 bounce 3
```

## Fallbacks

A fallback answers a plugin's channel in Dart, inside the app. The embedder
passes the channel's messages up to the package (the *bounce*), the package
does the nearest thing the console can do, and the plugin gets the result
it expects.

| Plugin | On a phone | On the console with the fallback |
|---|---|---|
| `share_plus` | The share sheet | The text or the files are written to `ux0:data/<title id>/shared/`. A toast says where. |
| `url_launcher` | The browser or the mail app | `http(s)` opens the console's browser. `mailto`, `tel`, `sms` show the address with a Copy button. |
| `image_picker` | The photo library | The file browser over `ux0:picture/` or `ux0:video/`. |

An app with `url_launcher_vita` in its pubspec does not need the
`urlLauncher` fallback. The Vita implementation answers first.

## Older embedders

An app built before embedder 0.2.0 has no `vita/config` channel. The
package gets `MissingPluginException` and does nothing. Rebuild the app
with the current tool.
