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

## The loop, as built

**The confinement was self-inflicted.** `vita_create_self` builds a *safe* self
by default — it passes `-s` to `vita-make-fself` — and a safe self cannot see
`ux0:app` at all, whatever "Enable unsafe homebrew" is set to. Adding `UNSAFE`
to the loader's `vita_create_self` removed the flag, and with it every
restriction this document previously recorded as a platform rule.

So the loop is now two apps and one socket each:

| | Port | Role |
|---|---|---|
| M1 (`FVTA00002`) | 1339 | the app under test; hands off, serves its log |
| loader (`FVTA00003`) | 1341 | **UNSAFE self** — writes `ux0:app/FVTA00002/` and launches M1 |

```
M1 --handoff--> loader --stage, install, launch--> M1
```

`./dev.sh cycle` — **~5 seconds, no FTP, no taps.**

Both apps are UNSAFE selfs, so **each can install the other**: the loader writes
`ux0:app/FVTA00002/`, and M1's `put` writes `ux0:app/FVTA00003/`. Nothing
external is needed to update either one.

Staging and installing stay separate: the upload lands in `ux0:data` and only a
complete file is copied over `eboot.bin` via a `.tmp` and a rename, so a dropped
transfer cannot damage the installed app.

### What this corrected

Three earlier conclusions here were wrong, all downstream of one unchecked
assumption:

- *"Sandboxed homebrew cannot see `ux0:app` at all."* True only of **safe**
  selfs, which is what we were building without ever choosing to.
- *"BGFTP cannot be dropped; the boundary is app vs SceShell plugin."* No — the
  boundary was safe vs unsafe self. BGFTP was never special.
- *"An app cannot write its own `ux0:app` directory."* Untested under UNSAFE;
  possibly also false. It no longer matters, since the two-app design is needed
  for the launch anyway.

Routes explored and abandoned before finding it: `ux0:patch` (invisible to a
safe self, same as `ux0:app`), and `ScePromoterUtil` (its library is refused
with `MODULEMGR_NO_LIB`, and calling it without
`sceSysmoduleLoadModuleInternal` first crashes the process outright).

The lesson is narrow and worth keeping: **check your own build flags before
concluding the platform forbids something.** Four measurements were correct and
the conclusion drawn from them was still wrong, because the variable under test
was one we had set ourselves.

## Superseded: the FTP-based loop


Three parties, each doing the one thing it is permitted to do:

| | Port | Can |
|---|---|---|
| BGFTP | 1337 | write `ux0:app/` — it is a **SceShell plugin**, so it runs with shell permissions, and it stays reachable even while another app runs |
| M1 (`FVTA00002`) | 1339 | hand off, serve its log |
| loader (`FVTA00003`) | 1341 | **launch M1** — that is all, and it is enough |

```
M1 --handoff--> loader --(BGFTP writes eboot.bin)--> launch --> M1
```

`./dev.sh cycle` runs it: hand off so the directory unlocks, upload over BGFTP,
launch, print the log. **Verified end to end with no manual steps.**

`sceAppMgrLaunchAppByUri(0xFFFFF, "psgm:play?titleid=...")` works on this device.

### Exit immediately after launching, or the shell prompts

The first version lingered two seconds after issuing the launch, to log whether
it had taken effect. That diagnostic was buying a **"close the current
application?"** dialog every cycle: the shell asks precisely because the
outgoing app is still alive. Launchers that switch silently (HEXFlow, RetroFlow)
call `sceKernelExitProcess` straight after the launch, and so do both of ours
now.

It also broke a cycle outright — the prompt appeared, the app then exited out
from under it, and the launch was cancelled, leaving nothing running.

A full cycle takes **~10 seconds** including a 2.4 MB upload.

### The loader does not write anything

The first design had the loader install the binary itself. It cannot: it gets
the **same `0x80010002` ENOENT** on `ux0:app/FVTA00002/` that M1 gets on its own
directory. So the restriction is not "an app cannot see its own directory" — it
is that **sandboxed homebrew cannot see `ux0:app/` at all**. BGFTP is exempt
because it is a shell plugin, not an app.

That was an inference I got wrong and the `probe` command caught in one round
trip, before anything was built on top of it. The loader's `stage` and `install`
commands survive in the binary but always fail; only `ping`, `probe` and
`launch` do anything. Not worth a reinstall to remove.

**Two explanations were tested and both failed**, so BGFTP stays in the loop:

- *"unsafe homebrew" is off.* It was on the whole time.
- *"the probe ran on an L-boot, so no plugins were loaded."* Plausible — that
  boot really did skip plugins — but re-probing on a normal boot gives the same
  `0x80010002`.

The second test is sound because it measured both sides at once: port 1337 being
open proves plugins are loaded, since that FTP server *is* a plugin, and on that
same boot it wrote `ux0:app/FVTA00002/` while the loader could not see it.

So the boundary is **sandboxed app vs. SceShell plugin**, not a setting and not
a boot mode. BGFTP is not removable from the cycle without becoming a plugin
itself, and it costs nothing: it is always resident and has been the most
reliable component here.

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

## Screen power, and not burning the panel

Verified on hardware.

| | |
|---|---|
| **Suspend** | always blocked — `sceKernelPowerTick(DEFAULT)` every 200 ms. A suspended console takes the network, and the deploy loop, with it. |
| **Display** | panel stays powered; the **framebuffer is blanked to black** after 60 s idle. |
| **Any button** | redraws immediately. |
| **SELECT** | toggles stay-awake. |

**Do not use `scePowerRequestDisplayOff`.** It was tried and it works, which is
the problem: `scePowerRequestDisplayOn` had no effect afterwards, and the only
routes back were exiting the app or minimising it. On a single-console setup
that is an unacceptable way to lose the display.

Blanking reaches the same goal without the risk. On an OLED a black pixel draws
essentially no current, and what causes burn-in here is static *text* sitting on
screen for hours — which blanking removes. Recovery is guaranteed because the
app owns the framebuffer.

Note `nosleep.skprx`, loaded on this device, prevents *sleep* and has nothing to
do with the display timers.

## WiFi drops

**There is no user-mode API to join a given access point.** `sceNetCtl` exposes
`sceNetCtlInetGetState` and callbacks and nothing else; AP selection belongs to
the system. A kernel plugin could reach further, and plugins are off the table
here.

What the loader does instead is survive drops without help: it polls the net
state about once a second, tears the listener down when the link goes, and
rebuilds it when the system reconnects. A drop used to leave a dead socket that
needed a tap to clear; now it just goes quiet and comes back.

## Note on WiFi

There is **no auto-reconnect plugin** for the Vita; this was searched properly
and one does not exist. The relevant lever is a system setting:
**Settings → Power Save Settings → "Use Wi-Fi in Power Save Mode" → off**. The
name is backwards from its effect — it pins the radio in a permanent low-power
state, costing signal strength and range.

`NoPowerLimits` and `nosleep.skprx` are already loading and help, but neither
reconnects. If the setting is not enough, the fallback is to write a small
SceShell plugin that polls `sceNetCtlInetGetState()` and reconnects on drop.
