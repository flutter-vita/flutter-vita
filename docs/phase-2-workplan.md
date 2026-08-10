# Phase 2 work plan — the Flutter engine for `arm-vita-eabi`

Written 2026-08-10, at the start of Phase 2. Companion to
[phase-2-gn-notes.md](phase-2-gn-notes.md), which was the assessment made
*before* the checkout existed. This file is what the checkout actually says.

**M2 is met when the Flutter engine links for `arm-vita-eabi` with no
unresolved symbols.**

---

## What the notes got right, and what they missed

The GN assessment holds up. Adding `vita` to the engine's build was mechanical
and took six files — and it was easier than the notes predicted, for a reason
they could not have known: **the engine already carries a non-Clang embedded
target.** `build/toolchain/qnx/BUILD.gn` is 22 lines, and every place that needs
a new branch already has an `is_qnx` one to copy. `gn gen` configures.

What the notes did not anticipate is where the remaining work actually sits. It
is not in GN and it is not in Skia. It is in two dependencies the plan never
listed, both discovered by reading `BUILD.gn` files after the sync:

### 1. The embedder depends on `dart:io`

`//flutter/shell/platform/embedder:flutter_engine` lists
`$dart_src/runtime/bin:common_embedder_dart_io` in its base `deps` —
unconditionally, not behind any renderer or platform flag. That is the whole
`dart:io` native layer.

**Phase 1 deliberately excluded `dart:io`.** Every embedder hook it worked
around — `_printClosure`, the microtask closure, the timer hooks,
`platformScript` — exists because `runtime/bin` was not in the build. The engine
puts it back.

`runtime/bin/io_impl_sources.gni` is a flat list of 91 files with per-OS `#if`
guards inside them, the same shape as `runtime/vm`. Eleven modules have a
per-platform implementation:

```
console  eventhandler  file_system_watcher  namespace  platform  process
security_context  socket  socket_base  stdio  sync_socket
```

So the shape is: **~11 new `*_vita.cc` files**, comparable in size to Phase 1's
eight. Not all need to be real. Sockets exist on Vita and are already used by
the dev tooling; `process` and `file_system_watcher` can fail honestly.
`security_context` pulls BoringSSL, and `dart_disable_secure_socket` is a
declared GN arg — turning it off is likely right and should be decided
deliberately rather than discovered at link time.

### 2. `fml` needs a platform layer, and its POSIX fallback is not portable

`//flutter/fml` is the engine's base library and everything depends on it. Its
per-OS block has no `else`: it adds `platform/linux/`, `platform/win/`,
`platform/darwin/`, `platform/fuchsia/` or, for QNX, a single `paths_qnx.cc`.
Vita will need at least

- `platform/vita/message_loop_vita.{cc,h}` — Linux's is timerfd-based
- `platform/vita/paths_vita.cc`

and separately, the `!is_win` branch adds `platform/posix/` wholesale:

```
command_line_posix  file_posix  mapping_posix  native_library_posix
paths_posix         posix_wrappers_posix       process_posix
```

Three of those seven do not exist on Vita: `mapping_posix` is `mmap`,
`native_library_posix` is `dlopen`, `process_posix` is `fork`/`exec`. This is
the same category of problem Phase 1 solved in `virtual_memory_vita.cc`, and
`mapping_posix` is the one that matters — the engine maps files for assets and
for the AOT snapshot.

## Status

| Step | State |
|---|---|
| Monorepo checked out at 3.44.8, DEPS synced | done — 12 GB |
| Dart pinned at `d684a576` inside the engine | confirmed identical to Phase 1's |
| Nine Dart patches reapplied | done, every file byte-compared |
| `gn gen` for `target_os=vita` | done — 921 targets |
| zlib, libpng, freetype2, harfbuzz, expat, ICU | build clean |
| Skia | **builds** — 544 objects, [two files patched](../patches/skia/README.md) |
| `fml` | not started — needs the platform layer above |
| Dart runtime under the engine's GN | not started |
| `dart:io` for vita | not started — the largest new item |
| `dart:ui` in the platform dill | not started |
| Link `flutter_engine` | **M2** |

## Order of work

1. ~~**Skia**~~ — done. Two files: platform detection, and a heap-copy
   replacement for `mmap`. See [the patch notes](../patches/skia/README.md);
   the `mmap` one is a memory-cost decision, not just a portability fix.
2. **`fml`**, because everything above it depends on it, and because
   `mapping_posix` is the first genuinely hard file.
3. **The Dart runtime under the engine's GN.** Release mode resolves
   `//flutter/runtime:libdart` to `libdart_aotruntime`, which is the target
   Phase 1 already builds — this should be close to free, and if it is not, the
   reason is worth knowing early.
4. **`dart:io`**, the eleven platform files.
5. **`dart:ui` into the platform dill**, via the same three-edit procedure
   `dart:vita` needed — library file, `libraries.json`, and
   `extraRequiredLibraries` in `pkg/vm/lib/modular/target/vm.dart`. Omitting the
   third produces a byte-identical dill with no error.
6. **Link.**

## Things to carry forward from Phase 1

- **Read the upstream startup path before writing embedder code.** Every one of
  M1's last failures was something `runtime/bin` does that our harness did not.
  See [embedder-startup.md](embedder-startup.md).
- **Check exit codes on every build step.** Three separate false "success"
  reports in Phase 1 came from `ninja | grep | tail`, a missing exit check, and
  a stale tool binary that ran after its rebuild had failed.
- **Never edit the vendored tree without producing a patch file.** Two series
  now: [dart-sdk](../patches/dart-sdk/README.md) and
  [flutter-engine](../patches/flutter-engine/README.md).
- **Diff the patched tree against the last known-good one.** Doing this when
  moving into the engine checkout caught that patch 0008 was stale — the
  `installPlatformScript` that makes `Isolate.spawn` work had never been written
  back, and a fresh checkout would have silently lost it.
