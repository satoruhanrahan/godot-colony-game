extends CharacterBody2D

const LogDragger = preload("res://scripts/log_dragger.gd")
const PlankPiles = preload("res://scripts/plank_piles.gd")
const Dismantle = preload("res://scripts/dismantle.gd")
const WorkFeedback = preload("res://scripts/work_feedback.gd")
const HungerMeter = preload("res://scripts/hunger_meter.gd")
const SleepSkip = preload("res://scripts/sleep_skip.gd")
const Items = preload("res://scripts/items.gd")
const FoodConfig = preload("res://scripts/food_config.gd")
const WaterMap = preload("res://scripts/water_map.gd")
const GameOver = preload("res://scripts/game_over.gd")
const ScreenFade = preload("res://scripts/screen_fade.gd")
const WorkFx = preload("res://scripts/work_fx.gd")
const SleepVisual = preload("res://scripts/asleep_frames.gd")
const RestMeter = preload("res://scripts/rest_meter.gd")
const RestIndicator = preload("res://scripts/rest_indicator.gd")
# Frame of the "chop" sheet where the axe head is fully extended (the strike). Each hit is
# counted when this frame appears, so the counter matches the visible impact.
const CHOP_STRIKE_FRAME: int = CharacterAnimator.CHOP_STRIKE_FRAME
# Frame of the "dig" sheet where the shovel blade comes down into the ground (the last
# frame; frame 0 is the blade resting in the ground, the start pose).
const DIG_STRIKE_FRAME: int = CharacterAnimator.DIG_STRIKE_FRAME
# Frame of the "pull" sheet where the grass comes up (the yank), counted as one pull.
const PULL_STRIKE_FRAME: int = CharacterAnimator.PULL_STRIKE_FRAME
# Frame of the "hammer" sheet where the hammer head is fully out (the blow); frame 2 holds it.
const HAMMER_STRIKE_FRAME: int = CharacterAnimator.HAMMER_STRIKE_FRAME

@export var speed: float = 40.0
# Playable area, and how far the character's sprite stays from its edges
# (half of the 16x16 sprite's width). His origin is at his feet, so the top limit
# is a full sprite height down and the bottom limit is the map's bottom edge.
@export var map_rect: Rect2 = Rect2(0, 0, 640, 640)
@export var edge_margin: float = 8.0
# Multiplier applied to `speed` while he drags a log (he uses his normal walk animation).
@export var drag_speed_multiplier: float = 0.5
# Where he stands relative to the tree's origin (its base) while chopping, for the LEFT side
# of the tree; the x is mirrored when he stands on the right. y is for his feet. Felling:
# the axe head touches the standing trunk. Delimbing: the trunk lies on the ground, so he
# stands a few pixels lower and closer to reach it. (Same numbers as the Lumberjack.)
@export var fell_stand_offset: Vector2 = Vector2(-16, 0)
@export var delimb_stand_offset: Vector2 = Vector2(-13, 7)
# The 32x32 chop frames draw the character in the bottom half and 2px left of centre; this
# sprite offset (mirrored in x when flipped) keeps his body where it is in the 16x16 walk
# frames. Only applied while the "chop" animation plays.
@export var chop_sprite_offset: Vector2 = Vector2(2, -16)
# Planks he can carry at once (one), and the speed multiplier while he does. Carrying uses the
# "carry_plank" animation (frame 1 of it when he stands still).
@export var carry_capacity: int = 1
@export var plank_speed_multiplier: float = 0.75
# Q / right-click puts what he holds down at the mouse when the mouse is within this many pixels
# of him (and the spot is free), otherwise in front of him.
@export var drop_reach: float = 48.0
# When his hands are full, picking up another item (a tool, a plank, the blade or a log) puts down
# what he holds at his feet first and takes the new one. Off: "Your hands are full".
@export var swap_on_pickup: bool = true
# Carrying a bundle of grass or hay: his speed is this share of normal (times his efficiency).
@export var hay_speed_multiplier: float = 0.9
# Where he stands to pull a patch of grass, relative to it (mirrored to the side he came from).
@export var pull_stand_offset: Vector2 = Vector2(10, 3)
# A plank he puts down (Q) goes into the nearest pile this close that has fewer than 3.
@export var pile_merge_radius: float = 20.0
# How many of the tree's hits one swing counts. 1 = exactly one hit per swing. (The tree
# needs FELL_HITS then DELIMB_HITS, 10 each; 2 would halve the presses needed by hand.)
@export var hits_per_chop: int = 1
# While true, one extra E press / click during a swing is remembered and starts the next
# swing the moment this one ends. Off: presses during a swing are ignored.
@export var queue_next_chop: bool = false
# He keeps the tree claimed while standing within the interaction radius and he has chopped
# within this many seconds; after that (or when he walks off) the claim is released.
@export var claim_hold_time: float = 3.0
# The 32x32 dig frames draw the character 3px left and 9px above the bottom of the
# canvas centre; this sprite offset (mirrored in x when flipped) keeps his body where it is
# in the walk frames. Only applied while the "dig" animation plays.
@export var dig_sprite_offset: Vector2 = Vector2(3, -9)
# Nudge for where he stops to pick up a log (same meaning as the Hauler's).
@export var log_pickup_offset: Vector2 = Vector2.ZERO
# Clearance kept from solid things when he walks himself somewhere.
@export var path_margin: float = 4.0

# CHOP_IDLE: standing in his chopping spot between swings (the tree stays claimed for a
# few seconds). CHOPPING: one swing of the chop animation is playing.
enum State { FREE, WALKING_TO, CHOP_IDLE, CHOPPING, SAW_WALK, SAWING, SLEEPING }

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var body_shape: CollisionShape2D = $CollisionShape2D
@onready var interaction = $Interaction

var state: State = State.FREE
var dragger
var base_offset: Vector2
# Picks and plays his animations (the same CharacterAnimator every colonist uses).
var animator: CharacterAnimator
# The asleep picture (main_character_asleep.png, the "asleep" animation) is shown while he lies on a bed or
# on the ground (not in a house: he is hidden there). Same 16x16 canvas as the standing picture, so only these
# small nudges (on top of his normal offset) are ever needed; the picture is never scaled.
@export var asleep_offset_on_bed: Vector2 = Vector2.ZERO
@export var asleep_offset_on_ground: Vector2 = Vector2.ZERO
@export var asleep_rotation_degrees: float = 0.0
# The House whose room he is in (null: out in the world), whether a fade in or out of it is under way (he
# cannot act then), and the house he is walking to the door of.
var inside_building = null
var transitioning: bool = false
var enter_target = null
var _fade: Node
var _inside_grace: float = 0.0
# How close to the door he must be for E to take him in at once; further away he walks there first.
const ENTER_REACH: float = 22.0
# His hunger (a HungerMeter), and the berries in the basket he holds (held_tool == &"basket"); a dropped basket
# keeps them (see _unhold / _place_item).
var hunger: Node
var basket_berries: int = 0
var _unheld_berries: int = 0
# Debug (F9): stays asleep until he wakes himself with E / a movement key.
var debug_hold_sleep: bool = false
# The tree he is working (chop or delimb), or whose log he is going to take / dragging.
var work_tree = null
var work_kind: StringName = &""
# The pit saw he is digging (work_kind "dig").
var work_pit = null
# The blueprint he is hammering (work_kind "hammer").
var work_building = null
# The grass patch he is pulling (work_kind "pull").
var work_grass = null
# The bed he is working on (breaking it up, or building / taking down the proper bed), and the bed he is
# asleep in (null: on the ground or in a house).
var work_bed = null
# The construction he is dismantling with the hammer (work_kind "dismantle"; see Dismantle).
var work_dismantle = null
var sleep_bed = null
# The bundle in his hands (held_tool == &"bundle"): its age in clock seconds (it counts while carried);
# and the age of the one he has just put down (see _unhold).
var held_bundle_age: float = 0.0
var _unheld_age: float = 0.0
# The opening hint about beds: shown from the first bundle he pulls until a bed has been made.
var first_bundle_pulled: bool = false
var bed_made: bool = false
# THE ONE HELD-ITEM SLOT (character_hands.gd). He holds ONE thing at a time: planks, the saw blade, a tool, a basket, a loaf, ... (a dragged log and a toolbox
# carried with the friend take the hands too). The three variables below are views of that slot, not stores of their own, so two of them can never be set at
# once: taking a second thing while one is held is a bug, reported once (HELD-ITEM) and mended by putting the first down at his feet. Callers put down or
# swap first (swap_on_pickup, _unhold / _place_item).
var hands: CharacterHands = CharacterHands.new("the player")
# Planks in his hands.
var carrying_planks: int:
	get:
		return hands.amount if hands.kind == CharacterHands.PLANK else 0
	set(value):
		if value > 0:
			_slot_take(CharacterHands.PLANK, value)
		elif hands.kind == CharacterHands.PLANK:
			hands.clear()
# A saw blade in his hands.
var carrying_blade: bool:
	get:
		return hands.kind == CharacterHands.BLADE
	set(value):
		if value:
			_slot_take(CharacterHands.BLADE, 1)
		elif hands.kind == CharacterHands.BLADE:
			hands.clear()
# A tool or item in his hands: &"hammer", &"shovel", &"axe", &"basket", ... or &"" for none. Where
# tools are required (see tools_required) hammering needs the hammer, digging the shovel and
# chopping the axe; a tool does not slow him down.
var held_tool: StringName:
	get:
		return hands.kind if hands.kind != CharacterHands.PLANK and hands.kind != CharacterHands.BLADE else &""
	set(value):
		if value != &"":
			_slot_take(value, 1)
		elif hands.kind != CharacterHands.PLANK and hands.kind != CharacterHands.BLADE:
			hands.clear()
# The seeds in the seed bag he holds (held_tool == &"seed_bag"); a bag put down keeps them (see _unhold).
var held_seeds: int = 0
var _unheld_seeds: int = 0
# The scoops of water in the bucket he holds (held_tool == &"bucket"); a bucket put down keeps them.
var held_scoops: int = 0
var _unheld_scoops: int = 0
# The state (flour, water, dough) of the dough board he holds (held_tool == &"dough_board"); a board put down keeps it.
var held_board: Dictionary = {}
var _unheld_board: Dictionary = {}
# Real time (msec) before which he cannot scoop again (one scoop takes bucket_scoop_seconds at normal energy).
var _scoop_ready_at: int = 0
# The same for pouring a scoop (onto a plot or the dough board): bucket_pour_seconds at normal energy.
var _pour_ready_at: int = 0
# How many times he has put something down with Q / right-click (the HUD slot teaches the keys for
# the first few).
var drops_made: int = 0
# The sleep fade and time skip (see sleep_skip.gd): all in real seconds except the speed, which is clock-seconds
# per real second.
@export_group("Sleep skip")
@export var fade_out_seconds: float = 0.5
@export var fade_in_seconds: float = 0.7
# The least speed of the skip; the real speed is max(this, the clock-seconds left to sleep / sleep_skip_target_real_seconds),
# so a whole night takes about sleep_skip_target_real_seconds in the dark.
@export var sleep_skip_speed: float = 30.0
@export var sleep_skip_target_real_seconds: float = 2.0
# After this many real seconds in the dark the speed ramps up so the sleep always ends soon after (the black screen
# never lasts much longer than this).
@export var sleep_skip_max_real_seconds: float = 3.0
# The black screen after he wakes, with "Day N", before the fade in.
@export var sleep_black_hold_seconds: float = 0.1
# No frame may move the clock by more than this many clock-seconds (a dusk or dawn is never skipped over).
@export var sleep_skip_max_clock_step: float = 10.0
# The SFX bus is turned down by this many dB while it is dark (it is never pitched).
@export var sleep_skip_quiet_db: float = -12.0
@export_group("")

# Dead (starved): the game-over screen is up and nothing answers any more.
var dead: bool = false
var _sleep_skip: CanvasLayer
var _game_over: CanvasLayer

# His Rest need (drains awake, recovers asleep; a tired body is slower).
var rest: Node
# The house he sleeps in (null: asleep outdoors), and the clock speed to give back when he wakes.
var sleep_house = null
var _clock_multiplier_before: float = 1.0
var carrying_hammer: bool:
	get:
		return held_tool == &"hammer"
	set(value):
		if value:
			held_tool = &"hammer"
		elif held_tool == &"hammer":
			held_tool = &""
