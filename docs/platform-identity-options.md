# Which operating system the Vita should claim to be

[ADR-0008](adr/0008-app-visible-platform-identity.md) decided this: report
`"linux"`. It compared that against **inventing a `vita` platform** and priced
the fork tax carefully. What it never did was compare `"linux"` against the
other five identities already in the enum — it asserted in one sentence that
linux is "the correct *behavioural* answer" and moved on.

This document is that missing comparison, measured. It does not overturn the
decision. It does show that the sentence justifying it is weaker than it reads,
and that the strongest argument for linux is not the one the ADR gives.

---

## What is actually being chosen

Three separate identities get confused with each other. Only one is in play.

| Identity | Where it lives | Value | Settled? |
|---|---|---|---|
| **Build target** | GN `target_os` | `vita` | Yes — never in question. It selects `platform_vita.cc`, `eventhandler_vita.cc`, the whole port |
| **VM label** | `kHostOperatingSystemName` in `runtime/platform/globals.h` | `"linux"` | **This is the question** |
| **Framework platform** | `defaultTargetPlatform` | `TargetPlatform.linux` | Derived from the VM label; not independently settable |

The third follows from the second with no freedom in between:

```dart
// packages/flutter/lib/src/foundation/_platform_io.dart
if (Platform.isAndroid) { result = TargetPlatform.android; }
else if (Platform.isIOS) { ... }
...
if (result == null) { throw FlutterError('Unknown platform.\n...'); }
```

and `Platform.isLinux` is nothing more than `operatingSystem == "linux"`.

## The mechanism is one string, and it has no other job

`kHostOperatingSystemName` is used in exactly two places in the whole VM:

```
runtime/bin/platform.h:32   static const char* OperatingSystem() { return kHostOperatingSystemName; }
runtime/vm/os.h:21          static const char* Name() { return kHostOperatingSystemName; }
```

plus one `PrintErr` in the profiler. **Nothing in the VM branches on it.** Every
actual behaviour — file operations, sockets, paths, threads — comes from the
`*_linux.cc` and `*_vita.cc` files chosen at build time by the GN target.

So changing this string changes nothing about how the port works. It changes
only what **Dart and Flutter code above it** decides to do. That makes this a
pure question about the ecosystem's assumptions, not about correctness of the
runtime.

## Why we cannot just say "vita"

Two independent reasons, and the second is the one that actually binds.

**1. A stock framework refuses to start.** With an honest `"vita"`, the if-chain
above falls through and throws `Unknown platform` inside `FocusManager`, before
the first frame. `debugDefaultTargetPlatformOverride` is ignored in release, and
this port only builds AOT release. No Flutter app starts at all.

**2. Fixing that means shipping a forked Flutter SDK.** `_platform_io.dart`
lives inside the SDK the *developer* installs, not in the 20 MB engine artifact
they download from us. Teaching it about Vita — even as a one-line map to
`TargetPlatform.linux` — turns "works with your Flutter" into "install our
Flutter fork", with a new fork required every release.

Adding a real `TargetPlatform.vita` is worse again. The framework's own source
says why, and also gives the recipe:

> When adding support for a new platform (e.g. Windows Phone, Raspberry Pi),
> first create a new value on the `TargetPlatform` enum, then add a rule for
> selecting that platform in `_platform_io.dart` and `_platform_web.dart`.
>
> It would be incorrect to make a platform that isn't supported by
> `TargetPlatform` default to the behavior of another platform, because doing
> that would mean we'd be stuck with that platform forever emulating the other,
> and we'd never be able to introduce dedicated behavior for that platform
> (since doing so would be a big breaking change).
>
> — `packages/flutter/lib/src/foundation/platform.dart`

Upstream is describing precisely what this port does, and calling it incorrect.
They are right in principle. The cost of being correct, measured on 3.44.8:

