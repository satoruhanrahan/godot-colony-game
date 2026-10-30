"""Generates the small designation icons (placeholders) into res://ui/: designation_axe.png (a tree marked to be chopped),
designation_hammer.png (a blueprint assigned to be built), designation_saw.png (the pit saw assigned). Each is drawn on a small
grid, enlarged 2x with nearest, with a dark outline so it reads on any ground. Never overwrites a file that exists (draw your own
and drop it in with the same name).

    python tools/make_designation_icons.py     (needs Pillow)
"""
import os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "ui")
SCALE = 2
INK = (0x1c, 0x14, 0x0e, 255)
STEEL = (0xd8, 0xdf, 0xe6, 255)
STEEL_D = (0x8f, 0x9a, 0xa6, 255)
WOOD = (0xb7, 0x7a, 0x3c, 255)
WOOD_D = (0x7d, 0x4e, 0x25, 255)
BRASS = (0xe0, 0xb4, 0x4a, 255)

AXE = [
    "..........",
    "...SSS....",
    "..SSSSS...",
    "..SSSSSW..",
    "...SSSWW..",
    ".....WW...",
    "....WW....",
    "...WW.....",
    "..WW......",
    "..........",
]
HAMMER = [
    "..........",
    ".HHHHHH...",
    ".HHHHHH...",
    ".HHHHHH...",
    "....WW....",
    "....WW....",
    "....WW....",
    "....WW....",
    "....WW....",
    "..........",
]
SAW = [
    "..........",
    "..........",
    "SSSSSSSSS.",
    "STSTSTSTS.",
    "SSSSSSSSS.",
    ".......WW.",
    ".......WW.",
    "..........",
    "..........",
    "..........",
]
PALETTE = {"S": STEEL, "W": WOOD, "H": STEEL_D, "T": STEEL_D}

def draw(rows, name):
    path = os.path.join(OUT, name)
    if os.path.exists(path):
        print("kept (exists):", name)
        return
    h, w = len(rows), len(rows[0])
    img = Image.new("RGBA", (w + 2, h + 2), (0, 0, 0, 0))
    px = img.load()
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch in PALETTE:
                px[x + 1, y + 1] = PALETTE[ch]
    # outline
    src = img.copy().load()
    for y in range(h + 2):
        for x in range(w + 2):
            if src[x, y][3] == 0:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w + 2 and 0 <= ny < h + 2 and src[nx, ny][3] > 0 and src[nx, ny] != INK:
                        px[x, y] = INK
    img = img.resize(((w + 2) * SCALE, (h + 2) * SCALE), Image.NEAREST)
    img.save(path)
    print("wrote", name)

if __name__ == "__main__":
    draw(AXE, "designation_axe.png")
    draw(HAMMER, "designation_hammer.png")
    draw(SAW, "designation_saw.png")
