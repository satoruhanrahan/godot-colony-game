extends Node2D

# E and left-click for the MainCharacter. Both work on the same list of "candidates" (things he
# can do right now: chop a tree, take a plank, deliver to a blueprint, hammer a pit saw, ...)
# and both run the same _do() on the one chosen, so they follow exactly the same rules:
#  - E does the target shown in the prompt: the object under the mouse if it is in reach
#    (and the mouse moved lately), otherwise the nearest one within interaction_radius.
#  - A left-click does the object under the mouse; out of reach it says "Too far away" and does
#    nothing (he never walks to it). Empty ground does nothing, and build mode (which places
#    buildings with the same click) takes priority.
# Each press or click is one action: held-key repeats are ignored, and an animated job (a swing,
# a dig, a hammer blow) takes one action per input. Lives under the MainCharacter.

# How close (px, from his feet) something must be to be used.
@export var interaction_radius: float = 28.0
# A click this close (px) to an object's base counts as a click on it, as does a click on its
# sprite.
@export var click_radius: float = 10.0
# The prompt follows the mouse only while the mouse has moved within this many seconds (so a
# mouse left lying over something does not hijack E while he walks about).
@export var hover_seconds: float = 3.0
# Of two things about equally near (within this many px), the one already shown stays, so the prompt
# does not flicker between them as he moves.
@export var target_hysteresis: float = 4.0
# The E chooser: when E would act on a pickup and other pickups lie within chooser_radius_px of it, a small list opens beside him
# instead (see the end of this file). The mouse is never asked: it keeps picking the item under the cursor.
@export var chooser_radius_px: float = 24.0
# Pressing E again within this many seconds of opening the chooser does the top row (the fast path).
@export var chooser_double_tap_seconds: float = 0.3
# The default order of the chooser's rows: the nearest thing to the cursor (else his feet) first, things within this many px of each
# other counting as equally near; then a tool-using action before a plain pick-up; then this list (earlier = higher).
@export var chooser_tolerance_px: float = 6.0
@export var verb_priority: Array[String] = ["Chop", "Delimb", "Dig", "Hammer", "Dismantle", "Till", "Sow", "Harvest", "Water", "Pick", "Take", "Add seeds to", "Pick up", "Swap for"]
# Holding E or the left mouse button repeats a work action on the same target until it is let go (see _tick_hold).
@export var hold_repeat_enabled: bool = true
# Between repeats of an action that has no swing of its own (tilling, harvesting, grinding, the ferro rod), in seconds
# at full efficiency: a tired or hungry player takes longer, so holding never makes him faster.
@export var hold_repeat_interval: float = 0.4

# The prompt: a small "E" key cap and a short verb, both at the HUD's small text size, close to the
# target, and only one at a time. (The verbs in Full detail; in Minimal just the first word.)
const Dismantle = preload("res://scripts/dismantle.gd")
const BundleArt = preload("res://scripts/bundle_art.gd")
const Items = preload("res://scripts/items.gd")
const HoverNames = preload("res://scripts/hover_names.gd")
const GroundPlacement = preload("res://scripts/ground_placement.gd")
const Actions = preload("res://scripts/actions.gd")
const CAP_W: float = 9.0
const CAP_H: float = 11.0
const VERBS: Dictionary = {
	"log": "Take log", "pit_dig": "Dig", "hammer": "Hammer", "pit_hammer": "Hammer",
	"take_plank": "Take plank", "take_blade": "Take blade", "take_hammer": "Take hammer",
	"take_shovel": "Take shovel", "take_axe": "Take axe",
	"pit_add_plank": "Deliver plank", "pit_add_blade": "Deliver blade", "deliver_plank": "Deliver plank",
	"store_plank": "Store plank", "store_log": "Store log", "add_to_pile": "Add plank",
	"pit_load": "Load log", "sawmill_load": "Load log", "pit_saw": "Saw", "drop": "Drop log",
	"pit_needs": "Check", "sleep": "Sleep",
	"pull": "Pull grass", "take_bundle_pile": "Take bundle", "add_bundle": "Add bundle", "sleep_bed": "Sleep", "break_bed": "Break up", "add_bedding": "Add bedding", "remove_bedding": "Remove bedding",
	"take_back_plank": "Take back", "cancel_blueprint": "Cancel", "pit_take_plank": "Take plank back", "pit_take_blade": "Take blade back",
	"dismantle": "Dismantle", "dismantle_hint": "Dismantle (Shift)",
	"enter": "Enter", "leave": "Leave", "crate_use": "Use", "take_item": "Take", "merge_seeds": "Add seeds",
	"plot_till": "Till", "plot_sow": "Sow", "plot_harvest": "Harvest",
	"crate_cycle": "Next", "deliver_material": "Deliver", "scoop": "Scoop", "plot_water": "Water",
	"board_flour": "Put flour", "board_water": "Pour water", "board_knead": "Knead", "board_take": "Take dough",
	"talk": "Talk", "thresh": "Thresh sheaf", "board_pickup": "Pick up board", "toolbox_open": "Open", "toolbox_close": "Close", "table_put": "Put on table", "grinding_stone_add": "Add sheaf", "grinding_stone_grind": "Grind", "grinding_stone_take": "Take flour",
	"campfire_fuel": "Add fuel", "campfire_spark": "Light", "campfire_stone": "Place stone", "campfire_bake": "Put on stone", "campfire_take_food": "Take", "campfire_take_stone": "Take stone", "sleep_floor": "Sleep", "take_basket": "Take basket", "pick": "Pick berry", "eat": "Eat berry",
}

@onready var player = get_parent()
@onready var prompt: Node2D = $Prompt

var current: Dictionary = {}
var _verb_label: Label
var _last_key: String = ""
# `current` is the target under the mouse (not just the nearest).
var _hovered: bool = false
var _mouse_moved_at: float = -1000.0
# Where the mouse last was, in screen (viewport) coordinates, taken from the mouse events
# themselves (a click acts where that click happened).
var _mouse_screen: Vector2 = Vector2.ZERO

