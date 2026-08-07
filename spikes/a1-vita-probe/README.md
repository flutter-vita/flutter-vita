# Track A probe

One `.vpk` that answers every remaining Phase 0.5 question that only real
hardware can answer. See [../../docs/phase-0.5-feasibility.md](../../docs/phase-0.5-feasibility.md).

**Do not run this on Vita3K.** It stubs `sceKernelOpenVMDomain` and returns
success, and it does not enforce the 16 MiB VM cap — so it would report a clean
pass while proving nothing. See [../../docs/vita3k-as-a-target.md](../../docs/vita3k-as-a-target.md).

## Build

```bash
./build.sh
```

Produces `build/flutter_vita_probe.vpk` (~47 KB). Title ID `FVTA00001`.

## Deploy

1. Start the FTP server in VitaShell (press `SELECT`).
2. Upload `build/flutter_vita_probe.vpk` to `ux0:/`.
3. In VitaShell, press `X` on the `.vpk` to install.
4. Launch **Flutter Vita Probe** from the LiveArea.

There are no LiveArea assets, so the icon is blank. That is expected for a spike.

## Results

Printed to the screen, and written to `ux0:data/flutter-vita/spike.log` so it can
be pulled back over FTP rather than transcribed from a photo.

Press `START` to exit.

## What it measures

**A1 — VM domain** (decides [ADR-0005](../../docs/adr/0005-aot-snapshot-delivery.md))

Allocates a VM block, writes hand-assembled machine code into it while the
domain is closed, calls `sceKernelOpenVMDomain` + `sceKernelSyncVMDomain`, then
executes it. Both ARM (A32) and Thumb encodings are tested — Dart's AOT backend
emits ARM while VitaSDK defaults to Thumb, so each needs proving separately.

If this passes, the AOT snapshot can be shipped as a data file and loaded at
runtime, and third parties never relink the engine. If it fails, the snapshot
must be baked into `eboot.bin` and every app rebuild is a full engine link.

**A1 — allocation limits**

Largest obtainable VM block (checks the documented 16 MiB cap against reality),
and largest contiguous `sceKernelAllocMemBlock` for `USER_MAIN_RW`,
`USER_MAIN_PHYCONT_RW`, and `USER_CDRAM_RW`. If the largest single block is
smaller than the Dart heap needs, `virtual_memory_vita.cc` becomes a multi-block
allocator and a much harder file than the plan assumes.

**A2 — raster cost** (sets the bar in [ADR-0006](../../docs/adr/0006-performance-bar-set-from-measurement.md),
decides [ADR-0007](../../docs/adr/0007-enable-partial-repaint-in-software-path.md))

`memcpy`, solid fill, and naive per-pixel alpha blend over 960×544 and 720×408
buffers, at 333 MHz and 444 MHz. Reports ms/frame, implied fps, and the
fill+blit floor — the cost of a full-screen software frame *before Skia does any
real work*.

This is not a Skia number, but it brackets one. If `memcpy` alone of a 2.09 MB
framebuffer already costs ~10 ms, full-screen 60 fps is arithmetically dead and
partial repaint stops being an optimisation.

## Known limitation

It does **not** try executing a VM block *before* `sceKernelOpenVMDomain`. That
would be the cleanest proof the domain toggle is actually enforced, but a fault
there kills the process and takes the log with it. Worth a follow-up run once
the safe results are banked.
