#!/usr/bin/env python3
"""
Tether — app icon + menu-bar template generator.

Outputs
-------
1. A 1024x1024 app icon: a plain full-bleed SQUARE (no corner radius, fully
   opaque). The corner shape / mask is applied later, in Xcode.

2. Monochrome menu-bar "template" marks (black + alpha) in two STATES:
        connected    - the two links interlocked
        disconnected - identical geometry, but each link is SEVERED exactly
                       where it hooks through the other one: the break sits at
                       the connection, not at the outer surface, with a gap
                       2x the stroke width
   Both states share the exact same bounding box, stroke weight and positions,
   so the menu bar never shifts or resizes when the state flips - only the two
   breaks appear.

Design notes
------------
The weave is defined purely by SHAPE (real cut-outs), never by colour, so the
mark survives at 16px and in pure monochrome — which matters because macOS
tints menu-bar template images, so colour is never available to signal state.

Geometry constraint that keeps the weave clean:
    The "cut" region (halo of ring L AND band of ring R) must be two lobes that
    stay empty across the centre line V = 0, otherwise truncating the cut at
    V = 0 leaves a notch at the visual centre of the icon:
        required:  2 * (R - halfstroke) - d  >  gap

Usage:
    python3 make_icon.py [outdir]
"""

import sys
import os
import numpy as np
from PIL import Image, ImageFilter, ImageDraw, ImageFont

N = 1024
C = N / 2.0

# ---------------------------------------------------------------- base geometry
R = 220.0          # centre-line radius of each ring
HW = 37.0          # half stroke  (stroke = 74)
D = 320.0          # distance between ring centres, interlocked
GAP = 24.0         # weave gap: how far the "over" ring cuts into the "under" one
FEATHER = 1.0      # analytic antialias width, in px

BREAK_ARC = 2.0    # snap: half-arc of link R removed, in half-strokes
                   # (2 -> total gap = 2x stroke width)

TEMPLATE_BOX = 840.0   # both menu-bar states are scaled to this bounding box

# axis of the pair (x-axis rotated by -45deg): points up-and-right
UX, UY = 0.70710678, -0.70710678
# perpendicular (y-axis): points down-and-right
VX, VY = 0.70710678, 0.70710678


def bbox_for(d, r, hw):
    """Axis-aligned bounding box of the two-ring arrangement (always square)."""
    return d * 0.70710678 + 2 * (r + hw)


# ---------------------------------------------------------------- primitives
def band(d, radius, halfwidth, feather=FEATHER):
    """Antialiased annulus: 1 where |d - radius| <= halfwidth."""
    t = np.abs(d - radius)
    return np.clip((halfwidth + feather - t) / (2 * feather), 0.0, 1.0).astype(np.float32)


def half_plane(v, sign, feather=FEATHER):
    """Soft 0/1 selector: 1 where sign*v > 0 (sign = +1 selects v > 0)."""
    return np.clip(sign * v / (2 * feather) + 0.5, 0.0, 1.0).astype(np.float32)


def ramp(t, stops):
    """t in [0,1] -> RGB floats in [0,1] from colour stops [(pos, (r,g,b)), ...] (0-255)."""
    pos = np.array([s[0] for s in stops], dtype=np.float64)
    cols = np.array([s[1] for s in stops], dtype=np.float64) / 255.0
    out = np.empty(t.shape + (3,), dtype=np.float64)
    for i in range(3):
        out[..., i] = np.interp(t, pos, cols[:, i])
    return out


def flat(rgb):
    """Constant colour (0-255 tuple) as a normalised 0..1 RGB plane."""
    return np.full((N, N, 3), np.array(rgb, dtype=np.float64) / 255.0)


def resize_rgba(img, size):
    """LANCZOS resize that doesn't smear transparent pixels into the artwork."""
    a = np.asarray(img, dtype=np.float64) / 255.0
    pm = a[..., :3] * a[..., 3:4]
    pmi = Image.fromarray(np.clip(pm * 255, 0, 255).astype(np.uint8), "RGB").resize(size, Image.LANCZOS)
    ai = Image.fromarray(np.clip(a[..., 3] * 255, 0, 255).astype(np.uint8), "L").resize(size, Image.LANCZOS)
    pmn = np.asarray(pmi, dtype=np.float64) / 255.0
    an = np.asarray(ai, dtype=np.float64) / 255.0
    rgb = np.divide(pmn, an[..., None], out=np.zeros_like(pmn), where=an[..., None] > 1e-4)
    out = np.dstack([np.clip(rgb, 0, 1), np.clip(an, 0, 1)]) * 255.0
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def radial(cx, cy, r, falloff=1.0):
    """1 at centre, 0 at radius r (smooth)."""
    dd = np.hypot(X - cx, Y - cy) / r
    return (np.clip(1.0 - dd, 0.0, 1.0) ** falloff).astype(np.float32)