# A point on screen as a point in the world, through the Camera2D.
func _world_at(screen: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen

func _ready() -> void:
	prompt.visible = false
	_move_hud_to_ui()
	# The one system that names every pickup under the mouse.
	var names: Node2D = HoverNames.new()
	names.player = player
	add_child(names)

# The pixel-art HUD parts (the Energy and Hunger bars and the held-item slot) are drawn in the UI's art layer at a
# whole-number multiple, not in a layer of the little world view. They sit in the bottom-left corner.
var _hud_parts: Array = []

func _move_hud_to_ui() -> void:
	var hud: Node = get_node_or_null("Hud")
	if hud == null:
		return
	for child in hud.get_children():
		hud.remove_child(child)
		Ui.art_root.add_child(child)
		_hud_parts.append(child)
	hud.queue_free()
	Ui.ui_changed.connect(_place_hud_parts)
	_place_hud_parts()

func _place_hud_parts() -> void:
	var art_h: float = Ui.art_size().y
	for part in _hud_parts:
		if is_instance_valid(part):
			# (They were laid out for a 270 px high view: the same distance from the bottom edge.)
			var from_bottom: float = 270.0 - (216.0 if part.name == "RestBar" else 228.0)
			part.position = Vector2(4.0, art_h - from_bottom)

func _exit_tree() -> void:
	for part in _hud_parts:
		if is_instance_valid(part):
			part.queue_free()
	if Ui.ui_changed.is_connected(_place_hud_parts):
		Ui.ui_changed.disconnect(_place_hud_parts)

func _build_prompt() -> void:
	var cap := Panel.new()
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.size = Vector2(CAP_W, CAP_H)
	var box := StyleBoxFlat.new()
	# A light key cap with a dark letter and a darker lower edge, outlined so it reads on any ground.
	box.bg_color = Color(0.9, 0.9, 0.92)
	box.border_color = Color(0.08, 0.08, 0.1)
	box.set_border_width_all(1)
	box.border_width_bottom = 2
	cap.add_theme_stylebox_override("panel", box)
	var key := Label.new()
	key.mouse_filter = Control.MOUSE_FILTER_IGNORE
	key.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	key.text = "E"
	# The letter sits inside the cap: the font's line is 12 px high with the capital E on rows 2-8.
	key.position = Vector2(2, -2)
	key.add_theme_font_size_override("font_size", 8)
	key.add_theme_color_override("font_color", Color(0.1, 0.1, 0.12))
	cap.add_child(key)
	prompt.add_child(cap)
	_verb_label = Label.new()
	_verb_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_verb_label.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_verb_label.add_theme_font_size_override("font_size", 8)
	_verb_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_verb_label.add_theme_constant_override("outline_size", 3)
	prompt.add_child(_verb_label)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _hover_only() -> bool:
	var hud: Node = get_tree().get_first_node_in_group("hud")
	return hud != null and hud.show_overlays_only_on_hover

func _process(_delta: float) -> void:
	current = {}
	_hovered = false
	# Carrying the toolbox with the friend: no actions but putting it down (that is the carry's own).
	if player.carrying_together != null or player.designating:
		_hold = {}
		close_chooser()
		_update_highlight()
		_update_prompt()
		return
	if player.transitioning:
		_update_prompt()
		return
	var candidates: Array = []
	if player.is_free() or player.is_chopping_session():
		candidates = _candidates()
		# The object under the mouse (in reach) wins; otherwise the nearest one. With the prompt on hover
		# only, the mouse counts while it is over the thing (not just for a few seconds after moving).
		var mouse_known: bool = _mouse_moved_at > -999.0
		if mouse_known and (_hover_only() or _now() - _mouse_moved_at <= hover_seconds):
			var hovered: Dictionary = _target_at(_world_at(_mouse_screen), candidates)
			if not hovered.is_empty() and player.position.distance_to(hovered["point"]) <= interaction_radius:
				current = hovered
				_hovered = true
		if current.is_empty():
			current = _find_nearest(candidates)
		# Tab has chosen another one of the overlapping pickups: that is the target until the cursor or he moves away.
		var cycled: Dictionary = _cycle_target(candidates)
		if not cycled.is_empty():
			current = cycled
	_chooser_tick()
	# A hold session that began in the chooser keeps its target: the nearest-thing rule must not swap it for the branch beside it.
	if not chooser_open and _hold.get("pin", false):
		for cc in candidates:
			if _key_of(cc) == _hold["key"]:
				current = cc
				_hovered = false
				break
	_last_key = _key_of(current) if not current.is_empty() else ""
	_update_highlight()
	_update_plot_hover()
	_tick_hold()
	_update_prompt()

# --- Holding E or the left button: the same work action again and again ---------------------------------------------

# The work actions that repeat while the key or the button is held (each is a swing or a press that already takes
# several presses). One-shot actions (pick up, drop, swap, eat, put into a crate or basket, place a stone, fuel the
# fire) never repeat, so a swap is never followed by a second pick-up.
const REPEATING: Array[String] = ["thresh", "tree", "pit_dig", "hammer", "pit_hammer", "pull", "break_bed", "dismantle", "plot_till", "plot_harvest", "grinding_stone_grind", "campfire_spark", "scoop", "plot_water", "board_knead"]
# The ones that play a swing animation (the next one starts the moment he is between swings); the rest wait
# hold_repeat_interval / efficiency.
const SWINGING: Array[String] = ["tree", "pit_dig", "hammer", "pit_hammer", "pull", "break_bed", "dismantle"]

# {"source": "key" or "mouse", "key": _key_of(target), "verb": what the prompt said, "last": time of the last repeat}.
var _hold: Dictionary = {}
var _last_msg: String = ""
# (The self-check cannot press a real mouse button in a headless window: it sets this for the left button.)
var _test_mouse_down: bool = false

# `pinned`: the hold began from a row of the chooser, so it keeps that exact target (see _process), however it was confirmed.
func _begin_hold(c: Dictionary, source: String, pinned: bool = false) -> void:
	_hold = {}
	if hold_repeat_enabled and REPEATING.has(c["kind"]) and _last_msg == "":
		_hold = {"source": source, "key": _key_of(c), "verb": _verb_text(c), "last": _now(), "pin": pinned}

func _end_hold() -> void:
	_hold = {}

# Every frame while a hold is on: the same target again, as soon as the last swing (or press) is done.
func _tick_hold() -> void:
	if _hold.is_empty():
		return
	if chooser_open:
		_end_hold()
		return
	var still_down: bool = Input.is_key_pressed(KEY_E) if _hold["source"] == "key" else (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or _test_mouse_down)
	var walking: bool = Input.get_vector("move_left", "move_right", "move_up", "move_down") != Vector2.ZERO
	var working: bool = player.is_free() or player.is_chopping_session() or player.state == player.State.WALKING_TO
	if not hold_repeat_enabled or not still_down or walking or player.transitioning or not working:
		_end_hold()
		return
	# (On his way to the job: the hold waits for him to get there.)
	if player.state == player.State.WALKING_TO:
		return
	var c: Dictionary = {}
	if _hold.get("pin", false) or _hold["source"] == "key":
		c = current
	else:
		c = _target_at(_world_at(get_viewport().get_mouse_position()), _candidates(), true)
	# The target is gone, finished (a tree that is down, a plot that is cut) or has become something else: stop.
	if c.is_empty() or _key_of(c) != _hold["key"] or _verb_text(c) != _hold["verb"]:
		_end_hold()
		return
	if player.position.distance_to(c["point"]) > interaction_radius and c["kind"] != "enter":
		_end_hold()
		return
	if SWINGING.has(c["kind"]):
		# Between swings (standing at the job): the next swing starts at once.
		if player.state != player.State.CHOP_IDLE:
			return
	else:
		if player.state != player.State.FREE:
			return
		# (A scoop takes bucket_scoop_seconds, a pour bucket_pour_seconds, the others hold_repeat_interval; all slower when he is tired or hungry.)
		var interval: float = _repeat_interval(c["kind"])
		if _now() - float(_hold["last"]) < interval / maxf(0.1, player.rest.efficiency()):
			return
	_hold["last"] = _now()
	_do(c)

# How long one repeat of this kind of work takes at full efficiency.
func _repeat_interval(kind: String) -> float:
	match kind:
		"scoop":
			return load("res://scripts/food_config.gd").cfg().bucket_scoop_seconds
		"plot_water", "board_water":
			return load("res://scripts/food_config.gd").cfg().bucket_pour_seconds
	return hold_repeat_interval

func _key_of(c: Dictionary) -> String:
	var suffix: String = ":%d,%d" % [c["cell"].x, c["cell"].y] if c.has("cell") else ""
	return "%s:%d%s" % [c["kind"], c["node"].get_instance_id() if c["node"] != null else 0, suffix]

# The plot cell under the mouse when it is within reach of his feet (and the mouse moved lately), else none.
func _mouse_plot_cell() -> Variant:
	if _mouse_moved_at <= -999.0 or not (_hover_only() or _now() - _mouse_moved_at <= hover_seconds):
		return null
	var m: Node2D = load("res://scripts/plot_manager.gd").get_for(get_tree())
	var cell: Vector2i = m.cell_of(_world_at(_mouse_screen))
	if player.position.distance_to(m.cell_center(cell)) > load("res://scripts/food_config.gd").cfg().reach_px:
		return null
	return cell

# The 11x11 outline and the plot's text while the mouse is over a cell he could work (holding the hoe, the sickle
# or a seed bag) or over an existing plot. Hover only.
func _update_plot_hover() -> void:
	var m: Node = get_tree().get_first_node_in_group("plot_manager")
	var held: StringName = player.held_tool
	var tooled: bool = held == &"hoe" or held == &"sickle" or held == &"seed_bag" or held == &"bucket"
	if m == null and not tooled:
		return
	if m == null:
		m = load("res://scripts/plot_manager.gd").get_for(get_tree())
	var cell = _mouse_plot_cell() if (player.is_free() and player.inside_building == null) else null
	if cell == null or not (tooled or m.has_plot(cell)):
		m.set_hover(Vector2i.ZERO, false)
		return
	m.set_hover(cell, true)

# The water tile he can scoop from: the one under the mouse when it is within reach of his feet, else the nearest water
# within reach. Returns null when there is none.
func _water_cell() -> Variant:
	var WaterMap = load("res://scripts/water_map.gd")
	var reach: float = load("res://scripts/food_config.gd").cfg().reach_px
	if _mouse_moved_at > -999.0 and (_hover_only() or _now() - _mouse_moved_at <= hover_seconds):
		var cell: Vector2i = WaterMap.tile_of(_world_at(_mouse_screen))
		if WaterMap.is_water(cell) and WaterMap.distance_to_tile(player.position, cell) <= reach:
			return cell
	var near: Vector2i = WaterMap.nearest_water(player.position)
	if near.x > -9000 and WaterMap.distance_to_tile(player.position, near) <= reach:
		return near
	return null

# A bucket in his hands at the water: scoop.
func _water_candidates(out: Array) -> void:
	if player.held_tool != &"bucket" or player.inside_building != null:
		return
	var layer: Node = get_tree().get_first_node_in_group("water_layer")
	var cell = _water_cell()
	if layer == null or cell == null:
		return
	var WaterMap = load("res://scripts/water_map.gd")
	var point: Vector2 = WaterMap.closest_point_in_tile(player.position, cell)
	var c: Dictionary = _candidate("scoop", layer, point, "", point + Vector2(0, -14), 1)
	c["cell"] = cell
	out.append(c)

# The colonists he can talk to. Lowest priority: anything else in reach (an item, a tree) is the target, and the colonist only wins
# when he is the clear one; when he overlaps an item the chooser lists "Talk to Friend" beside it.
func _colonist_candidates(out: Array) -> void:
	for col in get_tree().get_nodes_in_group("colonists"):
		if col.dead or not col.visible or col.in_room:
			continue
		out.append(_candidate("talk", col, col.position + Vector2(0, -2), "", col.position + Vector2(0, -30), 0))

# What the held hoe, seed bag or sickle can do to the cell he works now (the mouse's, else the one in front).
func _plot_candidates(out: Array) -> void:
	var held: StringName = player.held_tool
	if player.inside_building != null or not (held == &"hoe" or held == &"sickle" or held == &"seed_bag" or held == &"bucket"):
		return
	var m: Node2D = load("res://scripts/plot_manager.gd").get_for(get_tree())
	var mouse_cell = _mouse_plot_cell()
	var cell: Vector2i = mouse_cell if mouse_cell != null else player.plot_cell_in_front()
	var stage: StringName = m.stage(cell)
	var kind: String = ""
	match held:
		&"hoe":
			if stage == &"" or stage == &"stubble":
				kind = "plot_till"
		&"seed_bag":
			if stage == &"tilled":
				kind = "plot_sow"
		&"sickle":
			if stage == &"ripe":
				kind = "plot_harvest"
		&"bucket":
			if stage == &"tilled" or stage == &"sown" or stage == &"growing":
				kind = "plot_water"
	if kind == "":
		return
	var centre: Vector2 = m.cell_center(cell)
	var c: Dictionary = _candidate(kind, m, centre, "", centre + Vector2(0, -14), 1)
	c["cell"] = cell
	out.append(c)

# One prompt at a time, for `current`: hidden when nothing is in reach and while he is busy working
# on that very target (its progress bar is showing).
func _update_prompt() -> void:
	# (Build mode has its own prompts and hint; the world prompt would only add clutter.)
	var building: bool = false
	for b in get_tree().get_nodes_in_group("build_mode"):
		building = building or b.active
	# With overlays on hover only, only a target under the mouse gets a prompt (E still works on the
	# nearest one in reach).
	var hidden_for_hover: bool = _hover_only() and not _hovered
	if current.is_empty() or building or hidden_for_hover or chooser_open or _busy_with(current):
		prompt.visible = false
		return
	var verb: String = _verb_text(current)
	var anchor: Vector2 = current["anchor"]
	# Above any progress bar or pips drawn over the same thing.
	var progress = get_tree().get_first_node_in_group("work_progress")
	if progress != null and current["node"] != null:
		anchor.y = minf(anchor.y, progress.content_top(current["node"]) - 1.0)
	# (The prompt is drawn by the UI in screen space, crisp, just above this point of the world.)
	Ui.show_prompt(get_viewport(), anchor, "E", verb)
	prompt.visible = false

# Walking to, or at work on, the very thing the prompt would be about.
func _busy_with(c: Dictionary) -> bool:
	var node = c["node"]
	if node == null:
		return false
	return player.is_working_on(node)

func _verb_text(c: Dictionary) -> String:
	var text: String = VERBS.get(c["kind"], "")
	if c["kind"] == "talk":
		text = "Talk to %s" % c["node"].display_name
	if c["kind"] == "tree":
		text = "Chop" if c["node"].is_standing() else "Delimb"
	if (c["kind"] == "hammer" or c["kind"] == "pit_hammer") and player.held_tool == &"hammer":
		text += "  (Shift: Dismantle)"
	if c["kind"] == "crate_use":
		text = player.crate_verb(c["node"])
	if c["kind"] == "campfire_take_food" and not c["node"].food.is_empty():
		text = "Take flatbread" if c["node"].food[0]["kind"] == &"flatbread" else "Take dough back"
	if c["kind"] == "take_item":
		text = "Take %s" % Items.name_of(c["node"].kind).to_lower()
	if c["kind"] == "sleep_bed":
		if not c["node"].is_wooden():
			text = "Sleep  (click: break up)"
		elif c["node"].bedding_count() > 0:
			text = "Sleep  (Shift: Remove bedding)"
	var hud = get_tree().get_first_node_in_group("hud")
	if hud != null and hud.is_minimal():
		text = text.split(" ")[0]
	return text

# A message for the player goes to the HUD's one message line.
func show_message(text: String) -> void:
	var hud = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say(text)

func _unhandled_input(event: InputEvent) -> void:
	if player.carrying_together != null or player.designating:
		if event is InputEventMouseMotion:
			_mouse_moved_at = _now()
			_mouse_screen = event.position
		return
	if chooser_open and _chooser_input(event):
		return
	if event is InputEventMouseMotion:
		_mouse_moved_at = _now()
		_mouse_screen = event.position
	# Just-pressed only: key-repeat (echo) events are ignored.
	elif player.transitioning and (event is InputEventKey or event is InputEventMouseButton):
		get_viewport().set_input_as_handled()
		return
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		if cycle_target():
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		# E wakes him if he is asleep.
		if player.state == player.State.SLEEPING:
			get_viewport().set_input_as_handled()
			player.wake_up(true)
			return
		# With the chooser open E confirms the selected item (a quick second E takes the nearest).
		if chooser_open:
			get_viewport().set_input_as_handled()
			if _now() - _ch_opened_at <= chooser_double_tap_seconds:
				_ch_index = 0
			_chooser_confirm()
			return
		if event.shift_pressed and (player.held_tool == &"hammer" or not player.hands_occupied()):
			current = _find_nearest(_candidates())
		if current.is_empty():
			return
		# Two or more things to do close together and no mouse target: choose between them (one doable thing: just do it).
		var in_hold: bool = _hold.get("pin", false) and _key_of(current) == _hold["key"]
		var group: Array = _chooser_actions() if not event.shift_pressed and not in_hold else []
		if not group.is_empty():
			var doable: Array = Actions.enabled_of(group)
			if doable.size() >= 2:
				get_viewport().set_input_as_handled()
				_open_chooser(group)
				return
			if doable.size() == 1:
				get_viewport().set_input_as_handled()
				current = doable[0]["candidate"]
				_do(current)
				_begin_hold(current, "key")
				return
		get_viewport().set_input_as_handled()
		_do(current)
		_begin_hold(current, "key")
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_mouse_moved_at = _now()
		_mouse_screen = event.position
		_click(_world_at(event.position))

# --- Clicking -------------------------------------------------------------------------

# Left-click = the same action E would do on the object under the mouse.
func _click(world: Vector2) -> void:
	for b in get_tree().get_nodes_in_group("build_mode"):
		if b.active:
			return
	if not (player.is_free() or player.is_chopping_session()):
		return
	var all_candidates: Array = _candidates()
	var hit: Dictionary = _target_at(world, all_candidates, true)
	var cycled: Dictionary = _cycle_target(all_candidates)
	if not cycled.is_empty() and (hit.is_empty() or _is_pickup(hit)):
		hit = cycled
	if hit.is_empty():
		# A click on empty ground eats what he holds (a berry, a flatbread, berries in the basket).
		if (player.held_tool == &"basket" and player.basket_berries > 0) or player.held_tool == &"berry" or player.held_tool == &"flatbread":
			get_viewport().set_input_as_handled()
			var eat_msg: String = player.request_eat()
			if eat_msg != "":
				show_message(eat_msg)
		return
	get_viewport().set_input_as_handled()
	if player.position.distance_to(hit["point"]) > interaction_radius and hit["kind"] != "enter":
		show_message("Too far away")
		return
	_do(hit)
	_begin_hold(hit, "mouse")

# --- Which thing is THE target ------------------------------------------------------------------------------------------
# There is always exactly one current target. Pickups (items lying on the ground) have shapes made from their sprite's opaque
# bounds (at least 12 x 12 px, see GroundPlacement). With the MOUSE the target is the pickup under the cursor; of several, the one
# whose centre is closest to the cursor, ties to the front-most (highest y). Other things (trees, buildings ...) keep the old rule
# (the one drawn on top). With E and no mouse target it is the closest pickup to his feet, with a bonus for the ones in front of him
# (the way he faces). Tab steps through the overlapping candidates, nearest first. The target is outlined, and only it shows its name.

const PICKUP_GROUPS: Array[String] = ["ground_items", "saw_blades", "hammers", "shovels", "axes", "plank_piles", "bundle_piles", "baskets", "dough_boards"]
# The key bonus for a pickup in front of him, in px of distance.
const FACING_BONUS: float = 6.0
# The Tab cycle ends when the cursor moves more than this (world px) or he walks more than cycle_player_px.
const CYCLE_CURSOR_PX: float = 12.0
const CYCLE_PLAYER_PX: float = 14.0

var _cycle_key: String = ""
var _cycle_cursor: Vector2 = Vector2.ZERO
var _cycle_player: Vector2 = Vector2.ZERO
# Set while the target was chosen by Tab (the outline and the name show even without the mouse over it).
var cycling: bool = false
var _hl_node: Node2D = null
var _hl_sprite: Node2D = null
var _hl_material: ShaderMaterial = null

func _is_pickup(c: Dictionary) -> bool:
	var node = c["node"]
	if node == null or not is_instance_valid(node):
		return false
	for group in PICKUP_GROUPS:
		if node.is_in_group(group):
			return true
	return false

# The candidate for the object under this world point (see above).
func _target_at(world: Vector2, candidates: Array, click: bool = false) -> Dictionary:
	var hits: Array = []
	var pickup_hits: Array = []
	for c in candidates:
		if c["node"] == null or c["mode"] == ("key" if click else "click"):
			continue
		var base: Vector2 = _base_of(c)
		if _is_pickup(c):
			var rect: Rect2 = GroundPlacement.pickup_rect(c["node"]).grow(1.0)
			if rect.has_point(world):
				pickup_hits.append({"c": c, "y": base.y, "d": world.distance_to(rect.get_center())})
		elif _area_of(c).has_point(world) or world.distance_to(base) <= click_radius:
			hits.append({"c": c, "y": base.y, "d": world.distance_to(base)})
	var best_pickup: Dictionary = _best_hit(pickup_hits, true)
	var best_other: Dictionary = _best_hit(hits, false)
	var best: Dictionary = {}
	if not best_pickup.is_empty() and not best_other.is_empty():
		# an item lying in front of a building or tree wins; a tree or building standing clearly in front of it covers it
		var covered: bool = best_other["y"] > best_pickup["y"] + 12.0
		best = best_other["c"] if covered else best_pickup["c"]
	elif not best_pickup.is_empty():
		best = best_pickup["c"]
	elif not best_other.is_empty():
		best = best_other["c"]
	if best.is_empty():
		return {}
	# of that object's candidates, the highest priority
	var chosen: Dictionary = best
	for c in candidates:
		if c["node"] == best["node"] and c["mode"] != ("key" if click else "click") and c["priority"] > chosen["priority"]:
			chosen = c
	return chosen

# `by_centre`: the closest centre to the cursor, ties (within 0.5 px) to the front-most; else the one drawn on top, then the nearest.
func _best_hit(hits: Array, by_centre: bool) -> Dictionary:
	if hits.is_empty():
		return {}
	var top: Dictionary = hits[0]
	for h in hits:
		if by_centre:
			if h["d"] < top["d"] - 0.5 or (absf(h["d"] - top["d"]) <= 0.5 and h["y"] > top["y"]):
				top = h
		elif h["y"] > top["y"] + 0.5 or (absf(h["y"] - top["y"]) <= 0.5 and h["d"] < top["d"]):
			top = h
	return top

# Tab: the next of the overlapping pickups, nearest first. Returns whether there was one to go to.
func cycle_target() -> bool:
	var candidates: Array = _candidates()
	var mouse_world: Vector2 = _world_at(_mouse_screen)
	var use_mouse: bool = _hovered and not current.is_empty()
	var origin: Vector2 = mouse_world if use_mouse else player.position
	var anchor_rect := Rect2()
	if not current.is_empty() and _is_pickup(current):
		anchor_rect = GroundPlacement.pickup_rect(current["node"])
	var list: Array = []
	var seen: Dictionary = {}
	for c in candidates:
		if not _is_pickup(c) or c["mode"] == "click" or c["mode"] == "hover" or seen.has(c["node"]):
			continue
		if player.position.distance_to(c["point"]) > interaction_radius:
			continue
		var rect: Rect2 = GroundPlacement.pickup_rect(c["node"])
		var overlapping: bool = rect.grow(1.0).has_point(mouse_world) if use_mouse else (anchor_rect.size != Vector2.ZERO and rect.grow(2.0).intersects(anchor_rect))
		if overlapping or (not use_mouse and anchor_rect.size == Vector2.ZERO):
			seen[c["node"]] = true
			list.append({"c": c, "d": origin.distance_to(rect.get_center()), "y": c["node"].global_position.y})
	if list.size() < 2:
		return false
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["d"] < b["d"] or (a["d"] == b["d"] and a["y"] > b["y"]))
	var index: int = 0
	var key_now: String = _key_of(current) if not current.is_empty() else ""
	for i in list.size():
		if _key_of(list[i]["c"]) == key_now:
			index = (i + 1) % list.size()
			break
	_cycle_key = _key_of(list[index]["c"])
	_cycle_cursor = mouse_world
	_cycle_player = player.position
	cycling = true
	current = list[index]["c"]
	return true

