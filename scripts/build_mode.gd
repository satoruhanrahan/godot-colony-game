extends Node2D

const BUILDING_SCENE: PackedScene = preload("res://scenes/Building.tscn")
const CELL: int = 32
const PlankPiles = preload("res://scripts/plank_piles.gd")
const Logistics = preload("res://scripts/logistics.gd")
const GroundPlacement = preload("res://scripts/ground_placement.gd")
const WaterMap = preload("res://scripts/water_map.gd")

# The kinds of building the player can place: number keys pick one (1 = first, ...).
# A type with a `scene` places that scene (the pit saw, dug by hand); otherwise Building.tscn.
@export var building_types: Array[BuildingType] = []
# Placing outside this rectangle is not allowed.
@export var map_rect: Rect2 = Rect2(0, 0, 640, 640)
@export var valid_tint: Color = Color(0.4, 1.0, 0.4, 0.6)
@export var invalid_tint: Color = Color(1.0, 0.3, 0.3, 0.6)
# Placing it would clear tilled plots under it (the existing rule: nothing is refunded).
@export var amber_tint: Color = Color(1.0, 0.75, 0.2, 0.6)
# Outdoor blueprints are placed on the exact pixel under the cursor (not on the 32 px grid); holding this key snaps them to it.
@export var snap_modifier: Key = KEY_SHIFT
# Room kept round the footprint (px), and the walking strip in front of every door (px deep and wide).
@export var placement_margin_px: float = 2.0
@export var door_clearance_px: float = 24.0
# The spot in front of a building (where builders stand to hand things over and where tools are used) must lie this many cells inside the map (a new
# building is not placed closer to the edge); in a room the same rule holds against the floor, with one route cell (px) as the margin (a floor is small).
@export var edge_margin_cells: int = 1
@export var room_edge_margin_px: float = 8.0
# In front of an object on a floor (the crate's use_spot).
const ROOM_FRONT_OFFSET: Vector2 = Vector2(0, 7)
const EDGE_TEXT: String = "Too close to the edge."
# The key named in the Build button's text ("Build (B)"). The key itself is B.
@export var shortcut_hint: String = "B"

var active: bool = false
var type_index: int = 0

@onready var ghost: Sprite2D = $Ghost

# The build menu (the UI's panel, build_menu.gd): category tabs and a card for every building.
var menu: Node
# What is unlocked (unlock_manager.gd): a building needs its unlock_requirement before it can be chosen.
var unlocks: Node

func _ready() -> void:
	add_to_group("build_mode")
	unlocks = get_tree().get_first_node_in_group("unlock_manager")
	if unlocks == null:
		unlocks = load("res://scripts/unlock_manager.gd").new()
		unlocks.name = "UnlockManager"
		add_child(unlocks)
	unlocks.changed.connect(_on_unlocks_changed)
	menu = load("res://scripts/build_menu.gd").new()
	menu.name = "BuildMenu"
	add_child(menu)
	menu.setup(self)
	Ui.register_closable(Callable(self, "is_panel_open"), Callable(self, "close_panel"), "build mode (the build menu)", Ui.TIER_BUILD)
	_set_active(false)

# (For the UI's Esc: close the menu first, pause only when nothing is open.)
func is_panel_open() -> bool:
	return active

func close_panel() -> void:
	_set_active(false)

func _exit_tree() -> void:
	if is_instance_valid(menu):
		menu.close_ui()

func _on_unlocks_changed() -> void:
	if is_instance_valid(menu):
		menu.refresh()

# Is this building still locked by what has not been unlocked yet (not by where he stands)?
func is_unlock_locked(type: BuildingType) -> bool:
	return not unlocks.is_unlocked(type.unlock_requirement)

func _set_active(value: bool) -> void:
	var carrier: Node = get_tree().get_first_node_in_group("player")
	if value and carrier != null and carrier.get("designating") == true:
		value = false
	if value and carrier != null and carrier.get("carrying_together") != null:
		_say("Put the toolbox down first.")
		value = false
	var was: bool = active
	active = value and not building_types.is_empty()
	ghost.visible = active
	if active and not was:
		Ui.sfx("ui_open")
	elif was and not active:
		Ui.sfx("ui_close")
	if active:
		# A locked type (see _locked) cannot be the chosen one: start on the first free one.
		if _locked(building_types[clampi(type_index, 0, building_types.size() - 1)]):
			for i in building_types.size():
				if not _locked(building_types[i]):
					type_index = i
					break
		_select_type(type_index)
	menu.set_open(active)

