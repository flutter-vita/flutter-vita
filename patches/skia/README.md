# Skia patches

Against `e9ed4fc9`, the `skia_revision` pinned by the Flutter monorepo at
`3.44.8`. Skia is its own DEPS-managed repo inside the engine checkout, so these
are not covered by the [flutter-engine](../flutter-engine/README.md) series.

| # | Patch | What it does |
|---|---|---|
| 0001 | [vita-platform-detection-and-no-mmap](0001-vita-platform-detection-and-no-mmap.patch) | Makes Skia recognise the Vita, and gives it a file mapping that does not need `mmap` |

## Applying

```bash
cd third_party/flutter/engine/src/flutter/third_party/skia
git apply ../../../../../../../patches/skia/0001-vita-platform-detection-and-no-mmap.patch
```

---

## 0001 — platform detection and the missing `mmap`

Two files, and they are the *entire* Vita delta for Skia. 544 objects compile
for `arm-vita-eabi` with nothing else changed, which is a better result than the
roadmap assumed.

### `include/private/base/SkFeatures.h`

VitaSDK's GCC defines exactly one interesting predefine: `__vita__`. It does not
define `__unix__`. So Skia's platform chain fell all the way through to its
final `#else` and concluded it was **building for macOS** — the first symptom
was `SkSemaphore.cpp` reaching for `<dispatch/dispatch.h>`.

Adding `__vita__` to the `SK_BUILD_FOR_UNIX` arm fixes it, and fixes it
everywhere at once rather than file by file. The Vita is close enough to Unix
for what Skia asks of it: real pthreads, POSIX semaphores (`sem_init` and
friends are in VitaSDK's `semaphore.h`), and `open`/`read`/`close`.

What it does not have is `mmap`, which is the other half of this patch.

### `src/ports/SkOSFile_posix.cpp`

`<sys/mman.h>` does not exist, so `sk_fdmmap` needs a different implementation.

**Returning `nullptr` would have been the smaller change and it would have been
wrong.** `SkData::MakeFromFileName` has no fallback path — a null from
`sk_fdmmap` propagates straight out as a null `SkData` — so every font and image
Skia loads by path would have failed to load, silently, at runtime rather than
at build time. That is precisely the class of bug this project keeps paying for.

Instead the Vita branch reads the file into the heap and frees it in
`sk_fmunmap`. To the caller that is the same contract: a read-only snapshot of
the contents, released through the same function. Two details matter:

- `mmap` ignores the descriptor's file position, so the read seeks to 0 and
  restores the original offset afterwards — the caller still owns the `FILE*`.
- Allocation is `sk_malloc_canfail`, not `sk_malloc`, because a failed map is a
  documented outcome and an out-of-memory abort is not.

The cost is real and should be stated: a mapped file becomes a heap copy, on a
device whose largest contiguous allocation measured 188 MiB. If asset loading
becomes a memory problem later, this function is where to look first.
