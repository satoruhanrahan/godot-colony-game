class_name Colonist
extends AnimatedSprite2D

signal moved_in(colonist: Colonist)
# Emitted when he loses his house (the Colony then looks for another free bed).
signal became_unhoused(colonist: Colonist)
# Emitted when he is let go from a job (the Colony may now have a bed for him).
signal released(colonist: Colonist)

const RestMeter = preload("res://scripts/rest_meter.gd")
const RestIndicator = preload("res://scripts/rest_indicator.gd")
const BedFinder = preload("res://scripts/bed_finder.gd")
const SleepVisual = preload("res://scripts/asleep_frames.gd")
const HungerMeter = preload("res://scripts/hunger_meter.gd")
const WorkFx = preload("res://scripts/work_fx.gd")
const EatTrip = preload("res://scripts/eat_trip.gd")
const WaterMap = preload("res://scripts/water_map.gd")
const Orders = preload("res://scripts/colonist_orders.gd")
const OrderAI = preload("res://scripts/colonist_order_ai.gd")
const OrdersPanel = preload("res://scripts/orders_panel.gd")

# IDLE / WALKING: standing or wandering outside (a free colonist near the MainCharacter, or
#   round the landing point when following is switched off; with the daily schedule a housed
#   colonist is out like this by day).
# FOLLOWING: a free colonist walking after the MainCharacter, who got too far away.
# MOVING_IN: walking to his house's door.   ENTERING: the short pause at the door.
# INSIDE: in his house, hidden, asleep (at the house's sleep quality).
# RETURNING: walking back to the door (to sleep, or after a job without the schedule).
# TO_WORK: walking to a work spot (the pit saw); AT_WORK: there, waiting or working
#   (hidden while the saw runs). Claimed colonists are not available for anything else.
# SLEEPING_OUTSIDE: asleep on the bare ground where he stood (idle frame, a "z" above him).
# TO_BUSH: walking to a ripe berry bush he has reserved because he is hungry.   EATING: picking and eating
#   its berries there (no basket: a stand-in until there is a food store), then he follows the player again.
# TO_CRATE: walking to the door of a building with a crate that holds berries.   EATING_CRATE: inside it (gone from the
#   world, or seen in the room if the player is in it), eating from the crates there (see "Crates" below).
# ORDERED: he has a stance other than Free time (follow / assist / stay): ColonistOrderAI moves him (see colonist_orders.gd for the
#   precedence: carry, needs, tasks, stance). Needs and the carry interrupt it and he comes back to it through _stand_still().
# HELPING_CARRY: walking to the toolbox, then carrying it with the player (see carry_together.gd, which moves him).
# TO_BED: walking to a free bed he has reserved.   ON_BED: lying on it (idle frame, a "z"; drawn above the
#   bed, which is a flat decal on the ground).
enum State { IDLE, WALKING, MOVING_IN, ENTERING, INSIDE, RETURNING, TO_WORK, AT_WORK, FOLLOWING, SLEEPING_OUTSIDE, TO_BED, ON_BED, TO_BUSH, EATING, TO_CRATE, EATING_CRATE, HELPING_CARRY, ORDERED, TO_SLEEP_SPOT }
# Why he sleeps: it is bedtime (until dawn), or he was exhausted (a nap, until nap_wake_energy).
enum SleepReason { NONE, NIGHT, EXHAUSTED }

const CELL: int = 32

# Same unloaded walking speed as the Lumberjack, Hauler and Builder.
@export var speed: float = 50.0
# Seconds spent standing still between wanders (a random value in this range).
@export var idle_time_range: Vector2 = Vector2(2.0, 5.0)
# How far from his anchor (the landing point, or his own door) he wanders, in grid cells.
@export var wander_radius_cells: float = 3.0
# Wander targets stay inside the map.
@export var map_rect: Rect2 = Rect2(0, 0, 640, 640)
# Clearance kept from solid things when walking round them.
@export var path_margin: float = 5.0
# Pause at the door before he vanishes inside (0 = instantly).
@export var enter_delay: float = 0.3
# Walking home to bed: if he has not got in after this many seconds (stuck for good), he is put at
# the door.
@export var walk_home_timeout: float = 25.0

# Dead (starved): he lies where he fell, as a body that fades after a clock day (see die()).
var dead: bool = false
var _dead_time: float = 0.0

# Set by the Colony before he is added: where unhoused colonists hang about.
var landing_position: Vector2 = Vector2.ZERO
# His house, or null while he has none. Set when a bed is claimed, even if still walking.
var home = null
var state: State = State.IDLE
var timer: float = 0.0
var waypoints: Array[Vector2] = []
# The job (a PitSaw) that has claimed him, or null.
var work_claim = null
# The CarryTogether he is helping with (HELPING_CARRY), or null.
var carry_job = null
# His name (the Orders panel, the hover overlay, the acknowledgements) and his orders (colonist_orders.gd) with the AI that carries them out.
var display_name: String = "Friend"
var orders = Orders.new()
var order_ai: Node = null
var orders_panel: Node = null
var _carry_replan: float = 0.0
# Free-colonist behaviour: the Colony (its follow settings), the point he is heading for,
# and the stuck check (no progress towards the next waypoint for a couple of seconds).
var colony = null
var target_point: Vector2 = Vector2.INF
var replan_left: float = 0.0
var stuck_time: float = 0.0
var best_distance: float = INF
const STUCK_SECONDS: float = 2.0
const REPLAN_SECONDS: float = 0.5

# His Rest need, and why / how he sleeps.
var rest: Node
var sleep_reason: SleepReason = SleepReason.NONE
var _home_walk_time: float = 0.0
# How long the walk to his bed or his house may take before he is taken to be stuck: walk_home_timeout, or longer for a long way (at a quarter of his speed, plus a margin: an exhausted colonist is that slow).
var _walk_budget: float = 25.0
var _clock: Node
# The bed he has reserved or is lying on (null: none), the beds he has given up on until he wakes, how
# long this sleep has lasted and his own running clock (both in clock-seconds), when he may nap outdoors
# again, and whether he woke up full during the night (he stays up until dawn).
var bed = null
var _bed_avoid: Array = []
# Walking on inside the room (the player is in it) towards the bed after coming in at its door.
var _interior_walk: bool = false
var _nap_seconds: float = 0.0
var _time: float = 0.0
var _nap_block_until: float = 0.0
var _night_rested: bool = false
# His hunger, and the berry bush he has reserved (walking to it or eating at it) and the ones he gave up on.
var hunger: Node
# The shared trip to food (a crate in a building, else a berry bush).
var eat: Node
# True while he is shown in the room of his house (the player is inside it): standing near the door if awake,
# lying on a free bit of floor if asleep. He is still INSIDE for every other purpose.
var in_room: bool = false
# Seconds one berry takes him (picking and eating), at full efficiency.
@export var eat_seconds: float = 1.4
# The asleep picture (colonist_asleep.png, the "asleep" animation) is shown while he lies on a bed or on the
# ground (not inside a house: he is hidden there). It has the same 16x16 canvas as the standing one, so only
# these small nudges (on top of his normal offset) are ever needed; the picture is never scaled.
@export var asleep_offset_on_bed: Vector2 = Vector2.ZERO
@export var asleep_offset_on_ground: Vector2 = Vector2.ZERO
@export var asleep_rotation_degrees: float = 0.0
# His hat and pants colours (res://data/palettes/friend.tres for the friend; the Colony gives every settler an unused one from
# settler_palettes.tres; with none he picks an unused one himself).
@export var palette: CharacterPalette = null
# Picks and plays his animations (the player's CharacterAnimator): walking and standing with what he holds, and the work animations.
var animator: CharacterAnimator = null
var _base_offset: Vector2 = Vector2.ZERO

