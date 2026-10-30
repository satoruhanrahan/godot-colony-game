extends Node2D

# The starting toolbox: a solid, y-sorted chest near the cabin that holds the tools (hammer, shovel, axe, hoe, sickle, fire
# starter) instead of them lying about. TODO: it could become a BuildingType (a build-menu entry) later; for now it is only placed
# at the start of the game, it cannot be dismantled and is not in the build menu.
#
#  - E on it ALWAYS opens a themed panel (title "Toolbox"), whatever is in the hands, listing the contents as framed slots (the
#    item's sprite, its name and count, its number). Click a slot, or press its number, to take that item: it goes to the hands
#    exactly as if it had been picked up (equipped), with a tool or accepted item already in the hands it is a SWAP (the chosen one
#    is taken, the old one goes into the box), and the panel CLOSES by itself.
#  - While an accepted item is in the hands the panel has a button at the bottom, "Put away [item]", that stores it (the panel
#    stays open). Only the kinds in `accepts` (every tool plus the basket, the bucket and the seed bag) go in: anything else is
#    not offered.
#  - A themed X button in the top-right corner of the panel closes it.
#  - The lid shows toolbox_open.png while the panel is open (toolbox_open / toolbox_close sounds). The panel does not pause the
#    game. It closes with Esc, E again, a click outside it, or by walking more than close_distance_px (3 tiles) away.
#  - "Move Toolbox" (the generic two_person_carry flag, on for this object only): the player and the friend lift it and carry it
#    to a new spot together (see carry_together.gd for the whole description). The button is greyed with the reason when it
#    cannot be done (hands full, no friend, the friend asleep / indoors / too tired or hungry).
#  - The contents are this object's own state (`contents`: kind, amount (seeds, scoops, berries) and count), set by whoever
#    places it (init_contents). Colonists and workers keep their own tools and never look at it.

const Items = preload("res://scripts/items.gd")
const GroundPlacement = preload("res://scripts/ground_placement.gd")
const TOOL_KINDS: Array[StringName] = [&"hammer", &"shovel", &"axe", &"hoe", &"sickle", &"fire_starter"]
const ICONS: Dictionary = {
	&"hammer": "res://sprites/hammer.png", &"shovel": "res://sprites/shovel.png", &"axe": "res://sprites/axe.png",
	&"basket": "res://sprites/basket.png",
}
const NAMES: Dictionary = {&"hammer": "Hammer", &"shovel": "Shovel", &"axe": "Axe", &"basket": "Basket"}

@export var accepts: Array[StringName] = [&"hammer", &"shovel", &"axe", &"hoe", &"sickle", &"fire_starter", &"basket", &"bucket", &"seed_bag"]
@export var toolbox_capacity: int = 16
@export var close_distance_px: float = 96.0
@export var closed_texture: Texture2D
@export var open_texture: Texture2D
# Carrying it with the friend (generic: any object with this flag could be moved by two; only the toolbox has it on).
@export var two_person_carry: bool = true
@export var carry_helper_timeout_seconds: float = 15.0
@export var carry_together_speed_multiplier: float = 0.7
# The carriers stand at the two short ends of the box (its long axis is horizontal), in every direction of travel: each is
# carry_end_offset_px() from the box centre (half the box width + carry_end_gap_px), level with it (carry_end_vertical_px off).
@export var carry_end_gap_px: float = 3.0
@export var carry_end_vertical_px: float = 0.0
@export var carry_together_drain_multiplier: float = 1.5
@export var carry_tether_px: float = 48.0
@export var carry_place_reach_px: float = 48.0
# The friend is too worn out / hungry to start or go on below this (energy or hunger), and gives up when stuck this long.
@export var carry_min_condition: float = 15.0
@export var carry_stuck_seconds: float = 5.0
# How high the box hangs above the ground while carried (px), and how close the player must be to lift it.
@export var carry_lift_px: float = 5.0

# [{kind, amount, count}]: a tool stacks (count), a basket / bucket / seed bag is an entry of its own with what it holds.
var contents: Array[Dictionary] = []
var init_contents: Array = []
var is_open: bool = false
# The CarryTogether that has it lifted (null: it stands on the ground).
var carrier: Node = null
# How the last move ended (the message the player saw).
var last_carry_end: String = ""