# In the opening, until the first pit saw is built, the plank-cost buildings are locked (their
# planks are kept for the pit saw).
func _locked(type: BuildingType) -> bool:
	if is_unlock_locked(type):
		return true
	if type.indoor_only:
		var room: Node2D = _room_he_is_in()
		return room == null or not type.indoor_kinds.has(room.kind)
	# Inside a building only the types that may go there (the table, in a house) can be picked.
	var in_room: Node2D = _room_he_is_in()
	if in_room != null:
		return not (type.indoor_ok and type.indoor_kinds.has(in_room.kind))
	return false

# The sentence that says why an option is locked.
func _locked_hint(type: BuildingType) -> String:
	if is_unlock_locked(type):
		return unlocks.reason(type.unlock_requirement)
	if not type.indoor_only and _room_he_is_in() != null:
		return "That goes outside (or in a house, for a table)."
	return type.locked_hint if type.indoor_only else "Build the pit saw first"

# Why this building cannot be placed now ("" = it can): outdoors / indoors only, the supplies kept for the pit saw, a room
# that already holds the most of its kind or has no room. (The menu greys the card and says it on hover.)
func unavailable_reason(type: BuildingType) -> String:
	if _locked(type):
		return _locked_hint(type)
	var room: Node2D = _room_he_is_in()
	if room != null and (type.indoor_only or type.indoor_ok) and not room.has_room_for(type):
		return room.cannot_fit_text(type.indoor_limit_key)
	return ""

# The room (BuildingInterior) the player is in, or null in the world.
func _room_he_is_in() -> Node2D:
	var player: Node = get_tree().get_first_node_in_group("player")
	if player != null and player.get("inside_building") != null and is_instance_valid(player.inside_building):
		return player.inside_building.get_interior()
	return null

func _say(text: String) -> void:
	var interaction: Node = get_node_or_null("../MainCharacter/Interaction")
	if interaction != null:
		interaction.show_message(text)

# Shows the chosen type on the ghost (and in the menu).
func _select_type(index: int) -> void:
	index = clampi(index, 0, building_types.size() - 1)
	# A building that is still locked cannot be chosen (by click, number key or wheel): it says what is needed.
	if is_unlock_locked(building_types[index]):
		_say(unlocks.reason(building_types[index].unlock_requirement))
		return
	type_index = index
	var type: BuildingType = building_types[type_index]
	if _locked(type):
		# It can be looked at (greyed) but not placed.
		_say(_locked_hint(type))
	ghost.texture = type.texture
	ghost.offset = type.sprite_offset
	menu.refresh()

# Chosen with the mouse in the menu.
func choose(index: int) -> void:
	_select_type(index)

# Step to the next (+1) or previous (-1) option, wrapping round at the ends.
func _cycle(step: int) -> void:
	var count: int = building_types.size()
	# (the ones still locked are skipped)
	for i in count:
		var next: int = (type_index + step * (i + 1) + count * 4) % count
		if not is_unlock_locked(building_types[next]):
			_select_type(next)
			return

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_B:
			_set_active(not active)
			get_viewport().set_input_as_handled()
		# (Esc is the UI's: it closes this menu first, and only then pauses.)
		elif active and event.keycode >= KEY_1 and event.keycode <= KEY_9:
			var index: int = event.keycode - KEY_1
			if index < building_types.size():
				_select_type(index)
			get_viewport().set_input_as_handled()
	elif active and event is InputEventMouseButton and event.pressed:
		# The wheel steps through the options, one notch = one step, and does nothing else here.
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			menu.step_card(1)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			menu.step_card(-1)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_set_active(false)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_try_place()
			get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	if not active:
		return
	menu.refresh()
	var type: BuildingType = building_types[type_index]
	if _is_indoor_placement(type):
		# Inside a room too: the exact pixel under the cursor (Shift snaps to the grid), green / red, the reason on hover.
		var in_origin: Vector2 = free_origin(type)
		ghost.global_position = in_origin
		if _locked(type):
			ghost.modulate = Color(0.55, 0.55, 0.55, 0.5)
			return
		var in_result: Dictionary = check_indoor(type, in_origin, true)
		last_result = in_result
		ghost.modulate = valid_tint if in_result["ok"] else invalid_tint
		if not in_result["ok"]:
			Ui.world_text("ghost_reason", get_viewport(), in_origin + Vector2(0, -type.footprint.y * CELL - 4.0), in_result["text"], "small", Color(1.0, 0.55, 0.45))
		return
	# Outdoors: the exact pixel under the cursor, green / red / amber, and the reason on hover.
	var origin: Vector2 = free_origin(type)
	ghost.global_position = origin
	if _locked(type):
		ghost.modulate = Color(0.55, 0.55, 0.55, 0.5)
		return
	var result: Dictionary = check_outdoor(type, origin, true)
	last_result = result
	ghost.modulate = amber_tint if result["ok"] and result["amber"] else (valid_tint if result["ok"] else invalid_tint)
	var size: Vector2 = Vector2(type.footprint * CELL)
	var text: String = result["text"] if not result["ok"] else ("Tilled ground under it will be cleared." if result["amber"] else "")
	if text != "":
		Ui.world_text("ghost_reason", get_viewport(), origin + Vector2(0, -size.y - 4.0), text, "small", Color(1.0, 0.55, 0.45) if not result["ok"] else Color(1.0, 0.85, 0.4))

