# ADR-0016: The loader becomes a Flutter app, and stops being invisible

**Status:** Accepted
**Date:** 2026-08-22

## Context

The loader is `FVTA00003`: a 91 KB C application that receives a `.vpk` from
the CLI, writes it into the app slot, launches it, and serves logs and crash
dumps back over TCP on port 1341. [ADR-0011](0011-crash-recovery-without-taihen.md)
built it so a crash costs no walk to the console, and
[ADR-0015](0015-four-products-one-audience.md) named it one of the port's four
products — the developer-only one.

**It draws nothing.** The framebuffer is deliberately left black, with a
comment about OLED burn-in, and every capability it has is reachable only
through a socket. That was a reasonable choice for a tool driven entirely by a
CLI, and it has one concrete cost that this session hit twice: **when the
console's Wi-Fi drops and comes back on a different address, the loader knows
its own IP and has no way to say so.** The recovery is a human reading it off
the Vita's settings screen and typing it back. A tool whose whole purpose is to
remove trips to the console requires one to find out where it is.

There is a second reason, and it is the one that decided the shape rather than
the existence of this work. Quoting the decision directly:

> It should be on flutter because it will be window in flutter world for
> flutter developers — thats the idea

The loader is the first thing a Flutter developer installs on their Vita and
the first thing they see running. If it is a C program, the first evidence they
get that the port works is an app they have to build themselves. If it is a
Flutter app, the proof is on screen before they have written a line.

## Decision

**The loader is rewritten as a Flutter application, built from the same app
template as any other, with a C layer underneath that owns the network port.**

The screen carries, top to bottom: the Flutter logo, the IP and port, the
current status, a log of recent actions, and the versions — loader, engine,
Flutter and Dart.

### The nine decisions behind that, and what each rejected

**1. Flutter, not a bitmap font in C.** The four screen elements could be drawn
by the app template's existing debug-HUD font for a fraction of the work, with
no bootstrap risk and instant startup. Rejected because the UI is not the
point: a C loader that displays an IP solves the Wi-Fi problem and proves
nothing about the port. The showcase is the requirement; the IP display is the
bonus.

**2. A pinned, known-good engine — not the current build.** The loader would
otherwise link the engine it exists to help develop, so an engine change that
breaks an app breaks the tool needed to deploy the fix. Pinning costs two
engine copies on the memory card and means the loader lags the engine under
development. It buys the property that matters: **a broken engine can cost you
your app, never your ability to replace it.** The pin is bumped deliberately,
never as a side effect of a rebuild.

**3. The C layer starts the TCP server before the engine.** Exactly the pattern
`vita_embedder.cc` already uses for the app's dev server, and for the same
reason — a hang or fault during startup must still be debuggable. If Flutter
fails to start for any reason, the loader is still fully functional over the
socket and only the screen is lost. This is what makes decision 1 affordable.

**4. Built from the app template.** The loader becomes an ordinary
Flutter-Vita application: same template, same build script, same snapshot, same
engine artifact. That dogfoods the whole toolchain rather than only the engine,
and it means the loader cannot drift into a private build path that works when
the real one does not. Loader-specific commands extend the dev server it
already shares.

**5. The log is in-memory and session-scoped.** Rejected persistence, and this
one was argued: `cmd_launch` calls `sceAppMgrLaunchAppByUri` and then
`sceKernelExitProcess(0)`, so **the loader dies every time it launches an
app**. Its whole life is boot, serve a handful of commands, launch, exit — and
an in-memory log is therefore empty at exactly the moment after a crash
recovery when a history would be most wanted. Chosen anyway, knowingly: the
field's job is to show a deploy happening live, and the CLI already pulls the
app's log and dumps on demand. Recorded here so that "the log is always empty"
is a known property rather than a bug report.

**6. The ~3 second startup is accepted.** The C loader appears instantly; a
Flutter one does not, and every crash recovery in the debug loop pays the
difference. Rejected the alternative of painting the critical line in C first
and letting Flutter take over, which would have hidden the cost. Three seconds
is small against a build, and the CLI waits on the port rather than the screen.

**7. Software rendering, always.** No `gl.on` switch, unlike apps.
[ADR-0014](0014-gpu-backend-via-vitagl.md) established on 2026-08-22 that a
hard crash under GL can wedge the entire console — the PS button stops
responding and only the power button recovers it — because a data abort runs no
user code and nothing releases the GXM context. **The loader is the component
that recovers from crashes, so it is the last one permitted to cause an
unrecoverable one.** The cost is real and accepted: the window into the Flutter
world shows the CPU rasteriser.

**8. No crash supervisor.** The template ships one — a background application
that relaunches the loader when the app dies — and the loader is what it
recovers *to*. A second copy would contend for the same background title id,
and "relaunch the loader when the loader dies" has no obvious stopping
condition. A loader crash therefore still costs a tap, as it does today.

**9. The command surface is trimmed.** Nineteen commands become twelve:
`ping`, `probe`, `log`, `get`, `put`, `shot`, `shotinfo`, `stage`, `install`,
`launch`, `promote`, `ls`. Dropped: `kload`, `inject` and `exec`, which were kernel and taiHEN
experiments that ADR-0011 closed off; and `touch`, `rm`, `mkdir`, `cp`,
`canwrite`, `deploy`, `screen`, `exit`. `shot` and `shotinfo` are in because
the loader now has a screen: capturing it is how a change to it is checked,
and this is the one component whose panel is the deliverable. Less surface on the one component with
the strongest reliability requirement.

