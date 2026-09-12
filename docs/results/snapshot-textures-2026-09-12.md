# Page snapshots leaked a GPU texture each, and the unref queue dropped them

**Question:** the first gallery bench on fvita_gles2 (2026-09-12) ran CDRAM
from 88 MiB free to nothing during the `route_*` scenes and logged 1,123
refused memblock allocations, while Skia's own resource cache sat at 6 entries
and 4.2 MiB. Who held the memory?

**Build:** gallery on `--gl gles2`, with counters added to the layer for this
question: live memblocks it owns per memory, textures with storage, textures
that have been drawn into (`tgt`), blocks waiting in the garbage list, CDRAM
refusals. `flutter_vita_gl_stats` puts them on every FRAMES line.

## What the counters said

Three scenes on the route path, each on a fresh launch:

| scene | transition | `tgt` over the scene | CDRAM the layer owns |
|---|---|---|---|
| `route_tx_none` | none | 1, flat | 11 MiB, flat |
| `route_tx_zoom` | Zoom, snapshotting on | 1 → 5 → 9 → 12 → 15 → 17 | 11 → 45 MiB |
| `route_bare,route_wrap,route_push` | Material default (Zoom) | 1 → 5 → 23 → 40 → 47 | 11 → 96 MiB, then `fail` |

`garbage` stayed 0 throughout: nothing was waiting on the GPU. The blocks were
live textures, all of them render targets, about two per push-and-pop cycle,
and none was released after the scene had popped back to the root. Skia did not
count them because they are not budgeted: `GrDirectContext::getResourceCacheUsage`
reports budgeted resources only, and a page snapshot is an unbudgeted surface.

## Where they were dropped

`ZoomPageTransition` snapshots each page with `toImageSync`. In the engine that
is `DlDeferredImageGPUSkia`; disposing the `ui.Image` runs
`ImageWrapper::DeleteTexture()` on the raster thread, which hands the
`GrBackendTexture` to the Skia unref queue. The queue deletes backend textures
only through the IO manager's resource context:

```cpp
// flow/skia_gpu_object.h, UnrefQueue::DoDrain
if (context) {
  for (const GrBackendTexture& texture : textures) {
    context->deleteBackendTexture(texture);
  }
  ...
}
```

This embedder gives the IO manager no resource context, on purpose: the
console has one GL context and `make_resource_current` is null so that every
GL call stays on the raster thread. So `context` is null, the loop does not
run, and the texture handle is dropped with the GL object still alive. One
960x544 RGBA8 render target, 2 MiB in this layer's layout, per snapshot.

Patch 0011 counted the queue's `Unref` calls (`unref q=0 d=0` in every
report) and not its `DeleteTexture` calls, which is why the queue read as
"never used" on 2026-09-01.

## Fix

Patch 0012: `ImageWrapper::DeleteTexture()` deletes the texture through
`context_`, the raster context that made it, when it has one. Both callers
already run on the raster thread. The queue path stays for a wrapper without a
context.

With the patch, the full 34-scene bench on the same build: no refused
allocation, the kernel's free CDRAM never under 62 MiB, the layer's own peak
32 MiB (eleven live render targets inside `route_tx_fade_*`, released after),
and the last FRAMES line back at 5 blocks, 2 textures, 1 target. Raster time
summed over the suite fell from 279 ms to 185 ms against the morning's run;
the stalls the bench ranks first (`list_churn`, `spinner`, `scroll_fling`)
are on the UI thread in both runs and did not move.

## What this closes

`the-second-route-scene-2026-09-01.md` measured the same leak under vitaGL as
native heap, 12 MiB a sample, and refuted snapshotting because `route_tx_zoom`
held flat there. It did not hold flat here: on this layer the growth is visible
inside the first scene, because CDRAM blocks are counted the moment they are
made, where vitaGL's pool hid the first tens of megabytes. The "positional"
reading was the pool filling up.

## Also from this run

The layer's first answer to a refused CDRAM allocation was to place the
texture in main memory. Unbounded, that took 43 MiB of it in the three-scene
run and the Dart heap stopped growing: `sceKernelAllocMemBlock('dart-heap')
failed -> 0x80024302`, the app alive on its port and never finishing the scene.
The fallback is now capped at 8 MiB; past that, `GL_OUT_OF_MEMORY`, which Skia
survives by dropping the layer.
