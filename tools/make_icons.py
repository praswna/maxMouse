#!/usr/bin/env python3
"""Generate simple placeholder icons for the maxMouse marking menu.

White glyphs on a transparent background, 32x32 PNG. They are intentionally
minimal — drop your own PNGs of the same names into ../icons/ to replace them.
Drawn at 4x and downscaled for cheap anti-aliasing.
"""
import math
import os
from PIL import Image, ImageDraw, ImageFont

S = 32           # final size
SS = 4           # supersample factor
W = S * SS
STROKE = 3 * SS
WHITE = (255, 255, 255, 255)
OUT = os.path.join(os.path.dirname(__file__), "..", "icons")


def canvas():
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def save(img, name):
    img = img.resize((S, S), Image.LANCZOS)
    img.save(os.path.join(OUT, name + ".png"))


def line(d, p, fill=WHITE, width=STROKE):
    d.line(p, fill=fill, width=width, joint="curve")


def arrowhead(d, tip, ang, size=7 * SS):
    a = math.radians(ang)
    for da in (140, -140):
        b = math.radians(ang + da)
        d.line([tip, (tip[0] + size * math.cos(a + math.radians(0)) * 0, tip[1])],
               fill=WHITE, width=STROKE)
        d.line([tip, (tip[0] + size * math.cos(b), tip[1] + size * math.sin(b))],
               fill=WHITE, width=STROKE)


def dot(d, c, r=4 * SS, fill=WHITE, outline=None):
    d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], fill=fill, outline=outline,
              width=STROKE if outline else 1)


def make_undo(mirror=False):
    img, d = canvas()
    box = [W * 0.28, W * 0.30, W * 0.72, W * 0.74]
    start, end = 30, 300
    d.arc(box, start=start, end=end, fill=WHITE, width=STROKE)
    a = math.radians(start)
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    rx, ry = (box[2] - box[0]) / 2, (box[3] - box[1]) / 2
    tip = (cx + rx * math.cos(a), cy + ry * math.sin(a))
    s = 6 * SS
    d.line([tip, (tip[0] - s, tip[1] - s)], fill=WHITE, width=STROKE)
    d.line([tip, (tip[0] + s, tip[1] - s)], fill=WHITE, width=STROKE)
    if mirror:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    return img


def make_letter(ch):
    img, d = canvas()
    size = int(W * 0.62)
    font = None
    for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                 "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"):
        if os.path.exists(path):
            font = ImageFont.truetype(path, size)
            break
    if font is None:
        font = ImageFont.load_default()
    bb = d.textbbox((0, 0), ch, font=font)
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    d.text(((W - w) / 2 - bb[0], (W - h) / 2 - bb[1]), ch, font=font, fill=WHITE)
    return img


def square(d, x0, y0, x1, y1, fill=None):
    d.rectangle([x0, y0, x1, y1], outline=WHITE, width=STROKE, fill=fill)


