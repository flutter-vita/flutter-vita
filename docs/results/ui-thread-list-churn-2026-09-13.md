# The list_churn stall: a synced trace write under every heap page

**Question:** `list_churn` stalls for about three seconds on both backends,
and the user saw the same freeze on vitaGL before fvita_gles2 existed. The
bench blames the UI thread. What on the UI thread costs it?

**Build:** gallery on `--gl gles2`, engine with patch 0013 (`--verbose_gc`
allowed in release on `__vita__`) and the embedder passing
`--dart-flags=--verbose_gc` when `ux0:data/flutter-vita/gc.on` starts with
`1`. The GC report reaches app.log through stderr.

## What `diag` said first

Two samples five seconds apart during the scene: `io.flutter.ui` ran 36% of
the window, `io.flutter.raster` 4%, everything else idle. The stall is the UI
thread computing, not a wait. No renderer change reaches it.

## What the GC report said

Fourteen scavenges during the scene, and they were slow for the amount of
memory moved:

| | scavenge time, ms |
|---|---|
| mean | 104.0 |
| median | 74.8 |
| max | 445.0 |

A scavenge of a 1 to 2 MiB new space should take a few milliseconds on this
CPU. The time was not in the copying.

## Where it went

`runtime/platform/syslog_vita.cc` in the Dart runtime port has `VitaTrace`,
a line-per-event trace used by `virtual_memory_vita.cc`. It did an
`sceIoWrite` and an `sceIoSyncByFd` for every line, and the allocator emits
three lines for every heap page it takes. A scavenge that grows the semispace
takes pages, and each one paid three synced writes to the memory card.

The fix gates `VitaTrace` on `ux0:data/flutter-vita/trace.on`, checked once.
Patch 0003 (Dart) carries it.

## After

Same suite, same engine otherwise, fvita_gles2:

| | scavenges | mean ms | median ms | max ms |
|---|---|---|---|---|
| trace on | 14 (one scene) | 104.0 | 74.8 | 445.0 |
| trace gated | 345 (full suite) | 15.9 | 14.3 | 72.0 |

Suite sums, 36 scenes:

| build | worst-frame sum | stall sum | heaviest-build sum |
|---|---|---|---|
| vitaGL, trace on | 4450 | 10750 | 6557 |
| fvita_gles2, tiled targets, trace on | 4667 | 9783 | 3902 |
| fvita_gles2, trace gated | 3167 | 9067 | 2095 |

`list_churn` itself: stall 3233 → 2900 ms, heaviest build 217 → 223 ms. The
rest of the scene is Dart building and laying out about twenty `ListTile`s
per frame at 444 MHz, 100 to 150 ms a frame, and that is the scene's design.

## What this settles

- The freeze the user saw on vitaGL had the same cause; the layer under Skia
  was never part of it.
- The vitaGL line in the parity table was taken with the trace on and needs a
  rerun on the gated runtime before the two backends are compared again.
- Scavenges still cost about 20 ms per MiB moved. That is the next question
  for the GC report, not this one.
