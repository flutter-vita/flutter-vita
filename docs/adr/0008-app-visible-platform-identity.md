# ADR-0008: How an app learns it is running on a Vita

**Status:** Accepted — Option A, with Option B as the named revisit
**Date:** 2026-08-14

## Context

The goal was refined on 2026-08-14: a developer opts their app in to Vita by
editing `pubspec.yaml` and, optionally, depending on a `psvita` package. That
makes "the Vita is reachable as an OS from inside the app" an explicit
requirement rather than a nice-to-have.

Today it is not reachable at all, and deliberately so.
[The Dart patch](https://github.com/flutter-vita/dart-sdk/commits/vita-3.44.8)
sets `kHostOperatingSystemName` to `"linux"`, because `defaultTargetPlatform`
in `packages/flutter/lib/src/foundation/_platform_io.dart` is an if-chain over
`Platform.isAndroid` / `isIOS` / `isFuchsia` / `isLinux` / `isMacOS` /
`isWindows` that **throws when none match**:

    Unhandled Exception: Unknown platform.
    #0  defaultTargetPlatform (_platform_io.dart:39)
    ...
    #16 runApp (binding.dart:1884)

That fires inside `FocusManager`, before the first frame. With an honest
`"vita"` and a stock framework, no Flutter app starts. The lie is load-bearing.

The question is what to do about it, and the answer turns out not to hinge on
honesty.

## Options, measured

Numbers are from Flutter 3.44.8 on 2026-08-14.

| | Patches the **framework**? | Ecosystem breakage | Sites to fix |
|---|---|---|---|
| **A** — keep `"linux"`, expose the truth through `psvita` | no | none | 0 |
| **B** — VM reports `"vita"`; one-line map in `_platform_io.dart` to `TargetPlatform.linux` | **yes** | none | 1 |
| **C** — add `TargetPlatform.vita` | **yes** | 8 of 408 packages | 132 + every app |

### What C actually costs

`TargetPlatform` is switched over **752 times across 52 files** in the
framework — 126 switch statements and 6 switch expressions.

Adding an enum value is not a warning in Dart 3. Verified by compiling a
reduced case:

```
error - non_exhaustive_switch_statement  ... doesn't match the pattern 'Platform.vita'
error - non_exhaustive_switch_expression ... doesn't match the pattern 'Platform.vita'
```

Both shapes are hard compile errors. The framework's 132 sites are findable and
fixable — the compiler enumerates them — but **third-party packages are not
ours to fix.** Grepping an ordinary 408-package pub cache, 8 packages switch on
`TargetPlatform` with no `default:` and would fail to compile against a patched
framework: `adaptive_dialog`, `bottom_sheet`, `calendar_date_picker2`,
`macos_ui`, `modal_bottom_sheet`, `settings_ui`, `swipeable_page_route`,
`webview_flutter_wkwebview`. About 2%, and the developer would have to fork each
one.

Flutter classified this exact change as breaking when it
[added `linux` and `windows`](https://docs.flutter.dev/release/breaking-changes/target-platform-linux-windows) —
and at the time it produced only a `missing_enum_constant_in_switch` **warning**.
Dart 3 promoted it to an error. **Doing this now is strictly worse than when
Google did it.**

### The cost B and C share, which is the one that decides

This project patches four trees: `abseil`, `dart-sdk`, `flutter-engine`,
`skia`. **A developer installs none of them.** They download a 20 MB engine
artifact and use their own stock Flutter SDK.

`_platform_io.dart` lives *inside that SDK*. Both B and C therefore convert
flutter-vita from *"works with your Flutter"* into *"install our Flutter
fork"* — and inherit every consequence: a fork per Flutter release, a second
thing to keep in version lockstep on top of the engine artifact
([the coupling already recorded in the ADR index](README.md)), and an install
step that no longer looks like adding a package.

With adoption as the stated audience, that is a larger tax than an inaccurate
`Platform.operatingSystem`.

### What every other third-party platform does

The enum's complete contents, unchanged: `android`, `fuchsia`, `iOS`, `linux`,
`macOS`, `windows`. **Six values, all Google-shipped. No third-party platform
has ever been added** — not Tizen, not OpenHarmony, not embedded Linux, not
flutter-pi.

Samsung's [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen) is
the strongest precedent available: funded, maintained, and shipping the Tizen
10 home screen. It describes itself as *"an extension to the Flutter SDK"* and
does not fork the framework.

## Decision

**Option A.** `Platform.operatingSystem` continues to report `"linux"`. The
`psvita` package exposes the truth — `Vita.isVita`, plus device details — over
a platform channel the embedder already owns.

`TargetPlatform.linux` is also the correct *behavioural* answer independently
of the cost argument: it selects desktop text-editing shortcuts, desktop
scrollbars, and no mobile overscroll glow, which is right for a handheld with
physical buttons and no mobile OS. flutter-pi and flutter-elinux report linux
for the same reason.

> **Amended 2026-08-19.** That paragraph was asserted, not measured, and most
> of it does not survive being checked — see
> [platform-identity-options.md](../platform-identity-options.md), which prices
> all six candidates instead of only linux against `vita`. In short: paths and
> fonts do not route through the identity at all (`path_provider_vita` and
> `platform_vita.cc` handle both), and "desktop text-editing shortcuts" are
> unreachable input, because [ADR-0010](0010-input-layering-and-psvita-api.md)
> synthesizes arrows and scroll but no modifier keys. Android and linux differ
> in **43 of 93** exhaustive switches, and the Linux identity has already cost
> one test apps patch — localsend's `checkPlatformIsDesktop()` returned true,
> `window_manager` threw during `preInit`, and the app never reached `runApp`.
>
> **The decision is unchanged**, but the surviving reason is different: the
> Android ecosystem assumes a plugin host and its branches lead to
> MethodChannels we do not implement, whereas Linux branches usually lead to
> pure Dart, which [ADR-0009](0009-plugins-via-non-endorsed-vita-implementations.md)
> is built to substitute.

**`psvita` is a pure-Dart package, not a plugin.** It talks over
`MethodChannel('vita/gamepad')` and friends to an embedder we control, so it
needs no registrant, no plugin resolution, and does not collide with
[ADR-0004](0004-static-single-binary.md)'s single static ELF. This is what
makes "we can ship without it" true: the toolchain works before `psvita`
exists, and `psvita` can land without any plugin infrastructure.

## Consequences

- **`Platform.operatingSystem` lies to application code.** Anything branching
  on it takes the Linux path, including packages that reach for `/proc` or
  `/sys` and will find nothing. This is a real defect, accepted knowingly.
- Apps cannot write `if (Platform.isVita)`. They write
  `if (Vita.isVita)` after depending on `psvita`, which is consistent with the
  opt-in model — they are already editing `pubspec.yaml`.
- Anything keyed on `defaultTargetPlatform` gets desktop behaviour. Where that
  is wrong for a handheld, the fix is a widget-level override in `psvita`, not
  a platform identity change.
- We keep the property that a developer uses **their own stock Flutter SDK**.
  This is worth defending; it is the difference between adding a dependency and
  installing a fork.

## Revisit trigger

Adopt **Option B** — not C — if the test apps turns up a real app that cannot
work under the Linux identity and cannot be fixed from `psvita`. B is one line
and breaks nothing in the ecosystem; its only cost is the forked SDK, which at
that point would have been shown to be worth paying.

Revisit C only if Flutter upstream accepts a `TargetPlatform` value for Vita,
which would make it the ecosystem's problem to absorb rather than ours to
inflict.

## Related

- [ADR-0004](0004-static-single-binary.md) — why `psvita` being a plugin would hurt
- [ADR-0009](0009-plugins-via-non-endorsed-vita-implementations.md) — the same opt-in model, applied to third-party plugins
