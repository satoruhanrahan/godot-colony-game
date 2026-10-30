extends AnimatedSprite2D

const WorkerRest = preload("res://scripts/worker_rest.gd")
const WaterMap = preload("res://scripts/water_map.gd")
const WaterWalker = preload("res://scripts/water_walker.gd")
var _walker = WaterWalker.new()

@export var speed: float = 50.0
# Where the Builder's feet stand while hammering, relative to a 1-cell Building's origin
# (the bottom edge of its sprite). The default is just outside the building's left edge,
# on the same ground line; wider buildings push it further left. He faces the building
# automatically (a negative x means he is on its left).
@export var hammer_offset: Vector2 = Vector2(-22, 0)
# When false he stays idle where he is and claims nothing.
@export var automation_enabled: bool = true

enum State { IDLE, WALKING_TO_BUILDING, HAMMERING, WALKING_HOME }

var state: State = State.IDLE
var timer: float = 0.0
var target_position: Vector2
var home_position: Vector2
var home_flip: bool = false
# The blueprint he has claimed (one at a time).
var building = null

# His Rest need and daily routine (shared with the other workers).
var worker_rest: Node

func _ready() -> void:
	home_position = position
	home_flip = flip_h
	play("idle")
	worker_rest = WorkerRest.new()
	add_child(worker_rest)
	worker_rest.setup(self, _drain_multiplier, _at_safe_point, _abandon_task)

# The awake drain now: hammering is work; walking is not.
func _drain_multiplier() -> float:
	var clock: Node = get_tree().get_first_node_in_group("game_clock")
	if clock != null and state == State.HAMMERING:
		return clock.work_drain_multiplier
	return 1.0

# Between jobs: no blueprint claimed (walking home counts: nothing is held).
func _at_safe_point() -> bool:
	return state == State.IDLE or state == State.WALKING_HOME

# Lets go of the blueprint (whatever was built stays; it can be claimed again) and stands idle.
func _abandon_task() -> void:
	if building != null and is_instance_valid(building):
		building.release_claim(self)
	building = null
	state = State.IDLE
	play("idle")

func _process(delta: float) -> void:
	# On his way to a bed, or asleep (WorkerRest moves and animates him then).
	if worker_rest.takes_over():
		return
	# The blueprint he was heading for has been dismantled or cancelled: drop that job cleanly.
	# (A freed object is not == null, so ask is_instance_valid on its own: the job goes when its blueprint does.)
	if (state == State.WALKING_TO_BUILDING or state == State.HAMMERING) and not is_instance_valid(building):
		building = null
		state = State.IDLE
		play("idle")
	match state:
		State.IDLE:
			_claim_next_building()
		State.WALKING_TO_BUILDING:
			if _move_to_target(delta):
				# Arrived: face the building and start hammering. The build timer starts here.
				flip_h = _hammer_offset_for(building).x > 0.0
				building.start_building()
				# (Full time for a fresh blueprint; less if the player already hammered some.)
				timer = building.build_time * building.remaining_fraction()
				state = State.HAMMERING
				play("hammer")
		State.HAMMERING:
			# Tired, the same job takes longer (the hammer animation plays slower too).
			timer -= delta * worker_rest.efficiency()
			if timer <= 0.0:
				var done_name: String = building.display_name()
				building.release_claim(self)
				building.finish_building()
				print("%s built!" % done_name)
				building = null
				target_position = home_position
				state = State.WALKING_HOME
				play("walk")
		State.WALKING_HOME:
			# A freshly supplied blueprint turns him round at once; otherwise he goes home.
			if not _claim_next_building() and _move_to_target(delta):
				flip_h = home_flip
				state = State.IDLE
				play("idle")

# Picks the nearest blueprint that has all its planks and no Builder yet.
func _claim_next_building() -> bool:
	if not automation_enabled or not worker_rest.may_start_job():
		return false
	var best = null
	var best_dist: float = INF
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.global_position.x >= 2000.0:
			continue   # (a Wooden Bed blueprint in a room is for the player)
		if not b.is_fully_supplied():
			continue
		var d: float = position.distance_squared_to(b.position)
		if d < best_dist:
			best_dist = d
			best = b
	if best == null:
		return false
	building = best
	building.try_claim(self)
	target_position = (building.position + _hammer_offset_for(building)).round()
	state = State.WALKING_TO_BUILDING
	# He carries his hammer on the way over (his other walking is the plain walk).
	play("carry_hammer")
	return true

func _hammer_offset_for(b) -> Vector2:
	return Vector2(hammer_offset.x - (b.footprint.x - 1) * 16.0, hammer_offset.y)

func _move_to_target(delta: float) -> bool:
	if target_position.x < position.x:
		flip_h = true
	elif target_position.x > position.x:
		flip_h = false
	var before: Vector2 = position
	position = position.move_toward(_walker.next(position, target_position), speed * worker_rest.efficiency() * WaterMap.speed_factor(position) * delta)
	WaterMap.walked(self, position.distance_to(before))
	return position.distance_to(target_position) < 0.01