def vertical_band(top, bottom):
    """1 between y=top and y=bottom with a soft fade to `bottom`."""
    return np.clip((bottom - Y) / (bottom - top), 0.0, 1.0).astype(np.float32)


def blur(arr, radius):
    img = Image.fromarray(np.clip(arr * 255.0, 0, 255).astype(np.uint8), "L")
    img = img.filter(ImageFilter.GaussianBlur(radius))
    return np.asarray(img, dtype=np.float32) / 255.0


def over(dst, src_rgb, src_a):
    a = src_a[..., None]
    return dst * (1.0 - a) + src_rgb * a


def screen(dst, src_rgb, src_a):
    s = src_rgb * src_a[..., None]
    return 1.0 - (1.0 - dst) * (1.0 - s)


# ---------------------------------------------------------------- coordinates
yy, xx = np.mgrid[0:N, 0:N]
X = (xx + 0.5).astype(np.float32)
Y = (yy + 0.5).astype(np.float32)

U = (X - C) * UX + (Y - C) * UY
V = (X - C) * VX + (Y - C) * VY


# ---------------------------------------------------------------- mark builder
def arc_notch(cx, cy, theta, half_arc, r):
    """
    1 everywhere, except over an angular bite of arc-length 2*half_arc taken out
    of a ring of centre-line radius r about (cx, cy), centred on direction theta.
    """
    ang = np.arctan2(Y - cy, X - cx)
    da = np.angle(np.exp(1j * (ang - theta)))      # wrapped to (-pi, pi]
    arc = np.abs(da) * r
    # 0 inside the bite, 1 outside it
    return np.clip((arc - half_arc + FEATHER) / (2 * FEATHER), 0.0, 1.0).astype(np.float32)


def build_mark(r, hw, d, gap, broken=False):
    """
    Two rings at ±d/2 along the U axis, woven: ring L is over in the upper
    lobe (V < 0), ring R is over in the lower lobe (V > 0).

    broken=True severs each link exactly where it hooks through the other one,
    i.e. at the connection point (each ring's tip facing its neighbour), with a
    gap BREAK_ARC half-strokes wide. Both cuts lie on the chain axis, so the
    bounding box is untouched.

    Returns (mark, visL, visR, castL, castR).
    """
    cl = (C - d / 2 * UX, C - d / 2 * UY)
    cr = (C + d / 2 * UX, C + d / 2 * UY)
    dl = np.hypot(X - cl[0], Y - cl[1])
    dr = np.hypot(X - cr[0], Y - cr[1])

    ringL, ringR = band(dl, r, hw), band(dr, r, hw)
    haloL, haloR = band(dl, r, hw + gap), band(dr, r, hw + gap)

    if broken:
        # each link is severed at the connection: the arc of that ring which
        # reaches through the other link's hole. Both cuts sit on the chain axis.
        keepL = arc_notch(cl[0], cl[1], -np.pi / 4, hw * BREAK_ARC, r)
        keepR = arc_notch(cr[0], cr[1], 3 * np.pi / 4, hw * BREAK_ARC, r)
        ringL, haloL = ringL * keepL, haloL * keepL
        ringR, haloR = ringR * keepR, haloR * keepR

    # only meaningful when the two rings actually cross
    if d < (r + hw + gap) + (r + hw):
        assert 2 * (r - hw) - d > gap, "weave lobes would pinch shut at the centre"

    low = half_plane(V, -1.0)      # V < 0 -> ring L passes OVER
    high = half_plane(V, +1.0)     # V > 0 -> ring R passes OVER

    visL = ringL * (1.0 - haloR * high)
    visR = ringR * (1.0 - haloL * low)
    mark = np.maximum(visL, visR)

    # contact shadows: what makes the weave read as 3D in colour
    castL = blur(haloL * low, 13.0)
    castR = blur(haloR * high, 13.0)
    return mark, visL, visR, castL, castR