func _ready() -> void:
	add_to_group("colonists")
	colony = get_tree().get_first_node_in_group("colony")
	_base_offset = offset
	animator = CharacterAnimator.new(self, _base_offset)
	animation_changed.connect(_refresh_overlay)
	# The player's complete set of animations (his own idle / walk / asleep art laid over it) in the colours of his palette.
	sprite_frames = ColonistFrames.get_frames()
	if palette == null:
		palette = PaletteList.unused_palette(get_tree(), self)
	PaletteSwap.apply(self, palette)
	SleepVisual.ensure(self, "res://sprites/colonist_asleep.png")
	play("idle")
	timer = _random_idle_time()
	rest = RestMeter.new()
	# Awake drain: faster while he is at work at the running saw.
	rest.activity = func() -> float:
		var clock: Node = _game_clock()
		if state == State.HELPING_CARRY and carry_job != null and is_instance_valid(carry_job):
			return carry_job.friend_drain()
		if clock != null and state == State.ORDERED and order_ai != null and order_ai.working:
			return clock.work_drain_multiplier
		if clock != null and state == State.ORDERED and order_ai != null and (order_ai.dragger.is_dragging() or not order_ai.carrying.is_empty()):
			return clock.carry_drain_multiplier
		if clock != null and state == State.AT_WORK and work_claim != null and is_instance_valid(work_claim) and work_claim.state == work_claim.State.SAWING:
			return clock.work_drain_multiplier
		return 1.0
	add_child(rest)
	hunger = HungerMeter.new()
	hunger.who_name = "A colonist"
	hunger.starved.connect(die.bind("starvation"))
	hunger.rest = rest
	hunger.activity = func() -> float:
		var clock: Node = _game_clock()
		if clock != null and state == State.ORDERED and order_ai != null and order_ai.working:
			return clock.hunger_work_multiplier
		if clock != null and state == State.AT_WORK and work_claim != null and is_instance_valid(work_claim) and work_claim.state == work_claim.State.SAWING:
			return clock.hunger_work_multiplier
		return 1.0
	add_child(hunger)
	rest.hunger = hunger
	eat = EatTrip.new()
	add_child(eat)
	order_ai = OrderAI.new()
	order_ai.setup(self)
	add_child(order_ai)
	orders_panel = OrdersPanel.new()
	orders_panel.name = "OrdersPanel"
	add_child(orders_panel)
	orders_panel.setup(self)
	eat.setup(self, rest, hunger, eat_seconds)
	eat.phase_changed.connect(_on_eat_phase)
	eat.ended.connect(_on_eat_ended)
	var indicator: Node2D = RestIndicator.new()
	indicator.hunger = hunger
	indicator.rest = rest
	indicator.display_name = "Friend"
	indicator.asleep_outdoors = func() -> bool: return state == State.SLEEPING_OUTSIDE or state == State.ON_BED or (state == State.INSIDE and in_room and rest.sleeping)
	indicator.awake = func() -> bool: return not is_asleep() and not dead
	add_child(indicator)

