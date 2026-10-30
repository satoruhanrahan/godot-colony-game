extends RefCounted

# The rope-and-log drag, shared by the Hauler and the MainCharacter.
# The log trails on the side opposite the carrier's facing, with its near end LOG_NEAR_GAP
# from the carrier's x (so the log's centre sits roughly one log length behind him). The
# hand pixel is relative to his feet on the trailing side; LOG_Y puts the log's centre row
# just above his feet. The lying Trunk becomes the log: it is moved into the main (y-sorted)
# scene keeping its world transform, and a rope is tied to the end nearest him.

const LOG_NEAR_GAP: float = 11.0
const LOG_Y: float = -4.0
const LOG_LENGTH: float = 14.0
const HAND_OFFSET: Vector2 = Vector2(4.5, -4.5)
const ROPE_COLOR: Color = Color(0.48, 0.32, 0.17)

# `carrier` has the feet position (its parent is the y-sorted world); `facing` is the
# AnimatedSprite2D whose flip_h says which way he faces (they can be the same node).
var carrier: Node2D
var facing: AnimatedSprite2D
var log_node: Sprite2D = null
var rope: Line2D = null
# Which end of the log he walked up to (and so which end the rope is tied to).
var pickup_tied_top: bool = false
var log_tied_top: bool = false
# Direction (-1 / +1) he stands away from the log when picking it up.
var pickup_away: float = 1.0

func _init(carrier_node: Node2D, facing_sprite: AnimatedSprite2D) -> void:
	carrier = carrier_node
	facing = facing_sprite

func is_dragging() -> bool:
	return log_node != null

# Where he stops to pick up a lying log: level with it, just beyond whichever end is
# nearest him, at the same spacing he keeps while dragging it.
func pickup_point(trunk: Sprite2D, nudge: Vector2 = Vector2.ZERO) -> Vector2:
	var base_end: Vector2 = trunk.global_position
	var top_end: Vector2 = base_end + Vector2.UP.rotated(trunk.global_rotation) * LOG_LENGTH
	pickup_tied_top = carrier.position.distance_to(top_end) < carrier.position.distance_to(base_end)
	var near_end: Vector2 = top_end if pickup_tied_top else base_end
	var far_end: Vector2 = base_end if pickup_tied_top else top_end
	pickup_away = signf(near_end.x - far_end.x)
	if pickup_away == 0.0:
		pickup_away = 1.0
	return Vector2(near_end.x + pickup_away * (LOG_NEAR_GAP + nudge.x), base_end.y - LOG_Y + nudge.y).round()

# Ties the rope on and starts the log following him.
func attach(trunk: Sprite2D) -> void:
	if trunk == null:
		return
	var main: Node = carrier.get_parent()
	if trunk.get_parent() != main:
		trunk.reparent(main)
	log_node = trunk
	log_tied_top = pickup_tied_top

	rope = Line2D.new()
	rope.width = 1.0
	rope.default_color = ROPE_COLOR
	rope.begin_cap_mode = Line2D.LINE_CAP_BOX
	rope.end_cap_mode = Line2D.LINE_CAP_BOX
	rope.points = PackedVector2Array([Vector2.ZERO, Vector2.ZERO])
	main.add_child(rope)

# The log is used up: it and the rope go.
func release() -> void:
	if log_node != null:
		log_node.queue_free()
		log_node = null
	_remove_rope()

# The log is put down where it lies; returns it (the rope goes).
func drop() -> Sprite2D:
	var dropped: Sprite2D = log_node
	update()
	log_node = null
	_remove_rope()
	return dropped

func _remove_rope() -> void:
	if rope != null:
		rope.queue_free()
		rope = null

# Keep the log and rope on whole pixels. The log's origin is its near (tied) end; rotating
# by -90/+90 lays it out along -x/+x away from him. The rope runs from the trailing-side
# hand to the middle of that near end.
func update() -> void:
	if log_node == null:
		return
	var dir: float = -1.0 if facing.flip_h else 1.0
	var hp: Vector2 = carrier.position.round()
	# x of the end of the log nearest him (the end the rope is tied to).
	var tied_x: float = hp.x - dir * LOG_NEAR_GAP
	var origin := Vector2(tied_x, hp.y + LOG_Y)
	if log_tied_top:
		# The thin top end is the near end, so the flared base (the node's origin)
		# is the far end: lay the log out the other way round.
		origin.x = tied_x - dir * LOG_LENGTH
		log_node.rotation_degrees = 90.0 * dir
	else:
		log_node.rotation_degrees = -90.0 * dir
	log_node.position = origin

	# Pixel centres: the hand pixel, and the middle row of the log's near end.
	var hand := Vector2(hp.x - dir * HAND_OFFSET.x, hp.y + HAND_OFFSET.y)
	var tip := Vector2(tied_x - dir * 0.5, hp.y + LOG_Y - 0.5)
	# The rope's depth position sits just in front of the log's (origin.y) and behind
	# his feet; its points are relative to that position.
	rope.position = Vector2(0, hp.y + LOG_Y + 1.0)
	rope.points = PackedVector2Array([hand - rope.position, tip - rope.position])
