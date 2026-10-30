extends Sprite2D

# A patch of grass on the ground: tall (it can be pulled) or stubble (it grows back). The node's origin is
# the base of the patch, so it depth-sorts by it like everything else; no collision. The player pulls it
# with E or a click, four pulls (PULL_HITS), and gets a bundle of hay; the patch becomes stubble and is
# tall again after regrow_clock_seconds of clock time (so clock_speed_multiplier speeds the regrowth up).

const TALL: Texture2D = preload("res://sprites/grass_patch.png")
const STUBBLE: Texture2D = preload("res://sprites/grass_stubble.png")

@export var PULL_HITS: int = 4
# One full clock-day by default.
@export var regrow_clock_seconds: float = 600.0

var tall: bool = true
# Pulls made so far on this patch.
var pull_progress: int = 0
# Who is pulling it (the player), so nobody else starts on it.
var claimed_by = null
var regrow_left: float = 0.0

func _ready() -> void:
	add_to_group("grass_patches")
	texture = TALL

func is_tall() -> bool:
	return tall

func try_claim(who) -> bool:
	if not tall or (claimed_by != null and claimed_by != who):
		return false
	claimed_by = who
	return true

func release_claim(who) -> void:
	if claimed_by == who:
		claimed_by = null

func interact_point() -> Vector2:
	return global_position + Vector2(0, -2)

# One pull. Returns true when it was the last one (the patch is stubble now).
func pull_hit() -> bool:
	if not tall:
		return false
	pull_progress += 1
	if pull_progress >= PULL_HITS:
		_become_stubble()
		return true
	return false

func _become_stubble() -> void:
	tall = false
	pull_progress = 0
	claimed_by = null
	regrow_left = regrow_clock_seconds
	texture = STUBBLE

func _process(delta: float) -> void:
	if tall:
		return
	var clock: Node = get_tree().get_first_node_in_group("game_clock")
	regrow_left -= clock.clock_delta if clock != null else delta
	if regrow_left <= 0.0:
		tall = true
		texture = TALL
