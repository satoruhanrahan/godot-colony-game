extends Node2D

enum State { STANDING, FELLED, DELIMBED }

const FELL_HITS: int = 10
const DELIMB_HITS: int = 10
const FALL_ANGLES: Array = [25.0, 50.0, 70.0, 90.0]
const FALL_TIME: float = 0.45
const CANOPY_FADE_TIME: float = 0.3

var state: State = State.STANDING
var fell_hits_remaining: int = FELL_HITS
var delimb_hits_remaining: int = DELIMB_HITS
var logs_ready: int = 0

# Who is working this tree (the Lumberjack or the MainCharacter), so two workers never
# chop the same tree. A worker must claim before swinging and release when he stops.
var claimed_by = null
# Who has claimed the ready log, and where a log that was dropped lies (a Trunk that left
# the tree is a Sprite2D in the world; this points at it so the Hauler can still find it).
var log_claimed_by = null
var dropped_log: Node2D = null

var falling: bool = false
var fall_direction: float = 1.0
var fall_elapsed: float = 0.0
var fall_pose: int = 0

var fading: bool = false
var fade_elapsed: float = 0.0

@onready var canopy: Sprite2D = $Canopy

func _ready() -> void:
	add_to_group("trees")

func _process(delta: float) -> void:
	if falling:
		fall_elapsed += delta
		var step_time: float = FALL_TIME / FALL_ANGLES.size()
		var poses_due: int = mini(int(fall_elapsed / step_time), FALL_ANGLES.size())
		while fall_pose < poses_due:
			rotation_degrees = fall_direction * FALL_ANGLES[fall_pose]
			fall_pose += 1
		if fall_pose >= FALL_ANGLES.size():
			falling = false
			_drop_branches()
	if fading:
		fade_elapsed += delta
		var alpha: float = 1.0 - fade_elapsed / CANOPY_FADE_TIME
		if alpha <= 0.0:
			canopy.visible = false
			fading = false
		else:
			canopy.modulate.a = alpha

# A felled tree leaves branches_per_tree (1 to 3) branch items on the ground beside its log (plain items: nobody
# claims them).
func _drop_branches() -> void:
	var cfg: Resource = load("res://scripts/food_config.gd").cfg()
	var Items = load("res://scripts/items.gd")
	var count: int = randi_range(cfg.branches_per_tree_min, cfg.branches_per_tree_max)
	for i in count:
		var near: Vector2 = position + Vector2(randf_range(-26.0, 26.0), randf_range(4.0, 16.0))
		Items.put(get_tree(), get_parent(), &"branch", near, Rect2(0, 0, 640, 640))

func receive_hit() -> void:
	match state:
		State.STANDING:
			fell_hits_remaining -= 1
			if fell_hits_remaining <= 0:
				state = State.FELLED
				_start_fall()
		State.FELLED:
			delimb_hits_remaining -= 1
			if delimb_hits_remaining <= 0:
				state = State.DELIMBED
				fading = true
				fade_elapsed = 0.0
				logs_ready += 1
				print("Log ready")
		State.DELIMBED:
			pass

func is_delimbed() -> bool:
	return state == State.DELIMBED

func is_standing() -> bool:
	return state == State.STANDING

func is_felled() -> bool:
	return state == State.FELLED

func try_claim(who) -> bool:
	if claimed_by != null and claimed_by != who:
		return false
	claimed_by = who
	return true

func release_claim(who) -> void:
	if claimed_by == who:
		claimed_by = null

# The log lying here once the tree is delimbed: its own Trunk, or one a worker dropped.
func log_node() -> Node2D:
	if is_instance_valid(dropped_log):
		return dropped_log
	return get_node_or_null("Trunk")

# Takes the ready log for `who` (it no longer counts as ready, so nobody else can take it)
# and returns its node, or null if there is none to take.
func claim_log(who) -> Node2D:
	if logs_ready <= 0:
		return null
	logs_ready -= 1
	log_claimed_by = who
	return log_node()

# A claimed log put down where it lies: ready for anyone to take again.
func return_log(trunk: Node2D) -> void:
	dropped_log = trunk
	log_claimed_by = null
	logs_ready += 1

# The log has been used up (sawn or delivered).
func finish_log() -> void:
	log_claimed_by = null
	dropped_log = null

func _start_fall() -> void:
	# Positive rotation is clockwise (tree falls right), so fall right unless
	# the chopper is on the right-hand side.
	# Falls away from whoever is chopping it.
	var worker = claimed_by if claimed_by != null else get_node_or_null("../Lumberjack")
	fall_direction = 1.0
	if worker != null and worker.position.x > position.x:
		fall_direction = -1.0
	falling = true
	fall_elapsed = 0.0
	fall_pose = 0
	AudioManager.play("tree_fall", global_position, 1.0)
