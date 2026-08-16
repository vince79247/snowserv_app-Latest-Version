#!/usr/bin/env python3
"""Pad iPhone store screenshots so Google Play accepts them.

Play rejects any image whose long side exceeds 2x its short side; a 6.9" iPhone
capture (1320x2868) is 2.17x. Widen to height/2 by stretching each row's own edge
pixel outward, which is seamless even across the dark app bar (a flat background
fill leaves visible bars there).

    python3 tools/pad_for_play.py docs/store/ios docs/store/play
"""
import sys, os
from PIL import Image


def pad(src_path, dst_path):
    im = Image.open(src_path).convert('RGB')
    w, h = im.size
    if h <= w * 2:
        im.save(dst_path)
        return w, h
    tw = h // 2
    left = (tw - w) // 2
    right = tw - left - w
    canvas = Image.new('RGB', (tw, h))
    canvas.paste(im.crop((0, 0, 1, h)).resize((left, h), Image.NEAREST), (0, 0))
    canvas.paste(im.crop((w - 1, 0, w, h)).resize((right, h), Image.NEAREST), (left + w, 0))
    canvas.paste(im, (left, 0))
    canvas.save(dst_path)
    return tw, h


if __name__ == '__main__':
    src_dir, dst_dir = sys.argv[1], sys.argv[2]
    os.makedirs(dst_dir, exist_ok=True)
    for name in sorted(os.listdir(src_dir)):
        if name.lower().endswith('.png'):
            size = pad(os.path.join(src_dir, name), os.path.join(dst_dir, name))
            print('%-28s -> %dx%d' % (name, *size))
