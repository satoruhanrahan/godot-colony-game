extends Sprite2D

# A basket lying on the ground, with the berries that are in it (a dropped basket keeps its contents). No
# collision; the node's origin is the base of the basket so it depth-sorts by it. The player picks it up with E
# or a click and puts it down with Q or a right-click, like a tool; he holds one thing at a time, so carrying a
# basket means holding nothing else.

const BundleArt = preload("res://scripts/bundle_art.gd")

@export var berries: int = 0

func _ready() -> void:
	add_to_group("baskets")
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	offset = BundleArt.offset_for(texture)

func interact_point() -> Vector2:
	return global_position + Vector2(0, -2)
