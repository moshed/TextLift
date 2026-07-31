#!/usr/bin/env python3
"""Generate TextLift's app icon and the full macOS icon set.

House style (see /Users/moshe/Apps/CLAUDE.md): 1024x1024 full bleed, vertical
gradient lighter-at-top, one hue family, a single centred flat glyph, 2-4 colors,
no gradients inside the glyph, no thin lines.

Glyph: scan-frame corner brackets around three text bars — "lift the text inside
this box". Teal, which no other app in the lineup uses.
"""
import os
from PIL import Image, ImageDraw

S = 1024
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "TextLift/Assets.xcassets/AppIcon.appiconset")
os.makedirs(OUT, exist_ok=True)

TOP = (44, 196, 194)      # light teal
BOTTOM = (11, 88, 116)    # deep teal
BRACKET = (255, 255, 255)
BAR = (255, 196, 61)      # amber, the one accent

img = Image.new("RGB", (S, S), TOP)
d = ImageDraw.Draw(img)

# vertical gradient, lighter at the top
for y in range(S):
    t = y / (S - 1)
    d.line([(0, y), (S, y)],
           fill=tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)))

# --- scan-frame corner brackets --------------------------------------------
INSET = 176          # distance from each edge to the outer bracket edge
ARM = 172            # how far each arm runs along the edge
TH = 50              # stroke thickness
R = TH // 2          # rounded cap radius

lo, hi = INSET, S - INSET


def bar(x0, y0, x1, y1, radius, fill):
    d.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=fill)


for (cx, sx) in ((lo, 1), (hi, -1)):
    for (cy, sy) in ((lo, 1), (hi, -1)):
        # horizontal arm
        x_a, x_b = sorted((cx, cx + sx * ARM))
        y_a, y_b = sorted((cy, cy + sy * TH))
        bar(x_a, y_a, x_b, y_b, R, BRACKET)
        # vertical arm
        x_a, x_b = sorted((cx, cx + sx * TH))
        y_a, y_b = sorted((cy, cy + sy * ARM))
        bar(x_a, y_a, x_b, y_b, R, BRACKET)

# --- text bars inside the frame --------------------------------------------
# Left-aligned with a ragged right edge, so it reads as lines of text rather
# than as a centred "sort" glyph.
BAR_H = 58
GAP = 48
WIDTHS = (410, 344, 250)
total = len(WIDTHS) * BAR_H + (len(WIDTHS) - 1) * GAP
x0 = (S - max(WIDTHS)) // 2
y = (S - total) // 2
for w in WIDTHS:
    bar(x0, y, x0 + w, y + BAR_H, BAR_H // 2, BAR)
    y += BAR_H + GAP

img.save(os.path.join(OUT, "icon_1024x1024.png"))

# --- the macOS icon set ----------------------------------------------------
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
         (256, 1), (256, 2), (512, 1), (512, 2)]

entries = []
for pt, scale in SIZES:
    px = pt * scale
    name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
    img.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
    entries.append(f'''    {{
      "filename" : "{name}",
      "idiom" : "mac",
      "scale" : "{scale}x",
      "size" : "{pt}x{pt}"
    }}''')

with open(os.path.join(OUT, "Contents.json"), "w") as f:
    f.write('{\n  "images" : [\n' + ",\n".join(entries) +
            '\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')

with open(os.path.join(os.path.dirname(OUT), "Contents.json"), "w") as f:
    f.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')

print(f"wrote {len(SIZES) + 1} PNGs + Contents.json to {OUT}")
