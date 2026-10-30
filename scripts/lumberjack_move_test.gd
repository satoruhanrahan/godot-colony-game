extends AnimatedSprite2D

const WorkerRest = preload("res://scripts/worker_rest.gd")
const WaterMap = preload("res://scripts/water_map.gd")
const WaterWalker = preload("res://scripts/water_walker.gd")
var _walker = WaterWalker.new()
const CHOP_TIME: float = 1.1
# Frame of the "chop" sheet where the axe head is fully extended. Each hit is
# counted when this frame appears, so the counter matches the visible impact.
const CHOP_STRIKE_FRAME: int = 6

@export var speed: float = 50.0

# His node origin is at his feet (so he depth-sorts by his feet).
# Where he stands relative to the tree's origin (its base) while chopping, for the
# LEFT side of the tree; the x is mirrored when he stands on the right. y is for
# his feet, so 0 puts them on the tree's base line.
# Felling: the axe head touches the standing trunk. Delimbing: the trunk now lies on
# the ground, so he stands a few pixels lower and closer to reach it.
@export var fell_stand_offset: Vector2 = Vector2(-16, 0)
@export var delimb_stand_offset: Vector2 = Vector2(-13, 7)
# The 32x32 chop frames draw the character in the bottom half and 2px left of
# centre; this sprite offset (mirrored in x when flipped) keeps his body in the same
# place as in the 16x16 walk frames (whose offset is the node's own `offset`).
# Only applied while the "chop" animation plays.
@export var chop_sprite_offset: Vector2 = Vector2(2, -16)
# When false he stays idle where he is and claims no tree.
@export var automation_enabled: bool = true

var trees: Array = []
var current_tree = null
# -1 = he stands on the tree's left (facing right), +1 = on its right (facing left).
var chop_side: float = -1.0
var base_offset: Vector2

enum State { MOVING, CHOPPING, STOPPED }

var state: State = State.MOVING
var target_position: Vector2
# His Rest need and daily routine (shared with the other workers): slower and longer swings when tired,
# stops and sleeps at dusk, works again at dawn.
var worker_rest: Node

func _ready() -> void:
	base_offset = offset
	worker_rest = WorkerRest.new()
	add_child(worker_rest)
	worker_rest.setup(self, _drain_multiplier, _at_safe_point, _abandon_task)
	# One full chop animation loop lasts exactly CHOP_TIME, so strikes land
	# CHOP_TIME apart.
	sprite_frames.set_animation_speed("chop", sprite_frames.get_frame_count("chop") / CHOP_TIME)
	frame_changed.connect(_on_frame_changed)
	trees = get_tree().get_nodes_in_group("trees")
	var next_tree = _find_next_untouched_tree()
	if next_tree == null:
		state = State.STOPPED
		play("idle")
	else:
		_start_moving_to(next_tree)

# The next tree still needing work that nobody (the MainCharacter) has claimed. That
# includes one the player started and let go: the hits already made stay, and he carries
# on from there.
func _find_next_untouched_tree():
	if not automation_enabled or not worker_rest.may_start_job():
		return null
	for t in trees:
		if not t.is_delimbed() and t.claimed_by == null:
			return t
	return null

# The awake drain now: chopping is work; walking is not.
func _drain_multiplier() -> float:
	var clock: Node = get_tree().get_first_node_in_group("game_clock")
	if clock != null and state == State.CHOPPING:
		return clock.work_drain_multiplier
	return 1.0

# Between jobs: no tree claimed.
func _at_safe_point() -> bool:
	return state == State.STOPPED

# Leaves the tree he was on (the hits made stay), so the player or anyone else can have it.
func _abandon_task() -> void:
	offset = base_offset
	if current_tree != null:
		current_tree.release_claim(self)
		current_tree = null
	state = State.STOPPED
	play("idle")

func _stand_position(tree_node, stand_offset: Vector2) -> Vector2:
	return Vector2(tree_node.position.x - chop_side * stand_offset.x, tree_node.position.y + stand_offset.y)

func _current_stand_offset() -> Vector2:
	if current_tree.fell_hits_remaining > 0:
		return fell_stand_offset
	return delimb_stand_offset

func _start_moving_to(tree_node) -> void:
	current_tree = tree_node
	tree_node.try_claim(self)
	# Stand on the side of the tree he is coming from.
	chop_side = 1.0 if position.x > tree_node.position.x else -1.0
	target_position = _stand_position(tree_node, fell_stand_offset)
	state = State.MOVING
	offset = base_offset
	play("walk")

func _on_frame_changed() -> void:
	if state == State.CHOPPING and animation == &"chop" and frame == CHOP_STRIKE_FRAME:
		current_tree.receive_hit()

func _process(delta: float) -> void:
	# On his way to a bed, or asleep (WorkerRest moves and animates him then).
	if worker_rest.takes_over():
		return
	match state:
		State.MOVING:
			if target_position.x < position.x:
				flip_h = true
			elif target_position.x > position.x:
				flip_h = false
			var before: Vector2 = position
			position = position.move_toward(_walker.next(position, target_position), speed * worker_rest.efficiency() * WaterMap.speed_factor(position) * delta)
			WaterMap.walked(self, position.distance_to(before))
			if position.distance_to(target_position) < 0.01:
				position = target_position
				state = State.CHOPPING
				flip_h = chop_side > 0.0
				offset = Vector2(chop_sprite_offset.x * (-1.0 if flip_h else 1.0), chop_sprite_offset.y)
				play("chop")
		State.CHOPPING:
			if current_tree.is_delimbed():
				offset = base_offset
				current_tree.release_claim(self)
				var next_tree = _find_next_untouched_tree()
				if next_tree == null:
					state = State.STOPPED
					play("idle")
				else:
					_start_moving_to(next_tree)
				return
			# Once the tree has fallen he shifts to the delimbing spot at walking speed.
			position = position.move_toward(_stand_position(current_tree, _current_stand_offset()), speed * worker_rest.efficiency() * delta)
		State.STOPPED:
			# Nothing left to do; picks up work again if a tree frees up or automation is
			# switched back on.
			var next_tree = _find_next_untouched_tree()
			if next_tree != null:
				_start_moving_to(next_tree)
