# Phase 4 — getting Flutter apps onto a Vita that isn't mine

M3 answered "can Flutter run on this hardware". It can: the counter app renders
text, takes touch, and repaints. What it did not answer is how anybody *else*
builds and installs a Flutter app for the device, which is the difference
between a demo and a port.

Two audiences, and they need opposite things.

**Vita users** are already served. `.vpk` is the platform's native package
format, VitaShell and VHBB install it, and VitaDB is an existing homebrew store
with an audience. No work needed — this is a better end-user story than most
embedded Flutter targets get.

**Flutter developers** are served by nothing at all. Building for Vita today
means a 12 GB gclient checkout, a patched engine, and a ~30 minute build before
the first line of app code compiles.

---

## `flutter custom-devices` cannot express this port

The obvious route is Flutter's built-in mechanism for third-party targets: a
JSON config declaring how to ping, install, and run on a device the tool does
not know about. It is what flutter-pi uses, devices defined this way appear in
`flutter devices`, and the VS Code extension reads that list — so the familiar
device-picker workflow would come free.

**It does not work here, and the reason is structural rather than fixable.**
From `packages/flutter_tools/lib/src/custom_devices/custom_device.dart` at the
pinned 3.44.8:

```dart
@override
FutureOr<bool> supportsRuntimeMode(BuildMode buildMode) {
  return buildMode == BuildMode.debug;
}
```

Debug only. Not profile, not release. And it is enforced, in
`commands/run.dart`:

```dart
if (!await device.supportsRuntimeMode(buildMode)) {
  throwToolExit(
    '${buildMode.uppercaseFriendlyName}'
    'mode is not supported by ${device.displayName}.',
  );
}
```

So `flutter run --release -d vita` exits with *"Release mode is not supported by
Vita"* before anything is built.

Debug mode is not an escape hatch. It means a JIT engine, which
[ADR-0001](adr/0001-aot-only-no-jit.md) puts permanently out of scope, and the
start path assumes it too — `CustomDeviceAppSession.start` awaits a VM service
URI scraped from the app's log output:

```dart
final Uri? vmServiceUri = await discovery.uri;
```

`ProtocolDiscovery.uri` is `await uris.first` with no timeout of its own, so a
device that never prints a VM service URI does not fail — it waits.

The device *would* still appear in `flutter devices` and in the VS Code picker,
because `isSupported()` returns true independently. Listable but not runnable is
worse than absent: it offers the workflow and then refuses it at the last step.

**This was checked rather than assumed**, after being proposed from memory as
the fast path. Half an hour of reading closed off a direction that would have
cost weeks.

---

## What remains

**A `flutter-vita` wrapper CLI**, the model Samsung uses for Tizen: a Dart CLI
that depends on `flutter_tools` as a package, subclasses `Device` with its own
`supportsRuntimeMode`, discovers Vitas on the network, builds and packages the
`.vpk`, and installs through the loader protocol this project already has.

That is more work than a JSON file, but it is the only route that can express an
AOT-only device, and it owns packaging properly instead of bolting it onto
generic hooks. The dev server already speaks ping, put, launch, log and
screenshot — most of a device interface exists.

Two things gate it regardless of which shape the tool takes:

1. **Prebuilt engine artifacts.** Nobody will try this if step one is a 12 GB
   checkout and a 30 minute build. Versioned tarballs pinned to a Flutter
   release, the way ardera publishes for ARM, are the actual unlock.
2. **A documented app template.** `spikes/m3-vpk` hardcodes the B2 counter
   app's `.dill` and asset bundle. Until an arbitrary Flutter app can be pointed
   at the toolchain, there is nothing to distribute.

## Not blocking, worth reporting anyway

The FreeType gating found in Phase 3 is arguably an upstream bug rather than a
Vita quirk:

```gn
skia_use_freetype = is_android || is_linux || is_canvaskit
```

Any target not on that list gets an engine with **no font backend at all**, and
it fails silently — text simply does not draw, and shipping fonts does not help
because the asset font manager needs a backend to decode them. Worth filing
whether or not Vita ever lands upstream.
