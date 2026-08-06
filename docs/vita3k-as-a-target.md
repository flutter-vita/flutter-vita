# Vita3K as a development target: what it can and cannot tell you

**Short answer: yes, use it — but not for anything this project is hard because of.**

The plan already says "Vita3K results are advisory only; real hardware is the
source of truth." That is right, but too vague to act on. This document makes it
specific, because the failure mode is not "Vita3K reports an error" — it is
**Vita3K reports success for things that fail on hardware.**

---

## The governing principle

> Vita3K is good at answering *"does my code run?"*
> It is bad at answering *"does my code obey the platform's limits?"*

Every constraint that makes this project difficult — the memory budget, the
16 MiB VM-block cap, W^X, CPU throughput, GXM format and alignment rules — is
precisely a constraint Vita3K relaxes or ignores. That is a reasonable design
choice for an emulator whose goal is running commercial games. It makes Vita3K
systematically optimistic for a porting project.

---

## The specific trap: silent success

Vita3K's `UNIMPLEMENTED()` macro is:

```c
#define UNIMPLEMENTED()                                                \
    ([&]() {                                                           \
        LOG_WARN_ONCE("Unimplemented {} import called.", export_name); \
        return 0;                                                      \
    })()
```

It logs **once**, at warn level, and **returns 0 — success**. `STUBBED()` does
the same. An unimplemented API is therefore indistinguishable from a working one
unless you are reading the log.

### This directly defeats the [ADR-0005](adr/0005-aot-snapshot-delivery.md) spike

The VM-domain spike is the highest-value experiment in Phase 0.5. Here is how
Vita3K handles the four calls it depends on (from `vita3k/modules/SceSysmem/SceSysmem.cpp`):

| Call | Vita3K status |
|---|---|
| `sceKernelAllocMemBlockForVM` | **Real implementation** — but validates only `size >= 0x1000` and 4 KiB alignment |
| `sceKernelSyncVMDomain` | **Real implementation** — validates block ID and range |
| `sceKernelOpenVMDomain` | **`UNIMPLEMENTED()`** → returns 0 |
| `sceKernelCloseVMDomain` | **`UNIMPLEMENTED()`** → returns 0 |

Combine that with the fact that Vita3K's CPU backend executes guest memory
regardless of any notional page protection — W^X has no meaning inside an
emulator that isn't modelling the MMU's execute bit — and you get:

- `OpenVMDomain` returns success without doing anything
- the code you wrote into the block executes **whether or not you called it**
- **`AllocMemBlockForVM` does not enforce the 16 MiB cap**, so a 64 MiB
  allocation that hardware would refuse succeeds cleanly

**The spike would pass perfectly on Vita3K and tell you nothing.** Worse, it
would tell you the *wrong* thing about the one decision that shapes Phases 3
and 4. This spike must run on hardware. There is no substitute.

---

## Turn the weakness into a tool

Because `UNIMPLEMENTED()` logs before returning, Vita3K is an excellent **API
coverage scanner**. Run the embedder under Vita3K at warn level and every
`Unimplemented <name> import called.` line is a `sce*` call you depend on that
the emulator does not model — which is a strong hint about which calls are
obscure enough to be worth verifying carefully on hardware.

**Working agreement:** treat any new `Unimplemented ... import called` line in a
Vita3K run as a finding to be recorded, not log noise. Grep for it in CI.

---

## Use it for / don't use it for

### Use Vita3K for

- **Toolchain validation.** Does the `.vpk` build, load, and start? Do symbols
  resolve? Is the SFO and LiveArea metadata well-formed? This is a fast loop and
  Vita3K is honest about it.
- **Dart and Flutter logic.** Once the embedder works, app-level iteration —
  widget code, channel wiring, asset loading — is legitimate here.
- **Crash triage.** A host debugger beats `psp2shell` for anything that isn't
  timing- or protection-sensitive.
- **Regression smoke tests in CI**, with the caveat below.

### Do not use Vita3K for

- **Any performance number.** The host CPU is orders of magnitude faster than a
  333–500 MHz Cortex-A9. The [ADR-0006](adr/0006-performance-bar-set-from-measurement.md)
  raster measurement is meaningless here. Never quote a Vita3K fps figure.
- **The VM domain spike.** See above.
- **Memory budget behaviour.** Vita3K does not enforce Sony's per-process
  budgets, so "it fits" means nothing.
- **Threading, timing, and race conditions.** Scheduling differs from the real
  kernel; a race that never fires under Vita3K may fire immediately on hardware,
  and Dart's GC and the engine's task runners are exactly the kind of code where
  this bites.
- **GXM specifics.** Vita3K translates GXM to host GL/Vulkan, so framebuffer
  format, stride, and alignment quirks will not reproduce — including the
  possible zero-copy `memcpy` blit noted in [VERSIONS.md](../VERSIONS.md).

---

## Consequence for the plan

Phase 0 lists Vita3K as "a secondary fast-iteration target". Keep that, but
Phase 0's exit criterion — *one-command build → deploy → log-capture loop* —
**must be satisfied against real hardware**, not Vita3K. If the hardware loop
slips, every subsequent phase is running on optimistic data.

This also raises the stakes on the iteration-cost problem: Vita3K is the obvious
answer to "the hardware loop is slow", and it is a partly false answer. That
tension is worth its own discussion.

## Sources

- `vita3k/modules/SceSysmem/SceSysmem.cpp` — https://github.com/Vita3K/Vita3K
- `vita3k/module/include/module/module.h` — `UNIMPLEMENTED` / `STUBBED` definitions
