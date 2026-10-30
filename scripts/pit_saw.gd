extends Node2D

# A two-person pit saw. The MainCharacter loads a log and, with a free colonist, saws it
# into planks. Its planks are collected by the Hauler exactly like the Sawmill's.
#
# It is dug by the player in three stages: MARKED ground, a HALF_DUG hole, then BUILT (the
# finished pit saw, with everything above). The first two are flat marks on the ground,
# drawn below every character (z -1, not y-sorted), with no collision. Nothing can be
# loaded or sawn until it is BUILT.
#
# The node's origin is the bottom edge of the pit (so it depth-sorts by its base). The
# static sprite and the in-use sprite share one 32x32 canvas and one offset, so nothing
# jumps when they swap.

const PlankPiles = preload("res://scripts/plank_piles.gd")
const GroundPlacement = preload("res://scripts/ground_placement.gd")

enum State { EMPTY, LOADED, WAITING_FOR_WORKERS, SAWING }
enum Stage { MARKED, HALF_DUG, BUILT }

# False: starts as marked ground, ready to dig. True: already a finished pit saw.
@export var starts_built: bool = true
# Three things finish it, in any order: digging (DIG_HITS strikes), planks brought to it, and
# a saw blade brought to it. Delivered planks and blades are used up.
@export var DIG_HITS: int = 12
@export var PLANKS_REQUIRED: int = 2
@export var BLADES_REQUIRED: int = 1
# Once dug and supplied it is "ready to build" (it keeps the half-dug hole look) and is
# finished by hammering, like the other buildings: this many blows.
@export var PIT_BUILD_HITS: int = 6
# Where the player stands to hammer it, relative to the origin: beside the pit, outside the
# footprint, facing it.
@export var hammer_spot: Vector2 = Vector2(-22, -4)
# Where the player stands to dig, relative to the origin: beside the pit, outside the
# footprint (so he is never inside it when it finishes), facing it.
@export var dig_spot: Vector2 = Vector2(-20, -4)

@export var PIT_SAW_TIME: float = 6.0
@export var PLANKS_PER_LOG: int = 3
# (There is no longer a limit on the planks lying round the pit: the saw always works. A finished job puts its planks on the
# nearest free ground within plank_search_tiles; with none there they wait and the saw says "No room for the planks.")
@export var plank_search_tiles: float = 12.0
# Where the finished pile of planks is put, relative to the origin (beside the pit, outside
# its footprint). If another pile is already there the nearest free spot is used.
@export var plank_drop_spot: Vector2 = Vector2(26, 2)
# Piles are only put inside the map.
@export var map_rect: Rect2 = Rect2(0, 0, 640, 640)
# The loaded log (sawpit.png has no log of its own) is the tree trunk sprite lying across the
# pit, set to match the log drawn in the first frame of sawpit_in_use pixel for pixel: the
# thick, flared stump end on the right. A plain flip_h cannot do that (the log lies along the
# sprite's y axis once rotated, and flip_h mirrors across the other axis), so the default is a
# -90 degree rotation; flip_h / flip_v are here to nudge it. The offset is the sprite centre's
# position relative to the pit's origin.
@export var loaded_log_offset: Vector2 = Vector2(-7, -7)
@export var loaded_log_rotation_degrees: float = -90.0
@export var loaded_log_flip_h: bool = false
@export var loaded_log_flip_v: bool = false
# Where the MainCharacter and the colonist stand to saw, relative to the origin. The
# MainCharacter's is where the sawyer is drawn in sawpit_in_use (he is behind the pit);
# the colonist is not drawn, and stands at the front.
@export var player_spot: Vector2 = Vector2(2, -10)
@export var colonist_spot: Vector2 = Vector2(-8, 9)

var state: State = State.EMPTY
var stage: Stage = Stage.BUILT
var dig_count: int = 0
var planks_delivered: int = 0
var blades_delivered: int = 0
var build_progress: int = 0
var timer: float = 0.0
var player = null
var worker = null
var player_arrived: bool = false
var worker_arrived_flag: bool = false
# The saw's looping sound (AudioManager handle), and the time to the next puff of sawdust.
var _saw_loop: int = 0
var _sawdust_left: float = 0.0
var _ready_done: bool = false
# A puff of sawdust every this many seconds while it saws.
@export var sawdust_interval: float = 0.45

@onready var static_sprite: Sprite2D = $Static
@onready var loaded_log: Sprite2D = $LoadedLog
@onready var in_use: AnimatedSprite2D = $InUse
@onready var marked_sprite: Sprite2D = $Marked
@onready var half_dug_sprite: Sprite2D = $HalfDug
@onready var shape: CollisionShape2D = $Collision/Shape