func _process(delta: float) -> void:
	if dead:
		_process_body()
		return
	rest.sync_animation(self)
	# Whatever took him out of his order (a need, the carry, a task) lets his order's claims go.
	if state != State.ORDERED and order_ai.has_claims():
		order_ai.on_interrupted()
	# Safety: the asleep picture never outlasts the sleep.
	if SleepVisual.is_asleep_shown(self) and state != State.ON_BED and state != State.SLEEPING_OUTSIDE and not in_room:
		_clear_asleep_look()
		play("idle")
	var clock_now: Node = _game_clock()
	if clock_now != null:
		_time += clock_now.clock_delta
		if is_asleep():
			_nap_seconds += clock_now.clock_delta
	# The Orders panel is open: he stands still, facing me, until it closes. Nothing he holds or claims is given up and his job, his path and his
	# timers stay as they were; only HE is held (the world, the clock and his meters go on).
	if orders_panel != null and orders_panel.is_open and _hold_for_panel():
		return
	# A house that has gone away leaves him unhoused.
	if home != null and not is_instance_valid(home):
		become_unhoused()
	if _scheduled():
		_schedule_tick()
	# With a stance he is not "free": every way out of a need or a task lands in IDLE / WALKING / FOLLOWING, and he takes up his order again.
	order_ai.tools.tick_idle(delta)
	order_ai.expire_stale_reason()
	order_ai.debug_tick(delta)
	# (A colonist with roles or tasks is "ordered" too while there is work for him: try_take_work asks the job board; one holding a tool that
	# has to go back is ordered until it is back.)
	if (state == State.IDLE or state == State.WALKING or state == State.FOLLOWING) and (orders.stance != Orders.Stance.FREE or order_ai.sleepy or order_ai.tools.wants_return() or order_ai.try_take_work()):
		order_ai.begin()
		state = State.ORDERED
	# A free colonist who is too far from the MainCharacter stops and goes after him.
	if (state == State.IDLE or state == State.WALKING) and _follows_player() and _distance_to_player() > _leash():
		_start_following()
	match state:
		State.FOLLOWING:
			_process_following(delta)
		State.IDLE:
			timer -= delta
			if timer <= 0.0:
				_start_wander()
		State.WALKING:
			if _follow_path(delta):
				_stand_still()
			elif _is_stuck(delta):
				# No progress for a couple of seconds: choose somewhere else.
				_start_wander()
		State.MOVING_IN:
			if _follow_path(delta):
				print("Colonist moved into %s" % home.name)
				moved_in.emit(self)
				if _scheduled() and not _wants_sleep():
					# Moved in by day: he is out and about like a free colonist, not shut inside.
					_stand_still()
				else:
					# Time to sleep: a free bed in his house, else its floor.
					sleep_reason = SleepReason.NIGHT if _game_clock().is_bedtime() else SleepReason.EXHAUSTED
					_bed_avoid.clear()
					_start_sleep_routine()
		State.ENTERING:
			timer -= delta
			if timer <= 0.0:
				_go_inside()
		State.INSIDE, State.SLEEPING_OUTSIDE:
			# Asleep; the schedule decides when he wakes (without it he stays inside for good).
			pass
		State.RETURNING:
			_home_walk_time += delta
			if _follow_path(delta):
				_begin_entering()
			elif _is_stuck(delta) or _home_walk_time > _walk_budget:
				_replan_home()
		State.TO_SLEEP_SPOT:
			_home_walk_time += delta
			if _follow_path(delta):
				_sleep_outside()
			elif _is_stuck(delta) or _home_walk_time > walk_home_timeout / maxf(0.1, rest.efficiency()):
				waypoints.clear()
				_sleep_outside()
		State.TO_BED:
			_home_walk_time += delta
			if not _bed_still_mine():
				# The bed was broken or taken: the next choice.
				_forget_bed()
				_start_sleep_routine()
			elif _follow_path(delta):
				_arrive_at_bed()
			elif _is_stuck(delta) or _home_walk_time > _walk_budget / maxf(0.1, rest.efficiency()):
				# Cannot get there: give up on this bed.
				_bed_avoid.append(bed)
				_forget_bed()
				_start_sleep_routine()
		State.ON_BED:
			if _bed_still_mine():
				rest.sleep_rate = bed.sleep_rate_now()
		State.TO_BUSH, State.EATING, State.TO_CRATE, State.EATING_CRATE:
			eat.tick(delta)
		State.TO_WORK:
			if _follow_path(delta):
				state = State.AT_WORK
				play("idle")
				if work_claim != null and is_instance_valid(work_claim):
					work_claim.worker_arrived(self)
		State.AT_WORK:
			pass
		State.ORDERED:
			order_ai.tick(delta)
			order_ai.expire_stale_reason()
		State.HELPING_CARRY:
			# (moved by the CarryTogether that owns him)
			pass
	# His picture follows what he does and holds: a work animation only while he swings, else the walk / idle picture for what is in his hands.
	if animator.in_work and (state != State.ORDERED or not order_ai.working):
		animator.end_work()
		# (the work picture goes: back to standing with what he holds; the walk comes when he moves)
		if not SleepVisual.is_asleep_shown(self) and animation != &"asleep":
			pose_idle()
	if not animator.in_work:
		animator.sync_carry(carry_state())
	order_ai.refresh_overlay()

# While the Orders panel is open: idle picture, turned to the player. False (not held) for the ones the panel cannot be opened for anyway.
func _hold_for_panel() -> bool:
	if is_asleep() or state == State.SLEEPING_OUTSIDE or state == State.ON_BED or state == State.INSIDE or state == State.ENTERING or state == State.HELPING_CARRY:
		return false
	var p: Node = get_tree().get_first_node_in_group("player")
	if p != null:
		flip_h = p.global_position.x < global_position.x
	# (a swing in hand stops: the idle picture, the normal offset; the work picks up again from its first frame)
	animator.end_work()
	if not SleepVisual.is_asleep_shown(self):
		pose_idle()
	return true

# --- Dying ---------------------------------------------------------------------------------------------------

# Called by his hunger meter when he starves (the one death check). He stops; his claims go (a crate or bush he
# was taking from, a bed, a job at the pit saw, his place in a house); a body lies where he fell. If he died inside
# a building (asleep in it, or eating at its crate) the body lies INSIDE, in that room, and goes with the room; the
# Colony and the room forget him. After a clock day the body fades and goes.
func die(cause: String = "starvation") -> void:
	if dead:
		return
	# (Working in a room, he lies there: he is not put out at the door first.)
	var work_room: Node2D = order_ai.inside_room if order_ai.inside_room != null and is_instance_valid(order_ai.inside_room) else null
	order_ai.release_all(true, false)
	order_ai.tools.drop_here("he died")
	dead = true
	var room: Node2D = null
	var spot: Vector2 = position
	if work_room != null:
		room = work_room
	elif eat.inside() and eat.crate_building != null and is_instance_valid(eat.crate_building):
		room = eat.crate_building.get_interior()
		spot = eat.crate_spot()
	elif state == State.ON_BED and bed != null and is_instance_valid(bed):
		room = bed.interior_node()
		spot = bed.sleep_spot_world()
	elif (state == State.INSIDE or state == State.ENTERING) and home != null and is_instance_valid(home) and home.interior != null and is_instance_valid(home.interior):
		room = home.interior
		spot = room.occupant_spot(true)
	eat.abort()
	if work_claim != null and is_instance_valid(work_claim) and work_claim.has_method("cancel_request"):
		work_claim.cancel_request()
	work_claim = null
	_forget_bed()
	rest.stop_sleep()
	if home != null and is_instance_valid(home):
		home.residents.erase(self)
	home = null
	waypoints.clear()
	target_point = Vector2.INF
	in_room = false
	if room != null:
		room.shown.erase(self)
		position = spot
	state = State.IDLE
	stop()
	_clear_asleep_look()
	_show_asleep(false)
	set_body_visible(&"*", true)
	add_to_group("bodies")
	remove_from_group("colonists")
	remove_from_group("eaters")
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say("A colonist starved." if cause == "starvation" else "A colonist died.")
	var fast: Node = get_node_or_null("/root/FastForward")
	if fast != null:
		fast.warning("death")
	if colony != null and is_instance_valid(colony):
		colony.colonist_died(self)

# The body: it lies for a clock day, then fades out and goes.
func _process_body() -> void:
	var clock: Node = _game_clock()
	if clock == null:
		return
	_dead_time += clock.clock_delta
	if _dead_time <= clock.day_length:
		return
	var fade: float = clampf((_dead_time - clock.day_length) / 10.0, 0.0, 1.0)
	modulate.a = 1.0 - fade
	if fade >= 1.0:
		queue_free()

# --- The daily schedule --------------------------------------------------------------------------

func _scheduled() -> bool:
	return colony != null and colony.colonists_follow_schedule

func _game_clock() -> Node:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	return _clock

# Is it time for him to sleep: bedtime (dusk or night) for a housed colonist, night for an unhoused one
# (unless he already woke up rested in the night), or he is exhausted (energy below exhausted_threshold),
# by day too. Where he sleeps is chosen by _start_sleep_routine.
func _wants_sleep() -> bool:
	var clock: Node = _game_clock()
	if clock == null:
		return false
	if _is_exhausted(clock):
		return true
	if _night_rested:
		return false
	return clock.is_bedtime() if home != null else clock.is_night()