def mono(mark, color):
    """Mark as RGBA at a flat colour (0-255) — alpha carries the whole shape."""
    rgb = np.zeros((N, N, 3), dtype=np.float64)
    rgb[..., 0], rgb[..., 1], rgb[..., 2] = color
    return np.dstack([rgb, mark * 255.0]).astype(np.uint8)


# ---------------------------------------------------------------- the app icon
def build_icon():
    mark, visL, visR, castL, castR = build_mark(R, HW, D, GAP)
    half_u = (D + 2 * (R + HW)) / 2.0

    # --- background: deep navy running corner to corner
    diag = np.clip((X / N) * 0.62 + (Y / N) * 0.38, 0.0, 1.0)
    bg = ramp(diag, [
        (0.00, (18, 32, 92)),      # top-left
        (0.45, (9, 17, 48)),
        (1.00, (2, 4, 14)),        # bottom-right
    ])
    bg = screen(bg, flat((46, 108, 255)), radial(0.38 * N, 0.33 * N, 0.80 * N, 1.6) * 0.26)
    bg = screen(bg, flat((0, 200, 255)), radial(0.66 * N, 0.68 * N, 0.52 * N, 1.9) * 0.09)
    bg = screen(bg, np.ones((N, N, 3)), vertical_band(0.0, 0.16 * N) * 0.07)

    # vignette — also keeps the corners dark once a mask is applied later
    r_from_c = np.hypot(X - C, Y - C) / (0.72 * N)
    vig = np.clip((r_from_c - 1.0) / 0.55, 0.0, 1.0)
    bg *= (1.0 - 0.42 * vig)[..., None]

    # --- mark colour: blue (lower-left) -> ice (upper-right)
    t = np.clip((U + half_u) / (2 * half_u), 0.0, 1.0)
    mark_rgb = ramp(t, [
        (0.00, (30, 78, 236)),
        (0.30, (33, 120, 255)),
        (0.58, (40, 178, 255)),
        (0.82, (76, 226, 255)),
        (1.00, (158, 247, 255)),
    ])
    spec = radial(0.34 * N, 0.28 * N, 0.62 * N, 1.6)
    shade = radial(0.70 * N, 0.74 * N, 0.60 * N, 1.4)
    mark_rgb = mark_rgb * (1.0 - 0.30 * shade[..., None]) + np.ones((N, N, 3)) * (spec * 0.34)[..., None]
    mark_rgb = np.clip(mark_rgb, 0.0, 1.0)

    # --- composite
    comp = bg.copy()

    sh = blur(mark, 22)
    sh = np.asarray(Image.fromarray((sh * 255).astype(np.uint8), "L")
                    .transform((N, N), Image.AFFINE, (1, 0, 0, 0, 1, -11)),
                    dtype=np.float32) / 255.0
    comp *= (1.0 - (sh * 0.58)[..., None])

    comp = screen(comp, flat((70, 214, 255)), blur(mark, 52) * 0.44)
    comp = screen(comp, flat((60, 130, 255)), blur(mark, 130) * 0.18)

    underL = mark_rgb * (1.0 - 0.60 * castR[..., None])
    underR = mark_rgb * (1.0 - 0.60 * castL[..., None])
    tot = np.maximum(visL + visR, 1e-6)[..., None]
    mark_col = (underL * visL[..., None] + underR * visR[..., None]) / tot
    comp = over(comp, mark_col, np.clip(visL + visR, 0.0, 1.0))

    # plain opaque square — the corner shape is applied later, in Xcode
    rgba = np.dstack([np.clip(comp, 0, 1) * 255.0, np.full((N, N), 255.0)]).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


