extends Node

# One hungry trip to food, shared by the Colonists and the three workers (the Lumberjack, the Hauler and the
# Builder, through WorkerRest). The owner (`who`, an AnimatedSprite2D with a `speed`) creates one, calls setup(),
# start()s it when he is hungry, tick()s it every frame while active(), and reacts to `ended`.
#
#  - start(): the nearest crate that holds berries (by the length of the walk to its building's door, any
#    building's interior, skipping crates somebody else is taking from); with none, the nearest ripe berry bush
#    nobody has reserved. False when there is nothing edible.
#  - Crate: he walks to the building's door, goes in (gone from the world; if the player is in that room he is seen
#    coming in at the door and standing at the crate), eats berry after berry until his hunger reaches
#    colonist_eat_until or the crate is empty, then the next crate with berries (in the same building or another),
#    and finally comes out of the door. A crate is claimed only while he is actually taking from it.
#  - Bush: he reserves it, walks there and picks and eats its berries on the spot, the next ripe bush if it runs
#    out before he has had enough.
#  - `ended` is emitted when he has had enough or has nothing left to go to (he stands free outside again);
#    abort() stops the trip silently (a bedtime, a job, a death): claims are released and he is put outside the
#    door if he was inside.
# Everything the owner reads about it: phase, crate, crate_building, in_room.

const WorkFx = preload("res://scripts/work_fx.gd")
const FoodConfig = preload("res://scripts/food_config.gd")
const WaterMap = preload("res://scripts/water_map.gd")

signal phase_changed(phase: int)
signal ended

enum Phase { NONE, TO_CRATE, IN_CRATE, TO_BUSH, AT_BUSH }

var phase: Phase = Phase.NONE
var who: AnimatedSprite2D
var rest: Node
var hunger: Node
# Seconds one berry takes at full efficiency (picking and eating).
var eat_seconds: float = 1.4
# Overrides of the GameClock's numbers (-1 = use the clock's): the hunger he stops eating at.
var eat_until_override: float = -1.0
var path_margin: float = 5.0
var walk_timeout: float = 25.0

var crate = null
var crate_building = null
var bush = null
var in_room: bool = false
# Walking from the door to the crate inside the room (only while the player is in that room).
var _walking_in_room: bool = false
# The outside door of the building he went to (where he comes out).
var _trip_door: Vector2 = Vector2.ZERO
var waypoints: Array[Vector2] = []
var _crate_avoid: Array = []
var _bush_avoid: Array = []
var _eat_timer: float = 0.0
var _walk_time: float = 0.0
var _stuck_time: float = 0.0
var _best_distance: float = INF
var _clock: Node

func setup(owner_sprite: AnimatedSprite2D, rest_meter: Node, hunger_meter: Node, seconds_per_berry: float = 1.4) -> void:
	who = owner_sprite
	rest = rest_meter
	hunger = hunger_meter
	eat_seconds = seconds_per_berry
	who.add_to_group("eaters")
	who.set_meta(&"eat_trip", self)

func _game_clock() -> Node:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	return _clock

func active() -> bool:
	return phase != Phase.NONE

func crate_active() -> bool:
	return phase == Phase.TO_CRATE or phase == Phase.IN_CRATE

# Inside a building, at a crate (not in the world).
func inside() -> bool:
	return phase == Phase.IN_CRATE

func _set_phase(value: Phase) -> void:
	phase = value
	phase_changed.emit(int(value))

# --- Starting ------------------------------------------------------------------------------------------------

func start() -> bool:
	var found_crate = _find_crate()
	if found_crate != null:
		_go_to_crate(found_crate)
		return true
	var found_bush = _find_ripe_bush()
	if found_bush != null and found_bush.try_claim(who):
		_go_to_bush(found_bush)
		return true
	return false

# Is there anything to eat at all (without setting out)?
func food_exists() -> bool:
	return _find_crate() != null or _find_ripe_bush() != null

# Stops the trip (no `ended`): claims go, and if he was inside he is out at the door.
func abort() -> void:
	if phase == Phase.NONE:
		return
	_release_crate()
	_release_bush()
	if phase == Phase.IN_CRATE:
		_leave_building()
	waypoints.clear()
	_crate_avoid.clear()
	_bush_avoid.clear()
	in_room = false
	_walking_in_room = false
	crate = null
	crate_building = null
	phase = Phase.NONE

