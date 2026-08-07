# Docs

| Document | What it is |
|---|---|
| [roadmap.md](roadmap.md) | What stands between today and a `.vpk` with Flutter inside, and how long each stage costs |
| [phase-0.5-feasibility.md](phase-0.5-feasibility.md) | The current gate. Every measurement taken so far, and the exit criteria still open |
| [adr/](adr/README.md) | Architecture decision records, with an index and the open questions |
| [glossary.md](glossary.md) | Shared vocabulary across the Vita homebrew and Flutter halves |
| [dev-environment.md](dev-environment.md) | Toolchain and IDE setup, including the three-index clangd arrangement |
| [vita3k-as-a-target.md](vita3k-as-a-target.md) | What the emulator can and cannot be trusted for |
| [../VERSIONS.md](../VERSIONS.md) | Pinned commits and why 3.44.8 |

## Where the project stands

**Phase 0.5**, the paper-feasibility gate. Track B (host-only) is complete;
Track A (hardware) has not started and holds every remaining blocker.

Measured so far, all against the pinned Flutter 3.44.8:

| | |
|---|---|
| Engine code (armv7) | 12.41 MiB `.text`, ~14.5 MiB resident |
| Flutter counter app AOT snapshot | 2.11 MiB instructions + 1.40 MiB data |
| Pure-Dart AOT snapshot | 352 KiB instructions + 262 KiB data |
| `icudtl.dat` | 10 MB, reducible |
| Float ABI | hard float on both sides — match |

**Memory is not the binding constraint.** CPU throughput for software
rasterisation is, and it is still unmeasured.

## Reading order for someone new

1. [roadmap.md](roadmap.md) — the shape of the whole project
2. [adr/README.md](adr/README.md) — the decisions and why
3. [phase-0.5-feasibility.md](phase-0.5-feasibility.md) — what is actually known
4. [glossary.md](glossary.md) — when a term is unfamiliar

## Conventions

- Every decision gets an ADR. A wrong premise in an ADR is worse than no ADR —
  see [ADR-0001](adr/0001-aot-only-no-jit.md), whose stated rationale was
  factually incorrect and had to be replaced.
- Performance and behaviour claims name the hardware they came from. Vita3K
  results say so explicitly. Real hardware is ground truth.
- Measurements are reproducible: each lives behind a script in `spikes/`.
