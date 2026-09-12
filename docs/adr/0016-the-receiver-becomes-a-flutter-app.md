# ADR-0016: The receiver becomes a Flutter app, and stops being invisible

**Status:** Accepted
**Date:** 2026-08-22

## Context

The receiver is `FVTA00003`: a 91 KB C application that receives a `.vpk` from
the CLI, writes it into the app slot, launches it, and serves logs and crash
dumps back over TCP on port 1341. [ADR-0011](0011-crash-recovery-without-taihen.md)
built it so a crash costs no walk to the console, and
[ADR-0015](0015-four-products-one-audience.md) named it one of the port's four
products — the developer-only one.

**It draws nothing.** The framebuffer is deliberately left black, with a
comment about OLED burn-in, and every capability it has is reachable only
through a socket. That was a reasonable choice for a tool driven entirely by a
CLI, and it has one concrete cost that this session hit twice: **when the
console's Wi-Fi drops and comes back on a different address, the receiver knows
its own IP and has no way to say so.** The recovery is a human reading it off
the Vita's settings screen and typing it back. A tool whose whole purpose is to
remove trips to the console requires one to find out where it is.

There is a second reason, and it is the one that decided the shape rather than
the existence of this work. Quoting the decision directly:

> It should be on flutter because it will be window in flutter world for
> flutter developers — thats the idea

The receiver is the first thing a Flutter developer installs on their Vita and
the first thing they see running. If it is a C program, the first evidence they
get that the port works is an app they have to build themselves. If it is a
Flutter app, the proof is on screen before they have written a line.

## Decision

**The receiver is rewritten as a Flutter application, built from the same app
template as any other, with a C layer underneath that owns the network port.**

The screen carries, top to bottom: the Flutter logo, the IP and port, the
current status, a log of recent actions, and the versions — receiver, engine,
Flutter and Dart.

### The nine decisions behind that, and what each rejected

**1. Flutter, not a bitmap font in C.** The four screen elements could be drawn
by the app template's existing debug-HUD font for a fraction of the work, with
no bootstrap risk and instant startup. Rejected because the UI is not the
point: a C receiver that displays an IP solves the Wi-Fi problem and proves
nothing about the port. The showcase is the requirement; the IP display is the
bonus.

**2. A pinned, known-good engine — not the current build.** The receiver would
otherwise link the engine it exists to help develop, so an engine change that
breaks an app breaks the tool needed to deploy the fix. Pinning costs two
engine copies on the memory card and means the receiver lags the engine under
development. It buys the property that matters: **a broken engine can cost you
your app, never your ability to replace it.** The pin is bumped deliberately,
never as a side effect of a rebuild.

**3. The C layer starts the TCP server before the engine.** Exactly the pattern
`vita_embedder.cc` already uses for the app's dev server, and for the same
reason — a hang or fault during startup must still be debuggable. If Flutter
fails to start for any reason, the receiver is still fully functional over the
socket and only the screen is lost. This is what makes decision 1 affordable.

**4. Built from the app template.** The receiver becomes an ordinary
Flutter-Vita application: same template, same build script, same snapshot, same
engine artifact. That dogfoods the whole toolchain rather than only the engine,
and it means the receiver cannot drift into a private build path that works when
the real one does not. Receiver-specific commands extend the dev server it
already shares.

**5. The log is in-memory and session-scoped.** Rejected persistence, and this
one was argued: `cmd_launch` calls `sceAppMgrLaunchAppByUri` and then
`sceKernelExitProcess(0)`, so **the receiver dies every time it launches an
app**. Its whole life is boot, serve a handful of commands, launch, exit — and
an in-memory log is therefore empty at exactly the moment after a crash
recovery when a history would be most wanted. Chosen anyway, knowingly: the
field's job is to show a deploy happening live, and the CLI already pulls the
app's log and dumps on demand. Recorded here so that "the log is always empty"
is a known property rather than a bug report.

**6. The ~3 second startup is accepted.** The C receiver appears instantly; a
Flutter one does not, and every crash recovery in the debug loop pays the
difference. Rejected the alternative of painting the critical line in C first
and letting Flutter take over, which would have hidden the cost. Three seconds
is small against a build, and the CLI waits on the port rather than the screen.

**7. Software rendering, always.** No renderer switch, unlike apps — and
since the app default flipped to GL on 2026-08-24, the receiver is now the
exception rather than the rule. It links its own strong
`int flutter_vita_force_software = 1;` against the engine's weak definition, so
the CPU path is a link-time fact rather than a file the memory card might be
missing: a switch the receiver has to read is a switch that can be missing on the
one component where that matters most.
[ADR-0014](0014-gpu-backend-via-vitagl.md) established on 2026-08-22 that a
hard crash under GL can wedge the entire console — the PS button stops
responding and only the power button recovers it — because a data abort runs no
user code and nothing releases the GXM context. **The receiver is the component
that recovers from crashes, so it is the last one permitted to cause an
unrecoverable one.** The cost is real and accepted, and grew when the app
default flipped: the window into the Flutter world now shows the slower of the
two rasterisers, by margins [ADR-0017](0017-the-gallery-becomes-the-benchmark.md)
puts between 5× and 17× on the scenes that move. The receiver draws a logo, an
address and a log — none of which are those scenes.

