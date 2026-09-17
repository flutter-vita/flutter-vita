# What stops localsend shipping

Driven on the console over the dev server's `tap` and `swipe`, against the
build deployed 2026-08-31, on the GPU path. Every entry below has a log line or
a screenshot behind it; nothing here is inferred from reading the source.

The headline: **you cannot look at a file you received.** That is the app's
whole point after the transfer completes, and it fails silently.

## Blockers

### 1. Tapping a received file does nothing, and throws — FIXED 2026-09-01

The throw is caught and the console now has somewhere to send you. Details at
the end of this section; the original diagnosis follows because the reasoning
is what produced the fix.

#### The fix

`OpenFilex.open` threw before its result was ever inspected, so
`CannotOpenFileDialog` -- which already existed, was translated, and named the
file -- was never reached. Catching it is most of the repair: a tap now raises
an alert with the path, a "delete from history" button, and Close.

Beyond that, VitaShell can be opened **in the file's own folder**. It has no
deep link -- its `main()` takes argc and argv and ignores both, and it registers
no URI scheme -- but `browser.c` reads `ux0:VitaShell/internal/lastdir.txt` at
startup and navigates there, so the embedder writes that file and then launches
`psgm:play?titleid=VITASHELL`. The button is hidden when `ux0:app/VITASHELL` is
absent, and it is labelled "closes app" because it does: the Vita runs one
application at a time.

What this is not is an in-app viewer. Showing a received photo without leaving
the app is still the better answer for the common case, and
`packages/vita_file_browser` already draws a file browser in Flutter if a
folder view is wanted without quitting.

#### The original diagnosis

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

### 2. The receive stall — very likely the same bug as 3

Documented in [localsend-stall-2026-08-31.md](localsend-stall-2026-08-31.md):
frames stop after repeated transfers while the platform loop keeps perfect
cadence, throughput decays 648 → 503 KB/s and free memory 45 → 28 MB across
nine transfers. Not reproduced again today; nothing about it has changed.

### 3. A data abort inside SceGxm — FIXED 2026-09-01

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

**Cause:** vitaGL never checked `sceGxmReserveVertexDefaultUniformBuffer` and
wrote through the null it leaves on refusal. Fixed in
[patches/vitagl/0002](../../engine/patches/vitagl/0002-the-reservation-vitagl-never-checked.patch).
One tap on an overflow menu reproduced it; twenty cycles now survive.

**This also closes item 2.** The receive stall and this abort were the same
bug — GXM handed a draw built on a null uniform buffer either faults or wedges,
and the wedge is what the stall write-up spent a day failing to find in the
thread states. Holding the menu open for two minutes used to freeze it in
twenty-two seconds and now does not. The memory slide across nine transfers in
that write-up is a separate observation and stays open.

### 3b. A shader libshacccg would not compile — FIXED 2026-09-01

Scrolling to the receive-history row with a JPEG in it took 29 fps to 5, with
`link failed but did not provide an info log` on Skia's image draw.

The cause was in vitaGL, not Skia: `#define s x` in the Cg translation header
renamed every variable called `s` in every shader, and Skia's colour transfer
function declares one inside a function taking `x`. Fixed in
[patches/vitagl/0004](../../engine/patches/vitagl/0004-the-define-that-renamed-every-s.patch).
That row now holds 29.0 fps with the raster thread at 8% and refuses no links.
Full account in
[shader-compile-failures-2026-09-01.md](shader-compile-failures-2026-09-01.md).

**The thumbnail on that row is still blank**, and it is now item 3c.

### 3c. The JPEG thumbnail never appears

Neither a picture nor the file-type icon: an empty rounded tile, while the HEIC
row beside it draws the icon through the same widget's `errorBuilder`. Nothing
in the log — no refused link, no decode error. `SmartFileThumbnail` calls
`Image.file(File(path), cacheWidth: 64)`, and an empty tile is what `Image`
draws while a decode is pending, so the scaled decode of a 4 MB JPEG is neither
completing nor failing. Not measured further.

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
that the receiver exists partly to report it. localsend will not notice.

### 6. wakelock_plus throws on every toggle — and nothing on this port stays awake

The Dart side of a hole that runs all the way down. Until 2026-09-01 **nothing
in the Flutter app path called `sceKernelPowerTick`**, so the console suspended
itself on its idle timeout and took the network with it. The embedder now ticks
from its platform loop behind `flutter_vita_keep_awake`; a `wakelock_plus`
implementation finally has something real to call. Full account in
[the-console-was-asleep-2026-09-01.md](the-console-was-asleep-2026-09-01.md).

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
test apps build is not passing `--release`.

### 10. LiveArea art is the template's

localsend gets the shared Vita-with-Flutter-logo icon and gate. Fine for a
test apps under test, wrong for anything called a release.

## What is not a bug

**White horizontal lines across screenshots.** Present in several captures on
the Receive tab and absent from the panel: two consecutive `shot` calls on a
settled screen are byte-identical, and the lines only appear while the tab's
ring animation is running. `shot` reads the scanout buffer while the GPU is
writing it. A screenshot artefact, not a display one.

**The CPU/FPS bar over the top-left corner.** A plugin on this console, drawn
by the shell over every application, not something localsend or the port does.

## Order to fix

3 is fixed, and 2 with it; 3b is fixed and left 3c behind; 1 is fixed. Of what is
left, 6 is a two-line stub with a real
consequence. 4 and 5 are small plugins of the kind already in `packages/`. 7 is
the long-standing one and the only one that is a research task rather than a
job.