Two of those were on the drop list when this was first written and were put
back on reading what the CLI actually sends, which is what "trim to what the
CLI and I actually use" has to mean. `stage` is half of `install` —
`tools/deploy.sh` streams the eboot with it and then installs from the staged
copy. `promote` is how the loader replaces *itself*, and it matters more now
than it did: a Flutter loader is ~13 MB and `ux0:app/<self>` is a read-only
mount, so the promoter is the only route by which a new loader can reach the
console at all. `ls` survives because it has repeatedly answered "is this path
writable" without a rebuild, including twice in this session.

## The status model

"Current status" is the field that justifies the screen, so it is worth being
precise about rather than leaving to the implementation. The loader is in
exactly one of:

| Status | Means | Why it earns a line |
|---|---|---|
| **No network** | Wi-Fi is down or unassociated | The single most valuable state. It is precisely when the CLI cannot reach the loader, so the panel is the only channel left — and it is the state that cost this session two long stalls |
| **Waiting** | Listening, no client connected | The normal resting state. Shows the address to type |
| **Receiving** | A `put` or `install` is streaming | With bytes so far, because a large `eboot.bin` takes long enough to look like a hang |
| **Installing** | Writing into the app slot | Distinct from receiving: this is the part that can fail on permissions |
| **Launching** | About to hand over and exit | Brief by construction — the process ends here |

`Launching` being terminal is the model telling the truth about decision 5: the
loader has no state after it, because it has no self after it.

## Consequences

- **The loader grows from 91 KB to 13 MB** (measured; this said "roughly
  20 MB" before it was built). It carries an engine, a
  snapshot, `icudtl.dat` and assets. It is installed rarely, so this is a
  one-time transfer rather than a per-cycle cost, but `tools/update-loader.sh`
  becomes a slow command.
- **Two engine copies live on the console**, at different revisions by design.
- **The port's reliability story now has a Flutter dependency in it.** ADR-0011
  built crash recovery out of pieces that could not themselves fail in the ways
  they were recovering from. Decisions 2, 3, 7 and 9 exist to keep that true;
  decision 6 and the absence of a supervisor are where it is weakened.
- **A loader crash is more likely than before** — a Flutter app has more ways
  to fail than a 91 KB C program — and less recoverable, because decision 8
  leaves nothing catching it.
- The `.vpk` the CLI installs and the loader itself are now built the same way,
  which means the loader is a working example of the toolchain rather than an
  exception to it.

## Where this stands, and the one thing blocking it

Built and measured on hardware on 2026-08-22, running from a scratch slot on
port 1342 rather than `FVTA00003`, because replacing the loader in place is
replacing the only way to install anything.

Working: the C layer holds the port before the engine starts, the panel renders
all five elements, the watcher publishes the address within a second of Wi-Fi
associating, the log fills live, `launch <titleid>` hands the console over, and
the whole thing is 13 MB rather than the 20 MB this ADR guessed.

**Not working: `promote`, which is the only route by which the Flutter loader
can reach `FVTA00003`.** An app cannot write its own install directory —
`ux0:app/<self>` is the read-only `app0:` mount — so a new loader has to go
through the system promoter, and on this console
`sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL)` returns
`SCE_KERNEL_ERROR_MODULEMGR_NO_LIB` (`0x8002D003`). The `WithArg` spelling
returns the same code once it is given a real `SceSysmoduleOpt` — passing
`NULL` for `option` returns `INVALID_MEMORY_ACCESS` and says nothing about the
module. **The existing C loader fails identically**, so this is the console's
state rather than anything this rework introduced, and it is not a reason to
doubt the design.

Two things learned the hard way while getting here, both worth more than the
code they fixed:

- **A Vita import stub for a module that is not resident is address zero, not
  a function that fails.** The first watcher called `sceNetCtlInetGetInfo` from
  its constructor, before the dev server had loaded `SCE_SYSMODULE_NET`, and
  the process died with a prefetch abort at PC 0 — no frame, no symbol, nothing
  to read but the LR. `dev_server_set_ready_handler` exists because of it. The
  same mistake, made deliberately on the promoter path in the belief that a
  failed load could be survived, produced the same abort a second time.
- **The supervisor works.** When the scratch loader faulted, `FVTA00003` came
  back on its own and the next deploy went out without a tap. ADR-0011's
  recovery path was exercised by accident and held.

## Revisit trigger

- **The loader crashes often enough to be annoying.** Then decision 8 was
  wrong, and the answer is either a supervisor with a bounded relaunch count or
  a reversion to C.
- **The pinned engine falls far enough behind to be misleading.** A window into
  the Flutter world that shows a stale renderer is a worse advertisement than
  no window. If the pin lags by more than a release, either bump it or say so
  on the screen.
- **GL crash recovery is solved.** Decision 7 exists only because a faulting
  process cannot release the GPU. If that changes, the loader showing the GPU
  path becomes the better showcase.

## Related

- [ADR-0011](0011-crash-recovery-without-taihen.md) — why the loader exists at all
- [ADR-0014](0014-gpu-backend-via-vitagl.md) — why it renders in software
- [ADR-0015](0015-four-products-one-audience.md) — the loader as one of four products
