# ADR-0011: A crash returns to the bridge by exiting cleanly, not by being caught

**Status:** Accepted
**Date:** 2026-08-15

## Context

The dev loop's cost is not build time. Builds are twenty seconds and an engine
object is one. The cost is that **a crash needs a person**: the console puts up
an error dialog, and somebody has to walk to the Vita, tap OK, find the bridge
bubble and open it. Two manual steps, once per crash, and a port under
development produces many — on 2026-08-15 it was one every twenty seconds.

That makes the developer the slowest component in the loop, and it caps
iteration regardless of how fast everything else gets.

## Constraint: no taiHEN, including on the development console

Decided 2026-08-15. This is stronger than [ADR-0001](0001-aot-only-no-jit.md),
which only promises that *end users* need no kernel plugin.

It is worth stating explicitly because the console **does** have taiHEN —
HENkaku is what allows UNSAFE selfs to run at all — and the bridge already
links `taihen_stub` and carries `kload` and `inject` commands. There is even a
SceShell module already written for exactly this problem
(`experiments/vita-shell-launcher`, commit `d1ec483`), abandoned one unresolved pid
short. The capability is present; using it is what is declined.

The reasons: a module inside SceShell can hang the shell, two earlier
`config.txt` experiments left the console unbootable, and there is one console.
A dev loop that risks the only device it runs on is not a faster dev loop.

## Amendment, 2026-08-21: in-process user hooks are not what this declined

The constraint above is written flat — "no taiHEN" — and the GPU work found a
case its *reasons* do not reach.

vitaGL's shader compiler chain ends at taiHEN:

```
libvitaGL.a        -> shark_*, sceShaccCg*   (gxm.o calls shark_init from vglInit)
libvitashark.a     -> sceShaccCgExt*
libSceShaccCgExt.a -> taiHookFunctionOffsetForUser, taiInjectDataForUser, ...
```

The edge is the **`*ForUser`** family. Every `ForKernel` entry point in
`taihen.h` takes an explicit `SceUID pid`; the `ForUser` ones take none. They
patch `SceShaccCg` **inside our own address space**, and they die with the
process.

The reasons this ADR gives for the constraint are specific: *a module inside
SceShell can hang the shell*, and *two `config.txt` experiments left the console
unbootable*. An in-process hook can do neither. It cannot touch SceShell, it
does not survive a reboot, and there is nothing to write into `config.txt`.

Measured rather than argued: `shark_init(NULL)` returns **0** on this console
from an UNSAFE self, and `experiments/g1-vitagl` then passes every check including a
correct green readback out of an FBO.

**Decided 2026-08-21: the constraint is narrowed to what it meant.**

| Declined, still | Permitted |
|---|---|
| Kernel plugins (`taiLoadStartKernelModule`) | In-process user hooks that die with the app |
| SceShell modules (`inject`) | — |
| Anything in `ur0:tai/config.txt` | — |

The bridge keeps its `kload` and `inject` commands and keeps not using them.
[ADR-0001](0001-aot-only-no-jit.md)'s product promise is unaffected: a console
that can run homebrew at all already has taiHEN, and it is the same population
that installs `libshacccg.suprx`.

See [ADR-0014](0014-gpu-backend-via-vitagl.md) for the evidence.

## What that rules out

