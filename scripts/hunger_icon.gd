extends TextureRect

# The little berry beside the Hunger bar. It is its own small node so it is easy to swap: put a picture at
# res://sprites/hunger_icon.png and it is used instead of the berry drawn in code (PixelIcons.berry).

const PixelIcons = preload("res://scripts/pixel_icons.gd")
const ART_PATH: String = "res://sprites/hunger_icon.png"

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	stretch_mode = TextureRect.STRETCH_KEEP
	expand_mode = TextureRect.EXPAND_KEEP_SIZE
	texture = load(ART_PATH) if ResourceLoader.exists(ART_PATH) else PixelIcons.berry()
	size = texture.get_size()
