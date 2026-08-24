# Flutter engine patches

Ordered patch series against the pinned Flutter monorepo commit in
[VERSIONS.md](../../VERSIONS.md) — `058e0af2` (tag `3.44.8`), which carries
engine version `0cd61071` and pins Dart at `d684a576`, the same commit
[the Dart patches](../dart-sdk/README.md) target.

Same working agreement as the Dart series: **never edit the vendored tree
without producing a patch file.** `third_party/flutter` is gitignored and
disposable; these patches are the artifact.

| # | Patch | What it does |
|---|---|---|
| 0001 | [gn-vita-toolchain](0001-gn-vita-toolchain.patch) | Teaches the engine's GN about `target_os=vita`, including which renderers it builds |
| 0002 | [fml-for-vita](0002-fml-for-vita.patch) | Teaches `fml` the platform, and gets it off `mmap`. **Read the message-loop note** |
| 0003 | [engine-sources-for-vita](0003-engine-sources-for-vita.patch) | Clang-only flags, missing `<cstring>`, two more platform chains, one Skia type |
| 0004 | [m2-link-check](0004-m2-link-check.patch) | An executable that makes the linker answer the M2 question — and, because it owns those files, the embedder itself: both renderer paths and the C++ runtime's static guards |
| 0005 | [skia-target-for-vita](0005-skia-target-for-vita.patch) | `flutter/skia/BUILD.gn` — the log backend, and where `-ldl` was hiding |
| 0006 | [vita-fonts](0006-vita-fonts.patch) | `txt` gets a real font manager, plus two probes promoted out of `FML_DLOG` |
| 0008 | [partial-repaint-in-the-software-path](0008-partial-repaint-in-the-software-path.patch) | The software surface claims `supports_partial_repaint`, and reports the damage rect to the embedder |
| 0009 | [gl-without-impeller](0009-gl-without-impeller.patch) | Two upstream files that assume `shell_enable_gl` implies Impeller |
| 0010 | [paragraph-timing](0010-paragraph-timing.patch) | Times `ui.Paragraph` construction, build and layout, because this port has no profiler |

**There is no 0007.** It was `boringssl-no-asm-for-vita`, a bisect that put the
Vita on BoringSSL's `no_asm_config` to test whether ARM assembly was crashing
the TLS handshake. It was not — and the run that proved it also showed the
Vita target has **zero** assembly objects in the build graph either way, so the
patch was a no-op that read like a decision. It was reverted from the tree at
the time but left in the series, where a clean checkout would have re-applied
it. `tools/apply-patches.sh --verify` found the discrepancy on 2026-08-19 and
the patch was deleted. The story is in
[docs/phase-7-tls.md](../../docs/phase-7-tls.md).

## Applying

```bash
./tools/apply-patches.sh --apply
```

One command for all six repos. Everything below is what it is doing and why —
worth reading once, because the layout is not guessable, but do not hand-run it.
The prose version of this procedure was wrong in three places until 2026-08-19.

```bash
./tools/apply-patches.sh --list      # which patch goes into which repo
./tools/apply-patches.sh --dry-run   # say what would happen, write nothing
./tools/apply-patches.sh --verify    # do the patches and the trees still agree?
```

**Six repos, not one.** `third_party/flutter` is the monorepo; Dart, Skia,
zlib, abseil and BoringSSL are DEPS-managed checkouts nested inside it, each
with its own `.git`. A patch is filed under the name of the *component* it
fixes, which is not always the repo it applies to — `patches/dart-sdk/0005`
applies to **zlib**. `--list` is the authority on this.

**`git apply patches/dart-sdk/000*.patch` is wrong**, and was in this file and
in [the Dart README](../dart-sdk/README.md) three times. `000*` does not match
`0010`, so it silently skips a 29-file patch containing every socket
implementation. `--verify` now fails on any glob in the docs that misses part
of its series.

