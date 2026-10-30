extends AnimatedSprite2D

const PICKUP_TIME: float = 0.4
const DROPOFF_TIME: float = 0.4
const TILE_SIZE: float = 32.0

# His node origin is at his FEET (so he depth-sorts by them); all offsets below
# are relative to that.
# Where he stops (feet position) relative to the Sawmill's / a Building's / Storage's
# origin, which is the bottom edge of their sprites. The Storage one is just in front of
# its door, which is also where a log leaving Storage is laid down.
const SAWMILL_STOP_OFFSET: Vector2 = Vector2(0, 27)
const BUILDING_STOP_OFFSET: Vector2 = Vector2(0, 31)
const STORAGE_STOP_OFFSET: Vector2 = Vector2(0, 16)

const WorkerRest = preload("res://scripts/worker_rest.gd")
const WaterMap = preload("res://scripts/water_map.gd")
const WaterWalker = preload("res://scripts/water_walker.gd")
var _walker = WaterWalker.new()
const LogDragger = preload("res://scripts/log_dragger.gd")
const PlankPiles = preload("res://scripts/plank_piles.gd")
const TRUNK_TEXTURE: Texture2D = preload("res://sprites/tree_trunk.png")

@export var speed: float = 50.0
# Multiplier applied to `speed` while a log is being dragged (planks are not affected).
@export var carry_speed_multiplier: float = 0.5
# Multiplier applied to `speed` while he is carrying planks.
@export var plank_carry_speed_multiplier: float = 0.75
# Nudge for where he stops at a log. x = extra distance away from the log's end
# (0 = the same spacing he keeps while dragging it), y = vertical shift.
@export var log_pickup_offset: Vector2 = Vector2.ZERO
# When false he stays idle where he is and claims nothing.
@export var automation_enabled: bool = true
# He carries exactly one plank per trip. When true he may also take a plank from a pile on
# the ground (only to deliver it to a blueprint that needs it).
@export var hauler_uses_piles: bool = true
# The plank yard: a spot near the Sawmill where he puts planks nobody needs yet, once Storage
# has no room. It holds yard_capacity planks (three piles) within yard_radius of the marker.
@export var plank_yard: Marker2D
@export var yard_capacity: int = 9
@export var yard_radius: float = 40.0
# A plank put on the ground goes into the nearest pile this close that has fewer than 3.
@export var pile_merge_radius: float = 20.0
# Piles are only put inside the map.
@export var map_rect: Rect2 = Rect2(0, 0, 640, 640)

# The Sawmill and Storage he works with: the nearest of each that exists (they can be built
# during the game, or not exist at all yet). Looked up whenever he is free to choose a task
# and kept for the whole trip.
var sawmill = null
var storage = null

enum Place { SAWMILL, STORAGE, BUILDING, YARD, PILE }

var trees: Array = []
# The log he is walking to or dragging: a tree's lying Trunk, or one laid down at the
# Storage door. current_log_tree is only set for a tree log (used if its Trunk is gone).
var current_log: Sprite2D = null
var current_log_tree = null
# The rope-drag (shared with the MainCharacter).
var dragger

enum State {
	IDLE,
	MOVING_TO_LOG,
	PICKING_UP_LOG,
	MOVING_WITH_LOG,
	DROPPING_OFF_LOG,
	MOVING_TO_PLANKS,
	PICKING_UP_PLANKS,
	MOVING_WITH_PLANKS,
	DROPPING_OFF_PLANKS,
}

var state: State = State.IDLE
var target_position: Vector2
var timer: float = 0.0
var carrying_planks: int = 0
# A task is claimed the moment it is chosen: the log or planks come off the tree /
# Sawmill / Storage count straight away, so nothing can pick the same ones twice.
var log_dest: Place = Place.SAWMILL
var plank_dest: Place = Place.BUILDING
var plank_source: Place = Place.SAWMILL
var claimed_planks: int = 0
# The blueprint the planks are for, and how many of them are reserved on it.
var plank_building = null
var plank_reservation: int = 0
# The Sawmill, Storage or pile the claimed plank comes from.
var plank_source_node = null
# His Rest need and daily routine (shared with the other workers).
var worker_rest: Node

