# The gallery on fvita_gles2, first run

**Question:** does Skia draw the gallery through `gles2/` (ADR-0019, M3)?

**Build:** `./tools/build-vita-app.sh apps/gallery --gl gles2`, engine
artifact repackaged after the embedder switch (patch 0004), deployed to the
FVTA00002 slot, 2026-09-12 22:10.

**Answer:** yes. The home screen and the list of rows render as under vitaGL
to the eye ([frame](gallery-fvita-gles2-2026-09-12.png)): anti-aliased
circles, text from the glyph atlas (GL_ALPHA textures), the scrollbar.

From `app.log`:

| measure | value |
|---|---|
| `GL up` | `OpenGL ES 2.0 fvita_gles2 / fvita_gles2 over sceGxm` |
| programs linked before the scroll | 22 |
| recording stubs Skia called | **0** (`gles2-unimplemented.txt` never written) |
| `glGetIntegerv` names not answered | 0 |
| steady frame window before the scroll | 60 frames at 22.7 ms, 44 fps, raster 5.1 ms per frame |
| stalls into in-flight textures | not reported by the embedder yet |

**The scroll stalled**, and the report says where: `STALL 2000 ms since
present #3098 -- raster phase idle`, the raster thread waiting on its message
loop after a finished present, the UI thread and a `pthread` both waiting on
`0x40020661`. Nothing inside `fvgl_*` or sceGxm. The same signature was
recorded under vitaGL on 2026-09-11 (the bench's `page_swipe` scene), so it is
the engine-side stall in the backlog, not the backend.

**The exit path, second run (22:40):** `handoff` from the home screen after
two minutes at 60 fps (raster 5.6 ms). `gles2-shutdown.txt`:

```
begin: 31 programs 1315 textures 8 buffers 54 framebuffers, frame 7511 done 7510
finish / display queue / programs / buffers / framebuffers and textures /
garbage / patcher / display and context / terminate / down
```

The receiver came back. The first run's "receiver did not come up" was the
poll, not the console: the receiver answers a cold connect after 2 to 4 s and
the poll gave it 2. `tools/deploy.sh` waits 6 for that reason; so does every
poll here now.