**Patch 0004 goes in half-way.** Its `runtime/` hunks belong in the engine's
Dart tree; its `build/` half does not, because the engine resolves
`//build/...` to `engine/src/build` rather than to the Dart SDK's own copy, and
gets its vita toolchain from engine patch 0001 instead. The script filters it;
`--verify` checks only the `runtime/` half against that tree, so the deliberate
absence does not read as drift.

**Order matters, and applying twice does not fail.** Each patch is a `git diff`
against the *pristine* tree, so two patches touching one file overlap — the
later contains the earlier's hunks. Applying 0010 onto a tree that already had
0004 once inserted a **second copy** of the vita `gen_snapshot` targets:
twenty `vita_arm` references where there should be ten, and no error. `--apply`
refuses to start on a tree that is not pristine, for exactly this reason.

`flutter/third_party/tonic` is **not** a separate repo — it lives in the
monorepo, so its changes are in 0003 above.

---

## 0001 — GN vita toolchain

Six files. The engine's `build/` is Chromium's, so this is the same shape as
Dart patch 0004, and **QNX is the precedent worth reading first**
(`build/toolchain/qnx/BUILD.gn` is 22 lines): the engine already carries one
non-Clang embedded target, so this is a supported path rather than a new one.

**`build/config/BUILDCONFIG.gn`** — `is_vita` is declared once above the
`current_os` chain instead of as a `false` line inside each branch. Upstream
edits that chain on every roll; a variant that lives outside it does not have to
be re-added each time. A `vita` branch sets the usual booleans, and the default
toolchain dispatch gains an `is_vita` arm pointing at `//build/toolchain/vita:arm`
with a mac or linux host toolchain beside it.

**`is_posix = false`.** newlib plus sceKernel is not POSIX, and saying otherwise
makes GN hand us every `*_posix.cc` in the tree — files referencing `mmap`,
`dlopen`, `fork` and signals. Phase 1 established this for the Dart runtime.

**`build/toolchain/vita/BUILD.gn`** — a `gcc_toolchain()` with the
`arm-vita-eabi-` prefix taken from `$VITASDK`. Modelled on the QNX one.

**`build/config/arm.gni`** — `arm_tune = cortex-a9` and, more importantly,
`arm_float_abi = hard`. VitaSDK's GCC is built `--with-float=hard`; defaulting to
`softfp` would link against hard-float VitaSDK libraries with no error from the
linker, and doubles would arrive as garbage across every boundary.

**`build/config/compiler/BUILD.gn`** — four changes:

- `-march`/`-mfloat-abi`/`-mtune`/`-mthumb` in a new `is_vita` block. These
  normally come from the `is_posix` branch, which vita deliberately skips. It is
  tempting to leave them out — `arm-vita-eabi-gcc` is single-target and already
  defaults to armv7-a hard-float — and that is exactly why it would be
  dangerous: the build would work while depending on a compiler default.
- `_DEFAULT_SOURCE`, because `-std=c++20` defines `__STRICT_ANSI__` and newlib
  then hides `strdup`, `strtok_r` and the rest behind feature-test macros.
- `U_HAVE_MMAP=0`, so ICU takes its stdio path.
- `-Werror` off, as QNX does. GCC 15.2 is not a compiler this warning set was
  tuned against, and burying porting errors under new-in-GCC-15 diagnostics
  across Skia, ICU and HarfBuzz helps nobody. Revisit once the target links.

`cxx_disable_modules` is also gated on `is_clang` now. `-fno-modules -Xclang
-fno-cxx-modules` are Clang spellings; GCC rejects them outright and has nothing
to disable.

**`flutter/shell/platform/BUILD.gn`** — a `vita` arm returning no deps. The port
is an embedder-API client, so the sceGxm/sceDisplay/sceTouch code lives outside
the engine tree, exactly as `is_qnx` does above it.

**`flutter/tools/gn`** — `vita` joins `--target-os`, maps to `arm`, uses the
host's prebuilt Dart SDK, and selects the software-only renderer: no GL, Vulkan,
Metal, Ganesh or Graphite, `shell_enable_software = true`,
`impeller_supports_rendering = false`. NEON stays **on**, unlike QNX — the
Cortex-A9 has it.

