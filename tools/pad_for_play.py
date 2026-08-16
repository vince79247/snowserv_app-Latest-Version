#!/usr/bin/env python3
"""Pad iPhone store screenshots into the shape Google Play wants.

Play applies two different bars to phone screenshots:
  * to UPLOAD at all, the long side may be at most 2x the short side. A 6.9"
    iPhone capture is 1320x2868 = 2.17x, so the raw iOS files are rejected.
  * to be eligible for PROMOTIONAL placement, Play wants 9:16 (portrait), at
    least 1080px, and at least 4 of them.

Targeting 9:16 satisfies both, so that is what this produces: a 1620x2880 canvas
with the capture centered. The padding is made by stretching each edge row/column
of the image outward, not by filling with a flat color — a flat fill leaves
visible bars across the dark app bar, whereas edge extension is invisible.

    python3 tools/pad_for_play.py docs/store/ios docs/store/play
"""
import sys, os
from PIL import Image

TARGET_W, TARGET_H = 1620, 2880          # exactly 9:16


def pad(src_path, dst_path):
    im = Image.open(src_path).convert('RGB')
    w, h = im.size
    if w > TARGET_W or h > TARGET_H:
        raise SystemExit('%s is %dx%d, larger than the %dx%d canvas'
                         % (os.path.basename(src_path), w, h, TARGET_W, TARGET_H))
    lx, ty = (TARGET_W - w) // 2, (TARGET_H - h) // 2
    c = Image.new('RGB', (TARGET_W, TARGET_H))
    # stretch the left and right edge columns outward, then the top and bottom rows
    c.paste(im.crop((0, 0, 1, h)).resize((lx, h), Image.NEAREST), (0, ty))
    c.paste(im.crop((w - 1, 0, w, h)).resize((TARGET_W - lx - w, h), Image.NEAREST), (lx + w, ty))
    c.paste(im, (lx, ty))
    c.paste(c.crop((0, ty, TARGET_W, ty + 1)).resize((TARGET_W, ty), Image.NEAREST), (0, 0))
    c.paste(c.crop((0, ty + h - 1, TARGET_W, ty + h)).resize((TARGET_W, TARGET_H - ty - h), Image.NEAREST),
            (0, ty + h))
    c.save(dst_path)
    return lx, ty


if __name__ == '__main__':
    src_dir, dst_dir = sys.argv[1], sys.argv[2]
    os.makedirs(dst_dir, exist_ok=True)
    for name in sorted(os.listdir(src_dir)):
        if name.lower().endswith('.png'):
            lx, ty = pad(os.path.join(src_dir, name), os.path.join(dst_dir, name))
            print('%-28s -> %dx%d  (pad %dpx sides, %dpx top/bottom)'
                  % (name, TARGET_W, TARGET_H, lx, ty))
