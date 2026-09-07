# Phase 1 work plan — porting the Dart runtime to Vita

Derived from the source, not estimated. **No timeframes here on purpose**: the
plan's "2–4 months" was inherited with no derivation behind it, and every other
number in this project is measured. What follows is *scope* — what must be
written, what already exists, and what is genuinely unknown.

## Method (reproducible)

1. Listed the platform-specific files in `runtime/vm/` at the pinned Dart SDK
   commit `d684a576` (the one Flutter 3.44.8 ships).
2. Extracted the interface each must implement from `os.h`, `os_thread.h`,
   `virtual_memory.h`, `cpuinfo.h`.
3. Pulled the Linux implementations and extracted every libc/POSIX call they make.
4. Diffed that against the symbols VitaSDK actually defines, by running
   `arm-vita-eabi-nm` over `libc.a`, `libpthread.a`, `libm.a` and all
   `libSce*_stub.a` — **1,778 defined symbols**.

## Headline finding: VitaSDK has pthreads

The plan lists *"pthread absence"* as an expected newlib gap. **It is wrong.**
VitaSDK ships a real `libpthread.a`:

| | |
|---|---|
| `pthread_create`, `pthread_join` | present |
| `pthread_mutex_*`, `pthread_cond_wait`, `pthread_cond_timedwait` | present |
| `pthread_key_create`, `pthread_getspecific`, `pthread_setspecific` (TLS) | present |
| `pthread_attr_setstacksize` | present |
| `clock_gettime`, `gettimeofday`, `nanosleep`, `sched_yield`, `sysconf` | present |

`os_thread_linux.h` is essentially just `typedef pthread_t ThreadJoinId;` — the
platform header is trivial, and the threading substrate question
([open questions](adr/README.md)) largely answers itself: **use the pthread
shim, because Dart and the engine's C++ both already target it.**

## The complete gap list — 12 symbols

Every POSIX call the Dart platform layer makes that VitaSDK does not define:

| symbol | needed by | verdict |
|---|---|---|
| `mmap`, `munmap`, `mprotect`, `madvise`, `getpagesize`, `prctl` | `virtual_memory_posix.cc` | **the only real work** — but far less than the symbol list suggests; `mprotect`/`madvise`/`prctl` serve paths unreachable on ARM AOT |
| `mmap`, `munmap`, `getpagesize`, `syscall` | `os_linux.cc` | **out of scope** — only used by the `perf` jitdump code observer |
| `pthread_getattr_np` | `os_thread_linux.cc` | **real, small** — stack bounds |
| `pthread_setname_np`, `pthread_getname_np` | `os_thread_linux.cc` | trivial — thread naming, or a no-op |
| `sigemptyset`, `sigaddset` | `os_thread_linux.cc` | **out of scope** — `UnblockSIGPROF`, the profiler |
| `syscall` (`__NR_gettid`) | `os_thread_linux.cc` | trivial — `sceKernelGetThreadId` |

### The reclassification that matters

Reading the call sites rather than the symbol names changes the picture
substantially. **Most of these gaps are profiler and timeline plumbing, which is
already out of scope** (no DevTools — see the non-goals):

- `os_linux.cc`'s `mmap` is `PROT_READ | PROT_EXEC` on a file descriptor inside
  the **perf jitdump code observer**. Stub `RegisterCodeObservers` and it vanishes.
- `sigemptyset`/`sigaddset` are inside `UnblockSIGPROF()`. No profiler, no signals.
- `syscall(__NR_gettid)` is for `setpriority` and `GetCurrentThreadTraceId`,
  i.e. timeline support.

`thread_interrupter_vita.cc` is likewise a **stub** — the thread interrupter is
the sampling profiler, and it needs POSIX signals the Vita does not have.

## Build reality, and what the compiler found that this inventory missed

**A full Dart build needs `depot_tools` and a multi-gigabyte `gclient sync`.**
None of `gclient`, `gn` or `ninja` is installed, and standing all that up is
really Phase 2 work. So Phase 1 uses a lighter loop:
[`experiments/p1-compile-check/check.sh`](../experiments/p1-compile-check/check.sh)
compiles individual runtime sources with `arm-vita-eabi-g++` against the real
headers. It does not link and is no substitute for the GN build, but it catches
most mistakes immediately instead of after a multi-GB bring-up.