func _is_exhausted(clock: Node) -> bool:
	return rest.value < clock.exhausted_threshold and _time >= _nap_block_until

func is_asleep() -> bool:
	return state == State.INSIDE or state == State.SLEEPING_OUTSIDE or state == State.ENTERING or state == State.ON_BED

# Called every frame with the schedule on: sends him to bed, or wakes him.
func _schedule_tick() -> void:
	var clock: Node = _game_clock()
	if clock == null:
		return
	if clock.is_daytime():
		_night_rested = false
	if order_ai.sleepy and not _wants_sleep():
		order_ai.sleepy = false
	# (A visitor in a room cannot go to eat or sleep from there: out at the door first. Going to bed waits until his hands and his job are let go, the wind-down
	# for bed finishes what he carries first: put out of the room with the plank in his hands he walked back in with it, and was put out again, for ever.)
	if state == State.ORDERED and (order_ai.visiting != null or order_ai.inside_room != null) and (hunger.is_hungry() or _starving(clock) or (_wants_sleep() and _ready_for_bed())):
		order_ai.release_all()
	match state:
		State.IDLE, State.WALKING, State.FOLLOWING, State.ORDERED:
			if _starving(clock) and not _is_exhausted(clock) and work_claim == null and _start_eating():
				pass
			elif _wants_sleep() and not _ready_for_bed():
				# (still finishing his swing, delivering what he carries, putting the tool back: he sets out for his bed when his hands and his claims are free)
				pass
			elif _wants_sleep():
				order_ai.sleepy = false
				sleep_reason = SleepReason.NIGHT if (clock.is_bedtime() if home != null else clock.is_night()) else SleepReason.EXHAUSTED
				_bed_avoid.clear()
				_start_sleep_routine()
			elif work_claim == null and hunger.is_hungry():
				# Hungry (and not sleepy: sleeping comes first): the nearest crate with berries, else the nearest
				# ripe bush.
				_start_eating()
		State.TO_CRATE, State.EATING_CRATE, State.TO_BUSH, State.EATING:
			# Once he has set out to eat only bedtime stops him (being exhausted decided things before he chose: sleep
			# first, then food).
			if (clock.is_bedtime() if home != null else clock.is_night()) and not _starving(clock):
				eat.abort()
				sleep_reason = SleepReason.NIGHT if (clock.is_bedtime() if home != null else clock.is_night()) else SleepReason.EXHAUSTED
				_bed_avoid.clear()
				_start_sleep_routine()
		State.RETURNING:
			# Heading home to bed, but starving (food first) or it is day again and he is rested: carry on.
			if _starving(clock) and not _is_exhausted(clock) and _start_eating():
				pass
			elif home != null and not _wants_sleep() and clock.is_daytime():
				_stand_still()
		State.TO_SLEEP_SPOT:
			if _starving(clock) and not _is_exhausted(clock) and _start_eating():
				pass
			elif not _wants_sleep() and clock.is_daytime():
				_stand_still()
		State.TO_BED:
			# On his way to a bed, but starving (food first) or it is day again and he is rested: carry on.
			if _starving(clock) and not _is_exhausted(clock) and _start_eating():
				_forget_bed()
			elif not _wants_sleep() and clock.is_daytime():
				_forget_bed()
				_stand_still()
		State.INSIDE, State.SLEEPING_OUTSIDE, State.ON_BED:
			if state == State.ON_BED and not _bed_still_mine():
				# The bed has gone from under him: the next choice.
				_forget_bed()
				_start_sleep_routine()
			else:
				_check_wake(clock)

# Is he ready to set out for his bed? Ordered, the order AI gets him ready (see ColonistOrderAI, GETTING READY FOR BED); standing about or following with a
# tool or a thing in his hands, the same happens as soon as he is ordered (a held thing makes him sleepy-ordered).
func _ready_for_bed() -> bool:
	if state == State.ORDERED:
		return order_ai.ready_for_bed()
	if order_ai.tools.holding() or not order_ai.carrying.is_empty() or order_ai.dragger.is_dragging():
		order_ai.sleepy = true
		return false
	return true

# Where he sleeps (shared rules in BedFinder): a free bed (his house's first, then any spare one, the nearest
# reachable), else the floor of his house, else outdoors where he stands.
func _start_sleep_routine() -> void:
	var found = BedFinder.choose(get_tree(), self, position, home, _bed_avoid)
	if found != null and found.reserve(self):
		_go_to_bed(found)
	elif home != null and is_instance_valid(home):
		_go_home_to_sleep()
	else:
		_go_sleep_outside()

# No bed and no house: he lies down on the ground beside the toolbox or the campfire nearest to him (else where he stands), in the asleep picture; he is never taken
# out of the world. The hover line says "Sleeping outside, no free bed".
func _go_sleep_outside() -> void:
	var spot: Vector2 = Vector2.INF
	var best: float = 500.0 * 500.0
	for g in ["toolboxes", "campfires"]:
		for n in get_tree().get_nodes_in_group(g):
			if g == "toolboxes" and n.is_carried():
				continue
			var d: float = position.distance_squared_to(n.global_position)
			if d < best:
				best = d
				spot = n.global_position + Vector2(0, 20)
	if spot == Vector2.INF or position.distance_to(spot) < 24.0:
		_sleep_outside()
		return
	waypoints = _path_to(spot)
	_home_walk_time = 0.0
	_reset_stuck()
	state = State.TO_SLEEP_SPOT
	play("walk")

# The sleep skip: the screen is black and the night is passing. A colonist who would be in bed is brought there in ONE step: what he holds put away first (a tool into
# the toolbox, a thing into storage or beside the house), his claims let go, then into his bed (or onto his house's floor, or the ground by the toolbox). One who is
# not due to sleep (a nap of mine by day) carries on with his work as he was.
func bed_down_for_skip() -> void:
	if dead or is_asleep() or work_claim != null or state == State.HELPING_CARRY or state == State.TO_WORK or state == State.AT_WORK:
		return
	if _game_clock() == null or not _wants_sleep():
		return
	eat.abort()
	order_ai.prepare_instantly()
	sleep_reason = SleepReason.NIGHT if (_game_clock().is_bedtime() if home != null else _game_clock().is_night()) else SleepReason.EXHAUSTED
	_bed_avoid.clear()
	_start_sleep_routine()
	match state:
		State.TO_BED:
			_arrive_at_bed()
		State.RETURNING:
			position = home.door_position()
			waypoints.clear()
			_begin_entering()
		State.TO_SLEEP_SPOT:
			waypoints.clear()
			_sleep_outside()

