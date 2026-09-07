# Project: Flutter for PlayStation Vita (`flutter-vita`)

> **Status, 2026-08-08.** This is the original plan, reconciled against what has
> since been measured. Phases 0, 0.5 and 1 are complete — **M1 is green on real
> hardware** — and Phase 2 is next.
>
> Where this document and [`docs/`](docs/) disagree, **`docs/` wins**: it records
> measurements, this records intent. Corrections are marked **[corrected]**
> inline rather than quietly edited, because several of the original claims were
> not just stale but wrong in ways that shaped early decisions.
>
> Start at [`docs/HANDOFF.md`](docs/HANDOFF.md) for the current state.

**Goal:** Make the PS Vita (homebrew, HENkaku/h-encore) a working target platform for Flutter applications. Success criterion for v1: a standard Flutter counter app and mid-complexity UIs run on real hardware in AOT/release mode — "laggy but working" is acceptable.

**Non-goals (v1):** JIT/debug mode, hot reload, Dart DevTools, pub.dev plugins with native code, Impeller renderer, PSN/official distribution.

---

## 0. What changed since this was written

| Claim here | Reality | Where |
|---|---|---|
| JIT impossible without kernel plugins | **Wrong premise.** The VM domain is user-mode; no plugin needed. JIT is defeated instead by a 16 MiB block cap and process-global W^X | [ADR-0001](docs/adr/0001-aot-only-no-jit.md) |
| Pin Flutter ~3.24–3.27 | Pinned **3.44.8** | [ADR-0002](docs/adr/0002-skia-not-impeller.md), [VERSIONS.md](VERSIONS.md) |
| ~330–400 MB available; "aggressive memory budget" | **188 MiB** largest contiguous, and memory is **not** the binding constraint — it is slack by an order of magnitude. CPU is the constraint | [phase-0.5](docs/phase-0.5-feasibility.md) |
| No page-permission changes needed in AOT | **Wrong.** Write-protection flags and the BSS both need them; this drove the ADR-0005 reversal | [ADR-0005](docs/adr/0005-aot-snapshot-delivery.md) |
| newlib lacks pthread | pthread exists and works; `DartWorker` spawns and joins | [HANDOFF](docs/HANDOFF.md) |
| 960×544 is "~2 MP" | 522,240 px ≈ **0.52 MP**. The arithmetic this justified was wrong | [ADR-0006](docs/adr/0006-performance-bar-set-from-measurement.md) |
| 60 fps for simple UIs | **Arithmetically impossible** at native resolution — the present blit alone is 8.06 ms, 48% of the frame budget. 30 fps marginal; **720×408 reaches 68 fps** | [ADR-0006](docs/adr/0006-performance-bar-set-from-measurement.md) |
| Docker toolchain image | VitaSDK installed natively via vdpm; no Docker | [dev-environment](docs/dev-environment.md) |
| `psp2shell` / network logging | **No taiHEN plugin works on this device.** BGFTP for file transfer, manual launch from LiveArea, logs pulled over FTP | [HANDOFF](docs/HANDOFF.md) |
| M1 = `app-aot-elf` snapshot that prints | `app-aot-assembly` **linked into eboot.bin**; success is a checksum, though `print()` now works too | [ADR-0005](docs/adr/0005-aot-snapshot-delivery.md) |

---

## 1. Background & Constraints