**8. No crash supervisor.** The template ships one — a background application
that relaunches the receiver when the app dies — and the receiver is what it
recovers *to*. A second copy would contend for the same background title id,
and "relaunch the receiver when the receiver dies" has no obvious stopping
condition. A receiver crash therefore still costs a tap, as it does today.

**9. The command surface is trimmed.** Nineteen commands become twelve:
`ping`, `probe`, `log`, `get`, `put`, `shot`, `shotinfo`, `stage`, `install`,
`launch`, `promote`, `ls`. Dropped: `kload`, `inject` and `exec`, which were kernel and taiHEN
experiments that ADR-0011 closed off; and `touch`, `rm`, `mkdir`, `cp`,
`canwrite`, `deploy`, `screen`, `exit`. `shot` and `shotinfo` are in because
the receiver now has a screen: capturing it is how a change to it is checked,
and this is the one component whose panel is the deliverable. Less surface on the one component with
the strongest reliability requirement.

Two of those were on the drop list when this was first written and were put
back on reading what the CLI actually sends, which is what "trim to what the
CLI and I actually use" has to mean. `stage` is half of `install` —
`tools/deploy.sh` streams the eboot with it and then installs from the staged
copy. `promote` is how the receiver replaces *itself*, and it matters more now
than it did: a Flutter receiver is ~13 MB and `ux0:app/<self>` is a read-only
mount, so the promoter is ~~the only route by which a new receiver can reach the
console at all~~ one of two routes.

> **Corrected 2026-08-31.** The read-only mount is real and only covers the
> app's *own* directory. Any other title's is ordinary storage an UNSAFE self
> writes freely, so an app installs the receiver by plain file copy, and the
> promoter is needed only to register a title id that does not exist yet. The
> receiver installs the app, the app installs the receiver:
> `tools/update-receiver.sh` is that second half, and it replaced FVTA00004 in
> place today with no promoter and no tap. `ls` survives because it has repeatedly answered "is this path
writable" without a rebuild, including twice in this session.

> **`rm` came back, 2026-09-09.** It was on the drop list as a debugging verb.
> It is not: without it `tools/deploy.sh` can only add and overwrite, so a file
> dropped from a package stays in `ux0:app/<titleid>` for the life of the
> install. `assets/fonts/NotoEmoji-Regular.ttf` was removed from the repo and
> the package that day, the gallery was redeployed clean, and the console still
> held it at 1,982,596 bytes — still in `app0:/fonts`, still a candidate for
> every codepoint. The deploy's manifest already knows which files have gone;
> it had no way to say so. Thirteen commands, and the recursive one is still
> confined to `ux0:data`.

## The status model

"Current status" is the field that justifies the screen, so it is worth being
precise about rather than leaving to the implementation. The receiver is in
exactly one of:

| Status | Means | Why it earns a line |
|---|---|---|
| **No network** | Wi-Fi is down or unassociated | The single most valuable state. It is precisely when the CLI cannot reach the receiver, so the panel is the only channel left — and it is the state that cost this session two long stalls |
| **Waiting** | Listening, no client connected | The normal resting state. Shows the address to type |
| **Receiving** | A `put` or `install` is streaming | With bytes so far, because a large `eboot.bin` takes long enough to look like a hang |
| **Installing** | Writing into the app slot | Distinct from receiving: this is the part that can fail on permissions |
| **Launching** | About to hand over and exit | Brief by construction — the process ends here |

`Launching` being terminal is the model telling the truth about decision 5: the
receiver has no state after it, because it has no self after it.

## Consequences

