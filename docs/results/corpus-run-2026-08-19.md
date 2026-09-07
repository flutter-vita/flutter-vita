# The test apps, run end to end

All five apps from [`apps/test-apps/manifest.txt`](../../apps/test-apps/manifest.txt)
built and put on hardware, 2026-08-19. Under
[ADR-0012](../adr/0012-test-apps-as-measurement-instrument.md) the score is
lines changed to reach first frame, because ADR-0009's `registerWith()` is
itself an app edit and no app here can run unmodified.

| App | Axis | Lines changed | First frame | Notes |
|---|---|---|---|---|
| material_3_demo | control | **0** | yes | had to fix the *build*, not the app |
| wonderous | assets, 58 MB vpk | **16** | yes | found a missing embedder API |
| keklist | storage, long lists | **31** | yes | 15-minute soak, 777 taps, stable |
| flutter_manga_reader | remote content, codegen | **17** | yes | clean; one `intl` override |
| localsend | networking | 30 and counting | **no** | core is Rust behind `dlopen` |

Four of five reach their own UI. The control needed no app edit at all.

## What each one cost

**material_3_demo — 0 lines.** It depends on `url_launcher`, so it is not quite
the plugin-free app the manifest claims, but the call is behind a tap and never
runs at startup. Both of its failures were in *our* toolchain and are written up
in [test apps-build-failures](test apps-build-failures-2026-08-19.md) — one of them
was silently shipping day-old snapshots for every app.

**wonderous — 16 lines**, the ADR-0009 registrations for `path_provider` and
`shared_preferences`. It also found the one engine bug of the run: the embedder
never called `FlutterEngineNotifyDisplayUpdate`, so
`PlatformDispatcher.instance.displays` was empty and `displays.first` threw
during the first build. See
[test apps-wonderous](test apps-wonderous-2026-08-19.md).

**keklist — 31 lines**, unchanged from 2026-08-18, and it now survives a
15-minute soak with 777 tab switches: heap flat at 9 MB of a 12 MB arena, frame
rate steady at 24–27 fps throughout with no degradation.

**flutter_manga_reader — 17 lines.** The same registrations, plus a one-line
`intl` override because `flutter_localizations` pins 0.20.2 and the app asks for
^0.20.3. It reaches its Library screen with a working bottom navigation and no
unhandled exceptions. **Cheapest real app in the test apps.**

> **Superseded the same day.** localsend was repinned to v1.15.4, the last
> release with no Rust in it, and now runs: it serves HTTPS, announces itself
> and answers peers. See
> [test apps-localsend-2026-08-19.md](test apps-localsend-2026-08-19.md). What
> follows describes the old pin and is kept because the ADR-0013 prediction it
> tested is the reason the repin was possible.

**localsend — does not reach first frame.** Its transfer core *and its crypto*
are Rust, loaded through `flutter_rust_bridge` with `DynamicLibrary.open`:

```
Failed to load dynamic library 'librust_lib_localsend_app.so':
loading dynamic libraries is not supported
```

ADR-0004 links one static ELF and there is no `dlopen`. Making that survivable
only moves the failure to `generateSecurityContext`, which is also Rust and is
called before `runApp`. **[ADR-0013](../adr/0013-ffi-needs-static-linking.md)'s
admission test rejects this** — and it was admitted anyway because the analysis
was done before the app grew a Rust core. Two lessons, and the second is the
useful one:

- Rust for `arm-vita-eabi` is not a target that exists, so "statically link the
  native code instead" is not available here at any price.
- **An admission test has to be re-run whenever a pin moves**, because what an
  app depends on is not a property of the app, it is a property of the commit.

What ADR-0013 *did* get right is worth recording: it predicted localsend would
fail visibly rather than blackly, because its `main()` wraps `preInit` in a
try/catch that renders an error screen. That is exactly what happened — the
first thing the console showed was localsend's own stack trace, legibly, on a
white background.

## Two things the numbers say that the plan did not

**`dmg%` does not predict frame rate on its own.** flutter_manga_reader sits at
**89% damage and 48 fps**; keklist at **64% damage manages 27**. The difference
is what is inside the damaged area — manga_reader's Library screen is mostly
white. So the GPU question cannot be settled by the damage figure alone; it
needs the raster cost underneath it, which is still unattributed.

**Our Linux identity has a cost, and this is the first bill.**
[ADR-0008](../adr/0008-app-visible-platform-identity.md) reports
`TargetPlatform.linux`, which is right for paths and fonts. localsend reads it
as *desktop* and goes looking for a window to position, a tray to populate and
a running instance to hand over to — `window_manager.ensureInitialized` threw
unhandled and killed startup before any of the Rust trouble mattered. Nothing to
fix in the engine; worth knowing that "linux" means "desktop" to a good deal of
the ecosystem.
