# Vita NTP

Sets the console clock from a network time server, because this Vita's own
"Set Automatically" no longer works — the Set Now button does nothing — and
**there is no NTP homebrew or plugin for the Vita at all** (searched GameBrew,
VitaDB, the plugins wiki and GitHub; Wii and Switch have one, Vita does not).

## Why a kernel module is unavoidable

| | |
|---|---|
| `psp2/rtc.h` | `sceRtcGetCurrentTick` — read only |
| `psp2kern/kernel/rtc.h` | `ksceRtcSetCurrentTick` — **kernel only** |

No user-mode API sets the clock. That is presumably why nobody has built this.

## Why it is still low risk

The module is **not** installed into `ur0:tai/config.txt` and does not load at
boot. It lives in `ux0:data/flutter-vita/`, and the app loads it on demand with
`taiLoadStartKernelModuleForUser`, makes one call, and unloads it.

- Nothing in the system partition is modified
- A fault costs a power cycle, not a bootloop
- Removing it entirely means deleting one file

This matters on this console specifically: two earlier attempts to add a plugin
the ordinary way (`config.txt`, load at boot) stopped it booting.

## Layout

```
kernel/   the skprx: one function, ksceRtcSetCurrentTick, plus a sanity range
src/      the app: DNS, SNTP over UDP 123, load → set → unload
```

`kernel/` is a **separate CMake project on purpose**. `vita_create_self`'s
`CONFIG` leaks to later targets in the same `CMakeLists.txt`, so a kernel module
and a user app in one file makes the app build against the module's export yml
and fail with *"Could not find symbol 'module_start'"*.

```bash
cmake -S kernel -B kernel/build && cmake --build kernel/build
cmake -S . -B build && cmake --build build
```

## Safety in the module

`vitaNtpKernelSetUnixTime` rejects anything outside 2023-11 … 2036-07. A
corrupted or spoofed packet should not be able to set the clock to 1970 or to
the next century, and the check is in kernel space where it cannot be bypassed
by the caller.

The app tries `pool.ntp.org`, then `time.google.com`, then
`time.cloudflare.com`, with a bounded receive timeout so a silent server cannot
hang it.