func _ready() -> void:
	trees = get_tree().get_nodes_in_group("trees")
	dragger = LogDragger.new(self, self)
	worker_rest = WorkerRest.new()
	add_child(worker_rest)
	worker_rest.setup(self, _drain_multiplier, _at_safe_point, _abandon_task)
	# The yard marker (set in the scene; found by name if the reference did not resolve).
	if plank_yard == null:
		plank_yard = get_node_or_null("../PlankYard") as Marker2D
	play("idle")

func _find_tree_with_logs():
	for t in trees:
		if t.logs_ready > 0:
			return t
	return null

# Task priority, re-evaluated every time he is free:
#  a. a blueprint needs a plank (counting those already delivered or on the way) and one
#     is available: from the Sawmill's output first, then a pile on the ground, then Storage
#     -> the nearest such blueprint
#  b. log at a tree, Sawmill buffer has room -> Sawmill
#  c. log at a tree, Sawmill buffer full, Storage has room -> Storage
#  d. Sawmill buffer has room, Storage holds logs -> Sawmill
#  e. a plank in the Sawmill's output no blueprint needs: Storage if it has room, else a
#     pile at the PlankYard if the yard has room (never picked up without somewhere to go)
#  f. otherwise stay idle
func _nearest_in_group(group: String):
	var best = null
	var best_dist: float = INF
	for n in get_tree().get_nodes_in_group(group):
		var d: float = position.distance_squared_to(n.position)
		if d < best_dist:
			best_dist = d
			best = n
	return best

# The awake drain now: hauling a log or carrying a plank costs more than walking empty-handed.
func _drain_multiplier() -> float:
	var clock: Node = get_tree().get_first_node_in_group("game_clock")
	if clock != null and (dragger.is_dragging() or carrying_planks > 0):
		return clock.carry_drain_multiplier
	return 1.0

# Between trips: nothing claimed, nothing carried.
func _at_safe_point() -> bool:
	return state == State.IDLE

# Leaves the trip he is on safely: gives back the claimed log or plank, puts down what he carries where
# he stands (planks into a pile, a log left lying), and stands idle.
func _abandon_task() -> void:
	# A plank claimed at its source but not yet picked up goes back.
	if claimed_planks > 0:
		match plank_source:
			Place.SAWMILL:
				if sawmill != null and is_instance_valid(sawmill):
					sawmill.planks_ready += 1
			Place.STORAGE:
				if storage != null and is_instance_valid(storage):
					storage.add_planks(1)
			Place.PILE:
				if is_instance_valid(plank_source_node):
					plank_source_node.reserved = maxi(0, plank_source_node.reserved - 1)
		claimed_planks = 0
	_release_plank_reservation()
	# A plank in his hands goes on the ground here.
	if carrying_planks > 0:
		PlankPiles.put_plank(get_tree(), get_parent(), position, pile_merge_radius, map_rect, position)
		carrying_planks = 0
	# A log: one he was walking to is given back; one he is dragging stays where it lies.
	if current_log != null:
		if dragger.is_dragging():
			var dropped: Sprite2D = dragger.drop()
			if current_log_tree != null:
				current_log_tree.return_log(dropped)
			elif storage != null and is_instance_valid(storage) and storage.add_log():
				# It came out of Storage: back in it.
				dropped.queue_free()
		else:
			if current_log_tree != null:
				current_log_tree.return_log(current_log)
			elif storage != null and is_instance_valid(storage) and storage.add_log():
				current_log.queue_free()
	current_log = null
	current_log_tree = null
	state = State.IDLE
	play("idle")

