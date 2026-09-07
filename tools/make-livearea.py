"""LiveArea artwork: a Vita with the Flutter logo on its screen.

Run from the repo root. Writes templates/vita-app/livearea/, which every app
built from the template ships as its icon, gate and background. The palette is
the receiver panel's, so the bubble and the app agree.

The silhouette follows the real hardware: two full-height oval ends, a slab
between them a shade shorter, a 16:9 screen taking just over half the width,
and the controls where your thumbs expect them. Every offset below is a
fraction of body width or height, measured off a front-on photo of the device.
"""
from PIL import Image, ImageDraw

BG      = (11, 20, 32)      # 0B1420, the panel's ground
BODY    = (24, 38, 54)
RIM     = (52, 74, 96)
CTRL    = (14, 24, 36)
CTRL_HI = (44, 64, 86)
SCREEN  = (8, 16, 26)
EDGE    = (30, 48, 66)

L_BLUE  = (0x54, 0xC5, 0xF8)
M_BLUE  = (0x29, 0xB6, 0xF6)
D_BLUE  = (0x01, 0x57, 0x9B)

# The Flutter logo in its own 256 x 317 space, scaled and placed by `logo`.
A = [(157.7, 0), (255.3, 0), (48.8, 206.5), (0, 157.7)]
B = [(156.6, 145.2), (255.3, 145.2), (170.1, 230.9), (121.4, 279.6), (72.6, 229.3)]
C = [(121.4, 279.6), (158.1, 316.3), (255.3, 316.3), (170.1, 230.9)]
D = [(121.4, 279.6), (170.1, 230.9), (193.5, 254.3)]


def logo(d, cx, cy, h):
    s = h / 317.0
    ox, oy = cx - 256 * s / 2, cy - h / 2
    def put(pts, col):
        d.polygon([(ox + x * s, oy + y * s) for x, y in pts], fill=col)
    put(A, L_BLUE)
    put(B, L_BLUE)
    put(C, D_BLUE)
    put(D, M_BLUE)


def disc(d, cx, cy, r, fill, ring=None, rw=0):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fill,
              outline=ring, width=rw)


def dpad(d, cx, cy, arm, detail):
    """A cross. Below about 3 px of arm the strokes merge into a blob, so the
    small sizes get a disc instead."""
    if not detail:
        disc(d, cx, cy, arm * 0.7, CTRL)
        return
    t = arm * 0.42
    d.rectangle([cx - arm, cy - t, cx + arm, cy + t], fill=CTRL)
    d.rectangle([cx - t, cy - arm, cx + t, cy + arm], fill=CTRL)


def vita(d, cx, cy, w, detail=True):
    h = w * 0.45
    x0, y0, x1, y1 = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
    # Body. One rounded rectangle, corner radius just under half the height:
    # flat across the middle fifth-to-fifth, oval from there out, which is the
    # hardware's outline. Two overlapping shapes left a step where they met.
    d.rounded_rectangle([x0, y0, x1, y1], radius=h * 0.45, fill=BODY,
                        outline=RIM, width=max(1, int(w * 0.005)))

    # Screen, 16:9, centred, just over half the width.
    sw, sh = w * 0.572, h * 0.766
    d.rounded_rectangle([cx - sw / 2, cy - sh / 2, cx + sw / 2, cy + sh / 2],
                        radius=sh * 0.05, fill=SCREEN, outline=EDGE,
                        width=max(1, int(w * 0.004)))
    logo(d, cx, cy, sh * 0.60)

    # Controls. Fractions of w and h, off the photo.
    dpad(d, cx - w * 0.410, cy - h * 0.138, w * 0.048, detail)
    if detail:
        br, bo = w * 0.024, w * 0.046
        fx, fy = cx + w * 0.405, cy - h * 0.138
        for dx, dy in ((0, -bo), (-bo, 0), (bo, 0), (0, bo)):
            disc(d, fx + dx, fy + dy, br, CTRL)
    else:
        disc(d, cx + w * 0.405, cy - h * 0.138, w * 0.034, CTRL)

    sr = w * 0.042
    for sx in (cx - w * 0.378, cx + w * 0.379):
        disc(d, sx, cy + h * 0.128, sr, CTRL_HI)
        disc(d, sx, cy + h * 0.128, sr * 0.66, CTRL)


def canvas(w, h, vita_w, detail=True):
    im = Image.new("RGB", (w, h), BG)
    vita(ImageDraw.Draw(im), w / 2, h / 2, vita_w, detail)
    return im


out = "templates/vita-app/livearea"
# The icon is 128 px: the d-pad arms and face buttons land under a pixel there,
# so it gets the same silhouette with the controls simplified to discs.
canvas(128, 128, 120, detail=False).save(f"{out}/icon0.png")
canvas(840, 500, 660).save(f"{out}/bg0.png")
canvas(280, 158, 258).save(f"{out}/startup.png")
canvas(960, 544, 740).save("/tmp/art-preview.png")
print("written")
