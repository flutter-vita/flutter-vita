# Wonderous: the assets fit, and it found a missing embedder API

Wonderous is the corpus's asset-weight axis under
[ADR-0012](../adr/0012-app-corpus-as-measurement-instrument.md): a finished
showcase app, deliberately heavy on imagery. The question was whether the bundle
even fits before anything runs.

## It fits

```
apps/corpus/wonderous/build/vita/wonders.vpk   58M
.text  17,566,002
```

51 MB of assets, including a 5.8 MB Chinese font, on a card with room to spare.
The welcome screen renders with its photographs, its custom display face and its
page indicator — no missing glyphs, no failed decodes.

## The pin had to move, and not for a Vita reason

`123f4749` cannot be built with Flutter 3.44.8 at all. It wants `intl ^0.17`
where `flutter_localizations` now requires 0.20.2, and past that it uses
`DecoderCallback` and `UnmodifiableUint8ListView` — both removed — plus a
`go_router` predating mixin classes. That is an app three years behind the SDK,
with nothing to say about this port, so the corpus follows upstream's own
Flutter 3.41.9 update at `747b945` instead. Recorded in the manifest with the
reason, because a pin that moves silently is not a pin.

## The finding: the embedder never told the framework a display exists

After the plugin registrations, wonderous still rendered nothing but grey:

```
Bad state: No element
#0  Iterable.first (dart:core/iterable.dart:663)
#1  AppLogic.display (package:wonders/logic/app_logic.dart:118)
#2  AppLogic.handleAppSizeChanged (package:wonders/logic/app_logic.dart:112)
#3  WondersAppScaffold.build (package:wonders/ui/app_scaffold.dart:14)
```

`PlatformDispatcher.instance.displays` was an **empty list**. The embedder sent
window metrics — how big the window is — and never called
`FlutterEngineNotifyDisplayUpdate`, which says what the window is attached to.
They are separate APIs answering separate questions, and this port had only ever
answered one of them.

Any app reading `displays.first` — for the refresh rate, or the physical size,
both ordinary things to want — got `Bad state: No element` out of dart:ui during
its first build. Because wonderous reads it from the widget wrapping the whole
app, the exception came out of MediaQuery's own callback and **nothing rendered
at all**, with the log blaming `Iterable.first`.

Fixed in the embedder: one display, `single_display`, 960x544, pixel ratio 1.0,
`refresh_rate` 60. Sixty is the panel's rate, deliberately, not the rate this
port achieves — an app asking what the display *does* should not be told what
the software is currently managing.

**This is the first corpus finding that changes the engine rather than the app**,
and it would not have come from the control: material_3_demo never asks.

## Score

| | |
|---|---|
| Patches | 1 |
| Lines added to the app | 16 |
| Engine changes required | 1 (`FlutterEngineNotifyDisplayUpdate`) |

The 16 lines are the ADR-0009 registrations for `path_provider` and
`shared_preferences` — the same edit keklist needed, in the same shape.
