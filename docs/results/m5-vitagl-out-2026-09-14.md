# M5: vitaGL and vitaShaRK out of the tree

**Question:** ADR-0019's last milestone asks for a tree in which `fvita_gles2`
is the only GL. What had to go, what proves nothing still needs it, and does
the bridge, which links a pinned engine, come along?

**Builds:** gallery builds 25 and 26 of 2026-09-14 (`gallery-gles2-run25`,
`run26`), the scratch bridge FVTA00004 and the bridge FVTA00001 on engine
pin `a2f902e2` (`bridge/engine-pin.txt`). Bench results
`out/bench/gl-gles2-run{24,25,26}-2026-09-14.json`.

## What left

| where | what |
|---|---|
| `patches/vitagl/` | the four patches and their README |
| `templates/vita-app/` | `gl_vitagl.c`; the vitaGL link block in `CMakeLists.txt`; the GL block is unconditional and `GLES2_DIR` is a cache path |
| `tools/build-vita-app.sh` | `--gl`, `FLUTTER_VITA_VITAGL`, `GL_BACKEND`, `-DFLUTTER_VITA_GL` |
| `tools/apply-patches.sh` | the `vitagl` tree; `--verify` now checks 51 patches |
| embedder (patch 0004) | the weak `vgl_*` counters and `ReportGlCounters`, the `kSharkOpt*` probe, the `vgl` fields of the diag `mem` line, the seven `VitaGl*` shims that stood in for entry points vitaGL lacked |
| `NOTICE` | the LGPL section; nothing in the link is LGPL |
| `third_party/vitaGL` | the checkout, gitignored and disposable; the patches it carried are in git history under `patches/vitagl/` |

`flutter_vita_gl.h` keeps its six functions and `gl_gles2.c` is the only
file that answers them. Two of the shims covered calls Skia makes at context
creation that the layer did not answer; the layer answers them now:
`glGetShaderPrecisionFormat` (float range 127/127 with 23 bits, int 31/30)
and `glGetIntegerv(GL_NUM_PROGRAM_BINARY_FORMATS_OES)` returning 0. The
first was a recording stub in `stubs.c` and is real now; the second is a row
of the `glGetIntegerv` table. Neither name is in Skia's bound set
(`gles2/surface.txt`), so the generated counts and the ledger in
`docs/gles2-progress.md` did not move.

## Evidence

**Symbols.** `arm-vita-eabi-nm` over the unstripped ELF, counting names that
start with `vgl`, `vitashark` or `shark_`: build 25 has 8, all weak
references from the embedder's counter block, which is why that block went
too; build 26 has 0. The bridge's ELF on the new pin has 0.

**The gallery.** Builds 25 and 26 ran the 36-scene bench to the end, no
`interrupted` scene, no `WATCHDOG` report, no `unimplemented:` line in the
log. Sums over 36 scenes, with the two build 23 runs from the parity record
for scale:

| run | engine | worst ms | stall ms | heaviest build ms | UI build ms | raster ms |
|---|---|---|---|---|---|---|
| vitaGL, build 23 | 2d7f2a4 | 3567 | 11267 | 1625 | 254.4 | 216.4 |
| fvita_gles2, build 23 | 2d7f2a4 | 3033 | 7650 | 1503 | 255.7 | 211.5 |
| fvita_gles2, build 24 | + pthread_cond, NSEC | 2850 | 7533 | 1428 | 247.2 | 222.1 |
| fvita_gles2, build 25 | + shot copy, static-screen guard | 4350 | 11800 | 1551 | 249.5 | 266.5 |
| fvita_gles2, build 26 | shim-free, no vitaGL | 3283 | 11233 | 1743 | 235.5 | 224.2 |

