#!/usr/bin/env python3
# Writes docs/images/layers.svg, the diagram in the README's "How it works":
# one bar per layer, a tag on each saying where the layer comes from, and the
# interface between each pair. The SVG carries its own light and dark colours.
#
#   python3 tools/readme-layers.py            writes docs/images/layers.svg
#   python3 tools/readme-layers.py OUT.svg    writes somewhere else
#
# The tags are sized from their length in a 12 px monospace font, which is why
# this is a script and not a hand-edited file.
import sys
from pathlib import Path
from xml.sax.saxutils import escape as esc

W, X0, X1 = 880, 40, 840
TOP, BAR, GAP = 28, 54, 26
MONO_CH = 7.3   # px per char at 12px monospace, rounded up

LAYERS = [
    ("yours", "Your app", "Your Dart code. main.dart does not change.", "your code"),
    ("stock", "Flutter framework", "Widgets, layout, animation. Compiled with your app to ARMv7 code on your Mac.", "Flutter 3.44.8, unchanged"),
    ("fork", "Flutter engine", "Skia draws each frame. The Dart runtime runs your compiled code.", "flutter-vita/flutter · prebuilt"),
    ("ours", "Vita embedder", "Starts the engine, sends touch and buttons in, puts each frame on the screen.", "flutter-vita-embedder"),
    ("ours", "GLES2 layer (fvita_gles2)", "OpenGL ES 2.0 on top of sceGxm. Translates GLSL shaders to Cg.", "flutter-vita · gles2"),
    ("sony", "sceGxm and libshacccg", "Sony's GPU interface and shader compiler, on the console.", "Sony · on the console"),
    ("sony", "PowerVR SGX543MP4+", "The GPU of the PS Vita.", "hardware"),
]
LINKS = ["package:flutter", "dart:ui", "Flutter embedder API: frames out, input in",
         "OpenGL ES 2.0", "sceGxm commands, Cg through libshacccg", "GPU commands"]
LEGEND = [("yours", "your code"), ("stock", "Flutter, unchanged"),
          ("fork", "fork of Flutter"), ("ours", "written for this port"),
          ("sony", "Sony, on the console")]

stack_h = len(LAYERS) * BAR + (len(LAYERS) - 1) * GAP
LEG_Y = TOP + stack_h + 34
H = LEG_Y + 30

out = []
o = out.append
o(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="t d">')
o('<title id="t">How Flutter runs on the PS Vita</title>')
o('<desc id="d">Seven layers from top to bottom: your app, the Flutter framework, '
  'the Flutter engine, the Vita embedder, the GLES2 layer, sceGxm with libshacccg, '
  'and the PowerVR GPU. Each layer is tagged with where it comes from.</desc>')
o('''<style>
.card{fill:#ffffff;stroke:#d0d7de}
.bar{fill:#f6f8fa;stroke:#d0d7de}
.name{font:600 15px -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;fill:#1f2328}
.desc{font:13px -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;fill:#59636e}
.link{font:12px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;fill:#59636e}
.arrow{stroke:#8c959f;stroke-width:1.5;fill:none}
.head{fill:#8c959f}
.tag{font:12px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.leg{font:12px -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;fill:#59636e}
.s-yours{fill:#6e7781}.p-yours{fill:#eaeef2}.t-yours{fill:#424a53}
.s-stock{fill:#0969da}.p-stock{fill:#ddf4ff}.t-stock{fill:#0550ae}
.s-fork{fill:#8250df}.p-fork{fill:#fbefff}.t-fork{fill:#6639ba}
.s-ours{fill:#1a7f37}.p-ours{fill:#dafbe1}.t-ours{fill:#116329}
.s-sony{fill:#bc4c00}.p-sony{fill:#fff1e5}.t-sony{fill:#953800}
@media (prefers-color-scheme: dark){
.card{fill:#0d1117;stroke:#30363d}
.bar{fill:#161b22;stroke:#30363d}
.name{fill:#e6edf3}.desc,.link,.leg{fill:#9198a1}
.arrow{stroke:#6e7681}.head{fill:#6e7681}
.s-yours{fill:#8b949e}.p-yours{fill:#21262d}.t-yours{fill:#c9d1d9}
.s-stock{fill:#4493f8}.p-stock{fill:#0c2d6b}.t-stock{fill:#a5d6ff}
.s-fork{fill:#ab7df8}.p-fork{fill:#2e1c4f}.t-fork{fill:#e2c5ff}
.s-ours{fill:#3fb950}.p-ours{fill:#0f2e1a}.t-ours{fill:#aff5b4}
.s-sony{fill:#db6d28}.p-sony{fill:#3d1e0a}.t-sony{fill:#ffc680}
}
</style>''')
o(f'<rect class="card" x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="12"/>')

y = TOP
for i, (cat, name, desc, tag) in enumerate(LAYERS):
    o(f'<rect class="bar" x="{X0}" y="{y}" width="{X1-X0}" height="{BAR}" rx="8"/>')
    o(f'<rect class="s-{cat}" x="{X0}" y="{y}" width="6" height="{BAR}" rx="3"/>')
    o(f'<text class="name" x="{X0+22}" y="{y+22}">{esc(name)}</text>')
    o(f'<text class="desc" x="{X0+22}" y="{y+41}">{esc(desc)}</text>')
    tw = round(len(tag) * MONO_CH + 20)
    tx = X1 - 14 - tw
    o(f'<rect class="p-{cat}" x="{tx}" y="{y+15}" width="{tw}" height="24" rx="12"/>')
    o(f'<text class="tag t-{cat}" x="{tx+tw/2}" y="{y+31}" text-anchor="middle">{esc(tag)}</text>')
    if i < len(LINKS):
        ay0, ay1 = y + BAR + 3, y + BAR + GAP - 3
        ax = X0 + 60
        o(f'<line class="arrow" x1="{ax}" y1="{ay0}" x2="{ax}" y2="{ay1-5}"/>')
        o(f'<path class="head" d="M{ax-4},{ay1-6} L{ax+4},{ay1-6} L{ax},{ay1} Z"/>')
        o(f'<text class="link" x="{ax+14}" y="{y+BAR+GAP/2+4}">{esc(LINKS[i])}</text>')
    y += BAR + GAP

COL = (X1 - X0) / len(LEGEND)
for i, (cat, label) in enumerate(LEGEND):
    x = X0 + i * COL
    o(f'<rect class="s-{cat}" x="{x}" y="{LEG_Y-9}" width="10" height="10" rx="2"/>')
    o(f'<text class="leg" x="{x+16}" y="{LEG_Y}">{esc(label)}</text>')
o('</svg>')
dest = Path(sys.argv[1]) if len(sys.argv) > 1 else \
    Path(__file__).resolve().parent.parent / "docs/images/layers.svg"
dest.write_text("\n".join(out) + "\n")
print(dest)