# -1 = he stands on the tree's left (facing right), +1 = on its right (facing left).
var chop_side: float = -1.0
var waypoints: Array[Vector2] = []
var drag_tree = null
var saw_pit = null
# At his sawing spot, waiting for the colonist.
var saw_arrived: bool = false
# Chopping: the last swing finished the job (tree fell / delimbed); an extra press is
# remembered (queue_next_chop); seconds of claim left while standing between swings.
var chop_work_done: bool = false
var chop_queued: bool = false
var claim_left: float = 0.0
# The CarryTogether he is part of (the toolbox lifted with the friend), or null. While it is set he can only walk and put it down.
var carrying_together = null:
	set(value):
		carrying_together = value
		hands.together = value
# True while the player is marking a colonist's tasks on the main view (designation_mode.gd): no other actions then.
var designating: bool = false
# What he did last ({"kind": chop / delimb / hammer / pull / till / sow / water / harvest, "target", "cell", "at": seconds}): an assisting
# colonist copies it (see colonist_order_ai.gd).
var work_log: Dictionary = {"kind": &"", "target": null, "cell": Vector2i.ZERO, "at": -1000.0}

func _note_work(kind: StringName, target = null, cell: Vector2i = Vector2i.ZERO) -> void:
	work_log = {"kind": kind, "target": target, "cell": cell, "at": Time.get_ticks_msec() / 1000.0}

func _ready() -> void:
	add_to_group("player")
	base_offset = sprite.offset
	animator = CharacterAnimator.new(sprite, base_offset)
	animator.config = self
	SleepVisual.ensure(sprite, "res://sprites/main_character_asleep.png")
	dragger = LogDragger.new(self, sprite)
	hands.dragger = dragger
	sprite.frame_changed.connect(_on_frame_changed)
	sprite.animation_finished.connect(_on_animation_finished)
	sprite.play(_idle_anim())
	rest = RestMeter.new()
	# His awake drain: faster while he works (a swing, or sawing), a little faster while he carries.
	rest.activity = func() -> float:
		var clock: Node = _game_clock()
		if clock == null:
			return 1.0
		# Working: mid-swing, standing at the job between swings, or sawing.
		if carrying_together != null and is_instance_valid(carrying_together):
			return carrying_together.drain_multiplier
		if state == State.CHOPPING or state == State.CHOP_IDLE or state == State.SAWING:
			return clock.work_drain_multiplier
		if hands_occupied():
			return clock.carry_drain_multiplier
		return 1.0
	add_child(rest)
	# His hunger: it drains a little faster while he works, and its efficiency is multiplied into the one
	# shared efficiency (RestMeter.efficiency()).
	_fade = ScreenFade.new()
	add_child(_fade)
	_sleep_skip = SleepSkip.new()
	_sleep_skip.player = self
	add_child(_sleep_skip)
	_game_over = GameOver.new()
	add_child(_game_over)
	hunger = HungerMeter.new()
	hunger.who_name = "The player"
	hunger.starved.connect(die.bind("starvation"))
	hunger.rest = rest
	hunger.activity = func() -> float:
		var clock: Node = _game_clock()
		if clock != null and rest.activity.call() >= clock.work_drain_multiplier:
			return clock.hunger_work_multiplier
		return 1.0
	add_child(hunger)
	rest.hunger = hunger
	# A "z" over him while he sleeps outdoors (his rest bar is on the HUD instead).
	var indicator: Node2D = RestIndicator.new()
	indicator.rest = rest
	indicator.hover_bar = false
	indicator.asleep_outdoors = func() -> bool: return state == State.SLEEPING and sleep_house == null
	indicator.awake = func() -> bool: return false
	add_child(indicator)

func is_dragging() -> bool:
	return dragger.is_dragging()

# Free to be given an order with E (not already working or walking somewhere).
func is_free() -> bool:
	return state == State.FREE and not dead

# Walking to, or working at, this tree / pit saw / blueprint (it is the thing his current order is
# about).
func is_working_on(target) -> bool:
	if state != State.WALKING_TO and state != State.CHOP_IDLE and state != State.CHOPPING:
		return false
	return target != null and (target == work_tree or target == work_pit or target == work_building or target == work_grass or target == work_bed or target == work_dismantle)

# Standing at a tree between swings or mid-swing: E / click on a tree still means "chop".
func is_chopping_session() -> bool:
	return state == State.CHOP_IDLE or state == State.CHOPPING

# His animations follow his efficiency: walking, carrying walks and every work swing play slower when he
# is tired (their frame rates are not changed, only the playback speed), and at full speed again the
# moment he is rested or asleep.
func _process(_delta: float) -> void:
	rest.sync_animation(sprite)
	# A bundle in his hands keeps ageing (green, then hay-coloured: only the look).
	if held_tool == &"bundle":
		var clock: Node = _game_clock()
		if clock != null:
			held_bundle_age += clock.clock_delta

func _physics_process(delta: float) -> void:
	if dead:
		velocity = Vector2.ZERO
		return
	if transitioning:
		velocity = Vector2.ZERO
		return
	if state == State.SAWING:
		# (a movement key steps him out of the saw: it stops, the log keeps its progress, and so does the helper's pose)
		if Input.get_vector("move_left", "move_right", "move_up", "move_down") != Vector2.ZERO:
			stop_sawing()
		return
	if state == State.SLEEPING:
		_tick_sleep()
		return
	# get_vector returns a unit-length vector on diagonals, so speed is constant.
	var dir: Vector2 = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	# (While the E chooser is open W / S / the up and down arrows move its selection instead of him.)
	if interaction.chooser_open:
		dir.y = 0.0
	match state:
		State.FREE:
			_move_freely(dir)
		State.WALKING_TO:
			if dir != Vector2.ZERO:
				_cancel_order()
				_move_freely(dir)
			else:
				_auto_walk(delta)
		State.CHOP_IDLE:
			velocity = Vector2.ZERO
			if dir != Vector2.ZERO:
				_cancel_order()
				_move_freely(dir)
			else:
				_tick_claim(delta)
		State.CHOPPING:
			velocity = Vector2.ZERO
			if dir != Vector2.ZERO:
				_cancel_order()
				_move_freely(dir)
		State.SAW_WALK:
			if dir != Vector2.ZERO:
				_cancel_order()
				_move_freely(dir)
			else:
				_auto_walk(delta)
	_clamp_to_map()
	dragger.update()
	# Inside a house, walking into the door area leaves it.
	if inside_building != null and state == State.FREE:
		_inside_grace = maxf(0.0, _inside_grace - delta)
		if _inside_grace <= 0.0 and inside_building.get_interior().in_exit(position):
			request_leave()

# The rectangle items may be put down in: the floor of the room he is in, or the map.
func _items_rect() -> Rect2:
	if inside_building != null:
		return inside_building.get_interior().floor_rect_world()
	return map_rect

func _clamp_to_map() -> void:
	if inside_building != null:
		# In a room the walls keep him on the floor (and the door gap leads out).
		position = inside_building.get_interior().clamp_walk(position)
		return
	var lo: Vector2 = map_rect.position + Vector2(edge_margin, edge_margin * 2.0)
	var hi: Vector2 = map_rect.end - Vector2(edge_margin, 0.0)
	position = position.clamp(lo, hi)

# The walk / idle animation for what he holds: a plank, a saw blade or a tool in his arms has its
# own (dragging a log keeps the normal walk). Chop, dig and hammer play their own animations,
# which show the tool in use in his hand; the carrying one comes back afterwards.
# What he holds, as the shared picker wants it (CharacterAnimator).
func _held_state() -> Dictionary:
	var bundle: String = ""
	if held_tool == &"bundle":
		bundle = "hay" if bundle_is_hay() else "grass"
	return CharacterAnimator.held_state(dragger.is_dragging(), carrying_planks, carrying_blade, bundle, held_tool if held_tool != &"bundle" else &"")

func _walk_anim() -> StringName:
	return CharacterAnimator.walk_name(sprite.sprite_frames, _held_state())

func _idle_anim() -> StringName:
	return CharacterAnimator.idle_name(sprite.sprite_frames, _held_state())

# His speed: what he carries (a log 50%, a plank or the blade 75%, nothing or a tool 100%) times the
# share his tiredness leaves him (100% from rest 40 up, 60% at rest 0).
func _current_speed() -> float:
	var carried: float = speed
	if carrying_together != null and is_instance_valid(carrying_together):
		# Two carry it: slower, and no faster than the friend can follow.
		carried = minf(speed * carrying_together.speed_multiplier, carrying_together.player_speed_limit())
	elif dragger.is_dragging():
		carried = speed * drag_speed_multiplier
	elif carrying_planks > 0 or carrying_blade:
		carried = speed * plank_speed_multiplier
	elif held_tool == &"bundle":
		carried = speed * hay_speed_multiplier
	elif held_tool == &"basket":
		# 100% empty, down to basket_full_speed when full (linear in between).
		var clock: Node = _game_clock()
		var full: float = float(basket_berries) / float(maxi(1, clock.basket_capacity)) if clock != null else 0.0
		carried = speed * lerpf(1.0, clock.basket_full_speed if clock != null else 1.0, clampf(full, 0.0, 1.0))
	return carried * rest.speed_factor() * WaterMap.speed_factor(position)

# He holds one thing at a time: a plank, a saw blade, a tool or a dragged log.
func hands_occupied() -> bool:
	return hands.is_holding()

# For tests: whatever is in his hands is replaced by `kind` (&"" for nothing), planks, or the blade, without putting the old thing down.
func debug_hold(kind: StringName) -> void:
	hands.clear()
	if kind != &"":
		hands.kind = kind
		hands.amount = 1

func debug_hold_planks(count: int) -> void:
	hands.clear()
	if count > 0:
		hands.kind = CharacterHands.PLANK
		hands.amount = count

func debug_hold_blade() -> void:
	hands.clear()
	hands.kind = CharacterHands.BLADE
	hands.amount = 1

# Takes `kind` into the one slot. When the slot already holds something else the caller broke the rule (it should have put that down or swapped first):
# said once, and the old thing goes down at his feet so nothing is held twice, lost or doubled.
func _slot_take(kind: StringName, amount: int) -> void:
	if hands.kind != &"" and hands.kind != kind:
		CharacterHands.report("the player took '%s' while holding '%s'" % [kind, held_item()])
		for i in 3:
			if hands.kind == &"" or hands.kind == kind:
				break
			_place_item(_unhold(), position)
	hands.kind = kind
	hands.amount = amount
	hands.as_tool = false

# While the first pit saw is not built (opening mode) the 2 planks and the blade are kept for
# it: no planks to other blueprints or the Storage.
func supplies_locked() -> bool:
	var root: Node = get_parent()
	return root.has_method("supplies_locked") and root.supplies_locked()

# Only a dragged log keeps his hands busy: planks in his arms do not stop him chopping,
# digging or hammering.
func hands_full() -> bool:
	return dragger.is_dragging()

func _move_freely(dir: Vector2) -> void:
	velocity = dir * _current_speed()
	var before: Vector2 = position
	move_and_slide()
	WaterMap.walked(self, position.distance_to(before))
	if dir != Vector2.ZERO:
		if sprite.animation != _walk_anim():
			sprite.play(_walk_anim())
		if dir.x != 0.0:
			sprite.flip_h = dir.x < 0.0
	elif sprite.animation != _idle_anim():
		sprite.play(_idle_anim())

# Walks himself along `waypoints` (his own movement keys cancel it).
func _auto_walk(delta: float) -> void:
	if state == State.SAW_WALK and saw_arrived:
		velocity = Vector2.ZERO
		return
	if waypoints.is_empty():
		velocity = Vector2.ZERO
		_arrived()
		return
	var target: Vector2 = waypoints[0]
	var to_target: Vector2 = target - position
	if to_target.x != 0.0:
		sprite.flip_h = to_target.x < 0.0
	if sprite.animation != _walk_anim():
		sprite.play(_walk_anim())
	# The route is already worked out round the obstacles, so he follows it directly rather
	# than through the physics (his collision body would catch on the corners it hugs).
	var before_step: Vector2 = position
	position = position.move_toward(target, _current_speed() * delta)
	WaterMap.walked(self, position.distance_to(before_step))
	velocity = Vector2.ZERO
	if position.distance_to(target) < 0.01:
		waypoints.remove_at(0)
		if waypoints.is_empty():
			_arrived()

func _walk_to(point: Vector2, new_state: State) -> void:
	waypoints = Footprints.path_around(Footprints.base_rects(get_tree()), position, point, path_margin)
	state = new_state

func _arrived() -> void:
	match state:
		State.WALKING_TO:
			if work_kind == &"take_log":
				_attach_log_now()
			elif work_kind == &"enter":
				var house = enter_target
				_finish_order()
				if house != null and is_instance_valid(house):
					_enter_sequence(house)
			else:
				_begin_chopping()
		State.SAW_WALK:
			saw_arrived = true
			sprite.play(_idle_anim())
			if saw_pit != null:
				saw_pit.player_arrived_at_spot()