- **752 `case TargetPlatform.*` arms across 52 files.** A seventh enum value is
  a **hard compile error** at every exhaustive one — Dart 3 promoted
  `missing_enum_constant_in_switch` from a warning to an error, so this is
  strictly more expensive now than when Google themselves added `linux` and
  `windows` and classified it as a breaking change.
- **Third-party packages are not ours to fix.** 8 of 408 packages in an
  ordinary pub cache switch on `TargetPlatform` with no `default:`.
- No third-party platform has ever been added to this enum. Not Tizen, not
  OpenHarmony, not flutter-pi. Samsung's flutter-tizen is funded and shipping
  and still calls itself "an extension to the Flutter SDK".

So the honest identity is available, costs a framework fork plus an ecosystem
break, and buys nothing the `psvita` package cannot provide. That is ADR-0008's
Option C, and it stays rejected.

---

## The six candidates, priced

All six are reachable by changing one `#define`. What follows is what each one
would actually do.

| Identity | What it buys | What it costs | Verdict |
|---|---|---|---|
| **linux** *(current)* | No mobile overscroll glow; desktop text-editing shortcuts; `/proc`-shaped assumptions are at least *coherent* with our newlib layer | Apps read "desktop" as **has a window manager, tray, mouse, file dialog**. This already broke localsend | **Held**, but for weaker reasons than the ADR states |
| **android** | Capability inference is right: no window, no tray, touch-first, fullscreen. Overscroll glow suits touch scrolling | Packages reach for Android plugins and JNI; `/data/data` paths; every Android MethodChannel is missing | **The real contender** — see below |
| **fuchsia** | Sits **between** the two: agrees with android in 75 of 93 switches and with linux in 68, so it inherits mobile furniture without desktop capability inference. Almost no ecosystem baggage — nobody writes `if (Platform.isFuchsia)` special cases | Obscure to the point of being untestable; a package that *does* check it will guess wrong; zero prior art; and it is a lie about a Google OS rather than a lie about a family of them | Interesting, unserious — but see the pairwise table |
| **iOS** | Cupertino defaults; a handheld touch device is genuinely iOS-shaped | Pulls the entire Apple behaviour cluster (40 arms), plus packages assuming iOS platform channels, App Store APIs and Darwin paths | No |
| **macOS** | Desktop, like linux | Same desktop-inference problem as linux **plus** the Apple cluster. Strictly worse than linux | No |
| **windows** | Desktop, like linux | Same desktop problem, plus packages reaching for win32. Strictly worse than linux | No |

macOS and windows are dominated by linux — same downside, extra baggage. iOS is
dominated by android — same touch-shaped upside, far more Apple-specific
assumptions. That leaves **linux, android, and the curiosity of fuchsia.**

---

## linux vs android, measured

The framework does not split platforms one way. It splits them two ways, and
the two axes disagree about where a Vita belongs.

Grouping every arm of all 93 exhaustive switches by which platforms share it.

(93, where [ADR-0008](adr/0008-app-visible-platform-identity.md) counts 132
sites. Both are right and they count different things: the ADR counts every
site a `TargetPlatform.vita` would have to be added to, including switch
*expressions* and switches with a `default:`. The 93 here are switch statements
naming all six values, which are the ones that tell you what the framework
thinks the platforms have in common — the question this section is asking.)

| Arm | Count | What the axis is |
|---|---|---|
| `android + fuchsia + linux + windows` | **42** | Apple vs not |
| `iOS + macOS` | **40** | Apple vs not |
| `linux + macOS + windows` | **18** | **desktop** vs mobile |
| `android + fuchsia + iOS` | **15** | desktop vs **mobile** |
| `fuchsia + linux + macOS + windows` | 10 | desktop-ish |
| `android + iOS` | 9 | mobile |
| `android + fuchsia` | 8 | Android-family |

**Android and linux land in the same arm 50 times and different arms 43 times.**
So the choice is real, but it is a coin-flip in scope rather than a wholesale
change of behaviour — a little under half of everything that is keyed on
platform at all.

