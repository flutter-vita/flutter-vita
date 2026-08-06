# Project: Flutter for PlayStation Vita (`flutter-vita`)

**Goal:** Make the PS Vita (homebrew, HENkaku/h-encore) a working target platform for Flutter applications. Success criterion for v1: a standard Flutter counter app and mid-complexity UIs run on real hardware in AOT/release mode — "laggy but working" is acceptable.

**Non-goals (v1):** JIT/debug mode, hot reload, Dart DevTools, pub.dev plugins with native code, Impeller renderer, PSN/official distribution.

---

## 1. Background & Constraints

| Constraint | Detail | Consequence |
|---|---|---|
| CPU | ARM Cortex-A9, armv7-a, 4 cores, 333–500 MHz (overclockable via PSVshell) | Dart AOT armv7 codegen already exists — reuse it |
| RAM | 512 MB total; ~330–400 MB available to an app with extended memory mode | Aggressive memory budget; avoid large image caches |
| GPU | PowerVR SGX543MP4+, native API is **GXM** (proprietary) | No GLES3/Vulkan → **Impeller impossible**; use Skia. GLES2 available via **vitaGL** wrapper |
| OS | Proprietary Sony OS, no POSIX; homebrew toolchain is **VitaSDK** (arm-vita-eabi, newlib) | Dart runtime platform layer must be written from scratch on top of `sceKernel*` APIs |
| Code signing | Runtime code generation is forbidden without kernel plugins | **AOT only.** No JIT ever. This is a hard architectural decision |
| Display | 960×544, ~220 ppi, front touch + rear touchpad, physical buttons + 2 analog sticks | DPR ≈ 1.0; map front touch → pointer events; buttons/sticks → custom platform channel |
| Text input | No hardware keyboard | Use system IME dialog (`sceImeDialog`) bridged through a platform channel |
| Distribution | `.vpk` packages installed via VitaShell; discovery via VitaDB | Final artifact of the build pipeline is a `.vpk` with LiveArea assets |

