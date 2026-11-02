"""Checks res://sprites/main_character_carrying_stone.png against the player's palette source groups (res://data/player_palette.tres)
and writes res://tools/stone_palette_check.png: every opaque colour of the sheet as a swatch with its hex, its pixel count, the frames it sits in
and what it is (the hat / pants source colour, a colour the walk sheet already has, or new with the stone), plus every colour that is NEAR a
hat / pants source colour without being it (a likely export mismatch). Prints the same as text.

    python tools/stone_palette_check.py          (needs Pillow)
"""
import os
import re
from collections import Counter, defaultdict

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPR = os.path.join(ROOT, "sprites")
NEAR = 40  # the largest per-channel difference that still counts as "near"


def hexof(c):
    return "#%02x%02x%02x" % c[:3]


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def source_groups():
    text = open(os.path.join(ROOT, "data", "player_palette.tres"), encoding="utf-8").read()
    out = {}
    for key in ("hat_hex", "pants_hex", "hat_alias_hex", "pants_alias_hex"):
        m = re.search(key + r' = PackedStringArray\((.*?)\)', text)
        out[key] = re.findall(r'"(#[0-9a-fA-F]{6})"', m.group(1)) if m else []
    return out


def colours(path):
    im = Image.open(path).convert("RGBA")
    cell = 32 if im.height == 32 else 16
    count = Counter()
    frames = defaultdict(set)
    for y in range(im.height):
        for x in range(im.width):
            p = im.getpixel((x, y))
            if p[3] > 0:
                count[hexof(p)] += 1
                frames[hexof(p)].add(x // cell)
    return count, frames


def main():
    groups = source_groups()
    sources = set(h.lower() for k in ("hat_hex", "pants_hex") for h in groups[k])
    stone, frames = colours(os.path.join(SPR, "main_character_carrying_stone.png"))
    walk, _ = colours(os.path.join(SPR, "main_character_walk.png"))
    lines = ["hat / pants source colours (data/player_palette.tres): %s" % ", ".join(sorted(sources))]
    rows = []
    mismatches = []
    for hx, n in stone.most_common():
        if hx in sources:
            what = "HAT / PANTS source colour"
        else:
            near = [s for s in sources if max(abs(a - b) for a, b in zip(rgb(hx), rgb(s))) <= NEAR]
            if near:
                what = "NEAR %s: a possible export mismatch" % near[0]
                mismatches.append((hx, n, sorted(frames[hx])))
            elif hx in walk:
                what = "body colour of the walk sheet"
            else:
                what = "new with the stone"
        rows.append((hx, n, sorted(frames[hx]), what))
        lines.append("  %s  %4d px  frames %s  %s" % (hx, n, sorted(frames[hx]), what))
    lines.append("mismatches: %s" % (mismatches if mismatches else "none: every hat / pants pixel is exactly the source colour"))
    print("\n".join(lines))
    sw, rh = 24, 30
    im = Image.new("RGB", (620, 30 + rh * (len(rows) + 2)), (66, 68, 79))
    d = ImageDraw.Draw(im)
    f = ImageFont.load_default()
    d.text((8, 6), "carrying_stone vs the player's palette (hat / pants source: %s)" % ", ".join(sorted(sources)), fill=(255, 255, 255), font=f)
    for i, (hx, n, fr, what) in enumerate(rows):
        y = 28 + i * rh
        d.rectangle([8, y, 8 + sw, y + sw - 4], fill=rgb(hx), outline=(0, 0, 0))
        d.text((44, y + 2), "%s  %d px  frames %s" % (hx, n, fr), fill=(255, 255, 255), font=f)
        d.text((260, y + 2), what, fill=(255, 220, 120) if "NEAR" in what else (200, 230, 200), font=f)
    d.text((8, 28 + len(rows) * rh + 6), "mismatches: %s" % ("none" if not mismatches else ", ".join(m[0] for m in mismatches)), fill=(255, 255, 255), font=f)
    im.save(os.path.join(ROOT, "tools", "stone_palette_check.png"))


main()