### The one that cost a build: `is_clang` must be a global arg

`//build/toolchain/vita:arm` sets `is_clang = false` in its `toolchain_args`,
and that is not enough, because **GN ignores `toolchain_args` for the default
toolchain** — which is precisely what the vita toolchain is. Every
`if (is_clang)` in the tree still evaluated true and `arm-vita-eabi-gcc` was
handed `-fcolor-diagnostics`, `-Wstring-conversion`, `-Wnewline-eof` and
`-Xclang`. The fix is `gn_args['is_clang'] = args.target_os != 'vita'` in
`tools/gn`; the toolchain's own `is_clang = false` is kept because it is correct
for any non-default use and costs nothing.

Same rule explains why `current_os` worked without help: for the default
toolchain GN takes it from the `target_os` build arg instead.

### Verified

`gn gen` configures 921 targets, and every third-party dependency compiles for
`arm-vita-eabi` with

```
-march=armv7-a -mfloat-abi=hard -mtune=cortex-a9 -mthumb -mfpu=neon
```

on the command line: zlib, libpng, freetype2, harfbuzz, expat, ICU, and Skia.
See [the Skia patches](../skia/README.md) — that tree needed two files.

## 0002 — fml for vita

`//flutter/fml` is the engine's base library; everything depends on it. Four
files, and it now compiles clean.

**`fml/build_config.h`** was 22 of the 22 failures on the first attempt — one
`#error Please add support for your platform`, reached because VitaSDK's GCC
defines neither `__linux__` nor `__unix__`. `FML_OS_VITA` joins the chain and
`FML_OS_POSIX`, the latter for the same reason GN hands us
`fml/platform/posix/`: newlib supplies `open`/`read`/`close`, pthreads and
`pthread_once`, which is everything `FML_OS_POSIX` gates. It is not a claim that
the platform is POSIX.

**`platform/posix/paths_posix.cc`** — `PATH_MAX` is undefined. VitaSDK ships a
`<limits.h>` that defines it, but GCC's own `limits.h` shadows that one and the
`include_next` chain never reaches it. `<sys/syslimits.h>` has it (1024).

**`platform/posix/file_posix.cc`** — includes `<sys/mman.h>` and never uses it.

**`platform/posix/mapping_posix.cc`** — the real one. Same shape as the Skia
change, with one deliberate difference: **writable mappings are refused rather
than emulated.** A read-only mapping can be a heap copy without the caller being
able to tell. A `MAP_SHARED` writable one cannot — its writes go back to the
file, a heap copy's do not, and there is no honest point at which to write it
back. Emulating it would make the persistent shader cache appear to work while
discarding everything. Callers check `IsValid()`, so refusing degrades a feature
instead of corrupting data.

### ~~Compiles is not runs: `MessageLoopImpl::Create()` returns nullptr~~ — fixed

`platform/vita/message_loop_vita.{cc,h}` now exists and `MessageLoopImpl::Create()`
returns it. It is a sceKernel event flag rather than epoll plus timerfd, because
this loop waits on no descriptors at all — only "sleep until a time, or until
someone wakes me", which is exactly what an event flag is, and it is the
primitive the M1 timer thread already proved on this device.

Two details worth not undoing:

- **The flag is cleared before the wake time is read, not after.** A `WakeUp`
  landing in that window leaves the bit set, so the wait returns immediately —
  correct. Clearing afterwards would swallow it and the loop would sleep through
  a pending task.
- **`SceUInt` timeouts are 32-bit**, so a deadline beyond ~71 minutes is capped
  rather than allowed to overflow. Waking early costs one cheap iteration;
  overflowing would cost a missed one.

Unlike the Linux loop, a failed wait logs and stops rather than dropping out
silently — a message loop that has quietly stopped running is not something to
discover three layers up.

### The original note, for context

