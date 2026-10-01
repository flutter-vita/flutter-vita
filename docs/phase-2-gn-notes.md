# Phase 2 — the GN gate

The next gate after Phase 1's platform files is linking, and that needs GN.
This is the assessment made *before* spending the multi-gigabyte `gclient sync`,
by reading the build configuration that ships checked into the Dart SDK.

## What GN is

**GN = "Generate Ninja."** Google's meta-build system: you write `.gn`/`.gni`
config, GN generates `.ninja` files, `ninja` does the compiling. Roughly what
CMake is to Make, except GN only ever targets Ninja. Chromium, the Flutter
engine, the Dart SDK and Skia all use it — which is why "port Flutter to Vita"
necessarily includes "teach GN about `vita`".

## Tooling reality

| | |
|---|---|
| `ninja` | `brew install ninja` — trivial |
| `gn` | **not** in Homebrew, and **not** in `depot_tools` either |
| `depot_tools` | 11 MB clone, 697 MB after bootstrap |

The `gn` in `depot_tools` is a wrapper script. The real binary lives in
`buildtools/<platform>/gn` **inside the source tree**, fetched by DEPS. So
`gclient sync` is unavoidable for an actual build.

Good news for reading, though: **`build/` is checked into the Dart repo.** Only
`buildtools/` (clang, sysroots, the gn binary) comes from DEPS — so the entire
build configuration can be studied from the 486 MB shallow checkout, for free.

## The foreign-toolchain risk is lower than the plan assumed

`docs/plan.md` rates "engine GN build resists a foreign toolchain" as
**High**, and the roadmap repeated it. Reading the config, it looks
**moderate** — GN is *designed* for this:

1. **`build/toolchain/gcc_toolchain.gni` already exists** and is what Linux
   builds through. VitaSDK is GCC, so this is the same template, not a new path.
2. **`arm_toolchain_prefix` is already a declared GN arg** in
   `build/toolchain/linux/BUILD.gn`. Pointing a build at `arm-vita-eabi-` is an
   anticipated use, not a hack.
3. **`current_os` dispatch in `build/config/BUILDCONFIG.gn`** is a plain
   `if`/`else` chain setting `is_*` booleans — the same shape as the platform
   `#if` chains patch 0002 already extended, and about as mechanical.

So the work is:

- add a `vita` branch to the `current_os` chain in `BUILDCONFIG.gn`
- add `build/toolchain/vita/BUILD.gn` instantiating `gcc_toolchain()` with the
  `arm-vita-eabi-` prefix
- a config carrying the flags Phase 1 already established: `-std=gnu++20`,
  `-march=armv7-a`, `-mtune=cortex-a9`, `-mfpu=neon`, hard float
- teach `runtime/BUILD.gn` to pick up the `*_vita.cc` files

**None of that is novel.** It is the same category of work as patch 0002.

## GCC vs Clang — where the residual risk actually sits

Worth stating plainly, because it is easy to miss:

- **VitaSDK is GCC.** Its libraries, headers and `sce*` stubs were all built with
  `arm-vita-eabi-gcc` (15.2.0 here).
- **Dart and Chromium default to Clang.** That is what `buildtools/<platform>/clang`
  is in DEPS, and why `BUILDCONFIG.gn` reads
  `is_clang = current_os == "mac" || current_os == "linux"`.

A Vita build must therefore set `is_clang = false` and go through
`gcc_toolchain.gni`. That path exists and is maintained — Dart's Linux GCC builds
use it — but it is **less travelled than the Clang path**, and that is where the
"moderate" in the assessment above really lives. The risk is not "will GN accept
a foreign toolchain" (it is designed to); it is "how well-exercised is Dart's GCC
path for a cross-compiled target."

**The alternative, if the GCC path fights us:** Clang can target `arm-none-eabi`
directly, and ARM EABI is standardised enough that Clang-built objects generally
link against GCC-built libraries. That keeps Dart on its default toolchain, at
the cost of mixing compilers across the VitaSDK boundary — new risk traded for
old. Not worth attempting first, but worth remembering as an escape hatch, and
we would find out quickly either way.

## What remains genuinely unknown

- Whether the build works with a **macOS host** and an `arm-vita-eabi` target.
  Dart cross-compiles routinely, but not to a bare-metal-ish newlib target from
  a Mac. This is the real question, and it is the reason Docker is in the plan.
- What DEPS actually needs to be synced for a runtime-only build, and how large
  that is. `gclient sync` on the full Dart SDK is several GB.
- The link step will surface symbols the compile loop cannot see. **Current
  suspicion: `GetAppDSOBase` in the shared `runtime/vm/os.cc`** — on Linux it
  uses `dl_iterate_phdr`, which the Vita has no equivalent for. It compiles today
  only because nothing has linked it yet.

## Order

1. `gclient sync` the Dart SDK (multi-GB, slow)
2. `BUILDCONFIG.gn` + `build/toolchain/vita/BUILD.gn`
3. `gn gen` and iterate until it configures
4. `ninja libdart` and iterate on undefined symbols — **that list is the honest
   remainder of Phase 1**
5. Link with the armv7 snapshot [B1](phase-0.5-feasibility.md) produces, package
   with the `.vpk` harness Track A proved, run on hardware → **M1**