The stall and worst sums of 25 and 26 sit above 24, and the per-scene view
says why: the excess is in different scenes in each run, and in one run
only. `modal_sheet` stalled 1017 ms in run 25 and 0 in runs 24 and 26;
`transform_rotate` 1050 ms in run 26 and 100 in the other two; `image_scale`
767 ms in run 25 and 0 in the other two; `list_churn` 3583 in run 26 against
2850 and 2850. Only `route_text_uniq` rose in both (183 to 1167 and 967).
Nothing in builds 25 and 26 touched the GL path itself; the shot copy and
the stall-check guard run outside the frame. So this is the run-to-run
spread of one console, not a cost of removing the shims. The runs that
followed the same morning (`docs/results/log-writes-on-the-frame-threads-2026-09-14.md`)
found where a good part of that spread comes from.

**The bridge.** The engine pin moved to the archive built at
2026-09-14T06:19:23Z (`archive_sha256 a2f902e2…`), which carries the UI-thread
watchdog and wait notes, the Dart monitors on LwMutex/LwCond, the AAAA answer
below, the one-frame screenshot copy, and links `fvita_gles2` with
`pthread_cond` on LwCond from the template. In order:

1. `tools/build-bridge.sh --scratch` and `tools/install-vpk.sh` promoted the
   scratch bridge FVTA00004. It boots on the layer (`GL up -- OpenGL ES 2.0
   fvita_gles2`), draws its panel, and `deploy.sh --bridge-port 1342`
   pushed and launched the gallery through it, exit 0.
2. `tools/selfupdate-bridge.sh` staged the 16 files of the FVTA00001 build
   (12.6 MB `eboot.bin` in 18 s), handed the console to the updater
   FVTA00009, and the new bridge answered `pong bridge FVTA00002 1341
   FVTA00001` 15 s later. Its panel renders (`shotinfo`: `match=fvita_gles2
   … copy=20499 us`), its log shows eight programs linked and no error past
   the two expected resource-context lines.
3. `deploy.sh apps/gallery --no-build` through the new FVTA00001: eboot
   staged, installed, launched, `up on 1339 after 3s`, 34 s end to end.

The scratch bridge stays installed; it is the rehearsal slot for the next
pin and costs nothing.

## What rode along on the same pin

Two changes of this window are in every build from 24 on and are recorded
here because the parity numbers above include them.

**The responder answers AAAA.** `docs/results/test-apps-fvita-gles2-2026-09-13.md`
found the 5.00 s macOS pays asking for an IPv6 record and put `-4` on every
`nc` in `tools/`. The console-side fix is in `devserver.c`: a query for type
28 gets an answer with no AAAA record and an NSEC record (RFC 6762 §6.1)
naming the types that exist, A only; announcements carry the same NSEC.
`dns-sd -Q flutter-vita.local AAAA IN` now says "No Such Record" at once, so
a host that forgets `-4` waits 0.06 s instead of 5.

**`std::condition_variable` on the kernel.** The frozen-UI-thread record
left the engine's `std::condition_variable` users on pthreads-embedded,
polling every 500 µs. `templates/vita-app/pthread_cond.c` defines the six
`pthread_cond_*` functions over an LwCond bound to a private LwMutex gate,
so the linker never pulls the SDK's; `nm` shows `cond_new` and none of
`pte_cond_*`'s functions in builds 24 to 26 (four `pte_cond_*` data symbols
remain from pte's globals, unused). The diag `thr` lines show
`io.worker.1` and `.2` parked at 0% CPU where they woke 2000 times a second
before. Builds 24 to 26 ran 108 scenes without a freeze.

## What this settles

- The tree builds, runs, benches and deploys with no vitaGL and no
  vitaShaRK object in any ELF, bridge included. ADR-0019's M5 is done and
  ADR-0014 is superseded in full.
- The LGPL question of ADR-0018 is closed by absence: a `.vpk` built from
  this tree links BSD-3 code, Sony's runtime modules, and `libshacccg` on
  the console.
- Run-to-run spread on this console is a few hundred milliseconds of stall
  per scene in a handful of scenes. A single bench run cannot show a change
  smaller than that; the build 23 pair remains the parity measurement.

## Deferred, by the user's choice of 2026-09-14

The Zoom transition's GPU time and screenshots scene by scene, both open in
the parity record, stay open.