The tree is a shallow checkout at the pinned commit (486 MB), gitignored;
edits are captured as an ordered series in
[`patches/dart-sdk/`](../../patches/dart-sdk/README.md).

**Within minutes the compiler found three things this inventory did not:**

1. **`runtime/platform/globals.h` must be patched.** Dart detects its host OS
   from compiler predefines and hard-errors on anything unrecognised. VitaSDK's
   GCC defines **`__vita__`**, so the chain gains a branch — plus three
   dependent switches (`DART_TARGET_OS_*`, `kTargetOperatingSystemName`,
   `kHostOperatingSystemName`) that each hard-error independently.
2. **A sixth file: `runtime/platform/utils_vita.h`.** `utils_linux.h` includes
   `<endian.h>`, which newlib does not have. Also `strerror_r` is not exposed
   under VitaSDK's feature-test defaults.
3. **C++20 is mandatory** — Dart uses `std::bit_cast`, `std::has_single_bit`
   and `std::bit_ceil`. Building with C++17 produces a wall of unrelated-looking
   errors that would be easy to misdiagnose.

None of these were visible from reading interfaces and diffing symbol tables.
That is the argument for standing up a compile loop before writing the files
rather than after.

**Status: patch 0001 applied and verified — Dart runtime headers now compile for
`arm-vita-eabi` with a real `vita` target OS.**

## What must actually be written

| file | difficulty | notes |
|---|---|---|
| `platform/utils_vita.h` | ✅ **done** | patch 0001 — no `endian.h`, no `strerror_r` |
| `platform/globals.h` patch | ✅ **done** | patch 0001 — `__vita__` detection |
| `virtual_memory_vita.cc` | **straightforward** (revised down twice — see below) | allocate aligned memory and free it; no protection, no reserve/commit |
| `os_thread_vita.cc` + `.h` | ✅ **done** | patch 0003 — pthreads plus four substitutions |
| `os_vita.cc` | ✅ **done** | patch 0003 — time, sleep, print |
| `cpuinfo_vita.cc` | ✅ **done** | patch 0003 — fixed answers |
| `thread_interrupter_vita.cc` | ✅ **done** | patch 0003 — stubs |

**All seven Vita files compile.** Verified by
[`experiments/p1-compile-check/check.sh`](../experiments/p1-compile-check/check.sh):

```
  probe.cc                           OK
  cpuinfo_vita.cc                    OK
  thread_interrupter_vita.cc         OK
  virtual_memory_vita.cc             OK
  os_thread_vita.cc                  OK
  os_vita.cc                         OK
  cpu_arm.cc                         OK
```

**Compiling is not working.** Nothing here has been linked or run. The next gate
is GN — `depot_tools`, `gclient sync`, and a toolchain definition for
`arm-vita-eabi` — and that is where Phase 2's unknown about foreign toolchains
on a macOS host arrives.

### `virtual_memory_vita.cc`: what it actually has to do

`virtual_memory.h` looks, at first, like it demands much more than "give me memory":

```
static VirtualMemory* Reserve(intptr_t size, intptr_t alignment);
static void Commit(void* address, intptr_t size);
static void Decommit(void* address, intptr_t size);
static VirtualMemory* AllocateAligned(size, alignment, is_executable, ...);
bool Protect(...);
```

### ✅ Reserve/Commit resolved: never called on 32-bit ARM

This looked like the one genuinely hard problem in Phase 1 — Dart reserving
address space without backing it, against a `sceKernelAllocMemBlock` that
commits immediately at an address of its choosing, with no `mmap(PROT_NONE)` to
reserve with.

**It does not arise.** Three facts, checked at the pinned commit:

1. **`Reserve`, `Commit` and `Decommit` are `private`** in `virtual_memory.h` —
   internal helpers of `VirtualMemory`, not part of the interface a platform
   port exposes to the rest of the VM.
