"""Analyses the player's sheets (res://sprites/main_character_*.png) and writes

    res://tools/palette_report.png   every distinct opaque colour: swatch, hex, pixel counts, and where on the body it sits
    res://tools/palette_report.txt   the same as text, plus the proposed HAT and PANTS groups and what is AMBIGUOUS
    res://data/player_palette.tres   the proposed source colour lists (edit the hex strings in it to correct them)

    python tools/palette_report.py            (needs Pillow)

How it decides (no guessing behind your back, everything is printed):
  * the BODY colours are the ones the walk sheet uses; every other colour of the other sheets belongs to a held thing (hay, a tool ...)
  * on the idle frame (walk frame 0) every opaque pixel is put in a band by its row: head top (hat) rows 0-3, face rows 4-8,
    body rows 9-11, legs and feet rows 12-15. A colour that sits in the hat band and in the legs band only is the hat AND the pants colour.
  * the hat group is the body colours of the hat band that are not the outline, the skin or the shirt; the pants group the same for the legs band.
  * a colour in both groups (or in a group and in another region) is marked AMBIGUOUS. The shader then tells hat from pants by the pixel's row
    (see shaders/palette_swap.gdshader), which is what makes two independent colours possible for one shared source colour.
The explicit art of the colonist (colonist_*.png) is looked at too: its hat/pants colour is listed as an ALIAS of the same two groups.
"""
import json
import os
import sys
from collections import Counter, defaultdict

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPRITES = os.path.join(ROOT, "sprites")
BANDS = [("hat", 0, 3), ("face", 4, 8), ("body", 9, 11), ("legs", 12, 15)]


def hexof(c):
    return "#%02x%02x%02x" % c[:3]


def cell_size(im):
    return 16 if im.height == 16 else 32


def load_sheets(prefix):
    out = {}
    for f in sorted(os.listdir(SPRITES)):
        if f.startswith(prefix) and f.endswith(".png"):
            out[f] = Image.open(os.path.join(SPRITES, f)).convert("RGBA")
    return out


def band_of(y):
    for name, lo, hi in BANDS:
        if lo <= y <= hi:
            return name
    return "legs"


