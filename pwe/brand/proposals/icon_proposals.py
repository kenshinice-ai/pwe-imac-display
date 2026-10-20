"""Icon proposals for PWE iMac Display, rendered for review. Not the shipping generator:
that is pwe/icon/main.swift, and it changes only after Lee approves (BRAND doc, spec R6).

    <venv with cairosvg, pillow>/bin/python -I icon_proposals.py "<01 BRAND ASSETS/source>" <out dir>

Kinds: now (today's geometry), s1 (sender: 16:9 screen + chin), rE (receiver: paper frame),
rA (receiver: paper tile, rejected). Writes icon-<kind>.svg / -1024.png and two contact sheets.
"""
import io, sys
sys.path.insert(0, sys.argv[1])          # 01 BRAND ASSETS/source
OUT = sys.argv[2]
import wing_gen as W
import cairosvg
from PIL import Image

NAVY, AMBER, PAPER, INK, DEEP = "#0E1729", "#F5B335", "#F7F5F2", "#0C0A09", "#A16207"

def wing(weight, x, y, w, fills):
    paths, _t, _a, _top, bb = W.build(weight)
    s = w / (bb[2] - bb[0])
    tr = "translate(%.3f,%.3f) scale(%.5f)" % (x - bb[0] * s, y - bb[1] * s, s)
    out = []
    for n in range(1, 6):                 # brand feather 1 = top/longest = generator index 4
        out.append('<path fill="%s" d="%s"/>' % (fills[n - 1], paths[5 - n]))
    return '<g transform="%s">%s</g>' % (tr, "".join(out)), (bb[2] - bb[0]) / (bb[3] - bb[1])

def icon(kind, side=1024):
    """kind: now | s1 (sender, iMac 16:9 + chin) | rA (receiver, paper) | rE (receiver, paper outline)"""
    pad = side * 0.085
    P = side - 2 * pad
    cx, cy = side / 2, side / 2
    ground, line, wfill = NAVY, AMBER, [AMBER] * 5
    if kind == "rA":
        ground, line, wfill = PAPER, INK, [DEEP] + [INK] * 4
    if kind == "rE":
        line = PAPER
    body = ['<rect x="%f" y="%f" width="%f" height="%f" rx="%f" fill="%s"/>' % (pad, pad, P, P, P * 0.2237, ground)]
    if kind == "now":
        mw = P * 0.60
        g, ar = wing(W.LINE, cx - mw / 2, cy - mw / ar_line / 2, mw, wfill)
        sw, sh, r, lw = P * 0.80, P * 0.54, P * 0.055, max(P * 0.018, 1)
        sx, sy = cx - sw / 2, cy - sh / 2
        body.append('<rect x="%f" y="%f" width="%f" height="%f" rx="%f" fill="none" stroke="%s" stroke-width="%f"/>' % (sx, sy, sw, sh, r, line, lw))
        nt = sy + sh + lw / 2
        nh, ntw, nbw = P * 0.085, P * 0.10, P * 0.14
        body.append('<path fill="%s" d="M%f,%f L%f,%f L%f,%f L%f,%f Z"/>' % (line, cx - ntw/2, nt, cx + ntw/2, nt, cx + nbw/2, nt + nh, cx - nbw/2, nt + nh))
        body.append(g)
    else:
        # The 27-inch iMac (2014-2017) front: a 16:9 panel inside a thin bezel, an aluminium
        # chin, a tapered foot. Proportions from the real machine: body 650 x 474 mm with
        # a 597 x 336 mm panel; chin about 100 mm. Drawn as one outline + a solid chin line.
        bw = P * 0.80                      # body width
        bh = bw * 450 / 650                # body height incl. chin, stand excluded (650 x 450 mm)
        lw = P * 0.024
        r = P * 0.045
        top = cy - (bh + P * 0.07) / 2 - P * 0.01
        bx = cx - bw / 2
        body.append('<rect x="%f" y="%f" width="%f" height="%f" rx="%f" fill="none" stroke="%s" stroke-width="%f"/>' % (bx, top, bw, bh, r, line, lw))
        chin_y = top + bh - bh * CHIN      # the chin's top edge
        body.append('<rect x="%f" y="%f" width="%f" height="%f" fill="%s"/>' % (bx, chin_y - lw / 2, bw, lw, line))
        # foot: tapered neck
        nt = top + bh + lw / 2
        nh, ntw, nbw = P * 0.07, P * 0.12, P * 0.17
        body.append('<path fill="%s" d="M%f,%f L%f,%f L%f,%f L%f,%f Z"/>' % (line, cx - ntw/2, nt, cx + ntw/2, nt, cx + nbw/2, nt + nh, cx - nbw/2, nt + nh))
        # wing centred in the panel area
        panel_top, panel_bot = top + lw, chin_y - lw
        mw = bw * 0.66
        mh = mw / ar_line
        pcy = (panel_top + panel_bot) / 2
        g, _ = wing(W.LINE, cx - mw / 2, pcy - mh / 2, mw, wfill)
        body.append(g)
    svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d">%s</svg>' % (side, side, side, side, "".join(body))
    return svg

CHIN = 0.19
_p, _t, _a, _top, _bb = W.build(W.LINE)
ar_line = (_bb[2] - _bb[0]) / (_bb[3] - _bb[1])

def png(svg, px):
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(), output_width=px, output_height=px))).convert("RGBA")

if __name__ == "__main__":
    import os
    os.makedirs(OUT, exist_ok=True)
    kinds = ["now", "s1", "rE", "rA"]
    for k in kinds:
        open(os.path.join(OUT, "icon-%s.svg" % k), "w").write(icon(k))
        png(icon(k), 1024).save(os.path.join(OUT, "icon-%s-1024.png" % k))
    # comparison sheet: rows = kinds, columns = 256, 128, 64, 32, 16 actual + 16 at 6x
    for bg_name, bg in (("light", (236, 236, 236, 255)), ("dark", (40, 40, 44, 255))):
        sizes = [256, 128, 64, 32, 16]
        rowh = 276
        sheet = Image.new("RGBA", (256 + 128 + 64 + 32 + 16 + 96 + 7 * 24, rowh * len(kinds)), bg)
        for i, k in enumerate(kinds):
            x = 12
            for s in sizes:
                im = png(icon(k), s)
                sheet.alpha_composite(im, (x, i * rowh + 10 + (256 - s) // 2))
                x += s + 24
            z = png(icon(k), 16).resize((96, 96), Image.NEAREST)
            sheet.alpha_composite(z, (x, i * rowh + 10 + 80))
        sheet.save(os.path.join(OUT, "icon-sheet-%s.png" % bg_name))
