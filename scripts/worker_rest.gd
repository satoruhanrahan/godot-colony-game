extends Node

# The Rest need and the daily routine of an automated worker (Lumberjack, Hauler, Builder, ...): one
# shared component, so every worker follows exactly the same rules as the colonists and the player.
#
#  - A RestMeter: starts at 100, drains at the clock's awake rate times `activity` (the worker says
#    whether he is working, hauling or just walking), recovers nothing outdoors.
#  - Efficiency (the same GameClock curve): the worker moves slower, his walk / carry / work animations
#    play slower (speed_scale), and the time his work actions take is divided by it. The number of
#    hits a job needs never changes. (The worker script uses efficiency() for these.)
#  - Schedule: at dusk he stops. If he is between jobs he goes to sleep at once; if he is in the middle of
#    one he may finish it, but after the GameClock's worker_finish_grace clock-seconds he abandons it safely
#    (the worker releases his claims and drops what he carries). He also goes to sleep, by day, when he is
#    between jobs and exhausted (energy below exhausted_threshold). He wakes at dawn (a night's sleep), or
#    at nap_wake_energy (a daytime nap), and works again.
#  - Where he sleeps (BedFinder, the same rules as a colonist without a house): the nearest free bed, which
#    he reserves while he walks to it (at his own energy-slowed speed) and lies on, drawn on top of the bed
#    and sleeping at that bed's recovery rate; with no free bed, outdoors where he stands (idle frame, energy
#    only drains, slowly; an outdoor daytime nap is cut off after nap_outdoor_max_seconds).
#  - While he walks to a bed or sleeps, takes_over() is true: the worker's own script must do nothing (it
#    returns at the top of its _process) and start no job (may_start_job()).
#  - A "z" while asleep, a "!" when awake and below 25 energy, and his bar only while the mouse is over him
#    (RestIndicator), like the colonists.
#
# Hunger (the same HungerMeter and numbers as the colonists, one shared EatTrip to food):
#  - His hunger drains like a colonists (x hunger_work_multiplier while he works or carries, x hunger_sleep_multiplier
#    asleep) and is multiplied into the ONE efficiency with min() (only the worse of energy and hunger counts), so
#    his speed, walk animation and action times all follow it.
#  - Below hungry_below (GameClock.hungry_threshold, 40) he eats: between jobs at once; in the middle of one he may
#    finish it, but after worker_finish_grace clock-seconds he abandons it safely (his _abandon_task releases every
#    claim and puts what he carries down where he stands as a normal item: a plank into a pile, a log left lying),
#    walks to the nearest crate with berries (else the nearest ripe bush), goes in, eats until colonist_eat_until,
#    comes out and works again. With nothing edible anywhere he carries on working, slowly, and looks again.
#  - Below very_hungry_below (15) food beats everything: it interrupts work at once and wakes a sleeper. The sleep
#    rules are otherwise unchanged: hungry (but not that hungry) and exhausted or at bedtime, he sleeps first.
#  - At hunger 0 he dies (see _die): everything he held is released, a body lies where he fell and fades after a
#    clock day, and the Hud says "The Lumberjack starved.".
#  - The values can be overridden with the exports below (-1 = the GameClock number).
#
# The worker calls setup() from its _ready(), asks may_start_job() whenever it picks a job, multiplies its
# speeds and durations by efficiency(), and returns from _process while takes_over().

const RestMeter = preload("res://scripts/rest_meter.gd")
const RestIndicator = preload("res://scripts/rest_indicator.gd")
const BedFinder = preload("res://scripts/bed_finder.gd")
const SleepVisual = preload("res://scripts/asleep_frames.gd")
const HungerMeter = preload("res://scripts/hunger_meter.gd")
const WaterMap = preload("res://scripts/water_map.gd")
const EatTrip = preload("res://scripts/eat_trip.gd")

# Clearance kept from solid things when walking to a bed (as the colonists do).
const PATH_MARGIN: float = 5.0
# Walking to a bed: give up on it after this many seconds (stuck for good).
const WALK_TIMEOUT: float = 25.0

signal fell_asleep
signal woke_up
signal died

