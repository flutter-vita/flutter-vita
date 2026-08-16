# Roadmap after M3 — what a real app needs, in priority order

M3 proved a Flutter counter app runs on hardware. A counter app needs a screen
and a finger. A *real* app needs a filesystem, a network, a keyboard, and sound,
and this is the order those get built.

Controls are deliberately late. Touch is enough to operate an app, the design is
already settled in [ADR-0010](adr/0010-input-layering-and-psvita-api.md), and
nothing else is waiting on it.

## The status table

**Measured, not assumed** — every row below was run on hardware. The audit was
[2026-08-14](phase-5-capability-audit.md); the current state is the conformance
app's own verdict, **45 probes, 45 pass, 0 fail**, in a single run on
2026-08-15.

That was the point of doing the audit first. `runtime/bin` was ported in Phase 2
to make the engine *link*, and the working assumption was that little of it
would actually run. Most of it does, and the three things that do not are
specific enough to name — which is a very different plan from the one written
before the measurement.

| Capability | Status | Evidence |
|---|---|---|
| Front touch | **works** | M3, on hardware |
| Rendering, text, assets | **works** | M3 |
| `dart:io` File / Directory | **works** | [audited on hardware](phase-5-capability-audit.md) — read, stat, mkdir, write, append, list, rename, delete |
| `dart:io` Socket / HttpClient | **works** | audited — DNS, TCP, and `HTTP 200` from the open internet |
| TLS / HTTPS | **works** | [Phase 7](phase-7-tls.md) — real handshake, verified chain, `HTTPS 200` on hardware |
| `Directory.systemTemp` | **works** | Phase 6 — `ux0:data/<TITLEID>/tmp`, created on first use |
| `Platform.numberOfProcessors` | **works** | Phase 6 — 3, from the thread affinity mask |
| Dart `print` | **works** | goes through the engine log, not `dart:io` |
| Dart stdout / stderr | **partly** | construction works — Vita reports `kPipe`, since `fstat` on fds 0/1/2 fails — but the write itself still fails: `writeFrom failed (OS Error: Bad file number, errno = 9)`, surfacing asynchronously as an unhandled exception rather than at the call. Needs fd 1/2 routed to the log |
| `Process` | **refused, correctly** | `process_vita.cc` — no fork, no exec, documented as an implementation not a placeholder |
| Text input / IME | **channel works, dialog blocked** | `flutter/textinput` measured end to end from a real `TextField`; `sceImeDialogInit` succeeds and the GPU driver then kills the process. Needs a minimal GXM pipeline — see Phase 8 |
| Audio | **not started** | `sceAudioOut` exists |
| Gamepad, sticks, rear touch | **designed, not built** | [ADR-0010](adr/0010-input-layering-and-psvita-api.md) |
| **Bluetooth** | **blocked** | see below |
| Motion, camera, mic, GPS | **not started** | headers exist |

### Bluetooth is blocked, and not by effort

VitaSDK exposes Bluetooth only as `psp2kern/bt.h` — **kernel-side**. Reaching it
needs a taiHEN kernel plugin, and [ADR-0001](adr/0001-aot-only-no-jit.md) makes
taiHEN explicitly not a dependency of this project.

So Bluetooth is not a phase, it is an ADR revision. It would mean shipping a
kernel plugin alongside every app, asking every user to install it, and owning
the crash surface of kernel code on a console people cannot easily un-brick.
The revisit condition is a use case that justifies all three, and "some apps use
`flutter_blue_plus`" is not it — those apps do not run for many other reasons
first.

Worth separating from what people usually mean by Bluetooth on a Vita: pairing a
DualShock controller is a *system* function that works without any app
involvement, and it arrives as ordinary `sceCtrl` input.

---

## Phase 5 — Capability audit — **DONE**

Ran 2026-08-14. **28 of 31 probes pass**; see
[the results](phase-5-capability-audit.md). Filesystem and networking both
substantially work, which shrinks Phases 6 and 7 from "port a subsystem" to
"fix four specific things". The section below is kept as written, because the
argument for measuring before planning is what the outcome vindicates.

One Flutter app that exercises `dart:io` end to end and reports over the log
channel the dev server already has:

- `File` read and write, under both `app0:` (read-only) and `ux0:data/`
- `Directory` create, list, recurse, delete
- `Socket` connect to a LAN host
- `HttpClient` over plain HTTP
- `HttpClient` over HTTPS — the one most likely to fail
- `Platform.operatingSystem`, `Platform.numberOfProcessors`, environment
- `Process.start`, to confirm it refuses cleanly rather than crashing

**Cost: one app build, no engine rebuild.** Roughly the 12-second tier plus a
deploy.

The output is a table of what actually works, and it reorders every phase below
it. Doing this as one app rather than three investigations is most of the
saving — the failures will be correlated, and a single log tells you that.

Its second job is to become the **conformance app**: the same harness grows a
section per capability as each lands, so there is always one artifact that says
what this port can currently do.

## Phase 6 — Filesystem

The top plugin blocker by measurement:
[the survey](../tools/plugin-survey/) puts `path_provider` at 38% of real apps
and `shared_preferences` at 50% cumulative, and both are filesystem.

- Fix whatever Phase 5 finds in `File` / `Directory`
- Settle the path model: `app0:` is the read-only install directory, and
  per-app writable data belongs in `ux0:data/<titleid>/`. Nothing creates that
  directory today.
- `path_provider_vita` — a non-endorsed implementation per
  [ADR-0009](adr/0009-plugins-via-non-endorsed-vita-implementations.md).
  `getApplicationDocumentsDirectory`, `getTemporaryDirectory`,
  `getApplicationSupportDirectory`. Shallow: they are string constants and a
  `mkdir`.