func _choose_task() -> void:
	if not automation_enabled or not worker_rest.may_start_job():
		return
	sawmill = _nearest_in_group("sawmills")
	storage = _nearest_in_group("storages")
	var target = _nearest_building_needing_planks()
	if target != null:
		if sawmill != null and sawmill.planks_ready > 0:
			_begin_plank_trip(Place.SAWMILL, sawmill, Place.BUILDING, target)
			return
		if hauler_uses_piles:
			var pile = _nearest_available_pile()
			if pile != null:
				_begin_plank_trip(Place.PILE, pile, Place.BUILDING, target)
				return
		if storage != null and storage.planks_stored > 0:
			_begin_plank_trip(Place.STORAGE, storage, Place.BUILDING, target)
			return
	var t = _find_tree_with_logs()
	if t != null:
		if sawmill != null and sawmill.has_room():
			_claim_tree_log(t, Place.SAWMILL)
			return
		if storage != null and storage.has_log_room():
			_claim_tree_log(t, Place.STORAGE)
			return
	if sawmill != null and storage != null and sawmill.has_room() and storage.logs_stored > 0:
		_claim_storage_log()
		return
	if target == null and sawmill != null and sawmill.planks_ready > 0:
		# Only with somewhere for it to go.
		if storage != null and storage.plank_room() > 0:
			_begin_plank_trip(Place.SAWMILL, sawmill, Place.STORAGE)
		elif _yard_has_room():
			_begin_plank_trip(Place.SAWMILL, sawmill, Place.YARD)

# The blueprint (counting planks already delivered or reserved by a trip) that still needs
# planks and is nearest to him.
func _nearest_building_needing_planks():
	var best = null
	var best_dist: float = INF
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.global_position.x >= 2000.0:
			continue   # (a Wooden Bed blueprint in a room is for the player)
		if b.planks_needed() <= 0:
			continue
		var d: float = position.distance_squared_to(b.position)
		if d < best_dist:
			best_dist = d
			best = b
	return best

# The nearest pile on the ground with a plank nobody has claimed.
func _nearest_available_pile():
	var best = null
	var best_dist: float = INF
	for pile in get_tree().get_nodes_in_group("plank_piles"):
		if pile.available() <= 0 or pile.global_position.x >= 2000.0:
			# (Planks lying inside a house, far off the map, are not for the Hauler.)
			continue
		var d: float = position.distance_squared_to(pile.global_position)
		if d < best_dist:
			best_dist = d
			best = pile
	return best

# Room for another plank at the PlankYard (three piles' worth by default).
func _yard_has_room() -> bool:
	return plank_yard != null and PlankPiles.planks_within(get_tree(), plank_yard.global_position, yard_radius) < yard_capacity

# Does this destination still have room for the plank he is carrying / about to carry?
func _dest_has_room(dest: Place) -> bool:
	match dest:
		Place.STORAGE:
			return storage != null and is_instance_valid(storage) and storage.plank_room() > 0
		Place.YARD:
			return _yard_has_room()
	return true

# Where he stands to take a plank from a source.
func _source_stop(src_kind: Place, src) -> Vector2:
	match src_kind:
		Place.PILE:
			return src.global_position + Vector2(0, 10)
		Place.STORAGE:
			return src.position + STORAGE_STOP_OFFSET
	return src.position + SAWMILL_STOP_OFFSET

func _claim_tree_log(t, dest: Place) -> void:
	current_log_tree = t
	current_log = t.claim_log(self)
	print("Hauler task: log %s -> %s" % [t.name, Place.keys()[dest].to_lower()])
	_begin_log_trip(dest)

func _claim_storage_log() -> void:
	storage.take_log()
	current_log_tree = null
	current_log = _spawn_storage_log()
	print("Hauler task: log storage -> sawmill")
	_begin_log_trip(Place.SAWMILL)

func _begin_log_trip(dest: Place) -> void:
	log_dest = dest
	target_position = _log_pickup_point(current_log)
	state = State.MOVING_TO_LOG
	play("walk")