# --- Chopping and delimbing -----------------------------------------------------------

# One swing per E press / click on a tree. Returns "" if accepted (or quietly ignored), or
# a message for the HUD.
func request_chop(tree) -> String:
	var wrong: String = tool_check(&"axe", "chop")
	if wrong != "":
		return wrong
	match state:
		State.FREE:
			if not start_tree_work(tree):
				return "Someone else is working on this tree"
		State.CHOP_IDLE:
			if tree == work_tree:
				_start_swing()
			else:
				# Another tree: let this one go and walk to the new one.
				_cancel_order()
				if not start_tree_work(tree):
					return "Someone else is working on this tree"
		State.CHOPPING:
			# A swing is playing: extra presses do not count, unless one may be queued.
			if queue_next_chop and tree == work_tree and not chop_work_done:
				chop_queued = true
	return ""

# One dig per E press / click on a marked or half-dug pit saw. Returns "" if accepted (or
# quietly ignored), or a message for the HUD.
func request_dig(pit) -> String:
	var wrong: String = tool_check(&"shovel", "dig")
	if wrong != "":
		return wrong
	match state:
		State.FREE:
			start_pit_work(pit)
		State.CHOP_IDLE:
			if pit == work_pit:
				_start_swing()
			else:
				_cancel_order()
				start_pit_work(pit)
		State.CHOPPING:
			if queue_next_chop and pit == work_pit and not chop_work_done:
				chop_queued = true
	return ""

# Tools are required in the opening (the tools are lying about the start): the root scene says.
func tools_required() -> bool:
	var root: Node = get_parent()
	return root.has_method("tools_required") and root.tools_required()

# "" if he may do this work now; otherwise why not. With tools required he must hold the right
# one ("Pick up the axe to chop", or "Put it down and pick up the axe" if his hands hold something
# else). Without tools only a dragged log gets in the way.
func tool_check(tool: StringName, verb: String) -> String:
	if not tools_required():
		return "Press E to drop the log" if hands_full() else ""
	if held_tool == tool:
		return ""
	if hands_occupied():
		return "Put it down and pick up the %s" % tool
	return "Pick up the %s to %s" % [tool, verb]

# One hammer blow per E press / click on a blueprint that has all its planks. Returns "" if
# accepted (or quietly ignored), or a message for the HUD.
func request_hammer(b) -> String:
	var wrong: String = tool_check(&"hammer", "build")
	if wrong != "":
		return wrong
	if not b.is_supplied():
		return "Needs %s" % b.missing_text()
	match state:
		State.FREE:
			if not start_building_work(b):
				return "Someone else is working on this"
		State.CHOP_IDLE:
			if b == work_building:
				_start_swing()
			else:
				_cancel_order()
				if not start_building_work(b):
					return "Someone else is working on this"
		State.CHOPPING:
			if queue_next_chop and b == work_building and not chop_work_done:
				chop_queued = true
	return ""

# One hammer blow per E press / click on a pit saw that is dug and supplied (the same rules as
# a plank blueprint). Returns "" if accepted (or quietly ignored), or a message.
func request_hammer_pit(pit) -> String:
	var wrong: String = tool_check(&"hammer", "build")
	if wrong != "":
		return wrong
	if not pit.ready_to_build():
		return pit.missing_text()
	match state:
		State.FREE:
			start_pit_hammer(pit)
		State.CHOP_IDLE:
			if pit == work_pit and work_kind == &"hammer":
				_start_swing()
			else:
				_cancel_order()
				start_pit_hammer(pit)
		State.CHOPPING:
			if queue_next_chop and pit == work_pit and work_kind == &"hammer" and not chop_work_done:
				chop_queued = true
	return ""

# One pull per E press / click on a tall patch of grass (no tool, but empty hands). Four pulls take it
# up. Returns "" if accepted (or quietly ignored), or a message for the HUD.
func request_pull(patch) -> String:
	if hands_occupied():
		return "Put it down first"
	match state:
		State.FREE:
			if not start_grass_work(patch):
				return "Someone else is pulling this"
		State.CHOP_IDLE:
			if patch == work_grass:
				_start_swing()
			else:
				_cancel_order()
				if not start_grass_work(patch):
					return "Someone else is pulling this"
		State.CHOPPING:
			if queue_next_chop and patch == work_grass and not chop_work_done:
				chop_queued = true
	return ""

# Claims the patch (so nobody else pulls it) and walks to the spot beside it; the first pull happens there.
func start_grass_work(patch) -> bool:
	if not patch.try_claim(self):
		return false
	work_grass = patch
	work_kind = &"pull"
	_note_work(&"pull", patch)
	chop_side = 1.0 if position.x > patch.position.x else -1.0
	_walk_to(Vector2(patch.position.x + chop_side * pull_stand_offset.x, patch.position.y + pull_stand_offset.y), State.WALKING_TO)
	return true

# Walks to the hammering spot beside the pit saw (facing it); the first blow happens there.
func start_pit_hammer(pit) -> void:
	work_pit = pit
	work_kind = &"hammer"
	var spot: Vector2 = pit.hammer_spot_world()
	chop_side = -1.0 if spot.x < pit.global_position.x else 1.0
	_walk_to(spot, State.WALKING_TO)

# Claims the blueprint (so the Builder leaves it alone) and walks to the hammering spot beside it.
func start_building_work(b) -> bool:
	if not b.try_claim(self):
		return false
	work_building = b
	work_kind = &"hammer"
	_note_work(&"hammer", b)
	var spot: Vector2 = b.hammer_spot_world()
	# (In a room the walls keep him on the floor: stand where he can.)
	if inside_building != null:
		spot = inside_building.get_interior().clamp_walk(spot)
	chop_side = -1.0 if spot.x < b.global_position.x else 1.0
	_walk_to(spot, State.WALKING_TO)
	return true

# Walks to the digging spot beside the pit (facing it); the first dig happens there.
func start_pit_work(pit) -> void:
	work_pit = pit
	work_kind = &"dig"
	var spot: Vector2 = pit.dig_spot_world()
	# Stands on whichever side the spot is, facing the pit.
	chop_side = -1.0 if spot.x < pit.global_position.x else 1.0
	_walk_to(spot, State.WALKING_TO)

# Claims the tree and walks to his chopping spot, where the first swing happens.
func start_tree_work(tree) -> bool:
	if not tree.try_claim(self):
		return false
	work_tree = tree
	work_kind = &"chop" if tree.is_standing() else &"delimb"
	_note_work(work_kind, tree)
	# Stands on the side he came from.
	chop_side = 1.0 if position.x > tree.position.x else -1.0
	var offs: Vector2 = fell_stand_offset if tree.is_standing() else delimb_stand_offset
	_walk_to(Vector2(tree.position.x - chop_side * offs.x, tree.position.y + offs.y), State.WALKING_TO)
	return true

func _begin_chopping() -> void:
	velocity = Vector2.ZERO
	_start_swing()

# Plays the chop animation once; its strike frame counts the hit.
func _start_swing() -> void:
	state = State.CHOPPING
	chop_queued = false
	claim_left = claim_hold_time
	sprite.flip_h = chop_side > 0.0
	# (pull, hammer: the walk's canvas, no shift; dig and chop: their 32x32 canvas shifted so the body stands where he does; anything else chops)
	animator.start_work(work_kind if CharacterAnimator.WORK.has(work_kind) else &"chop", sprite.flip_h)

func _on_frame_changed() -> void:
	if state != State.CHOPPING:
		return
	if sprite.animation == &"pull":
		if sprite.frame == PULL_STRIKE_FRAME and work_kind == &"bedbreak" and is_instance_valid(work_bed):
			# Pulling a grass / hay bed apart.
			var bed = work_bed
			var broken: bool = bed.break_hit()
			_report_work(bed, bed.break_presses if broken else bed.progress, bed.break_presses, &"hay", broken)
			if broken:
				chop_work_done = true
		elif sprite.frame == PULL_STRIKE_FRAME and work_kind == &"pick" and is_instance_valid(work_grass):
			# One press, one berry into the basket.
			var bush = work_grass
			if bush.pick_one():
				if held_tool == &"basket":
					basket_berries += 1
				else:
					# By hand: the berry is now the one thing he holds, so this press is the last.
					held_tool = &"berry"
					chop_work_done = true
			var per_bush: int = bush.berries_per_bush
			var emptied: bool = bush.berries <= 0
			_report_work(bush, per_bush - bush.berries, per_bush, &"hay", emptied)
			var clock_now: Node = _game_clock()
			if emptied:
				chop_work_done = true
			if clock_now != null and basket_berries >= clock_now.basket_capacity:
				chop_work_done = true
				interaction.show_message("Your basket is full.")
		elif sprite.frame == PULL_STRIKE_FRAME and is_instance_valid(work_grass):
			var patch = work_grass
			var done: bool = patch.pull_hit()
			_report_work(patch, patch.PULL_HITS if done else patch.pull_progress, patch.PULL_HITS, &"hay", done)
			if done:
				chop_work_done = true
				_give_bundle()
		return
	if sprite.animation == &"hammer":
		if sprite.frame == HAMMER_STRIKE_FRAME and work_kind == &"dismantle" and is_instance_valid(work_dismantle):
			# Taking a construction apart: one press, one hit (checked again each time: someone may have
			# gone to sleep in it, or started to use it).
			var target = work_dismantle
			var why: String = Dismantle.block_reason(get_tree(), target, self)
			if why != "":
				interaction.show_message(why)
				chop_work_done = true
			else:
				var result: Dictionary = Dismantle.hit(get_tree(), target)
				_report_work(target, result["done"], result["total"], &"hammer", result["finished"])
				if result["finished"]:
					chop_work_done = true
					interaction.show_message("Dismantled")
		elif sprite.frame == HAMMER_STRIKE_FRAME and is_instance_valid(work_building):
			var b = work_building
			for i in _take_hits():
				b.hammer_hit()
			_report_work(b, b.build_progress, b.BUILD_HITS, &"hammer", b.state == b.State.BUILT)
			if b.state == b.State.BUILT:
				chop_work_done = true
				b.release_claim(self)
		elif sprite.frame == HAMMER_STRIKE_FRAME and work_pit != null:
			for i in _take_hits():
				work_pit.hammer_hit()
			_report_work(work_pit, work_pit.build_progress, work_pit.PIT_BUILD_HITS, &"hammer", work_pit.is_built())
			if work_pit.is_built():
				chop_work_done = true
		return
	if sprite.animation == &"dig":
		if sprite.frame == DIG_STRIKE_FRAME and work_pit != null:
			for i in _take_hits():
				work_pit.dig()
			_report_work(work_pit, work_pit.dig_count, work_pit.DIG_HITS, &"shovel", not work_pit.can_dig())
			if not work_pit.can_dig():
				chop_work_done = true
		return
	if sprite.animation != &"chop" or sprite.frame != CHOP_STRIKE_FRAME:
		return
	var tree = work_tree
	for i in _take_hits(maxi(1, hits_per_chop)):
		# Stop if this swing already felled / delimbed it (more hits would count on the next stage).
		if (work_kind == &"chop" and not tree.is_standing()) or (work_kind == &"delimb" and tree.is_delimbed()):
			break
		tree.receive_hit()
	if work_kind == &"chop":
		_report_work(tree, tree.FELL_HITS - tree.fell_hits_remaining, tree.FELL_HITS, &"axe", not tree.is_standing())
	else:
		_report_work(tree, tree.DELIMB_HITS - tree.delimb_hits_remaining, tree.DELIMB_HITS, &"axe", tree.is_delimbed())
	# The tree falls after the felling hits (E on it starts delimbing); a delimbed tree is done.
	# The swing plays out, then he stands free of the tree.
	if (work_kind == &"chop" and not tree.is_standing()) or (work_kind == &"delimb" and tree.is_delimbed()):
		chop_work_done = true
		tree.release_claim(self)

# One press of work is always one full hit (a job needs the same number of presses at any rest). Being
# tired makes each swing / dig / hammer animation take longer instead (see RestMeter.sync_animation).
func _take_hits(per_press: int = 1) -> int:
	return per_press

# A press landed on `target`: the world progress bar above it shows it (only the player's own work).
func _report_work(target, done: int, total: int, tool: StringName, finished: bool) -> void:
	var progress = get_tree().get_first_node_in_group("work_progress")
	if progress != null:
		progress.report_hit(target, done, total, tool, finished)
	# What he sees and hears for the hit (the bars are off by default).
	WorkFeedback.hit(get_tree(), work_kind, target, done, total, finished)
	_note_work(work_kind, target)

