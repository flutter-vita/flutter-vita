# Pinned versions

Every third-party tree is vendored at an exact commit. Changing anything here is
an explicit project, never routine maintenance ([ADR-0002](adr/0002-skia-not-impeller.md)).

This page is for people. The tools read [`versions.json`](../versions.json): the
Flutter version, the framework revision, the engine release and its download.
Change both together.

| Component | Version | Commit |
|---|---|---|
| Flutter (framework) | **3.44.8** | `058e0af2c2b57e369d905a03ac9748b0ebf543c6` |
| Flutter engine | matching 3.44.8 | `0cd610717bde95fd88343c64f81c11ba4e5c0010` |
| Dart SDK | matching 3.44.8 (3.12.2) | `d684a576a6aa954ae107a03b2b4e1d61c3bebe93` |
| VitaSDK | *TBD — pin at Phase 0* | |

> **Corrected 2026-08-19.** The first two rows were both wrong. The framework
> row carried the *engine* revision, and the engine row carried
> `82bd5b7209…`, which matches nothing in any tree here. Ground truth is
> `bin/cache/flutter.version.json` in the tools' own SDK, which is also what
> `tools/build-vita-app.sh`'s lockstep check reads — so the check was right
> and the table it was supposed to agree with was not.

```bash
cat ~/.flutter-vita/flutter/3.44.8/bin/cache/flutter.version.json
```

## Why 3.44.8 specifically

These are not arbitrary. They are the **exact commits
[`ardera/flutter-engine-binaries-for-arm`](https://github.com/ardera/flutter-engine-binaries-for-arm)
ships prebuilt 32-bit ARM engine binaries for**, as of its 2026-07-24 update.
Matching that pin buys four concrete things:

1. **Proof that the engine builds for armv7 at this commit.** A third party has
   already done it. That converts "will the engine cross-compile to 32-bit ARM?"
   from an open risk into a solved problem — for a Linux target, at least.
2. **A `gen_snapshot` targeting arm, useful for measurement.** Their `arm/`
   directory contains `gen_snapshot_linux_x64_release`, a host tool producing
   armv7 AOT snapshots.

   > **Corrected 2026-08-07.** This section previously claimed "M1 does not
   > require building the Dart SDK first." **That is wrong.** Dart's
   > `FeaturesString()` embeds the target OS and validates it when loading a
   > snapshot, so a snapshot from this `linux-arm` tool will be *rejected* by a
   > `vita` runtime. What it genuinely bought: proof that armv7 codegen works,
   > accurate size measurements (the OS name is metadata, not code), and
   > confirmation that the version pin and kernel format are right. M1 needs a
   > `gen_snapshot` built to target vita.
3. **A reference `libflutter_engine.so.release` for arm32 and a working
   `icudtl.dat`** to diff your own build against when it inevitably misbehaves.
4. **A shared version to ask questions about.** ardera is the flutter-pi author
   and the closest thing this project has to prior art.

## Why the plan's advice to pin ~3.24–3.27 is obsolete

`docs/plan.md` §1 says to pin "Flutter ~3.24–3.27 era or earlier" because
Skia support is being removed. Three checks say that is over-conservative:

- **The software renderer is alive in current `embedder.h`.** `kSoftware`,
  `FlutterSoftwareRendererConfig`, `FlutterSoftwareBackingStore2`, and a full
  `FlutterSoftwarePixelFormat` set are all present at HEAD.
- **Impeller has no software backend.** So the `kSoftware` embedder path is
  necessarily Skia-backed. Skia cannot be removed from the engine while that
  path exists — and it is still vendored in the current DEPS.
- **32-bit ARM is not dead.** ardera updated arm32 binaries to 3.44.8 last month.
  What *was* dropped is 32-bit **iOS** (Flutter 3.3), which is unrelated.

The removal that would actually hurt this project is not "Skia is removed" but
"the `kSoftware` embedder path is removed". That is a much larger, much
better-signalled change affecting many embedders, and pinning to 3.24 today buys
no protection against it while costing three years of framework and package
compatibility.

## What this changes downstream

- Apps target a **current** Flutter SDK, so current pub packages work. This was
  going to be a significant user-facing limitation under the old pin.
- Phase 1's critical path shortens: get ardera's `gen_snapshot`, produce an
  armv7 AOT snapshot immediately, and attack the Vita runtime port with a real
  artifact in hand rather than a hypothetical one.

## Do not chase 3.47

Flutter 3.47 targets August 2026 (branch cutoff 2026-07-07). ardera has not
shipped arm32 binaries for it. The value of this pin is the prebuilt arm32
reference; moving ahead of it discards the main reason to be here.
**Revisit when ardera's `arm/` directory moves, not when Flutter stable moves.**

**Priced, 2026-08-19, and the answer is still no** — for a better reason than
the one above. See
[docs/flutter-upgrade-cost.md](flutter-upgrade-cost.md) for the full
measurement and the procedure to redo it. In short: 3.47.0 is a release
candidate (`[user-branch]`, no changelog); the engine patch series survives it
almost untouched (6 of 44 files, all GN); the Dart series does not (24 of 67
files, eight of ten patches, plus one guaranteed compile break in
`InterfaceSocketAddress`); and **nothing in the 1,358-commit range addresses
the measured bottleneck.** Upstream's engine work in that window went to
Impeller — 336 files, +13,110 lines — while the Skia software path this port
executes got 5 insertions across 2 files.

## Incidental finding: the blit may be free

`kFlutterSoftwarePixelFormatRGBA8888` is R,G,B,A in memory order. Vita's
`sceDisplaySetFrameBuf` wants `SCE_DISPLAY_PIXELFORMAT_A8B8G8R8`, which on a
little-endian target is also R,G,B,A in memory order. If that holds, the
software present callback → framebuffer path is a straight `memcpy` with no
channel swizzle, which matters a lot on a CPU this slow.
**Verify in Phase 0.5 — do not assume.**

## Sources

- https://github.com/ardera/flutter-engine-binaries-for-arm
- https://github.com/ardera/flutter-pi
- https://docs.flutter.dev/release/archive
- https://github.com/sony/flutter-embedded-linux/issues/166