func _ready() -> void:
	add_to_group("pit_saws")
	add_to_group("build_blockers")
	loaded_log.position = loaded_log_offset
	loaded_log.rotation_degrees = loaded_log_rotation_degrees
	loaded_log.flip_h = loaded_log_flip_h
	loaded_log.flip_v = loaded_log_flip_v
	loaded_log.visible = false
	in_use.visible = false
	# Start unfinished; a pit saw that starts built has everything in already.
	stage = Stage.MARKED
	if starts_built:
		dig_count = DIG_HITS
		planks_delivered = PLANKS_REQUIRED
		blades_delivered = BLADES_REQUIRED
		build_progress = PIT_BUILD_HITS
	_update_stage()
	_ready_done = true

func _process(delta: float) -> void:
	if _pending_planks > 0:
		_retry_left -= delta
		if _retry_left <= 0.0:
			_put_out_planks()
	if state == State.SAWING:
		# The saw runs at the efficiency of the more tired sawyer, and its animation with it.
		var efficiency: float = _saw_efficiency()
		timer -= delta * efficiency
		in_use.speed_scale = efficiency
		var progress = _work_progress()
		if progress != null:
			progress.report_time(self, 1.0 - timer / PIT_SAW_TIME, &"saw")
		# By ear and eye: the rasp stays at one pitch and volume; puffs of sawdust.
		_sawdust_left -= delta
		if _sawdust_left <= 0.0:
			_sawdust_left = sawdust_interval
			load("res://scripts/work_fx.gd").sawdust(get_tree(), global_position + Vector2(0, -8))
		if timer <= 0.0:
			_finish_sawing()

# The lower of the two sawyers' efficiencies (1 if there is no Rest meter); a lone sawyer's own work factor on top.
func _saw_efficiency() -> float:
	var e: float = solo_efficiency if solo else 1.0
	if player != null and is_instance_valid(player) and "rest" in player and player.rest != null:
		e = minf(e, player.rest.efficiency())
	if worker != null and is_instance_valid(worker) and "rest" in worker and worker.rest != null:
		e = minf(e, worker.rest.efficiency())
	return e

# The world progress display (bars and pips), if the scene has one.
func _work_progress():
	return get_tree().get_first_node_in_group("work_progress")

# The one-cell ground it covers (for build mode and wander checks).
func footprint_rect() -> Rect2:
	return Rect2(global_position + Vector2(-16, -32), Vector2(32, 32))

func interact_point() -> Vector2:
	return global_position + Vector2(0, -6)

func player_spot_world() -> Vector2:
	return global_position + player_spot

func colonist_spot_world() -> Vector2:
	return global_position + colonist_spot

func has_log() -> bool:
	return state != State.EMPTY

func can_saw() -> bool:
	return stage == Stage.BUILT and state == State.LOADED

# --- Digging -------------------------------------------------------------------------

func is_built() -> bool:
	return stage == Stage.BUILT

# Still has digging to do.
func can_dig() -> bool:
	return dig_count < DIG_HITS

func dig_spot_world() -> Vector2:
	return global_position + dig_spot

# One dig (the shovel strike).
func dig() -> void:
	if not can_dig():
		return
	dig_count += 1
	_update_stage()

func planks_missing() -> int:
	return maxi(0, PLANKS_REQUIRED - planks_delivered)

func blades_missing() -> int:
	return maxi(0, BLADES_REQUIRED - blades_delivered)

func materials_complete() -> bool:
	return planks_missing() == 0 and blades_missing() == 0

# Fully dug but still waiting for planks and / or the saw blade.
func needs_materials() -> bool:
	return not can_dig() and not materials_complete() and not is_built()

# Dug and supplied: only the hammering is left.
func ready_to_build() -> bool:
	return not can_dig() and materials_complete() and not is_built()

func hammer_spot_world() -> Vector2:
	return global_position + hammer_spot

# One hammer blow (the strike frame). Only once it is ready to build.
func hammer_hit() -> void:
	if not ready_to_build():
		return
	build_progress += 1
	_update_stage()

# "Needs: dig 3/12, 1 plank, saw blade" (whatever is still missing).
func missing_text() -> String:
	var parts: PackedStringArray = []
	if can_dig():
		parts.append("dig %d/%d" % [dig_count, DIG_HITS])
	if planks_missing() > 0:
		parts.append("%d plank%s" % [planks_missing(), "" if planks_missing() == 1 else "s"])
	if blades_missing() > 0:
		parts.append("saw blade" if blades_missing() == 1 else "%d saw blades" % blades_missing())
	return "Needs: " + ", ".join(parts)