2. **Every call site is inside `#if defined(DART_COMPRESSED_POINTERS)`** —
   `Reserve` for the compressed heap reservation, `Commit` in the
   `is_compressed` branch of `AllocateAligned`, `Decommit` in the destructor's
   compressed-heap path. There are no others.
3. **Compressed pointers are off.** `TARGET_ARCH_ARM` maps to
   `TARGET_ARCH_IS_32_BIT` in `platform/globals.h`, the feature exists only to
   compress 64-bit pointers, and `runtime_args.gni` defaults
   `dart_use_compressed_pointers = false` — a GN arg we control.

So `Reserve`/`Commit`/`Decommit` can be `UNREACHABLE()` alongside `Protect()`.

### What is actually left in the file

| | |
|---|---|
| `Init` / `Cleanup` / `PageSize` / `CalculatePageSize` | trivial |
| `AllocateAligned` (non-executable, uncompressed) | the substance |
| `Free` (destructor) / `FreeSubSegment` | see wrinkle below |
| `Protect`, `Reserve`, `Commit`, `Decommit` | `UNREACHABLE()` |
| `ForImagePage`, `DuplicateRX`, dual-mapping | shared code or out of scope |

**Allocate aligned memory and free it.** That is the whole file.

#### The one remaining wrinkle: `FreeSubSegment`

POSIX `AllocateAligned` over-allocates by `alignment - PageSize()` and trims the
excess with `FreeSubSegment`. **Vita cannot trim a memblock** — `sceKernelFreeMemBlock`
frees the whole allocation, not part of one. Two ways out:

- Use `SceKernelAllocMemBlockOpt` to request the alignment directly, so no trim
  is needed. Cleanest if the option behaves.
- Over-allocate and simply not reclaim the slack. Wasteful, but with **188 MiB
  contiguous measured** the waste is affordable.

This is a detail to settle while writing the file, not a design risk.

Two things that reduce the difficulty:

- **Compressed pointers are off on 32-bit ARM**, so the huge aligned reservation
  that `is_compressed` normally forces does not apply.
- **`is_executable` is not needed — confirmed 2026-08-07.** See below.

### ✅ Step 1 resolved: no executable allocation required

The question was whether `virtual_memory_vita.cc` must ever hand back
executable memory. **It does not.** Four independent lines of evidence at the
pinned commit:

1. **Fresh executable pages come only from the heap's code space.**
   `Page::Allocate` sets `kExecutable` from an `is_exec` flag that flows from
   `PageSpace` allocations into code space. Under AOT, code lives in the
   snapshot image, not in freshly allocated heap pages.
2. **`ForImagePage` allocates nothing at all**, and it lives in the shared
   `virtual_memory.cc`, not the platform file. Its comment states the
   architecture outright:
   > *"Memory for precompilated instructions was allocated by the embedder, so
   > create a VirtualMemory without allocating."*

   That is precisely [ADR-0005](adr/0005-aot-snapshot-delivery.md): the embedder
   allocates the VM-domain block, writes the snapshot, flips it executable, and
   hands over the pointer. `ForImagePage` wraps it. **The two designs already
   agree — Dart expects exactly what we intend to do.**
3. **`DuplicateRX` is Mac-only** — its body is Mach `vm_remap`, present because
   iOS forbids allocating new executable memory.
4. **`ShouldDualMapExecutablePages` is gated on `DART_ENABLE_RX_WORKAROUNDS`**,
   which is iOS-only, and `ffi_callback_metadata.cc` sets `is_executable = false`
   on every non-macOS host.

**Consequence:** `virtual_memory_vita.cc` can `ASSERT(!is_executable)` and
ignore the parameter. `DuplicateRX`, `ShouldDualMapExecutablePages` and
`OffsetToExecutableAlias` all leave scope. The file's remaining problem is
purely the Reserve/Commit semantics above — real, but a much smaller and better
understood problem than "implement W^X without `mprotect`".

### ✅ And the follow-up question is closed too: `Protect` is unreachable

Vita fixes page protection at allocation via the memblock type and offers no
runtime change, so `VirtualMemory::Protect` was the last thing that could have
forced an awkward design. **It is never called on ARM AOT.** All three call
paths, checked:

