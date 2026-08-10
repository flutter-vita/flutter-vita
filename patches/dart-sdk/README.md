# Dart SDK patches

Ordered patch series against the pinned Dart SDK commit in
[VERSIONS.md](../../VERSIONS.md) (`d684a576`, the one Flutter 3.44.8 ships).

Per the project's working agreement: **never edit the vendored tree without
producing a patch file.** The tree at `third_party/sdk` is gitignored and
disposable; these patches are the real artifact.

| # | Patch | What it does |
|---|---|---|
| 0001 | [add-vita-host-and-target-os](0001-add-vita-host-and-target-os.patch) | Teaches Dart that `vita` is a platform |
| 0002 | [route-vita-through-platform-dispatch](0002-route-vita-through-platform-dispatch.patch) | Adds `vita` to every per-OS `#if` chain that hard-errors |
| 0003 | [vita-platform-implementations](0003-vita-platform-implementations.patch) | The Vita platform files themselves |
| 0004 | [gn-vita-toolchain](0004-gn-vita-toolchain.patch) | Teaches the GN build about `vita` |
| 0005 | [zlib-no-armv8-on-vita](0005-zlib-no-armv8-on-vita.patch) | **Applies to `third_party/zlib`, a separate repo** |
| 0006 | [newlib-portability-fixes](0006-newlib-portability-fixes.patch) | Shared Dart sources that assume glibc or "not POSIX means Windows" |
| 0007 | [vmlibraryhooks-entry-point](0007-vmlibraryhooks-entry-point.patch) | Marks `VMLibraryHooks` and its fields `vm:entry-point` so an embedder can install the timer hooks. **Affects the platform dill, not the runtime** — rebuild `vm_platform_product.dill`, not just the runtime |
| 0008 | [dart-vita-embedder-library](0008-dart-vita-embedder-library.patch) | Adds `dart:vita`, the Dart-side embedder shim. **Three files**: the library, `libraries.json`, and the VM target's `extraRequiredLibraries` — omitting the last produces a byte-identical dill with no error |
| 0009 | [vita-emulated-tls](0009-vita-emulated-tls.patch) | Replaces libgcc's `__emutls_get_address`. **Without this every `thread_local` in the runtime is one shared global**, because `__gthread_active_p()` is a weak reference to `pthread_cancel` that never links — and forcing it in crashes instead, since emutls uses a statically initialised pthread mutex VitaSDK does not support |

| 0010 | [runtime-bin-for-vita](0010-runtime-bin-for-vita.patch) | `dart:io`'s native layer, plus dropping `-latomic`. **New in Phase 2** — the engine's embedder depends on `runtime/bin` unconditionally, which Phase 1 excluded |

