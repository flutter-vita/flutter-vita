# Engine

The engine under every app is Flutter 3.44.8 plus the Vita port. Its source
of truth is the fork [flutter-vita/flutter](https://github.com/flutter-vita/flutter),
branch `vita-3.44.8`. The branch is the tag `3.44.8` (`058e0af2`) plus the
commits below.

`third_party/flutter` is a checkout of that branch, so `git log` and
`git blame` answer for every line of the port. There is no patch series for
the engine. An engine change is a commit, and `git push fork vita-3.44.8`
publishes it.

## The engine's own changes

| Commit | What it does |
|---|---|
| `gn: a vita target os` | GN learns `target_os=vita`, and which renderers it builds |
| `fml: the vita platform, and no mmap` | `fml` learns the platform and stops using `mmap` |
| `engine: the sources build with the vita toolchain` | Clang-only flags, a missing `<cstring>`, two platform chains, one Skia type |
| `embedder: static guards and the link check for the Vita` | The C++ runtime's static guards, and an executable that makes the linker answer the M2 question |
| `skia: a vita target` | `flutter/skia/BUILD.gn`: the font backend, the log backend, and where `-ldl` was hiding |
| `txt: a font manager for the Vita` | `txt` gets a font manager that reads the app's own directory |
| `shell: partial repaint in the software path` | The software surface reports its damage rectangle to the embedder |
| `embedder: GL without Impeller` | Two upstream files assume that GL means Impeller |
| `ui: time paragraph construction, build and layout` | This port has no profiler, so the engine times paragraphs itself |
| `shell: a report of where the memory goes` | Every 60 draws: Skia's resource cache, the raster cache, the glyph cache, the unref queue |
| `ui: delete a snapshot's texture on the raster context` | The unref queue has no resource context here, and dropped every texture ([the record](../docs/results/snapshot-textures-2026-09-12.md)) |
| `shell: --verbose_gc allowed in release on __vita__` | The embedder passes it when `ux0:data/flutter-vita/gc.on` starts with `1` ([the record](../docs/results/ui-thread-list-churn-2026-09-13.md)) |
| `vita: the dependency patches, applied by a DEPS hook` | The patch files for the five dependencies below, and the hook that applies them |

## The dependencies' changes

Five programs also change: the Dart SDK, zlib, Skia, abseil and BoringSSL.
Flutter does not contain them. `DEPS` names a revision of each, and
`gclient sync` checks them out. A commit on the fork cannot reach them.

Their changes are patch files inside the fork, under
`engine/src/flutter/tools/vita/patches/`, one directory for each program. The
`vita_patches` hook in `DEPS` applies them after every sync.

| Directory | What the change is |
|---|---|
| `patches/dart/` | A Vita OS layer for the Dart VM: platform dispatch, `runtime/bin` (sockets, files, the event handler), emulated TLS, the entry-point hooks, the SSL filter on the isolate |
| `patches/zlib/` | No ARMv8 code paths on this ARMv7 |
| `patches/skia/` | Platform detection, and a file reader in place of `mmap` |
| `patches/abseil/` | No ELF introspection, no `tm_gmtoff`, and `memalign` in place of `mmap` |
| `patches/boringssl/` | An entropy source on the console's kernel RNG |

**These five will become forks.** Then each change is a commit in the
repository it belongs to, `DEPS` names our forks, and the patch files and the
hook go away. The Dart SDK is the largest, at 4 834 lines, and goes last.

## What this directory holds

| Path | What it is |
|---|---|
| `embedder/` | The Vita embedder, `main()` and everything between the engine and the console. A submodule of [flutter-vita/flutter-vita-embedder](https://github.com/flutter-vita/flutter-vita-embedder), compiled from source into every app against the engine archive's `include/` |
| `gles2/` | `fvita_gles2`, the GLES2 over `sceGxm` that Skia draws through ([ADR-0019](../docs/adr/0019-gles2-over-gxm-written-here.md)). The template builds it from source into every app. `tools/gles2-progress.py` measures its coverage |

## Commands

```bash
./tools/apply-patches.sh --verify   # the tree is the branch, the hook is satisfied
./tools/apply-patches.sh --list     # the commits, and the dependency patches
./tools/apply-patches.sh --apply    # put the branch into a fresh checkout
```

## The engine artifact

`flutter-engine-vita-<version>` is the fork's build:
`lib/libflutter_engine_vita.a`, `include/` with `embedder.h`, the port's
`embedder_software_frame_damage.h` and a generated `engine_version.h`, the ICU
data, the fonts, the platform dill, and `gen_snapshot` for the host. The
embedder and the GL layer are not in it. The app build compiles both.

To build the engine you need a 12 GB checkout and about thirty minutes. See
[docs/dev-environment.md](../docs/dev-environment.md).
`tools/package-engine.sh` turns a build into the artifact that apps link
against. `tools/pin-receiver-engine.sh` pins one, with the embedder beside it,
for the receiver.
