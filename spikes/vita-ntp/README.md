# Vita NTP — PARKED, unfinished

Sets the console clock from a network time server. **The networking works; the
kernel module will not load.** Parked 2026-08-08 after seven on-device attempts.

## Status

| Part | State |
|---|---|
| DNS + SNTP over UDP 123 | **works** — resolves `pool.ntp.org`, returns the correct Unix time |
| Server fallback | **works** — `pool.ntp.org` → `time.google.com` → `time.cloudflare.com` |
| Reading the clock | works |
| Loading the kernel module | **fails: `0x8002D013` `MODULEMGR_OLD_LIB`** |
| Setting the clock | never reached |

Last log from the device:

```
clock before: 2026-08-09 05:09:23      (~7 hours fast; true time was ~22:09 on the 8th)
trying pool.ntp.org
got unix time 1786219763                <- correct
loading kernel module...
load failed 0x8002D013
```

## Why a kernel module at all

| | |
|---|---|
| `psp2/rtc.h` | `sceRtcGetCurrentTick` — read only |
| `psp2kern/kernel/rtc.h` | `ksceRtcSetCurrentTick` — **kernel only** |

No user-mode API sets the clock, and there is no NTP homebrew or plugin for the
Vita at all (checked GameBrew, VitaDB, the plugins wiki, GitHub — Wii and Switch
have one, Vita does not). This console's own "Set Automatically" is enabled and
its Set Now button does nothing.

## What was ruled out, and how

Worth reading before resuming — four of these were dead ends that each cost a
launch.

- **`UNSAFE` on the kernel self** — *was* a real bug. It faulted taiHEN's
  loader outright. `UNSAFE` is for user selfs needing extended permissions; a
  kernel module is already kernel-side. Removing it turned a crash into a clean
  error. **Do not re-add it.**
- **Extra imports** — the module linked `taihenForKernel_stub` and
  `SceSysmemForDriver_stub` and used neither. Removing them changed nothing.
- **`SceRtcForDriver` being unavailable** — **disproved by bisect.** The module
  was rebuilt importing `SceThreadmgrForDriver` instead, a library this device
  demonstrably accepts (vitacompanion imports it and loads). Same `OLD_LIB`. So
  the RTC library is not the problem; the module format or its binding is.
- **Stale kernel state from the first crash** — a reboot did change behaviour
  once, but the error came back. Not the cause.
- **`_start` declaration** — ours was `void _start()` declared before
  `module_start`, aliasing a function of a different prototype. Now matches the
  known-good form (`int _start(SceSize, const void*)`, declared after). This
  removed a crash but not `OLD_LIB`.

## Where it stopped: the weak-stub hypothesis, untested

The app linked `libvitantp_kernel_stub.a` — the **non-weak** stub — which bakes
a hard import of `VitaNtpKernel` into the app binary. The loader tries to
resolve that when the *app* starts, long before the module is loaded on demand.
vitacompanion gets away with the strong stub only because its kernel module is
loaded at boot from `config.txt`; ours deliberately is not.

The build was switched to `libvitantp_kernel_stub_weak.a` and uploaded, **but
never launched.** That is the first thing to try on resuming.

## If that fails, do this instead of guessing again

Compare our `.skprx` against a known-good kernel module for this exact
firmware, offline, with no launches needed:

```
spikes/vita-tooling/backup/vitacompanion_kernel.skprx.stock
```

Diff the SCE/self header, module attributes, SDK version field and the export
library descriptor. Five of the seven attempts here were flag permutations; the
one that actually narrowed things was the bisect. Prefer that style.

## Layout

```
kernel/   the skprx: one function, ksceRtcSetCurrentTick, plus a range check
src/      the app: DNS, SNTP, load → set → unload
```

`kernel/` is a **separate CMake project on purpose**: `vita_create_self`'s
`CONFIG` leaks to later targets in the same `CMakeLists.txt`, so a kernel module
and a user app in one file makes the app build against the module's export yml
and fail with *"Could not find symbol 'module_start'"*.

```bash
cmake -S kernel -B kernel/build && cmake --build kernel/build
cmake -S . -B build && cmake --build build
```

## Risk notes, still true

The module is **not** in `ur0:tai/config.txt` and does not load at boot. It
lives in `ux0:data/flutter-vita/vitantp_kernel.skprx`, loaded on demand with
`taiLoadStartKernelModuleForUser`. Every failure here cost a power cycle and
nothing more. Deleting that one file removes it completely.

The kernel side rejects timestamps outside 2023-11 … 2036-07, in kernel space,
so a corrupted or spoofed NTP reply cannot set the clock to 1970.