@onready var sprite: Sprite2D = $Sprite

var _root: Control
var _panel: PanelContainer
var _close_button: Button
var _put_button: Button
var _move_button: Button
var _move_reason: Label
var _slot_nodes: Array = []

func _ready() -> void:
	add_to_group("toolboxes")
	add_to_group("build_blockers")
	if closed_texture == null and ResourceLoader.exists("res://sprites/toolbox.png"):
		closed_texture = load("res://sprites/toolbox.png")
	if open_texture == null and ResourceLoader.exists("res://sprites/toolbox_open.png"):
		open_texture = load("res://sprites/toolbox_open.png")
	if closed_texture != null:
		sprite.texture = closed_texture
	for entry in init_contents:
		add_item(entry[0], entry[1] if entry.size() > 1 else 0)
	Ui.register_closable(Callable(self, "is_panel_open"), Callable(self, "close"))

func is_panel_open() -> bool:
	return is_open

func _exit_tree() -> void:
	if is_instance_valid(_root):
		_root.queue_free()

# --- State -----------------------------------------------------------------------------------------------------

func interact_point() -> Vector2:
	return global_position + Vector2(0, -2)

func footprint_rect() -> Rect2:
	return footprint_at(global_position)

func footprint_at(origin: Vector2) -> Rect2:
	return Rect2(origin + Vector2(-12, -12), Vector2(24, 14))

# The solid base (its collision shape) it would have standing at `origin`.
func base_at(origin: Vector2) -> Rect2:
	var shape_node: CollisionShape2D = get_node_or_null("Collision/Shape")
	if shape_node != null and shape_node.shape is RectangleShape2D:
		var size: Vector2 = shape_node.shape.size
		return Rect2(origin + shape_node.position - size * 0.5, size)
	return Rect2(origin + Vector2(-11, -6), Vector2(22, 6))

func is_carried() -> bool:
	return carrier != null

# How far each carrier stands from the box centre: half the box width plus the gap.
func carry_end_offset_px() -> float:
	return footprint_at(Vector2.ZERO).size.x * 0.5 + carry_end_gap_px

# --- Being carried -------------------------------------------------------------------------------------------------

# Lifted: it stops being solid (nobody walks round a box that is in the air) and hangs where the pair puts it.
func begin_carried(by: Node) -> void:
	carrier = by
	close()
	remove_from_group("build_blockers")
	var shape_node: CollisionShape2D = get_node_or_null("Collision/Shape")
	if shape_node != null:
		shape_node.disabled = true

