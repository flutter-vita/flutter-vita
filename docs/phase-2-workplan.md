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
guards inside them, the same shape as `runtime/vm`.

### The inventory, corrected

An earlier pass through this file said "~11 modules, comparable in size to
Phase 1's eight." **That was an undercount**, from grepping only the modules
whose names appear with an OS suffix in the sources list. The real figure is
**16 modules, 4675 lines of Linux implementation**, and it is worth having the
honest number before starting rather than discovering it two files in.

It is less work than 4675 lines suggests, because VitaSDK's POSIX file and
directory surface is nearly complete — `fcntl`, `opendir`, `readdir`, `stat`,
`lstat`, `mkdir`, `rmdir`, `unlink`, `rename`, `realpath`, `chdir`, `getcwd`,
`truncate`, `ftruncate`, `lseek`, `fsync`, `link`, `utime`, `access`, `isatty`
and `nanosleep` are all real. Absent: `symlink`, `readlink`, `tcgetattr`,
`ioctl`, `sched_yield`.

| Module | Linux LOC | Verdict |
|---|---:|---|
| `process` | 1203 | **Stub.** No `fork`, no `exec`. `Process.start` fails honestly |
| `file` | 809 | Port. Mostly mechanical; drop the `symlink`/`readlink` paths |
| `directory` | 518 | Port. Same |
| `eventhandler` | 433 | **Port, poll-based.** Design settled — see below |
| `socket` | 269 | Port. Follows Linux closely |
| `platform` | 221 | Small port — no `uname`, so the strings are ours |
| `namespace` | 159 | Small port |
| `file_system_watcher` | 155 | **Stub.** No inotify |
| `socket_base` | 148 | Port, minus `getifaddrs` and multicast |
| `stdio` | 140 | Small port — no `tcgetattr`, so terminal queries fail |
| `fdutils` | 132 | Port. `fcntl` is present, so this is close to a copy |
| `security_context` | 119 | **Excluded** by `dart_disable_secure_socket` |
| `utils` | 113 | Small port |
| `thread` | 97 | Port. VitaSDK has real pthreads |
| `sync_socket` | 91 | Port |
| `crypto` | 68 | Small port — `sceKernelGetRandomNumber` instead of `/dev/urandom` |

Realistically **1500–2000 lines of new code**, most of it mechanical, with the
event handler as the only piece needing design.

### What the compile probe found

Rather than guess how portable each module is, all twelve "port" modules had
`DART_HOST_OS_VITA` temporarily added to their `#if` guard and the tree was
built once. That is a five-minute experiment and it turns the estimate into a
list. The probe was then reverted; only the findings are kept.

Every module is *close*. In full, the reasons they do not compile as-is:

| Module | Errors | What is actually missing |
|---|---:|---|
| `crypto` | 1 | `<sys/syscall.h>` — it reaches `getrandom` through a raw syscall. Use `sceKernelGetRandomNumber` |
| `fdutils` | 1 | `<sys/ioctl.h>` — `FIONREAD` backs `SocketBase::Available`. **Needs a real alternative**, not a stub |
| `file` | 1 | `<sys/mman.h>` — the same call already made twice, in Skia and fml |
| `platform` | 1 | `<sys/prctl.h>` — thread naming. Drop it |
| `socket_base` | 1 | `<ifaddrs.h>` — no interface enumeration |
| `stdio`, `sync_socket` | 1 each | terminal and socket ioctls |
| `namespace` | 2 | `open64`, `openat64` — the LFS-64 spellings; plain `open`/`openat` exist |
| `socket` | 12 | Only missing constants: `SOCK_CLOEXEC`, `SOCK_NONBLOCK`, `SOMAXCONN`, `ENONET` |
| `directory` | 36 | The LFS-64 names again (`stat64`, `fstatat64`, `ino64_t`), plus `DT_*` and `dirent::d_type` — **newlib's `dirent` has no `d_type`, so listing must `stat` each entry** |

Two of those are genuine gaps needing a design choice — `FIONREAD` and
`d_type`. Everything else is a missing constant, a missing header, or an LFS-64
alias.

### Therefore: a compat header, not twelve forked files

The obvious move is to copy each `*_linux.cc` to `*_vita.cc`. That would
duplicate roughly 4600 lines to change perhaps eighty of them, and every engine
roll would then be a twelve-way merge.

Instead: **one small `bin/vita_compat.h`** supplying the LFS-64 aliases, the
`DT_*` values, `SOCK_CLOEXEC`/`SOMAXCONN` and friends, and `DART_HOST_OS_VITA`
added to the shared guards — with `#if` only around the handful of places that
are genuinely absent. Dart already shares this way: `socket_base_posix.cc` spans
three operating systems and `console_posix.cc` four.

`directory` did **not** need a fork after all. Dart already maintains a
`DT_UNKNOWN` branch for "file systems where readdir does not determine the entry
type", which stats the entry — so a `DART_DIRENT_TYPE()` macro reporting
`DT_UNKNOWN` reuses a tested path instead of adding one. 36 errors to zero.

### Where the compat header got to

`bin/vita_compat.h` plus widened guards cleared **six of the twelve** modules
outright: `directory`, `namespace`, `sync_socket`, `utils`, and — after four
deliberate call-site edits — `socket`.

Six remain, each blocked on exactly one missing facility, and each needing a
decision rather than a shim:

