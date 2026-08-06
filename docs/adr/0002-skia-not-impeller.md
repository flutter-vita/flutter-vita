# ADR-0002: Skia renderer on a frozen engine, not Impeller

**Status:** Accepted
**Date:** 2026-08-06 (back-filled from `Flutter Vita Plan.md` §1)

## Context

Impeller requires Metal, Vulkan, or OpenGL ES 3.x. The Vita's PowerVR SGX543MP4+
exposes only the proprietary GXM API natively; the community `vitaGL` wrapper
provides roughly GLES1.1/2.0-level functionality on top of it. There is no
GLES3 and no Vulkan, so Impeller cannot be made to work at any effort level.

Skia therefore is the only renderer. Upstream Flutter is removing Skia in favour
of Impeller across all platforms, so the Skia path has an expiry date.

## Decision

Skia is the renderer. Pin one engine commit and treat it as frozen; all patches
live as an ordered series in `patches/engine/`.

**Amended 2026-08-06 — the pin is 3.44.8, not "~3.24–3.27".** See
[VERSIONS.md](../../VERSIONS.md) for the commits and the full reasoning. In
short, the premise that a recent engine would lack Skia turned out to be wrong:

- `kSoftware` / `FlutterSoftwareRendererConfig` are present in `embedder.h` at HEAD.
- Impeller has **no software backend**, so the `kSoftware` embedder path is
  necessarily Skia-backed, and Skia is still vendored in the current DEPS.
- Skia's removal from **iOS** (3.29) is a platform-specific change, not a
  wholesale removal.

So the constraint is not "Skia's days are numbered" but "the `kSoftware`
embedder path's days are numbered" — a much larger and better-signalled change
that pinning three years back does not protect against.

## Consequences

- The project diverges from upstream Flutter at the pinned commit, but from a
  *current* commit, so apps can use current Flutter and current pub packages.
  Under the original ~3.24 pin this would have been a serious user-facing
  limitation; it now mostly isn't.
- Security and correctness fixes from upstream do not arrive automatically.
- Pinning removes a class of build breakage during Phases 1–3.
- Pinning to the commit `ardera/flutter-engine-binaries-for-arm` ships means a
  working armv7 `gen_snapshot` and a reference arm32 engine binary exist from
  day one — which materially shortens Phase 1.

## Revisit trigger

The real one to watch is **deprecation of the `kSoftware` embedder renderer**,
not Skia news generally. Also revisit if Impeller gains a GLES2 backend that
vitaGL could plausibly satisfy.

Version bumps follow ardera's `arm/` directory, not Flutter stable.

## Related

[ADR-0003](0003-software-rendering-first.md) — the renderer *backend* choice within Skia.