func _on_animation_finished() -> void:
	if state != State.CHOPPING or (sprite.animation != &"chop" and sprite.animation != &"dig" and sprite.animation != &"hammer" and sprite.animation != &"pull"):
		return
	if chop_work_done:
		_finish_order()
	elif chop_queued:
		_start_swing()
	else:
		# Back to idle, still in his chopping spot and facing the trunk.
		state = State.CHOP_IDLE
		claim_left = claim_hold_time
		sprite.offset = base_offset
		sprite.play(_idle_anim())

# He lets the tree go and is free for something else.
func end_chop_session() -> void:
	_cancel_order()

# Between swings: keep the claim only while he is close and has chopped recently.
func _tick_claim(delta: float) -> void:
	claim_left -= delta
	var target: Vector2 = Vector2.INF
	if work_tree != null:
		target = work_tree.position
	elif work_pit != null:
		target = work_pit.interact_point()
	elif work_building != null and is_instance_valid(work_building):
		target = work_building.interact_point()
	elif work_grass != null and is_instance_valid(work_grass):
		target = work_grass.interact_point()
	elif work_bed != null and is_instance_valid(work_bed):
		target = work_bed.interact_point()
	elif work_dismantle != null and is_instance_valid(work_dismantle):
		target = work_dismantle.interact_point()
	var too_far: bool = target == Vector2.INF or position.distance_to(target) > interaction.interaction_radius
	if claim_left <= 0.0 or too_far:
		_finish_order()

# Stops whatever he was ordered to do; hits already made stay on the tree.
func _cancel_order() -> void:
	if saw_pit != null:
		saw_pit.cancel_request()
		saw_pit = null
	if work_kind == &"take_log" and work_tree != null:
		# He had not picked the log up yet: give the claim back.
		work_tree.return_log(work_tree.log_node())
	_finish_order()

func _finish_order() -> void:
	if work_tree != null and work_kind != &"take_log":
		work_tree.release_claim(self)
	if work_building != null and is_instance_valid(work_building):
		work_building.release_claim(self)
	if work_grass != null and is_instance_valid(work_grass):
		work_grass.release_claim(self)
	if work_bed != null and is_instance_valid(work_bed):
		work_bed.release_claim(self)
	if work_dismantle != null:
		Dismantle.release_claim(work_dismantle, self)
	work_dismantle = null
	work_bed = null
	enter_target = null
	work_tree = null
	work_pit = null
	work_building = null
	work_grass = null
	work_kind = &""
	chop_work_done = false
	chop_queued = false
	waypoints.clear()
	sprite.offset = base_offset
	state = State.FREE
	sprite.play(_idle_anim())

# --- Dragging logs --------------------------------------------------------------------

# E on a ready log: walk up to its nearest end, then tie on and drag.
func start_take_log(tree) -> bool:
	var trunk = tree.claim_log(self)
	if trunk == null:
		return false
	work_tree = tree
	work_kind = &"take_log"
	_walk_to(dragger.pickup_point(trunk, log_pickup_offset), State.WALKING_TO)
	return true

func _attach_log_now() -> void:
	var tree = work_tree
	var trunk: Sprite2D = tree.log_node()
	work_tree = null
	work_kind = &""
	state = State.FREE
	if trunk == null:
		return
	dragger.attach(trunk)
	drag_tree = tree
	# Faces away from the log, so it trails behind him.
	sprite.flip_h = dragger.pickup_away < 0.0
	sprite.play(_idle_anim())

# E away from the pit saw: put the log down where it is and let the Hauler have it again.
func drop_log() -> void:
	if not dragger.is_dragging():
		return
	var trunk: Sprite2D = dragger.drop()
	if drag_tree != null:
		drag_tree.return_log(trunk)
	drag_tree = null

# E at a Storage with a log: it goes into the stock.
func store_log_in(storage) -> bool:
	if not dragger.is_dragging() or not storage.add_log():
		return false
	dragger.release()
	if drag_tree != null:
		drag_tree.finish_log()
	drag_tree = null
	return true

# --- Carrying planks --------------------------------------------------------------------
# One plank at a time (carry_capacity).

func can_take_plank() -> bool:
	return carrying_planks < carry_capacity and (carrying_planks > 0 or swap_on_pickup or not hands_occupied())

# E at a pile on the ground, the Sawmill's output or a Storage: takes one plank. A pile's
# planks that the Hauler has claimed are not available.
func take_plank_from(src) -> bool:
	if not can_take_plank():
		return false
	var got: bool = false
	if src.has_method("take_free"):
		got = src.take_free()
	elif "planks_stored" in src:
		got = src.take_planks(1) > 0
	elif src.planks_ready > 0:
		src.planks_ready -= 1
		got = true
	if got:
		# His hands were full of something else (swap_on_pickup): that goes down at his feet.
		var old: StringName = &"" if carrying_planks > 0 else _unhold()
		carrying_planks += 1
		_place_item(old, position)
		AudioManager.play("pickup", position)
	return got

# E at a blueprint that still needs planks: delivers the plank (the "3 / 8" label goes up by one).
func deliver_plank(b) -> bool:
	if carrying_planks <= 0 or b.planks_needed() <= 0 or supplies_locked():
		return false
	b.planks_ready += 1
	carrying_planks -= 1
	AudioManager.play("plank_drop", position)
	return true

# E at a Storage: stores the plank (planks_stored goes up by one).
func store_plank(st) -> bool:
	if carrying_planks <= 0 or supplies_locked() or st.add_planks(1) < 1:
		return false
	carrying_planks -= 1
	AudioManager.play("plank_drop", position)
	return true

# E at a pile with fewer than 3 planks: adds the plank to it.
func add_plank_to_pile(pile) -> bool:
	if carrying_planks <= 0 or not pile.add_plank():
		return false
	carrying_planks -= 1
	AudioManager.play("plank_drop", position)
	return true

# Where a put-down item goes: at the mouse (`mouse_world`, null for Q) when that is within drop_reach
# of him and the spot is free, otherwise in front of him. A plank also counts the mouse spot as
# good when a pile with room is near it (the plank joins that pile).
func _drop_near(mouse_world, item: StringName = &"") -> Vector2:
	var dir: float = -1.0 if sprite.flip_h else 1.0
	var front: Vector2 = position + Vector2(14.0 * dir, 0.0)
	if mouse_world is Vector2 and position.distance_to(mouse_world) <= drop_reach:
		if item == &"plank" and PlankPiles.nearest_open_pile(get_tree(), mouse_world, pile_merge_radius) != null:
			return mouse_world
		if item == &"bundle" and PlankPiles.nearest_open_bundle_pile(get_tree(), mouse_world, pile_merge_radius) != null:
			return mouse_world
		if PlankPiles.is_free(get_tree(), mouse_world, _items_rect()):
			return mouse_world
	return front

# What he holds as a name: &"plank", &"blade", &"hammer", &"shovel", &"axe", &"log" or &"".
func held_item() -> StringName:
	if dragger.is_dragging():
		return &"log"
	if carrying_planks > 0:
		return &"plank"
	if carrying_blade:
		return &"blade"
	return held_tool

# Takes what he holds out of his hands and says what it was. A log stays lying where it trailed
# (the Hauler may have it again); everything else must be put on the ground with _place_item.
func _unhold() -> StringName:
	if dragger.is_dragging():
		drop_log()
		return &"log"
	if carrying_planks > 0:
		carrying_planks -= 1
		return &"plank"
	if carrying_blade:
		carrying_blade = false
		return &"blade"
	var tool: StringName = held_tool
	if tool == &"bundle":
		_unheld_age = held_bundle_age
	if tool == &"basket":
		_unheld_berries = basket_berries
		basket_berries = 0
	if tool == &"seed_bag":
		_unheld_seeds = held_seeds
		held_seeds = 0
	if tool == &"bucket":
		_unheld_scoops = held_scoops
		held_scoops = 0
	if tool == &"dough_board":
		_unheld_board = held_board
		held_board = {}
	held_tool = &""
	return tool

# Puts an item that was in his hands on the ground at/near `near`: a plank joins the nearest pile
# with room within pile_merge_radius, anything else goes on the nearest free ground (never inside
# a building, tree or other solid, nor on another item); last resort at his feet. Nothing is lost.
func _place_item(item: StringName, near: Vector2) -> void:
	match item:
		&"", &"log", &"berry":
			# (A berry that is put down or swapped out just disappears: berries live on bushes, in baskets, or as the
			# one in his hand.)
			return
		&"plank":
			PlankPiles.put_plank(get_tree(), get_parent(), near, pile_merge_radius, _items_rect(), position)
		&"bundle":
			PlankPiles.put_bundle(get_tree(), get_parent(), near, pile_merge_radius, _items_rect(), position, _unheld_age)
		&"blade":
			PlankPiles.spawn_blade(get_parent(), PlankPiles.free_spot(get_tree(), near, _items_rect(), position))
		&"basket":
			var dropped: Node2D = (load("res://scenes/Basket.tscn") as PackedScene).instantiate()
			dropped.position = PlankPiles.free_spot(get_tree(), near, _items_rect(), position)
			dropped.berries = _unheld_berries
			get_parent().add_child(dropped)
		&"dough_board":
			Items.spawn_board(get_parent(), PlankPiles.free_spot(get_tree(), near, _items_rect(), position), _unheld_board)
			AudioManager.play("board_set", near)
		_:
			if Items.is_item(item):
				# An item of the food chain (or a new tool); a seed bag keeps its seeds.
				Items.spawn(item, get_parent(), PlankPiles.free_spot(get_tree(), near, _items_rect(), position), _unheld_seeds if item == &"seed_bag" else (_unheld_scoops if item == &"bucket" else 0))
			else:
				PlankPiles.spawn_tool(item, get_parent(), PlankPiles.free_spot(get_tree(), near, _items_rect(), position))

# Q / right-click: puts down whatever he holds (the log stays where it trails). Not while sawing,
# nor a tool in the middle of a swing. Returns whether anything was put down.
func drop_held(mouse_world = null) -> bool:
	if state == State.SAWING or (held_tool != &"" and state == State.CHOPPING):
		return false
	var item: StringName = _unhold()
	if item == &"":
		return false
	_place_item(item, _drop_near(mouse_world, item))
	drops_made += 1
	AudioManager.play("plank_drop" if item == &"plank" else "drop", position, 1.0, -9.0 if item == &"berry" else 0.0)
	return true

# He took something new (swap_on_pickup): whatever else he held goes down at his feet.
func put_down_for_swap() -> void:
	_place_item(_unhold(), position)

# --- Going in and out of a house ------------------------------------------------------------------------------

# E / click on a house: in at once when he is at the door, else he walks to the door first. Returns "" or a
# message.
func request_enter(house) -> String:
	if transitioning or inside_building != null or state == State.SLEEPING or state == State.SAWING:
		return ""
	if carrying_together != null:
		return "Put the toolbox down first."
	if dragger.is_dragging():
		return "It is too big to carry inside."
	if position.distance_to(house.door_position()) <= ENTER_REACH:
		_enter_sequence(house)
		return ""
	if state == State.FREE or state == State.CHOP_IDLE:
		if state != State.FREE:
			_cancel_order()
		enter_target = house
		work_kind = &"enter"
		_walk_to(house.door_position(), State.WALKING_TO)
	return ""

# Fade out, appear at the room's door with the camera on the room, fade in. He keeps what he holds.
func _enter_sequence(house) -> void:
	if transitioning or inside_building != null:
		return
	transitioning = true
	velocity = Vector2.ZERO
	waypoints.clear()
	for b in get_tree().get_nodes_in_group("build_mode"):
		b._set_active(false)
	await _fade.fade_out(0.3)
	var room: Node2D = house.get_interior()
	inside_building = house
	position = room.door_world()
	_inside_grace = 0.8
	var camera: Node = get_parent().get_node_or_null("Camera2D")
	if camera != null:
		camera.fixed_position = room.camera_position()
	room.player_entered()
	AudioManager.play("door", position)
	await _fade.fade_in(0.3)
	transitioning = false

func request_leave() -> String:
	if inside_building == null or transitioning or state != State.FREE:
		return ""
	_leave_sequence()
	return ""