# Where he sleeps (shared rules in BedFinder, second part): a free bed

# Debug (F10 from the player): lies down on the ground where he stands and stays asleep until F10 again.
var _debug_hold: bool = false

func debug_sleep_toggle() -> void:
	if _debug_hold:
		_debug_hold = false
		_wake_up()
		return
	if work_claim != null or state == State.INSIDE or state == State.ENTERING:
		return
	_forget_bed()
	_debug_hold = true
	sleep_reason = SleepReason.NIGHT
	_sleep_outside()

func _check_wake(clock: Node) -> void:
	if _debug_hold:
		return
	var outdoors: bool = state == State.SLEEPING_OUTSIDE
	match BedFinder.step(clock, rest, sleep_reason, outdoors, _nap_seconds):
		BedFinder.Wake.WAKE:
			_wake_up()
		BedFinder.Wake.WAKE_FULL:
			_night_rested = true
			_wake_up()
		BedFinder.Wake.WAKE_CAPPED:
			_nap_block_until = _time + clock.nap_retry_seconds
			_wake_up()
		BedFinder.Wake.TO_NIGHT:
			sleep_reason = SleepReason.NIGHT

# --- Eating ---------------------------------------------------------------------------------------------

# Starving: below hunger_warn_below. Then food comes before going to bed (a sleep he cannot avoid, being
# exhausted, still comes first).
func _starving(clock: Node) -> bool:
	return hunger.value < clock.hunger_warn_below

# Sets out for the nearest crate with berries, else the nearest ripe bush; false if there is neither. The trip
# itself (walking, going in, eating, coming out) is the shared EatTrip, which also feeds the workers.
func _start_eating() -> bool:
	return eat.start()

func _on_eat_phase(phase: int) -> void:
	match phase:
		EatTrip.Phase.TO_CRATE:
			state = State.TO_CRATE
		EatTrip.Phase.IN_CRATE:
			state = State.EATING_CRATE
		EatTrip.Phase.TO_BUSH:
			state = State.TO_BUSH
		EatTrip.Phase.AT_BUSH:
			state = State.EATING

# He has had enough, or nothing is left to go to: he stands free again (and follows the player).
func _on_eat_ended() -> void:
	_stand_still()

# The crate trip he is on, for the rooms and dismantling to ask about.
func crate_trip_active() -> bool:
	return eat.crate_active()

# --- Beds ---------------------------------------------------------------------------------------------

func _bed_still_mine() -> bool:
	return bed != null and is_instance_valid(bed) and bed.is_in_group("beds") and not bed.is_queued_for_deletion() and (bed.reserved_by == self or bed.sleeper == self)

func _forget_bed() -> void:
	if bed != null and is_instance_valid(bed):
		# On (or walking in to) a bed inside a house: he steps out of its door.
		var room: Node2D = bed.interior_node()
		if room != null and (state == State.ON_BED or _interior_walk):
			room.shown.erase(self)
			if room.building != null and is_instance_valid(room.building):
				position = room.building.door_position()
			set_body_visible(&"*", true)
			in_room = false
		bed.release_sleeper(self)
	_interior_walk = false
	bed = null

# Walking up to the bed he has reserved: a bed inside a house is reached through the door of that house.
func _go_to_bed(target_bed) -> void:
	_clear_asleep_look()
	bed = target_bed
	_interior_walk = false
	waypoints = _path_to(bed.approach_point())
	_home_walk_time = 0.0
	_walk_budget = _budget_for(waypoints)
	_reset_stuck()
	state = State.TO_BED
	play("walk")

# He has reached the bed (or, for one inside a house, its door): a bed outdoors he lies on at once; a bed inside
# he goes in to, and if the player is in that room he is seen coming in at the door and walking to it.
func _arrive_at_bed() -> void:
	var room: Node2D = bed.interior_node()
	if room != null and room.player_inside and not _interior_walk:
		_interior_walk = true
		position = room.door_world()
		set_body_visible(&"*", true)
		room.shown.append(self)
		waypoints = [bed.sleep_spot_world()]
		_reset_stuck()
		play("walk")
		return
	_lie_on_bed()

func _lie_on_bed() -> void:
	bed.lie_down(self)
	position = bed.sleep_spot_world()
	var room: Node2D = bed.interior_node()
	if room != null:
		# In a room he is seen only while the player is in it.
		_interior_walk = false
		set_body_visible(&"room", room.player_inside)
		in_room = room.player_inside
		if room.player_inside and not room.shown.has(self):
			room.shown.append(self)
	else:
		set_body_visible(&"*", true)
	waypoints.clear()
	target_point = Vector2.INF
	state = State.ON_BED
	_nap_seconds = 0.0
	_show_asleep(true)
	AudioManager.play("sleep_on", position, 1.0, -6.0)
	rest.start_sleep(bed.sleep_rate_now())

func _go_home_to_sleep() -> void:
	_nap_seconds = 0.0
	waypoints = _path_to(home.door_position())
	_home_walk_time = 0.0
	_walk_budget = _budget_for(waypoints)
	_reset_stuck()
	state = State.RETURNING
	play("walk")

# The time a walk along `path` may take: walk_home_timeout, or for a long way (a farm by the creek, a tree far from the house) what a quarter of his speed needs plus 10 s.
func _budget_for(path: Array) -> float:
	var length: float = 0.0
	var at: Vector2 = position
	for p in path:
		length += at.distance_to(p)
		at = p
	return maxf(walk_home_timeout, length / maxf(8.0, speed * 0.25) + 10.0)

func _replan_home() -> void:
	if home == null or not is_instance_valid(home):
		_stand_still()
		return
	if _home_walk_time > _walk_budget:
		# Stuck for good (the house cannot be reached): he lies down beside the toolbox or the campfire, in the open and visible.
		waypoints.clear()
		_go_sleep_outside()
		return
	waypoints = _path_to(home.door_position())
	_reset_stuck()

func _sleep_outside() -> void:
	waypoints.clear()
	target_point = Vector2.INF
	state = State.SLEEPING_OUTSIDE
	_nap_seconds = 0.0
	_show_asleep(false)
	AudioManager.play("sleep_on", position, 1.0, -6.0)
	rest.start_sleep(_game_clock().sleep_rate_outdoors())

# The asleep picture (see SleepVisual): one shared function for every sleeper.
func _show_asleep(on_bed: bool) -> void:
	SleepVisual.set_asleep(self, true, asleep_offset_on_bed if on_bed else asleep_offset_on_ground, asleep_rotation_degrees)

func _clear_asleep_look() -> void:
	SleepVisual.set_asleep(self, false)

