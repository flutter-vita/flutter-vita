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
| Skia | **builds** — 544 objects, [two files patched](../patches/skia/README.md) |
| `fml` | **compiles** — but `MessageLoopImpl::Create()` returns nullptr, see below |
| Everything else in the engine | **compiles** — display_list, lib/ui, lib/gpu, tonic, abseil, shell, flow, txt |
| Dart runtime under the engine's GN | **compiles** — it came for free, as hoped |
| `dart:io` for vita | **compiles — all 16 modules plus `socket_base_posix.cc`.** `process` still undefined at link |
| **Every source file in the engine** | **compiles — 2682 objects, `ninja` exit 0** |
| Link the engine | **attempted — 66 undefined symbols, listed in [m2-undefined-symbols.txt](m2-undefined-symbols.txt)** |

## Order of work

1. ~~**Skia**~~ — done. Two files: platform detection, and a heap-copy
   replacement for `mmap`. See [the patch notes](../patches/skia/README.md);
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
   new `spikes/m2-link-check/`, following the pattern `spikes/m1-vpk` already
   uses for Dart.

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

**2. The `*at()` family (12), and this is the find.** `openat`, `fstatat`,
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
nothing in a single-app homebrew build appears to need. **Decide before
writing.**

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