# Fade out, appear at the exterior door, the camera back on him, fade in.
func _leave_sequence() -> void:
	transitioning = true
	velocity = Vector2.ZERO
	await _fade.fade_out(0.3)
	var house = inside_building
	if house != null and is_instance_valid(house):
		house.get_interior().player_left()
		position = house.door_position() + Vector2(0, 3)
	inside_building = null
	var camera: Node = get_parent().get_node_or_null("Camera2D")
	if camera != null:
		camera.fixed_position = Vector2.INF
		camera.global_position = (global_position + camera.target_offset).round()
	AudioManager.play("door", position)
	await _fade.fade_in(0.3)
	transitioning = false

# --- Dying ----------------------------------------------------------------------------------------------------

# Called by his hunger meter when he starves (the one death check, which runs whatever he is doing: awake, asleep,
# inside a building, eating, carrying, fast forward, during the sleep fade). Any sleep fade is cut at once, the clock
# and the fast forward are given back, he lies where he is, and the game-over screen comes up.
func die(cause: String = "starvation") -> void:
	if dead:
		return
	dead = true
	_sleep_skip.abort_now()
	var clock: Node = _game_clock()
	if state == State.SLEEPING and clock != null:
		clock.clock_speed_multiplier = _clock_multiplier_before
	if dragger.is_dragging():
		drop_log()
	velocity = Vector2.ZERO
	waypoints.clear()
	rest.stop_sleep()
	_show_asleep()
	visible = true
	var fast: Node = get_node_or_null("/root/FastForward")
	if fast != null:
		fast.warning("death")
	var title: String = "You starved." if cause == "starvation" else "You died."
	_game_over.show_over(title, maxi(0, clock.day - 1), clock.day)

# --- Sleeping --------------------------------------------------------------------------------------

func _game_clock() -> Node:
	return get_tree().get_first_node_in_group("game_clock")

# Why he cannot go to sleep now ("" = he can): his hands must be empty and he must be tired.
func _sleep_block() -> String:
	if hands_occupied():
		return "Put it down first"
	if rest.is_not_tired():
		return "You're not tired"
	return ""

# Z: sleeps where he stands, on the ground. Returns "" or a message.
func request_sleep_outside() -> String:
	if state != State.FREE:
		return ""
	var why: String = _sleep_block()
	if why != "":
		return why
	sleep_house = null
	sleep_bed = null
	if inside_building != null:
		# On the floor of a room: the floor recovery (a little energy comes back).
		_begin_sleep(_game_clock().sleep_rate_for_bed(0), "You sleep on the floor - you recover a little")
		return ""
	_begin_sleep(_game_clock().sleep_rate_outdoors(), "You sleep outdoors - this won't restore your energy.")
	return ""

# E at a bed with empty hands: he sleeps in it (outdoors too), at the bed's quality. One sleeper per bed.
func request_sleep_on(bed) -> String:
	if state != State.FREE:
		return ""
	if (bed.sleeper != null and bed.sleeper != self) or (bed.reserved_by != null and bed.reserved_by != self):
		return "Someone is sleeping there."
	var why: String = _sleep_block()
	if why != "":
		return why
	sleep_house = null
	sleep_bed = bed
	bed.sleeper = self
	position = bed.sleep_spot_world()
	_begin_sleep(bed.sleep_rate_now(), bed.sleep_message())
	return ""

func _begin_sleep(rate: float, message: String) -> void:
	state = State.SLEEPING
	velocity = Vector2.ZERO
	waypoints.clear()
	_show_asleep()
	rest.start_sleep(rate)
	AudioManager.play("sleep_on", position)
	# Say where he sleeps (once per sleep): the floor and the ground restore nothing.
	interaction.show_message(message)
	# The screen fades to black and the clock runs fast while it is dark (see sleep_skip.gd).
	var clock: Node = _game_clock()
	_clock_multiplier_before = clock.clock_speed_multiplier
	_sleep_skip.begin()

# Asleep: he wakes when his rest is full, or at dawn once it is at least 60, or on any movement key
# (E wakes him too, see Interaction).
func _tick_sleep() -> void:
	velocity = Vector2.ZERO
	if Input.get_vector("move_left", "move_right", "move_up", "move_down") != Vector2.ZERO:
		wake_up(true)
		return
	if debug_hold_sleep:
		return
	var clock: Node = _game_clock()
	# Too hungry to go on sleeping.
	if hunger.value < clock.auto_wake_hunger:
		wake_up(false, "You woke up starving.")
		return
	# Full rest wakes him only where rest can rise (a bed). At dawn he wakes once rested enough, or
	# at once where sleeping cannot restore anything.
	var recovers: bool = rest.sleep_recovers()
	if recovers and rest.is_full():
		wake_up()
	elif clock.is_daytime() and (not recovers or rest.value >= clock.player_dawn_wake_rest):
		wake_up()

# The asleep picture (see SleepVisual): one shared function for every sleeper.
func _show_asleep() -> void:
	SleepVisual.set_asleep(sprite, true, asleep_offset_on_bed if sleep_bed != null else asleep_offset_on_ground, asleep_rotation_degrees)

func _clear_asleep_look() -> void:
	SleepVisual.set_asleep(sprite, false)

# `cancelled`: he woke because he wanted to (a key, E, a click); otherwise the sleep ended by itself (`note` says why when
# it matters).
func wake_up(cancelled: bool = false, note: String = "") -> void:
	if state != State.SLEEPING:
		return
	_sleep_skip.on_woke(cancelled, note)
	debug_hold_sleep = false
	_clear_asleep_look()
	rest.stop_sleep()
	AudioManager.play("wake", position)
	var clock: Node = _game_clock()
	if clock != null:
		clock.clock_speed_multiplier = _clock_multiplier_before
	if sleep_house != null and is_instance_valid(sleep_house):
		# Out at the door.
		position = sleep_house.door_position()
	if sleep_bed != null and is_instance_valid(sleep_bed):
		sleep_bed.sleeper = null
	sleep_bed = null
	sleep_house = null
	visible = true
	body_shape.set_deferred("disabled", false)
	state = State.FREE
	sprite.play(_idle_anim())

func _unhandled_input(event: InputEvent) -> void:
	if dead:
		return
	# Carrying the toolbox with the friend: nothing but walking and putting it down (the CarryTogether takes E and the click).
	if carrying_together != null or designating:
		return
	# Debug aids: F5 puts a grass bed (F6 a proper bed) on the floor of the room he is in, or else beside the nearest
	# finished house outdoors; F7 makes every bundle and bed hay-old at once (to see the colour change).
	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and (event.keycode == KEY_F5 or event.keycode == KEY_F6):
		if inside_building != null:
			var room_bed: Node2D = (load("res://scenes/WoodenBed.tscn" if event.keycode == KEY_F6 else "res://scenes/Bed.tscn") as PackedScene).instantiate()
			var room: Node2D = inside_building.get_interior()
			room_bed.position = PlankPiles.free_spot(get_tree(), position + Vector2(30, 0), room.floor_rect_world(), position + Vector2(30, 0))
			if event.keycode == KEY_F6:
				room_bed.ages.assign([0.0, 0.0, 0.0])
			get_parent().add_child(room_bed)
			interaction.show_message("Debug: a %s in the room" % ("wooden bed with 3 bedding" if event.keycode == KEY_F6 else "grass bed"))
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F6:
			interaction.show_message("Debug: a wooden bed only works inside a house")
			get_viewport().set_input_as_handled()
			return
		var nearest = null
		var best: float = INF
		for house in get_tree().get_nodes_in_group("buildings"):
			if house.state == house.State.BUILT and house.capacity > 0 and position.distance_to(house.global_position) < best:
				best = position.distance_to(house.global_position)
				nearest = house
		if nearest != null:
			var bed: Node2D = (load("res://scenes/Bed.tscn") as PackedScene).instantiate()
			var door: Vector2 = nearest.door_position()
			bed.position = (door + Vector2(30, 14)).round()
			for ring in [26.0, 34.0, 42.0]:
				var found: bool = false
				for k in 12:
					var spot: Vector2 = door + Vector2.from_angle(k * TAU / 12.0) * ring
					if PlankPiles.is_free(get_tree(), spot, map_rect):
						bed.position = spot.round()
						found = true
						break
				if found:
					break
			get_parent().add_child(bed)
			interaction.show_message("Debug: a grass bed beside %s" % nearest.name)
		else:
			interaction.show_message("Debug: no finished house")
		get_viewport().set_input_as_handled()
		return
	# Debug aids: F9 puts him to sleep on the ground wherever he stands (and keeps him asleep until a movement
	# key, E or F9 again), F10 does the same to the nearest colonist (F10 again wakes him).
	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and event.keycode == KEY_F9:
		get_viewport().set_input_as_handled()
		if state == State.SLEEPING:
			wake_up(true)
		elif state == State.FREE:
			debug_hold_sleep = true
			sleep_house = null
			sleep_bed = null
			_begin_sleep(_game_clock().sleep_rate_outdoors(), "Debug: asleep where he stands")
		return
	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and event.keycode == KEY_F10:
		get_viewport().set_input_as_handled()
		var nearest_colonist = null
		var nearest_distance: float = INF
		for c in get_tree().get_nodes_in_group("colonists"):
			if position.distance_to(c.position) < nearest_distance:
				nearest_distance = position.distance_to(c.position)
				nearest_colonist = c
		if nearest_colonist != null:
			nearest_colonist.debug_sleep_toggle()
		return
	# Debug aids: F11 goes into the nearest house or storage from anywhere, F12 comes out.
	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and event.keycode == KEY_F11:
		get_viewport().set_input_as_handled()
		var nearest_house = null
		var nearest_door: float = INF
		var enterable: Array = []
		for h in get_tree().get_nodes_in_group("buildings"):
			if h.state == h.State.BUILT and h.capacity > 0:
				enterable.append(h)
		enterable.append_array(get_tree().get_nodes_in_group("storages"))
		for h in enterable:
			if position.distance_to(h.global_position) < nearest_door:
				nearest_door = position.distance_to(h.global_position)
				nearest_house = h
		if nearest_house != null and state == State.FREE:
			_enter_sequence(nearest_house)
		return
	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and event.keycode == KEY_F12:
		get_viewport().set_input_as_handled()
		request_leave()
		return
	# Debug aids: Ctrl+F11 fills the bucket he holds; Ctrl+F12 waters every plot within 100 px.
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed and event.keycode == KEY_F11:
		get_viewport().set_input_as_handled()
		interaction.show_message("Debug: the bucket is full" if fill_bucket() else "Debug: hold a bucket first")
		return
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed and event.keycode == KEY_F12:
		get_viewport().set_input_as_handled()
		interaction.show_message("Debug: %d plot(s) watered" % plot_manager().water_near(position, 100.0))
		return
	# Debug aids: Ctrl+F6 starves (hunger 0) the nearest worker or colonist, Ctrl+F8 sets the nearest worker hunger to 30.
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed and (event.keycode == KEY_F6 or event.keycode == KEY_F8):
		get_viewport().set_input_as_handled()
		var want_worker: bool = event.keycode == KEY_F8
		var who = null
		var who_distance: float = INF
		for node in get_tree().get_nodes_in_group("eaters"):
			if want_worker and node.is_in_group("colonists"):
				continue
			if node.has_meta(&"worker_rest") and node.get_meta(&"worker_rest").is_dead():
				continue
			var d: float = position.distance_to(node.position)
			if d < who_distance:
				who_distance = d
				who = node
		if who == null:
			interaction.show_message("Debug: nobody to starve")
		else:
			var meter: Node = who.get_meta(&"eat_trip").hunger
			meter.value = 30.0 if want_worker else 0.0
			interaction.show_message("Debug: %s hunger set to %.0f" % [who.name, meter.value])
		return
	# Debug aid: F8 dismantles the nearest construction at once (no hits, no blocks), to test the refunds.
	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and event.keycode == KEY_F8:
		var target = null
		var best_distance: float = INF
		for node in Dismantle.all(get_tree()):
			var d: float = position.distance_to(node.global_position)
			if d < best_distance:
				best_distance = d
				target = node
		if target != null:
			var refund: Dictionary = Dismantle.refund(get_tree(), target)
			interaction.show_message("Debug: dismantled %s (%d planks, %d blades)" % [target.name, refund["planks"], refund["blades"]])
			Dismantle.finish(get_tree(), target)
		else:
			interaction.show_message("Debug: nothing to dismantle")
		get_viewport().set_input_as_handled()
		return
	# Debug aid: Ctrl+F9 ripens every plot within 100 px of him; Ctrl+F10 puts one of each food-chain item and tool at his feet.
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed and event.keycode == KEY_F9:
		get_viewport().set_input_as_handled()
		interaction.show_message("Debug: %d plot(s) ripened" % plot_manager().ripen_near(position, 100.0))
		return
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed and event.keycode == KEY_F10:
		get_viewport().set_input_as_handled()
		var i: int = 0
		for kind in [&"seed_bag", &"wheat_sheaf", &"flour", &"flatbread", &"flat_stone", &"branch", &"hoe", &"sickle", &"fire_starter", &"bucket", &"dough"]:
			var at: Vector2 = position + Vector2(-32.0 + i * 8.0, 8.0 + (i % 2) * 8.0)
			Items.put(get_tree(), get_parent(), kind, at, _items_rect(), FoodConfig.cfg().seed_bag_capacity if kind == &"seed_bag" else (FoodConfig.cfg().bucket_capacity if kind == &"bucket" else 0))
			i += 1
		interaction.show_message("Debug: items and tools at your feet")
		return
	# Debug aid: Ctrl+F7 fills the nearest crate (half flatbread, the rest berries).
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed and event.keycode == KEY_F7:
		get_viewport().set_input_as_handled()
		var nearest_crate = null
		var crate_distance: float = INF
		for crate in get_tree().get_nodes_in_group("crates"):
			if position.distance_to(crate.global_position) < crate_distance:
				crate_distance = position.distance_to(crate.global_position)
				nearest_crate = crate
		if nearest_crate != null:
			nearest_crate.add_item(&"flatbread", nearest_crate.room_left() / 2)
			nearest_crate.add_item(&"berry", nearest_crate.room_left())
			interaction.show_message("Debug: the crate is full of flatbread and berries (%s)" % nearest_crate.readout())
		else:
			interaction.show_message("Debug: no crate")
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
		held_bundle_age = maxf(held_bundle_age, _game_clock().bundle_to_hay_clock_seconds)
		for node in get_tree().get_nodes_in_group("bundle_piles") + get_tree().get_nodes_in_group("beds"):
			if node.has_method("age_to_hay"):
				node.age_to_hay()
		interaction.show_message("Debug: every bundle is hay-old")
		get_viewport().set_input_as_handled()
		return
	# Debug aids: F3 sets his rest to 0, F4 to 100; with Ctrl, his hunger instead (Ctrl+F3 5, Ctrl+F4 100,
	# Ctrl+F5 exactly 0).
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed and event.keycode == KEY_F5:
		hunger.value = 0.0
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and (event.keycode == KEY_F3 or event.keycode == KEY_F4):
		if event.ctrl_pressed:
			hunger.value = 5.0 if event.keycode == KEY_F3 else 100.0
		else:
			rest.value = 0.0 if event.keycode == KEY_F3 else 100.0
		get_viewport().set_input_as_handled()
		return
	# Z puts him to sleep where he stands (E at a house's door sleeps indoors).
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_Z:
		get_viewport().set_input_as_handled()
		var why: String = request_sleep_outside()
		if why != "":
			interaction.show_message(why)
		return
	# Q (the "drop" action in the Input Map), once per press. With the mouse over the toolbox it puts the item in the box instead.
	if event.is_action_pressed("drop") and not event.is_echo():
		if hands_occupied():
			get_viewport().set_input_as_handled()
			if put_in_toolbox_at(get_global_mouse_position()):
				return
			drop_held()
	# Right-click puts it down at the mouse (into the toolbox when the click is on it); in build mode it cancels build mode instead.
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		for b in get_tree().get_nodes_in_group("build_mode"):
			if b.active:
				return
		if hands_occupied():
			get_viewport().set_input_as_handled()
			var at: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * event.position
			if put_in_toolbox_at(at):
				return
			drop_held(at)

