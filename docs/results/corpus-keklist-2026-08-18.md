# Corpus app 1: keklist

**Result: reaches its own UI and is navigable.** A 60-dependency production
journal app, on hardware, in **31 added lines** across three patches — one of
which was a bug in the app rather than a gap in the port.

Pinned at `d3e02ac`. Slot `FVTA00002`.

## The host pipeline, unmodified

| Stage | Result |
|---|---|
| `pub get` | resolves; no platform gating anywhere |
| `build bundle` | one failure, then 2.0 MB |
| `frontend_server` | **clean**, 58 MB kernel, **no codegen needed** |
| `gen_snapshot` | 98 MB armv7 assembly, 9.7 s |
| assemble | `.text` 7.85 MB + `.rodata` 6.06 MB |
| link | 17 MB `.vpk`; whole binary `.text` 20.1 MB + `.rodata` 8.0 MB + `.bss` 0.57 MB |

`purchases_flutter`, `webview_flutter`, `geolocator`, `photo_manager`,
`just_audio`, `video_player`, `local_auth`, `record` — every one compiled and
linked. **A plugin is Dart until it is called**, and nothing in the build cares
that no implementation exists. This is the single most useful thing app 1
taught: the build is not where plugin absence bites.

Free user memory while running: **72–75 MB**, steady.

## The four blockers, in order

| # | Blocker | Whose |
|---|---|---|
| 1 | `build bundle`: no file for asset `dotenv` | app — gitignored, holds keys |
| 2 | `MissingPluginException` — `shared_preferences.getAll` | **expected**; ADR-0009 |
| 3 | `FileSystemException: lock failed … errno 9` | **ours** — a real port gap |
| 4 | `MissingPluginException` — `purchases_flutter.setupPurchases` | app — no graceful degrade |

### 3 is the one that mattered

`File::Lock` went through `fcntl(F_SETLK)`, which newlib does not implement
here. Hive takes an advisory lock before opening **every** box, so this single
call stood between any `hive_ce` app and its own data.

Fixed in patch 0010 by returning `true` on Vita. Not a lie: a POSIX advisory
lock never prevents access, it only signals other *cooperating processes*, and
[ADR-0004](../adr/0004-static-single-binary.md) means there is exactly one. The
lock is vacuously held.

With it, Hive opened and **all three schema migrations ran to completion** on
the first boot.

### 4 is a finding about apps, not about us

RevenueCat has no Vita implementation and will never have one. Unhandled, its
`MissingPluginException` killed initialization *after* the database, the
migrations and the DI container had all succeeded — so the app sat on a spinner
forever while the log blamed a purchase API for a journal app failing to open.

Worth generalising: **real apps do not degrade when a plugin is missing.** They
`await` it during startup and die. This will recur in every corpus app, and it
is the app's bug on any platform the plugin has not shipped for — but it is
*our* symptom to recognise.

## What renders

Settings with icons, list rows and chevrons; a four-tab bottom navigation bar;
and a language picker showing **Cyrillic, Kazakh, Kyrgyz, Serbian in both
scripts, and Spanish** — international text layout works.

**Flag emoji render as tofu.** The bundled font has no emoji coverage. Named
here because it is the first font-coverage gap the project has hit and it will
look like a text bug when it recurs.

## Not measured

Frame rate under this app, scrolling behaviour, and whether the ghosted rows in
the first capture were real or an artifact of reading the framebuffer mid-frame
over a socket. The `shot` path has no vsync interlock, so a capture during a
route transition is expected to tear; that is a property of the tool, and
separating the two needs a deliberate test rather than a glance.
