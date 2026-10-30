"""Generates the UI art and the theme into res://ui/ (hard-edged pixel art, drawn small and enlarged 2x with nearest).

Visual direction: a medieval-renaissance culture descended from a spacefaring civilisation: dark walnut and aged
parchment panels, brass trim, riveted corners, a little dithering, and faint star-chart / circuit-trace engravings with a
dim verdigris-teal glow.

    python tools/make_ui.py            (needs Pillow)

Re-runnable and safe: ui/generated_manifest.json records every file written here with a hash. A file that is missing
from the manifest, or whose hash no longer matches (you drew your own and dropped it in with the same name), is NEVER
overwritten. res://ui/theme.tres is one of those files too (so you can restyle the theme and keep it).

Files: panel_frame, panel_frame_dark, button_normal/hover/pressed/disabled, tab_normal/tab_active, slot_frame,
slot_frame_selected, divider, corner_ornament, title_banner, icon_pause (+ theme.tres, ui_config.tres).
"""
import hashlib
import json
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "ui")
MANIFEST = os.path.join(OUT, "generated_manifest.json")
SCALE = 2   # every picture is drawn on a small grid and enlarged this many times (nearest)

PARCHMENT = (0xe8, 0xd9, 0xb0, 255)
PARCHMENT_DARK = (0xcd, 0xb9, 0x8a, 255)
INK = (0x2b, 0x21, 0x18, 255)
WALNUT = (0x4a, 0x34, 0x26, 255)
WALNUT_DARK = (0x2e, 0x1f, 0x16, 255)
BRASS = (0xb0, 0x8d, 0x3c, 255)
VERDIGRIS = (0x3f, 0x8f, 0x86, 255)
EMBER = (0xd9, 0x82, 0x2b, 255)
DANGER = (0xa3, 0x3a, 0x2c, 255)
DISABLED = (0x8a, 0x7f, 0x6a, 255)


def mix(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3)) + (255,)