**Key strategic decisions (do not revisit without strong reason):**
1. **AOT-only.** Debug/JIT is out of scope permanently for v1.
2. **Skia, not Impeller.** Pin an engine version where the Skia backend is fully supported (Flutter ~3.24–3.27 era or earlier if needed).
3. **Software rendering first** (Skia raster into a CPU buffer, blitted via GXM), **vitaGL/GLES2 acceleration second** as an optimization phase.
4. **Static linking.** Vita homebrew prefers a single ELF (SELF) plus `suprx` modules; avoid dynamic loading complexity where possible.

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
|   - Dart runtime: new platform layer "vita" (os_vita.cc ...)  |
+---------------------------------------------------------------+
| Vita embedder (C/C++, this project's core deliverable):       |
|   - embedder.h API consumer                                   |
|   - frame loop synced to sceDisplayWaitVblankStart            |
|   - software FlutterRendererConfig -> GXM framebuffer blit    |
|   - sceTouch -> FlutterPointerEvent                           |
|   - sceCtrl (buttons/sticks) -> platform channel "vita/input" |
|   - sceImeDialog -> TextInput channel                         |
|   - asset bundle loader (app0:/assets)                        |
+---------------------------------------------------------------+
| Vita OS (sceKernel, sceGxm, sceDisplay, sceTouch, sceCtrl)    |
+---------------------------------------------------------------+
```

Host-side tooling (`flutter_vita_tool`) wraps: `flutter build bundle` → `gen_snapshot` (armv7 AOT) → link with embedder + engine → `vita-make-fself` / `vita-mksfoex` / `vita-pack-vpk` → `.vpk`.

---

## 3. Phases & Milestones

### Phase 0 — Environment & Vertical Slice Foundation (1–2 weeks)
- [ ] Set up VitaSDK toolchain in CI-able form (Docker image recommended).
- [ ] Build & deploy a plain C "hello world" `.vpk`; establish FTP deploy + `psp2shell`/network logging workflow to real hardware.
- [ ] Set up Vita3K emulator as a secondary fast-iteration target (note: Vita3K compatibility is imperfect; real hardware is the source of truth).
- [ ] Vendor the Dart SDK source at a pinned version matching the chosen Flutter engine commit. Document the exact pins in `VERSIONS.md`.

**Exit criteria:** one-command build → deploy → log-capture loop against real hardware.

### Phase 1 — Dart AOT Runtime Port (the critical path, 2–4 months)
Port the Dart runtime platform layer to Vita OS. AOT *runtime* only (no compiler on device).

- [ ] Create platform files in `runtime/vm/` and `runtime/platform/`:
  - `os_vita.cc` — time (`sceKernelGetProcessTimeWide`), sleep, environment stubs
  - `os_thread_vita.cc` — threads (`sceKernelCreateThread`), mutex, condvar, TLS
  - `virtual_memory_vita.cc` — `sceKernelAllocMemBlock`-based allocation; note: no `mprotect`-style page permission changes needed in AOT (no code pages are written at runtime)
  - `utils_vita.cc`, `cpu_arm.cc` adjustments if needed
- [ ] Stub or minimally implement `dart:io`-adjacent native code: start with **everything disabled**; files via newlib/`sceIo` later; sockets via `sceNet` later (Phase 5).
- [ ] Configure the Dart GN build with a `vita` OS target using the VitaSDK cross toolchain; expect and patch newlib gaps (`getenv`, `gettimeofday`, `pthread` absence, etc.).
- [ ] **Milestone M1 (the vertical slice):** a pure-Dart AOT "hello world" (no Flutter) — snapshot generated on host with `gen_snapshot --snapshot-kind=app-aot-elf` for armv7, linked into a Vita ELF with a minimal C harness calling `Dart_Initialize` + isolate startup — prints to debug screen/log on real hardware.

**Exit criteria:** M1 runs on hardware; GC works under stress test; multi-isolate smoke test passes.

> M1 is deliberately scheduled before any engine work. It surfaces every newlib/threading/memory landmine in the smallest possible codebase. Do not start Phase 2 before M1 is green.

### Phase 2 — Engine Cross-Compilation (1–2 months, parallelizable with late Phase 1)
- [ ] Write a GN toolchain definition for `arm-vita-eabi`; integrate into the engine's `//build` config at the pinned engine commit.
- [ ] Build order & expected patch areas: zlib → libpng → harfbuzz → ICU (data slimming: embed a minimal `icudtl.dat`) → Skia (**raster backend only**, disable GPU backends initially) → libtxt → engine core.
- [ ] Disable: Impeller, Vulkan/Metal/GL paths, platform-specific shells (Android/iOS/desktop), dart:ffi trampolines if problematic (revisit later).
- [ ] Fonts: no system fonts on Vita — embed a default font (e.g., Roboto + Noto subset) into the asset bundle and register it as the default.
- [ ] **Milestone M2:** `flutter_engine` static library (`libflutter_engine.a`) links into a Vita ELF together with the M1 harness without unresolved symbols.

### Phase 3 — The Embedder (1–2 months)
Core deliverable. Single binary: `flutter_vita_embedder`.

- [ ] Initialize engine via `FlutterEngineRun` with `FlutterProjectArgs` pointing at `app0:/assets` (flutter_assets) and the AOT snapshot symbols.
- [ ] **Renderer:** `FlutterSoftwareRendererConfig` with `surface_present_callback` → copy/convert pixel buffer into a GXM-managed framebuffer, `sceDisplaySetFrameBuf`, double buffering, vsync via `sceDisplayWaitVblankStart`.
- [ ] **Vsync:** implement `vsync_callback` + `FlutterEngineOnVsync` for proper frame pacing (60 Hz).
- [ ] **Task runners:** platform task runner on the main Vita thread; configure `FlutterTaskRunnerDescription` so engine tasks post correctly; render thread = platform thread initially (simplest).
- [ ] **Input:**
  - `sceTouchPeek` (front panel) → `FlutterPointerEvent` (add/down/move/up/remove), multi-touch supported
  - `sceCtrlPeekBufferPositive` (buttons, sticks) → custom platform channel `vita/gamepad` (JSON codec), plus optional D-pad → arrow-key `RawKeyEvent` synthesis for focus traversal
- [ ] **Text input:** implement the standard `flutter/textinput` channel by launching `sceImeDialog`; on completion, deliver editing state deltas.
- [ ] **Platform channels baseline:** `flutter/platform` (clipboard no-op, system sound no-op, orientation fixed landscape), `flutter/lifecycle` (map PS button suspend/resume → inactive/resumed), `flutter/settings` (dark mode from user config file).
- [ ] **Milestone M3:** stock Flutter counter app running on real hardware, touch works, buttons increment counter via the gamepad channel. Record FPS + memory numbers as the baseline.

### Phase 4 — Tooling & Developer Experience (3–6 weeks)
- [ ] `flutter_vita_tool` (Dart CLI, host-side):
  - `create` — scaffold from template (LiveArea assets, sfo metadata, gamepad helper package)
  - `build` — `flutter build bundle` → `gen_snapshot` → link → `vita-pack-vpk`; flags: `--release` (only mode), `--titleid`, `--name`
  - `deploy` — FTP upload to VitaShell, optional auto-launch
  - `logs` — network log tail
- [ ] Companion Dart package `vita_platform`: typed API over the `vita/gamepad` channel, screen metrics, IME helpers, focus-traversal-with-dpad widget wrapper.
- [ ] CI: GitHub Actions using the Docker toolchain image; artifact = sample `.vpk` per commit.
- [ ] **Milestone M4:** a third party can go from `git clone` to a running `.vpk` of their own Flutter app following only `README.md`.

### Phase 5 — Hardening & Ecosystem (ongoing)
- [ ] `dart:io` subset: file IO via `sceIo` (map `/` → `ux0:data/<app>/`), sockets via `sceNet`/`sceHttp`; enables `http` package and asset downloads.
- [ ] vitaGL/GLES2 Skia backend experiment; measure vs software renderer; keep whichever is faster per workload.
- [ ] Memory tuning: Skia resource cache caps, image decode limits, isolate heap caps.
- [ ] Performance targets: simple UIs 60 fps; complex scrolling ≥ 20 fps software / ≥ 30 fps GL.
- [ ] Ship 2–3 showcase apps to VitaDB (e.g., VitaDB browser client, a Flame-based game port, an EPUB reader).
- [ ] Docs: porting guide, plugin-authoring-inside-the-embedder guide, upstream engine version bump playbook.

---

## 4. Risk Register

| Risk | Likelihood | Mitigation |
|---|---|---|
| newlib gaps break Dart runtime in deep ways (TLS, atomics, timers) | High | M1 vertical slice first; keep a `compat/` shim library; consult how other large C++ ports to VitaSDK solved each gap |
| Engine GN build resists a foreign toolchain | High | Pin one engine commit; keep all patches as an ordered `patches/` series; never rebase mid-phase |
| Software rendering too slow even for "laggy but working" | Medium | 960×544 raster is ~2 MP — comparable to flutter-pi on Pi Zero class HW which works; fallback: render at 720×408 and scale via GXM |
| Skia removal from upstream engine (Impeller-only future) | Certain, long-term | Freeze on last good Skia engine; treat engine upgrades as explicit projects, not routine |
| GXM specifics (framebuffer formats, alignment) | Medium | vitaGL source and existing homebrew are reference implementations; blit path is well-trodden |
| Single-maintainer burnout | High | Phase gates produce independently useful artifacts (M1 = Dart-on-Vita alone is a publishable project) |

---

## 5. Repository Layout

```
flutter-vita/
├── CLAUDE.md                  # instructions for Claude Code (see §6)
├── VERSIONS.md                # pinned commits: flutter engine, dart sdk, vitasdk
├── docker/                    # toolchain image
├── patches/
│   ├── dart-sdk/              # ordered *.patch series
│   └── engine/
├── runtime-port/              # os_vita.cc etc. before upstreaming into the vendored tree
├── embedder/
│   ├── src/main.c             # entry, engine bootstrap
│   ├── src/renderer_sw.c      # software present -> GXM blit
│   ├── src/input_touch.c
│   ├── src/input_ctrl.c
│   ├── src/channels/          # textinput, platform, lifecycle, gamepad
│   └── CMakeLists.txt
├── tool/                      # flutter_vita_tool (Dart CLI)
├── packages/vita_platform/    # Dart-side companion package
├── examples/
│   ├── counter/
│   └── gamepad_demo/
└── docs/
```

---

## 6. Working Agreements for Claude Code

Copy the relevant parts of this section into `CLAUDE.md` at repo root.

- **Ground rules**
  - Never target JIT, hot reload, or Impeller. If a task seems to require them, stop and flag it.
  - All third-party source (Dart SDK, engine) is vendored at pinned commits from `VERSIONS.md`; modifications go through `patches/` as an ordered series — never edit vendored trees without producing a patch file.
  - Real hardware is ground truth. Vita3K results are advisory only; note in PR descriptions which target was tested.
  - Prefer `sceKernel*`/`sce*` native APIs over newlib emulation when both exist.
  - Memory is scarce: any cache or buffer > 8 MB requires a comment justifying its size.
- **Build & test loop**
  - `make docker-shell` → toolchain env; `make embedder` → ELF; `make vpk` → package; `make deploy VITA_IP=...` → FTP install; `make logs` → tail network logs.
  - Every phase milestone (M1–M4) has a checklist in `docs/milestones.md`; a milestone PR must tick all boxes with hardware evidence (log excerpt or photo/video reference).
- **Code style**
  - Embedder: C11, VitaSDK conventions, no exceptions/RTTI in any C++ used.
  - Dart tool & packages: standard `dart format`, null-safe, no external deps beyond `args`, `path`, `ftp` client.
- **When stuck on newlib/OS gaps:** search existing VitaSDK homebrew ports for prior art before writing shims from scratch; record findings in `docs/newlib-notes.md`.

---

## 7. Reference Material

- Flutter architectural overview — https://docs.flutter.dev/resources/architectural-overview
- Custom Flutter Engine Embedders — https://github.com/flutter/flutter/blob/main/docs/engine/Custom-Flutter-Engine-Embedders.md
- Custom Engine Embedding in AOT Mode — https://github.com/flutter/engine/blob/main/docs/Custom-Flutter-Engine-Embedding-in-AOT-Mode.md
- Embedder API header (`embedder.h`) — in the vendored engine tree at `shell/platform/embedder/embedder.h`
- Sony flutter-embedded-linux (reference third-party embedder) — https://github.com/sony/flutter-embedded-linux
- flutter-pi (reference embedder for constrained hardware) and the author's write-up — https://www.industrialflutter.com/blogs/pros-and-cons-of-flutter-on-embedded/
- VitaSDK — https://vitasdk.org / https://github.com/vitasdk
- vitaGL (GLES-over-GXM, reference for GXM usage) — search GitHub: Rinnegatamante/vitaGL
- Dart runtime internals docs — Dart SDK repo, `runtime/docs/`

---

## 8. Definition of Done (v1.0)

1. `flutter_vita_tool build` produces an installable `.vpk` from an unmodified Flutter project (AOT release).
2. Counter app: 60 fps, touch + gamepad input, IME text entry, suspend/resume survives.
3. One non-trivial showcase app published on VitaDB.
4. Docs sufficient for an external contributor to reproduce the build from scratch.
5. All engine/Dart patches published; project licensed BSD-3/MIT compatible with upstream.
