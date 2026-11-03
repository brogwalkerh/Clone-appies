#!/usr/bin/env python3
"""Regenerates the SVG layers of the app icon (App/Resources/AppIcon.icon/Assets).

The icon is an Icon Composer bundle (PLAN.md §4): icon.json sets the fill and
the Liquid Glass groups; this script draws the three white layers on a
1024 x 1024 canvas: the feather vane, its quill, and a sparkle. macOS derives
the dark, tinted and clear appearances from them.

Usage: python3 Scripts/make-app-icon-layers.py [App/Resources/AppIcon.icon/Assets]
Open AppIcon.icon in Icon Composer to fine-tune glass, shadow and fill.
"""
import math, os, sys
out = sys.argv[1] if len(sys.argv) > 1 else 'App/Resources/AppIcon.icon/Assets'
C = 512.0
ANG = math.radians(40)   # tilt: quill bottom-left, tip top-right
S = 0.92
def tf(x, y):
    # scale about center, then rotate clockwise by ANG
    x, y = (x - C) * S, (y - C) * S
    xr = x * math.cos(ANG) - y * math.sin(ANG)
    yr = x * math.sin(ANG) + y * math.cos(ANG)
    return xr + C, yr + C
def P(cmds):
    s = []
    for c in cmds:
        op, pts = c[0], c[1:]
        if op == 'Z':
            s.append('Z'); continue
        s.append(op + ' ' + ' '.join('%.1f %.1f' % tf(*p) for p in pts))
    return ' '.join(s)

# Upright feather, centre line x=512, tip at top. Rachis curves gently right.
# Right vane (wider), split twice like a real feather.
right = [
    ('M', (518, 168)),
    ('C', (580, 214), (628, 278), (650, 350)),
    ('L', (602, 352)),            # upper split in
    ('L', (658, 392)),            # and out
    ('C', (668, 470), (656, 528), (632, 566)),
    ('L', (584, 552)),            # lower split in
    ('L', (620, 602)),            # and out
    ('C', (598, 664), (566, 716), (528, 756)),
    ('C', (524, 600), (526, 380), (518, 168)),
    ('Z',),
]
# Left vane (narrower), split once.
left = [
    ('M', (506, 172)),
    ('C', (446, 236), (404, 320), (394, 410)),
    ('C', (388, 470), (396, 524), (414, 570)),
    ('L', (462, 548)),
    ('L', (430, 606)),
    ('C', (452, 652), (478, 700), (500, 736)),
    ('C', (506, 560), (508, 380), (506, 172)),
    ('Z',),
]
# Loose barbs below the vane, where real feathers go downy.
wisps = [
    [('M', (526, 770)), ('C', (560, 760), (592, 734), (606, 704)), ('C', (590, 744), (560, 772), (524, 786)), ('Z',)],
    [('M', (522, 800)), ('C', (548, 796), (570, 782), (582, 764)), ('C', (572, 790), (550, 808), (520, 814)), ('Z',)],
    [('M', (500, 758)), ('C', (468, 744), (446, 718), (436, 690)), ('C', (452, 726), (474, 754), (498, 774)), ('Z',)],
]
# Rachis: a tapered quill from the tip down past the vane.
shaft = [
    ('M', (512, 150)),
    ('C', (524, 380), (520, 640), (500, 880)),
    ('L', (488, 878)),
    ('C', (506, 640), (510, 380), (508, 150)),
    ('Z',),
]
def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            + body + '\n</svg>\n')
vane = svg('\n'.join('<path fill="#ffffff" d="%s"/>' % P(x) for x in [right, left] + wisps))
quill = svg('<path fill="#ffffff" d="%s"/>' % P(shaft))
# Four-point sparkle, upper left of the feather (the Smart Care "sparkles" idea, drawn from scratch).
cx, cy, r, w = 300, 300, 92, 20
sp = 'M %d %d C %d %d %d %d %d %d C %d %d %d %d %d %d C %d %d %d %d %d %d C %d %d %d %d %d %d Z' % (
    cx, cy - r,  cx + w*0.3, cy - w, cx + w, cy - w*0.3,  cx + r, cy,
    cx + w, cy + w*0.3, cx + w*0.3, cy + w,  cx, cy + r,
    cx - w*0.3, cy + w, cx - w, cy + w*0.3,  cx - r, cy,
    cx - w, cy - w*0.3, cx - w*0.3, cy - w,  cx, cy - r)
cx2, cy2, r2, w2 = 214, 438, 40, 9
sp2 = 'M %d %d C %.1f %.1f %.1f %.1f %d %d C %.1f %.1f %.1f %.1f %d %d C %.1f %.1f %.1f %.1f %d %d C %.1f %.1f %.1f %.1f %d %d Z' % (
    cx2, cy2 - r2,  cx2 + w2*0.3, cy2 - w2, cx2 + w2, cy2 - w2*0.3,  cx2 + r2, cy2,
    cx2 + w2, cy2 + w2*0.3, cx2 + w2*0.3, cy2 + w2,  cx2, cy2 + r2,
    cx2 - w2*0.3, cy2 + w2, cx2 - w2, cy2 + w2*0.3,  cx2 - r2, cy2,
    cx2 - w2, cy2 - w2*0.3, cx2 - w2*0.3, cy2 - w2,  cx2, cy2 - r2)
sparkle = svg('<path fill="#ffffff" d="%s"/>\n<path fill="#ffffff" d="%s"/>' % (sp, sp2))
os.makedirs(out, exist_ok=True)
for n, s in [('feather-vane.svg', vane), ('feather-quill.svg', quill), ('sparkle.svg', sparkle)]:
    open(os.path.join(out, n), 'w').write(s)
print('ok')