func _finish() -> void:
	_crate_avoid.clear()
	_bush_avoid.clear()
	if phase == Phase.IN_CRATE:
		_leave_building()
	_release_crate()
	_release_bush()
	crate = null
	crate_building = null
	in_room = false
	_walking_in_room = false
	phase = Phase.NONE
	ended.emit()

# --- Walking helpers -----------------------------------------------------------------------------------------

func _path_to(point: Vector2) -> Array[Vector2]:
	return Footprints.path_around(Footprints.base_rects(get_tree()), who.position, point, path_margin)

func _path_length(to: Vector2) -> float:
	var length: float = 0.0
	var prev: Vector2 = who.position
	for p in _path_to(to):
		length += prev.distance_to(p)
		prev = p
	return length

func _reset_stuck() -> void:
	_stuck_time = 0.0
	_best_distance = INF

func _is_stuck(delta: float) -> bool:
	if waypoints.is_empty():
		return false
	var d: float = who.position.distance_to(waypoints[0])
	if d < _best_distance - 0.5:
		_best_distance = d
		_stuck_time = 0.0
		return false
	_stuck_time += delta
	return _stuck_time >= 2.0

# Walks the waypoints; true once the last one is reached.
func _follow(delta: float) -> bool:
	if waypoints.is_empty():
		return true
	var target: Vector2 = waypoints[0]
	if target.x < who.position.x:
		who.flip_h = true
	elif target.x > who.position.x:
		who.flip_h = false
	var before: Vector2 = who.position
	who.position = who.position.move_toward(target, who.speed * rest.speed_factor() * WaterMap.speed_factor(who.position) * delta)
	WaterMap.walked(who, who.position.distance_to(before))
	if who.position.distance_to(target) < 0.01:
		waypoints.remove_at(0)
		# (The next waypoint is a new goal: a detour round something is no "no progress".)
		_reset_stuck()
	return waypoints.is_empty()

func _walk_to(point: Vector2) -> void:
	waypoints = _path_to(point)
	_walk_time = 0.0
	_reset_stuck()
	who.play("walk")

func _target_hunger() -> float:
	if eat_until_override >= 0.0:
		return eat_until_override
	var clock: Node = _game_clock()
	return clock.colonist_eat_until if clock != null else 75.0

func _berry_value() -> float:
	var clock: Node = _game_clock()
	return clock.berry_hunger_value if clock != null else 12.0

# The kinds he eats from a crate, best first: flatbread first when he is very hungry (bread_preferred_below), else
# berries first and flatbread after them.
func _preferred_kinds() -> Array[StringName]:
	if hunger.value <= FoodConfig.cfg().bread_preferred_below:
		return [&"flatbread", &"berry"]
	return [&"berry", &"flatbread"]

func _food_value(kind: StringName) -> float:
	return FoodConfig.cfg().flatbread_hunger_value if kind == &"flatbread" else _berry_value()

func _full_enough(value: float) -> bool:
	return hunger.value >= _target_hunger() or hunger.value > 100.0 - value

# --- Every frame ---------------------------------------------------------------------------------------------

func tick(delta: float) -> void:
	match phase:
		Phase.TO_CRATE:
			_walk_time += delta
			if not _crate_ok():
				abort()
				ended.emit()
			elif _follow(delta):
				_enter_building()
			elif _is_stuck(delta) or _walk_time > walk_timeout / maxf(0.1, rest.efficiency()):
				# Cannot get there: give up on this crate for now.
				_crate_avoid.append(crate)
				abort()
				ended.emit()
		Phase.IN_CRATE:
			_tick_inside(delta)
		Phase.TO_BUSH:
			_walk_time += delta
			if not _bush_mine():
				abort()
				ended.emit()
			elif _follow(delta):
				_set_phase(Phase.AT_BUSH)
				who.play("idle")
				_eat_timer = eat_seconds
			elif _is_stuck(delta) or _walk_time > walk_timeout / maxf(0.1, rest.efficiency()):
				_bush_avoid.append(bush)
				abort()
				ended.emit()
		Phase.AT_BUSH:
			if not _bush_mine():
				abort()
				ended.emit()
			else:
				# Picking and eating one berry takes as long as his efficiency makes it.
				_eat_timer -= delta * rest.efficiency()
				if _eat_timer <= 0.0:
					_eat_bush_berry()