| Idea | Verdict |
|---|---|
| C++ `try`/`catch` around the fault | **Impossible.** A data abort is a hardware fault, not an exception. The kernel terminates the process; no unwinding happens. |
| A user-mode fault handler | **Impossible.** `excpmgr.h` exists only in `psp2kern`. newlib declares `signal()` but nothing wires hardware faults to it. |
| An SDK setting to suppress the crash dialog | **Does not exist.** The dialog is SceShell's; changing it means shell code. |
| A SceShell plugin | Excluded by the constraint above. |
| vitacompanion | Independently dead on this console — two clean attempts, `experiments/vita-tooling/README.md`, "do not retry". |
| Background app (`eboot2.bin`) | ~~Blocked~~ **Unblocked 2026-08-31.** The shell resolves it through its installed-titles database, and `ScePromoterUtil` was read as refusing to load (`MODULEMGR_NO_LIB`). It does not refuse: it imports from PAF, which was not resident. Load PAF first and the promoter works, so no VitaShell install is needed. See [`experiments/promoter`](https://github.com/flutter-vita/flutter-vita/blob/c91294a/experiments/promoter). |

## Decision

**Failures the program can see coming exit cleanly into the bridge.**

`templates/vita-app/bailout.c` provides `vita_bail_to_loader(reason)`: record
the reason, `sceAppMgrLaunchAppByUri` the bridge, `sceKernelExitProcess`.

The key property is that **a clean exit produces no dialog**. There is nothing
to dismiss and nothing to recover from, so both manual steps disappear at once
— which is strictly better than the background app would have managed even if
it had worked, since that recovers the bridge but leaves the dialog standing.

It hooks in at `abort()` and `__assert_func()`, and this needs **no engine
rebuild**: `abort` is an *undefined* symbol in `libflutter_engine_vita.a` — the
engine calls it and libc supplies it — so a definition linked ahead of libc
wins. Dart's `OS::Abort()` is `PrepareToAbort(); abort();`, so every `FATAL`,
`UNREACHABLE` and failed runtime `ASSERT` in the VM arrives there, as does
anything in Skia or the embedder that aborts.

Measured on hardware, 2026-08-15:

```
=== TEST: abort() -> should exit clean, no dialog, bridge returns ===
>>> BRIDGE CAME BACK BY ITSELF after 6s — no human involved
```

`bail` and `abort` are dev-server commands, so the recovery path is checkable
in ten seconds from the host. A recovery mechanism nobody can trigger is a
recovery mechanism nobody notices is broken.

## What this does not cover, stated plainly

**A wild pointer still costs both taps.** Nothing user-mode can catch a data
abort, and that is not a gap in this design — it is the platform.

The mitigation is not a better handler, it is **fewer uncatchable failures**:
every place our own patches can fail fatally should call
`vita_bail_to_loader` rather than return something the caller cannot check.
The crash diagnosed the same day is the case in point — the emulated-TLS table
knew it was out of slots and returned NULL into
`dart::OSThread::SetCurrentTLS`, which dereferenced it. It had every piece of
information needed to bail out cleanly and instead produced a data abort.

### How much of the patch set needs that conversion: one file

Audited 2026-08-15, and the answer was smaller and more interesting than
expected. There are 38 silent-failure returns across the 13 Vita-specific
files, and nearly all are correct, because their contracts are **nullable** and
the caller is obliged to check:

| Pattern | Sites | Why it is fine |
|---|---|---|
| `errno = ENOTSUP; return -1` — POSIX shims | 15 | Standard contract; becomes a Dart exception |
| `return false` — `stdio_vita.cc` echo modes | 8 | Truthful; surfaces as `StdinException` |
| `Process` refusing to fork | 5 | A documented implementation, not a placeholder |
| `VirtualMemory::Allocate → nullptr` | 2 | Dart's own OOM path, plus the deliberate no-JIT refusal |

The dangerous case is not "returns NULL", it is **"returns NULL where the
caller structurally cannot check"** — functions the *compiler* emits calls to,
whose call sites dereference unconditionally. Across the whole series there is
exactly one:

```
$ grep -oE "__[a-z_]+" runtime/{bin,platform}/*vita*.cc | sort -u
__emutls_get_address
__emutls_register_common     # cannot fail; returns void
```

So `__emutls_get_address` was structurally unique rather than one instance of a
widespread pattern, which is why it produced an anonymous data abort while
every other failure in this port produces a readable Dart exception.

**There is no sweep outstanding.** What replaces it is a rule, recorded in
[the patch notes](https://github.com/flutter-vita/dart-sdk/commits/vita-3.44.8): a Vita implementation of a
function the compiler emits calls to must exit, not return a failure value.
That rule is for the next hand-rolled ABI function, not for the current ones.

## Consequences

- A shipping app links neither `bailout.c` nor `devserver.c`. An app that
  relaunches a development bridge on an assertion is obviously wrong, and
  dropping both files is all that takes.
- `abort()` no longer aborts. Anything that expected a core dump from
  `abort()` gets a clean exit and a line in
  `ux0:data/flutter-vita/bailout.txt` instead. Core dumps from real faults are
  unaffected, and those are the ones that have been worth reading.
- The bridge title id is compiled in (`VITA_LOADER_TITLEID`, default
  `FVTA00003`).
- The background-app work is not wasted but is parked: if the dialog ever
  needs surviving, a one-off VitaShell install of a promoted `.vpk` is the
  route, and the `param2.sfo` plumbing is already built.

## Related

- [ADR-0001](0001-aot-only-no-jit.md) — no taiHEN as a *product* dependency
- `experiments/vita-tooling/README.md` — vitacompanion, and what UNSAFE selfs can
  and cannot write
- [HANDOFF-nondeterministic-crash.md](../HANDOFF-nondeterministic-crash.md) —
  the emutls crash, and why it is the model for the conversion above