@export_group("Hunger")
# Below this he goes to eat (-1 = GameClock.hungry_threshold) and he eats until this (-1 = colonist_eat_until).
@export var hungry_below: float = -1.0
@export var eat_until: float = -1.0
# Below this food comes before everything (work is dropped at once, sleep is broken off).
@export var very_hungry_below: float = 15.0
# Seconds one berry takes at full efficiency.
@export var eat_seconds: float = 1.4
# When nothing edible was found he looks again after this many clock-seconds.
@export var food_retry_clock_seconds: float = 4.0
# The body lies for a clock day (GameClock.day_length), then fades out over this many clock-seconds.
@export var body_fade_clock_seconds: float = 10.0

var rest: Node
var asleep: bool = false
# The bed he has reserved (walking to it) or is lying on; null otherwise.
var bed = null

var _worker: AnimatedSprite2D
var _at_safe_point: Callable
var _abandon_task: Callable
var _clock: Node
# Clock-seconds he has been past his bedtime and still working.
var _overtime: float = 0.0
var _reason: int = BedFinder.Reason.NONE
var _walking_to_bed: bool = false
var _path: Array[Vector2] = []
var _walk_time: float = 0.0
var _bed_avoid: Array = []
var _nap_seconds: float = 0.0
var _time: float = 0.0
var _nap_block_until: float = 0.0
var _night_rested: bool = false

var hunger: Node
var eat: Node
var dead: bool = false
var _dead_time: float = 0.0
var _indicator: Node2D
var _hunger_overtime: float = 0.0
var _food_retry_at: float = 0.0

# `activity`: returns the awake drain multiplier now. `at_safe_point`: true when he holds no claim and
# carries nothing (between jobs). `abandon_task`: releases every claim, drops what he carries and
# leaves him idle.
func setup(worker: AnimatedSprite2D, activity: Callable, at_safe_point: Callable, abandon_task: Callable) -> void:
	_worker = worker
	_at_safe_point = at_safe_point
	_abandon_task = abandon_task
	rest = RestMeter.new()
	rest.activity = activity
	add_child(rest)
	hunger = HungerMeter.new()
	hunger.who_name = "The %s" % worker.name
	hunger.starved.connect(_die)
	hunger.rest = rest
	# (Working or carrying costs hunger more, as it costs energy more.)
	hunger.activity = func() -> float:
		var clock: Node = _game_clock()
		return clock.hunger_work_multiplier if clock != null and float(activity.call()) > 1.0 else 1.0
	add_child(hunger)
	rest.hunger = hunger
	eat = EatTrip.new()
	add_child(eat)
	eat.setup(worker, rest, hunger, eat_seconds)
	worker.set_meta(&"worker_rest", self)
	var indicator: Node2D = RestIndicator.new()
	indicator.rest = rest
	indicator.hunger = hunger
	indicator.hunger_bar = true
	indicator.display_name = String(worker.name)
	indicator.asleep_outdoors = func() -> bool: return asleep
	indicator.awake = func() -> bool: return not asleep
	worker.add_child(indicator)
	_indicator = indicator

func _game_clock() -> Node:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	return _clock

# The one efficiency (1 at full strength; 0.2 at rest 0).
func efficiency() -> float:
	return rest.efficiency()

# On his way to a bed, or asleep: the worker's own script does nothing meanwhile.
func takes_over() -> bool:
	return asleep or _walking_to_bed or dead or eat.active()

# May he pick a new job now: awake, not bedtime, and rested enough.
func may_start_job() -> bool:
	var clock: Node = _game_clock()
	if clock == null:
		return true
	# (Hungry with food to be had: he goes to eat before starting anything.)
	return not takes_over() and not clock.is_bedtime() and rest.value >= clock.worker_min_rest_to_start and not _wants_to_eat(clock)

