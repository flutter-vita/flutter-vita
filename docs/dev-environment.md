# Development environment

Phase 0 is "Environment & Vertical Slice Foundation", so this belongs in the
repo rather than in someone's head.

## Toolchain: VitaSDK natively, Docker later

**Install VitaSDK natively on macOS via `vdpm`.** It is supported, and it is all
Track A needs. Do not reach for Docker yet.

An app build does not need this section: since 2026-10-27 the tool finds
VitaSDK or installs its base archive (`tools/vitasdk.sh`,
[Install on macOS](install-macos.md#1-vitasdk)). This setup is for a
maintainer. The bridge's installer needs vdpm's `zlib`
(`vdpm install zlib`), and `tools/build-bridge.sh` says so when it is not
there.

### Installed setup on this machine

```bash
brew install cmake
git clone https://github.com/vitasdk/vdpm ~/vdpm
cd ~/vdpm
export VITASDK="$HOME/vitasdk"
export PATH="$VITASDK/bin:$PATH"
./bootstrap-vitasdk.sh
./install-all.sh
```

Add the two `export` lines to your shell profile.

**And a third, if you rebuild the engine:**

```bash
export PATH="$HOME/depot_tools:$PATH"
```

The engine's GN build shells out to `vpython3` for several generated headers —
the Impeller flatbuffers and Dart's `version.cc`. Without it on `PATH` those
actions fail with `code=127`, ninja stops, and **any object downstream of them
is silently left at its previous contents**.

This is nastier than a normal build failure, because the stale object still
links, still packages, and still deploys — so you get a working app that does
not contain your change, and the next thing you measure is the old code. It has
cost this project twice. If an engine change appears to have no effect,
check the object's timestamp before you doubt the change:

```bash
stat -f%Sm out/vita_release/obj/flutter/shell/platform/embedder/embedder.embedder.o
```

(`tools/package-engine.sh` refuses a build with pending steps for the same
reason.) The embedder itself is not an engine object any more: it is the
`embedder` submodule, compiled into every app, so an embedder change
needs no engine build at all.

Three things worth knowing, learned the hard way:

- **Install to `$HOME/vitasdk`, not the default `/usr/local/vitasdk`.**
  `bootstrap-vitasdk.sh` honours `${VITASDK:-/usr/local/vitasdk}`, and a home
  install needs no `sudo` at any point.
- **CMake 4 breaks some library ports.** CMake 4.x hard-errors on projects
  declaring `cmake_minimum_required(VERSION <3.5)`, and several VitaSDK ports
  still do. Export `CMAKE_POLICY_VERSION_MINIMUM=3.5` before `install-all.sh`.
- **The toolchain brings the ELF tools macOS lacks.** `arm-vita-eabi-readelf`,
  `-objdump`, `-nm`, and `-size` all work on any ARM ELF, including Dart's AOT
  snapshots. Before this, section sizes had to be pulled with `objdump` and
  hand-parsed in Python; use the cross tools now.

Toolchain versions installed: GCC 15.2.0, target `arm-vita-eabi`.

Docker does earn its place, but for three separate purposes that are easy to
conflate:

1. **CI and reproducibility (Phase 4 / M4).** The plan wants GitHub Actions
   producing a `.vpk` per commit, and M4 wants a third party to reproduce the
   build from `README.md` alone. A pinned toolchain image is the honest way to
   deliver both.
2. **Building the Flutter engine for `linux-arm`** ([Phase 0.5 B3b](phase-0.5-feasibility.md)).
   This genuinely requires a Linux host — but note it is a *different* container
   for a different job: a Linux build box, not a VitaSDK image.
3. **Possibly Phase 2.** Whether the engine's GN build tolerates a custom
   `arm-vita-eabi` toolchain *on a macOS host* is **unknown** — Flutter fetches
   host-specific buildtools, and nobody has tried this. If macOS will not
   cooperate, Docker becomes the fallback. Better to discover that in Phase 2
   than to assume it now.

The compiler VitaSDK gives you, per `vitasdk/buildscripts`:

```
--with-arch=armv7-a  --with-tune=cortex-a9  --with-fpu=neon
--with-float=hard    --with-mode=thumb      --disable-multilib
```

Hard float, matching Dart and the engine — see
[Phase 0.5 B5](phase-0.5-feasibility.md). `--disable-multilib` means there is no
softfp variant to fall back on, and the Thumb default is worth remembering when
Dart's ARM-mode code has to interwork with it.

## IDE: VS Code

This project is polyglot in an unusually demanding way. It needs, at once:

- navigation over **two very large vendored C++ trees** (Flutter engine, Dart SDK)
  built with **GN/ninja**
- a **cross-compiled C11 embedder** built with **CMake** against `arm-vita-eabi`
- **Dart** for the host CLI, the companion package, and example Flutter apps

VS Code is the only editor that is genuinely good at all three. The alternatives
each fail on one axis:

| Option | C++ (engine/Dart SDK) | Embedder (CMake cross) | Dart/Flutter |
|---|---|---|---|
| **VS Code** + clangd + Dart ext | Good — the engine's own tooling targets it | Good | Best |
| CLion | Best, if you like it | Best — real CMake + debugger | Weak |
| Android Studio / IntelliJ | Poor at this scale | Poor | Best |

The tiebreaker is that **the Flutter engine team's own tooling already assumes
this setup**: `gn` emits `compile_commands.json` as part of generating ninja
files, and the engine checkout ships a clangd binary at
`buildtools/mac-arm64/clang/bin/clangd`. You are on the paved road.

If you strongly prefer CLion for C++, a defensible split is CLion for
`embedder/` and VS Code for everything else. Do not try to make one JetBrains
window serve both halves.

## The part people get wrong: use three indexes, not one

There is no single `compile_commands.json` that describes this project. Trying
to make one produces an index that is subtly wrong everywhere. Use a
**multi-root workspace** with three separately-indexed roots:

### 1. Vendored engine + Dart SDK — index from the *host* build

Do **not** index these from the Vita cross-build. Index them from a normal host
build (`out/host_debug_unopt`), because that is where GN produces a complete and
correct `compile_commands.json`, and it is the same source you are reading.

```jsonc
// .vscode/settings.json
{
  "clangd.path": "<engine>/src/buildtools/mac-arm64/clang/bin/clangd",
  "clangd.arguments": ["--compile-commands-dir=out/host_debug_unopt"]
}
```

You are using the host build purely as a *navigation aid*. The Vita build is for
producing artifacts, not for reading code.

### 2. `embedder/` — index from CMake with the VitaSDK toolchain

VitaSDK ships a CMake toolchain file. Configure with:

```bash
cmake -B build -DCMAKE_TOOLCHAIN_FILE=$VITASDK/share/vita.toolchain.cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

**Gotcha:** clangd will not know where `arm-vita-eabi-gcc` keeps its system
headers, so every `#include <psp2/...>` will show a spurious error. Fix it by
letting clangd interrogate the cross compiler:

```yaml
# embedder/.clangd
CompileFlags:
  CompilationDatabase: build
  Add: [--target=armv7a-none-eabi]
Diagnostics:
  UnusedIncludes: Strict
```

plus `"clangd.arguments": ["--query-driver=$VITASDK/bin/arm-vita-eabi-*"]`.
Without `--query-driver`, clangd refuses to trust the cross compiler's include
paths and the whole embedder lights up red.

### 3. `tool/`, `plugins/`, `examples/` — the Dart extension

Nothing special. The official Dart and Flutter extensions handle these.

## Expect the C++ index to be heavy

The engine plus Dart SDK is millions of lines. The first clangd background index
takes a long while and a few GB. This is normal and it is worth waiting out —
most of Phase 1 and Phase 2 is reading vendored code you did not write, and
working "go to definition" across `runtime/vm/` is the difference between a
tractable port and a miserable one.

## Debugging reality check

On-device debugging is effectively unavailable: the loop is network logs and
`psp2shell`. So IDE *debugger* integration matters less than usual for the Vita
side, and IDE *navigation* matters much more. Optimise your setup for reading.

Where a real debugger does earn its keep:

- host-side Dart tooling (`flutter-vita`, in `cli/`)
- the `linux-arm` engine build from
  [Phase 0.5 track B3](phase-0.5-feasibility.md#sequencing), which runs under a
  normal debugger and is a much cheaper place to find Dart-runtime bugs than a Vita

## Sources

- https://github.com/vitasdk/vita-toolchain
- https://github.com/flutter/flutter/wiki/Setting-up-the-Engine-development-environment
- https://github.com/flutter/flutter/wiki/Compiling-the-engine