| Constraint | Detail | Consequence |
|---|---|---|
| CPU | ARM Cortex-A9, armv7-a, 4 cores, 333–500 MHz (overclockable via PSVshell) | Dart AOT armv7 codegen already exists — reuse it. **[corrected]** No SDIV: `integer_division_supported_ = false` |
| RAM | 512 MB total | **[corrected]** 188 MiB largest contiguous block, measured. Not the binding constraint — CPU throughput is |
| GPU | PowerVR SGX543MP4+, native API is **GXM** (proprietary) | No GLES3/Vulkan → **Impeller impossible**; use Skia. GLES2 available via **vitaGL** wrapper |
| OS | Proprietary Sony OS, no POSIX; homebrew toolchain is **VitaSDK** (arm-vita-eabi, newlib) | Dart runtime platform layer written from scratch on `sceKernel*`. **[corrected]** pthread *is* available and used |
| Code signing | **[corrected]** Runtime code generation *is* possible in user mode via the VM domain (`sceKernelAllocMemBlockForVM`, Open = writable, Close = executable) | **AOT only** still stands, but for different reasons: 16 MiB max block, 1 MiB min, and W^X is process-global. See [ADR-0001](docs/adr/0001-aot-only-no-jit.md) |
| Display | 960×544, ~220 ppi, front touch + rear touchpad, physical buttons + 2 analog sticks | DPR ≈ 1.0. **[corrected]** 0.52 MP, not 2 MP. 720×408 upscaled is the likely default |
| Text input | No hardware keyboard | Use system IME dialog (`sceImeDialog`) bridged through a platform channel |
| Distribution | `.vpk` packages installed via VitaShell; discovery via VitaDB | Final artifact of the build pipeline is a `.vpk` with LiveArea assets |

**Key strategic decisions (do not revisit without strong reason):**
1. **AOT-only.** Correct conclusion; see the corrected rationale above.
2. **Skia, not Impeller.** Pinned at **3.44.8**.
3. **Software rendering first** (Skia raster into a CPU buffer, blitted via GXM), **vitaGL/GLES2 acceleration second** as an optimization phase.
4. **Static linking.** Vita homebrew prefers a single ELF (SELF); avoid dynamic loading complexity where possible.
5. **[added] The snapshot is linked into `eboot.bin`**, not loaded at runtime — [ADR-0005](docs/adr/0005-aot-snapshot-delivery.md).

---

## 2. Architecture Overview

```
+---------------------------------------------------------------+
| Flutter app (Dart, unmodified)                                |
+---------------------------------------------------------------+
| Flutter framework (Dart, unmodified)                          |
+---------------------------------------------------------------+
| Flutter engine (C++): Skia, libtxt, ICU, Dart AOT runtime     |
|   - cross-compiled with VitaSDK (arm-vita-eabi)               |
|   - custom GN toolchain + newlib patches                      |
|   - Dart runtime: platform layer "vita" (os_vita.cc ...) DONE |
|   - dart:vita, the Dart-side embedder shim               DONE |
+---------------------------------------------------------------+
| Vita embedder (C/C++, this project's core deliverable):       |
|   - embedder.h API consumer                                   |
|   - frame loop synced to sceDisplayWaitVblankStart            |
|   - software FlutterRendererConfig -> GXM framebuffer blit    |
|   - sceTouch -> FlutterPointerEvent                           |
|   - sceCtrl (buttons/sticks) -> platform channel "vita/input" |
|   - sceImeDialog -> TextInput channel                         |
|   - asset bundle receiver (app0:/assets)                        |
+---------------------------------------------------------------+
| Vita OS (sceKernel, sceGxm, sceDisplay, sceTouch, sceCtrl)    |
+---------------------------------------------------------------+
```

Host-side tooling (`flutter_vita_tool`) wraps: `flutter build bundle` → `gen_snapshot` (armv7 AOT) → link with embedder + engine → `vita-make-fself` / `vita-mksfoex` / `vita-pack-vpk` → `.vpk`.

---

## 3. Phases & Milestones

Timeframes from the original plan are removed: they were guesses, and scope is
derived from source instead — see [`docs/roadmap.md`](docs/roadmap.md) and
[`docs/phase-1-workplan.md`](docs/phase-1-workplan.md).

### Phase 0 — Environment ✅ **complete**
- [x] VitaSDK toolchain — **[corrected]** installed natively via vdpm, not Docker.
- [x] Plain C `.vpk` on real hardware; deploy via **BGFTP**, logs pulled over FTP.
      **[corrected]** No `psp2shell`: no taiHEN plugin loads on this device, and
      vitacompanion destabilised SceShell. Launching is manual from the LiveArea.
- [x] Vita3K as a secondary target — advisory only, see [vita3k-as-a-target](docs/vita3k-as-a-target.md).
- [x] Dart SDK vendored at a pinned commit; pins in [VERSIONS.md](VERSIONS.md).

