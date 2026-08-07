# Dart SDK patches

Ordered patch series against the pinned Dart SDK commit in
[VERSIONS.md](../../VERSIONS.md) (`d684a576`, the one Flutter 3.44.8 ships).

Per the project's working agreement: **never edit the vendored tree without
producing a patch file.** The tree at `third_party/dart-sdk` is gitignored and
disposable; these patches are the real artifact.

| # | Patch | What it does |
|---|---|---|
| 0001 | [add-vita-host-and-target-os](0001-add-vita-host-and-target-os.patch) | Teaches Dart that `vita` is a platform |

## Applying

```bash
cd third_party/dart-sdk
git apply ../../patches/dart-sdk/*.patch
```

## Regenerating after edits

```bash
cd third_party/dart-sdk
git add -N .                       # so new files appear in the diff
git diff > ../../patches/dart-sdk/0001-add-vita-host-and-target-os.patch
```

## Checking out the tree from scratch

```bash
mkdir -p third_party/dart-sdk && cd third_party/dart-sdk
git init -q
git remote add origin https://dart.googlesource.com/sdk.git
git fetch --depth 1 origin d684a576a6aa954ae107a03b2b4e1d61c3bebe93
git checkout FETCH_HEAD
```

A shallow fetch is ~486 MB. Note this is **not** a `gclient sync` — no DEPS are
fetched, so this tree is enough to read, edit and *compile* runtime sources
against, but not yet to run the full GN build. See
[the Phase 1 work plan](../../docs/phase-1-workplan.md).

---

## 0001 — add vita host and target OS

Dart detects its host OS from compiler predefines and hard-errors on anything
unrecognised. VitaSDK's GCC defines **`__vita__`**, so the detection chain gains
one branch, and three dependent switch blocks gain a `vita` case.

Four edits to `runtime/platform/globals.h`:

1. host OS detection chain → `DART_HOST_OS_VITA`
2. the "no target OS specified, match the host" block → `DART_TARGET_OS_VITA`
3. `kTargetOperatingSystemName` → `"vita"`
4. `kHostOperatingSystemName` → `"vita"`

Plus `runtime/platform/utils.h` selecting the new header, and a new
`runtime/platform/utils_vita.h`.

### Why `utils_vita.h` exists rather than reusing `utils_linux.h`

`utils_linux.h` includes `<endian.h>`, which **newlib does not provide**. The
Vita is little-endian ARMv7, so the little-endian conversions are the identity
and the big-endian ones are `__builtin_bswap*`.

It also replaces `strerror_r` with `strerror`: newlib does not expose the POSIX
`strerror_r` under VitaSDK's feature-test defaults (it offers `_strerror_r`).
Only used on error paths, so the thread-safety difference is acceptable.

### Verified

```
arm-vita-eabi-g++ -std=c++20 -c probe.cc \
  -I. -Iruntime -Iruntime/include \
  -DDART_PRECOMPILED_RUNTIME -DTARGET_ARCH_ARM -DPRODUCT -DNDEBUG
```

compiles a translation unit including `vm/virtual_memory.h` cleanly. Reproduce
with [`spikes/p1-compile-check/check.sh`](../../spikes/p1-compile-check/check.sh).

**Note C++20 is required** — Dart uses `std::bit_cast`, `std::has_single_bit`
and `std::bit_ceil`. C++17 fails with a wall of unrelated-looking errors.