BRASS_LIGHT = mix(BRASS, PARCHMENT, 0.45)
BRASS_DARK = mix(BRASS, INK, 0.45)
WALNUT_LIGHT = mix(WALNUT, BRASS, 0.25)
VERDIGRIS_DIM = mix(VERDIGRIS, WALNUT_DARK, 0.45)
CLEAR = (0, 0, 0, 0)


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.img = Image.new("RGBA", (w, h), CLEAR)

    def px(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.img.putpixel((x, y), c)

    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.px(x, y, c)

    def dither(self, x0, y0, x1, y1, c, phase=0):
        """A 50% checkerboard of colour c (a little dithering)."""
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if (x + y + phase) % 2 == 0:
                    self.px(x, y, c)

    def cut_corners(self):
        for (x, y) in [(0, 0), (self.w - 1, 0), (0, self.h - 1), (self.w - 1, self.h - 1)]:
            self.px(x, y, CLEAR)

    def save(self, path):
        self.img.resize((self.w * SCALE, self.h * SCALE), Image.NEAREST).save(path)


def frame(cv, fill, fill_shadow, trim=BRASS, inner=INK):
    """The common panel: ink outline, brass trim (light edge, body, dark edge), an ink hairline and the fill."""
    w, h = cv.w, cv.h
    cv.rect(0, 0, w - 1, h - 1, INK)
    cv.rect(1, 1, w - 2, h - 2, mix(trim, INK, 0.35))     # dark outer edge of the brass
    cv.rect(2, 2, w - 3, h - 3, trim)
    cv.rect(1, 1, w - 2, 1, mix(trim, PARCHMENT, 0.5))    # light edge on top and left
    cv.rect(1, 1, 1, h - 2, mix(trim, PARCHMENT, 0.5))
    cv.rect(3, 3, w - 4, h - 4, inner)
    cv.rect(4, 4, w - 5, h - 5, fill)
    # a soft inner shadow (dithered) along the top and left inside edge
    cv.dither(4, 4, w - 5, 5, fill_shadow)
    cv.dither(4, 4, 5, h - 5, fill_shadow, 1)
    cv.cut_corners()
    # rivets in the four corners
    for (x, y) in [(4, 4), (w - 6, 4), (4, h - 6), (w - 6, h - 6)]:
        cv.rect(x, y, x + 1, y + 1, BRASS_LIGHT)
        cv.px(x + 1, y + 1, BRASS_DARK)


def circuit(cv, color, along_top=True):
    """A faint engraved circuit trace (a few right-angle runs ending in dots) near the top inside edge."""
    y = 7
    for x in range(8, cv.w - 8):
        if (x // 3) % 2 == 0 and along_top:
            cv.px(x, y, color)
    cv.px(10, y + 1, color)
    cv.px(10, y + 2, color)
    cv.px(cv.w - 11, y + 1, color)
    cv.px(cv.w - 11, y + 2, color)
    for (x, yy) in [(10, y + 3), (cv.w - 11, y + 3)]:
        cv.px(x, yy, color)
        cv.px(x + 1, yy, color)


def star(cv, cx, cy, color):
    cv.px(cx, cy, color)
    for d in (-1, 1):
        cv.px(cx + d, cy, mix(color, WALNUT_DARK, 0.4))
        cv.px(cx, cy + d, mix(color, WALNUT_DARK, 0.4))


def make_panel_frame():
    cv = Canvas(32, 32)
    frame(cv, PARCHMENT, PARCHMENT_DARK)
    # faint star-chart engraving: sparse dim stars joined by a hairline, in the lower right
    for (x, y) in [(20, 22), (24, 25), (17, 26), (26, 20)]:
        cv.px(x, y, mix(PARCHMENT_DARK, BRASS, 0.3))
    cv.px(21, 23, PARCHMENT_DARK)
    cv.px(22, 24, PARCHMENT_DARK)
    cv.px(23, 24, PARCHMENT_DARK)
    return cv


def make_panel_frame_dark():
    cv = Canvas(32, 32)
    frame(cv, WALNUT, mix(WALNUT, WALNUT_DARK, 0.6))
    circuit(cv, VERDIGRIS_DIM)
    star(cv, 24, 24, VERDIGRIS_DIM)
    return cv


def button(kind):
    w, h = 24, 14
    cv = Canvas(w, h)
    edge = {"normal": BRASS_DARK, "hover": BRASS_LIGHT, "pressed": BRASS_DARK, "disabled": DISABLED}[kind]
    fill = {"normal": WALNUT, "hover": WALNUT_LIGHT, "pressed": WALNUT_DARK, "disabled": mix(DISABLED, WALNUT_DARK, 0.6)}[kind]
    cv.rect(0, 0, w - 1, h - 1, INK)
    cv.rect(1, 1, w - 2, h - 2, edge)
    cv.rect(2, 2, w - 3, h - 3, fill)
    if kind == "pressed":
        cv.rect(2, 2, w - 3, 2, mix(fill, INK, 0.5))     # the top is in shadow
        cv.rect(2, 2, 2, h - 3, mix(fill, INK, 0.4))
    else:
        cv.rect(2, 2, w - 3, 2, mix(fill, PARCHMENT, 0.16 if kind != "disabled" else 0.05))   # a lit top edge
        cv.rect(2, h - 3, w - 3, h - 3, mix(fill, INK, 0.45))
    if kind == "hover":
        cv.dither(3, h - 5, w - 4, h - 4, VERDIGRIS_DIM)     # a faint ember of the old technology
    cv.cut_corners()
    return cv


def tab(active):
    w, h = 24, 16
    cv = Canvas(w, h)
    top = BRASS_LIGHT if active else BRASS_DARK
    fill = PARCHMENT if active else WALNUT_DARK
    cv.rect(0, 2, w - 1, h - 1, INK)
    cv.rect(2, 0, w - 3, 1, INK)
    cv.rect(1, 2, w - 2, h - 1, top)
    cv.rect(2, 1, w - 3, 1, top)
    cv.rect(2, 3, w - 3, h - 1, fill)
    if active:
        cv.rect(2, 3, w - 3, 3, mix(PARCHMENT, PARCHMENT_DARK, 0.4))
        cv.dither(2, 3, w - 3, 4, PARCHMENT)
        cv.rect(2, h - 1, w - 3, h - 1, PARCHMENT)         # opens into the panel
    else:
        cv.dither(2, 3, w - 3, 4, WALNUT)
    cv.px(0, 2, CLEAR)
    cv.px(w - 1, 2, CLEAR)
    return cv


def tab_hover():
    cv = tab(False)
    # a lighter top edge and fill: the tab under the mouse
    for y in range(cv.h):
        for x in range(cv.w):
            p = cv.img.getpixel((x, y))
            if p[3] and p[:3] == WALNUT_DARK[:3]:
                cv.img.putpixel((x, y), WALNUT)
            elif p[3] and p[:3] == BRASS_DARK[:3]:
                cv.img.putpixel((x, y), BRASS_LIGHT)
    return cv


def icon_lock():
    cv = Canvas(7, 9)
    cv.rect(1, 4, 5, 8, INK)
    cv.rect(2, 5, 4, 7, BRASS)
    cv.rect(2, 5, 4, 5, BRASS_LIGHT)
    cv.px(3, 6, INK)
    cv.rect(2, 1, 2, 4, INK)
    cv.rect(4, 1, 4, 4, INK)
    cv.rect(3, 0, 3, 0, INK)
    cv.px(2, 2, BRASS_DARK)
    cv.px(4, 2, BRASS_DARK)
    cv.px(3, 1, BRASS_DARK)
    return cv


def slot(selected):
    w, h = 28, 28
    cv = Canvas(w, h)
    cv.rect(0, 0, w - 1, h - 1, INK)
    cv.rect(1, 1, w - 2, h - 2, BRASS_LIGHT if selected else BRASS_DARK)
    cv.rect(2, 2, w - 3, h - 3, INK)
    cv.rect(3, 3, w - 4, h - 4, WALNUT_DARK)
    cv.dither(3, 3, w - 4, 4, mix(WALNUT_DARK, INK, 0.6))
    cv.dither(3, 3, 4, h - 4, mix(WALNUT_DARK, INK, 0.6), 1)
    if selected:
        cv.rect(3, 3, w - 4, 3, VERDIGRIS)
        cv.rect(3, h - 4, w - 4, h - 4, VERDIGRIS)
        cv.rect(3, 3, 3, h - 4, VERDIGRIS)
        cv.rect(w - 4, 3, w - 4, h - 4, VERDIGRIS)
        cv.rect(4, 4, w - 5, h - 5, WALNUT_DARK)
    cv.cut_corners()
    return cv


def divider():
    w, h = 64, 6
    cv = Canvas(w, h)
    cv.rect(10, 2, w - 11, 2, BRASS)
    cv.rect(10, 3, w - 11, 3, BRASS_DARK)
    cv.rect(10, 1, w - 11, 1, mix(BRASS, INK, 0.2))
    for (cx, flip) in [(5, 1), (w - 6, -1)]:
        cv.px(cx, 2, BRASS_LIGHT)
        cv.px(cx - 1, 2, BRASS)
        cv.px(cx + 1, 2, BRASS)
        cv.px(cx, 1, BRASS)
        cv.px(cx, 3, BRASS_DARK)
        cv.px(cx + 2 * flip, 2, VERDIGRIS)
    return cv


def corner_ornament():
    w, h = 16, 16
    cv = Canvas(w, h)
    cv.rect(0, 0, 11, 1, BRASS_LIGHT)
    cv.rect(0, 2, 11, 2, BRASS)
    cv.rect(0, 0, 1, 11, BRASS_LIGHT)
    cv.rect(2, 2, 2, 11, BRASS)
    cv.rect(3, 3, 5, 5, BRASS_DARK)
    cv.rect(4, 4, 4, 4, BRASS_LIGHT)
    cv.px(7, 7, VERDIGRIS)
    cv.px(8, 3, BRASS_DARK)
    cv.px(3, 8, BRASS_DARK)
    cv.px(10, 4, VERDIGRIS_DIM)
    cv.px(4, 10, VERDIGRIS_DIM)
    return cv


def title_banner():
    w, h = 96, 22
    cv = Canvas(w, h)
    cv.rect(8, 3, w - 9, h - 4, INK)
    cv.rect(9, 4, w - 10, h - 5, BRASS)
    cv.rect(9, 4, w - 10, 4, BRASS_LIGHT)
    cv.rect(9, h - 5, w - 10, h - 5, BRASS_DARK)
    cv.rect(9, 6, w - 10, h - 7, WALNUT_DARK)
    cv.dither(9, 6, w - 10, 7, WALNUT)
    # swallow-tail ends
    for side in (0, 1):
        x0 = 0 if side == 0 else w - 9
        cv.rect(x0, 6, x0 + 8, h - 3, INK)
        cv.rect(x0 + 1, 7, x0 + 7, h - 4, BRASS_DARK)
        cv.rect(x0 + 2, 8, x0 + 6, h - 5, WALNUT_DARK)
        notch = x0 + (0 if side == 0 else 8)
        for k in range(4):
            cv.px(notch + (k if side == 0 else -k), 6 + 3 + k, CLEAR)
            cv.px(notch + (k if side == 0 else -k), h - 3 - 3 - k, CLEAR)
    star(cv, 14, 11, VERDIGRIS)
    star(cv, w - 15, 11, VERDIGRIS)
    return cv


def icon_pause():
    cv = Canvas(10, 10)
    for x0 in (2, 6):
        cv.rect(x0, 1, x0 + 1, 8, BRASS_LIGHT)
        cv.rect(x0, 8, x0 + 1, 8, BRASS_DARK)
        cv.rect(x0 - 1 if x0 > 0 else 0, 1, x0 - 1, 8, INK)
    cv.rect(8, 1, 8, 8, INK)
    return cv


ASSETS = {
    "panel_frame.png": make_panel_frame, "panel_frame_dark.png": make_panel_frame_dark,
    "button_normal.png": lambda: button("normal"), "button_hover.png": lambda: button("hover"),
    "button_pressed.png": lambda: button("pressed"), "button_disabled.png": lambda: button("disabled"),
    "tab_normal.png": lambda: tab(False), "tab_active.png": lambda: tab(True), "tab_hover.png": tab_hover, "icon_lock.png": icon_lock,
    "slot_frame.png": lambda: slot(False), "slot_frame_selected.png": lambda: slot(True),
    "divider.png": divider, "corner_ornament.png": corner_ornament, "title_banner.png": title_banner,
    "icon_pause.png": icon_pause,
}

# 9-slice margins of each picture in REAL pixels (the pictures are 2x): left, top, right, bottom
MARGINS = {
    "panel_frame": (14, 14, 14, 14), "panel_frame_dark": (14, 14, 14, 14),
    "button_normal": (8, 8, 8, 8), "button_hover": (8, 8, 8, 8), "button_pressed": (8, 8, 8, 8), "button_disabled": (8, 8, 8, 8),
    "tab_normal": (10, 8, 10, 4), "tab_active": (10, 8, 10, 4), "tab_hover": (10, 8, 10, 4),
    "slot_frame": (10, 10, 10, 10), "slot_frame_selected": (10, 10, 10, 10),
    "divider": (24, 0, 24, 0), "title_banner": (20, 14, 20, 14),
}


def theme_text():
    """res://ui/theme.tres: styleboxes from the pictures above, colours from the palette, the fonts."""
    def box(name):
        l, t, r, b = MARGINS[name]
        return ('texture = ExtResource("%s")\ntexture_margin_left = %d\ntexture_margin_top = %d\ntexture_margin_right = %d\n'
                'texture_margin_bottom = %d\naxis_stretch_horizontal = 1\naxis_stretch_vertical = 1\n' % (name, l, t, r, b))

    def content(l, t, r, b):
        return "content_margin_left = %d\ncontent_margin_top = %d\ncontent_margin_right = %d\ncontent_margin_bottom = %d\n" % (l, t, r, b)

    names = ["panel_frame", "panel_frame_dark", "button_normal", "button_hover", "button_pressed", "button_disabled",
             "tab_normal", "tab_active", "tab_hover", "slot_frame", "slot_frame_selected", "divider", "title_banner"]
    lines = ['[gd_resource type="Theme" load_steps=%d format=3]\n' % (len(names) + 5)]
    for n in names:
        lines.append('[ext_resource type="Texture2D" path="res://ui/%s.png" id="%s"]' % (n, n))
    lines.append('[ext_resource type="FontFile" path="res://fonts/AlegreyaSans-Regular.ttf" id="font_body"]')
    lines.append('[ext_resource type="FontFile" path="res://fonts/Cinzel-Variable.ttf" id="font_head_base"]')
    lines.append("")
    lines.append('[sub_resource type="FontVariation" id="font_heading"]\nbase_font = ExtResource("font_head_base")\nvariation_opentype = {2003265652: 600}\n')
    for n in names:
        extra = {"panel_frame": content(14, 14, 14, 14), "panel_frame_dark": content(14, 14, 14, 14),
                 "button_normal": content(10, 6, 10, 6), "button_hover": content(10, 6, 10, 6),
                 "button_pressed": content(10, 8, 10, 4), "button_disabled": content(10, 6, 10, 6),
                 "tab_normal": content(10, 6, 10, 4), "tab_active": content(10, 6, 10, 4), "tab_hover": content(10, 6, 10, 4),
                 "slot_frame": content(6, 6, 6, 6), "slot_frame_selected": content(6, 6, 6, 6),
                 "divider": "", "title_banner": content(22, 8, 22, 8)}[n]
        lines.append('[sub_resource type="StyleBoxTexture" id="sb_%s"]\n%s%s' % (n, box(n), extra))
    lines.append('[sub_resource type="StyleBoxEmpty" id="sb_empty"]\n')
    lines.append("[resource]")
    lines.append('default_font = ExtResource("font_body")')
    lines.append("default_font_size = 17")
    # Label
    lines.append('Label/colors/font_color = Color(0.953, 0.906, 0.765, 1)')
    lines.append('Label/colors/font_outline_color = Color(0.17, 0.12, 0.09, 1)')
    lines.append('Label/constants/outline_size = 3')
    lines.append('Label/font_sizes/font_size = 17')
    for var, color in [("InkLabel", "Color(0.169, 0.129, 0.094, 1)"), ("DimLabel", "Color(0.541, 0.498, 0.416, 1)"),
                       ("DangerLabel", "Color(0.89, 0.42, 0.34, 1)"), ("BrassLabel", "Color(0.82, 0.69, 0.35, 1)"),
                       ("HeadingLabel", "Color(0.953, 0.906, 0.765, 1)"), ("InkHeadingLabel", "Color(0.169, 0.129, 0.094, 1)")]:
        lines.append('%s/base_type = &"Label"' % var)
        lines.append("%s/colors/font_color = %s" % (var, color))
        if var.startswith("Ink"):
            lines.append("%s/constants/outline_size = 0" % var)
        if "Heading" in var:
            lines.append('%s/fonts/font = SubResource("font_heading")' % var)
            lines.append("%s/font_sizes/font_size = 24" % var)
    # Panel
    lines.append('Panel/styles/panel = SubResource("sb_panel_frame")')
    lines.append('PanelContainer/styles/panel = SubResource("sb_panel_frame")')
    lines.append('DarkPanel/base_type = &"PanelContainer"')
    lines.append('DarkPanel/styles/panel = SubResource("sb_panel_frame_dark")')
    lines.append('ParchmentPanel/base_type = &"PanelContainer"')
    lines.append('ParchmentPanel/styles/panel = SubResource("sb_panel_frame")')
    lines.append('SlotPanel/base_type = &"PanelContainer"')
    lines.append('SlotPanel/styles/panel = SubResource("sb_slot_frame")')
    lines.append('SlotPanelSelected/base_type = &"PanelContainer"')
    lines.append('SlotPanelSelected/styles/panel = SubResource("sb_slot_frame_selected")')
    lines.append('Banner/base_type = &"PanelContainer"')
    lines.append('Banner/styles/panel = SubResource("sb_title_banner")')
    # Button
    for state, sb in [("normal", "button_normal"), ("hover", "button_hover"), ("pressed", "button_pressed"), ("disabled", "button_disabled"),
                      ("hover_pressed", "button_pressed")]:
        lines.append('Button/styles/%s = SubResource("sb_%s")' % (state, sb))
    lines.append('Button/styles/focus = SubResource("sb_empty")')
    lines.append("Button/colors/font_color = Color(0.953, 0.906, 0.765, 1)")
    lines.append("Button/colors/font_hover_color = Color(1, 0.945, 0.78, 1)")
    lines.append("Button/colors/font_pressed_color = Color(0.82, 0.69, 0.35, 1)")
    lines.append("Button/colors/font_hover_pressed_color = Color(0.82, 0.69, 0.35, 1)")
    lines.append("Button/colors/font_disabled_color = Color(0.541, 0.498, 0.416, 1)")
    lines.append("Button/colors/font_outline_color = Color(0.17, 0.12, 0.09, 1)")
    lines.append("Button/constants/outline_size = 3")
    # the category tabs are Buttons too
    lines.append('TabButton/base_type = &"Button"')
    for state, sb in [("normal", "tab_normal"), ("hover", "tab_hover"), ("pressed", "tab_active"), ("hover_pressed", "tab_active"), ("disabled", "tab_normal")]:
        lines.append('TabButton/styles/%s = SubResource("sb_%s")' % (state, sb))
    lines.append("TabButton/colors/font_pressed_color = Color(0.169, 0.129, 0.094, 1)")
    lines.append("TabButton/colors/font_hover_pressed_color = Color(0.169, 0.129, 0.094, 1)")
    lines.append("TabButton/constants/outline_size = 0")
    # separators
    lines.append('HSeparator/styles/separator = SubResource("sb_divider")')
    lines.append("HSeparator/constants/separation = 12")
    return "\n".join(lines) + "\n"


def ui_config_text():
    return '[gd_resource type="Resource" load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://scripts/ui_config.gd" id="1"]\n\n[resource]\nscript = ExtResource("1")\n'


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main():
    os.makedirs(OUT, exist_ok=True)
    manifest = {"generated": {}}
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as f:
            manifest = json.load(f)
    wrote, kept = [], []

    def guarded(name, write):
        path = os.path.join(OUT, name)
        if os.path.exists(path):
            rec = manifest["generated"].get(name)
            if rec is None or rec != sha(path):
                kept.append(name)
                return
        write(path)
        manifest["generated"][name] = sha(path)
        wrote.append(name)

    for name, fn in ASSETS.items():
        guarded(name, lambda p, fn=fn: fn().save(p))
    guarded("theme.tres", lambda p: open(p, "w", encoding="utf-8", newline="\n").write(theme_text()))
    guarded("ui_config.tres", lambda p: open(p, "w", encoding="utf-8", newline="\n").write(ui_config_text()))
    manifest["generated"] = dict(sorted(manifest["generated"].items()))
    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")
    print("wrote %d file(s), kept %d of yours" % (len(wrote), len(kept)))
    for k in kept:
        print("  kept:", k)


if __name__ == "__main__":
    main()