# The candidate chosen by Tab, while the cycle lasts (it ends when the cursor moves more than 12 px or he moves away).
func _cycle_target(candidates: Array) -> Dictionary:
	cycling = false
	if _cycle_key == "":
		return {}
	if _world_at(_mouse_screen).distance_to(_cycle_cursor) > CYCLE_CURSOR_PX or player.position.distance_to(_cycle_player) > CYCLE_PLAYER_PX:
		_cycle_key = ""
		return {}
	for c in candidates:
		if _key_of(c) == _cycle_key and player.position.distance_to(c["point"]) <= interaction_radius:
			cycling = true
			return c
	_cycle_key = ""
	return {}

# The target's outline (only a pickup the mouse is over, or one chosen by Tab, so walking about does not light things up).
func target_node() -> Node2D:
	if chooser_open and not _ch_list.is_empty():
		return _ch_list[clampi(_ch_index, 0, _ch_list.size() - 1)]["node"]
	if current.is_empty() or not _is_pickup(current) or not (_hovered or cycling):
		return null
	return current["node"]

func _update_highlight() -> void:
	var node: Node2D = target_node()
	if node == _hl_node:
		return
	if _hl_sprite != null and is_instance_valid(_hl_sprite):
		_hl_sprite.material = null
	_hl_node = node
	_hl_sprite = null
	if node != null:
		_hl_sprite = GroundPlacement.sprite_of(node)
		if _hl_sprite != null:
			if _hl_material == null:
				_hl_material = ShaderMaterial.new()
				_hl_material.shader = load("res://shaders/target_outline.gdshader")
			_hl_sprite.material = _hl_material