`fml/message_loop_impl.cc` dispatches on `FML_OS_*` and ends in
`#else return nullptr`. Vita takes that branch. **This is not a build error and
will not block M2** — the engine will link. It will then fail the `FML_CHECK` in
`MessageLoop::EnsureInitializedForCurrentThread` the first time any thread wants
a loop, which is immediately.

A real `fml/platform/vita/message_loop_vita.{cc,h}` is required before anything
runs. Linux's is `timerfd`-backed; the Vita equivalent is the event-flag wait
already written for the M1 timer thread (`spikes/m1-vpk/src/main.c`), so the
mechanism is known. Tracked as a Phase 3 prerequisite, recorded here because a
silent `nullptr` is exactly the kind of thing that gets found on hardware at the
worst moment.

## 0003 — engine sources for vita

Ten files across `flutter/assets`, `flutter/display_list`, `flutter/lib`,
`flutter/third_party/tonic` and `flutter/shell/platform/embedder`. None is
interesting on its own; together they are most of what stood between a
configured build and a compiling one. Four themes:

**Clang-only warning flags.** `flutter/lib/ui` and `flutter/lib/gpu` add
`-Wimplicit-float-conversion`, which GCC rejects outright — 74 of the 102
failures in the first full build were this one flag. It is now gated on
`is_clang`. GCC's nearest relative, `-Wfloat-conversion`, is much broader and
would bury the porting work under warnings from headers this port does not own;
the diagnostic is a developer aid for the `dart:ui` boundary, not a correctness
gate.

(`-Wno-newline-eof` also appears on the command line and is *not* an error —
GCC ignores unrecognised `-Wno-*` unless another diagnostic fires, in which case
it emits a note about it. That note is noise, not a cause.)

**Missing `<cstring>`** in four `display_list` files that call `memcpy`,
`memset`, `memcmp` and `memmove`. libc++ and glibc pull it in transitively;
newlib's libstdc++ does not. These are latent upstream bugs that only a
libstdc++-on-newlib build can see.