func _process(delta: float) -> void:
	# Walking, carrying and work animations play at his efficiency (1 while asleep).
	rest.sync_animation(_worker)
	var clock: Node = _game_clock()
	if clock == null:
		return
	if dead:
		_process_body(clock)
		return
	eat.eat_until_override = eat_until
	_time += clock.clock_delta
	if clock.is_daytime():
		_night_rested = false
	if eat.active():
		eat.tick(delta)
		return
	if _walking_to_bed:
		if _food_first(clock):
			return
		_walk_to_bed(delta)
		return
	if asleep:
		_nap_seconds += clock.clock_delta
		if bed != null and not _bed_still_mine():
			# The bed has gone from under him: the next choice.
			_forget_bed()
			_begin_sleep(_reason)
			return
		if _food_first(clock):
			return
		_check_wake(clock)
		return
	# Very hungry: food beats work and the sleep that was about to start.
	if _food_first(clock):
		return
	# Exhausted in the daytime: between jobs he lies down at once; mid-job he finishes it, or after the grace
	# period leaves it safely (as at bedtime).
	if not clock.is_bedtime() and rest.value < clock.exhausted_threshold and _time >= _nap_block_until:
		if not _at_safe_point.call():
			_overtime += clock.clock_delta
			if _overtime < clock.worker_finish_grace:
				return
			_abandon_task.call()
		_bed_avoid.clear()
		_begin_sleep(BedFinder.Reason.EXHAUSTED)
		return
	if not clock.is_bedtime():
		_overtime = 0.0
		_hungry_check(clock)
		return
	if _night_rested:
		_hungry_check(clock)
		return
	# Bedtime: between jobs he goes to sleep at once; mid-job he finishes it, or after the grace
	# period leaves it safely.
	if _at_safe_point.call():
		_bed_avoid.clear()
		_begin_sleep(BedFinder.Reason.NIGHT)
		return
	_overtime += clock.clock_delta
	if _overtime >= clock.worker_finish_grace:
		_abandon_task.call()
		_bed_avoid.clear()
		_begin_sleep(BedFinder.Reason.NIGHT)

# --- Hunger -----------------------------------------------------------------------------------------------

func _hungry_threshold(clock: Node) -> float:
	return hungry_below if hungry_below >= 0.0 else clock.hungry_threshold

# Hungry, and food was (last time he looked) to be had.
func _wants_to_eat(clock: Node) -> bool:
	return hunger.value < _hungry_threshold(clock) and _time >= _food_retry_at and not dead

# Hungry (not very): between jobs he sets out at once, mid-job after the grace period. Sleep came first.
func _hungry_check(clock: Node) -> void:
	if hunger.value >= _hungry_threshold(clock):
		_hunger_overtime = 0.0
		return
	if _time < _food_retry_at:
		return
	if not _at_safe_point.call():
		_hunger_overtime += clock.clock_delta
		if _hunger_overtime < clock.worker_finish_grace:
			return
	if not eat.food_exists():
		_food_retry_at = _time + food_retry_clock_seconds
		return
	if not _at_safe_point.call():
		_abandon_task.call()
	_hunger_overtime = 0.0
	_bed_avoid.clear()
	eat.start()

# Very hungry: drops whatever he is doing (safely), wakes if asleep, and goes to eat. True if he set out.
func _food_first(_clock_now: Node) -> bool:
	if hunger.value >= very_hungry_below or _time < _food_retry_at:
		return false
	if not eat.food_exists():
		_food_retry_at = _time + food_retry_clock_seconds
		return false
	if asleep or _walking_to_bed:
		SleepVisual.set_asleep(_worker, false)
		_forget_bed()
		_bed_avoid.clear()
		_reason = BedFinder.Reason.NONE
		woke_up.emit()
	elif not _at_safe_point.call():
		_abandon_task.call()
	_hunger_overtime = 0.0
	return eat.start()

# --- Death ------------------------------------------------------------------------------------------------

# Hunger 0: he stops. Whatever he held is released exactly as when he abandons a job (tree, log, plank, blueprint,
# the planks he carried are put down as a normal pile), and any crate, bush or bed claim goes. A body lies where
# he fell and fades after a clock day; the slot is simply empty afterwards.
func _die() -> void:
	if dead:
		return
	dead = true
	# (Died inside a building, eating at its crate: the body lies in the room and goes with it.)
	var room: Node2D = null
	var spot: Vector2 = _worker.position
	if eat.inside() and eat.crate_building != null and is_instance_valid(eat.crate_building):
		room = eat.crate_building.get_interior()
		spot = eat.crate_spot()
		room.shown.erase(_worker)
	eat.abort()
	if room != null:
		_worker.position = spot
	_worker.add_to_group("bodies")
	_forget_bed()
	SleepVisual.set_asleep(_worker, false)
	_abandon_task.call()
	rest.stop_sleep()
	_walking_to_bed = false
	asleep = false
	_worker.pause()
	_worker.speed_scale = 1.0
	_worker.rotation_degrees = 90.0
	if _indicator != null and is_instance_valid(_indicator):
		_indicator.queue_free()
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say("The %s starved." % _worker.name)
	var fast: Node = get_node_or_null("/root/FastForward")
	if fast != null:
		fast.warning("death")
	print("%s starved at %s" % [_worker.name, _worker.position])
	died.emit()