# Set down at `origin`: solid again there at once; the picture settles from where it hung (nothing jumps).
func end_carried(origin: Vector2) -> void:
	var shown_at: Vector2 = global_position + sprite.position
	global_position = origin
	sprite.position = shown_at - origin
	add_to_group("build_blockers")
	var shape_node: CollisionShape2D = get_node_or_null("Collision/Shape")
	if shape_node != null:
		shape_node.disabled = false
	carrier = null
	var tween: Tween = create_tween()
	tween.tween_property(sprite, "position", Vector2.ZERO, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# --- Moving it with the friend ----------------------------------------------------------------------------------------

const FRIEND_TIRED: String = "Your friend is too tired / hungry to help."

# The colonist who would help: the nearest one that is not dead.
func helper() -> Node:
	var player: Node2D = get_tree().get_first_node_in_group("player")
	var best: Node = null
	var best_d: float = INF
	for c in get_tree().get_nodes_in_group("colonists"):
		if c.dead:
			continue
		var d: float = c.global_position.distance_to(player.global_position if player != null else global_position)
		if d < best_d:
			best_d = d
			best = c
	return best

# Why the friend cannot help now ("" = he can).
func friend_reason(friend: Node) -> String:
	if friend == null:
		return "You need a friend to help."
	if friend.dead:
		return "You need a friend to help."
	var S = friend.State
	if friend.is_asleep() or friend.state in [S.INSIDE, S.ENTERING, S.MOVING_IN, S.RETURNING, S.TO_BED, S.TO_BUSH, S.EATING, S.TO_CRATE, S.EATING_CRATE, S.SLEEPING_OUTSIDE, S.ON_BED]:
		return FRIEND_TIRED
	if friend.state == S.TO_WORK or friend.state == S.AT_WORK or friend.work_claim != null or friend.state == S.HELPING_CARRY:
		return "Your friend is busy."
	if friend.rest.value < carry_min_condition or friend.hunger.value < carry_min_condition:
		return FRIEND_TIRED
	return ""

# Why "Move Toolbox" is greyed ("" = it can be done).
func move_disabled_reason() -> String:
	if carrier != null:
		return "It is already being carried."
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null:
		return "Nobody to carry it."
	if player.inside_building != null:
		return "Only outdoors."
	if player.hands_occupied():
		return "Put down what you are holding first."
	return friend_reason(helper())

# Starts the move; "" when it did, else the reason it did not.
func start_carry() -> String:
	var why: String = move_disabled_reason()
	if why != "":
		return why
	var player: Node = get_tree().get_first_node_in_group("player")
	var job: Node2D = load("res://scripts/carry_together.gd").new()
	get_parent().add_child(job)
	job.setup(self, player, helper())
	carrier = job
	close()
	job.start()
	return ""

func tool_count() -> int:
	var total: int = 0
	for entry in contents:
		if TOOL_KINDS.has(entry["kind"]):
			total += int(entry["count"])
	return total

func item_count() -> int:
	var total: int = 0
	for entry in contents:
		total += int(entry["count"])
	return total

# "Toolbox (3 tools)" on hover.
func readout() -> String:
	var n: int = tool_count()
	return "Toolbox (%d tool%s)" % [n, "" if n == 1 else "s"]

func accepts_kind(kind: StringName) -> bool:
	return accepts.has(kind)

func has_room(kind: StringName, amount: int = 0) -> bool:
	if TOOL_KINDS.has(kind):
		for entry in contents:
			if entry["kind"] == kind:
				return true
	return contents.size() < toolbox_capacity

# Puts something in (a tool stacks with the same tool). False when it is full or not accepted.
func add_item(kind: StringName, amount: int = 0) -> bool:
	if not accepts_kind(kind) or not has_room(kind, amount):
		return false
	if TOOL_KINDS.has(kind):
		for entry in contents:
			if entry["kind"] == kind:
				entry["count"] = int(entry["count"]) + 1
				_refresh()
				return true
	contents.append({"kind": kind, "amount": amount, "count": 1})
	_refresh()
	return true

# Takes one out of slot `index`: {kind, amount}, or {} if there is none.
func take_item(index: int) -> Dictionary:
	if index < 0 or index >= contents.size():
		return {}
	var entry: Dictionary = contents[index]
	var out: Dictionary = {"kind": entry["kind"], "amount": entry["amount"]}
	entry["count"] = int(entry["count"]) - 1
	if int(entry["count"]) <= 0:
		contents.remove_at(index)
	_refresh()
	return out

# The kinds in the box (for the self-check).
func kinds() -> Array:
	return contents.map(func(e: Dictionary) -> StringName: return e["kind"])

# --- Opening and closing -------------------------------------------------------------------------------------------

func open_for(who: Node) -> void:
	if is_open or carrier != null:
		return
	is_open = true
	if open_texture != null:
		sprite.texture = open_texture
	AudioManager.play("toolbox_open", global_position)
	_build_panel()

func close() -> void:
	if not is_open:
		return
	is_open = false
	if closed_texture != null:
		sprite.texture = closed_texture
	AudioManager.play("toolbox_close", global_position)
	if is_instance_valid(_root):
		_root.queue_free()
	_root = null
	_panel = null
	_close_button = null
	_put_button = null
	_move_button = null
	_move_reason = null
	_slot_nodes.clear()

func _process(_delta: float) -> void:
	if not is_open:
		return
	var player: Node2D = get_tree().get_first_node_in_group("player")
	if player == null or player.global_position.distance_to(global_position) > close_distance_px:
		close()
		return
	if is_instance_valid(_panel):
		_update_put_button()
		_update_move_button()
		_place_panel()

# What the player holds that the box would take ("" = nothing): the name for the "Put away" button.
func held_acceptable_name() -> String:
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null or player.dragger.is_dragging() or player.carrying_planks > 0 or player.carrying_blade:
		return ""
	var kind: StringName = player.held_tool
	if kind == &"" or not accepts_kind(kind) or not has_room(kind):
		return ""
	return _display_name(kind)

func _update_put_button() -> void:
	if not is_instance_valid(_put_button):
		return
	var held: String = held_acceptable_name()
	_put_button.visible = held != ""
	if held != "":
		_put_button.text = "Put away %s" % held

func _update_move_button() -> void:
	if not is_instance_valid(_move_button):
		return
	var why: String = move_disabled_reason()
	_move_button.disabled = why != ""
	_move_button.tooltip_text = why
	_move_reason.text = why
	_move_reason.visible = why != ""

func _on_move_pressed() -> void:
	var why: String = start_carry()
	if why != "":
		var hud: Node = get_tree().get_first_node_in_group("hud")
		if hud != null:
			hud.say(why)

# The button: stores the held item, then the panel closes.
func _on_put_away() -> void:
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null:
		return
	var msg: String = player.toolbox_put(self)
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null and msg != "":
		hud.say(msg)
	# (The item is stored and the panel closes.)
	close()

func _unhandled_input(event: InputEvent) -> void:
	if is_open and event is InputEventKey and event.pressed and not event.echo and event.keycode >= KEY_1 and event.keycode <= KEY_9:
		take_with_player(event.keycode - KEY_1)
		get_viewport().set_input_as_handled()

# The player takes slot `index`: into the hands as if picked up; a swap when the hands hold something the box takes.
func take_with_player(index: int) -> String:
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null or index < 0 or index >= contents.size():
		return ""
	var msg: String = player.toolbox_take(self, index)
	if msg != "":
		var hud: Node = get_tree().get_first_node_in_group("hud")
		if hud != null:
			hud.say(msg)
	else:
		# taken (or swapped): the panel closes by itself
		close()
		return msg
	_refresh()
	return msg

# --- The panel -----------------------------------------------------------------------------------------------------

func _build_panel() -> void:
	if is_instance_valid(_root):
		_root.queue_free()
	_root = Control.new()
	_root.name = "ToolboxPanel"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.menu_root.add_child(_root)
	# a click outside the panel closes it
	var catcher := Control.new()
	catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	catcher.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			close())
	_root.add_child(catcher)
	_panel = PanelContainer.new()
	_panel.theme_type_variation = &"DarkPanel"
	_root.add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Ui.px(8))
	_panel.add_child(column)
	# the title banner and the close button (top right)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", Ui.px(6))
	column.add_child(top)
	var banner := PanelContainer.new()
	banner.theme_type_variation = &"Banner"
	banner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(banner)
	var title := Label.new()
	title.text = "Toolbox"
	title.theme_type_variation = &"HeadingLabel"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_child(title)
	_close_button = Button.new()
	_close_button.text = "X"
	_close_button.focus_mode = Control.FOCUS_NONE
	_close_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_close_button.custom_minimum_size = Vector2(Ui.px(40), Ui.px(40))
	_close_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	Ui.decorate_button(_close_button)
	_close_button.pressed.connect(close)
	top.add_child(_close_button)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", Ui.px(6))
	grid.add_theme_constant_override("v_separation", Ui.px(6))
	column.add_child(grid)
	_slot_nodes.clear()
	for i in toolbox_capacity:
		var slot := PanelContainer.new()
		slot.theme_type_variation = &"SlotPanel"
		slot.custom_minimum_size = Vector2(Ui.px(80), Ui.px(92))
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		slot.mouse_entered.connect(func() -> void:
			Ui.sfx("ui_hover"))
		slot.gui_input.connect(_on_slot_input.bind(i))
		grid.add_child(slot)
		var box := VBoxContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_theme_constant_override("separation", Ui.px(2))
		slot.add_child(box)
		var holder := Control.new()
		holder.custom_minimum_size = Vector2(Ui.px(56), Ui.px(48))
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(holder)
		var icon := TextureRect.new()
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		holder.add_child(icon)
		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_size_override("font_size", Ui.font_size("small"))
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(name_label)
		var count_label := Label.new()
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count_label.theme_type_variation = &"BrassLabel"
		count_label.add_theme_font_size_override("font_size", Ui.font_size("small"))
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(count_label)
		_slot_nodes.append({"slot": slot, "holder": holder, "icon": icon, "name": name_label, "count": count_label})
	# "Put away [item]" while an accepted item is in the hands
	_put_button = Button.new()
	_put_button.focus_mode = Control.FOCUS_NONE
	_put_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_put_button.custom_minimum_size = Vector2(0, Ui.px(40))
	Ui.decorate_button(_put_button)
	_put_button.pressed.connect(_on_put_away)
	column.add_child(_put_button)
	# "Move Toolbox": carry it to another spot with the friend (greyed, with the reason under it, when that cannot be done)
	if two_person_carry:
		_move_button = Button.new()
		_move_button.text = "Move Toolbox"
		_move_button.focus_mode = Control.FOCUS_NONE
		_move_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_move_button.custom_minimum_size = Vector2(0, Ui.px(40))
		Ui.decorate_button(_move_button)
		_move_button.pressed.connect(_on_move_pressed)
		column.add_child(_move_button)
		_move_reason = Label.new()
		_move_reason.theme_type_variation = &"DimLabel"
		_move_reason.add_theme_font_size_override("font_size", Ui.font_size("small"))
		_move_reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(_move_reason)
	var hint := Label.new()
	hint.theme_type_variation = &"DimLabel"
	hint.add_theme_font_size_override("font_size", Ui.font_size("small"))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.text = "Click a slot or press its number to take it. E or Esc closes."
	column.add_child(hint)
	_refresh()
	_update_put_button()
	_update_move_button()
	await get_tree().process_frame
	_place_panel()