**Two more platform-detection chains**, each with its own `#error`:
`tonic/common/build_config.h` (a near-copy of fml's) and
`flutter/assets/native_assets.cc`. The latter defines a string used as a key
into the native-assets manifest; nothing emits a `vita_arm` entry, so the lookup
never matches, and naming it is what lets the file compile rather than what
makes native assets work.

**`embedder_surface.cc` and `GrDirectContext`.** `sk_sp<T>`'s destructor needs a
complete `T`, and the header only forward-declares it. Every other embedder
target picks up the definition transitively through a GPU backend header; a
software-only build has none, so the include has to be explicit. The pointer is
always null here — the GL, Vulkan and Metal surfaces that override
`CreateResourceContext` are all excluded.

## Keeping the two Dart trees identical

`third_party/sdk` (Phase 1's standalone checkout, still used by
`spikes/m1-vpk`) and `third_party/flutter/engine/src/flutter/third_party/dart`
are the same pinned commit and must carry the same changes.

```bash
./tools/apply-patches.sh --verify
```

**The check that used to live here was wrong**, and on 2026-08-14 it let real
drift through. It compared files reported by `git diff --name-only` from HEAD —
but the engine's tree carries a local commit above the pin, so anything changed
*inside that commit* is neither dirty nor untracked and was never compared.
`runtime/bin/virtual_memory_vita.cc` sat in that blind spot: present in the
engine tree, absent from `third_party/sdk`. Regenerating patch 0010 from `sdk`
would have dropped the file from the patch with no error at all.

`--verify` diffs against the pin, and asks the question from both directions:
every patch must reverse out of its tree, and every changed file in a tree must
be owned by some patch. It also knows which differences are **deliberate**,
which its predecessor did not.

### The five known differences, triaged 2026-08-19

`tools/check-dart-trees.sh` reported five and called them all dangerous. Four
of them were never drift:

```
differs         build/config/BUILDCONFIG.gn
differs         build/config/arm.gni
differs         build/config/compiler/BUILD.gn
only in sdk     build/toolchain/vita/BUILD.gn
```

These are the **`build/` half of patch 0004, which is deliberately not applied
to the engine tree** — the engine resolves `//build/...` to `engine/src/build`
and gets its vita toolchain from engine patch 0001 instead. The two trees are
*supposed* to differ here. A checker that cannot say so cries wolf four times
out of five, which is exactly why its output was being skimmed past.

The fifth was real:

```
differs         runtime/platform/globals.h
```

`third_party/sdk` still said `kHostOperatingSystemName "vita"` while the patch
and the engine tree said `"linux"` — the
[ADR-0008](../../docs/adr/0008-app-visible-platform-identity.md) change had
never reached the standalone tree. Fixed by syncing it to the patch.
`check-dart-trees.sh` has been deleted; `--verify` covers everything it did and
excludes the 0004 exception by construction.

Running this on the fresh engine checkout is what caught that a Dart patch had
gone stale. It is worth running after every change to either tree.

---

## 0009 — GL without Impeller

`shell_enable_gl = true` with `impeller_supports_rendering = false` is a
configuration upstream does not build, and two files assume it cannot happen.
Both were found by turning GL on for ADR-0014, and both are fixed by applying
the gate `BUILD.gn` already applies one level up.

**`embedder_external_texture_gl.cc`** includes Impeller's GLES backend
unconditionally. `BUILD.gn` adds the
`//flutter/impeller/renderer/backend/gles` dependency only when Impeller
renders, so without it the file asks for `GLES3/gl3.h` with no include path to
find it on — and VitaSDK ships GLES2 headers only. The includes and
`ResolveTextureImpeller` are guarded on `IMPELLER_SUPPORTS_RENDERING`, and
`ResolveTexture` falls through to the Skia path.

**`embedder.cc`** picks between `EmbedderSurfaceGLImpeller` and
`EmbedderSurfaceGLSkia` with a *runtime* `if (enable_impeller)`, referencing a
class whose translation unit `BUILD.gn` did not build. It links on every other
GL target because they all have Impeller. Guarded the same way.

It also needed `GL_RGBA8`, which arrives through a platform GL header on every
other target and through nothing at all here — GLES2 does not define the sized
internal formats. Defined next to the `GL_BGRA8_EXT` the file already defines
for itself.

Impeller stays off for a reason worth restating: it has no software backend,
and [ADR-0014](../../docs/adr/0014-gpu-backend-via-vitagl.md) measured
`saveLayer` *slower* on this tile-based GPU, so the Vita needs both paths
selectable at run time.

---

## 0010 — paragraph timing

Instrumentation, not a fix, and the only reason it is in the tree is that
nothing else can answer the question. There is no DevTools here, no timeline
and no profiler.

The question came from [ADR-0017](../../docs/adr/0017-the-gallery-becomes-the-benchmark.md):
a route push that builds 48 `Text` widgets spends 41 ms on the UI thread, and
the same 48 glyphs inside *one* `Text` cost 1 ms. So the cost is flat per
paragraph — but "per paragraph" covers resolving a text style, resolving a
font, handing runs to the shaper and breaking lines, and those fail very
differently.

Three counters and a paragraph count, guarded by `FML_OS_VITA` so the files
are untouched everywhere else, summed in
`lib/ui/text/paragraph{,_builder}.cc` and printed by the embedder with its
periodic loop statistics:

```
flutter-vita: PARAGRAPHS 304 | ctor 18270 us | build 27486 us | layout 30746 us | 251 us each
```

What it answered: **no single phase dominates.** Construction is about 22% of
a paragraph, build 33%, layout 40%, and the per-paragraph total sits near
260 us whatever the scene. It also showed that the engine is only about a third
of the story — 48 paragraphs at 260 us is 12.5 ms of a 41 ms frame, and the
rest is the Dart side of `TextPainter`.

Delete this when there is a profiler, or when the paragraph cost stops being
the thing that decides whether a screen holds 60 fps.
