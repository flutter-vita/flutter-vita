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
`.vpk`, and installs through the receiver protocol this project already has.

That is more work than a JSON file, but it is the only route that can express an
AOT-only device, and it owns packaging properly instead of bolting it onto
generic hooks. The dev server already speaks ping, put, launch, log and
screenshot — most of a device interface exists.

Two things gate it regardless of which shape the tool takes:

1. ~~**Prebuilt engine artifacts.**~~ Done — `tools/package-engine.sh`. See
   below.
2. ~~**A documented app template.**~~ Done — `templates/vita-app` plus
   `tools/build-vita-app.sh`. See below.

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


---

## The engine artifact

`tools/package-engine.sh` turns a finished build into a 20 MB tarball:

```
flutter-engine-vita-3.44.8/
  lib/libflutter_engine_vita.a     63 MB, 2939 objects
  include/embedder.h
  data/icudtl.dat, Roboto-Regular.ttf
  host-darwin-arm64/gen_snapshot_armv7
  MANIFEST.txt                     pins, read from args.gn
```

**1.1 GB of objects becomes 63 MB** because the build carries `-g2` and the
DWARF dwarfs the code. Stripping it costs engine-level symbolication in crash
dumps, which is the right trade: anyone debugging the engine is building it
anyway, and anyone building an app is not.

`gen_snapshot` is a build-machine binary, so it is tagged by host rather than
shipped with the target artifacts. A Linux user needs their own.

### Verified, not just produced

`experiments/m3-vpk` accepts `-DENGINE_ARCHIVE=<path>` and links the archive instead
of globbing the local object tree. Both paths were compared:

| | archive | objects |
|---|---|---|
| `.text` | 14,483,780 | 14,485,818 |
| defined symbols | 91,719 | 91,719 |

Sizes differ by 2 KB in 14.5 MB, and exactly one symbol differs in each
direction — both compiler-generated COMDAT variants (`.isra.0` clones and
inlined template instantiations) where the linker kept a different copy because
member order changed. No translation unit is missing.

Linking the archive also takes **4 seconds** against opening 2939 separate
objects, which is a real improvement to every iteration.

### The two flags that must survive

Both are in `MANIFEST.txt`, because both fail in ways that do not look like
their cause.

`--whole-archive`, because the engine relies on static initialisers in
translation units nothing references by symbol. Ordinary archive semantics pull
in only members that resolve an undefined reference, so a plain `-l` link
succeeds and fails at runtime. Linking loose objects has whole-archive
semantics already, which is why this only needs saying now.

`-Wl,-u,pthread_cancel`, because without it every `std::mutex::lock()` in the
engine compiles to a no-op. See [phase-2-workplan.md](phase-2-workplan.md).


---

## The app template

```
./tools/build-vita-app.sh path/to/app --name "Counter"
==> Counter.vpk  13M
```

`templates/vita-app` is `experiments/m3-vpk` with the experiment removed: no hardcoded
app, no hardcoded asset list, and the engine comes from the packaged artifact
rather than a local object tree. `tools/build-vita-app.sh` runs the whole
pipeline — `flutter build bundle`, frontend_server to a kernel, `gen_snapshot`
to armv7 assembly, link, package — and skips the snapshot step when the kernel
hash has not moved.

Assets are globbed from the bundle rather than listed, so whatever
`flutter build bundle` produced comes along. `kernel_blob.bin` is filtered out:
it is the JIT path's copy of the program, and this build links its AOT snapshot
into `eboot.bin` instead.

### Verified on an app that did not exist beforehand

Building the counter app again would only have proved the pipeline works on the
app it was written against. So the test was a fresh `flutter create` with an
asset the toolchain had never seen:

| | |
|---|---|
| custom asset | `flutter_assets/assets/logo.png`, 4898 B |
| manifest regenerated | `AssetManifest.bin` 117 → 162 B |
| custom title id | `FVTA00009` in `param.sfo` |
| custom name | `AssetTest` on the LiveArea |
| `.text` | 14,483,780 — identical to the known-good build |

**Verified on hardware.** The template-built `Counter.vpk` was installed with
`tools/install-vpk.sh` and runs: text in Roboto, the `+` icon from
MaterialIcons, and touch driving the counter. Byte-identical `.text` turned out
to be good evidence, but it was evidence rather than proof until this ran.

### What an app has to provide

The archive carries `main()` inside the embedder, but leaves three undefined
symbols:

```
U dev_server_run
U dev_server_set_framebuffer_source
U dev_server_set_tap_handler
```