# The toolbox under this world point (not one being carried), or null.
func toolbox_at(world: Vector2) -> Node2D:
	var HoverNames = load("res://scripts/hover_names.gd")
	for box in get_tree().get_nodes_in_group("toolboxes"):
		if box.is_carried() or box.is_queued_for_deletion():
			continue
		if HoverNames.rect_of(box).grow(1.0).has_point(world):
			return box
	return null

# Right-click / the drop key on the toolbox: the held item goes straight in without opening the panel ("Put away." and a soft lid
# sound); an item it does not take is refused and stays in the hands. Returns true when the click was on the toolbox (handled).
func put_in_toolbox_at(world: Vector2) -> bool:
	var box: Node2D = toolbox_at(world)
	if box == null:
		return false
	var msg: String = "Too far away"
	if position.distance_to(box.interact_point()) <= interaction.interaction_radius * 1.5:
		msg = toolbox_put(box)
		if msg == "Put away.":
			AudioManager.play("toolbox_close", box.global_position, 1.0, -9.0)
	interaction.show_message(msg)
	return true

# --- Saw blade ----------------------------------------------------------------------------

# E at a blade on the ground: picks it up. With his hands full it is a swap (swap_on_pickup) or a
# refusal. Returns "" or a message.
func take_blade(blade) -> String:
	if hands_occupied() and not swap_on_pickup:
		return "Your hands are full"
	blade.remove_from_group("saw_blades")
	blade.queue_free()
	var old: StringName = _unhold()
	carrying_blade = true
	_place_item(old, position)
	AudioManager.play("pickup", position)
	return ""

# --- Bundles and beds -------------------------------------------------------------------------------

# Is the bundle in his hands hay-coloured by now (age past bundle_to_hay_clock_seconds)? Only a look.
func bundle_is_hay() -> bool:
	var clock: Node = _game_clock()
	return held_tool == &"bundle" and clock != null and held_bundle_age >= clock.bundle_to_hay_clock_seconds

# A pulled patch gives one new (age 0) bundle: into his empty hands, otherwise down at his feet.
func _give_bundle() -> void:
	first_bundle_pulled = true
	if not hands_occupied():
		held_tool = &"bundle"
		held_bundle_age = 0.0
	else:
		PlankPiles.put_bundle(get_tree(), get_parent(), position, pile_merge_radius, _items_rect(), position, 0.0)

# E at a pile of bundles: takes one out (keeping its age). With his hands full it is a swap
# (swap_on_pickup) or a refusal.
func take_bundle_from(pile) -> String:
	if hands_occupied() and not swap_on_pickup:
		return "Your hands are full"
	var age: float = pile.take_bundle()
	if age < 0.0:
		return ""
	var old: StringName = _unhold()
	held_tool = &"bundle"
	held_bundle_age = age
	_place_item(old, position)
	AudioManager.play("pickup", position)
	return ""

# E at a pile of bundles with a bundle in hand: it joins the pile (the third one makes a bed).
func add_bundle_to_pile(pile) -> String:
	if held_tool != &"bundle":
		return ""
	var age: float = held_bundle_age
	held_tool = &""
	if not pile.add_bundle(age):
		held_tool = &"bundle"
		return "The pile is full"
	return ""

# A press on a grass / hay bed with empty hands: two presses break it into its bundles.
func request_bed_break(bed) -> String:
	if hands_occupied():
		return "Put it down first"
	if bed.sleeper != null:
		return "Someone is sleeping there."
	if bed.is_wooden():
		return "Only the hammer takes a wooden bed down (Shift+E)"
	match state:
		State.FREE:
			if not start_bed_work(bed, &"bedbreak"):
				return "Someone else is working on this"
		State.CHOP_IDLE:
			if bed == work_bed and work_kind == &"bedbreak":
				_start_swing()
			else:
				_cancel_order()
				if not start_bed_work(bed, &"bedbreak"):
					return "Someone else is working on this"
		State.CHOPPING:
			if queue_next_chop and bed == work_bed and not chop_work_done:
				chop_queued = true
	return ""

# Claims the bed and walks to the spot beside it (facing it); the first hit happens there.
func start_bed_work(bed, kind: StringName) -> bool:
	if not bed.try_claim(self):
		return false
	work_bed = bed
	work_kind = kind
	chop_side = 1.0 if position.x > bed.position.x else -1.0
	var spot := Vector2(bed.position.x + chop_side * 16.0, bed.position.y + 3.0)
	# (In a room the walls keep him on the floor: stand where he can.)
	if bed.interior_node() != null:
		spot = bed.interior_node().clamp_walk(spot)
	_walk_to(spot, State.WALKING_TO)
	return true

# A bundle in hand is laid on a wooden bed (E or a click): one at a time, up to its limit.
func add_bedding_to(bed) -> String:
	if held_tool != &"bundle":
		return ""
	if bed.sleeper != null or bed.reserved_by != null:
		return "Someone is sleeping there."
	if not bed.can_edit_bedding(self):
		return "Someone else is working on this"
	if bed.bedding_full():
		return "The bed is full."
	bed.add_bedding(held_bundle_age)
	held_tool = &""
	AudioManager.play("drop", position)
	WorkFx.rustle(get_tree(), bed.centre_world())
	return ""

# Shift+E with empty hands: the newest bundle of bedding comes off into his hand.
func remove_bedding_from(bed) -> String:
	if hands_occupied():
		return "Your hands are full."
	if bed.sleeper != null or bed.reserved_by != null:
		return "Someone is sleeping there."
	if not bed.can_edit_bedding(self):
		return "Someone else is working on this"
	var age: float = bed.take_bedding()
	if age < 0.0:
		return "There is no bedding on it."
	held_tool = &"bundle"
	held_bundle_age = age
	AudioManager.play("pickup", position)
	return ""

# --- Taking materials back, cancelling, dismantling ---------------------------------------------------

# E at a blueprint with empty hands, before any hammer hit: one delivered plank comes out into his hands.
func take_back_plank_from(b) -> String:
	if hands_occupied():
		return "Your hands are full"
	var back: StringName = b.take_back_one()
	if back == &"":
		return "Work has begun: the planks can no longer be taken back"
	if back == &"plank":
		carrying_planks += 1
	else:
		held_tool = back
	AudioManager.play("pickup", position)
	return ""

# E at a blueprint that needs what he holds (a branch, a flat stone): delivered.
func deliver_material(b) -> String:
	if not Items.is_item(held_tool) or not b.add_material(held_tool):
		return ""
	held_tool = &""
	AudioManager.play("drop", position)
	return ""

# --- The grinding stone ------------------------------------------------------------------------------------------------

# E at a grinding stone holding a wheat sheaf: it goes in.
func grinding_stone_add(q) -> String:
	if held_tool != &"wheat_sheaf":
		return ""
	var msg: String = q.add_sheaf(self)
	if msg == "":
		held_tool = &""
		_note_work(&"cook", q)
	return msg

# E at a grinding stone with empty hands: takes the flour if there is some, else one press of grinding.
func grinding_stone_press(q) -> String:
	if hands_occupied():
		return ""
	if q.flour_out > 0:
		if q.take_flour():
			held_tool = &"flour"
			AudioManager.play("pickup", position)
		return ""
	_note_work(&"cook", q)
	return q.grind_press(self)

# --- The campfire -----------------------------------------------------------------------------------------------

# E at a campfire holding a branch, a plank or a log: it burns (a log being dragged is used up).
func campfire_fuel(fire) -> String:
	var kind: StringName = &""
	if dragger.is_dragging():
		kind = &"log"
	elif carrying_planks > 0:
		kind = &"plank"
	elif held_tool == &"branch":
		kind = &"branch"
	else:
		return ""
	if not fire.add_fuel(kind):
		return "The fire has enough fuel."
	match kind:
		&"log":
			dragger.release()
			if drag_tree != null:
				drag_tree.finish_log()
			drag_tree = null
		&"plank":
			carrying_planks -= 1
		_:
			held_tool = &""
	return ""

# E at a campfire with the fire starter: one press of sparking.
func campfire_spark(fire) -> String:
	if held_tool != &"fire_starter":
		return ""
	return fire.spark_press(self)

# E at a campfire with a flat stone: it goes on top.
func campfire_place_stone(fire) -> String:
	if held_tool != &"flat_stone":
		return ""
	if not fire.place_stone():
		return "There is a stone on it already."
	held_tool = &""
	return ""

# Shift+E at a campfire with empty hands: takes the stone off.
func campfire_take_stone(fire) -> String:
	if hands_occupied():
		return "Your hands are full"
	if not fire.food.is_empty():
		return "Take the food off first."
	if fire.take_stone():
		held_tool = &"flat_stone"
	return ""

# E at a campfire with dough: it goes on the stone and cooks while the stone is hot. (Flour has to be made into
# dough on the board first.)
func campfire_place_dough(fire) -> String:
	if held_tool == &"flour":
		return "It needs water first."
	if held_tool != &"dough":
		return ""
	var msg: String = fire.place_dough()
	if msg == "":
		held_tool = &""
		_note_work(&"cook", fire)
	return msg