# E with no mouse target: the key rule prefers a pickup in front of him.
# The point an object is sorted and measured by (the base of its sprite).
func _base_of(c: Dictionary) -> Vector2:
	var node: Node2D = c["node"]
	if c.has("cell"):
		return node.cell_center(c["cell"])
	if c["kind"] == "log":
		return node.log_node().global_position
	if c["kind"] == "enter" and node.is_in_group("storages"):
		var door: Rect2 = node.door_rect_world()
		return door.position + door.size * 0.5
	return node.global_position

# The ground rectangle an object's picture covers (for hit-testing clicks).
func _area_of(c: Dictionary) -> Rect2:
	var node: Node2D = c["node"]
	var p: Vector2 = node.global_position
	if c.has("cell"):
		return node.cell_rect(c["cell"])
	# The door of a Storage (the rest of its picture is for planks and logs).
	if c["kind"] == "enter" and node.is_in_group("storages"):
		return node.door_rect_world().grow(1.0)
	if node.is_in_group("colonists"):
		return Rect2(p.x - 8.0, p.y - 18.0, 16.0, 20.0)
	if node.is_in_group("crates"):
		return Rect2(p.x - 11.0, p.y - 19.0, 22.0, 21.0)
	if node.is_in_group("trees"):
		if c["kind"] == "log":
			var trunk: Node2D = node.log_node()
			var top: Vector2 = trunk.global_position + Vector2.UP.rotated(trunk.global_rotation) * 14.0
			return Rect2(trunk.global_position, Vector2.ZERO).expand(top).grow(6.0)
		if node.is_standing():
			return Rect2(p.x - 12.0, p.y - 29.0, 24.0, 29.0)
		return Footprints.tree_rect(node)
	if node.is_in_group("pit_saws"):
		return Rect2(p.x - 16.0, p.y - 14.0, 32.0, 18.0)
	if node.is_in_group("plank_piles"):
		return Rect2(p.x - 10.0, p.y - 12.0, 20.0, 14.0)
	if node.is_in_group("saw_blades"):
		return Rect2(p.x - 4.0, p.y - 18.0, 8.0, 20.0)
	if node.is_in_group("hammers"):
		return Rect2(p.x - 5.0, p.y - 10.0, 10.0, 12.0)
	if node.is_in_group("bundle_piles"):
		return Rect2(p.x - 10.0, p.y - 17.0, 20.0, 19.0)
	if node.is_in_group("beds"):
		# The bed's picture: its drawn height (the art is 20-27 px tall), a little wider than it.
		var bed_h: float = float(BundleArt.used_height(node.sprite.texture))
		return Rect2(p.x - 12.0, p.y - bed_h, 24.0, bed_h + 2.0)
	if node.is_in_group("grass_patches"):
		return Rect2(p.x - 7.0, p.y - 12.0, 14.0, 14.0)
	if node.is_in_group("berry_bushes"):
		return Rect2(p.x - 9.0, p.y - 16.0, 18.0, 18.0)
	if node.is_in_group("baskets"):
		return Rect2(p.x - 6.0, p.y - 8.0, 12.0, 10.0)
	if node.is_in_group("ground_items"):
		return node.hover_rect()
	if node.is_in_group("toolboxes"):
		return Rect2(p.x - 12.0, p.y - 16.0, 24.0, 18.0)
	if node.is_in_group("grinding_stones") or node.is_in_group("campfires") or node.is_in_group("dough_boards") or node.is_in_group("tables"):
		return Rect2(p.x - 9.0, p.y - 16.0, 18.0, 18.0)
	if node.is_in_group("shovels"):
		return Rect2(p.x - 7.0, p.y - 8.0, 14.0, 10.0)
	if node.is_in_group("axes"):
		return Rect2(p.x - 5.0, p.y - 11.0, 10.0, 13.0)
	if node.is_in_group("buildings"):
		if node.building_type != null and node.building_type.indoor_only:
			# A wooden bed blueprint: the bed's picture.
			return Rect2(p.x - 12.0, p.y - 26.0, 24.0, 28.0)
		# The cabin picture: 31 wide, 27 tall (the door is part of it).
		return Rect2(p.x - 17.0, p.y - 28.0, 34.0, 31.0)
	if node.is_in_group("building_interiors"):
		var door_rect: Rect2 = node.exit_rect_world()
		return Rect2(door_rect.position.x - 4.0, door_rect.position.y - 18.0, door_rect.size.x + 8.0, 28.0)
	# Sawmill and Storage: their picture.
	return Footprints.blocker_rect(node)

# --- What is nearby -------------------------------------------------------------------

# Which tool lies in which group.
const TOOL_OF_GROUP: Dictionary = {"hammers": "hammer", "shovels": "shovel", "axes": "axe"}

# `priority` 2 beats 1 whatever the distance (delivering or storing a plank beats adding it to a
# pile); among equals the nearest wins.
# `mode`: "" works with E and a click; "key" only with E; "click" only with a click (a bed: E sleeps in it,
# a click breaks it up); "hover" with E or a click only on the object under the mouse (the Storage door).
func _candidate(kind: String, node, point: Vector2, text: String, anchor: Vector2, priority: int = 1, mode: String = "") -> Dictionary:
	return {"kind": kind, "node": node, "point": point, "text": text, "anchor": anchor, "priority": priority, "mode": mode}