### Phase 0.5 — Feasibility gate ✅ **complete** *(added after this plan was written)*
Measure before committing. Verdict: **go**. See [phase-0.5-feasibility.md](docs/phase-0.5-feasibility.md).

### Phase 1 — Dart AOT Runtime Port ✅ **complete, M1 green on hardware**
- [x] Platform files: `os_vita.cc`, `os_thread_vita.cc`, `virtual_memory_vita.cc`,
      `utils_vita.cc`, `cpu_arm.cc`.
      **[corrected]** `virtual_memory_vita.cc` *does* need page-permission
      changes — `FLAG_write_protect_code`, `FLAG_write_protect_vm_isolate`, and
      the BSS all require them. The original note said otherwise.
- [x] `dart:io` natives excluded entirely.
- [x] GN build with a `vita` OS target; patches 0001–0008 in [`patches/dart-sdk/`](patches/dart-sdk/README.md).
- [x] **Milestone M1.** **[corrected]** `app-aot-assembly` linked into
      `eboot.bin`, not `app-aot-elf` loaded at runtime. Verified on a
      PSVita-1000: `main()` returns 6830, `print()` works, microtasks drain,
      and a real 50 ms timer fires.

**Phase 1's exit criteria are now all met.** The GC stress test and the
multi-isolate smoke test were run on hardware on 2026-08-09: `gcStress()`
returns 1999000 after ~8 MB of churn, and `isoMarker()` returns 7777 from a
second isolate. Both found something. GC stress failed at ~200 iterations until
patch 0009 replaced libgcc's emulated TLS, under which every `thread_local` in
the runtime -- including `Thread::Current()` -- was one shared global.
`Isolate.spawn` needed two things: `create_group`/`initialize_isolate` callbacks
in `Dart_Initialize`, *and* `VMLibraryHooks.platformScript`, which nothing set
because this port has no `dart:io`.

> The original note "do not start Phase 2 before M1 is green" was correct and
> was honoured. M1 surfaced the frame-layout, snapshot-delivery, and embedder
> gaps in the smallest possible codebase, exactly as intended.

### Phase 2 — Engine Cross-Compilation ⬅ **next**
- [ ] GN toolchain definition for `arm-vita-eabi` in the engine tree at the pinned commit.
- [ ] Build order & expected patch areas: zlib → libpng → harfbuzz → ICU (data slimming: embed a minimal `icudtl.dat`, currently 10 MB) → Skia (**raster backend only**) → libtxt → engine core.
- [ ] Disable: Impeller, Vulkan/Metal/GL paths, platform-specific shells.
      **[corrected]** Do **not** disable `dart:ffi` — the port depends on FFI
      natives via `Dart_SetFfiNativeResolver`, which is also how `dart:ui`
      reaches its embedder.
- [ ] Fonts: no system fonts on Vita — embed a default font and register it.
- [ ] **[added]** `dart:io` platform files for vita — ~11 `*_vita.cc` in
      `runtime/bin`, moved here from Phase 5 (see below). Sockets are the bulk
      and VitaSDK ships the BSD headers; `sys/un.h` and `ifaddrs.h` are the
      absentees.
- [ ] **[added]** `dart:ui` gets added to the platform dill the same way
      `dart:vita` was, which takes **three** edits — see
      [embedder-startup.md](docs/embedder-startup.md). Omitting the third
      produces a byte-identical dill with no error.
- [ ] **Milestone M2:** engine links into a Vita ELF with the M1 harness, no unresolved symbols.

Notes: engine `.text` measures 12.41 MiB armv7, ~14.5 MiB resident.
See [phase-2-gn-notes.md](docs/phase-2-gn-notes.md).

### Phase 3 — The Embedder
Core deliverable. Single binary: `flutter_vita_embedder`.

- [ ] Initialize engine via `FlutterEngineRun` with `FlutterProjectArgs` pointing at `app0:/assets` and the AOT snapshot symbols.
- [ ] **Renderer:** `FlutterSoftwareRendererConfig` with `surface_present_callback` → GXM framebuffer, `sceDisplaySetFrameBuf`, double buffering, vsync via `sceDisplayWaitVblankStart`.
- [ ] **Vsync:** `vsync_callback` + `FlutterEngineOnVsync`. **[corrected]** Pace
      for 30 fps, or 60 fps at 720×408 — not 60 fps at native.
