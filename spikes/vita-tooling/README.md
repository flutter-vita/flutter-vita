# Vita device tooling

Device-side changes that support the build loop, kept here so they are
reversible and so the reasoning survives.

## vitacompanion, rebuilt on port 1340

`vitacompanion` gives remote `launch <titleid>`, button/touch injection,
`screen` (screenshot), `reboot` and `nosleep` — enough to run the whole
edit → deploy → launch → read-log loop without a human touching the device.

**Why it broke the first time.** Stock vitacompanion binds its FTP server to
**port 1337**, which is the port BGFTP uses, and it loads into SceShell at boot
— so it claims 1337 before BGFTP is ever launched. A user module stalling on a
bind inside the shell process gives exactly the reported symptom: a laggy
progress bar, then shutdown. It was a port collision, not a broken device.

Rebuilt from source with the FTP server moved:

```bash
cmake .. -DVITACOMPANION_FTP_PORT=1340 -DVITACOMPANION_CMD_PORT=1338
```

so 1337 stays BGFTP's. Verified in `CMakeCache.txt` and the compile flags — the
binaries are byte-identical in *size* to stock, because a port is a constant, so
size is not evidence the change took.

## Verdict: vitacompanion does not work on this device. Do not retry.

Attempt 2 was the clean experiment — the known-good config plus exactly two
lines, dead paths left dead, FTP moved to 1340. **Same failure: stuck on
loading, then shut off.**

So the port collision, while real and documented, was not the cause. That theory
is disproved, not merely unproven. Both modules stay on the device unreferenced;
neither belongs in `config.txt`.

No crash dump was produced, which fits a kernel-side load failure — coredumps
cover user-mode app crashes.

**C2-12828-1 is a red herring here.** It appeared only after booting with L
held. L skips every plugin including `nonpdrm.skprx`, and without nonpdrm,
NoNpDrm-installed titles fail with exactly that code. It is an artifact of the
recovery boot. A normal boot clears it.

**L-recovery is confirmed working on this device** — that much was worth
learning.

The remote-control problem is solved without taiHEN instead, but only partly --
see "What is actually possible" below.

## What is actually possible, measured

Two facts settle the design, and both were measured on the device rather than
assumed:

**An app cannot see its own directory.** From inside FVTA00002, creating a file
in `ux0:app/FVTA00002/` fails with `0x80010002` — **ENOENT, not EACCES**. The
path does not exist in that sandbox; the same content is mounted read-only as
`app0:`. So no amount of retiming or staging lets a running app replace its own
`eboot.bin`.

**While an app runs, its directory is locked against everyone.** BGFTP — a
separate background process that can normally write there — gets `550` on
`ux0:app/FVTA00002/` for as long as our app is up, and succeeds within seconds
of it exiting.

Together those kill self-update outright. The loop that remains:

| Step | How |
|---|---|
| pull logs | `./dev.sh log` — over the in-app server on 1339 |
| close the app | `./dev.sh exit` — releases the directory lock |
| upload a new build | BGFTP on 1337, which runs in the background permanently |
| **launch** | **tap the icon** — the one manual step |

`./dev.sh deploy` chains the middle three. Launching needs a SceShell plugin,
which is exactly what vitacompanion would have provided and cannot here.

A fully automatic loop would need a second small "loader" vpk: our app writes
the new binary to `ux0:data/` (writable), launches the loader by title id, and
exits; the loader — now that the lock is gone — copies it into place and
launches FVTA00002. That is a real option if one tap per iteration becomes the
bottleneck.

## Outcome of attempt 1: reverted

**The combined change stopped the Vita booting.** Config restored from
`backup/config.txt.orig` and verified byte-for-byte.

The mistake was not the port fix; it was bundling. Repointing the two
`psp2shell` paths was described below as fixing dead entries, which was wrong in
a way that mattered: those paths pointed at a directory that does not exist, so
`psp2shell_k.skprx` — a **kernel** module — had never loaded on this device.
Making the path valid did not fix anything, it switched on a kernel module and a
SceShell module for the first time, in the same boot that first enabled
vitacompanion. Three newly-active modules, two of them in kernel and shell.

**A dead path is a disabled plugin. Correcting the path is an activation, not a
cleanup.** Treat it with the same caution as installing something new.

Attempt 2 should add vitacompanion alone — two lines, nothing else, dead paths
left dead. If that boots, the port collision was the original cause. If it does
not, vitacompanion is incompatible with this setup and the fallback is a network
listener inside the app itself, which needs no taiHEN involvement at all.

## config.txt changes (attempt 1 — reverted)

Applied on top of the live config (backed up first, in `backup/`):

| Change | Reason |
|---|---|
| `+ ur0:tai/vitacompanion_kernel.skprx` under `*KERNEL` | user module imports its input API and does not load it itself |
| `+ ur0:tai/vitacompanion.suprx` under `*main` | the SceShell module |
| `ux0:tai/psp2shell_m.suprx` → `ur0:tai/…` | **`ux0:tai/` does not exist on this device**; the file is in `ur0:tai/` |
| `ux0:tai/psp2shell_k.skprx` → `ur0:tai/…` | same |
| `ur0:tai/yamt_helper.skprx` commented out | no such file anywhere on the device |

Those three were failing silently on every boot before this.

**Left alone deliberately:** `ur0:tai/henkaku.suprx` is listed under `*KERNEL`,
where a user module does not belong. It fails harmlessly, and HENkaku Settings
works because the same module is *also* listed under `*NPXS10015`/`*NPXS10016`,
which is the entry that actually matters. Not worth the risk of touching.

## Recovery

- **Hold L while powering on** — taiHEN skips loading every plugin, kernel and
  user ([taiHEN v0.10](https://github.com/yifanlu/taiHEN/releases/tag/v0.10)).
- Hold power during the enso logo for safe mode.
- `backup/config.txt.orig` and the stock `.suprx`/`.skprx` restore the previous
  state over FTP.

## Ports after this change

| Port | Service |
|---|---|
| 1337 | BGFTP (app — only while running) |
| 1338 | vitacompanion command server (always on) |
| 1340 | vitacompanion FTP (always on) |

If 1340 proves reliable, it removes the need to launch BGFTP by hand — which has
been the single biggest source of friction in the deploy loop.

## Note on WiFi

There is **no auto-reconnect plugin** for the Vita; this was searched properly
and one does not exist. The relevant lever is a system setting:
**Settings → Power Save Settings → "Use Wi-Fi in Power Save Mode" → off**. The
name is backwards from its effect — it pins the radio in a permanent low-power
state, costing signal strength and range.

`NoPowerLimits` and `nosleep.skprx` are already loading and help, but neither
reconnects. If the setting is not enough, the fallback is to write a small
SceShell plugin that polls `sceNetCtlInetGetState()` and reconnects on drop.