- `shared_preferences_vita` — a JSON file in that directory. Shallow for the
  same reason.

**Watch for:** newlib's `stat` on `app0:` paths, whether `Directory.list` works
given `sceIoDopen` semantics, and case sensitivity. The engine needed
[a whole dirfd shim](../patches/) to read assets; `dart:io` may need its own.

## Phase 7 — Networking

- Fix whatever Phase 5 finds in `Socket` and `HttpClient`
- **Resolve the TLS ambiguity.** `secure_socket_filter.o` and
  `secure_socket_unsupported.o` are both in the shipped archive, which means
  the link order decides whether HTTPS works. That is not a decision anyone
  made. Pick one deliberately and stop archiving the other.
- **Root certificates.** Dart's `SecurityContext` gets trust roots from the
  filesystem on Linux — `/etc/ssl/certs`, which does not exist here. Even with
  BoringSSL linked, HTTPS fails at verification until a CA bundle ships with
  the app and is loaded explicitly. This is a real gap and is probably the
  actual reason HTTPS will not work on the first try.
- **The network may be off.** `sceNetCtl` reports whether wifi is up, and on a
  handheld it frequently is not. Apps assume connectivity in a way phones let
  them get away with.
- `connectivity_plus_vita`, if the survey still justifies it afterwards.

## Phase 8 — Text input — **channel done, dialog blocked on GXM**

Any app with a `TextField` is unusable without it, which is why it sits above
controls.

**Done and measured on hardware.** A platform task runner, which nothing had
identified as necessary and which blocks *every* channel: `platform_message_callback`
is dispatched through it, so with no runner the engine queued messages nobody
drained and an `invokeMethod` simply timed out. Then `flutter/textinput` itself
— five inbound methods, two outbound, JSON both ways, UTF-16 conversion. A real
`TextField` in [apps/gallery](../apps/gallery), tapped with an injected touch,
drives the whole protocol and `sceImeDialogInit` returns success.

**Blocked.** The dialog never appears, and forcing it crashes the GPU driver:
`psp2core-*-GPUCRASH.psp2dmp`, in which **no thread has a crash stop reason** —
the driver rejected the work out of band rather than the CPU faulting.

Three attempts, three distinct failures, and the third is the real one:

| | |
|---|---|
| composite from the main loop | Flutter's next frame memcpy's over the keyboard — that copy covers the whole framebuffer |
| composite from `PresentSurface` | runs on the **raster thread**; GXM was initialised on the main thread |
| composite from the main loop, Flutter frame held | driver kills the process |

`sceGxmInitialize` is not the setup a common dialog needs. Every project that
composites one — SDL's `vitagxm` backend, vita2d, vitaGL — is a full GXM
renderer with a context, a colour surface mapped as GXM memory, a depth surface
and a sync object. We hand it a CDRAM block we `memcpy` into and a struct with
the right fields filled in, and the fields are not the requirement.

**Next:** a minimal GXM pipeline whose only job is to own the framebuffer, so
the shell has something it will composite into. ADR-0003's software raster stays
— this is about who owns the surface, not who draws the pixels.

The dialog is off unless `ux0:data/flutter-vita/ime.on` holds `1`, so a
`TextField` takes no input rather than taking the console down.

## Phase 9 — Audio

`sceAudioOut`, behind whatever the survey says apps actually use. Lower than it
looks: an app with no sound is still an app, whereas an app whose text fields do
not work is not.

## Phase 10 — Controls

[ADR-0010](adr/0010-input-layering-and-psvita-api.md), already designed.

Layer 1 in the embedder — D-pad to arrow keys, enter button to `gameButtonA`,
left stick to scroll — makes unmodified apps navigable and needs no package.
Layer 2 is the `psvita` package for raw buttons, sticks, rear touch and motion.

Deferred because touch already operates an app, and because layer 2 needs
`StandardMethodCodec` hand-encoded in C, which is the single largest piece of
embedder work outstanding.

## Fixed 2026-08-15: the non-deterministic crash

Every app on this port used to die after a while, at a position that correlated
with nothing measurable. It is why Phase 7 looked like a TLS bug for two days.

**It was the 33rd thread.** Our emulated-TLS replacement had a 32-entry table
that never released a slot, so the limit was threads *ever created* rather than
threads alive, and the 33rd got NULL handed to a caller that dereferences it.
Slots are now reclaimed from exited threads, the table is 128, and every NULL
path exits cleanly instead. The conformance app now runs the whole probe list in
one go — **42 pass, 1 fail** (`io/print` to stderr) — and was still alive at
260 s with a 250 MiB allocation storm behind it.

The story is worth reading for the method, not the bug:
[HANDOFF-nondeterministic-crash.md](HANDOFF-nondeterministic-crash.md).

**The dev loop no longer needs a person for it either.** Failures the program
can see coming exit cleanly into the loader — no error dialog, so nothing to
dismiss and no bubble to find. See
[ADR-0011](adr/0011-crash-recovery-without-taihen.md). A wild pointer still
costs two taps; nothing user-mode can catch a data abort.

## Ongoing, not phases

- **App corpus** — real apps from GitHub, checkouts gitignored, manifest
  committed. Becomes useful the moment Phase 6 lands, because that is when apps
  start getting far enough to fail interestingly.
- **Open-sourcing** — deferred, with
  [a cost recorded in the ADR index](adr/README.md).
- **Hardware-free verification** — still nothing. Every gate is "deploy and
  look."

## Related

- [roadmap.md](roadmap.md) — the original road to M3, now historical
- [phase-4-distribution.md](phase-4-distribution.md) — the toolchain around all of this