# The player is in the room he is in (his house, or the building whose crate he is eating from): he shows there
# (see BuildingInterior).
func show_in_room(spot: Vector2) -> void:
	in_room = true
	set_body_visible(&"*", true)
	if state == State.ON_BED or state == State.TO_BED:
		return
	position = spot
	if rest.sleeping:
		SleepVisual.set_asleep(self, true, asleep_offset_on_ground, asleep_rotation_degrees)
	else:
		SleepVisual.set_asleep(self, false)
		play("idle")

# The player left the room he is working in: he goes on with his job there, out of sight (nothing is moved).
func hide_in_place() -> void:
	in_room = false
	set_body_visible(&"room", false)

func hide_from_room() -> void:
	in_room = false
	if state == State.TO_BED and _interior_walk:
		# The player left while he was still walking in: he is on the bed.
		_lie_on_bed()
		set_body_visible(&"room", false)
		return
	if state == State.ON_BED:
		set_body_visible(&"room", false)
		return
	SleepVisual.set_asleep(self, false)
	set_body_visible(&"room", false)
	if home != null and is_instance_valid(home):
		position = home.door_position()

func _wake_up() -> void:
	if in_room:
		in_room = false
	if visible:
		AudioManager.play("wake", position, 1.0, -6.0)
	_clear_asleep_look()
	sleep_reason = SleepReason.NONE
	rest.stop_sleep()
	_forget_bed()
	_bed_avoid.clear()
	if state == State.INSIDE and home != null and is_instance_valid(home):
		position = home.door_position()
		_show()
	_stand_still()

# --- Houses and jobs ------------------------------------------------------------------------------

# Claims go through the Colony; this just sends him to the door.
func move_in(building) -> void:
	home = building
	_show()
	_clear_asleep_look()
	if state == State.SLEEPING_OUTSIDE or state == State.ON_BED or state == State.TO_BED:
		# He was asleep on the ground (or on a bed): the new house has a bed, but it is his own morning.
		_forget_bed()
		rest.stop_sleep()
		sleep_reason = SleepReason.NONE
	state = State.MOVING_IN
	waypoints = _path_to(building.door_position())
	play("walk")

func become_unhoused() -> void:
	if home != null and is_instance_valid(home):
		home.residents.erase(self)
	var was_inside: bool = state == State.INSIDE or state == State.ENTERING
	home = null
	if was_inside:
		# Steps out of the door he lived behind and carries on as an unhoused colonist.
		_show()
		rest.stop_sleep()
		sleep_reason = SleepReason.NONE
	if state == State.MOVING_IN or state == State.RETURNING or was_inside:
		_stand_still()
	became_unhoused.emit(self)

func is_unhoused() -> bool:
	return home == null

func is_claimed() -> bool:
	return work_claim != null

# Free to be asked to help: not already claimed, not on his way into a house, and awake. With the
# schedule on a colonist inside or asleep is never asked; without it, colonists inside a house count
# as free (the old behaviour).
func is_available_for_work() -> bool:
	if work_claim != null:
		return false
	if state == State.SLEEPING_OUTSIDE or state == State.ON_BED or state == State.TO_BED or state == State.TO_BUSH or state == State.EATING or state == State.TO_CRATE or state == State.EATING_CRATE or state == State.HELPING_CARRY:
		return false
	if _scheduled() and (state == State.INSIDE or state == State.ENTERING):
		return false
	return state != State.MOVING_IN and state != State.TO_WORK and state != State.AT_WORK

# --- Orders ---------------------------------------------------------------------------------------------------------------

# His orders changed (a stance, a role taken away, all orders cleared): a workstation he is helping at (the pit saw) lets him go at once.
func orders_changed() -> void:
	if work_claim != null and is_instance_valid(work_claim) and work_claim.has_method("helper_left"):
		work_claim.helper_left(self)

# Gives him a stance. (His claims go; STAY keeps him where he is now.)
func set_stance(stance: int) -> void:
	orders_changed()
	# (Follow and Assist pause the work: what he carries is set down; Free and Stay keep tasks and roles going.)
	order_ai.release_all(stance == Orders.Stance.FOLLOW or stance == Orders.Stance.ASSIST)
	orders.set_stance(stance, position)
	if state == State.ORDERED:
		if stance == Orders.Stance.FREE:
			_stand_still()
		else:
			order_ai.begin()

# Why E on him is disabled ("" = he can be talked to).
func talk_block_reason() -> String:
	if dead:
		return "He is gone."
	if state == State.HELPING_CARRY:
		return "He is carrying the toolbox."
	if is_asleep() or state == State.SLEEPING_OUTSIDE or state == State.ON_BED:
		return "He is asleep."
	if not visible and not in_room:
		return "He is indoors."
	return ""

# What he is doing, for the Orders panel and the hover overlay.
func status_text() -> String:
	if dead:
		return "Dead"
	match state:
		State.HELPING_CARRY:
			return "Carrying the toolbox"
		State.ORDERED:
			return order_ai.status if order_ai.status != "" else "Waiting"
		State.EATING, State.TO_BUSH, State.TO_CRATE, State.EATING_CRATE:
			return "Eating" if state == State.EATING or state == State.EATING_CRATE else "Looking for food"
		State.SLEEPING_OUTSIDE:
			return "Sleeping outside, no free bed"
		State.ON_BED, State.INSIDE, State.ENTERING:
			return "Resting"
		State.TO_BED, State.RETURNING, State.MOVING_IN:
			return "Heading home"
		State.TO_SLEEP_SPOT:
			return "Looking for a place to sleep"
		State.TO_WORK, State.AT_WORK:
			return "Helping at the pit saw"
		State.FOLLOWING:
			return "Following you"
	return "Free time"

# The line the hover overlay adds: "Order: Free time. Lumberjack. Chopping a tree (3 marked left)." plus what went wrong or was finished
# lately, why work is paused, and why he cannot be talked to.
func hover_note() -> String:
	var text: String = "Order: %s." % orders.name_now()
	var role_names: Array[String] = []
	for r in orders.roles:
		role_names.append(Orders.ROLE_NAMES[r])
	if not role_names.is_empty():
		text += " %s." % ", ".join(role_names)
	text += " %s." % status_text()
	var now: float = Time.get_ticks_msec() / 1000.0
	if order_ai.fail_text != "" and now < order_ai.fail_until and not order_ai.reason_is_stale():
		text += "\n" + order_ai.fail_text
	elif order_ai.last_report != "" and now < order_ai.report_until:
		text += "\n" + order_ai.last_report
	if paused_text() != "":
		text += "\n" + paused_text()
	if order_ai.tools.holding():
		text += "\nHolding: %s" % String(order_ai.tools.held).replace("_", " ")
	var why: String = talk_block_reason()
	if why != "":
		text += "\n" + why
	return text