# One plank per trip. The plank is claimed the moment the trip is chosen (taken off the
# Sawmill's output / Storage, reserved on the pile, reserved on the blueprint), so nobody
# else can claim the same one.
func _begin_plank_trip(source: Place, source_node, dest: Place, building = null) -> void:
	plank_source = source
	plank_source_node = source_node
	match source:
		Place.SAWMILL:
			source_node.planks_ready -= 1
		Place.STORAGE:
			source_node.take_planks(1)
		Place.PILE:
			source_node.reserve()
	claimed_planks = 1
	plank_dest = dest
	plank_building = building
	plank_reservation = 0
	var dest_name: String = Place.keys()[dest].to_lower()
	if building != null:
		# Reserve it on the blueprint now, so no other trip counts it as missing.
		plank_reservation = 1
		building.planks_reserved += 1
		dest_name = "%s (%d/%d)" % [building.name, building.planks_ready, building.plank_cost]
	print("Hauler task: 1 plank %s -> %s" % [Place.keys()[source].to_lower(), dest_name])
	target_position = _source_stop(source, source_node)
	state = State.MOVING_TO_PLANKS
	play("walk")

func _place_stop(place: Place) -> Vector2:
	match place:
		Place.SAWMILL:
			return sawmill.position + SAWMILL_STOP_OFFSET
		Place.STORAGE:
			return storage.position + STORAGE_STOP_OFFSET
		Place.YARD:
			return plank_yard.global_position
	return plank_building.position + BUILDING_STOP_OFFSET

func _release_plank_reservation() -> void:
	if plank_building != null and is_instance_valid(plank_building):
		plank_building.planks_reserved -= plank_reservation
	plank_reservation = 0
	plank_building = null

# The plank in his hands has lost its destination (its blueprint filled up, or Storage / the
# yard filled): another blueprint that needs one, else Storage, else the yard. If there is
# nowhere at all he puts it down on the ground where he stands (he never stands about
# holding it).
func _reroute_planks() -> void:
	_release_plank_reservation()
	var other = _nearest_building_needing_planks()
	if other != null:
		plank_building = other
		plank_reservation = 1
		other.planks_reserved += 1
		plank_dest = Place.BUILDING
	elif storage != null and is_instance_valid(storage) and storage.plank_room() > 0:
		plank_dest = Place.STORAGE
	elif _yard_has_room():
		plank_dest = Place.YARD
	else:
		PlankPiles.put_plank(get_tree(), get_parent(), position, pile_merge_radius, map_rect, position)
		carrying_planks = 0
		state = State.IDLE
		play("idle")
		return
	target_position = _place_stop(plank_dest)
	state = State.MOVING_WITH_PLANKS
	play("carry_plank")

# Can the plank in his hands still go where he is heading?
func _plank_target_full() -> bool:
	if plank_dest == Place.BUILDING:
		return not is_instance_valid(plank_building) or not plank_building.is_waiting() or plank_building.planks_ready >= plank_building.plank_cost
	return not _dest_has_room(plank_dest)

func _process(delta: float) -> void:
	# On his way to a bed, or asleep (WorkerRest moves and animates him then).
	if worker_rest.takes_over():
		return
	match state:
		State.IDLE:
			_choose_task()

		# Plank trips: pick up at the source, carry to the destination.
		State.MOVING_TO_PLANKS:
			if _move_to_target(delta):
				state = State.PICKING_UP_PLANKS
				timer = PICKUP_TIME
				play("idle")
		State.PICKING_UP_PLANKS:
			timer -= delta * worker_rest.efficiency()
			if timer <= 0.0:
				if plank_source == Place.PILE and is_instance_valid(plank_source_node):
					plank_source_node.take_reserved()
				carrying_planks = claimed_planks
				claimed_planks = 0
				target_position = _place_stop(plank_dest)
				state = State.MOVING_WITH_PLANKS
				play("carry_plank")
		State.MOVING_WITH_PLANKS:
			if _plank_target_full():
				_reroute_planks()
			elif _move_to_target(delta):
				state = State.DROPPING_OFF_PLANKS
				timer = DROPOFF_TIME
				# Still holding the planks: frame 1 of the carrying sheet.
				play("carry_plank_idle")
		State.DROPPING_OFF_PLANKS:
			timer -= delta * worker_rest.efficiency()
			if timer <= 0.0:
				_drop_planks()

		# Log trips: walk to the log (at a tree or the Storage door), drag it to its destination.
		State.MOVING_TO_LOG:
			if _move_to_target(delta):
				state = State.PICKING_UP_LOG
				timer = PICKUP_TIME
				play("idle")
		State.PICKING_UP_LOG:
			timer -= delta * worker_rest.efficiency()
			if timer <= 0.0:
				dragger.attach(current_log)
				_head_to_log_dest(log_dest)
		State.MOVING_WITH_LOG:
			if _move_to_target(delta):
				state = State.DROPPING_OFF_LOG
				timer = DROPOFF_TIME
				play("idle")
		State.DROPPING_OFF_LOG:
			timer -= delta * worker_rest.efficiency()
			if timer <= 0.0:
				_try_drop_log()

	dragger.update()