func _on_slot_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and index < contents.size():
		Ui.sfx("ui_click")
		take_with_player(index)

# Beside the box on the screen, kept inside the window.
func _place_panel() -> void:
	if not is_instance_valid(_panel):
		return
	_panel.reset_size()
	var size: Vector2 = _panel.get_combined_minimum_size()
	_panel.size = size
	# to the right of the box (the open chest stays in view)
	var at: Vector2 = Ui.to_screen(get_viewport(), global_position + Vector2(16, -10))
	var pos: Vector2 = (at + Vector2(float(Ui.px(24)), -size.y * 0.5)).round()
	var screen: Vector2 = Ui.screen_size()
	pos.x = clampf(pos.x, 6.0, maxf(6.0, screen.x - size.x - 6.0))
	pos.y = clampf(pos.y, 6.0, maxf(6.0, screen.y - size.y - 6.0))
	_panel.position = pos

func _display_name(kind: StringName) -> String:
	if NAMES.has(kind):
		return NAMES[kind]
	return Items.name_of(kind)

func _icon_of(kind: StringName) -> Texture2D:
	var path: String = ICONS.get(kind, "")
	var tex: Texture2D = load(path) if path != "" else (Items.texture(kind) if Items.KINDS.has(kind) else null)
	if tex == null:
		return null
	var used: Rect2i = GroundPlacement.used_rect(tex)
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2(used)
	return atlas

