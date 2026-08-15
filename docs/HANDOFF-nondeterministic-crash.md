# Handoff — the non-deterministic crash

**Written 2026-08-15.** Read this before touching the crash. It is one page of
what is known, one of what to do next, and one of how to stop the dev loop
costing a human interaction per attempt.

---

## 1. What the crash is

Any app running on this port dies after a while. Not at a fixed point.

| run | probes run | frames rendered | rebuilds | died at |
|---|---|---|---|---|
| conf10 | 32 | ~32 | ~32 | `plugin/path_provider support` |
| conf11 | 33 | 83 | ~33 | `plugin/prefs write+read` |
| conf13 | **0** | **600** | 56 | rebuild storm, iteration 56 |

**Nothing correlates.** Not probes, frames, rebuilds, timers, memory, or wall
time. Five runs, five positions.

### Eliminated, each by measurement on hardware

| | how |
|---|---|
| TLS / crypto | different probes at the same position die the same way |
| Frames, present path | 600 frames survived in the run that died earliest otherwise |
| Memory | 88–91 MB free at every death; 2 MB consumed per whole run |
| Timers | 400 sequential and 192 concurrent both pass |
| Text / glyph growth | rebuild storm dies with no text ever changing |
| Descriptors | `kMaxPollDescriptors` is 255; writes-per-probe varied without moving the wall |
| Entropy, cert verification, stack, ARM assembly | [Phase 7](phase-7-tls.md) |

### It cannot be Dart

Dart is memory-safe. A null is `NoSuchMethodError`, a bad index is `RangeError`
— exceptions, which the probe journal would have recorded as a clean `FAIL`.
A data abort cannot come from Dart semantics. **The fault is native**, and on
this port "native" is nearly all code we wrote or ported:

- **AOT-generated machine code** — `gen_snapshot` targeting armv7 hard-float, a
  configuration nobody had exercised before this project
- **Dart VM runtime** — GC, safepoints, TLS, on our OS layer
- **`dart:io` native layer** — patch 0010
- **Engine** — Skia, libtxt, the embedder

## 2. The leading hypothesis, and why it is better than the last four

**Heap corruption, most likely via the GC or the machinery it depends on.**

It is the only hypothesis so far that *predicts* the non-determinism rather
than explaining it after the fact. A GC runs when allocation crosses a
threshold, moves objects, and suspends threads at safepoints — so a bug there
fires at a point determined by **allocation history**, not by what the code
happens to be doing. That is exactly the observed pattern. It also explains the
truncated core dumps: a corrupted heap breaks the dump writer too.

Three suspects, in order of how much they were flagged as risky when written:

1. **`virtual_memory_vita.cc`** — the Phase 1 work plan named this as *the* hard
   file, where residual risk concentrated. Untested since.
2. **Patch 0009, the emutls replacement.** Its own note: without it *"every
   `thread_local` in the runtime is one shared global."* The VM's per-thread
   state — including safepoint bookkeeping — lives there. A subtle error is
   invisible until threads and GC interact.
3. **Safepoints and thread suspension**, which depend on both of the above.

### The test that would confirm or kill it in one run

Allocate garbage hard from Dart to force many GCs in seconds. **If the app dies
in two seconds instead of twenty, the GC is implicated; if allocation pressure
changes nothing, it is ruled out.** One app-only change, no engine rebuild,
about twenty seconds to build.

Note the shape: it makes the failure happen *sooner*, rather than measuring
where it happens. That is the method correction from this session.

## 3. Determining the layer

Bisect by removing, not by counting. In rough order of cost:

1. **Pure Dart, no Flutter.** An app that runs the probe loop and journals, with
   no `runApp`, no widgets, no rendering. Dies → the VM or `dart:io`. Survives →
   the engine. This single result halves the search space and the
   [M1 spike](../spikes/m1-snapshot/) already proves pure-Dart AOT runs here.
2. **Flutter with a trivial tree.** `runApp(Container())` plus the journal loop.
   Isolates the widget/render layers from the VM.
3. **Engine with no Dart.** The embedder rendering a fixed buffer in a loop, no
   isolate. Isolates Skia and the present path.

Each is an app-only build. None needs the engine rebuilt.

## 4. The dev loop is the real bottleneck — fix it first

**Every crash currently costs a human walking to the console and opening the
loader.** That is the constraint on iteration speed, not build time (builds are
12–20 s; an engine object is 1 s).

Two fixes, both worth doing, neither attempted yet:

### a. Resume from where it died — **DONE 2026-08-15**

`ux0:data/flutter-vita/resume.txt` holds one integer, written before each probe
runs. On startup the app skips past it. The journal appends per run instead of
truncating, so earlier attempts survive as evidence rather than being erased by
the relaunch that follows them.

It works, and it immediately paid for itself:

```
=== 11:35:56 (fresh run) ===          probes  0–16
=== 11:52:15 (resuming at probe 17) === probes 17–40
=== 11:53:28 (resuming at probe 41) === probes 41–43   == run complete ==
```

**Three launches, the whole probe list, one failure.** No run had ever passed
about 33 before. It is also what showed that [TLS works](phase-7-tls.md) —
those probes sit at the end of the list and nothing had ever reached them.

Note the resume point is deliberately the index *after* the probe that died, so
a crashing probe is stepped over rather than re-entered. The cost is that it
goes unmeasured: `tls/handshake, no verify` has no result for that reason.

To force a run from the top: `./spikes/m1-vpk/dev.sh rm ux0:data/flutter-vita/resume.txt`.

### b. Return to the loader without a human — API fixed, shell blocks it