# E at a campfire with empty hands and something on the stone: takes it (a cooked flatbread, or the flour back from
# an uncooked dough). If his hands are not empty it goes on the ground beside the fire.
func campfire_take_food(fire) -> String:
	var kind: StringName = fire.take_food()
	if kind == &"":
		return ""
	if hands_occupied():
		Items.put(get_tree(), get_parent(), kind, fire.global_position + Vector2(0, 12), _items_rect())
	else:
		held_tool = kind
	return ""

# The same at a pit saw: its planks and its saw blade come back one at a time.
func take_back_from_pit(pit, what: StringName) -> String:
	if hands_occupied():
		return "Your hands are full"
	if what == &"blade":
		if not pit.take_back_blade():
			return "Work has begun: the saw blade can no longer be taken back"
		carrying_blade = true
	else:
		if not pit.take_back_plank():
			return "Work has begun: the planks can no longer be taken back"
		carrying_planks += 1
	return ""

# E at a blueprint with nothing left in it (empty hands, no hits): it is cancelled.
func cancel_blueprint(b) -> String:
	if hands_occupied() or not b.can_cancel():
		return ""
	b.cancel()
	return "Blueprint cancelled"

# Shift+E / Shift+click on a construction with the hammer: one press per input (the first walks him there).
# Returns "" if accepted (or quietly ignored), or a message for the HUD.
func request_dismantle(target) -> String:
	if held_tool != &"hammer":
		return "Hold the hammer to dismantle"
	var why: String = Dismantle.block_reason(get_tree(), target, self)
	if why != "":
		return why
	match state:
		State.FREE:
			if not start_dismantle_work(target):
				return Dismantle.IN_USE
		State.CHOP_IDLE:
			if target == work_dismantle and work_kind == &"dismantle":
				_start_swing()
			else:
				_cancel_order()
				if not start_dismantle_work(target):
					return Dismantle.IN_USE
		State.CHOPPING:
			if queue_next_chop and target == work_dismantle and work_kind == &"dismantle" and not chop_work_done:
				chop_queued = true
	return ""

# Claims it (so nobody else works on it) and walks to the hammering spot beside it.
func start_dismantle_work(target) -> bool:
	if not Dismantle.try_claim(target, self):
		return false
	work_dismantle = target
	work_kind = &"dismantle"
	var spot: Vector2 = Dismantle.stand_spot(target)
	chop_side = -1.0 if spot.x < target.global_position.x else 1.0
	_walk_to(spot, State.WALKING_TO)
	return true

# --- The basket and berries -----------------------------------------------------------------------------

# What E does at a crate now (the prompt's verb): a berry or an item it takes goes in, a basket with berries pours,
# an empty basket fills, empty hands take what the crate offers (Shift+E steps to the next kind); with anything
# else the crate does not take it.
const CRATE_ITEMS: Array[StringName] = [&"seed_bag", &"wheat_sheaf", &"flour", &"flatbread"]

func crate_verb(crate = null) -> String:
	if held_tool == &"berry":
		return "Add berry"
	if CRATE_ITEMS.has(held_tool):
		return "Add %s" % Items.name_of(held_tool).to_lower()
	if held_tool == &"basket":
		return "Pour berries" if basket_berries > 0 else "Fill basket"
	if not hands_occupied():
		var kind: StringName = crate.selected_kind() if crate != null else &"berry"
		if kind == &"":
			return "Take"
		var name: String = "berry" if kind == &"berry" else Items.name_of(kind).to_lower()
		var more: bool = crate != null and crate.kinds_present().size() > 1
		return "Take %s%s" % [name, "  (Shift: next)" if more else ""]
	return "Use"

# E / click at a crate. Returns "" or a message.
func use_crate(crate) -> String:
	if state != State.FREE:
		return ""
	var clock: Node = _game_clock()
	var capacity: int = clock.basket_capacity if clock != null else 6
	var plain_hands: bool = not hands_occupied()
	if held_tool == &"berry":
		if crate.is_full():
			return "The crate is full."
		crate.add_item(&"berry", 1)
		held_tool = &""
		crate.open_lid()
		AudioManager.play("berry_drop", crate.global_position)
		return ""
	if CRATE_ITEMS.has(held_tool):
		if crate.is_full():
			return "The crate is full."
		if held_tool == &"seed_bag":
			crate.add_bag(held_seeds)
			held_seeds = 0
		else:
			crate.add_item(held_tool, 1)
		held_tool = &""
		crate.open_lid()
		AudioManager.play("drop", crate.global_position)
		return ""
	if held_tool == &"basket":
		if basket_berries > 0:
			# Pour: what fits goes in, the rest stays in the basket.
			if crate.is_full():
				return "The crate is full."
			var moved: int = crate.add_item(&"berry", basket_berries)
			basket_berries -= moved
			crate.open_lid()
			AudioManager.play("berry_drop", crate.global_position)
			return ""
		# An empty basket: fill it from the crate (up to its capacity).
		if not crate.has_berries():
			return "The crate is empty."
		basket_berries += crate.take_item(&"berry", capacity)
		crate.open_lid()
		AudioManager.play("berry_pick", crate.global_position)
		return ""
	if plain_hands:
		var kind: StringName = crate.selected_kind()
		if kind == &"":
			return "The crate is empty."
		if kind == &"berry":
			crate.take_item(&"berry", 1)
			held_tool = &"berry"
			AudioManager.play("berry_pick", crate.global_position)
		elif kind == &"seed_bag":
			held_seeds = maxi(0, crate.take_bag())
			held_tool = &"seed_bag"
			AudioManager.play("pickup", crate.global_position)
		else:
			crate.take_item(kind, 1)
			held_tool = kind
			AudioManager.play("pickup", crate.global_position)
		crate.open_lid()
		return ""
	return "The crate does not take that."

# Shift+E at a crate with empty hands: the next kind of thing in it.
func crate_cycle(crate) -> String:
	if hands_occupied():
		return ""
	var kind: StringName = crate.cycle_kind()
	if kind == &"":
		return "The crate is empty."
	return "%s (%d)" % [Items.name_of(kind) if kind != &"berry" else "Berries", crate.count_of(kind)]

# E / click at a basket on the ground: picks it up (with its berries). With his hands full it is a swap
# (swap_on_pickup) or a refusal. Returns "" or a message.
func take_basket(item) -> String:
	# A loose berry in hand goes into a basket on the ground that has room (the basket stays where it is).
	var clock: Node = _game_clock()
	if held_tool == &"berry" and clock != null and item.berries < clock.basket_capacity:
		held_tool = &""
		item.berries += 1
		AudioManager.play("drop", position)
		return ""
	if hands_occupied() and not swap_on_pickup:
		return "Your hands are full"
	var berries: int = item.berries
	item.remove_from_group("baskets")
	item.queue_free()
	var old: StringName = _unhold()
	held_tool = &"basket"
	basket_berries = berries
	_place_item(old, position)
	AudioManager.play("basket_pickup", position)
	return ""

# One press per berry on a ripe bush, with the basket in hand. Returns "" if accepted (or quietly ignored), or
# a message for the HUD.
func request_pick(bush) -> String:
	# With the basket in hand the berry goes into it (up to its capacity); with EMPTY hands one berry goes
	# into his hand; with anything else (or a berry already) his hands are full.
	var clock: Node = _game_clock()
	if held_tool == &"basket":
		if clock != null and basket_berries >= clock.basket_capacity:
			return "Your basket is full."
	elif hands_occupied():
		return "Your hands are full."
	match state:
		State.FREE:
			if not start_pick_work(bush):
				return "Someone else is picking this"
		State.CHOP_IDLE:
			if bush == work_grass and work_kind == &"pick":
				_start_swing()
			else:
				_cancel_order()
				if not start_pick_work(bush):
					return "Someone else is picking this"
		State.CHOPPING:
			if queue_next_chop and bush == work_grass and work_kind == &"pick" and not chop_work_done:
				chop_queued = true
	return ""

# Claims the bush and walks to the spot beside it; the first berry comes off there.
func start_pick_work(bush) -> bool:
	if not bush.try_claim(self):
		return false
	work_grass = bush
	work_kind = &"pick"
	chop_side = 1.0 if position.x > bush.position.x else -1.0
	_walk_to(Vector2(bush.position.x + chop_side * 14.0, bush.position.y + 3.0), State.WALKING_TO)
	return true

# E on empty ground with a berry in hand (or berries in the basket): eats one (restores berry_hunger_value
# hunger).
func request_eat() -> String:
	var berry_in_hand: bool = held_tool == &"berry"
	var bread_in_hand: bool = held_tool == &"flatbread"
	if not berry_in_hand and not bread_in_hand and (held_tool != &"basket" or basket_berries <= 0):
		return ""
	var clock: Node = _game_clock()
	var value: float = clock.berry_hunger_value if clock != null else 12.0
	if bread_in_hand:
		value = FoodConfig.cfg().flatbread_hunger_value
	if hunger.value > 100.0 - value:
		return "You are not hungry."
	if berry_in_hand or bread_in_hand:
		held_tool = &""
	else:
		basket_berries -= 1
	hunger.eat(value)
	AudioManager.play("eat_bread" if bread_in_hand else "eat", position, randf_range(0.95, 1.05))
	WorkFx.crumbs(get_tree(), position + Vector2(0, -10))
	WorkFx.pop(get_tree(), position + Vector2(0, -14))
	# A short bob (there is no eating picture): up and back.
	if state == State.FREE:
		var tw: Tween = sprite.create_tween()
		tw.tween_property(sprite, "offset", base_offset + Vector2(0, -2), 0.08)
		tw.tween_property(sprite, "offset", base_offset, 0.12)
	return ""

# --- The dough board is an item; tables hold items ----------------------------------------------------------------

# E at a dough board with empty hands (and nothing to take or knead): he picks the board up, keeping what is on it.
func take_board(board) -> String:
	if hands_occupied():
		return "Your hands are full"
	held_board = board.get_state()
	held_tool = &"dough_board"
	board.remove_from_group("dough_boards")
	board.queue_free()
	AudioManager.play("pickup", position)
	return ""

# The things a table takes on its surface: any of the items, the basket and the three old tools.
func table_takes(kind: StringName) -> bool:
	return Items.is_item(kind) or kind == &"basket" or kind == &"hammer" or kind == &"shovel" or kind == &"axe"

# A node for an item that he holds or has just put down (not yet in the tree), with what it keeps.
func _make_item_node(kind: StringName) -> Node2D:
	match kind:
		&"basket":
			var basket: Node2D = (load("res://scenes/Basket.tscn") as PackedScene).instantiate()
			basket.berries = _unheld_berries
			return basket
		&"hammer":
			return PlankPiles.HAMMER_SCENE.instantiate()
		&"shovel":
			return PlankPiles.SHOVEL_SCENE.instantiate()
		&"axe":
			return PlankPiles.AXE_SCENE.instantiate()
		&"dough_board":
			return Items.make_board(_unheld_board)
	if Items.is_item(kind):
		var item: Node2D = (load("res://scenes/GroundItem.tscn") as PackedScene).instantiate()
		item.kind = kind
		if kind == &"seed_bag":
			item.seeds = _unheld_seeds
		elif kind == &"bucket":
			item.scoops = _unheld_scoops
		return item
	return null

# E at a table holding something it takes: it goes on the surface.
func table_put(table) -> String:
	if not table_takes(held_tool) or dragger.is_dragging():
		return "That does not go on a table."
	if not table.has_room():
		return "The table is full."
	var kind: StringName = _unhold()
	var node: Node2D = _make_item_node(kind)
	if node == null:
		return ""
	table.put_node(node)
	AudioManager.play("board_set" if kind == &"dough_board" else "table_set", table.global_position)
	return ""

# --- Water: the bucket, scooping, watering and the dough board ---------------------------------------------------------

# E / click on water with the bucket (reach_px from his feet): one scoop, taking bucket_scoop_seconds at normal energy
# (a tired or hungry player takes longer). Returns "" or a message.
func scoop_water(_cell: Vector2i) -> String:
	if held_tool != &"bucket":
		return "Pick up the bucket to scoop"
	var cfg: Resource = FoodConfig.cfg()
	if held_scoops >= cfg.bucket_capacity:
		return "The bucket is full."
	var now_ms: int = Time.get_ticks_msec()
	if now_ms < _scoop_ready_at:
		return ""
	_scoop_ready_at = now_ms + int(cfg.bucket_scoop_seconds / maxf(0.1, rest.efficiency()) * 1000.0)
	held_scoops += 1
	AudioManager.play("scoop", position)
	WorkFx.burst(get_tree(), position + Vector2(0, -6), [Color(0.55, 0.78, 0.95), Color(0.8, 0.92, 1.0)] as Array[Color], 5, 28.0, 0.35, 90.0, Vector2.UP, 70.0)
	_work_bob()
	return ""