# One plank put down at the destination (re-checked on arrival: a blueprint that filled up
# meanwhile sends it to Storage or the yard instead).
func _drop_planks() -> void:
	if _plank_target_full():
		_reroute_planks()
		return
	match plank_dest:
		Place.BUILDING:
			plank_building.planks_ready += 1
			_release_plank_reservation()
		Place.STORAGE:
			storage.add_planks(1)
		Place.YARD:
			PlankPiles.put_plank(get_tree(), get_parent(), plank_yard.global_position, pile_merge_radius, map_rect, plank_yard.global_position)
	carrying_planks = 0
	state = State.IDLE
	play("idle")

func _head_to_log_dest(dest: Place) -> void:
	log_dest = dest
	target_position = _place_stop(dest)
	# Turn to face the way he will haul, so the log is already behind him.
	flip_h = target_position.x < position.x
	state = State.MOVING_WITH_LOG
	play("walk")

# Only the Hauler fills the Sawmill and Storage, so a destination chosen with room still has
# it on arrival. If it is refused anyway he reroutes to the other one, or holds the log and
# looks again shortly (no walking back and forth).
func _try_drop_log() -> void:
	var accepted: bool = sawmill.accept_log() if log_dest == Place.SAWMILL else storage.add_log()
	if accepted:
		dragger.release()
		if current_log_tree != null:
			current_log_tree.finish_log()
		current_log = null
		current_log_tree = null
		state = State.IDLE
		return
	if log_dest == Place.SAWMILL and storage != null and storage.has_log_room():
		_head_to_log_dest(Place.STORAGE)
	elif log_dest == Place.STORAGE and sawmill != null and sawmill.has_room():
		_head_to_log_dest(Place.SAWMILL)
	else:
		timer = DROPOFF_TIME

func _move_to_target(delta: float) -> bool:
	if target_position.x < position.x:
		flip_h = true
	elif target_position.x > position.x:
		flip_h = false
	var current_speed: float = speed * worker_rest.efficiency()
	if dragger.is_dragging():
		current_speed *= carry_speed_multiplier
	elif carrying_planks > 0:
		current_speed *= plank_carry_speed_multiplier
	current_speed *= WaterMap.speed_factor(position)
	var before: Vector2 = position
	position = position.move_toward(_walker.next(position, target_position), current_speed * delta)
	WaterMap.walked(self, position.distance_to(before))
	return position.distance_to(target_position) < 0.01

# A log leaving Storage is made here: lying along x just in front of the door, so he picks
# it up and drags it like any tree log.
func _spawn_storage_log() -> Sprite2D:
	var stored_log := Sprite2D.new()
	stored_log.texture = TRUNK_TEXTURE
	stored_log.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	stored_log.offset = Vector2(0, -14)
	stored_log.rotation_degrees = -90.0
	stored_log.position = (storage.position + STORAGE_STOP_OFFSET + Vector2(LogDragger.LOG_LENGTH * 0.5, LogDragger.LOG_Y)).round()
	get_parent().add_child(stored_log)
	return stored_log

# Where he stops to pick up a lying log (the shared drag code works it out).
func _log_pickup_point(trunk: Sprite2D) -> Vector2:
	if trunk == null:
		dragger.pickup_tied_top = false
		return current_log_tree.position + Vector2(0, TILE_SIZE + 8.0)
	return dragger.pickup_point(trunk, log_pickup_offset)