# The player hands over a plank (used up). False if it already has enough.
func add_plank() -> bool:
	if planks_missing() <= 0:
		return false
	planks_delivered += 1
	_update_stage()
	return true

# Before the first build hit the delivered plank / blade can be taken back (one at a time).
func can_take_back_plank() -> bool:
	return not is_built() and build_progress == 0 and planks_delivered > 0 and state == State.EMPTY

func can_take_back_blade() -> bool:
	return not is_built() and build_progress == 0 and blades_delivered > 0 and state == State.EMPTY

func take_back_plank() -> bool:
	if not can_take_back_plank():
		return false
	planks_delivered -= 1
	_update_stage()
	return true

func take_back_blade() -> bool:
	if not can_take_back_blade():
		return false
	blades_delivered -= 1
	_update_stage()
	return true

# The player hands over the saw blade (used up). False if it already has enough.
func add_blade() -> bool:
	if blades_missing() <= 0:
		return false
	blades_delivered += 1
	_update_stage()
	return true

# marked below half the digging, the half-dug hole from half the digging on (also when fully
# dug, waiting for materials, or ready to build), the finished pit saw only once it has been
# dug, supplied and hammered.
func _update_stage() -> void:
	var before: Stage = stage
	if stage != Stage.BUILT:
		if dig_count >= DIG_HITS and materials_complete() and build_progress >= PIT_BUILD_HITS:
			stage = Stage.BUILT
		elif dig_count * 2 >= DIG_HITS:
			stage = Stage.HALF_DUG
		else:
			stage = Stage.MARKED
	if stage == Stage.BUILT and before != Stage.BUILT:
		print("Pit saw: finished (dug, supplied and hammered)")
		if _ready_done:
			load("res://scripts/work_feedback.gd").completed(get_tree(), global_position)
	_apply_stage()

# Shows the sprite for the current stage (all three sit on one canvas and offset, so
# nothing moves), and gives it collision only once it is built.
func _apply_stage() -> void:
	var built: bool = stage == Stage.BUILT
	marked_sprite.visible = stage == Stage.MARKED
	half_dug_sprite.visible = stage == Stage.HALF_DUG
	static_sprite.visible = built
	shape.set_deferred("disabled", not built)

# --- Loading -------------------------------------------------------------------------

func can_load() -> bool:
	return stage == Stage.BUILT and state == State.EMPTY

func load_refusal() -> String:
	if stage != Stage.BUILT:
		return "The pit saw isn't finished yet"
	if state != State.EMPTY:
		return "The pit saw already holds a log"
	return "The pit saw is busy"

# Takes a log (one slot); false if it is not allowed right now.
func accept_log() -> bool:
	if not can_load():
		return false
	state = State.LOADED
	loaded_log.visible = true
	print("Pit saw loaded")
	return true

# --- Sawing (needs two people) -------------------------------------------------------

# The MainCharacter asks to start. Returns "" if sawing is on its way, else a message.
func request_saw(who) -> String:
	if stage != Stage.BUILT:
		return "The pit saw isn't finished yet"
	if state != State.LOADED:
		return "Load a log into the pit saw first"
	var helper = _nearest_free_colonist()
	if helper == null:
		return _no_helper_message()
	state = State.WAITING_FOR_WORKERS
	player = who
	worker = helper
	player_arrived = false
	worker_arrived_flag = false
	helper.claim_for_work(self, colonist_spot_world())
	who.start_saw_walk(self)
	print("Pit saw: %s comes to help" % helper.name)
	return ""

# Colonists who are awake and not busy; not those asleep or inside, nor too tired (the Rest need),
# nor on their way to a house or already working.
func _nearest_free_colonist():
	var best = null
	var best_dist: float = INF
	for c in get_tree().get_nodes_in_group("colonists"):
		if not c.is_available_for_work() or c.is_too_tired_to_work():
			continue
		var d: float = c.position.distance_squared_to(global_position)
		if d < best_dist:
			best_dist = d
			best = c
	return best

# Why nobody can help: someone is awake but too tired, or someone is asleep (or inside), or nobody
# is free.
func _no_helper_message() -> String:
	var tired: bool = false
	var asleep: bool = false
	for c in get_tree().get_nodes_in_group("colonists"):
		if c.work_claim != null:
			continue
		if c.is_asleep() and not c.is_available_for_work():
			asleep = true
		elif c.is_available_for_work() and c.is_too_tired_to_work():
			tired = true
	if tired:
		return "Your friend is too tired to saw"
	if asleep:
		return "He's asleep"
	return "Need a free colonist to work the saw"

