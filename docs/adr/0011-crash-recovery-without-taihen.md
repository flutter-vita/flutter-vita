# ADR-0011: A crash returns to the loader by exiting cleanly, not by being caught

**Status:** Accepted
**Date:** 2026-08-15

## Context

The dev loop's cost is not build time. Builds are twenty seconds and an engine
object is one. The cost is that **a crash needs a person**: the console puts up
an error dialog, and somebody has to walk to the Vita, tap OK, find the loader
bubble and open it. Two manual steps, once per crash, and a port under
development produces many — on 2026-08-15 it was one every twenty seconds.

That makes the developer the slowest component in the loop, and it caps
iteration regardless of how fast everything else gets.

## Constraint: no taiHEN, including on the development console

Decided 2026-08-15. This is stronger than [ADR-0001](0001-aot-only-no-jit.md),
which only promises that *end users* need no kernel plugin.

It is worth stating explicitly because the console **does** have taiHEN —
HENkaku is what allows UNSAFE selfs to run at all — and the loader already
links `taihen_stub` and carries `kload` and `inject` commands. There is even a
SceShell module already written for exactly this problem
(`spikes/vita-shell-launcher`, commit `d1ec483`), abandoned one unresolved pid
short. The capability is present; using it is what is declined.

The reasons: a module inside SceShell can hang the shell, two earlier
`config.txt` experiments left the console unbootable, and there is one console.
A dev loop that risks the only device it runs on is not a faster dev loop.

## What that rules out

| Idea | Verdict |
|---|---|
| C++ `try`/`catch` around the fault | **Impossible.** A data abort is a hardware fault, not an exception. The kernel terminates the process; no unwinding happens. |
| A user-mode fault handler | **Impossible.** `excpmgr.h` exists only in `psp2kern`. newlib declares `signal()` but nothing wires hardware faults to it. |
| An SDK setting to suppress the crash dialog | **Does not exist.** The dialog is SceShell's; changing it means shell code. |
| A SceShell plugin | Excluded by the constraint above. |
| vitacompanion | Independently dead on this console — two clean attempts, `spikes/vita-tooling/README.md`, "do not retry". |
| Background app (`eboot2.bin`) | Blocked: the shell resolves it through its installed-titles database and `ScePromoterUtil` refuses to load for us (`MODULEMGR_NO_LIB`). Would need a one-off VitaShell install. |

## Decision

**Failures the program can see coming exit cleanly into the loader.**

`templates/vita-app/bailout.c` provides `vita_bail_to_loader(reason)`: record
the reason, `sceAppMgrLaunchAppByUri` the loader, `sceKernelExitProcess`.

The key property is that **a clean exit produces no dialog**. There is nothing
to dismiss and nothing to recover from, so both manual steps disappear at once
— which is strictly better than the background app would have managed even if
it had worked, since that recovers the loader but leaves the dialog standing.

It hooks in at `abort()` and `__assert_func()`, and this needs **no engine
rebuild**: `abort` is an *undefined* symbol in `libflutter_engine_vita.a` — the
engine calls it and libc supplies it — so a definition linked ahead of libc
wins. Dart's `OS::Abort()` is `PrepareToAbort(); abort();`, so every `FATAL`,
`UNREACHABLE` and failed runtime `ASSERT` in the VM arrives there, as does
anything in Skia or the embedder that aborts.

Measured on hardware, 2026-08-15:

```
=== TEST: abort() -> should exit clean, no dialog, loader returns ===
>>> LOADER CAME BACK BY ITSELF after 6s — no human involved
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
information needed to bail out cleanly and instead produced a data abort. That
conversion, applied across the patch set, is what turns this from a partial
mitigation into the normal path.

## Consequences

- A shipping app links neither `bailout.c` nor `devserver.c`. An app that
  relaunches a development loader on an assertion is obviously wrong, and
  dropping both files is all that takes.
- `abort()` no longer aborts. Anything that expected a core dump from
  `abort()` gets a clean exit and a line in
  `ux0:data/flutter-vita/bailout.txt` instead. Core dumps from real faults are
  unaffected, and those are the ones that have been worth reading.
- The loader title id is compiled in (`VITA_LOADER_TITLEID`, default
  `FVTA00003`).
- The background-app work is not wasted but is parked: if the dialog ever
  needs surviving, a one-off VitaShell install of a promoted `.vpk` is the
  route, and the `param2.sfo` plumbing is already built.

## Related

- [ADR-0001](0001-aot-only-no-jit.md) — no taiHEN as a *product* dependency
- `spikes/vita-tooling/README.md` — vitacompanion, and what UNSAFE selfs can
  and cannot write
- [HANDOFF-nondeterministic-crash.md](../HANDOFF-nondeterministic-crash.md) —
  the emutls crash, and why it is the model for the conversion above
