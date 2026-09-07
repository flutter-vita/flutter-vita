# ADR-0010: Input arrives in two layers, and only the second one is a package

**Status:** Accepted
**Date:** 2026-08-14

## Context

[ADR-0008](0008-app-visible-platform-identity.md) settled that `psvita` is a
pure-Dart package over channels the embedder owns, and that it is optional —
the toolchain works before it exists. It did not say what is in it.

The obvious framing was "Flutter has no gamepad concept, so everything about
buttons goes in `psvita`". That framing is wrong, and checking it was the most
useful thing this design did.

## What Flutter already has

Flutter built a complete gamepad-navigation path for Android TV. It is
platform-neutral and it is sitting unused in the framework we already ship.

From `WidgetsApp.defaultShortcuts` in 3.44.8:

| Logical key | Already wired to |
|---|---|
| `arrowUp` / `arrowDown` / `arrowLeft` / `arrowRight` | `DirectionalFocusIntent` — focus traversal |
| `gameButtonA` | `ActivateIntent` — press the focused widget |
| `enter`, `space` | `ActivateIntent` |
| `escape` | `DismissIntent` — close dialogs and routes |

`LogicalKeyboardKey` defines 124 `gameButton*` constants. And our `embedder.h`
already exports `FlutterEngineSendKeyEvent` with a `FlutterKeyEventDeviceType`
enum containing `kFlutterKeyEventDeviceTypeDirectionalPad` and
`kFlutterKeyEventDeviceTypeGamepad`.

**So an unmodified Flutter app is already navigable by D-pad — it just has to
be told the D-pad was pressed.** Nothing about that requires a package, and
routing it through one would make basic navigation opt-in for no reason.

The hardware, from `psp2common/ctrl.h`: 16 buttons in a `buttons` bitfield,
two analog sticks as `lx`/`ly`/`rx`/`ry` bytes, and per-button analog pressure.
`SCE_TOUCH_PORT_BACK` is the rear panel; `sceMotionGetSensorState` is the IMU.

## Decision

**Two layers, split on whether Flutter already has a concept for the thing.**

### Layer 1 — the embedder. No package, no opt-in, unmodified apps benefit.

| Vita | Sent as |
|---|---|
| D-pad | `arrowUp` / `arrowDown` / `arrowLeft` / `arrowRight`, device type `DirectionalPad` |
| enter button | `gameButtonA` → `ActivateIntent` |
| cancel button | `escape` → `DismissIntent` |
| ✱ / △ / L / R / Select / Start | `gameButton*`, unmapped by default |
| left stick | synthesized pointer **scroll** events |
| front touch | `FlutterPointerEvent`, as today |

**Which button is "enter" is read from the console, not hardcoded.**
`sceAppUtilSystemParamGetInt(SCE_SYSTEM_PARAM_ID_ENTER_BUTTON)` reports the
system-wide assignment — ✕ on Western consoles, ○ on Japanese ones. Every other
app on the device honours it; an app that does not gets muscle memory exactly
backwards. One API call at startup, and it is the only choice that is right in
both regions.

**The left stick scrolls** rather than moving focus or a cursor. Scrollables are
most of what a real app is, and the D-pad already handles focus — so the two are
complementary instead of competing for the same job. A cursor would fight
Flutter's touch-first hit testing and would have to be drawn by us.

### Layer 2 — the `psvita` package. Only what Flutter has no concept of.

Raw button and stick state, rear touch, motion, device info, and runtime
configuration of layer 1.

**The rear touch panel is exposed raw and synthesizes nothing.** It is a second
touch surface with no visual feedback, held against the fingers gripping the
console. Mapping it to scroll or to a second pointer means unmodified apps get
phantom input from the hand holding the device — which is why Sony's own UI does
not do it either. Games can opt in.

**Shaped like the packages a Flutter developer already knows** — broadcast
streams in the manner of `sensors_plus`, plus a synchronous snapshot for game
loops that want to poll once per frame rather than rebuild on a stream.

```dart
abstract final class Vita {
  /// The honest answer ADR-0008 owes applications, since
  /// Platform.operatingSystem reports "linux".
  static bool get isVita;
  static Future<VitaDeviceInfo> get deviceInfo;

  static Stream<GamepadState> get gamepad;
  static Stream<AccelerometerEvent> get accelerometer;
  static Stream<GyroscopeEvent> get gyroscope;
  static Stream<RearTouchEvent> get rearTouch;

  /// Snapshot for per-frame polling. Mirrors how sceCtrlPeekBufferPositive
  /// actually works, rather than pretending the hardware pushes.
  static GamepadState get state;

  /// Turn layer 1 off. A game driving its own input wants the raw buttons
  /// without arrow keys arriving behind its back.
  static Future<void> configure({
    bool? dpadNavigation,
    bool? stickScrolling,
  });
}
```

## Consequences

- **Layer 1 is the cheap half and ships first.** Key and scroll synthesis are
  plain C structs through `FlutterEngineSendKeyEvent` and
  `FlutterEngineSendPointerEvent`. Layer 2 needs `StandardMethodCodec` encoded
  by hand in C, which is the larger piece of work — so the split is also the
  shipping order.
- Navigation works in apps that have never heard of this project. That is the
  single largest thing available for the "run real apps" goal, and it costs no
  dependency.
- **Layer 1 can be wrong in a way the app cannot see.** Synthesized arrow keys
  are indistinguishable from a real keyboard, so an app with its own arrow-key
  handling will receive D-pad presses it did not ask for. `configure()` is the
  escape hatch, and it exists because of this rather than as a convenience.
- Analog sticks have no non-synthetic representation. Scroll events are a lossy
  encoding of a continuous axis; anything wanting the axis must use `psvita`.
- The stick-scroll mapping needs a deadzone and a response curve, and both are
  guesses until they are tried on hardware. Expect to tune them.

## Revisit trigger

Revisit the layer-1 defaults if the test apps shows real apps fighting them —
the failure mode is an app that handles arrow keys itself and now behaves oddly.
If that turns out to be common rather than rare, the default flips to off and
navigation becomes opt-in through the `vita:` block.

## Related

- [ADR-0008](0008-app-visible-platform-identity.md) — why `psvita` is pure Dart and optional
- [ADR-0009](0009-plugins-via-non-endorsed-vita-implementations.md) — the `pubspec.yaml` opt-in surface