# The grid cell under the mouse (through the Camera2D), with the footprint centred on it.
func _top_left_under_mouse(type: BuildingType) -> Vector2i:
	var m: Vector2 = get_global_mouse_position()
	var cell := Vector2i(floori(m.x / CELL), floori(m.y / CELL))
	return cell - (type.footprint - Vector2i.ONE) / 2

# A building's origin is the bottom-centre of its footprint.
func _origin_for(top_left: Vector2i, type: BuildingType) -> Vector2:
	return Vector2((top_left.x + type.footprint.x * 0.5) * CELL, (top_left.y + type.footprint.y) * CELL)

func _try_place() -> void:
	var type: BuildingType = building_types[type_index]
	if _locked(type):
		_say(_locked_hint(type))
		return
	# In a room only the indoor types go up (the Wooden Bed, the Crate, and the Table in a house); elsewhere the
	# indoor-only ones do not.
	var room: Node2D = _room_he_is_in()
	if room != null:
		if not (type.indoor_only or type.indoor_ok):
			return
	elif type.indoor_only:
		return
	if room != null and not room.has_room_for(type):
		_say(room.cannot_fit_text(type.indoor_limit_key))
		return
	var top_left: Vector2i = _top_left_under_mouse(type)
	var origin: Vector2 = _origin_for(top_left, type)
	var footprint_rect := Rect2(Vector2(top_left * CELL), Vector2(type.footprint * CELL))
	if _is_indoor_placement(type):
		origin = free_origin(type)
		var in_result: Dictionary = check_indoor(type, origin, false)
		if not in_result["ok"]:
			_say(in_result["text"])
			return
		footprint_rect = footprint_at(type, origin)
	else:
		origin = free_origin(type)
		var result: Dictionary = check_outdoor(type, origin, false)
		if not result["ok"]:
			_say(result["text"])
			return
		footprint_rect = Rect2(origin + Vector2(-type.footprint.x * CELL * 0.5, -type.footprint.y * CELL), Vector2(type.footprint * CELL))
	var building: Node2D = (type.scene if type.scene != null else BUILDING_SCENE).instantiate()
	if building is Building:
		building.building_type = type
	elif "starts_built" in building:
		# A pit saw: placed as marked ground, free (it is paid for by digging).
		building.starts_built = false
	building.position = origin
	building.name = type.type_name.replace(" ", "")
	# Wheat plots under it are cleared (nothing refunded): ground that is built on is never farmland.
	if _room_he_is_in() == null:
		var plots: Node = get_tree().get_first_node_in_group("plot_manager")
		if plots != null:
			plots.clear_rect(footprint_rect)
	# Same y-sorted parent as every other object (this node's parent is the main scene).
	get_parent().add_child(building, true)
	AudioManager.play("blueprint_place", building.position)
	print("Placed %s blueprint at %s" % [type.type_name, building.position])

# --- Free placement (outdoors) --------------------------------------------------------------------------------------

var last_result: Dictionary = {"ok": true, "amber": false, "text": ""}
var _flood_cache: Dictionary = {}

func _is_indoor_placement(type: BuildingType) -> bool:
	return type.indoor_only or (type.indoor_ok and _room_he_is_in() != null)

# --- Free placement inside a room ---------------------------------------------------------------------------------------

