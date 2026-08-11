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
| 0001 | [gn-vita-toolchain](0001-gn-vita-toolchain.patch) | Teaches the engine's GN about `target_os=vita` |
| 0002 | [fml-for-vita](0002-fml-for-vita.patch) | Teaches `fml` the platform, and gets it off `mmap`. **Read the message-loop note** |
| 0003 | [engine-sources-for-vita](0003-engine-sources-for-vita.patch) | Clang-only flags, missing `<cstring>`, two more platform chains, one Skia type |
| 0004 | [m2-link-check](0004-m2-link-check.patch) | An executable that makes the linker answer the M2 question |
| 0005 | [skia-target-for-vita](0005-skia-target-for-vita.patch) | `flutter/skia/BUILD.gn` — the log backend, and where `-ldl` was hiding |
| 0006 | [vita-fonts](0006-vita-fonts.patch) | `txt` gets a real font manager, plus two probes promoted out of `FML_DLOG` |

## Applying

```bash
cd third_party/flutter
git apply ../../patches/flutter-engine/000*.patch
```

**Then apply the Dart series inside the engine's Dart tree**, which is a
separate DEPS-managed repo:

```bash
cd third_party/flutter/engine/src/flutter/third_party/dart
git apply ../../../../../../../patches/dart-sdk/000[1-3]*.patch
git apply ../../../../../../../patches/dart-sdk/000[6-9]*.patch
```

Patch **0004** is the odd one: its `runtime/` half belongs in the Dart tree, but
its `build/` half does not. The engine build resolves `//build/...` to
`engine/src/build`, not to the Dart SDK's own copy, so the Dart SDK's
`build/toolchain/vita` is dead weight here and the engine needs its own —
which is what 0001 above adds. Apply only the `runtime/` hunks:

```bash
awk '/^diff --git a\/runtime\//{p=1} /^diff --git a\/build\//{p=0} p' \
  patches/dart-sdk/0004-gn-vita-toolchain.patch
```

...and drop `runtime/platform/platform_sources.gni` from that extract, because
**0009 already contains it**. The Dart patches were each regenerated with
`git diff` against the pristine tree, so where two of them touch the same file
the later one is a superset of the earlier. That is fine when applying the whole
series in order, and a trap when applying a subset.

Finally the three other DEPS-managed repos inside the checkout, each with its
own series:

```bash
cd engine/src/flutter/third_party/zlib
git apply .../patches/dart-sdk/0005-zlib-no-armv8-on-vita.patch

cd engine/src/flutter/third_party/skia
git apply .../patches/skia/0001-vita-platform-detection-and-no-mmap.patch

cd engine/src/third_party/abseil-cpp
git apply .../patches/abseil/0001-vita-has-no-elf-introspection-or-tm-gmtoff.patch
```

`flutter/third_party/tonic` is **not** one of these — it lives in the monorepo,
so its changes are in 0003 above.

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
are the same pinned commit and must carry the same changes. Check it:

```bash
A=third_party/sdk
B=third_party/flutter/engine/src/flutter/third_party/dart
(cd $B && git diff --name-only; cd $B && git ls-files --others --exclude-standard) \
  | sort -u | while read -r f; do
      diff -q "$A/$f" "$B/$f" >/dev/null 2>&1 || echo "DIVERGED: $f"
    done
```

Running this on the fresh engine checkout is what caught that patch 0008 had
gone stale. It is worth running after every change to either tree.