> **Two trees now hold this series.** `third_party/sdk` is Phase 1's standalone
> checkout, still used by `spikes/m1-vpk`; `third_party/flutter/engine/src/flutter/third_party/dart`
> is the engine's, at the same pinned commit. They must stay byte-identical, and
> there is a one-liner that checks it — see
> [the engine patch notes](../flutter-engine/README.md#keeping-the-two-dart-trees-identical).
> Patch 0008 was found stale exactly this way.

All three are verified to compile with
[`spikes/p1-compile-check/check.sh`](../../spikes/p1-compile-check/check.sh).

## Applying

```bash
cd third_party/sdk
git apply ../../patches/dart-sdk/000*.patch
```

## Regenerating after edits

```bash
cd third_party/sdk
git add -N .                       # so new files appear in the diff
git diff > ../../patches/dart-sdk/0001-add-vita-host-and-target-os.patch
```

## Checking out the tree from scratch

**Let `gclient` own the whole checkout.** `third_party/.gclient` pins the
revision and `managed: True`, so one command does everything:

```bash
cd third_party
PATH="$HOME/depot_tools:$PATH" gclient sync --nohooks --no-history --shallow
cd sdk
git apply ../../patches/dart-sdk/000[1-46]*.patch
git -C third_party/zlib apply ../../../../patches/dart-sdk/0005-zlib-no-armv8-on-vita.patch
```

**0005 applies to a different repo.** `third_party/zlib` is its own DEPS-managed
git checkout, so it is not covered by a diff taken at the sdk root.

~7.8 GB and slow, but deterministic. It brings `buildtools/gn`, `buildtools/ninja`
and clang, which a plain `git clone` does not — those come from DEPS.

> **Do not hand-assemble this checkout, and never `rsync` into it.** DEPS
> sub-repos are recorded with gitlinks that a file copy silently corrupts; the
> failures surface later as *"not a git repository"* on a different directory
> each sync, and are not worth repairing piecemeal. This was learned the hard
> way: the tree was rebuilt from scratch, and the patch series restored the
> entire port in one command. That is exactly what the patch discipline is for.

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


---

## 0002 — route vita through platform dispatch

Dart has **six** independent per-OS `#if` chains that each hard-error on an
unknown platform, and they only reveal themselves one compile at a time:

| file | what it selects |
|---|---|
| `platform/threads.h` | `ThreadId` — 5 separate pthread-platform lists |
| `platform/synchronization.h` | `MutexImpl` / `ConditionVariableImpl` |
| `platform/synchronization_posix.cc` | whether the POSIX implementation compiles at all |
| `vm/os_thread.h` | which `os_thread_<os>.h` to include |
| `vm/constants_arm.h` | VFPv3-D16 vs D32 |
| `vm/signal_handler.h` | the `siginfo_t` / `mcontext_t` includes |

Vita joins the pthread group everywhere, because **VitaSDK ships a real
`libpthread`** over `sceKernel` threads. `os_thread_vita.h` is consequently
identical to `os_thread_linux.h`: a single `typedef pthread_t ThreadJoinId`.

Two are not routine:

- **`constants_arm.h` → `VFPv3_D32`.** Cortex-A9 with the NEON media engine has
  all 32 double registers, and VitaSDK builds `-mfpu=neon`. Choosing D16 would
  silently halve the register file the compiler believes it has.
- **`signal_handler.h`** declares its API in terms of `mcontext_t`, which newlib
  does not define. Under Vita the class is reduced to an empty shell rather than
  faked with dummy types, so anything genuinely needing signals fails loudly at
  compile time instead of linking against a silent stub.

It also adds a Vita branch to `cpu_arm.cc`'s `HostCPUFeatures::Init`, which
elsewhere reads `getauxval(AT_HWCAP)`. The Vita is one fixed device, so the
values are constants — and one of them matters a great deal:

**`integer_division_supported_ = false`.** Cortex-A9 does *not* implement the
ARMv7-A integer divide instructions; those arrive with Cortex-A7/A15. VitaSDK's
compiler agrees — it does not define `__ARM_FEATURE_IDIV`. Claiming support
would make Dart emit `SDIV`/`UDIV` that fault on the device.

## 0003 — vita platform implementations

| file | |
|---|---|
| `cpuinfo_vita.cc` | Fixed answers. One known device, nothing to probe: no `/proc`, no cpuid, no auxv. |
| `thread_interrupter_vita.cc` | No-ops. The sampling profiler needs signals the Vita lacks, and nothing consumes samples without DevTools. No-ops rather than `UNREACHABLE()`, because a profiler that collects nothing beats one that aborts. |
| `virtual_memory_vita.cc` | An aligned allocator over `sceKernelAllocMemBlock`. |

`virtual_memory_vita.cc` is short because source analysis established, before a
line was written, that most of `virtual_memory_posix.cc` serves paths that
cannot be reached here — no executable memory, no `Protect`, no
`Reserve`/`Commit`/`Decommit`. Those are `UNREACHABLE()`, so if the analysis
ever goes stale it fails loudly. See
[the Phase 1 work plan](../../docs/phase-1-workplan.md).

Two Vita APIs made it simpler than expected:

- **`SceKernelAllocMemBlockOpt.alignment`** asks the kernel for alignment
  directly. POSIX over-allocates and trims with `FreeSubSegment`, which is
  impossible here because a memblock frees whole — so this sidesteps the one
  wrinkle the work plan had flagged.
- **`sceKernelFindMemBlockByAddr`** recovers the `SceUID` at free time, so the
  destructor needs no side table keyed on address.


---

## 0004 — GN vita toolchain

Makes `gn gen` work for `target_os="vita"`. Four edits:

| file | |
|---|---|
| `build/config/BUILDCONFIG.gn` | a `vita` branch in the `current_os` chain, an `is_vita` variable, and `set_default_toolchain` |
| `build/toolchain/vita/BUILD.gn` | new — `gcc_toolchain_suite("arm")` with the `arm-vita-eabi-` prefix from `$VITASDK` |
| `build/config/arm.gni` | **hard float and `cortex-a9` by default on vita** |
| `runtime/BUILD.gn` | `dart_os_config` defines `DART_TARGET_OS_VITA` |

Two decisions worth their own note:

**`is_posix = false`.** Tempting to set it true — Vita has pthreads, after all —
but newlib plus `sceKernel` is not POSIX, and claiming otherwise pulls in
`*_posix.cc` sources that cannot build.

**`arm_float_abi` defaults to `"hard"` on vita.** Upstream defaults to `softfp`.
Getting this wrong links cleanly and then passes garbage doubles across every
Dart/C boundary — the failure mode Phase 0.5 B5 exists to prevent. Making it a
default rather than a `gn` argument means it cannot be forgotten.

The toolchain itself is a near-copy of the Linux `arm` toolchain, because
`gcc_toolchain` is the supported way to plug in a GCC cross compiler and
VitaSDK is GCC. **The foreign-toolchain risk the plan rated High did not
materialise:** `gn gen` produced 682 targets from a macOS host on the first
configuration that got that far.

## 0005 — zlib: no ARMv8 on vita

zlib enables `use_arm_neon_optimizations` for any `arm`/`arm64` target, but the
code behind it is the **ARMv8 CRC32 and crypto extensions**. The Vita is an
ARMv7 Cortex-A9: it has NEON, but not those. Enabling them would emit
instructions that fault on the device — the same class of error as the
`integer_division_supported_` question in patch 0002.


---

## 0006 — newlib portability fixes

Found by actually building, not by reading. Four shared Dart sources that
cannot compile against newlib as written:

| file | problem |
|---|---|
| `platform/utils.cc` | `ResolveSymbolInDynamicLibrary` falls off the end of a non-void function — no branch matches. `Basename` needs `basename()`, which newlib lacks. |
| `lib/integers.cc` | `LLONG_MAX`/`LLONG_MIN` — glibc pulls `<limits.h>` in transitively, newlib does not. |
| `lib/ffi_dynamic_library.cc` | `RTLD_DEFAULT` with a Windows-only `#else`. |
| `vm/dart.cc` | the features string had no `vita` case. |

Two recurring shapes are worth naming, because more will surface:

**"Not POSIX means Windows."** Several files branch on POSIX and then `#else`
straight into Win32. A target that is neither has nowhere to land. This is
genuinely novel territory for the codebase, not an oversight.

**glibc leaks headers; newlib does not.** Dart relies on transitive includes
that only work because glibc is generous. Each has to be made explicit.

### The `dart.cc` change has a consequence

`Dart::FeaturesString()` embeds the target OS, and it is **checked when loading
a snapshot** — upstream's comment calls the OS match a deliberate "strong
condition" so `Platform.isAndroid` can be a compile-time constant.

**So a snapshot built by a `linux` `gen_snapshot` will be rejected by a `vita`
runtime.** The armv7 snapshot from [Phase 0.5 B1](../../docs/phase-0.5-feasibility.md)
proves codegen, sizes and kernel-format pinning — but it is **not** a valid M1
input. M1 additionally needs a `gen_snapshot` that targets vita, which Dart
supports as a host-run cross-precompiler (see `libdart_precompiler_product_linux_arm`
for the shape).

---

## 0010 — `runtime/bin` for vita (in progress)

`dart:io`'s native layer. Phase 1 excluded `runtime/bin` entirely; the engine's
embedder depends on it unconditionally, so it has to exist before M2 can link.

### `socket_base_vita.h`, and why it declares `sockaddr_un`

VitaSDK's socket layer is a thin BSD-shaped wrapper over sceNet, and it is
thinner than its header list suggests:

| | |
|---|---|
| IPv4/IPv6, TCP/UDP, `getaddrinfo`, `poll` | present and linkable |
| `AF_UNIX` | `#define`d — but sceNet rejects the family |
| `struct sockaddr_un`, `<sys/un.h>` | **absent** |
| `struct cmsghdr`, `SCM_RIGHTS` | **absent** — no ancillary data at all, so passing file descriptors over a socket is impossible, not merely unimplemented |
| `<ifaddrs.h>` | **absent** — interfaces cannot be enumerated |
| `IPV6_*` options | only `IPV6_V6ONLY`. No multicast |

The shared, non-platform files reach into `RawAddr::un` from five places —
`socket_base.h`, `socket_base.cc`, `socket_base_posix.cc`, `socket.h`,
`socket.cc` — about thirty sites in total. Threading an `#if` through all of
them would be thirty chances to get it wrong on the next engine roll.

So `socket_base_vita.h` declares the type instead, with the standard BSD layout
so `sizeof` and `offsetof` give the values the shared code expects. **This is
safe because nothing can construct a working `AF_UNIX` socket here**: `socket()`
fails at the sceNet boundary, so those fields are never reached with a live
descriptor. Failing at the syscall is the correct answer for a platform without
Unix sockets — unlike the Skia `mmap` case, where returning an error would have
broken a feature that *should* work.

Same reasoning for `IPV6_MULTICAST_IF` and `SCM_RIGHTS`, both given their
standard BSD values rather than invented ones. `IPV6_MULTICAST_IF` is a real
option number that sceNet will reject; `SCM_RIGHTS` is only ever compared
against a control message's type, and no control message can exist.

This one header took the failing objects from eight to three.

### `eventhandler_vita.h`, and how the design was settled

`eventhandler_linux.cc` stands on three Linux primitives. Each has a Vita
answer, and every one was checked against **VitaSDK's own compiled libc** rather
than against its headers — `arm-vita-eabi-ar x libc.a` and `objdump -dr` on the
result. That is worth doing, because on this platform a declaration proves
nothing, and the disassembly settled in minutes what would otherwise have needed
a device round-trip.

| Linux | Vita |
|---|---|
| `epoll_create` | absent — but **`poll()` is real and is itself implemented over `sceNetEpoll`**, going through VitaSDK's descriptor table (`__vita_fd_grab`), so it accepts what `socket()` returns |
| `pipe2` self-pipe | `pipe()` is real but built on `sceKernelCreateMsgPipe`; a message-pipe descriptor is not a socket, so `sceNetEpoll` would reject it. Real, and unusable here |
| `timerfd` | absent, and unnecessary — `TimeoutQueue` already knows the next deadline, so it becomes `poll()`'s timeout |

**`socketpair()` is the wakeup channel, and it works.** An earlier note in this
project claimed it could not, on the reasoning that a socket pair needs
`AF_UNIX`. That was wrong, and the relocation table says so plainly: VitaSDK
implements `socketpair` as `socket` / `bind` / `listen` / `getsockname` /
`socket` / `connect` / `accept` on `127.0.0.1`, family `AF_INET`. Both ends are
ordinary sockets that `poll()` can wait on — exactly the loopback trick this
port was about to hand-roll.

**One hard limit:** `poll()` checks `nfds > 255` before anything else and
returns `EINVAL`. More than 255 concurrent sockets does not degrade, it stops
working.

### Still to write

- **`eventhandler_vita.cc`** — the header is in; the definitions are not, so
  `EventHandlerImplementation`'s methods are undefined at link.
- **`process_vita.cc`** — `process.cc` compiles, but nothing defines
  `Process::Start` and friends. An honest failure is the right implementation;
  there is no `fork` here.

Both surface at **link**, not compile, which is precisely what M2 is for.

### `-latomic`

`runtime/vm/BUILD.gn` adds `libs += [ "atomic" ]` for any non-Clang build.
VitaSDK has no `libatomic` — GCC 15.2 targeting armv7-a emits the atomics Dart
uses inline — so the link failed with `cannot find -latomic` before reporting a
single real symbol. If something ever does need an out-of-line atomic it will
appear as an undefined `__atomic_*`, which is a far clearer error than this one.

### Gotcha: do not apply a later patch onto an already-patched tree

The patches are each generated with `git diff` against the **pristine** tree, so
two patches touching the same file overlap — the later one contains the earlier
one's hunks. Applying 0010 to a tree that already had 0004 did not fail; `git
apply` found matching context elsewhere in `runtime/bin/BUILD.gn` and inserted a
**second copy** of the vita `gen_snapshot` targets. Twenty `vita_arm` references
where there should be ten, and no error.

Regenerating 0010 with `':!runtime/bin/BUILD.gn'` fixed the overlap. The
tree-comparison one-liner is what caught it; run it after touching either tree.
