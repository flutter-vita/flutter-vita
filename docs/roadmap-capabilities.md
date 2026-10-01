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
| Emoji, font fallback | **app must bundle it** | `app0:/fonts` holds one file (Roboto, 896 codepoints) and `SkFontMgr_Custom` has no character fallback, so emoji are tofu unless the app bundles a font *and names it* — see below. Colour emoji do render: CBDT decodes, verified in keklist 2026-08-28 |
| `dart:io` File / Directory | **works** | [audited on hardware](phase-5-capability-audit.md) — read, stat, mkdir, write, append, list, rename, delete |
| `dart:io` Socket / HttpClient | **works** | audited — DNS, TCP, and `HTTP 200` from the open internet |
| TLS / HTTPS | **works** | [Phase 7](phase-7-tls.md) — real handshake, verified chain, `HTTPS 200` on hardware |
| `Directory.systemTemp` | **works** | Phase 6 — `ux0:data/<TITLEID>/tmp`, created on first use |
| `Platform.numberOfProcessors` | **works** | Phase 6 — 3, from the thread affinity mask |
| Dart `print` | **works** | goes through the engine log, not `dart:io` |
| Dart stdout / stderr | **partly** | construction works — Vita reports `kPipe`, since `fstat` on fds 0/1/2 fails — but the write itself still fails: `writeFrom failed (OS Error: Bad file number, errno = 9)`, surfacing asynchronously as an unhandled exception rather than at the call. Needs fd 1/2 routed to the log |
| `Process` | **refused, correctly** | `process_vita.cc` — no fork, no exec, documented as an implementation not a placeholder |
| Text input / IME | **works** | Phase 8 — libime's inline keyboard over `flutter/textinput`, on both backends, with `physical_view_inset_bottom` reported so layouts move. Typed text, caret and composing range arrive back in the framework. Single line and obscured; multiline degrades to single-line, this console refuses it |
| Audio | **not started** | `sceAudioOut` exists |
| Gamepad, sticks, rear touch | **designed, not built** | [ADR-0010](adr/0010-input-layering-and-psvita-api.md) |
| **Bluetooth** | **blocked** | see below |
| Motion, camera, mic, GPS | **not started** | headers exist |

### Fonts: one family, and no automatic fallback

Two facts that compound, found on 2026-08-28 when every emoji in keklist came
out as `.notdef`:

**The system font pool is one file.** `package-engine.sh` ships
`Roboto-Regular.ttf` into `app0:/fonts` and nothing else. It carries 896
codepoints, tops out at U+FFFD, and has no codepoint at or above U+1F000 — good
for Latin, Greek and Cyrillic, and empty of emoji, CJK and everything else.

**There is no per-character fallback to rescue it.**
`SkFontMgr_Custom::onMatchFamilyStyleCharacter` returns `nullptr`, and that is
the hook Skia calls when the current family has no glyph for a codepoint. On
Android or a desktop the platform font manager answers it and the user never
learns the primary font was incomplete. Here nothing answers, so the missing
glyph is final.

The consequence is worth stating plainly, because it looks like an app bug:
**dropping more fonts into `app0:/fonts` does not fix missing glyphs.** It makes
them available *by name*, which is a different thing. An application that wants
a codepoint Roboto lacks must bundle a font that has it and name that family —
`fontFamilyFallback` in `ThemeData`, or `fontFamily` on the specific style.