# --- Crates --------------------------------------------------------------------------------------------------

func _host_ok(host) -> bool:
	if host == null or not is_instance_valid(host) or host.is_queued_for_deletion():
		return false
	return host.is_in_group("storages") or (host.is_in_group("buildings") and host.state == host.State.BUILT)

func _taken_by_other(candidate) -> bool:
	return candidate.claimed_by != null and candidate.claimed_by != who and is_instance_valid(candidate.claimed_by)

# The crate with berries nearest to him by the walk to its building's door (a crate in the building he is inside
# counts as 0), skipping the ones another is taking from, and null if there is none.
func _find_crate():
	for kind in _preferred_kinds():
		var found = _find_crate_with(kind)
		if found != null:
			return found
	return null

func _find_crate_with(kind: StringName):
	var best = null
	var best_key: float = INF
	for candidate in get_tree().get_nodes_in_group("crates"):
		if candidate.count_of(kind) <= 0 or _crate_avoid.has(candidate) or candidate.is_queued_for_deletion() or _taken_by_other(candidate):
			continue
		var host = candidate.host_building()
		if not _host_ok(host):
			continue
		var key: float = 0.0
		if not (phase == Phase.IN_CRATE and crate_building == host):
			key = _path_length(host.door_position())
		# (Inside a room, the nearer crate wins.)
		key += candidate.global_position.distance_to(host.get_interior().door_world()) * 0.01
		if key < best_key:
			best_key = key
			best = candidate
	return best

func _go_to_crate(target) -> void:
	crate = target
	crate_building = target.host_building()
	_trip_door = crate_building.door_position()
	_walk_to(_trip_door)
	_set_phase(Phase.TO_CRATE)

func _crate_ok() -> bool:
	return crate != null and is_instance_valid(crate) and not crate.is_queued_for_deletion() and _host_ok(crate_building)

func _release_crate() -> void:
	if crate != null and is_instance_valid(crate):
		crate.release_claim(who)

# He has reached the door: in he goes (to the nearest crate there with berries that nobody is taking from).
func _enter_building() -> void:
	var host = crate_building
	var pick = null
	var best: float = INF
	var room: Node2D = host.get_interior()
	for kind in _preferred_kinds():
		for candidate in get_tree().get_nodes_in_group("crates"):
			if candidate.host_building() != host or candidate.count_of(kind) <= 0 or _crate_avoid.has(candidate) or _taken_by_other(candidate):
				continue
			var d: float = candidate.global_position.distance_to(room.door_world())
			if d < best:
				best = d
				pick = candidate
		if pick != null:
			break
	if pick == null:
		# The berries here are gone: elsewhere, or he gives up for now.
		_crate_avoid.append(crate)
		crate = null
		crate_building = null
		phase = Phase.NONE
		if not start():
			_crate_avoid.clear()
			ended.emit()
		return
	crate = pick
	AudioManager.play("door", host.door_position(), 1.0, -4.0)
	waypoints.clear()
	_set_phase(Phase.IN_CRATE)
	if room.player_inside:
		# Seen coming in at the door and walking to the crate.
		who.set_body_visible(&"*", true)
		in_room = true
		who.position = room.door_world()
		room.shown.append(who)
		_walk_to(crate.use_spot())
		_walking_in_room = true
	else:
		who.set_body_visible(&"crate", false)
		in_room = false
		_walking_in_room = false
		who.position = _trip_door
		who.stop()
		_begin_taking()

# At the crate: it is his now (claimed only from here on), and he starts eating.
func _begin_taking() -> void:
	_walking_in_room = false
	if crate == null or not is_instance_valid(crate) or not crate.try_claim(who) or not crate.has_food():
		_next_crate()
		return
	who.play("idle")
	_eat_timer = eat_seconds

func _tick_inside(delta: float) -> void:
	if not _crate_ok():
		abort()
		ended.emit()
		return
	if _walking_in_room:
		if _follow(delta):
			_begin_taking()
		elif _is_stuck(delta):
			who.position = crate.use_spot()
			waypoints.clear()
			_begin_taking()
		return
	_eat_timer -= delta * rest.efficiency()
	if _eat_timer <= 0.0:
		_eat_from_crate()