Pairwise agreement across those 93 switches, which is the clearest measure of
how far apart the candidates actually are:

| Pair | Agree | Differ |
|---|---|---|
| android ↔ fuchsia | **75** | 18 |
| fuchsia ↔ linux | **68** | 25 |
| android ↔ linux | 50 | **43** |
| android ↔ iOS | 31 | **62** |

Two things fall out of this. **Fuchsia is the midpoint** — closer to android
than linux is, and closer to linux than android is — which is what makes it a
real option rather than only a joke. And **the mobile axis is weaker than the
Apple axis**: android and iOS, the two "mobile" platforms, agree in only 31 of
93 switches. "Mobile behaviour" is not a thing the framework has; Apple
behaviour is.

### What actually differs

| Behaviour | Under **linux** | Under **android** | Which is right for a Vita? |
|---|---|---|---|
| Scrollbar (`scroll_configuration.dart:163`) | Every scrollable is wrapped in `RawScrollbar` | No scrollbar | **android.** A persistent desktop scrollbar on a 960×544 panel costs screen area *and* raster work on every scroll frame |
| Overscroll (`:181`) | Nothing | `GlowingOverscrollIndicator` | **linux**, narrowly — the glow is a radial gradient, and this is a software rasterizer |
| Haptics / click (`feedback.dart:93`) | No-op | `SystemSound.play` + `HapticFeedback.vibrate` | **linux.** The Vita has no rumble. Not fatal either way: `SystemChannels.platform` is an `OptionalMethodChannel`, so an unhandled call is swallowed — it costs a wasted platform message per tap, not a crash |
| Page transition | `ZoomPageTransitionsBuilder` | `PredictiveBackPageTransitionsBuilder`, which falls back to `FadeForwardsPageTransitionsBuilder` with no back gesture in progress | **Possibly android**, and worth measuring: a fade-and-slide should be cheaper in software than a scale-and-fade. Unmeasured. Either way an app can override it via `ThemeData.pageTransitionsTheme`, so this does not bind the decision |
| Text editing shortcuts | Desktop (Ctrl-based) | Mobile | **android.** [ADR-0010](adr/0010-input-layering-and-psvita-api.md) synthesizes arrow keys from the D-pad and scroll from the sticks — there are no modifier keys, so desktop shortcuts are unreachable input that cannot be typed |
| `Platform.isLinux` / `isAndroid` in package code | Packages take their Linux path | Packages take their Android path | **The whole argument.** See below |

### The evidence that already exists

This is not hypothetical. The Linux identity has already cost a corpus patch:

```dart
// patches/corpus/localsend-0001-pure-dart-pin-vita-plugins-no-desktop.patch
 bool checkPlatformIsDesktop() {
-  return checkPlatform([TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS]);
+  // The Vita reports itself as TargetPlatform.linux (ADR-0008), which is right
+  // for paths and fonts and wrong for furniture: a handheld has no window to
+  // position, no tray, and no second instance to hand over to. Left as linux,
+  // window_manager throws during preInit and the app never reaches runApp.
+  return false;
 }
```

**localsend never reached `runApp`** under the Linux identity, because "desktop"
is how apps ask *"do I have a window manager?"* — and the answer for a handheld
is no. Under an android identity that function returns `false` on its own and
the patch is unnecessary.

Against that, the Android identity has its own version of the same failure:
apps ask `Platform.isAndroid` to mean *"can I call an Android plugin?"*, and the
answer is also no. The difference is in **how the failure arrives**. A missing
Android plugin raises `MissingPluginException` from a `MethodChannel`, which is
a runtime error an app can catch and which this port already produces for
`connectivity_plus` and `network_info_plus`. A wrong desktop inference calls
`window_manager` synchronously during `preInit` and takes the process down
before the first frame. **One is catchable and late; the other is fatal and
early.**

### What ADR-0008's justification assumed, which turns out not to hold