func player_arrived_at_spot() -> void:
	player_arrived = true
	_check_start()

func worker_arrived(who) -> void:
	if who == worker:
		worker_arrived_flag = true
		_check_start()

func _check_start() -> void:
	if state == State.WAITING_FOR_WORKERS and player_arrived and worker_arrived_flag:
		_begin_sawing()

# The player walked off (or the helper went missing) before sawing began: the log stays
# loaded, and the colonist is let go.
func cancel_request() -> void:
	if state != State.WAITING_FOR_WORKERS:
		return
	state = State.LOADED
	if worker != null and is_instance_valid(worker):
		worker.release_work()
	worker = null
	player = null

# A colonist saws ALONE (the Sawyer role / the "saw logs" task): the log must be in (LOADED); he is hidden at the saw until it is done, at
# `efficiency` of the pace (friend_work_efficiency). Returns false when the saw cannot start.
var solo: bool = false
var solo_efficiency: float = 1.0

func begin_solo(colonist, efficiency: float = 1.0) -> bool:
	if stage != Stage.BUILT or state != State.LOADED:
		return false
	player = null
	worker = colonist
	solo = true
	solo_efficiency = efficiency
	state = State.SAWING
	timer = PIT_SAW_TIME
	static_sprite.visible = false
	loaded_log.visible = false
	in_use.visible = true
	in_use.play("sawing")
	_saw_loop = AudioManager.play_loop("saw_loop", global_position, 1.0, -3.0)
	_sawdust_left = 0.0
	colonist.hide_for_work()
	return true

# He is called away mid-saw (he is hungry, the order changes): the saw stops, the log stays in it, he is back at the saw.
func cancel_solo(colonist) -> void:
	if not solo or worker != colonist or state != State.SAWING:
		return
	in_use.speed_scale = 1.0
	AudioManager.stop_loop(_saw_loop)
	_saw_loop = 0
	in_use.stop()
	in_use.visible = false
	static_sprite.visible = true
	loaded_log.visible = true
	state = State.LOADED
	var progress = _work_progress()
	if progress != null:
		progress.end_time(self)
	colonist.show_after_work(colonist_spot_world())
	solo = false
	worker = null

func _begin_sawing() -> void:
	state = State.SAWING
	timer = PIT_SAW_TIME
	static_sprite.visible = false
	loaded_log.visible = false
	in_use.visible = true
	in_use.play("sawing")
	_saw_loop = AudioManager.play_loop("saw_loop", global_position, 1.0, -3.0)
	_sawdust_left = 0.0
	player.hide_for_sawing()
	worker.hide_for_work()
	print("Pit saw: sawing started")

func _finish_sawing() -> void:
	in_use.speed_scale = 1.0
	AudioManager.stop_loop(_saw_loop)
	_saw_loop = 0
	AudioManager.play("plank_drop", global_position, 1.0)
	var progress = _work_progress()
	if progress != null:
		progress.end_time(self)
	in_use.stop()
	in_use.visible = false
	static_sprite.visible = true
	if player != null and is_instance_valid(player):
		player.show_after_sawing()
	worker.show_after_work(colonist_spot_world())
	# (A lone sawyer was never claimed through claim_for_work: he is simply back, in his order.)
	if not solo:
		worker.release_work()
	solo = false
	worker = null
	player = null
	# One pile of planks (at most three), on the nearest free ground to the drop spot (up to plank_search_tiles away).
	state = State.EMPTY
	_pending_planks = mini(PLANKS_PER_LOG, PlankPiles.MAX_PER_PILE)
	_put_out_planks()

# Planks of a finished job that have not found room yet (the saw keeps them and tries again every half second).
var _pending_planks: int = 0
var _retry_left: float = 0.0
var last_pile_spot: Vector2 = Vector2.INF

func _put_out_planks() -> void:
	if _pending_planks <= 0:
		return
	var drop: Vector2 = global_position + plank_drop_spot
	var spot: Vector2 = GroundPlacement.find_free_ground_near(get_tree(), drop, Vector2(20, 10), map_rect, plank_search_tiles * 32.0)
	if spot == Vector2.INF:
		var hud: Node = get_tree().get_first_node_in_group("hud")
		if hud != null:
			hud.say("No room for the planks.")
		_retry_left = 0.5
		return
	PlankPiles.spawn_pile(get_parent(), spot, _pending_planks)
	print("Pit saw: pile of %d planks at %s" % [_pending_planks, spot])
	_pending_planks = 0
	last_pile_spot = spot
