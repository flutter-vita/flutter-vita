# Engine

The engine under every app is Flutter 3.44.8 plus the Vita port. Its
source of truth is the fork
[flutter-vita/flutter](https://github.com/flutter-vita/flutter), branch
`vita-3.44.8`: the tag `3.44.8` (`058e0af2`), twelve commits with the
engine's Vita changes, and one commit that carries the Dart SDK, zlib,
Skia, abseil and BoringSSL patches under `engine/src/flutter/tools/vita/`,
applied by a `DEPS` hook after `gclient sync`.

What this directory holds:

| Path | What it is |
|---|---|
| `embedder/` | The Vita embedder, `main()` and everything between the engine and the console: a submodule of [flutter-vita/flutter-vita-embedder](https://github.com/flutter-vita/flutter-vita-embedder), compiled from source into every app against the engine archive's `include/`. |
| `gles2/` | `fvita_gles2`, the GLES2 over `sceGxm` that Skia draws through ([ADR-0019](../docs/adr/0019-gles2-over-gxm-written-here.md)). Built from source into every app by the template; `tools/gles2-progress.py` measures its coverage. |
| `patches/` | The same series as the fork's branch, as patch files, for `tools/apply-patches.sh --verify` against a vendored checkout. The fork is the truth; this is its export. |

The engine archive (`flutter-engine-vita-<version>`) is the fork's build:
`lib/libflutter_engine_vita.a`, `include/` with `embedder.h`, the port's
`embedder_software_frame_damage.h` and a generated `engine_version.h`, the
ICU data, the fonts, the platform dill and `gen_snapshot` for the host. The
embedder and the GL layer are not in it; the app build compiles both.

Building the engine (a 12 GB checkout and about thirty minutes) is
described in [docs/dev-environment.md](../docs/dev-environment.md);
`tools/package-engine.sh` turns a build into the artifact apps link
against, and `tools/pin-receiver-engine.sh` pins one, with the embedder
beside it, for the receiver.
