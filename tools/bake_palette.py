"""OPTIONAL: bakes a CharacterPalette into real recoloured copies of the player's sheets, so you can open and touch them up in Aseprite.

    python tools/bake_palette.py data/palettes/friend.tres                 writes res://sprites/generated/friend_*.png / .json
    python tools/bake_palette.py data/palettes/friend.tres --out SOME_DIR  writes there instead
    python tools/bake_palette.py data/palettes/friend.tres --dry           only lists what it would write

It is NOT run by the game or by anything else. Nothing in sprites/generated is ever overwritten without --force.

What it does is exactly what shaders/palette_swap.gdshader does on screen: the hat and pants source colours listed in
data/player_palette.tres are replaced by the palette's hat_color / pants_color (the shade ramp keeps the lightness and saturation offsets from
the group's mid colour), with the hat told from the pants by the row (the top group of rows of a frame is the hat, the bottom group the pants).
The png and the json (frame positions, durations) of every main_character_*.png are copied; only colours change, nothing is scaled or moved.

To use a baked sheet as EXPLICIT art (it then wins over the recoloured player art): put it in a SpriteFrames of the colonist
(sprites/colonist_frames.tres lists the animations that are explicit art). Add the baked sheet's hat/pants colour to the aliases in
data/player_palette.tres if the character should still follow its palette afterwards (or leave it out to freeze the baked colours).
"""
import argparse
import colorsys
import json
import os
import re
import shutil
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPRITES = os.path.join(ROOT, "sprites")


def parse_color(text, key):
    m = re.search(r"^%s\s*=\s*Color\(([^)]*)\)" % key, text, re.M)
    if not m:
        raise SystemExit("%s not found in the palette file" % key)
    r, g, b = [float(v) for v in m.group(1).split(",")[:3]]
    return (round(r * 255), round(g * 255), round(b * 255))


def parse_hex_list(text, key):
    m = re.search(r"^%s\s*=\s*PackedStringArray\(([^)]*)\)" % key, text, re.M)
    if not m:
        return []
    return [tuple(int(h[i:i + 2], 16) for i in (1, 3, 5)) for h in re.findall(r'"(#[0-9a-fA-F]{6})"', m.group(1))]


def hsl(c):
    h, l, s = colorsys.rgb_to_hls(c[0] / 255, c[1] / 255, c[2] / 255)
    return h, s, l


def from_hsl(h, s, l):
    r, g, b = colorsys.hls_to_rgb(h % 1.0, min(1, max(0, l)), min(1, max(0, s)))
    return (round(r * 255), round(g * 255), round(b * 255))


