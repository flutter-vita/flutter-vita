# K1 — does the overlay keyboard composite over vitaGL?

One `.vpk`, no Dart and no engine, that brings vitaGL up the way the embedder
does, opens **libime**, and swaps with `has_commondialog = GL_TRUE`.

It exists because this port's answer to text input was `sceImeDialog`, a modal
common dialog that needs a GXM surface to draw into — and under vitaGL there
isn't one to give it, so a tap into a `TextField` froze the app and never gave
the screen back ([ADR-0014](../../docs/adr/0014-gpu-backend-via-vitagl.md)).
The conclusion drawn at the time, that text input and the GPU are exclusive,
assumed the modal dialog is the only system keyboard. It is not.

## Build and run

```bash
./build.sh
VITA_HOST=<ip> ../../tools/deploy.sh --vpk build/flutter_vita_k1.vpk --no-launch
```

Then `launch` on the loader. It runs ~14 s, prints every IME event to
`ux0:data/flutter-vita/k1.log`, dumps a framebuffer at 6 s, and hands the
console back. Title ID is `FVTA00002`, the same slot every app deploys into.

## What it found, 2026-08-27

**libime works under vitaGL, unchanged.** `sceImeOpen` succeeds, the keyboard
appears over the bottom of the panel, and the GL bands keep animating
underneath it. No GXM surface is handed over, because the shell composites the
keyboard *after* the app has presented — which is also why the app never loses
the display the way the modal dialog took it.

Four things the spike pinned down that the embedder then relied on:

| | |
|---|---|
| `SCE_IME_EVENT_OPEN` carries a `SceImeRect` | this is `viewInsets.bottom`, and it is the reason a yes/no answer wasn't enough |
| `vglSwapBuffers(GL_TRUE)` is required | it is `has_commondialog` in vitaGL's swap; `GL_FALSE` and the keyboard never appears |
| `vgl_has_cdlg_support` stays TRUE | only `vglInit*` variants that claim the CDIALOG pool clear it, and with `vglInitExtended` that pool's size computes to 0 |
| the capture is empty | `dump_framebuffer` at 6 s contains the bands and **no keyboard** — `sceDisplayGetFrameBuf` returns what the app drew, so `shot` can never confirm this and the log has to |

The bands are drawn with nothing but `glClear` and a scissor: no shaders, no
vertex buffers, nothing that could fail for its own reasons and be mistaken for
the keyboard not compositing. The top band moves so a frozen capture is
distinguishable from a live one.

Prior art: `mswlandi/vita-libime-sample` shows libime under vita2d. The open
question this spike answered was vitaGL specifically.

## What it did not test

`SCE_IME_OPTION_MULTILINE`. The spike opens with `NO_ASSISTANCE` only, so it
never hit the rejection the embedder later did — this console returns
`0x80100715` (`SCE_IME_ERROR_INVALID_OPTION`) for multiline and there is no
inline multiline keyboard to be had.
