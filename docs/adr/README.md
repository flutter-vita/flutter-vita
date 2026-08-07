# Architecture Decision Records

Each ADR records one decision, the forces behind it, and what would have to change
for it to be revisited. Status values: `Accepted`, `Proposed`, `Superseded by ADR-NNNN`,
`Rejected`.

ADR-0001 through ADR-0004 are back-filled from §1 of `Flutter Vita Plan.md`
("Key strategic decisions"). They were made before this record existed; the
*Consequences* and *Revisit trigger* sections are the new material.

| # | Title | Status |
|---|---|---|
| [0001](0001-aot-only-no-jit.md) | AOT-only; JIT is permanently out of scope | Accepted |
| [0002](0002-skia-not-impeller.md) | Skia renderer on a frozen engine, not Impeller | Accepted |
| [0003](0003-software-rendering-first.md) | Software raster first, vitaGL/GLES2 second | Accepted |
| [0004](0004-static-single-binary.md) | Static linking into a single ELF | Accepted |
| [0005](0005-aot-snapshot-delivery.md) | How the Dart AOT snapshot gets into the process | Proposed — blocked on spike |
| [0006](0006-performance-bar-set-from-measurement.md) | Performance bar set from measurement, not asserted | Accepted |
| [0007](0007-enable-partial-repaint-in-software-path.md) | Patch the engine to enable partial repaint in the software path | Proposed — needs hardware measurement |

## Open questions not yet decided

These surfaced during grilling and have no ADR yet. Listed here so they don't get lost.
Most are now tracked as exit criteria in [Phase 0.5](../phase-0.5-feasibility.md).

- ~~Float ABI~~ — **closed**: hard float on both sides, see [Phase 0.5 B5](../phase-0.5-feasibility.md)
- **Threading substrate**: VitaSDK pthread shim vs direct `sceKernel*` primitives.
  The plan's working agreement says "prefer `sce*` over newlib emulation", but
  the engine's C++ (`std::thread`, `std::mutex`, `std::condition_variable`) will
  pull in the shim regardless — so the real question is whether two threading
  substrates end up in one binary and whether their TLS mechanisms coexist.
  Also: what `thread_local` compiles to under VitaSDK, since Dart uses TLS on
  hot paths. **Not yet grilled — highest-value remaining design question.**
- **Iteration cost / developer experience.** [ADR-0001](0001-aot-only-no-jit.md)
  makes the inner loop a full host rebuild plus a hardware redeploy, with no hot
  reload and no debugger. Vita3K is the obvious mitigation and is
  [a partly false one](../vita3k-as-a-target.md). The plan rates maintainer
  burnout High; this is the mechanism by which it would happen, and nothing in
  the plan addresses it. **Not yet grilled.**
- ARM/Thumb interworking: VitaSDK defaults to Thumb, Dart emits ARM (A32).
  Standard under EABI v5, but unverified — belongs on the M1 checklist.
- Engine task runner topology (how many OS threads, and which ones are merged)
- How many of the 4 CPU cores homebrew actually receives
- Exact enlarged-memory budget, and whether homebrew titles actually receive it