- [ ] **[added]** Enable partial repaint — [ADR-0007](docs/adr/0007-enable-partial-repaint-in-software-path.md).
- [ ] **Task runners:** platform task runner on the main Vita thread; render thread = platform thread initially.
- [ ] **Input:** `sceTouchPeek` → `FlutterPointerEvent`; `sceCtrlPeekBufferPositive` → platform channel `vita/gamepad`, plus D-pad → arrow-key synthesis for focus traversal.
- [ ] **Text input:** `flutter/textinput` via `sceImeDialog`.
- [ ] **Platform channels baseline:** `flutter/platform`, `flutter/lifecycle`, `flutter/settings`.
- [ ] **Milestone M3:** stock counter app on real hardware, touch works, buttons increment via the gamepad channel. Record FPS + memory as the baseline.

### Phase 4 — Tooling & Developer Experience
- [ ] `flutter_vita_tool` (Dart CLI, host-side): `create`, `build`, `deploy`, `logs`.
      **[corrected]** `deploy` targets BGFTP and cannot auto-launch; launching is manual.
- [ ] Companion Dart package `vita_platform`.
- [ ] CI: GitHub Actions. **[corrected]** No Docker image exists; either build one or script vdpm.
- [ ] **Milestone M4:** a third party goes from `git clone` to a running `.vpk` following only `README.md`.
      Note [ADR-0005](docs/adr/0005-aot-snapshot-delivery.md) makes this harder: every app relinks the engine.

### Phase 5 — Hardening & Ecosystem
- [ ] ~~`dart:io` subset~~ — **moved to Phase 2.** This was scheduled here on the
      assumption that `dart:io` is optional. It is not: the embedder's base
      `deps` include `$dart_src/runtime/bin:common_embedder_dart_io`
      unconditionally, so the platform files have to exist before M2 can link.
      Discovered 2026-08-10 by reading `shell/platform/embedder/BUILD.gn`. What
      may still belong here is the *quality* of that layer -- the first pass
      only has to link and behave honestly.
- [ ] vitaGL/GLES2 Skia backend experiment; measure against the software renderer.
- [ ] Memory tuning: Skia resource cache caps, image decode limits, isolate heap caps.
- [ ] **[corrected]** Performance targets: **30 fps at native, or 60 fps at 720×408**, from [ADR-0006](docs/adr/0006-performance-bar-set-from-measurement.md). The original "60 fps simple / 20 fps complex" was asserted, not measured, and 60 fps native is impossible.
- [ ] Ship 2–3 showcase apps to VitaDB.
- [ ] Docs: porting guide, plugin-authoring guide, engine version bump playbook.

---

## 4. Risk Register

| Risk | Original likelihood | Outcome / status |
|---|---|---|
| newlib gaps break Dart runtime in deep ways (TLS, atomics, timers) | High | **Retired.** Real but tractable; patches 0006 + the platform files handled it. pthread was available after all |
| Engine GN build resists a foreign toolchain | High | **Still open, Phase 2.** Lower than feared — the Dart GN build accepted a `vita` target with one patch. See [phase-2-gn-notes.md](docs/phase-2-gn-notes.md) |
| Software rendering too slow even for "laggy but working" | Medium | **Partly realised.** 60 fps native is impossible; 30 fps is marginal. The fallback (720×408 + scale) is now the likely default, not a contingency |
| Skia removal from upstream engine (Impeller-only future) | Certain, long-term | Unchanged. Frozen at 3.44.8 |
| GXM specifics (framebuffer formats, alignment) | Medium | **Retired for the blit path** — measured at 8.06 ms, 960×544 |
| Single-maintainer burnout | High | Unchanged. M1 alone is publishable, as intended |
| **[added]** Embedder omissions misread as port bugs | — | **Realised, repeatedly.** Every M1 failure after `Dart_Invoke` was a step `runtime/bin` performs and the harness skipped. Mitigation: [embedder-startup.md](docs/embedder-startup.md) |

---

## 5. Repository Layout