# Asked to bring the borrowed tool back (the greyed row in the toolbox panel): after the swing in hand he walks it back.
func recall_tool() -> void:
	order_ai.tools.recall()

# "Tasks paused while following." when he has work he is not doing because of his stance.
func paused_text() -> String:
	if orders.has_work() and not order_ai.work_allowed():
		if not orders.tasks.is_empty():
			return "Tasks paused while following."
		return "Roles paused while following."
	return ""

func talk(_player) -> String:
	var why: String = talk_block_reason()
	if why != "":
		return why
	orders_panel.open_for(_player)
	return ""

# --- What he holds and how he looks for it (CharacterAnimator) ---------------------------------------------------------------

# What he CARRIES (the item with the little picture above his head), for the picker and the overlay rule: a plank, the saw blade or an item; no tools.
func carried_state() -> Dictionary:
	var carried: StringName = order_ai.carrying.get("kind", &"")
	var item: StringName = &""
	if carried != &"" and carried != &"plank" and carried != &"saw_blade":
		item = carried
	return CharacterAnimator.held_state(false, 1 if carried == &"plank" else 0, carried == &"saw_blade", "", item)

# What is in his hands, for the picker: a dragged log (the normal walk), what he carries, else the tool he holds.
func carry_state() -> Dictionary:
	var ai: Node = order_ai
	var state: Dictionary = carried_state()
	state["dragging"] = ai.dragger.is_dragging()
	if CharacterAnimator.carry_key(carried_state()) == &"" and ai.tools != null and ai.tools.held != &"":
		state["item"] = ai.tools.held
	return state

func _refresh_overlay() -> void:
	if order_ai != null:
		order_ai.refresh_overlay()

func pose_walk() -> void:
	animator.pose(carry_state(), true)

func pose_idle() -> void:
	animator.pose(carry_state(), false)

# --- Helping to carry (the CarryTogether drives these) -----------------------------------------------------------------------

func begin_carry_help(job) -> void:
	order_ai.release_all(true)
	# (both hands are on the toolbox: a tool he held goes back first)
	order_ai.tools.return_instantly()
	eat.abort()
	carry_job = job
	state = State.HELPING_CARRY
	waypoints.clear()
	target_point = Vector2.INF
	_carry_replan = 0.0
	play("idle")

func end_carry_help() -> void:
	carry_job = null
	waypoints.clear()
	if state == State.HELPING_CARRY and not dead:
		_stand_still()

# One step towards `point` round whatever is in the way (own speed, tiredness and wading apply); returns how far he moved.
func carry_walk_to(point: Vector2, delta: float, speed_multiplier: float = 1.0) -> float:
	_carry_replan -= delta
	if _carry_replan <= 0.0 or waypoints.is_empty():
		_carry_replan = 0.25
		waypoints = _path_to(point) if position.distance_to(point) > 0.5 else ([] as Array[Vector2])
	elif waypoints.size() == 1:
		waypoints[0] = point
	var before: Vector2 = position
	if not waypoints.is_empty():
		_follow_path(delta, speed_multiplier)
	var moved: float = position.distance_to(before)
	if moved > 0.01:
		pose_walk()
	else:
		pose_idle()
	return moved

# Awake but too tired to help (the pit saw says "too tired").
func is_too_tired_to_work() -> bool:
	var clock: Node = _game_clock()
	return clock != null and rest.value < clock.refuse_work_below

# A job claims him: he comes out of his house (at the door) if he was inside, and walks to
# the spot.
func claim_for_work(job, spot: Vector2) -> void:
	order_ai.release_all(true)
	work_claim = job
	eat.abort()
	if state == State.INSIDE or state == State.ENTERING:
		position = home.door_position()
	_forget_bed()
	_clear_asleep_look()
	rest.stop_sleep()
	sleep_reason = SleepReason.NONE
	_show()
	state = State.TO_WORK
	waypoints = _path_to(spot)
	play("walk")

# The saw is running: he is drawn inside the in-use sprite, so he is hidden.
func hide_for_work() -> void:
	if dead:
		return
	set_body_visible(&"pose", false)

func show_after_work(spot: Vector2) -> void:
	if dead:
		return
	position = spot
	_show()
	play("idle")

# The job is over. With the schedule he is simply a free colonist again (and goes to bed if it is
# bedtime); without it a housed colonist goes home and inside.
func release_work() -> void:
	if dead:
		return
	work_claim = null
	if not _scheduled() and home != null and is_instance_valid(home):
		_return_to_door()
	else:
		_stand_still()
	released.emit(self)

func is_inside() -> bool:
	return state == State.INSIDE

# Where he idles and wanders around: the MainCharacter (a free colonist, or a housed one by day),
# else his door, else the landing point.
func anchor() -> Vector2:
	if _follows_player():
		return colony.player_anchor()
	if home != null and is_instance_valid(home):
		return home.door_position()
	return landing_position

# A free colonist: no house, not busy. With the schedule a housed colonist is out by day and follows
# like one. (Working, inside, or on his way into a house he is not "free".) And the Colony's switch
# is on.
func _follows_player() -> bool:
	if colony == null or not colony.free_colonists_follow_player or work_claim != null:
		return false
	return home == null or colony.colonists_follow_schedule

func _distance_to_player() -> float:
	return position.distance_to(colony.player_anchor())

func _leash() -> float:
	return colony.leash_distance_cells * CELL

# --- Following the MainCharacter ---------------------------------------------------------

func _start_following() -> void:
	state = State.FOLLOWING
	replan_left = 0.0
	target_point = Vector2.INF
	_reset_stuck()
	play("walk")

func _process_following(delta: float) -> void:
	if not _follows_player():
		_stand_still()
		return
	# Close enough again: back to idling and wandering round him.
	if _distance_to_player() <= colony.follow_radius_cells * CELL:
		_stand_still()
		return
	replan_left -= delta
	if replan_left <= 0.0 or waypoints.is_empty():
		_plan_follow_path()
	var hurry: float = colony.catch_up_multiplier if _distance_to_player() > _leash() * 2.0 else 1.0
	_follow_path(delta, hurry)
	if _is_stuck(delta):
		# Stuck behind something: aim at a different spot beside him.
		_plan_follow_path(true)

