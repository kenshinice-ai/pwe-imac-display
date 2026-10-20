#!/usr/bin/env python3
"""PWE iMac Display brand assets, drawn from numbers. Nothing here is traced by hand.

    <venv>/bin/python -I pwe/brand/make.py [--brand-source <01 BRAND ASSETS/source>]

Writes, next to this file:
  menubar/PWEMenuBarReady.imageset     menu-bar template: the iMac, screen dark  (not showing)
  menubar/PWEMenuBarShowing.imageset   menu-bar template: the iMac, screen lit   (it is a display)
  menubar/png/*.png                    the same at 1x and 2x, for review only
  receiver/receiver-wing.pdf           the calm wing the receiver draws on its idle screen
  dmg/background.png, background@2x.png  the disk-image window (dmgbuild joins them into one TIFF)

Needs cairosvg (and the system cairo library). The receiver wing needs
`wing_gen.py` from 01 BRAND ASSETS/source; its geometry is generated, never edited
(brand standard 08 §3). The outputs are committed, so packaging needs none of this.

Brand standard: 00 PLANNING 2026/08-品牌识别标准.md. Product rules: docs/pwe/BRAND-iMac-Display-2026-10-20.md.
"""
import argparse
import json
import os
import sys

import cairosvg

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BRAND = os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "01 BRAND ASSETS", "source"))

# Armature tokens (01 BRAND ASSETS/tokens/armature.json), light mode unless noted.
PAPER = "#F7F5F2"          # ground
INK = "#0C0A09"            # label
LABEL3 = (0x0C, 0x0A, 0x09, 0.36)   # glyph tint, never text
LINE = (0x0C, 0x0A, 0x09, 0.10)


def rgba(c):
    r, g, b, a = c
    return "rgba(%d,%d,%d,%.2f)" % (r, g, b, a)


def svg_doc(w, h, body, unit=""):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%s%s" height="%s%s" viewBox="0 0 %s %s">%s</svg>'
            % (w, unit, h, unit, w, h, body))


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


# --------------------------------------------------------------- menu bar
#
# One object in every state: the 27-inch iMac of 2014-2017 seen from the front,
# its aluminium chin solid, as SF Symbols' `desktopcomputer` draws it. "Showing"
# lights the screen (an inset fill); it never swaps to another object. 18 pt
# canvas, glyph 16 x 14 pt, 1 pt frame, 2 pt chin; the frame's edges sit on whole
# points so 1x and 2x are both crisp. Template images: black plus alpha, macOS tints them.

def imac_glyph(showing):
    body = "M3,2 H15 A2,2 0 0 1 17,4 V13 H1 V4 A2,2 0 0 1 3,2 Z"          # body to the chin's foot
    panel = "M3,3 H15 A1,1 0 0 1 16,4 V11 H2 V4 A1,1 0 0 1 3,3 Z"         # screen opening; chin 2 pt
    foot = "M7.5,13 H10.5 L11.5,16 H6.5 Z"
    parts = ['<path fill="#000" fill-rule="evenodd" d="%s %s"/>' % (body, panel),
             '<path fill="#000" d="%s"/>' % foot]
    if showing:
        parts.append('<rect fill="#000" x="3" y="4" width="12" height="6" rx="0.5"/>')
    return svg_doc(18, 18, "".join(parts), unit="pt")


