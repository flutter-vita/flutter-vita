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
to a process that has had PAF in it.

## It is a thread, and it is PAF's own

The console writes `psp2core-*.psp2dmp` to `ux0:data` on every fault, including
the ones that end with the console going down, and two of these runs left one
behind. Both say the same thing:

    === THREADS ===
        FVTA00002
            Status: 0x8 (Waiting)
            PC: 0x81019708 (flutter_vita_promoter@1 + 0xb708)
        SceCommonDialogWorker
            Status: 0x8 (Waiting)
        ScePaf EntryCall
            Stop reason: 0x30004 (Data abort exception)
            Status: 0x1 (Running)
            PC: 0xe0203306 (ScePaf@1 + 0x6)

**PAF starts a thread of its own, `ScePaf EntryCall`, and that thread takes a
data abort six bytes into the PAF module.** Our thread is asleep in the hold
loop the whole time, which is why nothing in this spike's own code ever looked
guilty, and why three power cycles spent adding instrumentation to it found
nothing. The dumps were on the card the whole time.

Six bytes in is a thread parked at its entry point. A thread parked at its entry
point that faults on resume is the shape of **the module being unmapped
underneath it**, and every run that died unmapped PAF one way or another. Runs
5, 6 and 7 called `sceSysmoduleUnloadModuleInternalWithArg` explicitly, each
returning `0x00000000`. Run 4 did not, and handed off instead, which unmaps
everything by ending the process. No run in the set both kept PAF resident and
stayed alive, so the timing fits with no second cause needed.

That reframes the ten seconds. Not a watchdog, and not a delayed consequence of
the promoter: it is how long that thread takes to be scheduled again after the
ground has gone.

What is still unexplained is why VitaShell does the same unload and survives.

The difference worth suspecting is the environment PAF's thread finds when it
resumes: VitaShell is a vita2d app with a live GXM context, and this spike draws
with `debugScreen`, which writes the framebuffer directly and initialises no
display subsystem at all. Unverified, and each attempt costs a power cycle,
which is why this still stops here.

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

1. **Load PAF and never unload it**, holding for several minutes without
   exiting. First now rather than third: every run so far unmapped PAF and none
   survived, so the one cell of the table nothing has filled in is the one the
   dumps point at. If it lives, the rule is that PAF is loaded once and kept,
   and `promote` becomes usable as it stands.
2. Load and unload PAF with **no promoter at all**, to confirm the promoter has
   no part in the fault.
3. The same from a process with a real GXM context rather than `debugScreen` —
   the one difference from VitaShell that could explain why the same unload is
   safe there.

`tools/analyse-crash.sh` read those dumps, and reading the next one is one
command.

Then the packaging, which is untouched and is its own piece of work. VitaShell
extracts a vpk to a staging directory, builds `sce_sys/package/head.bin` from an
embedded template with three HMAC-SHA1 signatures, calls
`scePromoterUtilityPromotePkgWithRif(path, 1)` — **not** `PromotePkg`, which is
what `loader/src/loader_dev.c` calls — and deletes the staging directory
afterwards. Their implementation is GPLv3 and this repo is BSD-3-Clause, so it
cannot be copied; the format is published and a clean-room version is fine.

Whether `PromotePkg` accepts an extracted directory with no `head.bin` is
unanswered and is one call. If it does, none of the signing work is needed.