func _eat_from_crate() -> void:
	var value: float = _berry_value()
	# One bite of the best food this crate has for him now (flatbread when he is very hungry, else berries first).
	for kind in _preferred_kinds():
		if crate.count_of(kind) > 0 and crate.take_item(kind, 1) > 0:
			value = _food_value(kind)
			hunger.eat(value)
			crate.open_lid()
			AudioManager.play("eat_bread" if kind == &"flatbread" else "eat", crate.global_position, 1.0, -4.0)
			if who.visible:
				WorkFx.crumbs(get_tree(), crate.global_position + Vector2(0, -14))
			break
	if _full_enough(value):
		_finish()
	elif not crate.has_food():
		_next_crate()
	else:
		_eat_timer = eat_seconds

# This crate is done with: the next crate with berries (in this building he stays inside; in another he goes out
# and over), else out and finished.
func _next_crate() -> void:
	_release_crate()
	var found = _find_crate()
	if found == null:
		_finish()
	elif found.host_building() == crate_building:
		crate = found
		if in_room:
			_walk_to(found.use_spot())
			_walking_in_room = true
		else:
			_begin_taking()
	else:
		_leave_building()
		_go_to_crate(found)

# Out of the door: visible at it again (the claim is let go, and the room forgets him).
func _leave_building() -> void:
	_release_crate()
	var host = crate_building
	if host != null and is_instance_valid(host) and host.get("interior") != null and is_instance_valid(host.interior):
		host.interior.shown.erase(who)
	who.position = _trip_door + Vector2(0, 3)
	who.set_body_visible(&"*", true)
	who.play("idle")
	AudioManager.play("door", _trip_door, 1.0, -4.0)
	in_room = false
	_walking_in_room = false
	waypoints.clear()
	crate = null
	crate_building = null

# Where he stands to take from his crate.
func crate_spot() -> Vector2:
	if crate != null and is_instance_valid(crate):
		return crate.use_spot()
	return who.position

# The player walked into the room he is eating in: he shows, standing at the crate.
func show_in_room(spot: Vector2) -> void:
	in_room = true
	who.set_body_visible(&"*", true)
	_walking_in_room = false
	waypoints.clear()
	who.position = spot
	who.play("idle")

# The player left: he goes on eating at the crate, out of sight.
func hide_from_room() -> void:
	in_room = false
	who.set_body_visible(&"crate", false)
	_walking_in_room = false
	waypoints.clear()
	who.position = _trip_door

# --- Bushes --------------------------------------------------------------------------------------------------

# The nearest ripe bush nobody has reserved (and that he has not given up on), or null.
func _find_ripe_bush():
	var best = null
	var best_distance: float = INF
	for candidate in get_tree().get_nodes_in_group("berry_bushes"):
		if not candidate.is_ripe() or candidate.claimed_by != null or _bush_avoid.has(candidate):
			continue
		var spot: Vector2 = candidate.pick_spot()
		if Footprints.rect_blocked(get_tree(), Rect2(spot - Vector2(4, 2), Vector2(8, 4))):
			continue
		var d: float = who.position.distance_to(candidate.global_position)
		if d < best_distance:
			best_distance = d
			best = candidate
	return best

func _bush_mine() -> bool:
	return bush != null and is_instance_valid(bush) and bush.claimed_by == who

func _release_bush() -> void:
	if bush != null and is_instance_valid(bush):
		bush.release_claim(who)
	bush = null

func _go_to_bush(target_bush) -> void:
	bush = target_bush
	_walk_to(bush.pick_spot())
	_set_phase(Phase.TO_BUSH)

# One berry: picked and eaten on the spot. He goes on while he is hungry and the bush has berries left.
func _eat_bush_berry() -> void:
	var value: float = _berry_value()
	var at: Vector2 = bush.global_position + Vector2(0, -6)
	if bush.pick_one():
		hunger.eat(value)
		AudioManager.play("berry_pick", at, 1.0, -4.0)
		AudioManager.play("eat", who.position, 1.0, -4.0)
		WorkFx.berries(get_tree(), at)
		WorkFx.shake(bush, 1.2)
		if bush.berries <= 0:
			WorkFx.dust(get_tree(), at, 4)
	if _full_enough(value):
		_finish()
	elif bush.berries <= 0:
		# This bush is bare and he is still below the target: the next ripe bush, else he is done for now.
		_release_bush()
		var next = _find_ripe_bush()
		if next != null and next.try_claim(who):
			_go_to_bush(next)
		else:
			_finish()
	else:
		_eat_timer = eat_seconds
