# Engine

The engine under every app is Flutter 3.44.8 plus the Vita port.

**Every change this port makes is a commit in the repository that owns the
file.** There are no patch files. To read the port, read the commits below;
to change it, commit in that repository and push.

All on branch `vita-3.44.8`, all public, all forks of the repository they
change except zlib.

| Repository | Forked from | Ours |
|---|---|---|
| [flutter-vita/flutter](https://github.com/flutter-vita/flutter) | `flutter/flutter` | 17 commits on the tag `3.44.8` (`058e0af2`). `third_party/flutter` is a checkout of this branch |
| [flutter-vita/dart-sdk](https://github.com/flutter-vita/dart-sdk) | `dart-lang/sdk` | 11 commits on `d684a576` |
| [flutter-vita/skia](https://github.com/flutter-vita/skia) | `google/skia` | 1 commit on `e9ed4fc9` |
| [flutter-vita/abseil-cpp](https://github.com/flutter-vita/abseil-cpp) | `abseil/abseil-cpp` | 1 commit on `564023aa` |
| [flutter-vita/boringssl](https://github.com/flutter-vita/boringssl) | `google/boringssl` | 1 commit on `b0ae229f` |
| [flutter-vita/zlib](https://github.com/flutter-vita/zlib) | nothing to fork | 1 commit on an `import:` of `7eda07b1` |

zlib is the exception because Flutter takes it from Chromium's copy, which
GitHub does not carry: `madler/zlib` does not contain `7eda07b1`. So that one
repository begins at an import commit and `git blame` stops there. The other
five reach upstream.

`git log` and `git blame` answer for every line. `./tools/engine-tree.sh
--verify` checks that the checkout on disk is these six and nothing else.

## The engine's own changes

The 17 commits on `vita-3.44.8`, oldest first.

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
| `vita: abseil comes from our fork` | `DEPS` |
| `vita: zlib, Skia and BoringSSL come from our forks` | `DEPS` |
| `vita: the Dart SDK comes from our fork` | `DEPS`, and the last patch file goes |
| `vita: four dependencies are real forks now, not imports` | `DEPS`, once each fork sat on the upstream revision instead of an import |

The five `DEPS` commits are the story of the change itself: one added the
dependency patch files, the next three replaced them with forks, and the last
made four of those forks real forks of upstream. From `vita-3.44.8` upward,
`DEPS` names our fork for each program that changes.

## The dependencies' changes

Flutter does not contain the Dart SDK, zlib, Skia, abseil or BoringSSL.
`DEPS` names a revision of each and `gclient sync` checks them out, so a
commit on the engine fork cannot reach their files. Each one is a fork of
its own instead, on the exact revision `DEPS` named before.

| Fork | Commits |
|---|---|
| `dart-sdk` | A Vita OS layer for the Dart VM: the platform, the toolchain, newlib portability, `dart:vita`, the entry-point hooks, emulated TLS, `dart:io` for the console, the TLS record layer on the calling isolate, the socket event mask |
| `skia` | Platform detection, and a file reader in place of `mmap` |
| `abseil-cpp` | No ELF introspection, no `tm_gmtoff`, and `memalign` in place of `mmap` |
| `boringssl` | An entropy source on the console's kernel RNG |
| `zlib` | No ARMv8 code paths on this ARMv7 |

`git log <upstream-revision>..HEAD` in any of them prints our commits and
nothing else, which is also how [an upgrade is
priced](../docs/flutter-upgrade-cost.md). `gclient` checks these out shallow,
so `git fetch --unshallow` first, or read them on GitHub.

## What this directory holds

| Path | What it is |
|---|---|
| `embedder/` | The Vita embedder, `main()` and everything between the engine and the console. A submodule of [flutter-vita/flutter-vita-embedder](https://github.com/flutter-vita/flutter-vita-embedder), compiled from source into every app against the engine archive's `include/` |
| `gles2/` | `fvita_gles2`, the GLES2 over `sceGxm` that Skia draws through ([ADR-0019](../docs/adr/0019-gles2-over-gxm-written-here.md)). The template builds it from source into every app. `tools/gles2-progress.py` measures its coverage |

## Commands

```bash
./tools/engine-tree.sh --verify   # the tree and its five dependencies are in place
./tools/engine-tree.sh --list     # the commits, in all six repositories
./tools/engine-tree.sh --apply    # put the branch into a fresh checkout
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