def menubar():
    out = os.path.join(HERE, "menubar")
    for name, showing in (("PWEMenuBarReady", False), ("PWEMenuBarShowing", True)):
        svg = imac_glyph(showing)
        iset = os.path.join(out, name + ".imageset")
        write(os.path.join(iset, name + ".pdf"), cairosvg.svg2pdf(bytestring=svg.encode()))
        contents = {
            "images": [{"filename": name + ".pdf", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
        }
        write(os.path.join(iset, "Contents.json"), (json.dumps(contents, indent=2) + "\n").encode())
        for scale, suffix in ((1, ""), (2, "@2x")):
            write(os.path.join(out, "png", name + suffix + ".png"),
                  cairosvg.svg2png(bytestring=svg.encode(), output_width=18 * scale, output_height=18 * scale))


# --------------------------------------------------------------- receiver
#
# The receiver's idle screen shows the house mark, calm: one colour (label on
# the night ground, #F7F5F2), solid weight (08 §4.1: screens and hero sizes),
# still. 144 pt wide in the design unit of display.c (min_side / 720).

def receiver(brand_source):
    sys.path.insert(0, brand_source)
    import wing_gen as W   # noqa: E402  (01 BRAND ASSETS/source)
    paths, _tips, _angs, _top, bb = W.build(W.SOLID)
    bw, bh = bb[2] - bb[0], bb[3] - bb[1]
    width = 144.0
    height = width * bh / bw
    feathers = "".join('<path d="%s"/>' % paths[4 - i] for i in range(5))   # longest first (08 §4.2)
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="%.3fpt" height="%.3fpt" viewBox="%f %f %f %f">'
           '<g fill="%s">%s</g></svg>' % (width, height, bb[0], bb[1], bw, bh, PAPER, feathers))
    write(os.path.join(HERE, "receiver", "receiver-wing.pdf"), cairosvg.svg2pdf(bytestring=svg.encode()))
    write(os.path.join(HERE, "receiver", "receiver-wing.svg"), svg.encode())


# --------------------------------------------------------------- disk image
#
# 640 x 400 pt, paper ground: Finder draws icon labels in its light style on any
# window with a background picture, so the picture is designed for light.
# No words: the two apps go to two computers, and the picture says which with
# two pictograms and the cable between them. Finder's own labels name the files.
# Icon centres (keep in step with dmg/settings.py):
#   sender (150,190) -> Applications (330,190)   receiver (530,190)
#   read me (150,322)  licences (330,322)

DMG_W, DMG_H = 640, 400
ICONS = {"sender": (150, 190), "apps": (330, 190), "receiver": (530, 190), "readme": (150, 322), "licences": (330, 322)}


def laptop(cx, cy, w, stroke):
    # A MacBook, open, from the front: screen with a thin bezel, then the base, wider and flat.
    sw, sh = w * 0.78, w * 0.78 * 0.64
    x, y = cx - sw / 2, cy - sh / 2 - w * 0.03
    base_w, base_h = w, w * 0.045
    return ('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f" fill="none" stroke-width="%.2f"/>'
            '<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f" stroke="none"/>'
            % (x, y, sw, sh, w * 0.04, stroke, cx - base_w / 2, y + sh + stroke * 0.5, base_w, base_h, base_h / 2))


def imac(cx, cy, w, stroke):
    # The same silhouette as the menu-bar glyph and the proposed icon: body 650 x 450, chin 19 %.
    bh = w * 450 / 650
    x, y = cx - w / 2, cy - bh / 2 - w * 0.06
    chin = y + bh * (1 - 0.19)
    foot_t, foot_b, foot_h = w * 0.13, w * 0.20, w * 0.12
    return ('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f" fill="none" stroke-width="%.2f"/>'
            '<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke-width="%.2f"/>'
            '<path stroke="none" d="M%.2f,%.2f H%.2f L%.2f,%.2f H%.2f Z"/>'
            % (x, y, w, bh, w * 0.045, stroke, x, chin, x + w, chin, stroke,
               cx - foot_t / 2, y + bh + stroke / 2, cx + foot_t / 2, cx + foot_b / 2, y + bh + stroke / 2 + foot_h, cx - foot_b / 2))


def dmg_background():
    glyph = rgba(LABEL3)
    s = 2.0                                        # pictogram stroke, pt
    sx, sy = ICONS["sender"]
    ax, _ = ICONS["apps"]
    rx, ry = ICONS["receiver"]
    top = 74                                       # pictogram centre line
    mid_left = (sx + ax) / 2
    parts = ['<rect width="%d" height="%d" fill="%s"/>' % (DMG_W, DMG_H, PAPER)]
    # The two computers, each over what goes on it.
    parts.append('<g fill="%s" stroke="%s">%s%s</g>' % (glyph, glyph, laptop(mid_left, top, 92, s), imac(rx, top, 84, s)))
    # The cable between them: one Thunderbolt cable, drawn as a plain dashed line.
    parts.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%.1f" stroke-dasharray="1 6" stroke-linecap="round"/>'
                 % (mid_left + 56, top + 22, rx - 56, top + 22, glyph, s))
    # Drag to install: a plain arrow from the sender to Applications.
    a0, a1, ay = sx + 50, ax - 50, sy - 6
    parts.append('<g fill="none" stroke="%s" stroke-width="%.1f" stroke-linecap="round" stroke-linejoin="round">'
                 '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f"/><polyline points="%.1f,%.1f %.1f,%.1f %.1f,%.1f"/></g>'
                 % (glyph, s, a0, ay, a1, ay, a1 - 9, ay - 9, a1, ay, a1 - 9, ay + 9))
    # The two computers' halves, and the papers below.
    parts.append('<line x1="440" y1="132" x2="440" y2="266" stroke="%s" stroke-width="1"/>' % rgba(LINE))
    parts.append('<line x1="72" y1="272" x2="568" y2="272" stroke="%s" stroke-width="1"/>' % rgba(LINE))
    svg = svg_doc(DMG_W, DMG_H, "".join(parts))
    for scale, suffix in ((1, ""), (2, "@2x")):
        write(os.path.join(HERE, "dmg", "background%s.png" % suffix),
              cairosvg.svg2png(bytestring=svg.encode(), output_width=DMG_W * scale, output_height=DMG_H * scale))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--brand-source", default=DEFAULT_BRAND,
                    help="01 BRAND ASSETS/source, for wing_gen.py (default: %(default)s)")
    args = ap.parse_args()
    menubar()
    dmg_background()
    if os.path.exists(os.path.join(args.brand_source, "wing_gen.py")):
        receiver(args.brand_source)
    else:
        print("skipped receiver/receiver-wing.pdf: no wing_gen.py in %s" % args.brand_source, file=sys.stderr)
    print("wrote menubar/, dmg/, receiver/ in %s" % HERE)


if __name__ == "__main__":
    main()
