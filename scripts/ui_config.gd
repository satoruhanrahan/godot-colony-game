extends Resource

# Every number of the UI in one place (res://ui/ui_config.tres). Sizes are for a 1080 px high window; with ui_scale_auto
# they are scaled by the window height / 1080 (clamped), so text stays the same share of the screen.

@export_group("Text")
@export var ui_font_size_small: int = 14
@export var ui_font_size_body: int = 17
@export var ui_font_size_heading: int = 24
@export var ui_text_outline: int = 3
# The font files (res://fonts/): a humanist body font and an inscriptional heading font (both OFL).
@export var font_body_path: String = "res://fonts/AlegreyaSans-Regular.ttf"
@export var font_body_bold_path: String = "res://fonts/AlegreyaSans-Bold.ttf"
@export var font_heading_path: String = "res://fonts/Cinzel-Variable.ttf"
@export var heading_weight: int = 600
@export var text_color: Color = Color(0.953, 0.906, 0.765)
@export var text_outline_color: Color = Color(0.11, 0.075, 0.05)

@export_group("Pixel text")
# Pixel-art UI text: pixel fonts at their NATIVE pixel size times ui_text_pixel_scale, no antialiasing, no hinting, no subpixel
# positioning, nearest filtering, a hard outline one UI pixel wide, and everything placed on the UI pixel grid (multiples of
# ui_art_pixel_scale screen pixels). Off: the smooth fonts above.
@export var ui_pixel_text: bool = true
# Screen pixels per font pixel (at a 1080 px high window; it follows ui_scale, rounded to a whole number).
@export var ui_text_pixel_scale: int = 2
@export var pixel_font_body_path: String = "res://fonts/Tiny5-Variable.ttf"
@export var pixel_font_heading_path: String = "res://fonts/Jacquard12-Regular.ttf"
# The native (crisp) size of each pixel font: Tiny5 is 8 px, Jacquard 12 is 12 px.
@export var pixel_body_native_px: int = 8
@export var pixel_heading_native_px: int = 12

@export_group("Scale")
@export var ui_scale_auto: bool = true
# Used when ui_scale_auto is off.
@export var ui_scale_manual: float = 1.0
@export var ui_reference_height: float = 1080.0
@export var ui_scale_min: float = 0.75
@export var ui_scale_max: float = 2.0
# Pixel-art UI parts (bars, icons, the held-item slot) are drawn at this whole-number multiple (times the UI scale, rounded).
@export var ui_art_pixel_scale: int = 2

@export_group("Palette")
@export var parchment: Color = Color("e8d9b0")
@export var parchment_dark: Color = Color("cdb98a")
@export var ink: Color = Color("2b2118")
@export var walnut: Color = Color("4a3426")
@export var walnut_dark: Color = Color("2e1f16")
@export var brass: Color = Color("b08d3c")
@export var verdigris: Color = Color("3f8f86")
@export var ember: Color = Color("d9822b")
@export var danger: Color = Color("a33a2c")
@export var disabled: Color = Color("8a7f6a")

@export_group("Build menu")
@export var menu_fade_seconds: float = 0.1
@export var menu_width: float = 520.0
@export var card_height: float = 112.0
