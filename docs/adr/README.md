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
| [0005](0005-aot-snapshot-delivery.md) | How the Dart AOT snapshot gets into the process | **Option A** — Option B defeated by a writable-BSS requirement |
| [0006](0006-performance-bar-set-from-measurement.md) | Performance bar set from measurement, not asserted | Accepted |
| [0007](0007-enable-partial-repaint-in-software-path.md) | Patch the engine to enable partial repaint in the software path | **Accepted** — measurement makes it load-bearing |

## Open questions not yet decided

These surfaced during grilling and have no ADR yet. Listed here so they don't get lost.
Most are now tracked as exit criteria in [Phase 0.5](../phase-0.5-feasibility.md).

- ~~Float ABI~~ — **closed**: hard float on both sides, see [Phase 0.5 B5](../phase-0.5-feasibility.md)
- ~~**Threading substrate**~~ — **closed by M3, and the answer was worse than the
  question.** The shim wins: the engine's `std::thread`/`std::mutex` pull in
  VitaSDK's pthreads regardless, and the two substrates do coexist. But
  libstdc++'s `__gthread_active_p()` decides at runtime whether locking is real
  by testing for a weak `pthread_cancel`, which VitaSDK does not reference from
  anything the link would otherwise pull in — so **every `std::mutex` in the
  engine silently compiled down to a no-op.** Fixed by forcing the symbol with
  `-Wl,-u,pthread_cancel`, which every link now carries. The lesson generalises:
  on this target, "it links and runs" does not imply the C++ runtime is intact.
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

## Surfaced by the 2026-08-14 grilling — post-M3, aimed at the toolchain goal

M3 met the technical bar: a Flutter counter app runs on hardware. These are the
questions between that and the stated goal — *"a Flutter developer can easily
run their app on a Vita"* — which is a distribution problem, not a porting one.
Nothing here needs a rebuild to decide.

- **The goal has no exit criterion.** M4 is "third party can reproduce the
  build", which delivers *our* app to *their* device. The goal is *their* app on
  *their* device. Needs a falsifiable statement before anything is planned
  against it. **Blocking — it decides the priority of everything below.**
- **Plugin support: in scope or explicitly not?** Verified: the toolchain's
  entire engagement with `pubspec.yaml` is one `grep` for `name:`
  ([build-vita-app.sh:78](../../tools/build-vita-app.sh:78)). No plugin
  resolution, no registrant, no per-plugin native build convention — and
  [ADR-0004](0004-static-single-binary.md)'s single static ELF removes the
  dynamic registration every other platform relies on. Nearly every real app
  transitively needs `path_provider`. "Run real apps from GitHub" is blocked on
  this, and the corpus of plugin-free apps is small. **ADR-sized either way.**
- **`vita_platform` API surface is undesigned.** Flutter's framework has no
  gamepad, rear-touchpad, or dual-analog concept, so a "touches every hardware
  thing" conformance app is really a test of a Dart API that does not exist yet.
  The API precedes the app. Open sub-question: mirror community conventions
  (`sensors_plus`, `gamepads`) so apps port unchanged, or design Vita-shaped?
- **Engine/framework version coupling is unenforced.** `dart:ui` and the engine
  are one source tree cut in half; a mismatch fails at runtime, not build time.
  `package-engine.sh` writes the pins into `MANIFEST.txt` and **nothing reads
  it** — both entry points instead read `VERSIONS.md` from the repo working
  tree ([build-vita-app.sh:21](../../tools/build-vita-app.sh:21),
  [flutter_vita.dart:352](../../tools/flutter_vita/bin/flutter_vita.dart:352)),
  which a downstream user does not have. Proposal: `MANIFEST.txt` becomes the
  source of truth and a mismatch is a hard refusal. Consequence to accept
  first: **one engine artifact per Flutter version, rebuilt by us.** That is the
  project's real long-term maintenance cost.
- **No hardware-free verification.** Every gate so far has been "deploy and
  look." That does not survive the maintainer being away from the device — which
  has already happened — and it does not survive contributors at all.
  Candidates: build-only CI (historically catches most breakage, which has been
  link errors), Vita3K as an advisory smoke test, golden-image diffing against
  the dev server's `shot`.
- **No `LICENSE` or `NOTICE`.** A `.vpk` statically links Skia, Dart and engine
  code, all BSD-3, whose binary-distribution clause requires the notice to
  accompany the binary. This is a live obligation the moment a `.vpk` is shared,
  independent of when the repo opens. Cheapest item on this list.
- **Open-sourcing is scheduled last; it is the mitigation for the top-rated
  risk.** The register rates single-maintainer burnout High. Also: the stated
  blocker is scrubbing "dangerous data" from history, and a scan finds none —
  `third_party/` is gitignored, `.git` is 5.6 MB, no credentials on any branch,
  one author. The cost of the rewrite only grows.
- **Audience: adoption or craft?** The market is *Flutter developers* ∩ *hacked
  Vita owners*, and the homebrew scene is a C/C++ population. Not a rhetorical
  question — "adoption" makes early open-sourcing the product and the CLI
  central; "craft" makes a legible, well-documented repo worth more than CLI
  polish. The two answers fund different work.