**[corrected]** The original layout was aspirational. Actual:

```
flutter-vita/
├── Flutter Vita Plan.md       # this file — intent; docs/ is authoritative
├── VERSIONS.md                # pinned commits
├── docs/                      # measurements, ADRs, handoff — start here
│   ├── HANDOFF.md
│   ├── adr/
│   └── embedder-startup.md
├── patches/dart-sdk/          # ordered *.patch series (0001–0008)
├── experiments/                    # each measurement behind a script
│   ├── b1-aot-snapshot/       # hello.dart -> kernel
│   ├── m1-snapshot/           # kernel -> snapshot.S
│   └── m1-vpk/                # the M1 harness and vpk
└── third_party/sdk/           # Dart SDK, gclient-owned, gitignored
```

Phase 2+ adds `embedder/`, `tool/`, `packages/vita_platform/`, `examples/`.
There is no `docker/` and no `runtime-port/` — the platform files live in the
vendored tree and are extracted as patch 0003.

---

## 6. Working Agreements

- **Ground rules**
  - Never target JIT, hot reload, or Impeller. If a task seems to require them, stop and flag it.
  - All third-party source is vendored at pinned commits; modifications go through `patches/` as an ordered series. **Never `rsync` into `third_party/sdk`** — gclient gitlinks do not survive a file copy.
  - Real hardware is ground truth. Vita3K is advisory. **[corrected]** But do not dismiss a Vita3K failure as an emulator artifact without evidence — one such dismissal cost two rounds.
  - Prefer `sce*` native APIs over newlib emulation when both exist.
  - **[added]** Before writing embedder code, read `runtime/bin/main_impl.cc` and `dartutils.cc`. Every M1 failure past `Dart_Invoke` was a step those files perform and the harness did not.
- **Build & test loop** — **[corrected]** no Makefile and no Docker. The pipeline
  is six ordered steps; see [HANDOFF.md](docs/HANDOFF.md). Steps 1–3 must be
  rebuilt together: Dart hashes VM sources into the snapshot version, and patch
  0007/0008 affect the **platform dill**, not the runtime.
- **Code style** — Embedder: C11, VitaSDK conventions, no exceptions/RTTI in any C++.
  Dart tool & packages: `dart format`, null-safe, minimal deps.
- **When stuck on newlib/OS gaps:** search existing VitaSDK homebrew for prior art first.

---

## 7. Reference Material

- Flutter architectural overview — https://docs.flutter.dev/resources/architectural-overview
- Custom Flutter Engine Embedders — https://github.com/flutter/flutter/blob/main/docs/engine/Custom-Flutter-Engine-Embedders.md
- Custom Engine Embedding in AOT Mode — https://github.com/flutter/engine/blob/main/docs/Custom-Flutter-Engine-Embedding-in-AOT-Mode.md
- Embedder API header (`embedder.h`) — vendored engine tree, `shell/platform/embedder/embedder.h`
- **The reference Dart embedder** — `runtime/bin/main_impl.cc` and `runtime/bin/dartutils.cc` in the vendored Dart SDK. Read before writing embedder code
- Sony flutter-embedded-linux — https://github.com/sony/flutter-embedded-linux
- flutter-pi (reference embedder for constrained hardware) — https://www.industrialflutter.com/blogs/pros-and-cons-of-flutter-on-embedded/
- VitaSDK — https://vitasdk.org / https://github.com/vitasdk
- vitaGL (GLES-over-GXM) — https://github.com/Rinnegatamante/vitaGL
- Dart runtime internals — Dart SDK repo, `runtime/docs/`

---

## 8. Definition of Done (v1.0)

1. `flutter_vita_tool build` produces an installable `.vpk` from an unmodified Flutter project (AOT release).
2. Counter app: **[corrected] 30 fps at native or 60 fps at 720×408** — not 60 fps at native, which is arithmetically impossible. Touch + gamepad input, IME text entry, suspend/resume survives.
3. One non-trivial showcase app published on VitaDB.
4. Docs sufficient for an external contributor to reproduce the build from scratch.
5. All engine/Dart patches published; project licensed BSD-3/MIT compatible with upstream.
