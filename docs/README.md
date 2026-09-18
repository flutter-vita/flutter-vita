# Docs

## For app developers

The pages the [README](../README.md) links, in the order a new developer
meets them.

| Page | What it is |
|---|---|
| [install-macos.md](install-macos.md), [install-linux.md](install-linux.md) | The toolchain: VitaSDK, Flutter 3.44.8, the engine artifact |
| [configure-console.md](configure-console.md) | Homebrew, the shader compiler, the network, the receiver, the two button chords |
| [get-started.md](get-started.md) | The first run: the gallery, then your own app |
| [commands.md](commands.md) | `flutter-vita`, the scripts under it, the app's own port |
| [debug-app.md](debug-app.md) | The debug strip column by column, the log, screenshots, crash dumps, a console that stops answering |
| [limitations.md](limitations.md) | No hot reload, fonts, plugins, memory, platform identity |
| [release-app.md](release-app.md) | `--release`, the title id, LiveArea art, notices |
| [configure-app.md](configure-app.md) | `FlutterVita.configure`: the pad, the rear panel, the pixel ratio, the strip, fallbacks for phone plugins |
| [develop-plugin.md](develop-plugin.md) | A Vita half for a plugin: the C file, the CMake fragment, the Dart side |
| [writing-flutter-that-runs-on-a-vita.md](writing-flutter-that-runs-on-a-vita.md) | What the benchmarks found, and what to do in app code |

## For people working on the port

| Document | What it is |
|---|---|
| **[HANDOFF.md](HANDOFF.md)** | The machine setup, the build pipeline, and every gotcha that cost time. **Its status section is from 2026-08-08 and predates Flutter running at all** — read "Where the project stands" below instead. |
| [roadmap.md](roadmap.md) | The stages and what each one cost |
| [phase-1-workplan.md](phase-1-workplan.md) | What Phase 1 actually requires, derived from the Dart SDK source |
| [embedder-startup.md](embedder-startup.md) | What `runtime/bin` does at startup, what M1 skips, and the timer/print plan for Phase 2 |
| [phase-2-gn-notes.md](phase-2-gn-notes.md) | The GN gate: what it is, tooling reality, and why the foreign-toolchain risk is lower than feared |
| [../engine/patches/dart-sdk/](../engine/patches/dart-sdk/README.md) | The Vita patch series against the pinned Dart SDK |
| [phase-0.5-feasibility.md](phase-0.5-feasibility.md) | The completed gate. Every measurement taken so far, and the exit criteria still open |
| [adr/](adr/README.md) | Architecture decision records, with an index and the open questions |
| [../Flutter Vita Plan.md](../Flutter%20Vita%20Plan.md) | The original plan, reconciled against measurement. Intent and phases 2–5; `docs/` wins on anything measured |
| [glossary.md](glossary.md) | Shared vocabulary across the Vita homebrew and Flutter halves |
| [open-sourcing.md](open-sourcing.md) | What stands between this tree and a public one, audited against the repository rather than remembered |
| [dev-environment.md](dev-environment.md) | Toolchain and IDE setup, including the three-index clangd arrangement |
| [vita3k-as-a-target.md](vita3k-as-a-target.md) | What the emulator can and cannot be trusted for |
| [../VERSIONS.md](../VERSIONS.md) | Pinned commits and why 3.44.8 |
| [../tools/apply-patches.sh](../tools/apply-patches.sh) | `--apply` puts the 26 patches into their six repos; `--verify` checks the series and the trees still agree |
| [platform-identity-options.md](platform-identity-options.md) | Which OS the Vita should claim to be: all six candidates priced, linux vs android measured, and why a real `vita` platform stays rejected |
| [flutter-upgrade-cost.md](flutter-upgrade-cost.md) | How to price a Flutter/Dart upgrade before committing to it, and the priced answer for 3.47.0 |
| [writing-flutter-that-runs-on-a-vita.md](writing-flutter-that-runs-on-a-vita.md) | What to do and avoid in app code, from what the benchmarks found |
| [roadmap-capabilities.md](roadmap-capabilities.md) | What the port can do, tracked as capabilities rather than phases |
| [phase-2-workplan.md](phase-2-workplan.md) | The engine port itself |
| [phase-4-distribution.md](phase-4-distribution.md) | Title ids, packaging and what a developer hands their users |
| [phase-5-capability-audit.md](phase-5-capability-audit.md) | Every capability priced against what the platform actually offers |
| [phase-7-tls.md](phase-7-tls.md) | TLS, and what it cost |
| [the-profiler-we-do-not-have.md](the-profiler-we-do-not-have.md) | Why there is no observatory, and what stands in for one |
| [HANDOFF-nondeterministic-crash.md](HANDOFF-nondeterministic-crash.md) | The emutls crash that cost two sessions, written up so it is not re-derived |
| [../README.md](../README.md) | What the public sees; links the developer pages above |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | How someone else helps |

## Where the project stands

**Flutter runs on real hardware.** Not the Dart runtime alone: the engine, Skia
and the framework, drawing through the Vita's GPU. The receiver in
`receiver/app/` is itself a Flutter application — tabs, lists, touch, a
monospace log view — and it is what installs everything else.

The renderer is Skia on GLES2 through `fvita_gles2`, this repository's own
layer in `engine/gles2/`, onto `sceGxm` ([ADR-0019](adr/0019-gles2-over-gxm-written-here.md);
vitaGL carried it from 2026-08-22 to 2026-09-14,
[ADR-0014](adr/0014-gpu-backend-via-vitagl.md)). Route transitions hold 60 fps
at a median 16.67 ms. Where the GPU wins it wins by 6-18x over the software
path, and there is no scene where software is faster.

**The software-era conclusion is superseded.** The Phase 0.5 arithmetic below
said 60 fps at 960x544 was impossible. That was true of a CPU `memcpy` into
CDRAM at 8.06 ms per present, and it is not true of the GPU path. Keep the
measurement, drop the conclusion.

Measured against the pinned Flutter 3.44.8:

| Measurement | Value |
|---|---|
| Receiver `.text` (armv7) | 14.67 MiB, 14 MB `.vpk` |
| Engine code (armv7) | 12.41 MiB `.text`, ~14.5 MiB resident |
| Flutter counter app AOT snapshot | 2.11 MiB instructions + 1.40 MiB data |
| `icudtl.dat` | 862 KB after trimming, was 10 MB |
| Largest contiguous main RAM | 188 MiB |
| Present blit, software path, 960x544 @ 444 MHz | 8.06 ms — why the GPU path exists |
| Route transitions, GPU path | 60 fps, median and p95 both 16.67 ms |
| Worst scene | `list_churn`, 92.5 ms of Dart build against 8.7 ms of raster |

**Memory is not the binding constraint** and never was — it is slack by an
order of magnitude. Dart build cost is: the slowest thing on the console is a
list rebuilding every frame, not anything the rasteriser does.

**The deploy loop needs no kernel plugin, no card swap and no VitaShell.**
`ScePromoterUtil` registers a fresh title id from inside the receiver, which
took three experiments and one stale conclusion to establish — see **Promote**
in [glossary.md](glossary.md). A full 15 MB deploy is about 35 seconds and a
code-only change about six.

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
- Measurements are reproducible: each lives behind a script in `experiments/`.
