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
| `mmap`, `munmap`, `mprotect`, `madvise`, `getpagesize`, `prctl` | `virtual_memory_posix.cc` | **real work** — the one hard file |
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

## What must actually be written

| file | difficulty | notes |
|---|---|---|
| `virtual_memory_vita.cc` | **hard — the whole phase lives here** | see below |
| `os_thread_vita.cc` + `.h` | moderate | `os_thread_linux.cc` with four substitutions |
| `os_vita.cc` | moderate | time and sleep map cleanly; stub the code observers |
| `cpuinfo_vita.cc` | easy | fixed answers — Cortex-A9, 4 cores |
| `thread_interrupter_vita.cc` | trivial | stub it |

### Why `virtual_memory_vita.cc` is the hard one

`virtual_memory.h` demands more than "give me memory":

```
static VirtualMemory* Reserve(intptr_t size, intptr_t alignment);
static void Commit(void* address, intptr_t size);
static void Decommit(void* address, intptr_t size);
static VirtualMemory* AllocateAligned(size, alignment, is_executable, ...);
bool Protect(...);
```

**Reserve-then-commit is the problem.** Dart wants to reserve a large aligned
address range without backing it, then commit pages into it on demand. Vita's
`sceKernelAllocMemBlock` commits immediately and picks the address itself. There
is no `mmap(PROT_NONE)` equivalent to reserve with.

Options, none free:
- Reserve by allocating the full range up front and treating `Commit` as a
  no-op. Simple, but the heap's peak reservation becomes its resident size.
  With **188 MiB contiguous measured available**, this may simply be affordable —
  and that measurement makes it far more attractive than it would otherwise be.
- Emulate a reservation with a bump allocator over one big block.
- `Protect()` has no runtime equivalent: Vita fixes protection at allocation via
  the memblock type. Likely a no-op, but Dart's assumptions need checking.

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

### The one question this opened

`VirtualMemory::Protect` is still called from `code_patcher.cc` and
`heap/freelist.cc`. In the freelist it is guarded by an `is_protected` member
that tracks the code space, which AOT should never populate — but that is
inference, not yet verified.

**This matters because Vita fixes page protection at allocation time via the
memblock type; there is no runtime protection change.** If AOT genuinely never
protects, `Protect()` becomes a no-op and the file is straightforward. If it
does, we need a strategy. Worth resolving before writing the file.

## Ordered steps

1. ~~**Confirm the `is_executable` assumption.**~~ ✅ **Done — no executable
   allocation is required.** See above. Superseded by a narrower question:
   confirm that AOT never sets the freelist's `is_protected`, so
   `VirtualMemory::Protect` can be a no-op.
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

- **Does Dart tolerate a no-op `Protect()`?** Narrowed but not closed — the
  remaining callers are `code_patcher.cc` and the code-space freelist. Vita
  fixes protection at allocation, so this is the next thing to resolve.
- **Does the reserve-as-full-allocation strategy fit real Dart heap behaviour**,
  or does the heap reserve far more than it commits?
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
