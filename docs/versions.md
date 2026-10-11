# Pinned versions

Every third-party tree is vendored at an exact commit. Changing anything here is
an explicit project, never routine maintenance ([ADR-0002](adr/0002-skia-not-impeller.md)).

This page is for people. The tools read [`versions.json`](../versions.json): the
Flutter version, the framework revision, the engine release and its download.
Change both together.

| Component | Version | Commit |
|---|---|---|
| Flutter (framework) | **3.47.7** | `abaf9c523780a608bd46686fd5e53740a07077f8` |
| Flutter engine | matching 3.47.7 | `deb287481e3ce9468f3434937ced4240a70539ca` |
| Dart SDK | matching 3.47.7 (3.13.5) | `04bcd1036cdc799ac6564988f159ee454d42c822` |
| VitaSDK | *TBD — pin at Phase 0* | |

> **Corrected 2026-08-19.** The first two rows were both wrong. The framework
> row carried the *engine* revision, and the engine row carried
> `82bd5b7209…`, which matches nothing in any tree here. Ground truth is
> `bin/cache/flutter.version.json` in the tools' own SDK, which is also what
> `tools/build-vita-app.sh`'s lockstep check reads — so the check was right
> and the table it was supposed to agree with was not.

```bash
cat ~/.flutter-vita/flutter/3.47.7/bin/cache/flutter.version.json
```

## Why 3.47.7 specifically

3.47.7 was the newest stable Flutter on 2026-10-11, the day of the upgrade.
[`ardera/flutter-engine-binaries-for-arm`](https://github.com/ardera/flutter-engine-binaries-for-arm)
ships prebuilt 32-bit ARM engine binaries for its engine revision, `deb28748`
(the tag `engine_deb287481e3c…`). 3.44.8 had the same property, and it was the
reason for that pin. Matching ardera buys four concrete things:

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
- **32-bit ARM is not dead.** ardera ships arm32 binaries for 3.47.7.
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

## The move from 3.44.8 to 3.47.7

On 2026-08-19 the answer for 3.47 was no: 3.47.0 was a release candidate,
ardera had no arm32 binaries for it, and nothing in the range touched the
measured bottleneck. On 2026-10-11 the first two reasons were gone: 3.47.7 is
stable, and ardera has binaries for its engine. The upgrade was done that day.
[docs/flutter-upgrade-cost.md](flutter-upgrade-cost.md) has the price and what
it cost.

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