def derive(sources, base):
    """The same as CharacterPalette.derive: the mid (median lightness) shade becomes `base`, the others keep their offsets."""
    if not sources:
        return []
    hb = hsl(base)
    order = sorted(range(len(sources)), key=lambda i: hsl(sources[i])[2])
    mid = hsl(sources[order[(len(sources) - 1) // 2]])
    out = []
    for s in sources:
        hs = hsl(s)
        if abs(hs[2] - mid[2]) < 1e-6 and abs(hs[1] - mid[1]) < 1e-6:
            out.append(base)
        else:
            out.append(from_hsl(hb[0], hb[1] + hs[1] - mid[1], hb[2] + hs[2] - mid[2]))
    return out


def split_row(im, colors):
    """The same as PaletteSwap.split_row, over the frames of one sheet."""
    cell = im.height
    n = im.width // cell
    hat_b, pants_t, singles = [], [], []
    for i in range(n):
        rows = [y for y in range(cell) if any(im.getpixel((i * cell + x, y))[3] > 0 and im.getpixel((i * cell + x, y))[:3] in colors for x in range(cell))]
        clusters = []
        for y in rows:
            if clusters and y - clusters[-1][1] <= 2:
                clusters[-1][1] = y
            else:
                clusters.append([y, y])
        if len(clusters) >= 2:
            hat_b.append(clusters[0][1])
            pants_t.append(clusters[-1][0])
        elif len(clusters) == 1:
            singles.append(clusters[0])
    for cl in singles:
        centre = (cl[0] + cl[1]) / 2
        if hat_b and pants_t:
            (hat_b if abs(centre - max(hat_b)) <= abs(centre - min(pants_t)) else pants_t).append(cl[1] if abs(centre - max(hat_b)) <= abs(centre - min(pants_t)) else cl[0])
        elif centre < cell / 2:
            hat_b.append(cl[1])
        else:
            pants_t.append(cl[0])
    if hat_b and pants_t:
        return (max(hat_b) + min(pants_t)) / 2 + 0.5
    if hat_b:
        return max(hat_b) + 4
    if pants_t:
        return min(pants_t) - 3
    return cell / 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("palette", help="a CharacterPalette .tres (hat_color, pants_color, palette_name)")
    ap.add_argument("--out", default=os.path.join(SPRITES, "generated"))
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--force", action="store_true", help="overwrite files that exist")
    args = ap.parse_args()
    ptext = open(args.palette if os.path.isabs(args.palette) else os.path.join(ROOT, args.palette), encoding="utf-8").read()
    hat_base = parse_color(ptext, "hat_color")
    pants_base = parse_color(ptext, "pants_color")
    m = re.search(r'^palette_name\s*=\s*"([^"]*)"', ptext, re.M)
    name = re.sub(r"[^a-z0-9]+", "_", (m.group(1) if m else os.path.splitext(os.path.basename(args.palette))[0]).lower()).strip("_") or "palette"
    src = open(os.path.join(ROOT, "data", "player_palette.tres"), encoding="utf-8").read()
    hat_src = parse_hex_list(src, "hat_hex")
    pants_src = parse_hex_list(src, "pants_hex")
    hat_map = dict(zip(hat_src, derive(hat_src, hat_base)))
    pants_map = dict(zip(pants_src, derive(pants_src, pants_base)))
    colors = set(hat_src) | set(pants_src)
    os.makedirs(args.out, exist_ok=True) if not args.dry else None
    written = 0
    for f in sorted(os.listdir(SPRITES)):
        if not (f.startswith("main_character_") and f.endswith(".png")):
            continue
        out_png = os.path.join(args.out, "%s_%s" % (name, f[len("main_character_"):]))
        out_json = out_png[:-4] + ".json"
        if os.path.exists(out_png) and not (args.force or args.dry):
            print("skip (exists): %s" % out_png)
            continue
        im = Image.open(os.path.join(SPRITES, f)).convert("RGBA")
        split = split_row(im, colors)
        out = im.copy()
        px = out.load()
        for y in range(im.height):
            for x in range(im.width):
                p = im.getpixel((x, y))
                if p[3] == 0:
                    continue
                c = p[:3]
                lower = y >= split
                in_hat, in_pants = c in hat_map, c in pants_map
                if in_hat and in_pants:
                    c = pants_map[c] if lower else hat_map[c]
                elif in_hat:
                    c = hat_map[c]
                elif in_pants:
                    c = pants_map[c]
                px[x, y] = c + (p[3],)
        print("%s -> %s (split row %.1f)" % (f, os.path.basename(out_png), split))
        if args.dry:
            written += 1
            continue
        out.save(out_png)
        src_json = os.path.join(SPRITES, f[:-4] + ".json")
        if os.path.exists(src_json):
            data = json.load(open(src_json, encoding="utf-8"))
            if "meta" in data and "image" in data["meta"]:
                data["meta"]["image"] = os.path.basename(out_png)
            json.dump(data, open(out_json, "w", encoding="utf-8"), indent=1)
        written += 1
    print("%s %d sheet(s) as '%s' (hat %s, pants %s)" % ("would write" if args.dry else "wrote", written, name, hat_base, pants_base))


if __name__ == "__main__":
    main()
