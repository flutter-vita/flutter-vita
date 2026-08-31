# ScePromoterUtil: it loads, and then the console dies ten seconds later

Two results, and the second is why this is parked rather than finished.

## 1. The promoter is not refused. It never was.

`sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL)` returns
`SCE_KERNEL_ERROR_MODULEMGR_NO_LIB` (`0x8002D003`). That has been measured
correctly and repeatedly since August — under UNSAFE, in both spellings, from
the 91 KB C loader as well as the 14 MB Flutter one — and read as "this console
will not let us have the promoter". Three ADRs are built on it.

`NO_LIB` means a **library could not be linked**. The promoter imports from PAF.
PAF was not resident in our process. Load PAF first and the promoter loads:

    A IsLoadedInternal      0x805A1001  UNLOADED   (so the id was always fine)
    B LoadModuleInternal    0x8002D003  NO_LIB
    C WithArg, NULL option  0x80022005  INVALID_MEMORY_ACCESS
    D WithArg, real option  0x8002D003  NO_LIB
    E after DestroyOtherApp 0x8002D003  NO_LIB
    G JPEG_ARM              0x00000000  ok
    G INI_FILE_PROCESSOR    0x8002D003  NO_LIB
    G DBUTIL               0x8002D003  NO_LIB
    H loadScePaf            0x00000000  ok
    H PROMOTER after PAF    0x00000000  ok
      scePromoterUtilityInit  0x00000000  ok
      scePromoterUtilityExit  0x00000000  ok

`JPEG_ARM` loading is the line that mattered. It ruled out "this process may not
load internal sysmodules at all" and left a per-module dependency as the only
story that fitted.

No taiHEN and no kernel module anywhere on that path.

What found it was not another measurement of our own code. It was reading
VitaShell's `package_installer.c`, which does one thing first that we never did:

    res = loadScePaf();
    if (res < 0) return res;
    res = sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);

PAF's argument block is not optional — the plain
`sceSysmoduleLoadModuleInternal(PAF)` faults the process, twice on the way here.
And `buf[0]` is a **size**, not flags, which is why zeroing a `SceSysmoduleOpt`
and filling in only `result` was never the same call the loader thought it was
making.

## 2. Ten seconds after touching PAF, the console goes down

Seven runs. Every one that loaded PAF took the console down, and the shape did
not move:

| run | after the promoter work | outcome |
|-----|-------------------------|---------|
| 4 | handoff, PAF left loaded | reboot |
| 5 | handoff, both modules unloaded (`0x00000000` each) | reboot |
| 6 | hold forever, never exit | went down |
| 7 | hold, auto-suspend and OLED-off inhibited, log flushed per beat | went down |

Run 7 is the one with a timeline, because runs 4–6 closed the log before the
part worth watching. It reached `still here, 0 s` and never wrote `10 s`.

So: **not the exit path** — it dies while holding. **Not the unload** — it dies
either way. **Not auto-suspend** — the timers were held off. **Not immediate** —
the whole promoter sequence completes, logs `done`, and starts holding first.

A delay of about ten seconds with nothing running in the foreground points at a
thread rather than a call: something PAF started, or something the system does
to a process that has had PAF in it. Unverified.

Worth noting what is *different* from VitaShell here, since that is where the
first answer came from and it may hold the second: VitaShell is a vita2d app
with a real graphics context, and this spike draws with `debugScreen`, which
writes the framebuffer directly. PAF initialises the display subsystem. Those
two may not coexist. Also unverified — and each attempt costs a power cycle,
which is why this stops here.

## Does any of this block the port?

No. There are two routes to installing something, and only the second needs the
promoter:

| goal | route | status |
|------|-------|--------|
| Update an **existing** title | plain file copy from any running app | **works.** `put 5 ux0:app/FVTA00004/probe.txt` from FVTA00002 returns OK, against EACCES when the loader tries its own directory. `ux0:app/<self>` is the read-only `app0:` mount; every other title is ordinary storage |
| Register a **fresh** title id | promoter | loads, then the console dies |

The loader update loop needs only the first. Fresh title ids — a loader at
FVTA00001, one id per corpus app (ADR-0012), the background supervisor
(ADR-0011) — need the second, and can be bought instead with one manual
VitaShell install per id.

## If someone picks this up

The remaining unknown is the ten seconds, not the promoter. Cheapest next
measurements, in order:

1. Load and unload PAF and **nothing else** — no promoter at all. If it still
   dies, the promoter is entirely innocent and this is a PAF question.
2. The same without `debugScreen` — no framebuffer writes after PAF loads.
3. Load PAF and never unload it, holding for a minute, to see whether the unload
   is what schedules the fault.

Then the packaging, which is untouched and is its own piece of work. VitaShell
extracts a vpk to a staging directory, builds `sce_sys/package/head.bin` from an
embedded template with three HMAC-SHA1 signatures, calls
`scePromoterUtilityPromotePkgWithRif(path, 1)` — **not** `PromotePkg`, which is
what `loader/src/loader_dev.c` calls — and deletes the staging directory
afterwards. Their implementation is GPLv3 and this repo is BSD-3-Clause, so it
cannot be copied; the format is published and a clean-room version is fine.

Whether `PromotePkg` accepts an extracted directory with no `head.bin` is
unanswered and is one call. If it does, none of the signing work is needed.
