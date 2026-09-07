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
| [0008](0008-app-visible-platform-identity.md) | How an app learns it is running on a Vita | **Option A** — keep the linux identity; B is one line if ever needed |
| [0009](0009-plugins-via-non-endorsed-vita-implementations.md) | `pubspec.yaml` as opt-in surface: build config + three non-endorsed plugins | Accepted — 19% → 50% of surveyed apps |
| [0010](0010-input-layering-and-psvita-api.md) | Input in two layers; only the second is a package | Accepted — D-pad navigation needs no dependency |
| [0011](0011-crash-recovery-without-taihen.md) | A crash returns to the receiver by exiting cleanly | Accepted — **amended 2026-08-21**: no kernel plugins or SceShell modules; in-process user hooks permitted |
| [0012](0012-test-apps-as-measurement-instrument.md) | The test apps is an instrument, and its output is a diff | Accepted — five axes, one control, patch size is the score |
| [0013](0013-ffi-needs-static-linking.md) | `dart:ffi` needs static linking, and that is the admission test | Accepted — decided one app in and one app out |
| [0014](0014-gpu-backend-via-vitagl.md) | The raster pass is the bottleneck, so the GPU becomes the target | **Accepted** — raster is 97% of a frame; engine work gated on a spike |
| [0015](0015-four-products-one-audience.md) | The toolchain is four products with one audience | Accepted — the product boundary ends at the `.vpk` |
| [0016](0016-the-receiver-becomes-a-flutter-app.md) | The receiver becomes a Flutter app, and stops being invisible | Accepted — pinned engine, software rendering, C layer holds the port |
| [0017](0017-the-gallery-becomes-the-benchmark.md) | The gallery becomes the benchmark, and a scene is the unit | Accepted — scripted scenes, a stall is 2+ frames at or below 30 fps, gated on a committed baseline |

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

- ~~**The goal has no exit criterion**~~ — **closed 2026-08-14.** The bar is
  *their app, plus a declared opt-in*: a `vita:` block in `pubspec.yaml`, and
  optionally a `psvita` dependency. Not "unmodified" — that was briefly chosen
  and then correctly rejected as more expensive than it was worth, since the
  opt-in edit is what makes non-endorsed plugin implementations legal
  ([ADR-0009](0009-plugins-via-non-endorsed-vita-implementations.md)) and what
  lets an app ask whether it is on a Vita at all
  ([ADR-0008](0008-app-visible-platform-identity.md)).
- ~~**Plugin support**~~ — **closed by [ADR-0009](0009-plugins-via-non-endorsed-vita-implementations.md).**
  Measured rather than argued: 5 of 26 real apps are plugin-free, and
  `path_provider` + `url_launcher` + `shared_preferences` take that to 13. Three
  non-endorsed implementations, no general plugin system.
- ~~**Audience**~~ — **adoption.** Which is what makes the forked-SDK cost in
  ADR-0008 decisive rather than a detail, and what makes the open-sourcing
  deferral below expensive rather than neutral.
- ~~**`psvita` API surface**~~ — **closed by [ADR-0010](0010-input-layering-and-psvita-api.md).**
  The premise was wrong: Flutter already wires arrow keys to focus traversal and
  `gameButtonA` to activation, so D-pad navigation belongs in the embedder and
  needs no package at all. `psvita` covers only what Flutter has no concept of.
- **Stick deadzone and response curve are unset.** ADR-0010 maps the left stick
  to scroll events; how much stick travel is how much scroll is a guess until it
  is tried on hardware. Belongs on the conformance app's checklist.
- **Title ID allocation.** `FVTA00002` is hard-coded, so any two flutter-vita
  apps on one device overwrite each other. ADR-0009 puts the ID in `pubspec.yaml`
  but does not decide whether the developer picks one or it is derived from a
  hash of the package name. Only bites with more than one user — which is to say,
  exactly when it is most expensive to fix.
- **Engine/framework version coupling is unenforced.** `dart:ui` and the engine
  are one source tree cut in half; a mismatch fails at runtime, not build time.
  `package-engine.sh` writes the pins into `MANIFEST.txt` and **nothing reads
  it** — both entry points instead read `VERSIONS.md` from the repo working
  tree ([build-vita-app.sh:21](../../tools/build-vita-app.sh:21),
  [flutter_vita.dart:352](../../cli/bin/flutter_vita.dart:352)),
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
- **Open-sourcing: deferred to the end, with a cost that is now named.** Not an
  open question — a decision, made 2026-08-14: *"decided later, when all steps
  are done."* Recorded here because the cost is worth seeing when the deferral
  is revisited. The stated blocker is scrubbing "dangerous data" from history,
  and a scan finds none — `third_party/` is gitignored, `.git` is 5.6 MB, no
  credentials on any branch, one author. The real cost is not danger, it is
  **feedback latency**: with adoption as the audience, no external user can
  exercise any of this until the repo opens, so every decision between now and
  then is made blind and is discovered to be wrong all at once, at the end. The
  secondary cost is that the history rewrite grows monotonically.
