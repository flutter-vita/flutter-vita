# Docs

| Document | What it is |
|---|---|
| **[HANDOFF.md](HANDOFF.md)** | **Start here.** Where the work stopped, the machine setup, the build pipeline, and every gotcha that cost time. |
| [roadmap.md](roadmap.md) | What stands between today and a `.vpk` with Flutter inside, and how long each stage costs |
| [phase-1-workplan.md](phase-1-workplan.md) | What Phase 1 actually requires, derived from the Dart SDK source |
| [embedder-startup.md](embedder-startup.md) | What `runtime/bin` does at startup, what M1 skips, and the timer/print plan for Phase 2 |
| [phase-2-gn-notes.md](phase-2-gn-notes.md) | The GN gate: what it is, tooling reality, and why the foreign-toolchain risk is lower than feared |
| [../patches/dart-sdk/](../patches/dart-sdk/README.md) | The Vita patch series against the pinned Dart SDK |
| [phase-0.5-feasibility.md](phase-0.5-feasibility.md) | The completed gate. Every measurement taken so far, and the exit criteria still open |
| [adr/](adr/README.md) | Architecture decision records, with an index and the open questions |
| [glossary.md](glossary.md) | Shared vocabulary across the Vita homebrew and Flutter halves |
| [dev-environment.md](dev-environment.md) | Toolchain and IDE setup, including the three-index clangd arrangement |
| [vita3k-as-a-target.md](vita3k-as-a-target.md) | What the emulator can and cannot be trusted for |
| [../VERSIONS.md](../VERSIONS.md) | Pinned commits and why 3.44.8 |

## Where the project stands

**M1 is met: pure-Dart AOT runs on real hardware.** On a PSVita-1000 the `.vpk`
initialises the Dart VM, creates an isolate, executes compiled ARM code, returns
6830 to C, and drains the microtask queue. No Flutter yet — only the Dart
runtime is ported. See [HANDOFF.md](HANDOFF.md) for how the last three failures
were resolved, all of them embedder gaps rather than porting problems.

`print()`, microtasks and real timers all work, so the async machinery Flutter
depends on is running. FFI natives resolve at runtime via
`Dart_SetFfiNativeResolver` — the same channel `dart:ui` uses.

**Phase 0.5 is complete and the verdict is go.** Both tracks are done; nothing
measured says stop. Five of six exit criteria are closed — the sixth, the thread
budget, is Phase 1's central problem rather than a feasibility gate.

Measured so far, all against the pinned Flutter 3.44.8:

| | |
|---|---|
| Engine code (armv7) | 12.41 MiB `.text`, ~14.5 MiB resident |
| Flutter counter app AOT snapshot | 2.11 MiB instructions + 1.40 MiB data |
| Pure-Dart AOT snapshot | 352 KiB instructions + 262 KiB data |
| `icudtl.dat` | 10 MB, reducible |
| Float ABI | hard float on both sides — match |
| VM domain execution | works, ARM and Thumb, no kernel plugin |
| Largest contiguous main RAM | 188 MiB |
| Present blit, 960×544 @ 444 MHz | 8.06 ms — the hard floor per frame |

**Memory is not the binding constraint** — it is slack by an order of magnitude.
CPU throughput is: 60 fps at native 960×544 is arithmetically impossible, 30 fps
is marginal, and 720×408 upscaled reaches 68 fps for the same work.

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