# What the object would cover on the floor at `origin`: a flat one (a bed) its picture's opaque bounds, a solid one (a crate, a
# table) its base.
func floor_cover(type: BuildingType, origin: Vector2) -> Rect2:
	if type.flat_decal and type.texture != null:
		var used: Rect2i = GroundPlacement.used_rect(type.texture)
		var size: Vector2 = type.texture.get_size()
		var centre: Vector2 = origin + type.sprite_offset + (Vector2(used.position) + Vector2(used.size) * 0.5 - size * 0.5)
		return Rect2(centre - Vector2(used.size) * 0.5, Vector2(used.size))
	return base_rect_at(type, origin)

# {"ok", "amber", "text"} for an indoor object at `origin` in the room he is in: inside the floor, clear of the door, not on
# another object, not shutting the way between the door and the others (the same flood fill as outdoors, over the room), and
# the room may hold another of its kind (crates, tables).
func check_indoor(type: BuildingType, origin: Vector2, throttled: bool) -> Dictionary:
	var room: Node2D = _room_he_is_in()
	if room == null or not type.indoor_kinds.has(room.kind):
		return {"ok": false, "amber": false, "text": "Not here."}
	if not room.has_room_for(type):
		return {"ok": false, "amber": false, "text": room.cannot_fit_text(type.indoor_limit_key)}
	var cover: Rect2 = floor_cover(type, origin)
	var grown: Rect2 = cover.grow(placement_margin_px)
	if not room.floor_rect_world().encloses(cover):
		return {"ok": false, "amber": false, "text": "Keep it on the floor."}
	# (a spot to stand at in front of it, on the floor too)
	var floor_inner: Rect2 = room.floor_rect_world().grow(-room_edge_margin_px)
	var front: Vector2 = origin + ROOM_FRONT_OFFSET
	if front.x < floor_inner.position.x or front.x > floor_inner.end.x or front.y < floor_inner.position.y or front.y > floor_inner.end.y:
		return {"ok": false, "amber": false, "text": EDGE_TEXT}
	if grown.intersects(door_strip(room.door_world())) or grown.intersects(room.door_clear_rect_world()):
		return {"ok": false, "amber": false, "text": "Too close to the door."}
	if room.object_overlaps(grown) or PlankPiles.item_in_rect(get_tree(), grown):
		return {"ok": false, "amber": false, "text": "Something is in the way."}
	# solid things must not shut the way
	if not type.flat_decal and room.blocks_route(base_rect_at(type, origin), throttled):
		return {"ok": false, "amber": false, "text": "Would block the way."}
	return {"ok": true, "amber": false, "text": ""}

# Is a person's spot in front of a new outdoor building far enough inside the map?
func front_spot_ok(spot: Vector2) -> bool:
	var inner: Rect2 = map_rect.grow(-edge_margin_cells * CELL)
	return spot.x >= inner.position.x and spot.x <= inner.end.x and spot.y >= inner.position.y and spot.y <= inner.end.y

# The origin (bottom centre) of the ghost: the exact pixel under the cursor with the footprint centred on it; with the snap key
# held it is the grid cell as before.
func free_origin(type: BuildingType) -> Vector2:
	if Input.is_key_pressed(snap_modifier):
		return _origin_for(_top_left_under_mouse(type), type)
	var m: Vector2 = get_global_mouse_position()
	return Vector2(roundf(m.x), roundf(m.y + type.footprint.y * CELL * 0.5))

func footprint_at(type: BuildingType, origin: Vector2) -> Rect2:
	var size := Vector2(type.footprint * CELL)
	return Rect2(origin + Vector2(-size.x * 0.5, -size.y), size)

# The solid base (collision) a building of this type would have at `origin`.
func base_rect_at(type: BuildingType, origin: Vector2) -> Rect2:
	var base: Vector2 = type.base_size if type.base_size != Vector2.ZERO else Vector2(type.footprint.x * CELL - 5, 8)
	return Rect2(origin + Vector2(0.5 - base.x * 0.5, -base.y), base)

# The walking strip in front of a door point (door_clearance_px wide and deep).
func door_strip(door: Vector2) -> Rect2:
	return Rect2(door + Vector2(-door_clearance_px * 0.5, -2.0), Vector2(door_clearance_px, door_clearance_px))

