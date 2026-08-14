# Roadmap after M3 — what a real app needs, in priority order

M3 proved a Flutter counter app runs on hardware. A counter app needs a screen
and a finger. A *real* app needs a filesystem, a network, a keyboard, and sound,
and this is the order those get built.

Controls are deliberately late. Touch is enough to operate an app, the design is
already settled in [ADR-0010](adr/0010-input-layering-and-psvita-api.md), and
nothing else is waiting on it.

## The status table, before any planning

The important column is the middle one, because **"built" and "works" are
different things here.** Most of `runtime/bin` was ported in Phase 2 to make the
engine *link*. Almost none of it has ever been executed.

| Capability | Status | Evidence |
|---|---|---|
| Front touch | **works** | M3, on hardware |
| Rendering, text, assets | **works** | M3 |
| `dart:io` File / Directory | **built, never run** | `file_linux.cc`, `directory_linux.cc` reused for vita in patch 0010 |
| `dart:io` Socket / HttpClient | **built, never run** | `eventhandler_vita.cc` on `sceNetEpoll*`, `socket_linux.cc` |
| TLS / HTTPS | **ambiguous** | 440 BoringSSL objects archived, but *both* `secure_socket_filter.o` and `secure_socket_unsupported.o` are in the archive |
| `Process` | **refused, correctly** | `process_vita.cc` — no fork, no exec, documented as an implementation not a placeholder |
| Text input / IME | **not started** | `sceIme` exists |
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

## Phase 5 — Capability audit

**First, because everything below is currently a guess.**

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

## Phase 8 — Text input

Not on the original list, and it belongs above controls: **any app with a
`TextField` is unusable without it**, and that is most apps that do anything.

`sceIme` provides the system IME dialog. The embedder implements
`flutter/textinput`, shows the dialog when a field gains focus, and feeds the
result back. The Vita has no on-screen keyboard of its own that a Flutter app
could use instead.

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
