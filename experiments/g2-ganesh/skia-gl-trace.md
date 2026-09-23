# The Skia GL trace

`skia-gl-trace.diff` is diagnostic instrumentation for this spike. It is not
part of the port. Keep it out of the engine unless you are debugging.

## What it does

It declares `extern "C" void fvita_gl_trace(const char* file, int line)` and
calls it from nine Skia files, so that a `GrDirectContext` that fails to start
says where it stopped. `GrGLUtil.h` puts the call inside `GR_GL_CALL`, so
**every** Ganesh GL call goes through it. The spike's own `src/` defines the
function; anything else that links Skia does not.

| File | Where it reports from |
|---|---|
| `src/core/SkMessageBus.h` | `Inbox` construction, around the static `Get()` |
| `src/gpu/ganesh/GrDirectContext.cpp` | Context creation |
| `src/gpu/ganesh/GrContextThreadSafeProxy.cpp` | The thread-safe proxy |
| `src/gpu/ganesh/gl/GrGLDirectContext.cpp` | GL context creation |
| `src/gpu/ganesh/gl/GrGLCaps.cpp` | Capability detection |
| `src/gpu/ganesh/gl/GrGLGpu.cpp` | The GPU object |
| `src/gpu/ganesh/gl/GrGLInterfaceAutogen.cpp` | Interface validation |
| `src/gpu/ganesh/gl/GrGLUtil.h` | Every `GR_GL_CALL` |
| `src/text/gpu/TextBlobRedrawCoordinator.cpp` | The glyph cache |

## Why it is a file and not a commit

The port lives in commits now (see [engine/README.md](../../engine/README.md)).
This does not, because it must never reach a build that is not this spike.
On 2026-09-23 it was still in the Skia checkout, and it reached the released
engine archive `3.44.8_0.1.0`: 20 references to `fvita_gl_trace`, 19 of them
undefined. An app that linked that archive and defined the symbol by accident
would have taken a call on every GL operation.

## To use it

```bash
cd third_party/flutter/engine/src/flutter/third_party/skia
git apply /path/to/experiments/g2-ganesh/skia-gl-trace.diff
# build the spike, read the output, then:
git checkout -- .
```

`./tools/engine-tree.sh --verify` fails while it is applied, which is the
point: it reports the Skia checkout as changed, so the instrumentation cannot
leave with an engine build again.