| Module | Blocked on | The decision |
|---|---|---|
| `crypto` | `<sys/syscall.h>` / `__NR_getrandom` | `sceKernelGetRandomNumber` (`psp2/kernel/rng.h`) — a straight swap |
| `platform` | `<sys/prctl.h>` / `PR_SET_NAME` | No-op. Threads are already named at creation in `os_thread_vita.cc` |
| `stdio` | `<sys/ioctl.h>` / `tcgetattr` | There is no terminal. Echo and line-mode queries report failure |
| `socket_base` | `<ifaddrs.h>` | `NetworkInterface.list` reports unsupported |
| `fdutils` | `FIONREAD` | **Open.** No `ioctl`, and no `SO_RXDATA`/`SO_NREAD` equivalent was found. This backs `SocketBase::Available`, which dart:io uses constantly, so a stub returning 0 would be a hang rather than a missing feature. Candidate: a `MSG_PEEK` read into a scratch buffer |
| `file` | `<sys/mman.h>` | **Open.** `File::Map` takes a hint and `MAP_FIXED`; the heap-copy answer used in Skia and fml does not fit a fixed-address mapping. Phase 1's `virtual_memory_vita.cc` already solved this shape and is the place to look |

### Not defined on purpose: `SOCK_NONBLOCK`

`SOCK_CLOEXEC` is defined as 0 and that is honest — there is no `exec()`, so no
descriptor can leak across one.

`SOCK_NONBLOCK` is deliberately **left undefined**. Defining it as 0 would have
compiled, and every socket dart:io created would have come back blocking — the
event loop stalling on the first read with nothing ready, at runtime, far from
the cause. Leaving it undefined turned each of the four call sites into a
compile error, and each now calls `FDUtils::SetNonBlocking` explicitly.
`accept4` is gone the same way; note that Linux gets atomicity there and this
does not, which is safe only because the descriptor is not yet visible to Dart.