def main():
    os.makedirs(OUT, exist_ok=True)
    icons = {}

    icons["undo"] = make_undo(False)
    icons["redo"] = make_undo(True)

    # delete: X
    img, d = canvas(); m = W * 0.3
    line(d, [(m, m), (W - m, W - m)]); line(d, [(W - m, m), (m, W - m)])
    icons["delete"] = img

    # remove: minus
    img, d = canvas()
    line(d, [(W * 0.28, W * 0.5), (W * 0.72, W * 0.5)])
    icons["remove"] = img

    # zoom: magnifier
    img, d = canvas()
    d.ellipse([W * 0.26, W * 0.22, W * 0.62, W * 0.58], outline=WHITE, width=STROKE)
    line(d, [(W * 0.58, W * 0.54), (W * 0.78, W * 0.74)])
    icons["zoom"] = img

    # wireframe: triangle outline
    img, d = canvas()
    d.polygon([(W * 0.5, W * 0.24), (W * 0.78, W * 0.74), (W * 0.22, W * 0.74)],
              outline=WHITE, width=STROKE)
    icons["wireframe"] = img

    # edged: filled triangle with an inner edge
    img, d = canvas()
    pts = [(W * 0.5, W * 0.24), (W * 0.78, W * 0.74), (W * 0.22, W * 0.74)]
    d.polygon(pts, outline=WHITE, width=STROKE)
    line(d, [(W * 0.5, W * 0.24), (W * 0.5, W * 0.74)], width=2 * SS)
    icons["edged"] = img

    # hide: eye + slash ; unhide: eye
    def eye(slash):
        img, d = canvas()
        d.arc([W * 0.2, W * 0.28, W * 0.8, W * 0.72], start=200, end=340, fill=WHITE, width=STROKE)
        d.arc([W * 0.2, W * 0.28, W * 0.8, W * 0.72], start=20, end=160, fill=WHITE, width=STROKE)
        dot(d, (W * 0.5, W * 0.5), r=4 * SS)
        if slash:
            line(d, [(W * 0.24, W * 0.74), (W * 0.76, W * 0.26)])
        return img
    icons["hide"] = eye(True)
    icons["unhide"] = eye(False)

    # weld: two dots + arrow to one
    img, d = canvas()
    dot(d, (W * 0.28, W * 0.32), r=4 * SS, fill=None, outline=WHITE)
    dot(d, (W * 0.28, W * 0.68), r=4 * SS, fill=None, outline=WHITE)
    dot(d, (W * 0.72, W * 0.5), r=5 * SS)
    line(d, [(W * 0.36, W * 0.36), (W * 0.64, W * 0.48)], width=2 * SS)
    line(d, [(W * 0.36, W * 0.64), (W * 0.64, W * 0.52)], width=2 * SS)
    icons["weld"] = img

    # break: one dot splitting into two with gap
    img, d = canvas()
    dot(d, (W * 0.3, W * 0.5), r=4 * SS, fill=None, outline=WHITE)
    dot(d, (W * 0.7, W * 0.32), r=4 * SS, fill=None, outline=WHITE)
    dot(d, (W * 0.7, W * 0.68), r=4 * SS, fill=None, outline=WHITE)
    icons["break"] = img

    # connect: two dots joined by a line
    img, d = canvas()
    line(d, [(W * 0.3, W * 0.5), (W * 0.7, W * 0.5)])
    dot(d, (W * 0.3, W * 0.5)); dot(d, (W * 0.7, W * 0.5))
    icons["connect"] = img

    # chamfer: square with a cut corner
    img, d = canvas()
    d.line([(W * 0.28, W * 0.28), (W * 0.6, W * 0.28)], fill=WHITE, width=STROKE)
    d.line([(W * 0.6, W * 0.28), (W * 0.72, W * 0.4)], fill=WHITE, width=STROKE)
    d.line([(W * 0.72, W * 0.4), (W * 0.72, W * 0.72)], fill=WHITE, width=STROKE)
    d.line([(W * 0.72, W * 0.72), (W * 0.28, W * 0.72)], fill=WHITE, width=STROKE)
    d.line([(W * 0.28, W * 0.72), (W * 0.28, W * 0.28)], fill=WHITE, width=STROKE)
    icons["chamfer"] = img

    # collapse: 4 arrows pointing inward
    img, d = canvas(); c = W * 0.5
    for dx, dy in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        x0, y0 = c + dx * W * 0.26, c + dy * W * 0.26
        x1, y1 = c + dx * W * 0.08, c + dy * W * 0.08
        line(d, [(x0, y0), (x1, y1)])
    icons["collapse"] = img

    # cut: knife / diagonal with small blade
    img, d = canvas()
    line(d, [(W * 0.24, W * 0.76), (W * 0.76, W * 0.24)])
    d.polygon([(W * 0.76, W * 0.24), (W * 0.62, W * 0.26), (W * 0.74, W * 0.38)], fill=WHITE)
    icons["cut"] = img

    # extrude: square with up arrow
    img, d = canvas()
    square(d, W * 0.3, W * 0.52, W * 0.7, W * 0.74)
    line(d, [(W * 0.5, W * 0.5), (W * 0.5, W * 0.24)])
    d.line([(W * 0.5, W * 0.24), (W * 0.42, W * 0.34)], fill=WHITE, width=STROKE)
    d.line([(W * 0.5, W * 0.24), (W * 0.58, W * 0.34)], fill=WHITE, width=STROKE)
    icons["extrude"] = img

    # bevel: trapezoid
    img, d = canvas()
    d.polygon([(W * 0.36, W * 0.34), (W * 0.64, W * 0.34), (W * 0.76, W * 0.7), (W * 0.24, W * 0.7)],
              outline=WHITE, width=STROKE)
    icons["bevel"] = img

    # inset: square within a square
    img, d = canvas()
    square(d, W * 0.24, W * 0.24, W * 0.76, W * 0.76)
    square(d, W * 0.36, W * 0.36, W * 0.64, W * 0.64)
    icons["inset"] = img

    # detach: two separated squares
    img, d = canvas()
    square(d, W * 0.2, W * 0.28, W * 0.46, W * 0.6)
    square(d, W * 0.56, W * 0.42, W * 0.82, W * 0.74)
    icons["detach"] = img

    for name, img in icons.items():
        save(img, name)
    print("wrote %d icons to %s" % (len(icons), os.path.normpath(OUT)))


if __name__ == "__main__":
    main()