func is_dead() -> bool:
	return dead

# The body: it lies for a clock day, then fades and goes.
func _process_body(clock: Node) -> void:
	_dead_time += clock.clock_delta
	if _dead_time <= clock.day_length:
		return
	var fade: float = clampf((_dead_time - clock.day_length) / maxf(0.1, body_fade_clock_seconds), 0.0, 1.0)
	_worker.modulate.a = 1.0 - fade
	if fade >= 1.0:
		_worker.queue_free()

# --- Sleeping ---------------------------------------------------------------------------------------------

# The free bed he picks (reserved at once, so nobody else takes it), else outdoors where he stands.
func _begin_sleep(reason: int) -> void:
	_reason = reason
	_overtime = 0.0
	var found = BedFinder.choose(get_tree(), _worker, _worker.position, null, _bed_avoid, false)
	if found != null and found.reserve(_worker):
		bed = found
		_path = Footprints.path_around(Footprints.base_rects(get_tree()), _worker.position, bed.sleep_spot_world(), PATH_MARGIN)
		_walk_time = 0.0
		_walking_to_bed = true
		_worker.play("walk")
		return
	_lie_down(null)

func _walk_to_bed(delta: float) -> void:
	_walk_time += delta
	if not _bed_still_mine():
		# The bed was broken or taken: the next choice.
		_forget_bed()
		_begin_sleep(_reason)
		return
	if _walk_time > WALK_TIMEOUT:
		_bed_avoid.append(bed)
		_forget_bed()
		_begin_sleep(_reason)
		return
	if not _path.is_empty():
		var target: Vector2 = _path[0]
		if target.x < _worker.position.x:
			_worker.flip_h = true
		elif target.x > _worker.position.x:
			_worker.flip_h = false
		var speed: float = float(_worker.get("speed")) if _worker.get("speed") != null else 50.0
		var before: Vector2 = _worker.position
		_worker.position = _worker.position.move_toward(target, speed * efficiency() * WaterMap.speed_factor(_worker.position) * delta)
		WaterMap.walked(_worker, _worker.position.distance_to(before))
		if _worker.position.distance_to(target) < 0.01:
			_path.remove_at(0)
	if _path.is_empty():
		_walking_to_bed = false
		_lie_down(bed)

# Starts the sleep: on `on_bed` (his reserved bed) or, with none, on the bare ground where he stands.
func _lie_down(on_bed) -> void:
	asleep = true
	_nap_seconds = 0.0
	var clock: Node = _game_clock()
	if on_bed != null:
		on_bed.lie_down(_worker)
		_worker.position = on_bed.sleep_spot_world()
		rest.start_sleep(on_bed.sleep_rate_now())
	else:
		rest.start_sleep(clock.sleep_rate_outdoors())
	_worker.play("idle")
	# (The same function as the player and the colonists; a worker with no asleep picture stays standing.)
	SleepVisual.set_asleep(_worker, true)
	fell_asleep.emit()

func _check_wake(clock: Node) -> void:
	match BedFinder.step(clock, rest, _reason, bed == null, _nap_seconds):
		BedFinder.Wake.WAKE:
			_wake()
		BedFinder.Wake.WAKE_FULL:
			_night_rested = true
			_wake()
		BedFinder.Wake.WAKE_CAPPED:
			_nap_block_until = _time + clock.nap_retry_seconds
			_wake()
		BedFinder.Wake.TO_NIGHT:
			_reason = BedFinder.Reason.NIGHT

func _bed_still_mine() -> bool:
	return bed != null and is_instance_valid(bed) and bed.is_in_group("beds") and not bed.is_queued_for_deletion() and (bed.reserved_by == _worker or bed.sleeper == _worker)

func _forget_bed() -> void:
	if bed != null and is_instance_valid(bed):
		bed.release_sleeper(_worker)
	bed = null
	_walking_to_bed = false
	asleep = false
	rest.stop_sleep()

func _wake() -> void:
	SleepVisual.set_asleep(_worker, false)
	_forget_bed()
	_bed_avoid.clear()
	_reason = BedFinder.Reason.NONE
	woke_up.emit()
