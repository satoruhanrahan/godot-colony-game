extends Sprite2D

# An item of the food chain lying on the ground (see items.gd): one sprite, no collision, its origin at the
# bottom of its art so it sorts like everything else. A seed bag shows the same picture full or empty; its count
# is in the hover text only (see hover_names.gd, the one system that names every pickup). The player takes it with E or
# a click and puts it down with Q.

@export var kind: StringName = &"branch"
# Only for the seed bag: how many seeds are in it.
@export var seeds: int = 0
# Only for the bucket: how many scoops of water are in it.
@export var scoops: int = 0

# The number this item carries (seeds in a seed bag, scoops in a bucket).
func amount() -> int:
	return scoops if kind == &"bucket" else seeds

const Items = preload("res://scripts/items.gd")
const BundleArt = preload("res://scripts/bundle_art.gd")

func _ready() -> void:
	add_to_group("ground_items")
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture = Items.texture(kind)
	offset = BundleArt.offset_for(texture)

func interact_point() -> Vector2:
	return global_position + Vector2(0, -2)

func hover_rect() -> Rect2:
	return Rect2(global_position + Vector2(-8, -13), Vector2(16, 15))