func _find_nearest(candidates: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_dist: float = INF
	var kept: Dictionary = {}
	var kept_dist: float = INF
	var here: Vector2 = player.position
	for c in candidates:
		# ("click" ones only with a click; "hover" ones only under the mouse: E does not take the Storage door.)
		if c["mode"] == "click" or c["mode"] == "hover":
			continue
		var d: float = here.distance_to(c["point"])
		if d > interaction_radius:
			continue
		# (A pickup in front of him, the way he faces, counts as a little nearer.)
		if _is_pickup(c) and d > 0.5:
			var facing := Vector2(-1.0 if player.sprite.flip_h else 1.0, 0.0)
			d -= FACING_BONUS * maxf(0.0, facing.dot((c["point"] - here) / d))
		if _last_key != "" and _key_of(c) == _last_key:
			kept = c
			kept_dist = d
		if best.is_empty() or c["priority"] > best["priority"] or (c["priority"] == best["priority"] and d < best_dist):
			best_dist = d
			best = c
	# The one shown last time stays unless something else is clearly nearer.
	if not kept.is_empty() and kept["priority"] == best["priority"] and kept_dist <= best_dist + target_hysteresis:
		return kept
	return best

# The door of a finished Storage: "[E] Enter" while the mouse is on the door, and a click on it. (E pressed away
# from the door keeps doing the plank and log jobs of the Storage; with nothing else to do beside it, it goes in.)
func _storage_door_candidates(out: Array) -> void:
	for st in get_tree().get_nodes_in_group("storages"):
		var door: Vector2 = st.door_position()
		# (Above the stock readout.)
		var above: Vector2 = st.global_position + Vector2(0, -50)
		out.append(_candidate("enter", st, door, "", above, 3, "hover"))
		out.append(_candidate("enter", st, door, "", above, 0, "key"))

func _dig_text(pit) -> String:
	return "E / click: Dig"

# Holding the hammer, Shift turns every construction into something to dismantle (and nothing else is
# offered): Shift+E on the nearest, Shift+click on the one clicked.
func _dismantle_candidates() -> Array:
	var out: Array = []
	for node in Dismantle.all(get_tree()):
		var p: Vector2 = node.interact_point()
		out.append(_candidate("dismantle", node, p, "", p + Vector2(0, -34), 2))
	return out

# Shift with empty hands: a wooden bed with bedding on it offers to give one bundle back.
func _bedding_removal_candidates() -> Array:
	var out: Array = []
	for bed in get_tree().get_nodes_in_group("beds"):
		if bed.is_wooden() and bed.bedding_count() > 0:
			var bp: Vector2 = bed.interact_point()
			out.append(_candidate("remove_bedding", bed, bp, "", bed.global_position + Vector2(0, -BundleArt.used_height(bed.sprite.texture) - 4.0), 2))
	return out

func _candidates() -> Array:
	var out: Array = []
	if player.held_tool == &"hammer" and Input.is_key_pressed(KEY_SHIFT):
		return _dismantle_candidates()
	if Input.is_key_pressed(KEY_SHIFT) and not player.hands_occupied():
		var removal: Array = _bedding_removal_candidates()
		# A crate holding more than one kind: Shift+E picks which one empty hands take.
		for crate in get_tree().get_nodes_in_group("crates"):
			if crate.kinds_present().size() > 1:
				var cpt: Vector2 = crate.interact_point()
				removal.append(_candidate("crate_cycle", crate, cpt, "", cpt + Vector2(0, -34), 2))
		# A campfire with a stone on it: Shift+E takes the stone off.
		for fire in get_tree().get_nodes_in_group("campfires"):
			if fire.stone:
				var fp: Vector2 = fire.interact_point()
				removal.append(_candidate("campfire_take_stone", fire, fp, "", fp + Vector2(0, -34), 2))
		if not removal.is_empty():
			return removal
	if player.is_dragging():
		# Dragging a log: load it into a pit saw / Sawmill, store it, or drop it.
		var near_site: bool = false
		for pit in get_tree().get_nodes_in_group("pit_saws"):
			var p: Vector2 = pit.interact_point()
			if pit.can_dig():
				# Not dug yet: E says to put the log down first.
				out.append(_candidate("pit_dig", pit, p, _dig_text(pit), p + Vector2(0, -34)))
			else:
				out.append(_candidate("pit_load", pit, p, "E / click: Load log", p + Vector2(0, -34)))
			if player.position.distance_to(p) <= interaction_radius:
				near_site = true
		for mill in get_tree().get_nodes_in_group("sawmills"):
			var p: Vector2 = mill.interact_point()
			out.append(_candidate("sawmill_load", mill, p, "E / click: Load log", p + Vector2(0, -34)))
			if player.position.distance_to(p) <= interaction_radius:
				near_site = true
		for st in get_tree().get_nodes_in_group("storages"):
			var p: Vector2 = st.interact_point()
			out.append(_candidate("store_log", st, p, "E / click: Store log", p + Vector2(0, -34)))
			if player.position.distance_to(p) <= interaction_radius:
				near_site = true
		if player.swap_on_pickup:
			_swap_candidates(out)
		if not near_site:
			# The fallback: anything else within reach (picking it up) beats it.
			out.append(_candidate("drop", null, player.position, "E: Drop log", player.position + Vector2(0, -22), 0))
		for fire in get_tree().get_nodes_in_group("campfires"):
			var fuel_p: Vector2 = fire.interact_point()
			out.append(_candidate("campfire_fuel", fire, fuel_p, "", fuel_p + Vector2(0, -34), 2))
			if player.position.distance_to(fuel_p) <= interaction_radius:
				near_site = true
		# A house: with a log in tow he cannot go in (the message says so).
		for house in get_tree().get_nodes_in_group("buildings"):
			if house.state == house.State.BUILT and house.capacity > 0:
				out.append(_candidate("enter", house, house.door_position(), "", house.global_position + Vector2(0, -34)))
		_storage_door_candidates(out)
		return out
	var carrying: bool = player.carrying_planks > 0
	var holding_blade: bool = player.carrying_blade
	_plot_candidates(out)
	_water_candidates(out)
	_colonist_candidates(out)
	for tree in get_tree().get_nodes_in_group("trees"):
		if tree.is_standing():
			out.append(_candidate("tree", tree, tree.position, "E / click: Chop", tree.position + Vector2(0, -36)))
		elif tree.is_felled():
			out.append(_candidate("tree", tree, tree.position, "E / click: Delimb", tree.position + Vector2(0, -20)))
		elif tree.is_delimbed() and tree.log_node() != null:
			var trunk: Node2D = tree.log_node()
			var middle: Vector2 = trunk.global_position + Vector2.UP.rotated(trunk.global_rotation) * 7.0
			out.append(_candidate("log", tree, middle, "E / click: Take log", middle + Vector2(0, -16)))
	for pit in get_tree().get_nodes_in_group("pit_saws"):
		var p: Vector2 = pit.interact_point()
		if pit.can_dig():
			out.append(_candidate("pit_dig", pit, p, _dig_text(pit), p + Vector2(0, -34)))
		elif pit.can_saw():
			# A log is waiting: it saws it (the planks wait until it is done).
			out.append(_candidate("pit_saw", pit, p, "E / click: Saw", p + Vector2(0, -34)))
		if not pit.is_built():
			# Hand over the plank / blade in his hands, but only while the pit still needs it
			# (otherwise holding it does not get in the way of digging or hammering).
			var offered: bool = false
			if carrying and pit.planks_missing() > 0:
				out.append(_candidate("pit_add_plank", pit, p, "E / click: Add plank", p + Vector2(0, -34), 2))
				offered = true
			if holding_blade and pit.blades_missing() > 0:
				out.append(_candidate("pit_add_blade", pit, p, "E / click: Add saw blade", p + Vector2(0, -34), 2))
				offered = true
			# Empty hands, before the first build hit: the delivered plank / blade can be taken back.
			if not player.hands_occupied():
				if pit.can_take_back_plank():
					out.append(_candidate("pit_take_plank", pit, p, "", p + Vector2(0, -34)))
				elif pit.can_take_back_blade():
					out.append(_candidate("pit_take_blade", pit, p, "", p + Vector2(0, -34)))
			if pit.ready_to_build():
				out.append(_candidate("pit_hammer", pit, p, "E / click: Hammer", p + Vector2(0, -34)))
			elif pit.needs_materials() and not offered:
				out.append(_candidate("pit_needs", pit, p, pit.missing_text(), p + Vector2(0, -34)))
	# Planks, one at a time. Empty hands: take one from the Sawmill's output, a pile on the
	# ground (not one the Hauler has claimed) or the Storage. With a plank: store it, or add it
	# to a pile that has room (delivering / storing beat adding to a pile).
	for mill in get_tree().get_nodes_in_group("sawmills"):
		if not carrying and mill.planks_ready > 0:
			var p: Vector2 = mill.interact_point()
			out.append(_candidate("take_plank", mill, p, "E / click: Take plank", p + Vector2(0, -34)))
	for st in get_tree().get_nodes_in_group("storages"):
		var p: Vector2 = st.interact_point()
		if carrying:
			if st.plank_room() > 0:
				out.append(_candidate("store_plank", st, p, "E / click: Store plank", p + Vector2(0, -34), 2))
		elif st.planks_stored > 0:
			out.append(_candidate("take_plank", st, p, "E / click: Take plank", p + Vector2(0, -34)))
	for pile in get_tree().get_nodes_in_group("plank_piles"):
		var p: Vector2 = pile.global_position
		if carrying:
			if not pile.is_full():
				out.append(_candidate("add_to_pile", pile, p, "E / click: Add to pile", p + Vector2(0, -26)))
		elif pile.available() > 0:
			out.append(_candidate("take_plank", pile, p, "E / click: Take plank", p + Vector2(0, -26)))
	for blade in get_tree().get_nodes_in_group("saw_blades"):
		var p: Vector2 = blade.interact_point()
		out.append(_candidate("take_blade", blade, p, "E / click: Take saw blade", p + Vector2(0, -22)))
	_tool_candidates(out)
	# The toolbox: E opens it with empty hands, puts away a tool or accepted item in the hands, closes it when it is open.
	for box in get_tree().get_nodes_in_group("toolboxes"):
		if box.is_carried():
			continue
		var xp: Vector2 = box.interact_point()
		var xa: Vector2 = xp + Vector2(0, -30)
		# (E on it ALWAYS opens its panel, whatever is in the hands; the panel has a "Put away" button.)
		out.append(_candidate("toolbox_close" if box.is_open else "toolbox_open", box, xp, "", xa, 2))
	# Piles of bundles: with a bundle in hand it joins the pile (the third makes a bed); otherwise he takes one.
	for pile in get_tree().get_nodes_in_group("bundle_piles"):
		var pp: Vector2 = pile.interact_point()
		if player.held_tool == &"bundle":
			if not pile.is_full():
				out.append(_candidate("add_bundle", pile, pp, "", pp + Vector2(0, -20)))
		else:
			out.append(_candidate("take_bundle_pile", pile, pp, "", pp + Vector2(0, -20)))
	# Grinding stone and campfire.
	for q in get_tree().get_nodes_in_group("grinding_stones"):
		var qp: Vector2 = q.interact_point()
		var qa: Vector2 = qp + Vector2(0, -34)
		if player.held_tool == &"wheat_sheaf":
			out.append(_candidate("grinding_stone_add", q, qp, "", qa, 2))
		elif not player.hands_occupied():
			out.append(_candidate("grinding_stone_take" if q.flour_out > 0 else "grinding_stone_grind", q, qp, "", qa, 2))
	if player.hands_occupied() and player.table_takes(player.held_tool):
		for table in get_tree().get_nodes_in_group("tables"):
			if table.has_room():
				var tp: Vector2 = table.interact_point()
				out.append(_candidate("table_put", table, tp, "", tp + Vector2(0, -34), 1))
	for board in get_tree().get_nodes_in_group("dough_boards"):
		var bp: Vector2 = board.interact_point()
		var ba: Vector2 = bp + Vector2(0, -34)
		match player.held_tool:
			&"flour":
				out.append(_candidate("board_flour", board, bp, "", ba, 2))
			&"bucket":
				out.append(_candidate("board_water", board, bp, "", ba, 2))
			&"":
				if not player.hands_occupied():
					# Dough first; both flour and water: knead; otherwise the board itself is picked up.
					var board_kind: String = "board_take" if board.dough else ("board_knead" if (board.has_flour and board.has_water) else "board_pickup")
					out.append(_candidate(board_kind, board, bp, "", ba, 2))
	for fire in get_tree().get_nodes_in_group("campfires"):
		var fp: Vector2 = fire.interact_point()
		var fa: Vector2 = fp + Vector2(0, -34)
		match player.held_tool:
			&"fire_starter":
				out.append(_candidate("campfire_spark", fire, fp, "", fa, 2))
			&"flat_stone":
				out.append(_candidate("campfire_stone", fire, fp, "", fa, 2))
			&"flour", &"dough":
				out.append(_candidate("campfire_bake", fire, fp, "", fa, 2))
			&"branch":
				out.append(_candidate("campfire_fuel", fire, fp, "", fa, 2))
		if player.carrying_planks > 0:
			out.append(_candidate("campfire_fuel", fire, fp, "", fa, 2))
		if not player.hands_occupied() and not fire.food.is_empty():
			out.append(_candidate("campfire_take_food", fire, fp, "", fa, 2))
	# Berry bushes: with the basket in hand E picks a berry (the message says if there is no basket / it is full).
	for bush in get_tree().get_nodes_in_group("berry_bushes"):
		if bush.is_ripe() and (bush.claimed_by == null or bush.claimed_by == player):
			var bsp: Vector2 = bush.interact_point()
			out.append(_candidate("pick", bush, bsp, "", bsp + Vector2(0, -20)))
	# Tall grass he can pull (no tool needed, but empty hands).
	for patch in get_tree().get_nodes_in_group("grass_patches"):
		if patch.is_tall() and (patch.claimed_by == null or patch.claimed_by == player):
			var gp: Vector2 = patch.interact_point()
			out.append(_candidate("pull", patch, gp, "", gp + Vector2(0, -22)))
	# Beds. E with empty hands sleeps in one. A grass / hay bed: a click breaks it up (empty hands, two presses).
	# A wooden bed: a bundle in hand is added to its bedding (E or a click), and Shift+E / Shift+click with empty
	# hands takes one off.
	for bed in get_tree().get_nodes_in_group("beds"):
		var bp: Vector2 = bed.interact_point()
		var above: Vector2 = bed.global_position + Vector2(0, -BundleArt.used_height(bed.sprite.texture) - 4.0)
		if bed.is_wooden():
			if player.held_tool == &"bundle":
				out.append(_candidate("add_bedding", bed, bp, "", above, 2))
			elif not player.hands_occupied():
				out.append(_candidate("sleep_bed", bed, bp, "", above, 2, "key"))
		elif not player.hands_occupied():
			out.append(_candidate("sleep_bed", bed, bp, "", above, 2, "key"))
			out.append(_candidate("break_bed", bed, bp, "", above, 2, "click"))
	# A finished house, at its door: with empty hands he can sleep in it.
	# In the room: the door leads out, and empty ground is a place to sleep.
	if player.inside_building != null:
		var room: Node2D = player.inside_building.get_interior()
		var exit_point: Vector2 = room.exit_point_world()
		out.append(_candidate("leave", room, exit_point, "", exit_point + Vector2(0, -22)))
		if not player.hands_occupied():
			out.append(_candidate("sleep_floor", null, player.position, "", player.position + Vector2(0, -24), 0))
	else:
		# A finished house: E or a click on the door or the house goes in (walking to the door first).
		for house in get_tree().get_nodes_in_group("buildings"):
			if house.state != house.State.BUILT or house.capacity <= 0:
				continue
			var door: Vector2 = house.door_position()
			out.append(_candidate("enter", house, door, "", house.global_position + Vector2(0, -34)))
		_storage_door_candidates(out)
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.state == b.State.BUILT:
			continue
		var p: Vector2 = b.interact_point()
		if carrying and b.planks_needed() > 0:
			out.append(_candidate("deliver_plank", b, p, "E / click: Deliver plank", b.global_position + Vector2(0, -44), 2))
		elif Items.is_item(player.held_tool) and b.needs_material(player.held_tool):
			out.append(_candidate("deliver_material", b, p, "", b.global_position + Vector2(0, -44), 2))
		elif not player.hands_occupied() and b.can_take_back():
			# Before the first hammer hit, empty hands take a delivered plank back out.
			out.append(_candidate("take_back_plank", b, p, "", b.global_position + Vector2(0, -44)))
		elif not player.hands_occupied() and b.can_cancel():
			out.append(_candidate("cancel_blueprint", b, p, "", b.global_position + Vector2(0, -44)))
		else:
			out.append(_candidate("hammer", b, p, "E / click: Hammer", b.global_position + Vector2(0, -44)))
	# Crates (inside a building): berries in, berries out.
	for crate in get_tree().get_nodes_in_group("crates"):
		var cp: Vector2 = crate.interact_point()
		out.append(_candidate("crate_use", crate, cp, "", crate.global_position + Vector2(0, -34)))
	# With berries in the basket, E on empty ground eats one (anything nearer to act on wins).
	if (player.held_tool == &"basket" and player.basket_berries > 0) or player.held_tool == &"berry" or player.held_tool == &"flatbread":
		out.append(_candidate("eat", null, player.position, "", player.position + Vector2(0, -24), 0))
	# With the hammer in hand, a finished construction says how to take it apart.
	if player.held_tool == &"hammer":
		for node in Dismantle.all(get_tree()):
			if node.is_in_group("buildings") and node.state != node.State.BUILT:
				continue
			if node.is_in_group("pit_saws") and not node.is_built():
				continue
			var hp: Vector2 = node.interact_point()
			out.append(_candidate("dismantle_hint", node, hp, "", hp + Vector2(0, -34), 0))
	return out

# The tools lying on the ground (the hammer, the shovel and the axe).
func _tool_candidates(out: Array) -> void:
	for item in get_tree().get_nodes_in_group("ground_items"):
		var ip: Vector2 = item.interact_point()
		var ia: Vector2 = ip + Vector2(0, -16)
		# A seed bag in his hands and another on the ground: E moves its seeds in (before swapping).
		if player.held_tool == &"seed_bag" and item.kind == &"seed_bag" and item.seeds > 0:
			out.append(_candidate("merge_seeds", item, ip, "", ia, 2))
		# A seed bag in his hands and a wheat sheaf (on the ground or a table): E threshes it into the bag (before swapping).
		if player.held_tool == &"seed_bag" and item.kind == &"wheat_sheaf":
			out.append(_candidate("thresh", item, ip, "", ia, 2))
		out.append(_candidate("take_item", item, ip, "", ia))
	for basket in get_tree().get_nodes_in_group("baskets"):
		var bp: Vector2 = basket.interact_point()
		out.append(_candidate("take_basket", basket, bp, "", bp + Vector2(0, -16)))
	for tool_group in ["hammers", "shovels", "axes"]:
		for item in get_tree().get_nodes_in_group(tool_group):
			var p: Vector2 = item.interact_point()
			var tool_name: String = TOOL_OF_GROUP[tool_group]
			out.append(_candidate("take_" + tool_name, item, p, "E / click: Take " + tool_name, p + Vector2(0, -16)))

# While he drags a log (swap_on_pickup): everything he could pick up instead, which puts the log
# down first.
func _swap_candidates(out: Array) -> void:
	for pile in get_tree().get_nodes_in_group("plank_piles"):
		if pile.available() > 0:
			var p: Vector2 = pile.global_position
			out.append(_candidate("take_plank", pile, p, "E / click: Take plank", p + Vector2(0, -26)))
	for mill in get_tree().get_nodes_in_group("sawmills"):
		if mill.planks_ready > 0:
			var p: Vector2 = mill.interact_point()
			out.append(_candidate("take_plank", mill, p, "E / click: Take plank", p + Vector2(0, -34)))
	for st in get_tree().get_nodes_in_group("storages"):
		if st.planks_stored > 0:
			var p: Vector2 = st.interact_point()
			out.append(_candidate("take_plank", st, p, "E / click: Take plank", p + Vector2(0, -34)))
	for blade in get_tree().get_nodes_in_group("saw_blades"):
		var p: Vector2 = blade.interact_point()
		out.append(_candidate("take_blade", blade, p, "E / click: Take saw blade", p + Vector2(0, -22)))
	_tool_candidates(out)
	for pile in get_tree().get_nodes_in_group("bundle_piles"):
		var gp: Vector2 = pile.interact_point()
		out.append(_candidate("take_bundle_pile", pile, gp, "", gp + Vector2(0, -20)))
	for tree in get_tree().get_nodes_in_group("trees"):
		if tree != player.drag_tree and tree.is_delimbed() and tree.log_node() != null:
			var trunk: Node2D = tree.log_node()
			var middle: Vector2 = trunk.global_position + Vector2.UP.rotated(trunk.global_rotation) * 7.0
			out.append(_candidate("log", tree, middle, "E / click: Take log", middle + Vector2(0, -16)))

# --- Doing it -------------------------------------------------------------------------

# The one place an action is carried out: E and click both come here.
func _do(c: Dictionary) -> void:
	var kind: String = c["kind"]
	var session_kinds: Array = ["tree", "pit_dig", "hammer", "pit_hammer", "pull", "break_bed", "dismantle", "pick"]
	if not session_kinds.has(kind) and player.is_chopping_session():
		# Another kind of job: not while a swing is playing; otherwise he lets the work go.
		if player.state == player.State.CHOPPING:
			return
		player.end_chop_session()
	var msg: String = ""
	match kind:
		"tree":
			msg = player.request_chop(c["node"])
		"pit_dig":
			msg = player.request_dig(c["node"])
		"hammer":
			msg = player.request_hammer(c["node"])
		"pit_hammer":
			msg = player.request_hammer_pit(c["node"])
		"log":
			if player.hands_occupied() and not player.swap_on_pickup:
				msg = "Your hands are full"
			elif not player.start_take_log(c["node"]):
				msg = "Someone else is taking this log"
			else:
				# Whatever he held goes down at his feet (nothing when his hands were empty).
				player.put_down_for_swap()
		"drop":
			player.drop_log()
		"pit_load":
			var pit = c["node"]
			if not player.load_log_into(pit):
				msg = pit.load_refusal()
		"sawmill_load":
			if not player.load_log_into(c["node"]):
				msg = "The sawmill is full"
		"store_log":
			if not player.store_log_in(c["node"]):
				msg = "No room for logs in the storage"
		"pit_saw":
			if player.carrying_planks > 0:
				msg = "Press Q to put the plank down"
			elif player.carrying_blade:
				msg = "Press Q to put the saw blade down"
			elif player.held_tool != &"":
				msg = "Press Q to put the %s down" % player.held_tool
			else:
				msg = c["node"].request_saw(player)
		"take_plank":
			if player.hands_occupied() and not player.swap_on_pickup:
				msg = "Your hands are full"
			else:
				player.take_plank_from(c["node"])
		"take_blade":
			msg = player.take_blade(c["node"])
		"take_hammer":
			msg = player.take_tool(c["node"], &"hammer")
		"take_shovel":
			msg = player.take_tool(c["node"], &"shovel")
		"take_axe":
			msg = player.take_tool(c["node"], &"axe")
		"pit_add_plank":
			msg = player.deliver_plank_to_pit(c["node"])
		"pit_add_blade":
			msg = player.deliver_blade_to_pit(c["node"])
		"pit_needs":
			msg = c["node"].missing_text()
		"enter":
			msg = player.request_enter(c["node"])
		"leave":
			msg = player.request_leave()
		"crate_use":
			msg = player.use_crate(c["node"])
		"crate_cycle":
			msg = player.crate_cycle(c["node"])
		"sleep_floor":
			msg = player.request_sleep_outside()
		"pull":
			msg = player.request_pull(c["node"])
		"take_bundle_pile":
			msg = player.take_bundle_from(c["node"])
		"add_bundle":
			msg = player.add_bundle_to_pile(c["node"])
		"sleep_bed":
			msg = player.request_sleep_on(c["node"])
		"break_bed":
			msg = player.request_bed_break(c["node"])
		"add_bedding":
			msg = player.add_bedding_to(c["node"])
		"remove_bedding":
			msg = player.remove_bedding_from(c["node"])
		"take_back_plank":
			msg = player.take_back_plank_from(c["node"])
		"cancel_blueprint":
			msg = player.cancel_blueprint(c["node"])
		"pit_take_plank":
			msg = player.take_back_from_pit(c["node"], &"plank")
		"pit_take_blade":
			msg = player.take_back_from_pit(c["node"], &"blade")
		"dismantle":
			msg = player.request_dismantle(c["node"])
		"take_basket":
			msg = player.take_basket(c["node"])
		"take_item":
			msg = player.take_item(c["node"])
		"deliver_material":
			msg = player.deliver_material(c["node"])
		"grinding_stone_add":
			msg = player.grinding_stone_add(c["node"])
		"grinding_stone_grind", "grinding_stone_take":
			msg = player.grinding_stone_press(c["node"])
		"campfire_fuel":
			msg = player.campfire_fuel(c["node"])
		"campfire_spark":
			msg = player.campfire_spark(c["node"])
		"campfire_stone":
			msg = player.campfire_place_stone(c["node"])
		"campfire_take_stone":
			msg = player.campfire_take_stone(c["node"])
		"campfire_bake":
			msg = player.campfire_place_dough(c["node"])
		"campfire_take_food":
			msg = player.campfire_take_food(c["node"])
		"scoop":
			msg = player.scoop_water(c["cell"])
		"plot_water":
			msg = player.plot_water(c["cell"])
		"board_flour":
			msg = player.board_flour(c["node"])
		"board_water":
			msg = player.board_water(c["node"])
		"board_knead", "board_take":
			msg = player.board_press(c["node"])
		"board_pickup":
			msg = player.take_board(c["node"])
		"table_put":
			msg = player.table_put(c["node"])
		"toolbox_open":
			c["node"].open_for(player)
		"toolbox_close":
			c["node"].close()

		"plot_till":
			msg = player.plot_till(c["cell"])
		"plot_sow":
			msg = player.plot_sow(c["cell"])
		"plot_harvest":
			msg = player.plot_harvest(c["cell"])
		"merge_seeds":
			msg = player.merge_seeds_from(c["node"])
		"thresh":
			msg = player.thresh_sheaf(c["node"])
		"talk":
			msg = c["node"].talk(player)
		"pick":
			msg = player.request_pick(c["node"])
		"eat":
			msg = player.request_eat()
		"dismantle_hint":
			msg = "Hold Shift and press E (or click) to dismantle it"
		"deliver_plank":
			if player.supplies_locked():
				msg = "Build the pit saw first"
			else:
				player.deliver_plank(c["node"])
		"store_plank":
			if player.supplies_locked():
				msg = "Build the pit saw first"
			else:
				player.store_plank(c["node"])
		"add_to_pile":
			player.add_plank_to_pile(c["node"])
	_last_msg = msg
	if msg != "":
		show_message(msg)
		# A refusal ends a hold: it would only say the same thing again and again.
		_end_hold()

# --- The E chooser --------------------------------------------------------------------------------------------------------
# E with no mouse target and two or more doable ACTIONS (see actions.gd) among the candidates within chooser_radius_px of the best
# one (several things, or several actions on one thing): a small themed list opens beside him, one row per action ("Chop Tree
# (Axe)", "Pick up Branch" ...), in the default order (the nearest thing to the cursor / his feet, then a tool-using action before a
# plain pick-up, then verb_priority), the first row selected and its target outlined in the world. Actions that exist but cannot be
# done now (no axe in the hands) are greyed at the bottom with the reason. W / S, Up / Down or the wheel move the selection, E, Enter
# or a click on a row does it, a quick second E does the top row, Esc (or walking away) closes it. Exactly one doable action is just
# done. While it is open hold-to-repeat is paused, and it carries on after a work action is chosen (E still held).

var chooser_open: bool = false
# The doable actions (the selectable rows), and the greyed ones below them.
var _ch_list: Array = []
var _ch_disabled: Array = []
var _ch_index: int = 0
var _ch_player_pos: Vector2 = Vector2.ZERO
var _ch_opened_at: float = -10.0
var _ch_root: Control = null
var _ch_rows: Array = []
var _ch_registered: bool = false

# The actions E would choose between ([] = nothing to choose: just act): every supported candidate in reach within chooser_radius_px of
# the best one, as actions, in the default order (doable ones first). The mouse is never asked: a target under the cursor is acted on.
func _chooser_actions() -> Array:
	if _hovered or current.is_empty() or not Actions.supported(current):
		return []
	var best_centre: Vector2 = Actions.centre_of(current)
	var here: Vector2 = player.position
	var list: Array = []
	var seen: Dictionary = {}
	for c in _candidates():
		if not Actions.supported(c) or c["mode"] == "click" or c["mode"] == "hover":
			continue
		# (Talking to a colonist joins a choice only beside an item: next to a tree or a plot he does not get in the way of the work.)
		if c["kind"] == "talk" and not _is_pickup(current) and current["kind"] != "talk":
			continue
		if here.distance_to(c["point"]) > interaction_radius:
			continue
		var same: bool = c["node"] == current["node"] and c["kind"] == current["kind"]
		if not same and Actions.centre_of(c).distance_to(best_centre) > chooser_radius_px:
			continue
		var k: String = _key_of(c)
		if seen.has(k):
			continue
		seen[k] = true
		list.append_array(Actions.get_actions(self, player, c))
	# The same action on several things of one kind is ONE choice: the closest instance stands for them all.
	var reference: Vector2 = _order_reference()
	var facing := Vector2(-1.0 if player.sprite.flip_h else 1.0, 0.0)
	for a in list:
		var d: float = reference.distance_to(a["centre"])
		if reference == player.position and d > 0.5 and _is_pickup(a["candidate"]):
			d -= FACING_BONUS * maxf(0.0, facing.dot((a["centre"] - reference) / d))
		a["score"] = d
	list = Actions.merge_duplicates(list)
	return Actions.sort_actions(list, reference, chooser_tolerance_px)

# What the order measures from: the cursor while it moved lately, else his feet.
func _order_reference() -> Vector2:
	if _mouse_moved_at > -999.0 and _now() - _mouse_moved_at <= hover_seconds:
		return _world_at(_mouse_screen)
	return player.position

func _open_chooser(list: Array) -> void:
	chooser_open = true
	_ch_list = Actions.enabled_of(list)
	_ch_disabled = list.filter(func(a: Dictionary) -> bool: return not a["enabled"])
	_ch_index = 0
	_ch_player_pos = player.position
	_ch_opened_at = _now()
	_end_hold()
	if not _ch_registered:
		_ch_registered = true
		Ui.register_closable(Callable(self, "is_chooser_open"), Callable(self, "close_chooser"))
	Ui.sfx("ui_open")
	_build_chooser()

func is_chooser_open() -> bool:
	return chooser_open

func close_chooser() -> void:
	if not chooser_open:
		return
	chooser_open = false
	_ch_list = []
	_ch_disabled = []
	if is_instance_valid(_ch_root):
		_ch_root.queue_free()
	_ch_root = null
	_ch_rows.clear()

func _chooser_confirm(source: String = "key") -> void:
	if _ch_list.is_empty():
		close_chooser()
		return
	var chosen: Dictionary = _ch_list[clampi(_ch_index, 0, _ch_list.size() - 1)]
	close_chooser()
	Ui.sfx("ui_click")
	var c: Dictionary = chosen["candidate"]
	if not c.has("cell") and (chosen["node"] == null or not is_instance_valid(chosen["node"])):
		return
	current = c
	_hovered = false
	_do(c)
	# (A work action carries on while the key or the button stays down: this press is the start of a hold session.)
	_begin_hold(c, source, true)

# The selected action (its "node", "kind" and "candidate" say what it is), or {}.
func chooser_selected() -> Dictionary:
	if not chooser_open or _ch_list.is_empty():
		return {}
	return _ch_list[clampi(_ch_index, 0, _ch_list.size() - 1)]

# Keys and wheel while it is open. Returns true when the event was used.
func _chooser_input(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed:
		var step: int = 0
		match event.keycode:
			KEY_W, KEY_UP:
				step = -1
			KEY_S, KEY_DOWN:
				step = 1
			KEY_ENTER, KEY_KP_ENTER:
				get_viewport().set_input_as_handled()
				if not event.echo:
					_chooser_confirm()
				return true
		if step != 0:
			get_viewport().set_input_as_handled()
			if not event.echo:
				_chooser_step(step)
			return true
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			get_viewport().set_input_as_handled()
			_chooser_step(-1)
			return true
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			get_viewport().set_input_as_handled()
			_chooser_step(1)
			return true
	return false

func _chooser_step(step: int) -> void:
	if _ch_list.is_empty():
		return
	_ch_index = (_ch_index + step + _ch_list.size()) % _ch_list.size()
	Ui.sfx("ui_hover")
	_refresh_chooser()

# Every frame: the selection is the current target; it closes when he walks away or the things are gone.
func _chooser_tick() -> void:
	if not chooser_open:
		return
	var alive: Array = []
	for c in _ch_list:
		if c["node"] != null and is_instance_valid(c["node"]) and not c["node"].is_queued_for_deletion():
			alive.append(c)
	if alive.size() != _ch_list.size():
		_ch_disabled = _ch_disabled.filter(func(a: Dictionary) -> bool: return a["node"] != null and is_instance_valid(a["node"]))
		_ch_list = alive
		_ch_index = mini(_ch_index, maxi(0, _ch_list.size() - 1))
		_build_chooser()
	if _ch_list.is_empty() or player.position.distance_to(_ch_player_pos) > 20.0 or not (player.is_free() or player.is_chopping_session()):
		close_chooser()
		return
	current = _ch_list[_ch_index]["candidate"]
	_hovered = false
	if is_instance_valid(_ch_root):
		_place_chooser()

func _build_chooser() -> void:
	if is_instance_valid(_ch_root):
		_ch_root.queue_free()
	_ch_rows.clear()
	_ch_root = Control.new()
	_ch_root.name = "EChooser"
	_ch_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ch_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.menu_root.add_child(_ch_root)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = &"DarkPanel"
	_ch_root.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Ui.px(4))
	panel.add_child(column)
	var title := Label.new()
	title.text = "Do what?"
	title.theme_type_variation = &"BrassLabel"
	column.add_child(title)
	var all_rows: Array = _ch_list + _ch_disabled
	for i in all_rows.size():
		var action: Dictionary = all_rows[i]
		var doable: bool = action["enabled"]
		var row := PanelContainer.new()
		row.theme_type_variation = &"SlotPanel"
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if doable else Control.CURSOR_ARROW
		if doable:
			row.gui_input.connect(_on_chooser_row.bind(i))
			row.mouse_entered.connect(func() -> void:
				if _ch_index != i:
					_ch_index = i
					_refresh_chooser())
		else:
			row.modulate = Color(1, 1, 1, 0.5)
			row.gui_input.connect(_on_chooser_disabled_row.bind(i - _ch_list.size()))
		column.add_child(row)
		var box := HBoxContainer.new()
		box.add_theme_constant_override("separation", Ui.px(8))
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(box)
		var holder := Control.new()
		holder.custom_minimum_size = Vector2(Ui.px(34), Ui.px(30))
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(holder)
		var icon := TextureRect.new()
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		var tex: Texture2D = _chooser_icon(action["node"])
		icon.texture = tex
		if tex != null:
			var factor: float = float(maxi(1, floori(minf(holder.custom_minimum_size.x / tex.get_width(), holder.custom_minimum_size.y / tex.get_height()))))
			icon.size = tex.get_size() * factor
			icon.position = ((holder.custom_minimum_size - icon.size) * 0.5).round()
		holder.add_child(icon)
		var texts := VBoxContainer.new()
		texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
		texts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		texts.add_theme_constant_override("separation", 0)
		box.add_child(texts)
		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.text = Actions.label_of(action)
		texts.add_child(name_label)
		if not doable:
			var why := Label.new()
			why.mouse_filter = Control.MOUSE_FILTER_IGNORE
			why.theme_type_variation = &"DimLabel"
			why.add_theme_font_size_override("font_size", Ui.font_size("small"))
			why.text = action["disabled_reason"]
			texts.add_child(why)
		_ch_rows.append(row)
	_refresh_chooser()

func _chooser_icon(node) -> Texture2D:
	if node == null or not node is Node2D:
		return null
	var sprite: Node2D = GroundPlacement.sprite_of(node)
	var texture: Texture2D = null
	if sprite is Sprite2D:
		texture = sprite.texture
	if texture == null:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = Rect2(GroundPlacement.used_rect(texture))
	return atlas

func _on_chooser_row(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_ch_index = index
		_chooser_confirm("mouse")

# A click on a greyed row says why it cannot be done (the list stays open).
func _on_chooser_disabled_row(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and index >= 0 and index < _ch_disabled.size():
		show_message(_ch_disabled[index]["disabled_reason"])

func _refresh_chooser() -> void:
	for i in _ch_rows.size():
		_ch_rows[i].theme_type_variation = &"SlotPanelSelected" if i == _ch_index and i < _ch_list.size() else &"SlotPanel"

# Beside him, in screen space, kept inside the window.
func _place_chooser() -> void:
	var panel: Control = _ch_root.get_node_or_null("Panel")
	if panel == null:
		return
	panel.reset_size()
	var size: Vector2 = panel.get_combined_minimum_size()
	panel.size = size
	var at: Vector2 = Ui.to_screen(get_viewport(), player.global_position + Vector2(14, -22))
	var pos: Vector2 = Ui.snap(at + Vector2(float(Ui.px(12)), -size.y * 0.5))
	var screen: Vector2 = Ui.screen_size()
	pos.x = clampf(pos.x, 6.0, maxf(6.0, screen.x - size.x - 6.0))
	pos.y = clampf(pos.y, 6.0, maxf(6.0, screen.y - size.y - 6.0))
	panel.position = pos

# The outlined item while the chooser is open is its selection (Interaction.target_node).