# One pour takes bucket_pour_seconds at normal energy (slower when tired or hungry): false while the last one is not done.
func _pour_ready() -> bool:
	var now_ms: int = Time.get_ticks_msec()
	if now_ms < _pour_ready_at:
		return false
	_pour_ready_at = now_ms + int(FoodConfig.cfg().bucket_pour_seconds / maxf(0.1, rest.efficiency()) * 1000.0)
	return true

# Fills the bucket he holds (debug).
func fill_bucket() -> bool:
	if held_tool != &"bucket":
		return false
	held_scoops = FoodConfig.cfg().bucket_capacity
	return true

# E with a bucket of water on a plot: it is watered for wheat_water_clock_seconds (growth counts only while it is).
func plot_water(cell: Vector2i) -> String:
	if held_tool != &"bucket":
		return ""
	var m: Node2D = plot_manager()
	var stage: StringName = m.stage(cell)
	if stage == &"tilled":
		return "Sow it first."
	if stage != &"sown" and stage != &"growing":
		return ""
	if held_scoops <= 0:
		return "The bucket is empty."
	if m.is_watered(cell):
		return "It is watered already."
	if not _pour_ready():
		return ""
	held_scoops -= 1
	m.water(cell)
	_note_work(&"water", null, cell)
	AudioManager.play("pour", position)
	_work_bob()
	return ""

# --- The dough board ---

# E at the board holding flour: it goes on the board.
func board_flour(b) -> String:
	if held_tool != &"flour":
		return ""
	var msg: String = b.put_flour()
	if msg == "":
		held_tool = &""
	return msg

# E at the board holding a bucket: one scoop is poured on it.
func board_water(b) -> String:
	if held_tool != &"bucket":
		return ""
	if held_scoops <= 0:
		return "The bucket is empty."
	if not _pour_ready():
		return ""
	var msg: String = b.pour_water()
	if msg == "":
		held_scoops -= 1
	return msg

# E at the board with empty hands: takes the dough if there is some, else one press of kneading (3 make dough).
func board_press(b) -> String:
	if hands_occupied():
		return ""
	if b.dough:
		if b.take_dough():
			held_tool = &"dough"
			AudioManager.play("pickup", position)
		return ""
	_note_work(&"cook", b)
	return b.knead_press(self)

# --- Plots (see plot_manager.gd) -------------------------------------------------------------------------------

func plot_manager() -> Node2D:
	return load("res://scripts/plot_manager.gd").get_for(get_tree())

# The cell he works when nothing is under the mouse: the one just in front of his feet, the way he faces.
func plot_cell_in_front() -> Vector2i:
	var m: Node2D = plot_manager()
	var dir: float = -1.0 if sprite.flip_h else 1.0
	var s: float = float(m.size_px())
	return m.cell_of(position + Vector2(dir * (s * 0.5 + 3.0), -2.0))

# E / click with the hoe on a cell: a bare cell is tilled in two presses, stubble goes back to tilled soil.
func plot_till(cell: Vector2i) -> String:
	if held_tool != &"hoe":
		return "Pick up the hoe to till"
	if inside_building != null:
		return "Can't till here."
	var m: Node2D = plot_manager()
	if m.has_plot(cell):
		if m.stage(cell) == &"stubble":
			m.retill(cell)
			_note_work(&"till", null, cell)
			return ""
		return "Already tilled."
	var why: String = m.can_till(cell)
	if why != "":
		return why
	m.till_press(cell)
	_note_work(&"till", null, cell)
	_work_bob()
	return ""

# E / click with a seed bag on a tilled cell: one seed is sown.
func plot_sow(cell: Vector2i) -> String:
	if held_tool != &"seed_bag":
		return ""
	if held_seeds <= 0:
		return "The bag is empty."
	var m: Node2D = plot_manager()
	if m.stage(cell) != &"tilled" or inside_building != null:
		return ""
	held_seeds -= 1
	m.sow(cell)
	_note_work(&"sow", null, cell)
	_work_bob()
	return ""

# E / click with the sickle on a ripe cell: it is cut. It gives the wheat sheaf only (he holds the sickle, so it goes beside
# the plot); seeds come from threshing a sheaf (thresh_sheaf).
func plot_harvest(cell: Vector2i) -> String:
	if held_tool != &"sickle":
		return "Pick up the sickle to harvest"
	var m: Node2D = plot_manager()
	if m.stage(cell) != &"ripe":
		return ""
	var cfg: Resource = FoodConfig.cfg()
	m.harvest(cell)
	_note_work(&"harvest", null, cell)
	_work_bob()
	var centre: Vector2 = m.cell_center(cell)
	var beside: Vector2 = centre + Vector2(0.0, float(m.size_px()) * 0.5 + 6.0)
	for i in cfg.wheat_per_harvest:
		Items.put(get_tree(), get_parent(), &"wheat_sheaf", beside + Vector2(i * 4.0, 0.0), map_rect)
	return ""

# E / click on a wheat sheaf (on the ground or on a table) with a seed bag in the hands: thresh_presses presses (a rustle each, at
# the same pitch) destroy the sheaf and put thresh_seeds_per_sheaf seeds into the bag (and a different sound for the last one). It
# needs room for all of them, else nothing happens. One sheaf per action; holding the key repeats the presses of the same sheaf.
func thresh_sheaf(item) -> String:
	if held_tool != &"seed_bag" or item == null or not is_instance_valid(item) or item.kind != &"wheat_sheaf":
		return ""
	var cfg: Resource = FoodConfig.cfg()
	if held_seeds + cfg.thresh_seeds_per_sheaf > cfg.seed_bag_capacity:
		return "Not enough room in the bag."
	var presses: int = int(item.get_meta(&"thresh_presses", 0)) + 1
	_work_bob()
	if presses < cfg.thresh_presses:
		item.set_meta(&"thresh_presses", presses)
		AudioManager.play("thresh_rustle", item.global_position, 1.0)
		return ""
	held_seeds += cfg.thresh_seeds_per_sheaf
	item.remove_from_group("ground_items")
	item.queue_free()
	AudioManager.play("thresh_done", item.global_position, 1.0)
	return ""

# A short bob for work with no swing picture of its own (like eating).
func _work_bob() -> void:
	if state == State.FREE:
		var tw: Tween = sprite.create_tween()
		tw.tween_property(sprite, "offset", base_offset + Vector2(0, 1), 0.06)
		tw.tween_property(sprite, "offset", base_offset, 0.08)

# --- Items of the food chain ---------------------------------------------------------------------

# E / click at an item on the ground (seed bag, wheat sheaf, flour, flatbread, flat stone, branch, hoe, sickle,
# fire starter): picks it up (a seed bag with its seeds), the same way as the tools: with his hands full it is a
# swap (swap_on_pickup) or a refusal. Returns "" or a message.
func take_item(item) -> String:
	if hands_occupied() and not swap_on_pickup:
		return "Your hands are full"
	var kind: StringName = item.kind
	var seeds: int = item.amount()
	item.remove_from_group("ground_items")
	item.queue_free()
	var old: StringName = _unhold()
	held_tool = kind
	if kind == &"seed_bag":
		held_seeds = seeds
	elif kind == &"bucket":
		held_scoops = seeds
	_place_item(old, position)
	AudioManager.play("pickup", position)
	return ""

# Holding a seed bag, E on another one on the ground: its seeds move into the one in his hands, up to its capacity.
func merge_seeds_from(item) -> String:
	var room: int = FoodConfig.cfg().seed_bag_capacity - held_seeds
	if held_tool != &"seed_bag" or item.seeds <= 0:
		return ""
	if room <= 0:
		return "The bag is full."
	var moved: int = mini(room, item.seeds)
	held_seeds += moved
	item.seeds -= moved
	AudioManager.play("pickup", position, 1.2)
	return ""

# --- The toolbox (see toolbox.gd) ---------------------------------------------------------------------------------------

# What he holds as {kind, amount}: the amount is the seeds of a seed bag, the scoops of a bucket, the berries of a basket.
func _held_amount(kind: StringName) -> int:
	match kind:
		&"seed_bag":
			return _unheld_seeds
		&"bucket":
			return _unheld_scoops
		&"basket":
			return _unheld_berries
	return 0

# E on the closed toolbox with something in his hands: it goes straight in ("Put away."), if the box takes it.
func toolbox_put(box) -> String:
	if not hands_occupied():
		return ""
	if dragger.is_dragging() or carrying_planks > 0 or carrying_blade or not box.accepts_kind(held_tool):
		return "The toolbox does not take that."
	if not box.has_room(held_tool):
		return "The toolbox is full."
	var kind: StringName = _unhold()
	box.add_item(kind, _held_amount(kind))
	AudioManager.play("drop", box.global_position)
	return "Put away."

# Takes slot `index` of the box into his hands as if he had picked it up. With a tool or accepted item in his hands it is a
# swap: the old one goes into the box. Returns "" or a message.
func toolbox_take(box, index: int) -> String:
	if index < 0 or index >= box.contents.size():
		return ""
	# a tool a colonist has reserved for himself is not mine to take
	var holder: Node = box.reserved_by(box.contents[index]["kind"])
	if holder != null:
		return "Reserved by %s." % holder.display_name
	var holding_other: bool = dragger.is_dragging() or carrying_planks > 0 or carrying_blade or (held_tool != &"" and not box.accepts_kind(held_tool))
	if holding_other:
		return "Your hands are full"
	var swapping: bool = held_tool != &""
	if swapping and not box.has_room(held_tool) and int(box.contents[index]["count"]) > 1:
		return "The toolbox is full."
	var chosen: Dictionary = box.take_item(index)
	if chosen.is_empty():
		return ""
	var old: StringName = _unhold()
	var old_amount: int = _held_amount(old) if old != &"" else 0
	held_tool = chosen["kind"]
	match held_tool:
		&"seed_bag":
			held_seeds = int(chosen["amount"])
		&"bucket":
			held_scoops = int(chosen["amount"])
		&"basket":
			basket_berries = int(chosen["amount"])
	if old != &"":
		box.add_item(old, old_amount)
	AudioManager.play("pickup", position)
	return ""

# --- Tools ---------------------------------------------------------------------------------------

# E / click at a tool lying on the ground (the hammer, the shovel or the axe): picks it up, the same
# way as the blade. Returns "" or a message.
func take_tool(item, tool: StringName) -> String:
	if hands_occupied() and not swap_on_pickup:
		return "Your hands are full"
	item.remove_from_group(item.tool_group)
	item.queue_free()
	var old: StringName = _unhold()
	held_tool = tool
	_place_item(old, position)
	AudioManager.play("pickup", position)
	return ""

# E at an unfinished pit saw with a plank / the blade in hand: hands it over (used up).
# Returns "" or a message (and he keeps the item).
func deliver_plank_to_pit(pit) -> String:
	if carrying_planks <= 0:
		return ""
	if not pit.add_plank():
		return "The pit saw already has enough planks"
	carrying_planks -= 1
	AudioManager.play("plank_drop", position)
	return ""

func deliver_blade_to_pit(pit) -> String:
	if not carrying_blade:
		return ""
	if not pit.add_blade():
		return "The pit saw already has its saw blade"
	carrying_blade = false
	AudioManager.play("drop", position)
	return ""

# E at the pit saw (or Sawmill) with a log: it disappears from the world into it.
func load_log_into(pit) -> bool:
	if not dragger.is_dragging() or not pit.accept_log():
		return false
	dragger.release()
	if drag_tree != null:
		drag_tree.finish_log()
	drag_tree = null
	return true

# --- Pit saw --------------------------------------------------------------------------

# The pit has asked for him: walk to his sawing spot behind it.
func start_saw_walk(pit) -> void:
	saw_pit = pit
	saw_arrived = false
	_walk_to(pit.player_spot_world(), State.SAW_WALK)

# He stops sawing (a movement key, E again): the pit saw stops, he steps out of the pose and the helper with him.
func stop_sawing() -> void:
	if saw_pit != null:
		saw_pit.stop_sawing(self)

# Both sawyers are drawn by the pit's in-use sprite, so he is hidden and out of the world.
func hide_for_sawing() -> void:
	state = State.SAWING
	velocity = Vector2.ZERO
	waypoints.clear()
	visible = false
	body_shape.set_deferred("disabled", true)

func show_after_sawing() -> void:
	visible = true
	body_shape.set_deferred("disabled", false)
	saw_pit = null
	state = State.FREE
	sprite.play(_idle_anim())