def main():
    sheets = load_sheets("main_character_")
    walk = sheets["main_character_walk.png"]
    # ---- every colour of every sheet
    total = Counter()
    per_sheet = defaultdict(Counter)
    for name, im in sheets.items():
        for y in range(im.height):
            for x in range(im.width):
                p = im.getpixel((x, y))
                if p[3] > 0:
                    total[p[:3]] += 1
                    per_sheet[p[:3]][name] += 1
    body = Counter()
    for y in range(16):
        for x in range(96):
            p = walk.getpixel((x, y))
            if p[3] > 0:
                body[p[:3]] += 1
    # ---- the idle frame bands
    bands = defaultdict(Counter)
    idle_pixels = defaultdict(list)
    for y in range(16):
        for x in range(16):
            p = walk.getpixel((x, y))
            if p[3] > 0:
                bands[p[:3]][band_of(y)] += 1
                idle_pixels[p[:3]].append((x, y))
    # ---- classification by where the colour sits (position heuristics on the idle frame)
    outline = min(body, key=lambda c: sum(c))  # the darkest body colour
    roles = {}
    for c in body:
        b = bands[c]
        if c == outline:
            roles[c] = "outline"
        elif c == (255, 255, 255):
            roles[c] = "eyes"
        elif b["hat"] and b["legs"] and not b["face"] and not b["body"]:
            roles[c] = "hat+pants"
        elif b["face"] and not b["legs"] and not b["hat"]:
            roles[c] = "skin / face"
        elif b["face"] and b["body"]:
            roles[c] = "face shade + shirt"
        else:
            roles[c] = "mixed"
    hat_group = [c for c in body if roles[c] in ("hat+pants",) or (bands[c]["hat"] >= 4 and roles[c] not in ("outline", "eyes", "skin / face", "face shade + shirt"))]
    pants_group = [c for c in body if roles[c] in ("hat+pants",) or (bands[c]["legs"] >= 4 and roles[c] not in ("outline", "eyes", "skin / face", "face shade + shirt"))]
    ambiguous = []
    for c in body:
        regions = [n for n in ("hat", "face", "body", "legs") if bands[c][n]]
        in_hat = c in hat_group
        in_pants = c in pants_group
        if in_hat and in_pants:
            ambiguous.append((c, "in BOTH the hat and the pants (same colour on the head top and on the legs)"))
        elif (in_hat or in_pants) and len([r for r in regions if r not in ("hat", "legs")]):
            ambiguous.append((c, "in a hat/pants region and also in " + ", ".join(r for r in regions if r not in ("hat", "legs"))))
    # colours of the other sheets that are not body colours: held things
    items = [c for c in total if c not in body]
    # ---- the colonist's own art: its hat/pants colour (an alias of the groups)
    own = load_sheets("colonist_")
    alias = Counter()
    for name, im in own.items():
        for y in range(im.height):
            for x in range(im.width):
                p = im.getpixel((x, y))
                if p[3] > 0 and p[:3] not in total:
                    alias[p[:3]] += 1
    # ---- the text
    lines = []
    lines.append("PLAYER PALETTE REPORT (%d sheets, %d distinct opaque colours; %d belong to the body, %d to held things)" % (len(sheets), len(total), len(body), len(items)))
    lines.append("")
    lines.append("BODY COLOURS (the colours of main_character_walk.png), idle frame = frame 0:")
    lines.append("  %-8s %-20s %9s %9s   %s" % ("hex", "role (by position)", "idle px", "all px", "idle frame pixels per band (hat rows 0-3 / face 4-8 / body 9-11 / legs 12-15)"))
    for c, n in body.most_common():
        lines.append("  %-8s %-20s %9d %9d   hat %d / face %d / body %d / legs %d" % (hexof(c), roles[c], sum(bands[c].values()), total[c], bands[c]["hat"], bands[c]["face"], bands[c]["body"], bands[c]["legs"]))
    lines.append("")
    lines.append("PROPOSED HAT GROUP   : " + ", ".join(hexof(c) for c in hat_group))
    lines.append("PROPOSED PANTS GROUP : " + ", ".join(hexof(c) for c in pants_group))
    lines.append("")
    lines.append("AMBIGUOUS:")
    for c, why in ambiguous:
        lines.append("  %s  %s" % (hexof(c), why))
    if not ambiguous:
        lines.append("  none")
    lines.append("  Note: the art has ONE flat colour for the hat and for the pants (no lighter / darker shades), so each group has a single")
    lines.append("  colour, and it is the SAME colour for both. The swap tells them apart by the pixel's row (hat above the split row of the")
    lines.append("  animation, pants from it down; the split is found from the art itself, see palette_swap.gd), so hat_color and pants_color are independent.")
    lines.append("  Also shared (not a hat/pants matter): " + ", ".join("%s (%s)" % (hexof(c), roles[c]) for c in body if roles[c] in ("face shade + shirt", "mixed")))
    lines.append("")
    lines.append("COLOURS THE COLONIST'S OWN ART USES FOR ITS HAT AND PANTS (aliases of the same two groups, so the dedicated art follows the palette too):")
    for c, n in alias.most_common():
        lines.append("  %s  %d px in colonist_*.png" % (hexof(c), n))
    lines.append("")
    lines.append("HELD THINGS (colours that are not body colours, %d): " % len(items) + ", ".join(hexof(c) for c in sorted(items)))
    lines.append("")
    lines.append("COLOURS PER SHEET (body colours only; the rest is the held thing):")
    for name, im in sheets.items():
        cs = Counter()
        for y in range(im.height):
            for x in range(im.width):
                p = im.getpixel((x, y))
                if p[3] > 0 and p[:3] in body:
                    cs[p[:3]] += 1
        lines.append("  %-44s %s" % (name, "  ".join("%s:%d" % (hexof(c), n) for c, n in cs.most_common())))
    text = "\n".join(lines) + "\n"
    open(os.path.join(ROOT, "tools", "palette_report.txt"), "w", encoding="utf-8").write(text)
    print(text)

    # ---- the picture
    scale = 10
    row_h = 30
    img_w = 980
    colours = sorted(total, key=lambda c: (-(c in body), -total[c]))
    head = 292
    img = Image.new("RGB", (img_w, head + row_h * (len(colours) + 2) + 20), (30, 28, 34))
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("consola.ttf", 13)
        bold = ImageFont.truetype("consolab.ttf", 15)
    except Exception:
        font = bold = ImageFont.load_default()
    d.text((12, 8), "PLAYER PALETTE (%d colours; body = colours of the walk sheet)" % len(total), fill=(240, 230, 200), font=bold)
    # the idle frame, magnified, plain and with the groups tinted
    idle = walk.crop((0, 0, 16, 16))
    big = idle.resize((16 * 12, 16 * 12), Image.NEAREST)
    bg = Image.new("RGBA", big.size, (60, 58, 66, 255))
    bg.alpha_composite(big)
    img.paste(bg.convert("RGB"), (12, 34))
    tint = Image.new("RGBA", (16 * 12, 16 * 12), (60, 58, 66, 255))
    tp = tint.load()
    for y in range(16):
        for x in range(16):
            p = idle.getpixel((x, y))
            if p[3] == 0:
                continue
            c = p[:3]
            col = p[:3]
            if c in hat_group and band_of(y) == "hat":
                col = (80, 220, 120)
            elif c in pants_group and band_of(y) == "legs":
                col = (240, 170, 60)
            for yy in range(12):
                for xx in range(12):
                    tp[x * 12 + xx, y * 12 + yy] = col + (255,)
    img.paste(tint.convert("RGB"), (12 + 16 * 12 + 14, 34))
    # the band lines
    for name, lo, hi in BANDS:
        y0 = 34 + lo * 12
        d.line([(12, y0), (12 + 16 * 12 * 2 + 14, y0)], fill=(120, 120, 150), width=1)
        d.text((12 + 16 * 12 * 2 + 22, y0 + 2), "%s (rows %d-%d)" % (name, lo, hi), fill=(180, 180, 210), font=font)
    d.text((12, 34 + 16 * 12 + 4), "idle frame x12.   right: hat pixels green, pants pixels orange (same source colour!)", fill=(200, 200, 200), font=font)
    d.text((12, 34 + 16 * 12 + 22), "hat group: " + ", ".join(hexof(c) for c in hat_group) + "    pants group: " + ", ".join(hexof(c) for c in pants_group) + "    AMBIGUOUS: " + ", ".join(hexof(c) for c, _ in ambiguous), fill=(255, 220, 140), font=font)
    y = head
    d.text((12, y), "swatch    hex      role (by position)    idle px   all px   sheets", fill=(160, 160, 170), font=font)
    y += row_h - 6
    for c in colours:
        d.rectangle([12, y, 12 + 56, y + row_h - 6], fill=c, outline=(200, 200, 200))
        role = roles.get(c, "held thing")
        mark = ""
        if c in hat_group and c in pants_group:
            mark = "  <== HAT + PANTS (AMBIGUOUS)"
        elif c in hat_group:
            mark = "  <== HAT"
        elif c in pants_group:
            mark = "  <== PANTS"
        d.text((80, y + 4), "%-8s %-20s %6d %8d   %d sheet(s)%s" % (hexof(c), role, sum(bands[c].values()), total[c], len(per_sheet[c]), mark), fill=(235, 235, 235), font=font)
        y += row_h
    img.save(os.path.join(ROOT, "tools", "palette_report.png"))

    # ---- the data file (hex strings are the source of truth; edit them to correct a group)
    os.makedirs(os.path.join(ROOT, "data"), exist_ok=True)
    def arr(cs):
        return "PackedStringArray(%s)" % ", ".join('"%s"' % hexof(c) for c in cs)
    tres = """[gd_resource type="Resource" script_class="PlayerPalette" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/player_palette.gd" id="1"]

[resource]
script = ExtResource("1")
; The colours of the player's art that make up his HAT and his PANTS. Written by tools/palette_report.py; correct them by editing the hex strings.
; One flat colour is used for the hat and for the pants (no shades), and it is the same colour: it is listed in both groups and the swap tells the
; two apart by the pixel's row (see palette_swap.gd).
hat_hex = %s
pants_hex = %s
; The hat / pants colour of the dedicated colonist art (colonist_walk.png, colonist_asleep.png), so that art follows the palette too.
hat_alias_hex = %s
pants_alias_hex = %s
; Colours that sit in both groups or in a group and another region (information only).
ambiguous_hex = %s
""" % (arr(hat_group), arr(pants_group), arr(list(alias)), arr(list(alias)), arr([c for c, _ in ambiguous]))
    open(os.path.join(ROOT, "data", "player_palette.tres"), "w", encoding="utf-8", newline="\n").write(tres)
    print("wrote tools/palette_report.png, tools/palette_report.txt, data/player_palette.tres")


if __name__ == "__main__":
    main()