# The doors of what stands in the world: finished or planned houses and storages (and the cabin).
func door_points() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.building_type != null and b.building_type.interior_kind != "":
			out.append(b.door_position())
	for st in get_tree().get_nodes_in_group("storages"):
		out.append(st.door_position())
	var cabin: Node2D = get_parent().get_node_or_null("Cabin")
	if cabin != null:
		out.append(cabin.global_position + Vector2(-4, 4))
	return out

# {"ok", "amber" (plots would go), "text" (why not)} for a building of `type` with its origin at `origin`, outdoors.
# `cheap_only`: skip the route check (the ghost does it a few times a second; placing always does it).
func check_outdoor(type: BuildingType, origin: Vector2, throttled: bool) -> Dictionary:
	var rect: Rect2 = footprint_at(type, origin)
	var grown: Rect2 = rect.grow(placement_margin_px)
	if not map_rect.encloses(rect):
		return {"ok": false, "amber": false, "text": "Something is in the way."}
	if not front_spot_ok(origin + Logistics.BUILDING_STOP_OFFSET):
		return {"ok": false, "amber": false, "text": EDGE_TEXT}
	if WaterMap.rect_has_water(grown):
		return {"ok": false, "amber": false, "text": "Can't build on water."}
	if Footprints.rect_blocked(get_tree(), grown) or PlankPiles.item_in_rect(get_tree(), grown):
		return {"ok": false, "amber": false, "text": "Something is in the way."}
	for group in ["berry_bushes", "beds", "toolboxes"]:
		for node in get_tree().get_nodes_in_group(group):
			if node is Node2D and grown.grow(6.0).has_point(node.global_position) and grown.intersects(GroundPlacement.pickup_rect(node)):
				return {"ok": false, "amber": false, "text": "Something is in the way."}
	# doors: the strip in front of every existing door stays clear, and so does this building's own
	for door in door_points():
		if grown.intersects(door_strip(door)):
			return {"ok": false, "amber": false, "text": "Too close to the door."}
	if type.interior_kind != "":
		var own_strip: Rect2 = door_strip(origin + type.door_offset)
		if Footprints.rect_blocked(get_tree(), own_strip) or PlankPiles.item_in_rect(get_tree(), own_strip) or WaterMap.rect_has_water(own_strip):
			return {"ok": false, "amber": false, "text": "Too close to the door."}
	# it must not cut anything off that could be reached
	if _would_block(type, origin, throttled):
		return {"ok": false, "amber": false, "text": "Would block the way."}
	var plots: Node = get_tree().get_first_node_in_group("plot_manager")
	var amber: bool = plots != null and plots.plots_in_rect(rect)
	return {"ok": true, "amber": amber, "text": ""}

# {"ok", "amber", "text"} for a free-standing object (the toolbox being carried) with this footprint and solid base, outdoors: the same
# rules as a building (inside the map, no water, clear of solids and items, the door strips, not shutting a way). `ignore` is the
# object itself.
func check_object(rect: Rect2, base: Rect2, ignore: Node, throttled: bool) -> Dictionary:
	var grown: Rect2 = rect.grow(placement_margin_px)
	if not map_rect.encloses(rect):
		return {"ok": false, "amber": false, "text": "Something is in the way."}
	if not front_spot_ok(Vector2(rect.get_center().x, rect.end.y) + ROOM_FRONT_OFFSET):
		return {"ok": false, "amber": false, "text": EDGE_TEXT}
	if WaterMap.rect_has_water(grown):
		return {"ok": false, "amber": false, "text": "Can't build on water."}
	if Footprints.rect_blocked(get_tree(), grown) or PlankPiles.item_in_rect(get_tree(), grown):
		return {"ok": false, "amber": false, "text": "Something is in the way."}
	for group in ["berry_bushes", "beds", "toolboxes"]:
		for node in get_tree().get_nodes_in_group(group):
			if node != ignore and node is Node2D and grown.grow(6.0).has_point(node.global_position) and grown.intersects(GroundPlacement.pickup_rect(node)):
				return {"ok": false, "amber": false, "text": "Something is in the way."}
	for door in door_points():
		if grown.intersects(door_strip(door)):
			return {"ok": false, "amber": false, "text": "Too close to the door."}
	if _blocks_base("object:%d,%d" % [int(base.position.x), int(base.position.y)], base, throttled):
		return {"ok": false, "amber": false, "text": "Would block the way."}
	var plots: Node = get_tree().get_first_node_in_group("plot_manager")
	return {"ok": true, "amber": plots != null and plots.plots_in_rect(rect), "text": ""}

