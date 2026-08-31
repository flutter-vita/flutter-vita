# What stops localsend shipping

Driven on the console over the dev server's `tap` and `swipe`, against the
build deployed 2026-08-31, on the GPU path. Every entry below has a log line or
a screenshot behind it; nothing here is inferred from reading the source.

The headline: **you cannot look at a file you received.** That is the app's
whole point after the transfer completes, and it fails silently.

## Blockers

### 1. Tapping a received file does nothing, and throws

Receive history → tap any entry. No navigation, no dialog, no feedback. The log:

    Unhandled Exception: Invalid argument(s): Failed to load dynamic library
    'libc.so.6': loading dynamic libraries is not supported
    #3  OpenFilex.open (package:open_filex/src/platform/open_filex.dart:36)
    #4  openFile (package:localsend_app/util/native/open_file.dart:25)
    #5  ReceiveHistoryPage._openFile (…/receive_history_page.dart:51)

The port reports `TargetPlatform.linux` (ADR-0008), so `open_filex` takes its
Linux branch, which `DynamicLibrary.open('libc.so.6')` to reach `system()`.
There is no libc.so.6 here and no dlopen at all.

It throws rather than returning a failure, so `openFile`'s own fallback --
`CannotOpenFileDialog`, which exists and would at least say something -- is
never reached. The user gets a tap that does nothing.

**Open folder** on the same page is the same call and the same outcome
(`open_folder.dart:18`).

It does not crash. Seventeen taps on a fresh boot throw seventeen times with
memory flat; the fault the console took on 2026-08-31 while a file was being
tapped is item 3, and the tap is not what caused it.

Fixing it needs a decision, not just a stub. There is no file association on
this console, so "open" cannot mean "hand it to another app". Either localsend
shows the file itself -- an image viewer and a text viewer are most of what a
received file is -- or it says plainly that it cannot, which is a worse product
but an honest one.

### 2. The receive stall, still open

Documented in [localsend-stall-2026-08-31.md](localsend-stall-2026-08-31.md):
frames stop after repeated transfers while the platform loop keeps perfect
cadence, throughput decays 648 → 503 KB/s and free memory 45 → 28 MB across
nine transfers. Not reproduced again today; nothing about it has changed.

### 3. A data abort inside SceGxm, twice, on the raster thread

    pthread <0x40010197>   io.flutter.raster
        Stop reason: 0x30004 (Data abort exception)
        PC: 0xe00aa728 (SceGxm@1 + 0x1e638)
        R0: 0x70100254   R11: 0x70100250   LR: 0x1

Registers identical to the 08-30 fault, and now symbolicated against the ELF
that produced it: the raster thread is in `glViewport` (`misc.c:342`, the
statement after `vglSetViewport`) with `update_scissor_test` (`tests.c:334`)
further up the stack. Both faults followed hours of uptime and a monotonic
slide in free memory. Full write-up in
[localsend-gxm-abort-2026-08-31.md](localsend-gxm-abort-2026-08-31.md).

It takes the app down with no warning, which no other item here does.

## Missing plugins, failing silently

Each of these is a feature that looks present and does nothing.

### 4. The app cannot report its own address

    MissingPluginException(No implementation found for method wifiIPAddress
    on channel dev.fluttercommunity.plus/network_info)

Discovery works -- an iPhone on the network showed up as "Bright Orange"
unprompted -- so this is not fatal. It costs the manual path: when discovery
does not find the console, there is no address on screen to type into the other
device.

### 5. No network-change detection

    MissingPluginException(No implementation found for method listen
    on channel dev.fluttercommunity.plus/connectivity_status)

This console drops its Wi-Fi and comes back on a different lease often enough
that the loader exists partly to report it. localsend will not notice.

### 6. wakelock_plus throws on every toggle

    Unhandled Exception: PlatformException(channel-error, Unable to establish
    connection on channel: "dev.flutter.pigeon.wakelock_plus_platform_interface
    .WakelockPlusApi.toggle")

Twice in one session, unhandled. The screen can sleep during a transfer, which
on this device is exactly when it must not.

## Performance

### 7. 29 fps on a static list, and the GPU is idle for it

    FRAMES active 60 @ 34446 us = 29.03 fps (raster 2275 us = 6%, blit 126 us
    = 0%, dmg 0%) | gl wait 31856 us

31.9 ms of a 34.4 ms frame is `gl wait` -- the raster thread idle, waiting to be
handed work (ADR-0014). Raster is 6%. The UI thread is the whole cost, on a
screen that is a scrolling list of text, not moving. The Settings tab measured
14 fps.

This is the same finding as the 08-25 results and the stall write-up, now on a
third screen. It is the performance problem; the GPU is not.

### 8. No resource context for texture uploads

    [ERROR:embedder_surface_gl_skia.cc(121)] Could not create a resource
    context for async texture uploads. Expect degraded performance. Set a valid
    make_resource_current callback on FlutterOpenGLRendererConfig.

Twice at startup. The embedder does not provide `make_resource_current`, so
Skia uploads textures on the render context and says so. Worth pricing before
chasing item 6 further -- it is an engine-side omission with a named fix.

## Release polish

### 9. The debug HUD ships

The green frame counter is `flutter_vita_debug_overlay`, weak-defaulted to 1 in
the embedder. `templates/vita-app/release.c` defines it strong at 0, and the
corpus build is not passing `--release`.

### 10. LiveArea art is the template's

localsend gets the shared Vita-with-Flutter-logo icon and gate. Fine for a
corpus app under test, wrong for anything called a release.

## What is not a bug

**White horizontal lines across screenshots.** Present in several captures on
the Receive tab and absent from the panel: two consecutive `shot` calls on a
settled screen are byte-identical, and the lines only appear while the tab's
ring animation is running. `shot` reads the scanout buffer while the GPU is
writing it. A screenshot artefact, not a display one.

**The CPU/FPS bar over the top-left corner.** A plugin on this console, drawn
by the shell over every application, not something localsend or the port does.

## Order to fix

3 is the only one that loses the user's session, so it goes first even though
it is the least understood. 1 is the release blocker for what the app is *for*,
and needs a product decision before any code. 6 is a two-line stub with a real
consequence. 4 and 5 are small plugins of the kind already in `packages/`. 7 is
the long-standing one and the only one that is a research task rather than a
job.