1. **`code_patcher.cc`** — its `WritableInstructionsScope`, the only `Protect`
   caller in the file, is inside `#if defined(TARGET_ARCH_IA32)`. **Not compiled
   on ARM at all.**
2. **`heap/freelist.cc`** — reached only when the freelist `is_protected`, and
   `pages.h` defines that as:
   ```cpp
   bool is_protected = (is_executable) && FLAG_write_protect_code;
   ```
   Step 1 established `is_executable` is always false under AOT, so this is
   false regardless of the flag. Note also the flag's own description —
   *"Write protect **jitted** code"*. It is a JIT concept.
3. **`ffi_callback_metadata.cc`** — its `WriteProtectCode` and `Protect` calls
   sit inside `if (should_remap_stub_page)`, and on non-macOS that is
   `const bool should_remap_stub_page = false;  // No support for remapping.`
   A compile-time constant, with a `static_assert(!should_remap_stub_page, ...)`
   in the same branch confirming it.

**Consequence:** `Protect()` can be `UNREACHABLE()` in `virtual_memory_vita.cc`.
No protection semantics are needed anywhere in the file.

### Revised difficulty

With both questions closed, `virtual_memory_vita.cc` is **not** the exotic file
it looked like. Its entire remaining surface is:

| | |
|---|---|
| `Init` / `Cleanup` / `PageSize` / `CalculatePageSize` | trivial |
| `AllocateAligned` (non-executable only) | ordinary |
| `Reserve` / `Commit` / `Decommit` | **the one real problem** |
| `Free` / `FreeSubSegment` | ordinary |
| `Protect` | `UNREACHABLE()` |
| `ForImagePage` | shared code, nothing to write |
| `DuplicateRX`, dual-mapping | out of scope |

That is an aligned allocator with reserve/commit semantics on top of
`sceKernelAllocMemBlock` — **moderate, not hard.** The difficulty rating in the
table above is revised accordingly.

## Ordered steps

1. ~~**Confirm the `is_executable` assumption**, and the `Protect` question it
   opened.~~ ✅ **Both done.** No executable allocation is required, and
   `Protect` is unreachable on ARM AOT through all three call paths. See above.
2. **`cpuinfo_vita.cc` and `thread_interrupter_vita.cc`** — stubs. Gets the file
   set complete so the build can be attempted early.
3. **`virtual_memory_vita.cc`** — decide the Reserve/Commit strategy against the
   188 MiB measurement, then implement.
4. **`os_thread_vita.cc`** — start from `os_thread_linux.cc`; replace
   `pthread_getattr_np` with `sceKernelGetThreadInfo` for stack bounds, thread
   naming with the `sceKernelCreateThread` name argument or a no-op,
   `syscall(__NR_gettid)` with `sceKernelGetThreadId`, and drop the SIGPROF
   handling.
5. **`os_vita.cc`** — time, sleep, and print. Stub `RegisterCodeObservers`.
6. **Build and iterate to M1** — a pure-Dart AOT hello world on hardware, using
   the armv7 snapshot [B1](phase-0.5-feasibility.md) already produces.

## What is still genuinely unknown

The scope above is derived. These are not, and they are where the risk actually
sits:

- ~~**Does Dart tolerate a no-op `Protect()`?**~~ Closed — it is never called.
- ~~**Does the reserve-as-full-allocation strategy fit real Dart heap behaviour?**~~
  Closed — reserve/commit is compressed-pointers-only and never runs on 32-bit ARM.
- **Thread count and stack commitment.** How many OS threads Dart plus the
  engine want at steady state, against Vita's limits. Still open —
  exit criterion 6 of [Phase 0.5](phase-0.5-feasibility.md), deliberately left
  to this phase.
- **GC under a foreign memory allocator.** The plan's own risk register calls
  this out and it remains right to.

## Useful discovery

`runtime/docs/qemu.md` exists in the Dart SDK — upstream documents running the
runtime under QEMU. Worth reading before Phase 1: it may offer a debugging path
for the runtime port that does not require deploying to hardware every cycle,
which is directly relevant to the iteration-cost problem in
[the open questions](adr/README.md).