# Heads for a spot a little way from him on the colonist's own side (so he never ends up on
# top of him), inside the follow radius.
func _plan_follow_path(jitter: bool = false) -> void:
	replan_left = REPLAN_SECONDS
	_reset_stuck()
	var centre: Vector2 = colony.player_anchor()
	var away: Vector2 = (position - centre).normalized()
	if away == Vector2.ZERO:
		away = Vector2.RIGHT
	var reach: float = colony.follow_radius_cells * CELL * 0.8
	for attempt in 10:
		var angle: float = randf_range(-0.9, 0.9) if (jitter or attempt > 0) else 0.0
		var point: Vector2 = (centre + away.rotated(angle) * reach).round()
		if _can_stand_at(point) and not _crowded(point):
			target_point = point
			waypoints = _path_to(point)
			return
	# Nowhere good found: walk straight at him (the stuck check will try again).
	target_point = centre
	waypoints = _path_to(centre)

# --- Wandering round the MainCharacter ---------------------------------------------------

# Is another free colonist standing at, or heading for, (about) this point?
func _crowded(point: Vector2) -> bool:
	for c in get_tree().get_nodes_in_group("colonists"):
		if c == self or not c._follows_player() or not c.visible:
			continue
		if c.position.distance_to(point) < colony.follow_spread:
			return true
		if c.target_point != Vector2.INF and c.target_point.distance_to(point) < colony.follow_spread:
			return true
	return false

func _start_follow_wander() -> void:
	var centre: Vector2 = colony.player_anchor()
	var radius: float = colony.follow_radius_cells * CELL
	for attempt in 14:
		# Between a little way off him and the follow radius.
		var dist: float = lerpf(colony.follow_min_distance, radius, sqrt(randf()))
		var point: Vector2 = (centre + Vector2.from_angle(randf() * TAU) * dist).round()
		if _can_stand_at(point) and not _crowded(point) and _route_clear_of_player(point):
			target_point = point
			waypoints = _path_to(point)
			_reset_stuck()
			state = State.WALKING
			play("walk")
			return
	timer = _random_idle_time()
	state = State.IDLE

# The straight walk to `point` must not pass within a little way of the MainCharacter (he is
# not to be walked through or stood on). Fine if he is already right beside him.
func _route_clear_of_player(point: Vector2) -> bool:
	var player: Vector2 = colony.player_anchor()
	var keep_away: float = colony.follow_min_distance * 0.75
	if position.distance_to(player) < keep_away:
		return true
	return Geometry2D.get_closest_point_to_segment(player, position, point).distance_to(player) >= keep_away

func _reset_stuck() -> void:
	stuck_time = 0.0
	best_distance = INF

# True once he has made no progress towards his next waypoint for STUCK_SECONDS.
func _is_stuck(delta: float) -> bool:
	if waypoints.is_empty():
		return false
	var d: float = position.distance_to(waypoints[0])
	if d < best_distance - 0.5:
		best_distance = d
		stuck_time = 0.0
		return false
	stuck_time += delta
	return stuck_time >= STUCK_SECONDS

func _path_to(point: Vector2) -> Array[Vector2]:
	return Footprints.path_around(Footprints.base_rects(get_tree()), position, point, path_margin)

func _stand_still() -> void:
	state = State.IDLE
	waypoints.clear()
	target_point = Vector2.INF
	timer = _random_idle_time()
	play("idle")

func _random_idle_time() -> float:
	return randf_range(idle_time_range.x, idle_time_range.y)

# At the door: wait enter_delay (if any), then go in.
func _begin_entering() -> void:
	waypoints.clear()
	state = State.ENTERING
	timer = enter_delay
	play("idle")
	if enter_delay <= 0.0:
		_go_inside()

# Gone from view and from the world: no wandering, no walking, no animation. He stays the
# house's resident (bed occupied, counted as housed) but cannot be picked as unhoused. He sleeps
# at the house's sleep quality (the wooden floor with no bed).
func _go_inside() -> void:
	state = State.INSIDE
	waypoints.clear()
	stop()
	set_body_visible(&"inside", false)
	if sleep_reason == SleepReason.NONE:
		sleep_reason = SleepReason.NIGHT
	_nap_seconds = 0.0
	rest.start_sleep(_game_clock().sleep_rate_for_bed(0))
	print("Colonist went inside %s" % home.name)
	# (If the player is in that very room he comes in where he can be seen.)
	if home.player_is_inside():
		home.interior.show_colonist(self)

func _show() -> void:
	set_body_visible(&"*", true)

# THE ONE PLACE a colonist's body is shown or hidden. Whoever hides him names itself ("room": out of sight in a room the player is not in, "inside": asleep
# in his house, "pose": at the pit saw, "crate": eating from a crate, "job": a step of a job that goes out of sight for a moment), and shows him again under
# the same name; he is visible exactly while nobody keeps him hidden. The name "*" shows him whatever hid him (arriving, waking, a room closing).
# ColonistViewGuard (debug builds) checks that every name still has its reason, and puts him back when one has not.
var hidden_by: Dictionary = {}

func set_body_visible(source: StringName, on: bool) -> void:
	if on:
		if source == &"*":
			hidden_by.clear()
		else:
			hidden_by.erase(source)
	else:
		hidden_by[source] = true
	visible = hidden_by.is_empty()

func _return_to_door() -> void:
	state = State.RETURNING
	_home_walk_time = 0.0
	waypoints = _path_to(home.door_position())
	play("walk")

func _start_wander() -> void:
	if _follows_player():
		_start_follow_wander()
		return
	var radius: float = wander_radius_cells * CELL
	for attempt in 12:
		var point: Vector2 = (anchor() + Vector2.from_angle(randf() * TAU) * radius * sqrt(randf())).round()
		if _can_stand_at(point):
			waypoints = _path_to(point)
			state = State.WALKING
			play("walk")
			return
	timer = _random_idle_time()
	state = State.IDLE

# Inside the map, and his feet not on a building footprint, tree, Sawmill or Storage.
func _can_stand_at(point: Vector2) -> bool:
	var allowed := Rect2(map_rect.position + Vector2(8, 16), map_rect.size - Vector2(16, 16))
	if not allowed.has_point(point):
		return false
	return not Footprints.rect_blocked(get_tree(), Rect2(point - Vector2(4, 2), Vector2(8, 4)))

# Walks the waypoints in order; true once the last one is reached. A tired colonist walks slower
# (the Rest meter's speed share).
func _follow_path(delta: float, speed_multiplier: float = 1.0) -> bool:
	if waypoints.is_empty():
		return true
	var target: Vector2 = waypoints[0]
	if target.x < position.x:
		flip_h = true
	elif target.x > position.x:
		flip_h = false
	var before: Vector2 = position
	position = position.move_toward(target, speed * speed_multiplier * rest.speed_factor() * WaterMap.speed_factor(position) * delta)
	WaterMap.walked(self, position.distance_to(before))
	if position.distance_to(target) < 0.01:
		waypoints.remove_at(0)
		# (The next waypoint is a new goal: a detour round something is no "no progress".)
		_reset_stuck()
	return waypoints.is_empty()
