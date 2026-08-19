# Two build failures the control app found before it ever ran

`material_3_demo` is the corpus control under
[ADR-0012](../adr/0012-app-corpus-as-measurement-instrument.md): plugin-free,
one line of `main()`, the app that must work or no other result means anything.
It failed to build twice, and neither failure was about the app.

## 1. A pub workspace puts `package_config.json` somewhere else

`flutter/samples` is a **pub workspace** — one root pubspec with `workspace:`
listing its members. Pub resolves the whole tree at once and writes a single
`.dart_tool/package_config.json` at the *root*, leaving each member's own
`.dart_tool` without one. `tools/build-vita-app.sh` looked only at
`$APP_DIR/.dart_tool/package_config.json`.

What that produced was not "file not found". `frontend_server` fell back to a
*relative* `.dart_tool`, found nothing, and reported

```
lib/main.dart:5:8: Error: Not found: 'package:flutter/material.dart'
```

on every import in the program — **1,900 errors that read as a broken SDK** —
then exited 254 having printed all of it to stdout, which the build script sent
to `/dev/null`. The visible result was three lines and a silent failure.

Fixed both halves: walk up for the package config the way Dart itself does (and
say so when the answer is a workspace root), and capture `frontend_server`'s
output to a log so a failure prints its own first thirty lines instead of
nothing.

## 2. `gen_snapshot` was rejecting every kernel the SDK produces

```
==> snapshot
Can't load Kernel binary: Invalid SDK hash.
```

The SDK hash exists so a kernel built by one SDK cannot be loaded by a VM built
from another. Ours disagreed with itself:

| | |
|---|---|
| Every `app.dill` from Flutter 3.44.8's `frontend_server` | `d684a576a6` |
| `gen_snapshot_armv7` in the packaged engine | `ec223733d2` |

`ec223733` is a **local commit in the vendored Dart tree** — a phase-M3 commit
that landed the Vita platform files into the checkout instead of leaving them as
working-tree changes. `tools/make_version.py` asks git for the current revision,
so the hash it baked in was that commit rather than the pin.

`out/vita_release/args.gn` already carried the right answer:

```
dart_sdk_verification_hash = "d684a576a6"
```

but the build directory had been generated before that arg was set, so the
generated `version.cc` still held the computed value. `gn gen` was never re-run.

**The part worth remembering is why nobody noticed.** `build-vita-app.sh` skips
`gen_snapshot` when the kernel has not moved, and neither keklist nor the
gallery had changed a line of Dart. Both apps built, packaged, deployed and ran
today on a `snapshot.S` dated *yesterday*. The failure was invisible to every
app whose Dart was unchanged, and would have surfaced as "my code change had no
effect" on the first app whose Dart moved.

Two fixes, and they are independent:

- **`gn gen out/vita_release`**, which is what actually restored the hash. A
  build directory generated before an `args.gn` edit keeps the old computed
  values; the freshness guard in `package-engine.sh` caught the three stale
  steps that followed, which is what it is for.
- **`git reset --mixed d684a576` in the engine's Dart tree.** The local commit
  should not have existed. Every file it contained is already in
  `patches/dart-sdk/` — verified file by file — so nothing is lost, and
  `tools/check-dart-trees.sh` documents the commit as a blind spot for patch
  regeneration: `git diff` from HEAD reports nothing for a file changed *inside*
  it, which is how `virtual_memory_vita.cc` once went missing from a patch. The
  tree now matches `third_party/sdk`, which was always at the clean pin.