- **The receiver grows from 91 KB to 13 MB** (measured; this said "roughly
  20 MB" before it was built). It carries an engine, a
  snapshot, `icudtl.dat` and assets. It is installed rarely, so this is a
  one-time transfer rather than a per-cycle cost, but `tools/update-receiver.sh`
  becomes a slow command.
- **Two engine copies live on the console**, at different revisions by design.
- **The port's reliability story now has a Flutter dependency in it.** ADR-0011
  built crash recovery out of pieces that could not themselves fail in the ways
  they were recovering from. Decisions 2, 3, 7 and 9 exist to keep that true;
  decision 6 and the absence of a supervisor are where it is weakened.
- **A receiver crash is more likely than before** — a Flutter app has more ways
  to fail than a 91 KB C program — and less recoverable, because decision 8
  leaves nothing catching it.
- The `.vpk` the CLI installs and the receiver itself are now built the same way,
  which means the receiver is a working example of the toolchain rather than an
  exception to it.

## Where this stands, and the one thing blocking it

Built and measured on hardware on 2026-08-22, running from a scratch slot on
port 1342 rather than `FVTA00003`, because replacing the receiver in place is
replacing the only way to install anything.

Working: the C layer holds the port before the engine starts, the panel renders
all five elements, the watcher publishes the address within a second of Wi-Fi
associating, the log fills live, `launch <titleid>` hands the console over, and
the whole thing is 13 MB rather than the 20 MB this ADR guessed.

**~~Not working: `promote`.~~ Working, 2026-08-31.** ~~The only route by which
the Flutter receiver can reach `FVTA00003`.~~

> **Resolved 2026-08-31.** `promote` works, and with it the receiver stopped
> needing a slot somebody had already created by hand.
>
> Three things were load-bearing, each found by driving the promoter one step at
> a time from the receiver rather than five steps per power cycle:
>
> - **PAF must stay resident.** It is loaded before the promoter and never
>   unloaded. Unloading it kills the console about ten seconds later, because
>   PAF runs a thread of its own and unmapping the module under it is a data
>   abort. Confirmed alive through fifteen minutes and four promote calls.
> - **The staging directory is `ux0:data/pkg`.** `PromotePkg` accepts any path
>   and never succeeds; `PromotePkgWithRif` succeeds only from there, and
>   returns `0x8010111C` from anywhere else — the same code as a missing
>   header, which is why it hid.
> - **`sce_sys/package/head.bin` must exist and carry this title's content id.**
>   `tools/make-head-bin.py` writes one. No key is involved.
>
> **The receiver is now `FVTA00001`**, installed by the promoter rather than by
> VitaShell, and `tools/install-vpk.sh` registers title ids that never existed.
> Every `FVTA00003` below should be read as `FVTA00001`; the number was an
> inheritance from whichever slot had been created by hand, and is now a choice.
> `tools/build-receiver.sh` defaults to it.
>
> One stale default remains and is harmless: the *pinned* engine's
> `devserver.h` still says `FVTA00003`, and it is a pinned artifact that only
> `pin-receiver-engine.sh` refreshes. `ux0:data/flutter-vita/receiver.titleid`
> overrides it at runtime and now reads `FVTA00001`. `sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL)`
returns `SCE_KERNEL_ERROR_MODULEMGR_NO_LIB` (`0x8002D003`), the `WithArg`
spelling returns the same, and the C receiver fails identically.

> **Corrected 2026-08-31.** All of those measurements were right and the
> conclusion was wrong. `NO_LIB` means a library could not be linked: the
> promoter imports from PAF, and PAF was not resident in our process. Load PAF
> first — with its argument block, which is not optional — and the promoter
> loads and initialises. No taiHEN and no kernel module. See
> [`experiments/promoter`](../../experiments/promoter/); the fix is in
> `receiver/src/receiver_dev.c`.
>
> Two other conclusions in this ADR rest on the old reading. A new receiver does
> **not** have to go through the promoter at all: an app can write any title's
> directory except its own, so any running app can install a receiver by file
> copy. And a new title id, which does need the promoter, is now ours to
> register.

Two things learned the hard way while getting here, both worth more than the
code they fixed:

- **A Vita import stub for a module that is not resident is address zero, not
  a function that fails.** The first watcher called `sceNetCtlInetGetInfo` from
  its constructor, before the dev server had loaded `SCE_SYSMODULE_NET`, and
  the process died with a prefetch abort at PC 0 — no frame, no symbol, nothing
  to read but the LR. `dev_server_set_ready_handler` exists because of it. The
  same mistake, made deliberately on the promoter path in the belief that a
  failed load could be survived, produced the same abort a second time.
- **The supervisor works.** When the scratch receiver faulted, `FVTA00003` came
  back on its own and the next deploy went out without a tap. ADR-0011's
  recovery path was exercised by accident and held.

## Revisit trigger

- **The receiver crashes often enough to be annoying.** Then decision 8 was
  wrong, and the answer is either a supervisor with a bounded relaunch count or
  a reversion to C.
- **The pinned engine falls far enough behind to be misleading.** A window into
  the Flutter world that shows a stale renderer is a worse advertisement than
  no window. If the pin lags by more than a release, either bump it or say so
  on the screen.
- **GL crash recovery is solved.** Decision 7 exists only because a faulting
  process cannot release the GPU. If that changes, the receiver showing the GPU
  path becomes the better showcase.

## Related

- [ADR-0011](0011-crash-recovery-without-taihen.md) — why the receiver exists at all
- [ADR-0014](0014-gpu-backend-via-vitagl.md) — why it renders in software
- [ADR-0015](0015-four-products-one-audience.md) — the receiver as one of four products