keklist was the worked example: `NotoColorEmoji.ttf` (4.7 MB, already in the
engine checkout beside Roboto) declared in `pubspec.yaml` and named in both
themes, which takes its `.vpk` from 18 MB to 22 MB. **It is not in
[flutter-vita/keklist_flutter](https://github.com/flutter-vita/keklist_flutter)**:
when the app moved from a patch series to a fork on 2026-09-23 that patch no
longer applied, and the checkout did not have it either. The measurement below
stands; the app change has to be made again to see it. Colour survives the trip — the font is
CBDT/CBLC, PNG bitmaps with no outlines, and the engine's FreeType is built with
`FT_CONFIG_OPTION_USE_PNG`, `TT_CONFIG_OPTION_EMBEDDED_BITMAPS` and
`TT_CONFIG_OPTION_COLOR_LAYERS`, so the emoji picker renders in full colour with
skin-tone variants on hardware.

Implementing `onMatchFamilyStyleCharacter` over the `app0:/fonts` directory
would make this automatic for every app, at the cost of shipping the fallback
fonts with the engine rather than the application. Not done, and the reason to
consider it is that every app hits this, not just the ones using emoji.

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
[a whole dirfd shim](https://github.com/flutter-vita/flutter/blob/vita-3.44.8/engine/src/flutter/fml/platform/vita/dir_fd_vita.cc) to read assets; `dart:io` may need its own.

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

## Phase 8 — Text input — **DONE 2026-08-16, rebuilt on libime 2026-08-28**

The system keyboard opens on a `TextField`, seeded with the field's current
value, and what you type arrives back in the framework. Single line, multiline
and obscured, measured on hardware in [samples/gallery](../samples/gallery) and in
[apps/keklist](../samples/test-apps/keklist).

It shipped on `sceImeDialog`, a modal common dialog, and moved to **libime**'s
inline keyboard on 2026-08-28 because the dialog cannot composite over vitaGL.
Everything below the next two headings describes the dialog era; the section
that replaces it is [The interaction model, and why](#the-interaction-model-and-why).

Two things had to exist first, and neither was on the plan.

**A platform task runner.** `platform_message_callback` is dispatched through
it, so with no runner the engine queues messages nobody drains and an
`invokeMethod` simply times out. This blocks *every* channel, not just text
input, and the embedder had it filed as an ADR-0004 performance concern.

**Three pieces of GXM setup, and no GXM rendering.** *(Written for the dialog,
still required by libime on the software path — that is the route
`sceCommonDialogUpdate` takes. Under GL the GLES2 layer does it instead, in
`engine/gles2/src/context.c`; vitaGL did until 2026-09-14.)* A common dialog is drawn by
the shell into the application's own frame, and it will only do that into a
surface GXM manages: the framebuffer mapped with `sceGxmMapMemory`, a
depth/stencil surface the descriptor requires even though nothing tests depth,
and a sync object. Skia still draws every pixel on the CPU — ADR-0003 is
unchanged. This is about who *owns* the surface, not who draws into it.

Six deploys, six specific error codes, each naming its own cause:

| | |
|---|---|
| *(silence)* | no platform task runner |
| `0x80102005` | `INVALID_TITLE` — required, and reads as optional |
| `0x80020436` | `GXM_IS_UNINITIALIZED` |
| `SCE_GXM_ERROR_DRIVER` | 256 KiB parameter buffer refused; the stock 16 MiB works |
| `GPUCRASH`, no faulting thread | no depth surface, no sync object |
| `0x80102004` | `INVALID_TEXT_BOX_MODE` — `WITH_CLEAR` is invalid on multiline |

### The interaction model, and why

Inline, on the bottom third of the panel, with the app still visible and still
running above it — the shape every mobile platform uses. The claim this
document made until 2026-08-28, that the modal dialog "is the platform rather
than a shortcut" because inline mode "wants a GXM render loop", was wrong:
`SceIme` composites *after* `sceDisplaySetFrameBuf`, owns no surface, and works
under vitaGL and the software rasteriser alike.

What that buys, and what it still costs:

- **The app keeps rendering and keeps its frame.** Flutter is told how much of
  the view the keyboard covers through `physical_view_inset_bottom`, taken from
  the `SceImeRect` in the `OPEN` and `CHANGE_SIZE` events, so `Scaffold` and
  `MediaQuery.viewInsets` scroll the focused field into view by themselves.
- **The caret survives.** `UPDATE_TEXT` carries `caretIndex`, `preeditIndex`
  and `preeditLength` in UTF-16 code units, which is what
  `TextInputClient.updateEditingState` wants, so selection and the composing
  range round-trip instead of collapsing to the end.
- **`TextInputType` and `TextInputAction` map onto the panel.** `emailAddress`,
  `url`, `number` and `phone` pick a `SCE_IME_TYPE_*`, `obscured` forces
  `BASIC_LATIN`, and `search`/`send`/`go` set the enter key's label.
- **This console refuses multiline.** `SCE_IME_OPTION_MULTILINE` returns
  `0x80100715` (`INVALID_OPTION`). `OpenIme` drops rejected options one at a
  time and retries, then records what it actually opened with, so a multiline
  field becomes single-line and its enter key fires `performAction` instead of
  inserting a newline. Without that record, enter in a `maxLines: null` field
  would do nothing at all.
- **The keyboard is invisible to `shot`.** `sceDisplayGetFrameBuf` returns the
  app's own frame, and the shell composites over it downstream. Confirming the
  keyboard is up means reading the `IME open rect …` log line.
- **Dismissal is distinguishable.** `PRESS_CLOSE` sends `onConnectionClosed`;
  a programmatic `TextInput.hide` does not.

### Still open

`flutter/keyboard` arrives in the **binary standard codec**, not JSON, so
ADR-0010's warning about hand-encoding `StandardMethodCodec` in C is deferred
rather than cancelled — the gamepad work will need it.

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
can see coming exit cleanly into the receiver — no error dialog, so nothing to
dismiss and no bubble to find. See
[ADR-0011](adr/0011-crash-recovery-without-taihen.md). A wild pointer still
costs two taps; nothing user-mode can catch a data abort.

## Ongoing, not phases

- **App test apps** — **active as of 2026-08-18.** Five real apps, one per axis,
  pinned in [samples/test-apps/manifest.txt](../samples/test-apps/manifest.txt). Phase 6 and
  Phase 8 both landing is what made it worth doing: apps now get far enough to
  fail interestingly. Run as boot-and-observe against one shared title id, with
  a plugin-free control that must pass; the output is a patch series and a
  ranked list of engine work items annotated with how many apps each unblocks.
  That ranking is what should reorder the phases below.
  [ADR-0012](adr/0012-test-apps-as-measurement-instrument.md),
  [ADR-0013](adr/0013-ffi-needs-static-linking.md).
- **Open-sourcing** — deferred, with
  [a cost recorded in the ADR index](adr/README.md).
- **Hardware-free verification** — still nothing. Every gate is "deploy and
  look."

## Related

- [roadmap.md](roadmap.md) — the original road to M3, now historical
- [phase-4-distribution.md](phase-4-distribution.md) — the toolchain around all of this