There was already a supervisor for this — `templates/vita-app/supervisor.c`,
built as `eboot2.bin` and started as a background application, a separate
process that outlives the foreground app dying. It had never run, and
`loader.log` had been saying so on every boot since 2026-08-10:

```
supervisor start: sysmodule=0x00000000 start=0x80106501
```

Two real bugs, both now fixed:

- **VitaSDK's `psp2/bgapputil.h` is wrong on both counts.** It says the mode
  argument "must be 1" and defines `SCE_BGAPP_UTIL_ERROR_INVALID_ARG` as
  `0x80106502`. Sony's own header says **mode 0** and `0x80106501` — which is
  precisely the code we were getting. The undocumented value was read as a
  permission problem when it was an invalid argument. Confirmed against Sony's
  `notification-util` sample and GrapheneCt's BGFTP, which both pass 0.
  (`supervisor.c` used to claim BGFTP was not a precedent because it had no
  `eboot2.bin`. It has one. That note was wrong.)
- **`sce_sys/param2.sfo` was missing** — a second manifest describing
  `eboot2.bin`, `CATEGORY=gdd`, `ATTRIBUTE=0x1000`. Without it the call cannot
  succeed at any mode.

With both, `sceBgAppUtilStartBgApp(0)` returns `0x00000000`. The supervisor
still does not run, and the remaining obstacle is specific: **the shell resolves
the background app through `param2.sfo`'s `TITLE_ID`, against its
installed-titles database.**

| `TITLE_ID` | result |
|---|---|
| `FVSV00003` — distinct, never installed | call returns 0; shell puts "could not find app" on the panel; `eboot2.bin` never runs |
| `FVTA00002` — the app's own | the app stops launching at all |

Nothing we control can add a title to that database: `ScePromoterUtil` refuses
to load with `MODULEMGR_NO_LIB` (`0x8002D003`), the same refusal
[the tooling notes](../spikes/vita-tooling/README.md) recorded — and *not*
because of the safe-self mistake, since this was measured under UNSAFE.

Two untried routes, in order of cost:

1. **Name the loader.** `FVTA00003` is registered. Whether the shell then takes
   `eboot2.bin` from the caller's directory or the named title's is unknown and
   the experiment answers it. If it is the named title's, the app can write
   `ux0:app/FVTA00003/eboot2.bin` from `dart:io` — only an app's *own*
   directory is read-only to it (see below).
2. **Install once through VitaShell.** A properly promoted vpk carrying
   `eboot2.bin` and `param2.sfo` registers everything the shell needs. One
   manual install instead of a tap per crash.

### c. Loader `rm` — **DONE**

`rm <path>`, plus `./spikes/m1-vpk/dev.sh rm <path>`. No glob and no recursion:
this deletes on a device with one homebrew slot and a lifeline app living in it.

The same round also hardened `put`, which accepted a size of zero and so
truncated its target and answered `OK` — a shell expansion that came out blank
destroyed `eboot2.bin` that way. And the liveness checks now retry: the loader's
listener is non-blocking, and a single `ping` reported "no loader" three times
against a loader that answered `ls` a second later.

### An app cannot write its own directory

`touch ux0:app/FVTA00003/x` returns `0x8001000D`, EACCES, from the loader
itself, while `ux0:app/FVTA00002` is freely writable by it. That settles a
question `spikes/vita-tooling/README.md` left open as *"untested under UNSAFE;
possibly also false."* It is true, and it is why the supervisor ships with the
app rather than the loader: the app slot is the only directory anything we
control can write, and the loader cannot update itself.

## 5. What is done and not at risk

- **Phase 5**, the [capability audit](phase-5-capability-audit.md) — 28/31, and
  the harness is the reason anything here is known.
- **Phase 6** — `numberOfProcessors` (−1 → 3), `Directory.systemTemp`
  (`/tmp` → `ux0:data/<TITLEID>/tmp`), `createTempSync`, plus
  `path_provider_vita` and `shared_preferences_vita`. 30 probes pass, 0 fail.
- **Phase 7** — TLS works. Verified handshake, `/CN=example.com`, `HTTPS 200`,
  measured once the resume file let the run reach those probes. The four fixes
  were right; the conclusion drawn around them was not.
- **The whole probe list passes** except `io/print` to stderr. 
  `tls/handshake, no verify` is the one probe with no result, skipped by the
  resume after the crash landed in it.
- **Tooling** — `tools/check-dart-trees.sh`, `cleandead` before archiving, the
  `.psp2dmp.tmp` fix in `dev.sh`, engine/SDK version refusal.

## 6. Method notes, because they cost most of two sessions

Four confident diagnoses were wrong: TLS, frames, timers, text. Each rested on
a correlation across runs that were not comparable, and each was reported before
anyone tried to break it. Every correction came from a decoupling experiment
costing about twenty seconds — moving the probes, adding an animation, counting
timers, freezing the text.

Three specific traps, all of which bit more than once:

- **Stale artifacts.** The archive shipped 123 orphaned objects; a stale
  `getentropy.o` caused a link error; a stale `eboot.bin` deployed silently
  after a failed build. Two of the three were silent. `cleandead` now runs
  automatically, but check the binary for the symbol an experiment was supposed
  to change before believing its result.
- **The Vita's clock runs about two hours behind the build machine.** Compare
  journal timestamps against *each other*, never against the host.
- **Vendored changes are not real until they are patch files.** `third_party/`
  is gitignored, so a working edit can commit as "nothing to commit".

The two instruments that actually worked, both one line: the probe journal
writing each step's name *before* running it, and the embedder's frame counter.
The crash-dump pipeline produced nothing usable in two days.
