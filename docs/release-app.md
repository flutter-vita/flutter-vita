# Release an app

A release build is the same pipeline as a debug build with a different
final link. What you hand your users is one `.vpk`.

## 1. Build

```sh
flutter-vita build ~/projects/my_app --release
```

The `.vpk` lands in `~/projects/my_app/build/vita/`. Compared with the
default build, `--release` leaves out:

- the dev server (the socket on port 1339 that reads and writes the card;
  nothing a shipped app should carry),
- the debug strip,
- the fall-back to the bridge on `abort` and on a fault, and the UI-thread
  watchdog: a user's console has no bridge to fall back to,
- the crash supervisor.

The Dart side is the same in both: AOT, `dart.vm.product=true`, the bundle
built with `--release`. There is no JIT build to choose between.

## 2. The title id and the name

Pick a title id your app keeps. Nine characters, four letters and five
digits; the letters are yours to choose, and the id must not collide with
another homebrew title on the user's console. Put it in `pubspec.yaml`:

```yaml
vita:
  title_id: MYAP00001
  name: My App
```

A user who installs a new version over the old one keeps the app's data
under `ux0:data/` and its save data, as with any Vita title. Changing the
id makes a second app.

## 3. LiveArea art

The LiveArea bubble wants three PNGs, each an 8-bit indexed (palette)
image at a fixed size; the console refuses the install for anything else,
a 32-bit icon most of all:

| File | Size | Where it shows |
|---|---|---|
| `icon0.png` | 128 x 128 | The bubble on the home screen |
| `bg0.png` | 840 x 500 | The background of the open bubble |
| `startup.png` | 280 x 158 | The start button's image |

Every app ships the set in `templates/vita-app/livearea/` unless you
replace it. Put yours in a directory with those three names plus the
`template.xml` from the template's set, and name it in `pubspec.yaml`:

```yaml
vita:
  title_id: MYAP00001
  name: My App
  livearea: vita/livearea      # relative to the app
```

(or `--livearea DIR` on `tools/build-vita-app.sh`). The build checks the
three files with `tools/check-livearea-art.dart` and stops on a wrong size or
format. The default set is the flutter-vita mark
([docs/images/flutter-vita-mark.svg](images/flutter-vita-mark.svg)).

The shell takes the three files out of the package at the first install of a
title only. To see new art on a title that is already installed, delete the
title on the console and install it again.

## 4. The splash

From the start of the app to its first frame, the console shows a picture:
the splash. Without it the screen stays black for that time, which is 1.6 s
for localsend and 2.3 s for the gallery (measured 2026-10-29). Before that,
the system loads the app and the screen is not the app's: no picture can
cover that part.

Every app shows the template's splash, `templates/vita-app/splash.png`: the
flutter-vita mark, "Built with flutter-vita" and the address of the project.
Debug and release builds show it the same way. To show your own picture, or
none, name it in `pubspec.yaml`:

```yaml
vita:
  title_id: MYAP00001
  splash: vita/splash.png      # relative to the app; or none
```

(or `--splash PNG|none` on `tools/build-vita-app.sh`). With `none` the app
starts on a black screen.

- The screen is 960 x 544. A smaller picture shows in the centre, on the
  colour of its top-left pixel. The build refuses a larger one.
- Any 8-bit PNG works: RGB, RGBA, grey or indexed. Transparent pixels take
  the colour of the top-left pixel, or black when that pixel is transparent
  too. The build refuses 16-bit and interlaced PNGs.
- The splash goes away at the first frame. It never keeps the app waiting.
- The build packs the picture into `splash.bin` with
  `tools/splash-pack.dart`, because the console cannot decode a PNG before
  the engine starts. Large areas of one colour pack small: the template's
  splash is 42 KB, and a photo is about 2 MB. The embedder reads the file in
  about 30 ms.

The splash is not part of the LiveArea. The shell does not keep it, so a new
splash shows on the next install, with no delete first.

## 5. What the user needs

- A console with a homebrew enabler; the `.vpk` installs from VitaShell like
  any other.
- `ur0:data/libshacccg.suprx`, the shader compiler. Most consoles that run
  homebrew 3D already have it; say so on your download page. An app on a
  console without it starts and shows nothing.
- Nothing else: no runtime, no plugin, no second title.

## 6. Notices

The `.vpk` contains the Flutter engine, Skia, ICU, the Dart runtime and
the libraries they bring. Their licenses are BSD, MIT, Apache 2.0 and the
ICU license. You do not have to add their texts: `flutter build` puts them
into the `.vpk` as `flutter_assets/NOTICES.Z`, and `showLicensePage()` shows
them in the app (an About screen is a good place). The code of flutter-vita
is under the zlib licence, which asks nothing of your `.vpk`
([ADR-0023](adr/0023-our-code-is-under-the-zlib-licence.md)). Nothing in the binary is
LGPL: the GLES2 layer under Skia is this project's own
([ADR-0018](adr/0018-the-lgpl-obligation-in-every-vpk.md)), and the shader
compiler is Sony's module on the console, not in your `.vpk`.

## 7. Where to publish

VitaDB is where homebrew goes. Your entry wants the `.vpk`, the art, and a
line about the shader compiler.
