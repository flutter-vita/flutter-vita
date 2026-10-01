# ADR-0004: Static linking into a single ELF

**Status:** Accepted
**Date:** 2026-08-06 (back-filled from `docs/plan.md` §1)

## Context

Vita homebrew conventionally ships as one `eboot.bin` (a signed ELF, "SELF"),
optionally alongside `.suprx` shared modules. Dynamic loading on the Vita is
possible but adds module-loading, relocation, and memory-budget complexity.
The Flutter engine, Skia, ICU, libtxt, and the Dart runtime are all available
as static archives.

## Decision

Link everything — engine, Skia, ICU, Dart runtime, embedder, and the AOT
snapshot — into a single statically linked ELF packaged as `eboot.bin`.

## Consequences

- No `dlopen`, therefore the standard `app-aot-elf` snapshot delivery mechanism
  (which other embedders load dynamically) is unavailable in its usual form.
  How the snapshot gets in is an open question, not a solved one.
- No native-code pub.dev plugins, ever, without a rebuild of the whole binary.
  This is already a stated non-goal but the *reason* is this ADR.
- Whole-binary link time becomes the inner-loop cost, on top of the AOT-only
  iteration cost from [ADR-0001](0001-aot-only-no-jit.md).
- The entire binary is resident in RAM at launch, so `.text` size is charged
  directly against the ~330–400 MB application memory budget.

## Revisit trigger

If binary size proves to be the binding memory constraint, splitting rarely-hot
code into a `.suprx` becomes worth its complexity.

## Related

[ADR-0001](0001-aot-only-no-jit.md)
