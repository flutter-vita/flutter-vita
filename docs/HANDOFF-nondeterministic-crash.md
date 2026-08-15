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

### a. Resume from where it died

The app reads a "last completed step" file at startup and continues past it,
rather than starting over. **Each manual relaunch then advances the
investigation instead of repeating it.** Cheap, needs no Vita API, and works
even if crash handling proves impossible. The journal already writes every step
before running it, so the resume point is already on disk — it needs reading,
not adding.

### b. Return to the loader without a human

Investigate a user-mode fault handler that relaunches the loader before the
process dies, so the console comes back to a usable state on its own.
`sceAppMgrLaunchAppByUri` is how the loader launches apps and terminates
itself; the question is whether a handler can run late enough to call it.
Vita homebrew commonly installs handlers to write crash logs, so the mechanism
exists — the specific API has not been researched.

If (b) works the loop becomes fully autonomous. If it does not, (a) still turns
N crashes into N steps of progress instead of N restarts.

### c. Loader `rm`

Unrelated to crashes but requested and still missing: the loader has `ls`, `get`
and `put` but no delete, so crash dumps accumulate. `ux0:data` currently holds
52 `psp2core` files from every homebrew title on the console, and one of them
misdirected an investigation in this session for half an hour.

## 5. What is done and not at risk

- **Phase 5**, the [capability audit](phase-5-capability-audit.md) — 28/31, and
  the harness is the reason anything here is known.
- **Phase 6** — `numberOfProcessors` (−1 → 3), `Directory.systemTemp`
  (`/tmp` → `ux0:data/<TITLEID>/tmp`), `createTempSync`, plus
  `path_provider_vita` and `shared_preferences_vita`. 30 probes pass, 0 fail.
- **Phase 7's four fixes** are real bugs fixed, even though none was the crash.
  TLS cannot work without them, and it may simply work once the app survives.
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
