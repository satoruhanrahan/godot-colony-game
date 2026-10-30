extends AnimatedSprite2D

enum State { IDLE, PROCESSING }

const PLANK_PROCESS_TIME: float = 2.0
const PLANKS_PER_LOG: int = 3

# Most logs the Sawmill holds at once (counting the one being sawn). A delivery is
# refused when it is full.
@export var BUFFER_CAP: int = 3
# Set when it was built from a blueprint (what dismantling returns); the one placed in the scene by hand falls
# back to the Sawmill type.
@export var building_type: BuildingType

var logs_buffered: int = 0
var planks_ready: int = 0
var state: State = State.IDLE
var timer: float = 0.0

func _ready() -> void:
	add_to_group("sawmills")
	add_to_group("build_blockers")

# Where the player stands near to use it.
func interact_point() -> Vector2:
	return global_position + Vector2(0, -8)

func has_room() -> bool:
	return logs_buffered < BUFFER_CAP

# Takes a delivered log; returns false (and takes nothing) if the buffer is full.
func accept_log() -> bool:
	if not has_room():
		return false
	logs_buffered += 1
	return true

func _process(delta: float) -> void:
	match state:
		State.IDLE:
			if logs_buffered >= 1:
				state = State.PROCESSING
				timer = PLANK_PROCESS_TIME
		State.PROCESSING:
			timer -= delta
			if timer <= 0.0:
				logs_buffered -= 1
				planks_ready += PLANKS_PER_LOG
				state = State.IDLE
				print("Plank batch finished, planks_ready = %d" % planks_ready)