func _refresh() -> void:
	if not is_open or _slot_nodes.is_empty():
		return
	for i in _slot_nodes.size():
		var nodes: Dictionary = _slot_nodes[i]
		if i < contents.size():
			var entry: Dictionary = contents[i]
			var tex: Texture2D = _icon_of(entry["kind"])
			var icon: TextureRect = nodes["icon"]
			icon.texture = tex
			if tex != null:
				var holder: Control = nodes["holder"]
				var box: Vector2 = holder.custom_minimum_size
				var factor: float = float(maxi(1, floori(minf(box.x / tex.get_width(), box.y / tex.get_height()))))
				icon.size = tex.get_size() * factor
				icon.position = ((box - icon.size) * 0.5).round()
			var label: String = _display_name(entry["kind"])
			if entry["kind"] == &"seed_bag" or entry["kind"] == &"bucket" or entry["kind"] == &"basket":
				label = Items.hover_text(entry["kind"], int(entry["amount"])) if entry["kind"] != &"basket" else "Basket %d" % int(entry["amount"])
			nodes["name"].text = label
			nodes["count"].text = ("%d   x%d" % [i + 1, entry["count"]]) if int(entry["count"]) > 1 else str(i + 1)
			nodes["slot"].modulate = Color.WHITE
		else:
			nodes["icon"].texture = null
			nodes["name"].text = ""
			nodes["count"].text = ""
			nodes["slot"].modulate = Color(1, 1, 1, 0.45)