The ADR defends linux as behaviourally correct on three grounds. Checking each
against the port as it now exists:

| Claim | Status |
|---|---|
| "right for **paths**" | **Does not hold.** We ship `path_provider_vita` ([ADR-0009](adr/0009-plugins-via-non-endorsed-vita-implementations.md)) and every corpus app registers it explicitly. Paths never route through the platform identity |
| "right for **fonts**" | **Does not hold.** The font manager is `txt/src/txt/platform_vita.cc`, selected by `is_vita` in GN at build time. Identity-independent |
| "desktop text-editing shortcuts... right for a handheld with physical buttons" | **Backwards.** The physical buttons synthesize arrows and scroll, not modifiers. Desktop shortcuts need a Ctrl key that does not exist |
| "no mobile overscroll glow" | **Holds** — and on a software rasterizer it is worth more than it sounds |
| "flutter-pi and flutter-elinux report linux for the same reason" | **Holds, but they are different devices.** Both target boards with a mouse, a keyboard and often a window system. A Vita has a touchscreen, a D-pad, and one fullscreen surface |

So of five justifications, two are obsolete, one is backwards, and two hold.

---

## Where this leaves it

**The decision stands. The reasoning should be replaced.**

The genuine argument for `"linux"` is not that it describes the device — it does
not; a Vita is capability-wise a phone with buttons. It is:

1. **Overscroll glow** is a radial gradient repainted during every overscroll,
   on a CPU rasterizer whose measured bottleneck is exactly raster cost inside
   the damaged region.
2. **The Android ecosystem assumes a plugin host.** Every `Platform.isAndroid`
   branch in a package leads toward a MethodChannel we do not implement. The
   Linux branch usually leads toward pure Dart, which we can actually run — and
   [ADR-0009](adr/0009-plugins-via-non-endorsed-vita-implementations.md)'s
   whole opt-in model is built on substituting pure-Dart implementations.
3. **Switching now invalidates the corpus.** Four apps carry patches written
   against the Linux identity, and every performance number in `docs/results/`
   was taken under it.

Point 2 is the one that would survive an argument. Points 1 and 3 are real but
contingent — 3 expires as soon as someone is willing to re-run the corpus.

**What is not settled** is whether the desktop *furniture* — the persistent
scrollbar in particular — is costing frames. That is cheap to answer now that
the raster pass is timed separately, and it is worth answering before anyone
argues about identity again:

> Run keklist, whose scrolling list is the corpus's worst frame-rate case, with
> `ScrollConfiguration` overridden to the mobile scrollbar behaviour, and
> compare `raster us`. If a scrollbar nobody asked for is measurable in the
> raster pass, that is a concrete cost of the Linux identity rather than a
> stylistic one — and it is fixable from `psvita` without touching the identity
> at all.

## Revisit triggers, refined from ADR-0008

ADR-0008's trigger was "an app that cannot work under the Linux identity". Two
sharper ones, from what is now known:

- **A second corpus app dies before `runApp` on a desktop-capability check.**
  One is an anecdote; two is a pattern, and it means the failure mode is
  systematically early and fatal rather than late and catchable.
- **The scrollbar measurement above shows a material raster cost** *and*
  overriding it from `psvita` turns out not to work for third-party scrollables.

Neither triggers a change to `"android"` on its own. Both would justify
reopening the comparison with numbers instead of adjectives.

## Related

- [ADR-0008](adr/0008-app-visible-platform-identity.md) — the decision, and the
  full costing of Options B and C
- [ADR-0009](adr/0009-plugins-via-non-endorsed-vita-implementations.md) — why
  paths and plugins do not depend on the identity
- [ADR-0010](adr/0010-input-layering-and-psvita-api.md) — what the D-pad and
  sticks actually synthesize
- [flutter-upgrade-cost.md](flutter-upgrade-cost.md) — `defaultTargetPlatform`
  still throws on an unknown OS in 3.47.0, so none of this expires soon
