# How the shell registers a title, measured

**Question:** can the receiver install an app from scratch the way VitaShell does,
without VitaShell?

**Answer: yes, and the mechanism is plain SQLite — but it was not exercised.**
The test apps needs one slot and we already own one, so the risk of writing the
shell's database on the only console here bought nothing today. Written down so
the next person does not re-derive it.

> **Superseded 2026-08-31.** `ScePromoterUtil` does work, and it is what
> `tools/install-vpk.sh` uses. The conclusion below is wrong in its cause, not
> its measurement: the promoter imports from PAF, and until PAF is resident its
> library cannot be linked, so the load is refused with `MODULEMGR_NO_LIB` —
> the error was naming its own missing dependency. Load PAF first with
> `sceSysmoduleLoadModuleInternalWithArg(SCE_SYSMODULE_INTERNAL_PAF, …)`, keep
> it resident, and the promote succeeds. See `experiments/promoter` and the
> **Promote** entry in [the glossary](../glossary.md). The SQLite route below
> was never needed and is kept as a record of what the shell's database holds.

## What is closed

`ScePromoterUtil` is not available to us, and this is now precise rather than
folkloric:

```
promote ux0:app/FVTA00006
ERR loadmodule 0x8002D003        # SCE_KERNEL_ERROR_MODULEMGR_NO_LIB
```

It fails at `sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL)`,
**before** `scePromoterUtilityInit` is reached. Two explanations were ruled out:

- **Not safe-vs-unsafe.** `vita_create_self(... UNSAFE)` landed 2026-08-08 in
  `f8a0937`; this measurement is from 2026-08-18 on that self.
- **Not our code.** VitaShell's `package_installer.c` makes the identical call.

## What is open

| Probe | Result |
|---|---|
| `mkdir ux0:app/FVTA00006` | `MADE (0x00000000)` |
| `touch ur0:shell/db/…` | `WRITABLE` |
| `get ur0:shell/db/app.db` | 1 MB SQLite 3 database, pulled intact |

`ur0:shell/db/app.db` is the installed-titles database. Registration is rows in
it, and both the file and `ux0:app` are writable from an unsafe self.

### The rows

**`tbl_appinfo`** — `(titleId TEXT, key INTEGER, val)`, 29 rows per title. Keys
are hashed strings; values are plain. For `FVTA00002`:

| key | val |
|---|---|
| 278217076, 904872283, 4045363504, 4183872847 | `'FVTA00002'` |
| 566916785 | `'gd'` — category |
| 572932585, 4007071428 | `'Flutter Vita M1'` — display name |
| 2593862978 | `'ux0:app/FVTA00002'` |
| 3022202214 | `'ux0:app/FVTA00002/eboot.bin'` |
| 1729228973 | `'ur0:appmeta/FVTA00002/pic0.png'` |
| 2630610402 | `'ur0:appmeta/FVTA00002/livearea/contents'` |
| 3168212510 | `'01.00'` — version |
| 414472871, 2722548093, 1281097414 | timestamps, `'%Y-%m-%d %H:%M:%S.%f'` |
| remainder | small integers: 32768, 4096, 16, 1, 0 |

**`tbl_appinfo_icon`** — one row, and this row *is* the LiveArea bubble:

```
(pageId=36, pos=8, iconPath='ur0:appmeta/FVTA00002/icon0.png',
 title='Flutter Vita M1', type=0, command=NULL, titleId='FVTA00002',
 icon0Type=5, parentalLockLv=0, status=0, reserved01..05=NULL)
```

`tbl_livearea`, `tbl_livearea_frame` and `tbl_uri` have **no rows** for our
titles, so they are not required.

### Two conveniences

`ur0:appmeta/FVTA00002/` is **empty** — the icon and pic paths above point at
files that do not exist and the shell falls back to its own default. So icon
assets are optional.

Page 36 holds positions 8 and 9; 10 is free.

## The recipe, untested

1. Write the app to `ux0:app/<TITLEID>/`
2. `get ur0:shell/db/app.db`
3. Offline, with host `sqlite3`: copy the 29 `tbl_appinfo` rows substituting the
   title id and paths, and insert one `tbl_appinfo_icon` row at a free
   `(pageId, pos)`
4. `put` it back
5. Restart the shell

## The unknown that stopped it

**SceShell holds `app.db` open**, and whether it flushes its own cached copy
over ours — or interleaves with the write — is not answerable by reading. The
failure range is: edit silently ignored, stale bubble, or a shell that dislikes
the row at boot. Recovery for the worst case is safe-mode **Rebuild Database**,
which regenerates `app.db` from `ux0:app`. Disruptive, not a brick.

## Consequence for the test apps

None, deliberately. [ADR-0012](../adr/0012-test-apps-as-measurement-instrument.md)
already calls for a single shared slot, and `FVTA00002` is registered, so the
test apps needs no new title at all.
