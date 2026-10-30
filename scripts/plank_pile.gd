extends Node2D

# A pile of 1 to 3 planks lying on the ground. It shows one_plank / two_planks / three_planks
# to match its count. The node's origin is the base of the pile (so it depth-sorts by it);
# the three images are drawn on different parts of their canvases, so each carries an offset
# that puts its bottom-centre on that origin and nothing shifts when the count changes. No
# collision. A pile is freed when it reaches 0 planks.

const MAX_PLANKS: int = 3
const TEXTURES: Array[Texture2D] = [
	null,
	preload("res://sprites/one_plank.png"),
	preload("res://sprites/two_planks.png"),
	preload("res://sprites/three_planks.png"),
]
# Offsets that put the bottom-centre of each image's art on the origin (art bottom-centre
# is at canvas (20, 24) for one plank and (20, 27) for two and three).
const OFFSETS: Array[Vector2] = [
	Vector2.ZERO,
	Vector2(-4, -8),
	Vector2(-4, -11),
	Vector2(-4, -11),
]

var count: int = 1:
	set(value):
		count = clampi(value, 0, MAX_PLANKS)
		if count <= 0:
			# Gone: stop counting as a pile right away (queue_free lands at the end of the frame).
			remove_from_group("plank_piles")
			queue_free()
		else:
			_refresh()
# Planks a carrier (the Hauler) has claimed and is walking over to take, so nobody else
# takes the same plank.
var reserved: int = 0

@onready var sprite: Sprite2D = $Sprite

func _ready() -> void:
	add_to_group("plank_piles")
	_refresh()

func _refresh() -> void:
	if sprite == null or count <= 0:
		return
	sprite.texture = TEXTURES[count]
	sprite.offset = OFFSETS[count]

# Planks nobody has claimed.
func available() -> int:
	return count - reserved

func is_full() -> bool:
	return count >= MAX_PLANKS

# Puts one plank on the pile; false if it is full.
func add_plank() -> bool:
	if is_full():
		return false
	count += 1
	return true

# Takes one unclaimed plank (the player's, instant); false if none is free.
func take_free() -> bool:
	if available() <= 0:
		return false
	count -= 1
	return true

# Claims one unclaimed plank for a carrier on his way; false if none is free.
func reserve() -> bool:
	if available() <= 0:
		return false
	reserved += 1
	return true

# The carrier arrived: takes the plank he claimed.
func take_reserved() -> void:
	reserved = maxi(0, reserved - 1)
	count -= 1

func interact_point() -> Vector2:
	return global_position
