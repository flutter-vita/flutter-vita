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

Finally, zlib, also its own repo:

```bash
cd third_party/flutter/engine/src/flutter/third_party/zlib
git apply ../../../../../../../patches/dart-sdk/0005-zlib-no-armv8-on-vita.patch
```

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

## Verified so far

`gn gen` configures 921 targets, and `//flutter/third_party/zlib` compiles for
`arm-vita-eabi` with

```
-march=armv7-a -mfloat-abi=hard -mtune=cortex-a9 -mthumb -mfpu=neon
```

on the command line. That is the toolchain proven end to end; it is not yet
evidence about the engine's own sources.