# ---------------------------------------------------------------- entry point
def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    os.makedirs(outdir, exist_ok=True)
    p = lambda *a: os.path.join(outdir, *a)

    icon = build_icon()
    icon.save(p("Tether-Icon-1024.png"))
    resize_rgba(icon, (512, 512)).save(p("Tether-Icon-512.png"))

    # --- menu bar states: identical geometry, one link snapped
    k = TEMPLATE_BOX / bbox_for(D, R, HW)
    states = {
        "Connected": build_mark(R * k, HW * k, D * k, GAP * k)[0],
        "Disconnected": build_mark(R * k, HW * k, D * k, GAP * k, broken=True)[0],
    }

    for name, m in states.items():
        Image.fromarray(mono(m, (0, 0, 0)), "RGBA").save(p(f"Tether-Template-{name}-1024.png"))
        Image.fromarray(mono(m, (255, 255, 255)), "RGBA").save(p(f"Tether-Template-{name}-White-1024.png"))
        blk = Image.fromarray(mono(m, (0, 0, 0)), "RGBA")
        for s in (44, 36, 32, 22, 18):
            resize_rgba(blk, (s, s)).save(p(f"Tether-Menubar-{name}-{s}.png"))

    build_preview(icon, states, p("preview.png"))
    print("wrote icon + both menu-bar states to", outdir)
    print(f"  template scale {k:.4f}  (stroke {2 * HW * k:.1f}px, "
          f"snap gap {2 * BREAK_ARC * HW * k:.0f}px = {BREAK_ARC:.0f}x stroke)")


# ---------------------------------------------------------------- contact sheet
def build_preview(icon, states, path):
    W, H = 1180, 764
    sheet = Image.new("RGB", (W, H), (245, 245, 247))
    d = ImageDraw.Draw(sheet)
    try:
        fs = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 12)
        fb = ImageFont.truetype("/System/Library/Fonts/SFNSBold.ttf", 14)
    except Exception:
        fs = fb = ImageFont.load_default()

    def label(x, y, s, font=None, fill=(120, 120, 126)):
        d.text((x, y), s, font=font or fs, fill=fill)

    tmpl = {k: Image.fromarray(mono(v, (0, 0, 0)), "RGBA") for k, v in states.items()}
    tmpl_w = {k: Image.fromarray(mono(v, (255, 255, 255)), "RGBA") for k, v in states.items()}
    col = lambda s: resize_rgba(icon, (s, s))

    def strip(items, x0, ymid, gap, make):
        x = x0
        for s in items:
            im = make(s)
            sheet.paste(im, (x, int(ymid - im.size[1] / 2)), im)
            x += im.size[0] + gap
        return x

    # ---- row 1: colour icon on a light wallpaper
    label(24, 14, "APP ICON  /  full colour  /  1024x1024 square, opaque", fb, (36, 36, 42))
    d.rectangle([0, 34, W, 272], fill=(246, 246, 249))
    x = 30
    for s in (184, 128, 64, 32, 16):
        im = col(s)
        sheet.paste(im, (x, 150 - s // 2), im)
        label(x, 248, f"{s}px", fs)
        x += s + 46

    # ---- row 2: dark UI + white template states
    label(24, 290, "DARK UI  /  menu bar template (white + alpha)", fb, (36, 36, 42))
    d.rectangle([0, 310, W, 494], fill=(26, 26, 30))
    x = 30
    for s in (128, 64, 32, 16):
        im = col(s)
        sheet.paste(im, (x, 402 - s // 2), im)
        x += s + 52
    d.line([(x + 8, 330), (x + 8, 474)], fill=(66, 66, 72), width=1)
    x += 36
    for name in ("Connected", "Disconnected"):
        x0 = x
        x = strip((36, 26, 18), x, 396, 26, lambda s, n=name: resize_rgba(tmpl_w[n], (s, s)))
        label(x0, 444, name.lower(), fs, (152, 152, 158))
        x += 24
    label(x + 6, 356, "same geometry,\nlinks cut at\nthe connection", fs, (152, 152, 158))

    # ---- row 3: both states, monochrome, on white
    label(24, 514, "MENU BAR STATES  /  pure shape, no colour available to signal state", fb, (36, 36, 42))
    d.rectangle([0, 534, W, 758], fill=(255, 255, 255))
    for i, name in enumerate(("Connected", "Disconnected")):
        x0 = 30 + i * 560
        x = strip((96, 48, 32, 24, 16), x0, 604, 44,
                  lambda s, n=name: resize_rgba(tmpl[n], (s, s)))
        label(x0, 668, name, fs)
        if i == 0:
            d.line([(x + 14, 556), (x + 14, 714)], fill=(224, 224, 228), width=1)

    sheet.save(path)


if __name__ == "__main__":
    main()