# Would a building here make something that can be reached from the cabin door unreachable? (The same flood fill the
# creek check uses, 16 px cells, over the doors, the trees, the bushes, the water and the items lying about.)
func _would_block(type: BuildingType, origin: Vector2, throttled: bool) -> bool:
	return _blocks_base("%s:%d,%d" % [type.type_name, int(origin.x), int(origin.y)], base_rect_at(type, origin), throttled)

func _blocks_base(key: String, base: Rect2, throttled: bool) -> bool:
	var now: float = Time.get_ticks_msec() / 1000.0
	if throttled and _flood_cache.get("key", "") == key:
		return _flood_cache["blocks"]
	if throttled and now - float(_flood_cache.get("at", -10.0)) < 0.12 and _flood_cache.has("blocks"):
		return _flood_cache["blocks"]
	var obstacles: Array[Rect2] = Footprints.base_rects(get_tree())
	var start: Vector2 = _route_start()
	var before: Dictionary = WaterMap.flood(start, obstacles)
	var with_new: Array[Rect2] = obstacles.duplicate()
	# (grown a little: walkers need room to pass, and a thin base would slip between the 16 px cells)
	with_new.append(base.grow(6.0))
	var after: Dictionary = WaterMap.flood(start, with_new)
	var blocks: bool = false
	for point in _key_points():
		if WaterMap.flood_reaches(before, point, 1) and not WaterMap.flood_reaches(after, point, 1):
			blocks = true
			break
	_flood_cache = {"key": key, "at": now, "blocks": blocks}
	return blocks

# Where the route check starts: in front of the cabin door (the first reachable place), else the player.
func _route_start() -> Vector2:
	var cabin: Node2D = get_parent().get_node_or_null("Cabin")
	if cabin != null:
		return cabin.global_position + Vector2(-4, 12)
	var player: Node2D = get_tree().get_first_node_in_group("player")
	return player.global_position if player != null else Vector2(320, 320)

# The places that must stay reachable.
func _key_points() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for door in door_points():
		out.append(door)
	for tree in get_tree().get_nodes_in_group("trees"):
		out.append(tree.global_position + Vector2(0, 14))
	for bush in get_tree().get_nodes_in_group("berry_bushes"):
		out.append(bush.global_position + Vector2(0, 8))
	for creek in WaterMap.creek_tiles:
		out.append(WaterMap.tile_rect(creek).get_center())
		break
	if not WaterMap.creek_tiles.is_empty():
		out.append(WaterMap.tile_rect(WaterMap.creek_tiles[WaterMap.creek_tiles.size() - 1]).get_center())
	for group in ["ground_items", "toolboxes", "hammers", "shovels", "axes", "plank_piles", "saw_blades"]:
		for item in get_tree().get_nodes_in_group(group):
			out.append(item.global_position)
	var landing: Node2D = get_parent().get_node_or_null("LandingPoint")
	if landing != null:
		out.append(landing.global_position)
	return out

# Valid when the footprint is inside the map and overlaps no tree, Sawmill, Storage,
# or other building.
func _can_place(top_left: Vector2i, type: BuildingType) -> bool:
	var rect := Rect2(Vector2(top_left * CELL), Vector2(type.footprint * CELL))
	# Nothing is built over a plank pile or a saw blade lying on the ground (it could never be
	# picked up again).
	if type.indoor_only or (type.indoor_ok and _room_he_is_in() != null):
		# On the floor of the room he is in: inside the walkable area, clear of the way out, of other beds, crates
		# and blueprints, and of anything lying there; and the room must have room for another one of its kind.
		# (A flat bed lies on the whole cell; a solid crate stands on its base, the bottom strip of the cell.)
		var room: Node2D = _room_he_is_in()
		if room == null or not type.indoor_kinds.has(room.kind) or not room.has_room_for(type):
			return false
		var footprint: Rect2 = rect if type.flat_decal else Rect2(rect.position.x + 5.0, rect.end.y - 8.0, rect.size.x - 10.0, 8.0)
		if not room.floor_rect_world().encloses(footprint) or footprint.intersects(room.door_clear_rect_world()):
			return false
		return not Footprints.rect_blocked(get_tree(), rect.grow(-2.0)) and not PlankPiles.item_in_rect(get_tree(), rect.grow(-2.0))
	return map_rect.encloses(rect) and not Footprints.rect_blocked(get_tree(), rect) and not PlankPiles.item_in_rect(get_tree(), rect.grow(4.0))