`socket_base_posix.cc` is now in the build too, which is what supplies
`SocketBase::Available` and the rest of the shared socket surface. Three of its
functions are excluded: `is_file_descriptors_control_message`, `ReceiveMessage`
and `SendMessage`, all of which need `struct cmsghdr`, which VitaSDK does not
have at any level. `ListInterfaces` reports `ENOSYS` rather than returning an
empty list — the device plainly does have an address, and code that checks "are
there any interfaces" before acting would take the wrong branch silently.

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
| Skia | **builds** — 544 objects, [two files patched](https://github.com/flutter-vita/skia/commits/vita-3.44.8) |
| `fml` | **compiles** — but `MessageLoopImpl::Create()` returns nullptr, see below |
| Everything else in the engine | **compiles** — display_list, lib/ui, lib/gpu, tonic, abseil, shell, flow, txt |
| Dart runtime under the engine's GN | **compiles** — it came for free, as hoped |
| `dart:io` for vita | **compiles — all 16 modules plus `socket_base_posix.cc`.** `process` still undefined at link |
| **Every source file in the engine** | **compiles — 2682 objects, `ninja` exit 0** |
| Link the engine | **M2 MET — zero undefined symbols** |

## Order of work

1. ~~**Skia**~~ — done. Two files: platform detection, and a heap-copy
   replacement for `mmap`. See [the patch notes](https://github.com/flutter-vita/skia/commits/vita-3.44.8);
   the `mmap` one is a memory-cost decision, not just a portability fix.
2. ~~**`fml`**~~ — compiles. Four files, and `mapping_posix` was indeed the
   hard one. **It is not finished**: `MessageLoopImpl::Create()` ends in
   `#else return nullptr` and Vita takes that branch, so the engine will link
   and then fail `MessageLoop::EnsureInitializedForCurrentThread` the first
   time any thread wants a loop. A real `message_loop_vita` is a prerequisite
   for anything running, not for M2.
3. ~~**The Dart runtime under the engine's GN**~~ — free, as predicted. Release
   mode resolves `//flutter/runtime:libdart` to `libdart_aotruntime`, the target
   Phase 1 already builds, and Phase 1's patches carried it.
4. **`dart:io`**, the platform files — the whole remainder. Of 1458 build edges,
   3 failing objects are left, all in `runtime/bin`:

   - **`eventhandler.o`** needs `eventhandler_vita.{h,cc}`, and there is a
     design decision open (below).
   - **`socket.o`** and **`dart_io_api_impl.o`** follow from it.

   Then `process_vita.cc`, which will surface at **link** rather than compile:
   `process.cc` builds fine, but nothing defines `Process::Start`. There is no
   `fork` here, so an honest failure is the implementation.

   ### The event handler: settled, without the device

   `eventhandler_linux.cc` stands on `epoll`, a `pipe2` self-pipe and
   `timerfd`. All three were resolved by disassembling VitaSDK's own libc
   (`ar x libc.a`, then `objdump -dr`) rather than by reading headers or
   waiting for hardware:

   - **`poll()` is real, and is itself implemented over `sceNetEpoll`**, via
     VitaSDK's descriptor table. It accepts what `socket()` returns.
   - **`socketpair()` is real**, implemented as a loopback TCP pair on
     `127.0.0.1` with `AF_INET` — *not* `AF_UNIX`, contrary to an earlier note
     in this project. Both ends are pollable sockets, which is exactly the
     wakeup channel needed.
   - **`pipe()` is real but unusable**: it is built on
     `sceKernelCreateMsgPipe`, and a message-pipe descriptor is not a socket.
   - **`timerfd` is absent and unnecessary** — `TimeoutQueue` already knows the
     next deadline, so it becomes `poll()`'s timeout.

   **Hard limit:** `poll()` returns `EINVAL` when `nfds > 255`. More than 255
   concurrent sockets does not get slow, it stops working.

   The lesson worth keeping is the method, not the answer: on this platform a
   declaration proves nothing — `pipe` and `socketpair` are both declared, one
   is usable and one is not — and the compiled library says which in minutes.

5. **The link, for M2.** Not the engine's `flutter_engine_library`: it is a
   `shared_library`, and on Vita that fails immediately (`crt0.o` and
   `crtbegin.o` are not PIC, and correctly so — homebrew is statically linked).
   A shared link would also *tolerate* undefined symbols, so passing it would
   prove nothing. M2 needs an executable that pulls in the object closure, in a
   new `experiments/m2-link-check/`, following the pattern `experiments/m1-vpk` already
   uses for Dart.

## Things to carry forward from Phase 1

- **Read the upstream startup path before writing embedder code.** Every one of
  M1's last failures was something `runtime/bin` does that our harness did not.
  See [embedder-startup.md](embedder-startup.md).
- **Check exit codes on every build step.** Three separate false "success"
  reports in Phase 1 came from `ninja | grep | tail`, a missing exit check, and
  a stale tool binary that ran after its rebuild had failed.
- **Never edit the vendored tree without producing a patch file.** Two series
  now: [dart-sdk](https://github.com/flutter-vita/dart-sdk/commits/vita-3.44.8) and
  [flutter-engine](https://github.com/flutter-vita/flutter/commits/vita-3.44.8).
- **Diff the patched tree against the last known-good one.** Doing this when
  moving into the engine checkout caught that patch 0008 was stale — the
  `installPlatformScript` that makes `Isolate.spawn` work had never been written
  back, and a fresh checkout would have silently lost it.


---

## The link, and what it found

`//flutter/shell/platform/embedder:vita_link_check` is an executable that names
the four embedder entry points a real host cannot do without. It exists because
the engine's own `flutter_engine_library` cannot answer the M2 question: it is a
`shared_library`, VitaSDK's `crt0.o` is not PIC, and a shared link tolerates
undefined symbols anyway, so succeeding would prove nothing.

It links to **66 undefined symbols**, in six groups. That list is the honest
remainder of Phase 2.

**1. `dart:io`'s process and watcher layers (26).** `Process::Start`, `Wait`,
`Kill`, the signal handlers, `FileSystemWatcher::*`, `Console::RestoreConfig`.
Expected — these are the stubs already scheduled. `Thread::TryStart` is here
too, which was missed: `thread_linux.cc` has a different guard shape from the
other eleven and was never widened.

**2. ~~The `*at()` family (12)~~ — done.** `openat`, `fstatat`,
`mkdirat`, `unlinkat`, `renameat`, `symlinkat`, `readlinkat`, `faccessat`,
`utimensat`, plus `dup2`, `readlink` and `uname`. Every one is **declared** in
VitaSDK's headers — which is why everything compiled — and **none is
implemented**.

That is the third time this platform has drawn the distinction today, after
`socketpair` (declared, and real) and `pipe` (declared, real, and unusable
here). It is worth stating as a rule: *on this target, compiling proves
nothing about a libc function; only the archive does.*

It matters more than the count suggests, because `runtime/bin` uses the `*at`
family throughout for namespace-relative paths — `Namespace` exists precisely to
hold a directory fd. Two routes: implement the dozen on top of `sceIo`, or make
`Namespace` resolve to absolute paths on this platform and use the plain calls.
The second is less code and loses the isolation `Namespace` provides, which
nothing in a single-app homebrew build appears to need. The wrappers won, and the reason is worth keeping: `NamespaceScope` already
yields `AT_FDCWD` unless an embedder installs a namespace, and this port does
not. So each shim handles the case that actually occurs and **refuses** a real
directory fd rather than silently resolving it against the process's cwd.
Rewriting `Namespace` would have touched more code to reach the same behaviour
and would have thrown away that check. See `bin/vita_posix_shims.cc`.

One wrinkle worth remembering: `uname` had to be defined **outside** the
`extern "C"` block. VitaSDK's `<sys/utsname.h>` declares it with no `extern "C"`
guard, so under C++ it has C++ linkage — and the mangled name is what the linker
was asking for. Defining it as C would have added a second, unrelated symbol and
left the original undefined.

**3. Ganesh (17).** `GrDirectContext`, `GrBackendTexture`,
`SkSurfaces::RenderTarget`, `SkImages::BorrowTextureFrom`. `skia_enable_ganesh`
is false, so Skia does not build them, but the engine references them anyway
from paths that a software-only build should never reach. The earlier
`embedder_surface.cc` include made the *compile* work; this is the other half.
Likely answers: `slimpeller`-style exclusion, or a small stub translation unit.

**4. abseil internals (6).** `LowLevelAlloc`, `SigSafeArena`,
`CreateThreadIdentity`, `AbslInternalPerThreadSem*`. Sources gated on an OS list
that has no vita arm, the same shape as everything else here.

**5. `SkLogVAList` (1).** Skia's logging backend, from a file that is not being
compiled.

**6. Two Vita libraries (2).** `sceSblDmac5HashTransform` and
`taiGetModuleInfo` — these are just link flags, `-lSceSblSsMgr_stub` and
`-ltaihen_stub`. The first is reached by Dart's crypto path; the second by
something in the toolchain's startup.


## Down to 28

66 → 54 → 30 → 28. What is left is two groups and one loose end.

**26 are Ganesh and abseil.** `GrDirectContext`, `GrBackendTexture`,
`SkSurfaces::RenderTarget`, `SkImages::BorrowTextureFrom`, `SkLogVAList`, and
six abseil internals (`LowLevelAlloc`, `SigSafeArena`, `CreateThreadIdentity`,
`AbslInternalPerThreadSem*`).

The Ganesh ones all arrive through one function —
`flutter::ConvertToRasterUsingResourceContext` — which is compiled because
nothing excludes it, and which cannot run in a build with no GPU context. This
is the same seam that made `embedder_surface.cc` need an explicit
`GrDirectContext.h` include: the engine is not fully partitioned against
`skia_enable_ganesh = false`. The likely fix is a `#if` around the raster
conversion path rather than trying to make Skia supply the symbols.

**2 are `sceSblDmac5HashTransform` and `taiGetModuleInfo`, and they are more
interesting than they look.** They are not referenced by anything in the
engine. They come from **`libdl.a`'s `dlsym`**, which VitaSDK implements on top
of taiHEN — so linking `-ldl` on a platform with no dynamic receiver drags in two
stub libraries to support a function that can never succeed.

`-ldl` has been dropped from `runtime/vm/BUILD.gn` for vita, and verified gone
from the link line, **and the symbols persist** — so `libdl.a` is entering by
another route not yet identified. Worth finding rather than papering over with
`-lSceSblSsMgr_stub`: something is linking a library this port has no use for.


## The Ganesh decision: on, with no backend

The link's largest group was seventeen Ganesh symbols — `GrDirectContext`,
`GrBackendTexture`, `SkSurfaces::RenderTarget`, `SkImages::BorrowTextureFrom`.

**My first reading of them was wrong.** I said they all arrived through
`flutter::ConvertToRasterUsingResourceContext` and that a single `#if` would
clear them. Guarding that function on Skia's own `SK_GANESH` was correct and
changed nothing: the symbols come from **twelve** translation units across
`flow`, `lib/ui`, `shell/common` and the embedder. The engine assumes
`GrDirectContext` exists *as a type* far more widely than it assumes a GPU is
present, and excluding all of it would mean forking a dozen engine files.

The alternative considered was a stub translation unit defining the nineteen
symbols to abort. Rejected: it converts a link error into a runtime crash, and
`GrBackendTexture`'s constructors are value-type operations that can legitimately
run on empty objects, so some stubs would have to be silent no-ops — a mix of
"loud" and "silent" stubs in one file is exactly the sort of thing that is
misread later.

**What was done instead: `skia_enable_ganesh = true` with every backend off.**

That reads as a contradiction and is not. Ganesh's core is backend-agnostic;
`skia_use_gl`, `skia_use_vulkan` and `skia_use_metal` are what select a driver,
and all three stay false. Nothing can construct a `GrDirectContext` without a
backend, so **every GPU path stays dead at runtime exactly as ADR-0003
intends** — this changes what links, not what executes.

The cost is compile time and binary size, and the size number matters on a
device with 188 MiB: it should be measured against the `.text` budget once M2
is met, and recorded next to the 12.41 MiB armv7 engine figure in the roadmap.
If it is unacceptable, the stub translation unit is still available as the
fallback, with the tradeoff above understood.


## The last ten

Ganesh-with-no-backend worked: all seventeen GPU symbols resolved, 28 → 10.

**Six are abseil, and this one is a real platform conflict rather than a
misconfiguration.** `LowLevelAlloc::AllocWithArena`, `SigSafeArena`,
`CreateThreadIdentity`, `AbslInternalPerThreadSem*`.

The objects are built. They are **empty** — `nm` reports zero defined symbols in
both `low_level_alloc.o` and `create_thread_identity.o` — because abseil sets
`ABSL_LOW_LEVEL_ALLOC_MISSING` when neither `ABSL_HAVE_MMAP` nor `_WIN32` is
defined, and `__vita__` is correctly absent from its mmap list. So abseil has
concluded, correctly, that this platform cannot support LowLevelAlloc, and
compiled it out. Its own `absl::Mutex` machinery then references it anyway.

Do **not** fix this by adding `__vita__` to abseil's `ABSL_HAVE_MMAP` list. That
would be a lie in the one place the codebase asks the question directly, and it
would break anything else keyed on it.

The principled fix is a malloc-backed `LowLevelAlloc` for vita. LowLevelAlloc
exists to allocate without touching malloc — so a malloc hook cannot recurse —
and to be async-signal-safe. Neither guarantee has content here: nothing in this
port hooks malloc, and there are no signals at all. Worth writing that reasoning
into the patch, because "we replaced the async-signal-safe allocator with malloc"
reads as reckless without it.

**`SkLogVAList` is one symbol and is not yet resolved.** Skia picks a logging
backend per platform and has no arm for an unknown one. `is_vita` was added
to the `is_linux || is_wasm` branch that selects `SkLog_stdio.cpp`, at line 2030
of `flutter/third_party/skia/BUILD.gn`, inside `skia_component("skia")` — and
after a `gn gen` **no `SkLog_stdio` object is produced**. The edit is in the
file and is not taking effect; why is not yet known. Start there rather than
assuming the branch is wrong.

**Two are the taiHEN pair**, unchanged and diagnosed in
`patches/flutter-engine/0004`: `libdl.a` is linked, needs those archives, and
GN emits them before `-ldl` where static resolution cannot use them.


---

# M2 is met

`out/vita_release/vita_link_check` links with **zero undefined symbols**.

```
Class:   ELF32
Machine: ARM
Type:    EXEC
Flags:   0x5000400, Version5 EABI, hard-float ABI
```

`nm -u` reports nothing, and 422 engine symbols (`FlutterEngineRun`, `SkCanvas`,
`Dart_Initialize`) are present. The hard-float flag is the same `0x...400` that
Phase 0.5 experiment B5 measured on VitaSDK's own libraries, so the ABI matches.

**`.text` is 6.26 MiB** — and that number should not be compared to the roadmap's
12.41 MiB armv7 reference as though Ganesh came for free. This binary is linked
with `--gc-sections` and only names four embedder entry points, so most of the
engine was discarded as unreachable. A real embedder will be larger. The Ganesh
size question is still open; measure it against a Phase 3 binary, not this one.

## The last three, and what they cost

**66 → 28** by stubbing and shimming. **28 → 10** by building Ganesh's core with
no backend. The last ten took three fixes, two of which were in a place I had
not looked:

1. **`SkLogVAList`.** `flutter/skia/BUILD.gn` — the *engine's* Skia target — is
   what builds Skia. `flutter/third_party/skia/BUILD.gn` is not used at all;
   the engine imports Skia's `.gni` source lists and defines its own target. An
   earlier edit to Skia's own `BUILD.gn` had no effect for that reason, which is
   worth knowing before making any other Skia build change.

2. **`-ldl`, found at last.** Same file: Skia's engine target adds it for
   everything non-Windows except QNX. Not `runtime/vm` and not `runtime/bin`,
   both of which were excluded for vita first and changed nothing. Removing it
   made `dlopen`/`dlsym`/`dlclose`/`dlerror` surface honestly — they are now
   four small refusals in `vita_posix_shims.cc` — and took the two taiHEN
   symbols with it, since VitaSDK's `libdl.a` implements `dlsym` on taiHEN.

3. **abseil's `LowLevelAlloc`.** Abseil sets `ABSL_LOW_LEVEL_ALLOC_MISSING`
   when `ABSL_HAVE_MMAP` is absent and compiles the file to nothing, while
   `absl::Mutex` goes on referencing it. Vita is excluded from that gate and
   given a `memalign`-backed arena. **Not** by adding `__vita__` to
   `ABSL_HAVE_MMAP`, which would be a lie in the one place the code asks
   directly. LowLevelAlloc's two guarantees — no malloc recursion, and
   async-signal-safety — are both vacuous here: nothing hooks malloc and there
   are no signals.

Then one warning: VitaSDK's `crtn.o` has no `.note.GNU-stack` section, and
`--fatal-warnings` turned that into a failed link. Disabled for vita, with the
reasoning at the call site.

## What M2 does not mean

The engine links. It does not run, and one thing is already known to stop it:
`MessageLoopImpl::Create()` returns `nullptr` on this platform, so the first
thread that asks for a loop fails an `FML_CHECK`. That is the first Phase 3
item, not an M2 one.

## `dart:ui` needs no work — and `dart:vita` may not either

The plan carried "add `dart:ui` to the platform dill" over from Phase 1. **It was
wrong.** The engine already builds its own:
`compile_platform("strong_platform")` in `flutter/lib/snapshot/BUILD.gn`, from
the engine's `libraries.json`, with `--target=flutter` rather than the plain VM
target. It builds for vita unchanged — 9.95 MiB `platform_strong.dill`, `ninja`
exit 0 — which is unsurprising once said out loud, because a kernel dill is
host-side and contains no target code.

The three-edit procedure (library file, `libraries.json`,
`extraRequiredLibraries`) still applies to adding a library to *that* dill, and
the third edit still fails silently.

**The more useful consequence is a question, recorded before Phase 3 acts on
reflex: `dart:vita` may no longer be needed at all.** It exists only because
Phase 1 excluded `dart:io`, so nothing supplied `_printClosure`, the microtask
closure, the timer hooks or `platformScript`, and each had to be installed by
hand from C. `runtime/bin` is in the build now and supplies all four the way it
does on every other platform. Verify at runtime — but do not port `dart:vita`
forward without checking, or four workarounds get carried into a phase that may
need none of them.

## `gen_snapshot` already targets vita

Phase 1 needed a purpose-built `gen_snapshot_product_vita_arm`, because Dart
embeds the target OS in a snapshot's features string and validates it on load —
a `linux-arm` gen_snapshot's output is *rejected* by a `vita` runtime. That was
the single thing standing between "we can make armv7 snapshots" and M1.

In the engine build it comes for free:

```
gn desc out/vita_release \
  "//flutter/third_party/dart/runtime/bin:gen_snapshot(//build/toolchain/mac:clang_arm64)" defines
  -> DART_TARGET_OS_VITA
```

The host `gen_snapshot` is already configured for vita, because the engine sets
`target_os = "vita"` globally and Dart's `dart_os_config` keys off `target_os`
rather than `current_os` — so patch 0004's one-line addition to that config
covers the host tool as well as the target runtime. The bespoke
`gen_snapshot_product_vita_arm` target is still in the tree from Phase 1 and is
**not** what the engine uses.

### Built and exercised

`flutter/lib/snapshot:create_arm_gen_snapshot` is the target — the engine's own
answer for 32-bit ARM, producing `clang_arm64/gen_snapshot_armv7`: a host arm64
binary that emits armv7 snapshots. 1158 edges, no failures.

Note the ninja target name. `gen_snapshot(//build/toolchain/mac:clang_arm64)` is
GN's label, not a ninja target; ninja mangles the `//` and rejects it. Use
`ninja -t targets all | grep gen_snapshot` to find the real name.

Verified rather than assumed:

- `strings` finds **`vita`** as the only OS name in the binary — no `linux`,
  `macos` or `android`. That is `kTargetOperatingSystemName`, the string Dart
  bakes into a snapshot's features and validates on load.
- Run against Phase 1's `hello.dill` it produced a 5,344,351-byte
  `snapshot.S`, exit 0 — within 8 KB of the 5,336,479 that Phase 1's purpose-built
  `gen_snapshot_product_vita_arm` produced from the same input.

**What that does not prove:** the `.S` is `.long` blobs rather than mnemonics —
`app-aot-assembly` emits the instructions image as raw words — so nothing here
disassembles armv7 and confirms it. Matching size and a clean exit are strong
circumstantial evidence, not execution. The proof is the device.


## The package, corrected

```
sce_sys/param.sfo      912 B
eboot.bin           11.2 MiB
icudtl.dat         862,304 B
                  ---------
                    11.6 MiB
```

Two corrections against what I wrote an hour earlier.

**`icudtl.dat` is 862 KB, not ~10 MB.** This project has repeated the 10 MB
figure since the plan was written, and it is wrong for Flutter: the engine
vendors an already-slimmed dataset at `third_party/icu/flutter/`. **"Slim
icudtl.dat" comes off the Phase 2 list** — upstream did it.

**`platform_strong.dill` should never have been in the package**, and the first
`.vpk` shipped it. It is a *host-side* artifact: the SDK half of the kernel that
`gen_snapshot` consumes when compiling an app on the build machine. The device
runs the AOT snapshot linked into `eboot.bin` and has no use for kernel. Removing
it took 2.7 MiB off the package, and it was 9.95 MiB of the previous 14.3 —
compressed well, but dead weight either way.

What is still missing is `flutter_assets`. A real bundle needs
`flutter build bundle` against an app, which is Phase 4 tooling. Until then the
engine will start and fail to find its assets, which is the expected first-run
outcome and not worth working around.

---

# First run on hardware: a data abort

The engine reached the device and crashed. Dump kept at
`experiments/m3-vpk/out/dumps/psp2core-1786386797-…psp2dmp`.

```
Stop reason: 0x30004 (Data abort exception)
PC:          0x81bc5e22  (flutter_vita_m3@1 + 0xb7be22)
R0:          0x6f742d65
```

Nearest symbols are `pthread_mutex_lock` and `pte_osSemaphoreCancellablePend` —
VitaSDK's pthread shim.

**`R0` is ASCII.** `65 2d 74 6f` little-endian reads `e-to`: a pointer into
string data being used as an object. That is the signature of a `this` or a
mutex pointer that was never what the caller thought it was.

## A hypothesis, tested and rejected

This looks like Phase 1's emutls crash, which was `pthread_mutex_unlock`
faulting on a garbage pointer because emutls guards its table with a
**statically initialised** mutex and VitaSDK's pthread does not support
`PTHREAD_MUTEX_INITIALIZER`.

Grepping `fml`, `runtime`, and abseil for `PTHREAD_MUTEX_INITIALIZER`,
`PTHREAD_COND_INITIALIZER` and `PTHREAD_ONCE_INIT` finds **nothing**. So it is
not that, and the resemblance is misleading. Recorded because the resemblance is
strong enough that someone will reach for it again.

## Where to start

1. **Get the full backtrace.** The output above was truncated; `analyse-crash.sh`
   prints a frame chain and it was not read.
2. **`0xb7be22` is a module-relative offset**, already slide-adjusted by the
   tool, so it can go straight to `addr2line` against
   `experiments/m3-vpk/build/flutter_vita_m3`. Do not subtract a slide again — Phase 1
   lost time to exactly that, resolving an address to obvious nonsense.
3. **Suspect the thread pool before the mutex.** The engine starts four task
   runners immediately; M1 ran essentially single-threaded. `MessageLoopVita` is
   new and unexercised, and `Thread::TryStart` came from `thread_linux.cc` with
   its `pthread_setname_np` call newly stubbed out.

## The memset did not fix it, and the reason rules out my theory

Second run, same crash, and one detail settles it:

```
run 1:  PC flutter_vita_m3 + 0xb7be22   R0 = 0x6f742d65
run 2:  PC flutter_vita_m3 + 0xb7be2a   R0 = 0x6f742d65
```

**`R0` is identical across runs.** Uninitialised heap does not repeat — it holds
whatever the previous allocation left, which varies. A constant value means the
memory is *consistently* that value, so the zeroing hypothesis is wrong even
though the mechanism behind it was real. (The `memset` is kept: `mmap` really
does zero and `memalign` really does not, and abseil's callers really do depend
on it. It was a latent bug, just not this one.)

The PC moved by 8 bytes, which is the `memset` shifting code, so it is the same
instruction: `pte_osAtomicExchange`, reached from `pthread_mutex_lock`,
dereferencing `R0`.

`0x6f742d65` little-endian is `e-to`. A `pthread_mutex_t` whose bytes are a
string fragment, at the same value every boot, is a **statically allocated mutex
that was never initialised** and happens to overlap string data in `.data`.

That is Phase 1's failure mode exactly: **VitaSDK's pthread does not support
static initialisers.** The earlier grep for `PTHREAD_MUTEX_INITIALIZER` came
back empty, but it searched `fml`, `runtime` and abseil only. It did not search
the place most likely to have one:

**libstdc++.** `std::mutex`, `std::recursive_mutex` and `std::once_flag` are
constant-initialised and lower to `__gthread_mutex_t` — a `pthread_mutex_t` with
static init. Any namespace-scope or function-local-static `std::mutex` in the
engine, Skia or tonic hits this. That is the next thing to check, and the search
should cover the whole tree rather than three directories.

## And the static-initialiser theory is wrong too

VitaSDK's static initialiser is a **sentinel, not a struct**:

```c
// sys/_pthreadtypes.h:87
#define _PTHREAD_MUTEX_INITIALIZER ((pthread_mutex_t) -1)
```

`pthread_mutex_t` is a handle, and `-1` means "not created yet". libstdc++'s
`__GTHREAD_MUTEX_INIT` is that sentinel, so a statically initialised
`std::mutex` would arrive at `pthread_mutex_lock` as **`0xFFFFFFFF`**.

`R0` is `0x6f742d65`. So it is not a static initialiser either.

### What is actually established

- The mutex **handle itself** is `0x6f742d65` — not a struct containing junk, a
  *pointer-sized handle* whose value is ASCII (`e-to`).
- It is **identical every boot**, so it is not uninitialised heap and not ASLR.
- It happens on the **main thread**, with three threads alive, before the
  engine's pool exists.
- Two mechanisms are ruled out by evidence rather than by argument:
  uninitialised arena memory (the value would vary) and static initialisation
  (the value would be `-1`).

Something reads string data and uses it as a mutex handle, deterministically, at
the same point every run. That is type confusion or a struct-layout mismatch —
a field read at the wrong offset — rather than a lifecycle bug.

**Where to look next:** a struct shared across a boundary where our port changed
the layout. The candidates this port actually altered are `struct stat`
(second-resolution, no `st_atim`), `struct dirent` (no `d_type`), and
`sockaddr_un` (declared locally in `socket_base_vita.h` and *not* the platform's
type). A `sizeof` or `offsetof` mismatch between a header one file sees and
another does not would produce exactly this: a consistent wrong offset, reading
adjacent string data.

`socket_base_vita.h` is the one to suspect first, because it **invents** a type
the platform does not have, and `RawAddr` is a union — get its size wrong and
every field after it in any containing struct shifts.

### The full backtrace, and what it corrects

`vita-parse-core` had been failing with `ModuleNotFoundError: No module named
'elftools'` — it was being run under the system Python instead of
`out/vpc-venv`, and it also needs `arm-vita-eabi-addr2line` on `PATH`. Both
fixed, the dump gives a symbolicated stack, and the stack rewrites most of the
paragraphs above.

**First correction: `R0` is not the address.** `pte_osAtomicExchange` opens with
`mov r3, r0` and then `ldrex r0, [r3]`, so by the time of the fault `R0` holds
the **loaded value** and `R3` holds the pointer. The faulting instruction is
`strex r2, r1, [r3]` with `R3 = 0x81c86320`. Subtracting the module load base
(`0x81066000`) gives ELF `0x81c20320`, which is **inside `.rodata`**.

So the data abort is not a wild pointer at all. It is a **write to read-only
memory**: an atomic exchange against a string literal.

```
.rodata @ 0x81c2031c:  "trace-to-file"
                        ^^^^ ^^^^
        0x81c20320 --------'
```

`0x6f742d65` is simply the four bytes `ldrex` read back from the middle of that
literal. It is constant every boot because it is a string constant. Every
inference drawn from treating it as a handle value was drawn from a red herring.

**Second correction: the layout theory is wrong too.** The stack names the
caller chain exactly:

```
FlutterEngineInitialize
  EmbedderThreadHost::CreateEngineManagedThreadHost   embedder_thread_host.cc:122
    ThreadHost::CreateThread                          thread_host.cc:70
      fml::Thread ctor
        fml::AutoResetWaitableEvent::Wait             waitable_event.cc:74
          std::condition_variable::wait
            pthread_cond_wait
              pte_cond_wait_cleanup   -- relocks the caller's mutex on exit
                pthread_mutex_lock
                  pte_osAtomicExchange   <-- fault
```

`pte_cond_wait_cleanup` reacquires the *user's* mutex, not the condvar's
internal one, and the object it was handed decodes cleanly off the main thread's
stack. `AutoResetWaitableEvent` is `cv_`, `mutex_`, `signaled_` in that order:

```
0x8208029c  cv_        = 0x82106460   valid: nWaitersBlocked=1, both sems live,
                                      mtxUnblockLock = 0x82106a90
0x820802a0  mutex_     = 0x81c2031c   &"trace-to-file"
0x820802a4  signaled_  = 1
```

Three fields, three offsets, all where the C++ says they should be. **The
layout is correct.** `stat`, `dirent` and `sockaddr_un` are off the hook; so is
`socket_base_vita.h`, which was first on the list an hour ago.

### What this actually is

`signaled_ == 1` means the child thread already ran `Signal()`, which locks
`mutex_`. `cv_` is a *live* condvar with a waiter registered, so
`Wait()` locked `mutex_` too. **The mutex was valid twice**, and by the time the
parent woke up to relock it, its four bytes held a pointer to a string literal.

That is a **stray write of one word into the main thread's stack**, at a fixed
offset, while the main thread is parked inside `pthread_cond_wait`. The value
written is a pointer into the switch-descriptor strings of
`shell/common/switches.cc` — the same table whose entries
(`icu-data-file-path`, `use-test-fonts`, `enable-impeller`, …) litter the
surrounding stack words from an earlier frame.

The pointer appears nowhere in the image as a stored word and nowhere in `.text`
as a literal-pool constant, so it is materialised at runtime.

### Next probes

1. `AutoResetWaitableEvent` sits on the *parent's* stack while a freshly created
   thread holds a reference to it. Confirm the child's stack does not overlap
   the parent's: print the `sceKernelCreateThread` stack base and size for each
   `pte_osThreadCreate`, against the main thread's `0x82041000..0x82081000`.
2. Only three threads exist at the fault and the new one is named `pthread`, not
   `io.flutter.ui` — the name never reached the kernel object. Whatever writes
   the name is a suspect for writing somewhere else too.
3. Put a guard word on either side of the latch in `fml::Thread`'s ctor and
   check it after `Wait()` returns. That converts "something writes the stack"
   into a bounded range.

### The bug: libstdc++ never knew this program had threads

The probe answered on the first run, and it answered the opposite of what the
last three theories assumed. The handle was already wrong **on entry to
`Wait()`**, before anything waited:

```
ARWE 0x8204029c enter handle=81c44604 signaled=0     x3
terminate called after throwing an instance of 'std::system_error'
```

`0x81c44604` less that run's module base is ELF `0x81c20604`, and `0x81c20604`
is the first byte of `"trace-to-file"` — the *same string literal* as the first
crash, in a binary whose `.rodata` had shifted by `0x280`. A value that follows
a string across a relink is not a coincidence and not corruption. It is the
literal's address, materialised at runtime, sitting in a stack slot that
`SettingsFromCommandLine` used earlier and that the latch was later placed on
top of.

Which means the mutex was **never initialised**, and the two locks that
"succeeded" never happened:

```
$ arm-vita-eabi-nm flutter_vita_m3 | grep pthread
         w pthread_cancel        <-- weak, unresolved, address 0
81b7a5d4 T pthread_create
81b7a4a0 T pthread_mutex_lock
```

GCC's `gthr-default.h` decides whether a program is threaded by taking the
address of a proxy symbol — `__pthread_key_create` on glibc, and everywhere
else `pthread_cancel`, declared as a weak reference. **A weak reference does
not pull a member out of an archive.** Nothing in the engine calls
`pthread_cancel`, so it linked with no address, `__gthread_active_p()` returned
0, and libstdc++ compiled the entire engine down to its single-threaded path:

```c
static inline int __gthread_mutex_lock (__gthread_mutex_t *__mutex) {
  if (__gthread_active_p ()) return __gthrw_(pthread_mutex_lock) (__mutex);
  else return 0;                                  /* <- what was running */
}
```

Every `std::mutex::lock()` in the engine and in Skia was `return 0` without
touching the handle. That is why the handle kept its stack garbage, why two
locks appeared to succeed, and why only one path ever faulted:
**`std::condition_variable::wait` is not gated on `__gthread_active_p`.** It
calls `pthread_cond_wait` for real, which locks the mutex it is handed for
real, and that mutex was a pointer to `.rodata`. The `strex` in
`pte_osAtomicExchange` then wrote to a read-only page.

The fix is one linker flag, in `experiments/m3-vpk/CMakeLists.txt`:

```
"-Wl,-u,pthread_cancel"
```

`-u` makes the reference strong enough to pull the archive member in. After it:

```
81b7b9ec T pthread_cancel
```

and the log shows every wait completing:

```
ARWE 0x8204029c enter     handle=82106c20 signaled=0
ARWE 0x8204029c pre-wait  handle=82106c20
ARWE 0x8204029c post-wait handle=82106c20
```

Real heap handles, three latches, no fault.

**This was never only a crash.** A silently single-threaded libstdc++ means
every mutex in a multi-threaded renderer is a no-op, so the crash was the
lucky outcome — the alternative was months of unreproducible corruption. Any
Vita C++ project that uses `std::mutex` across threads has this bug and has no
symptom pointing at it. The check is one command: `nm | grep pthread_cancel`,
and a `w` is the defect.

### Then, in order, the ordinary failures

With threads working the engine started and failed twice more, each time
usefully:

1. `Check failed: context->IsValid() ... Tried: app0:/icudtl.dat`. The receiver's
   `install` replaces `eboot.bin` and nothing else, so the app directory still
   held M1's contents. `dev.sh` now pushes `icudtl.dat` after install, hashed so
   it transfers only when it changes.
2. `Dart_LookupLibrary: library 'dart:ui' not found`, then
   `Check failed: !CheckAndHandleError(http_connection_hook_closure)`. Expected:
   the snapshot is built from `experiments/b1-aot-snapshot/out/hello.dill`, a plain
   Dart program. A Flutter app kernel has to come from the flutter frontend
   server, with `dart:ui` in it, alongside a real `flutter_assets`.

The engine reaches Dart isolate creation on hardware. What is left before
something appears on the panel is tooling, not porting.

## Text: Skia was built with no font backend at all

The first frame reached the panel with an app bar and a button and **not one
glyph**. The obvious guess -- a missing font file -- is wrong, and the way it is
wrong matters, because shipping fonts would not have fixed it.

`skia_use_freetype` is set in `gn/skia.gni` as:

```gn
skia_use_freetype = is_android || is_linux || is_canvaskit
```

Vita is none of the three, so every FreeType-dependent Skia target switched
itself off. The binary says so plainly -- of the whole build, the only font
objects present were:

```
obj/flutter/third_party/skia/src/core/skia.SkFontMgr.o
obj/flutter/third_party/skia/src/utils/skia.SkOrderedFontMgr.o
```

No `SkTypeface_FreeType`, no `SkFontMgr_custom_*`, and `nm` on the linked ELF
found no `SkFontMgr_New_Custom_*` at all. FreeType itself *was* compiled --
`libfreetype2.*.o` are all there, pulled in by another dependency -- which is
what makes this easy to misread: the library is present and unused.

**Asset fonts would not have helped.** The asset font manager still needs a
backend to turn font bytes into a typeface, so with no FreeType in Skia the
MaterialIcons font shipped in `flutter_assets` fails exactly as silently as a
system font would. Any amount of adding files to the bundle would have produced
the same blank text.

Downstream of that, `txt` had already fallen back to the generic
`src/txt/platform.cc`, which returns `SkFontMgr::RefEmpty()` and names `"Arial"`
as the default family -- an empty manager asked for a font that does not exist.

Three changes, and they have to go together:

1. `flutter/skia/BUILD.gn` turns on `skia_use_freetype` and
   `skia_enable_fontmgr_custom_directory` for `is_vita`. The directory manager
   is the right one here: no fontconfig, no system font store, but a read-only
   app mount, so fonts ship with the app and are found by path.
2. `txt/src/txt/platform_vita.cc` returns
   `SkFontMgr_New_Custom_Directory("app0:/fonts")` and `{"Roboto"}` as the
   default families.
3. The `.vpk` ships `Roboto-Regular.ttf` into `app0:/fonts`.

`app0:/fonts` is deliberately **not** `app0:/flutter_assets/fonts`. That
directory belongs to `flutter build bundle` and holds icon fonts meant to be
looked up by asset key. Scanning it would offer MaterialIcons as a candidate for
text fallback, and text rendered in icons is a failure that looks like a font
bug and is a configuration one.