The dev server lives in this repo rather than the engine tree, so it ships as
source in the artifact and the template compiles it. That is the right shape
rather than a workaround: a released app wants no listening socket on the
device, and can link a stub with the same three entry points.


---

## Installing

```
./tools/install-vpk.sh path/to/App.vpk
```

Unpacks the `.vpk`, stages `eboot.bin` through the receiver, pushes every other
file, and launches.

**It pushes the data files by reading the archive**, not from a list. The
receiver's `install` replaces `eboot.bin` and nothing else, so an app otherwise
runs against whatever the previous install left behind — which is exactly how
an engine spent an afternoon failing on a missing `icudtl.dat` that had never
been pushed at all, and then on a `flutter_assets` directory it could not
reach.

It also refuses a `.vpk` whose `param.sfo` title id does not match the slot the
receiver writes into. The receiver hard-codes `FVTA00002`; the asset-test build was
`FVTA00009`. Without the check that installs into the wrong slot and launches
the previous app, which looks like a build that silently did nothing.

This is the inner loop, not first-time setup: a slot has to already exist.
Installing a `.vpk` from scratch is still VitaShell's job.

---

## The opt-in surface: `pubspec.yaml`

Per [ADR-0009](adr/0009-plugins-via-non-endorsed-vita-implementations.md), the
app configures itself in the app:

```yaml
vita:
  title_id: FVTA00003        # optional
  name: My App               # optional, LiveArea tile
```

**Title id resolution**, in order: `--title-id`, then `vita.title_id`, then a
value derived from the *package* name if a `vita:` block exists, then
`FVTA00002`.

The last step is why an existing app keeps working untouched. `FVTA00002` is
the slot the dev receiver installs into, so deriving unconditionally would break
the edit-run loop for the counter app and every experiment. Adding a `vita:` block
is the signal that this is a real app wanting a real identity.

Derivation is `FV` plus two letters and five digits from a SHA-1 of the package
name — deterministic, so reinstalling replaces rather than accumulates, and two
apps essentially never collide. Keyed on the **package** name rather than the
display name, so renaming the LiveArea tile does not silently move the app to a
different install slot.

Verified end to end: a `vita:` block with `name: Counter Demo` and no title id
produced `FVDM77520` in the built `param.sfo`, with the tile reading "Counter
Demo" and the file still named `counter_app.vpk` — the display name is not
path-safe and does not name files.

Two parsers read this block, bash in `build-vita-app.sh` and Dart in the CLI,
which is why it is deliberately **flat**. Anything needing nesting should
become a separate top-level key rather than a nested one, because the cheapest
way to keep two parsers agreeing is to give them nothing to disagree about.

## Engine/SDK lockstep

`dart:ui` and the engine are one source tree cut in half. A framework from a
different revision links, builds, packages, and installs without complaint,
then misbehaves at runtime in a way that looks like anything except a version
skew.

`package-engine.sh` records `framework_rev` in `MANIFEST.txt`, read from the
building SDK's `bin/cache/flutter.version.json`. `build-vita-app.sh` reads the
consumer's copy of the same file, compares, and **refuses**:

```
!! Flutter SDK does not match the engine artifact.

   engine artifact was built against  deadbeef…
   your Flutter SDK is                058e0af2…
```

A warning would be worth nothing here: it scrolls past in a build log and the
failure it predicts arrives hours later wearing a different face.

Same file and same key on both sides, so the comparison is between like and
like rather than between two notions of "version". `doctor` reports it too, so
it is caught before a build rather than during one. An artifact predating
`framework_rev` degrades to a warning rather than a refusal — there is nothing
to check against, and inventing something would defeat the point.

**The consequence to accept: one engine artifact per Flutter revision.** Every
Flutter release a user wants is a rebuild by us. That is the project's real
long-term maintenance cost, and it is now enforced rather than hoped for.

## Licences

A `.vpk` statically links Flutter, Skia, Dart, ICU, HarfBuzz and their
dependencies into `eboot.bin`. That makes it a binary distribution of
BSD-3 software, and clause 2 requires the notice to travel with it. This is a
live obligation the moment a `.vpk` is shared, independent of whether this repo
is public.

The artifact therefore ships `LICENSE`, `NOTICE`, and `LICENSE.engine` — the
last being Flutter's own generated aggregate, 30,200 lines covering every
third-party component in the engine. It is copied from the pinned SDK rather
than composed here on purpose: an inventory assembled from memory would be both
incomplete and unverifiable, and upstream's is neither.
