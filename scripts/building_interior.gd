extends Node2D

# The inside of one building (a House or a Storage): a room (floor, walls, a door gap in the bottom wall) that lives far off the map in the
# SAME world scene, so everything else keeps running while the player is in it (the clock, needs, colonists,
# sounds). Each House has its own interior, made the first time it is entered and kept afterwards (so later
# beds, items and storage belong to that house); things dropped on its floor are ordinary world items lying
# at the room's coordinates and stay there.
#
# The room picture is res://sprites/cabin_interior.png, drawn with its top-left corner at this node's origin, so
# every number below is in that picture's pixels. Nothing is ever scaled. Walls are not physics bodies: the
# player's position is simply kept inside the walkable area (floor_rect, plus the corridor through the door).
#
#  - Backdrop: a plain dark rectangle behind the room (the room is smaller than the screen).
#  - Room: the picture (z -5).  Decals: a layer above the floor for floor items such as beds later (z -4).
#  - Objects: things in the room that depth-sort with the player (items, occupants) are children of the world
#    root, which is the y-sorted layer; add_object() puts a node there.
#  - The camera shows the room centred on screen at the normal zoom (camera_centre).

const ROOM_TEXTURE_PATH: String = "res://sprites/cabin_interior.png"
# Interiors are put in a row starting here, far to the right of the map (which is 640 px wide).
const FIRST_ORIGIN: Vector2 = Vector2(2400, 0)
const SPACING: float = 416.0   # a whole number of 32 px cells, so every room shares the build grid
static var _made: int = 0

# The planks and logs a Storage holds are drawn on the floor of its room: one stack of up to 3 planks per slot
# along the right wall, one log per slot along the left wall, at most stock_slots slots of each (the true count
# stays in the Storage; the hover text says it). The drawing is rebuilt from the Storage's counts whenever they
# change and whenever the room is made or entered, so it can never differ from the stock.
@export var stock_slots: int = 6
const PLANK_PILE = preload("res://scripts/plank_pile.gd")
const LOG_TEXTURE: Texture2D = preload("res://sprites/tree_trunk.png")
const PLANK_COLUMN_X: float = 132.0
const LOG_COLUMN_X: float = 35.0
const STOCK_TOP_Y: float = 74.0
const STOCK_ROW: float = 11.0
var _stock_nodes: Array = []
var drawn_planks: int = 0
var drawn_logs: int = 0
var stock_label: Label

# What kind of room this is ("house", "storage") and its size (the picture's canvas); set from the type.
var kind: String = "house"
var interior_size: Vector2 = Vector2(224, 160)
var room_texture: Texture2D = null
var crates_max: int = 0

# The walkable rectangle for his feet.
@export var floor_rect: Rect2 = Rect2(20, 62, 88, 76)
# Where he appears when he comes in (his feet), just inside the door.
@export var door_pos: Vector2 = Vector2(64, 126)
# Walking into this leaves the house (his feet).
@export var exit_area: Rect2 = Rect2(54, 134, 20, 10)
# The door gap in the bottom wall: he may walk through it (x range) down to corridor_bottom.
@export var door_gap_x: Vector2 = Vector2(54, 74)
@export var corridor_bottom: float = 142.0
# The middle of the room picture: the camera looks here.
@export var camera_centre: Vector2 = Vector2(64, 78)
@export var backdrop_color: Color = Color(0.07, 0.05, 0.06)

var building = null
var player_inside: bool = false
# The colonists currently shown in the room.
var shown: Array = []

var decals: Node2D
var room_sprite: Sprite2D

static func is_interior_point(p: Vector2) -> bool:
	return p.x >= FIRST_ORIGIN.x - 200.0

# The room of `host` (a House or a Storage: anything with building_type, door_position() and get_interior()),
# made from its BuildingType the first time it is asked for and kept afterwards.
static func create_for(host, parent: Node) -> Node2D:
	var type: BuildingType = host.interior_type()
	var room: Node2D = (load("res://scenes/BuildingInterior.tscn") as PackedScene).instantiate()
	room.building = host
	room.configure(type)
	room.position = next_origin()
	parent.add_child(room)
	# (A Storage that already holds things has them on its floor from the first time anyone walks in.)
	room.refresh_stock()
	return room

# Takes the room's numbers from the BuildingType.
func configure(type: BuildingType) -> void:
	if type == null:
		return
	kind = type.interior_kind if type.interior_kind != "" else "house"
	interior_size = Vector2(type.interior_size)
	room_texture = type.interior_texture
	floor_rect = type.floor_rect
	door_pos = type.door_pos
	exit_area = type.exit_area
	door_gap_x = type.door_gap_x
	corridor_bottom = type.corridor_bottom
	camera_centre = type.camera_centre
	crates_max = type.crates_max

# The whole picture's rectangle in the world.
func rect_world() -> Rect2:
	return Rect2(global_position, interior_size)

# The room that holds this world point (null in the world).
static func room_at(tree: SceneTree, point: Vector2):
	for room in tree.get_nodes_in_group("building_interiors"):
		if room.rect_world().has_point(point):
			return room
	return null

# --- What it may hold ---------------------------------------------------------------------------------------

# How many of a kind of thing ("bed", "crate") stand or are planned in it, and how many it may have.
func count_of(key: String) -> int:
	var n: int = 0
	var rect: Rect2 = rect_world()
	if key == "bed":
		for bed in get_tree().get_nodes_in_group("beds"):
			if rect.has_point(bed.global_position):
				n += 1
	elif key == "crate":
		for crate in get_tree().get_nodes_in_group("crates"):
			if rect.has_point(crate.global_position):
				n += 1
	elif key == "table":
		for table in get_tree().get_nodes_in_group("tables"):
			if rect.has_point(table.global_position):
				n += 1
	for other in get_tree().get_nodes_in_group("buildings"):
		if other != building and other.building_type != null and other.building_type.indoor_limit_key == key and other.state != other.State.BUILT and rect.has_point(other.global_position):
			n += 1
	return n

func limit_of(key: String) -> int:
	if key == "bed":
		# (0 = no limit: beds are only limited by the space)
		var max_beds: int = building.house_max_beds if building != null and "house_max_beds" in building else 0
		return max_beds if max_beds > 0 else 99999
	if key == "crate":
		return crates_max
	if key == "table":
		return building.house_max_tables if building != null and "house_max_tables" in building else 0
	return 0

func has_room_for(type: BuildingType) -> bool:
	if type.indoor_limit_key == "":
		return true
	return count_of(type.indoor_limit_key) < limit_of(type.indoor_limit_key)

func has_room_for_bed() -> bool:
	return count_of("bed") < limit_of("bed")

func cannot_fit_text(key: String) -> String:
	return "This %s cannot fit another %s." % [kind, key]

# Makes the next free interior spot.
static func next_origin() -> Vector2:
	var origin: Vector2 = FIRST_ORIGIN + Vector2(SPACING * _made, 0)
	_made += 1
	return origin

func _ready() -> void:
	add_to_group("building_interiors")
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var backdrop := ColorRect.new()
	backdrop.color = backdrop_color
	backdrop.position = camera_centre - Vector2(450, 350)
	backdrop.size = Vector2(900, 700)
	backdrop.z_index = -10
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	room_sprite = Sprite2D.new()
	room_sprite.centered = false
	room_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	room_sprite.z_index = -5
	if room_texture != null:
		room_sprite.texture = room_texture
	elif ResourceLoader.exists(ROOM_TEXTURE_PATH):
		room_sprite.texture = load(ROOM_TEXTURE_PATH)
	add_child(room_sprite)
	stock_label = Label.new()
	stock_label.visible = false
	stock_label.z_index = 100
	stock_label.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	stock_label.size = Vector2(90, 12)
	stock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stock_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stock_label.add_theme_font_size_override("font_size", 8)
	stock_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	stock_label.add_theme_constant_override("outline_size", 3)
	add_child(stock_label)
	Ui.adopt(stock_label)
	decals = Node2D.new()
	decals.name = "Decals"
	decals.z_index = -4
	add_child(decals)

# --- The stock of a Storage, drawn ------------------------------------------------------------------------

func _stock_rect(kind: String) -> Rect2:
	if kind == "planks":
		var piles: int = mini(stock_slots, ceili(drawn_planks / 3.0))
		return Rect2(global_position + Vector2(PLANK_COLUMN_X - 10.0, STOCK_TOP_Y - 11.0), Vector2(20.0, maxf(0.0, STOCK_ROW * piles)))
	return Rect2(global_position + Vector2(LOG_COLUMN_X - 15.0, STOCK_TOP_Y - 6.0), Vector2(15.0, STOCK_ROW * drawn_logs))

# Redraws the planks and logs from the Storage's counts (nothing else is kept).
func refresh_stock() -> void:
	for node in _stock_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_stock_nodes.clear()
	drawn_planks = 0
	drawn_logs = 0
	if building == null or not is_instance_valid(building) or not building.is_in_group("storages") or get_parent() == null:
		return
	var planks: int = building.planks_stored
	var piles: int = mini(stock_slots, ceili(planks / 3.0))
	for i in piles:
		var n: int = mini(3, planks - i * 3)
		var sprite := Sprite2D.new()
		sprite.texture = PLANK_PILE.TEXTURES[n]
		sprite.offset = PLANK_PILE.OFFSETS[n]
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.position = to_world(Vector2(PLANK_COLUMN_X, STOCK_TOP_Y + STOCK_ROW * i))
		_add_stock_node(sprite)
		drawn_planks += n
	for i in mini(stock_slots, building.logs_stored):
		var log_sprite := Sprite2D.new()
		log_sprite.texture = LOG_TEXTURE
		# (A log lying along x, as the Hauler puts one down.)
		log_sprite.offset = Vector2(0, -14)
		log_sprite.rotation_degrees = -90.0
		log_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		log_sprite.position = to_world(Vector2(LOG_COLUMN_X, STOCK_TOP_Y + STOCK_ROW * i))
		_add_stock_node(log_sprite)
		drawn_logs += 1

func _add_stock_node(node: Node2D) -> void:
	add_object(node)
	_stock_nodes.append(node)

func _clear_stock() -> void:
	for node in _stock_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_stock_nodes.clear()

# The hover text over a stack: the true count, and how many are drawn when that is fewer.
func _stock_text(kind: String) -> String:
	var total: int = building.planks_stored if kind == "planks" else building.logs_stored
	var drawn: int = drawn_planks if kind == "planks" else drawn_logs
	var text: String = "%s %d" % ["Planks" if kind == "planks" else "Logs", total]
	if drawn < total:
		text += " (%d shown)" % drawn
	return text

func _process(_delta: float) -> void:
	if not player_inside or stock_label == null or building == null or not is_instance_valid(building) or not building.is_in_group("storages"):
		if stock_label != null:
			stock_label.visible = false
		return
	var mouse: Vector2 = get_global_mouse_position()
	stock_label.visible = false
	for kind in ["planks", "logs"]:
		var rect: Rect2 = _stock_rect(kind)
		if rect.size.y > 0.0 and rect.has_point(mouse):
			stock_label.text = _stock_text(kind)
			stock_label.global_position = Vector2(rect.get_center().x - stock_label.size.x * 0.5, rect.position.y - 14.0)
			stock_label.visible = true

func _exit_tree() -> void:
	_clear_stock()

# --- Geometry -------------------------------------------------------------------------------------------------

func to_world(local: Vector2) -> Vector2:
	return global_position + local

func floor_rect_world() -> Rect2:
	return Rect2(global_position + floor_rect.position, floor_rect.size)

func door_world() -> Vector2:
	return to_world(door_pos)

func exit_point_world() -> Vector2:
	return to_world(exit_area.position + exit_area.size * 0.5)

func exit_rect_world() -> Rect2:
	return Rect2(global_position + exit_area.position, exit_area.size)

func camera_position() -> Vector2:
	return global_position + camera_centre

# A feet position (world) kept inside the walkable area: the floor, and the corridor through the door.
func clamp_walk(world: Vector2) -> Vector2:
	var local: Vector2 = world - global_position
	var lo: Vector2 = floor_rect.position
	var hi: Vector2 = floor_rect.end
	if local.x >= door_gap_x.x and local.x <= door_gap_x.y:
		hi.y = corridor_bottom
	local = local.clamp(lo, hi)
	# Below the floor only the door gap leads on: sliding sideways off it is not possible.
	if local.y > floor_rect.end.y:
		local.x = clampf(local.x, door_gap_x.x, door_gap_x.y)
	return global_position + local

func in_exit(world: Vector2) -> bool:
	return exit_rect_world().has_point(world)

# The strip in front of the door that nothing may be built on (so the way out stays open).
func door_clear_rect_world() -> Rect2:
	return Rect2(global_position + Vector2(door_gap_x.x, floor_rect.end.y - 30.0), Vector2(door_gap_x.y - door_gap_x.x, 40.0))

# --- Free placement: what stands in the room ---------------------------------------------------------------------------------

# Everything solid in the room: the bases of crates, tables, blueprints and the Storage's things (collision rectangles).
func solid_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	var rect: Rect2 = rect_world()
	for r in Footprints.base_rects(get_tree()):
		if rect.has_point(r.get_center()):
			out.append(r)
	return out

# Does this rectangle overlap anything in the room: a solid base, a bed lying on the floor (its picture), a flat bed blueprint?
func object_overlaps(area: Rect2) -> bool:
	for r in solid_rects():
		if area.intersects(r):
			return true
	var rect: Rect2 = rect_world()
	var GroundPlacement = load("res://scripts/ground_placement.gd")
	for bed in get_tree().get_nodes_in_group("beds"):
		if rect.has_point(bed.global_position) and area.intersects(GroundPlacement.pickup_rect(bed)):
			return true
	for other in get_tree().get_nodes_in_group("buildings"):
		if other != building and other.building_type != null and other.building_type.flat_decal and rect.has_point(other.global_position):
			var BuildModeScript = get_tree().get_first_node_in_group("build_mode")
			if BuildModeScript != null and area.intersects(BuildModeScript.floor_cover(other.building_type, other.global_position)):
				return true
	return false

const ROUTE_CELL: float = 8.0
var _route_cache: Dictionary = {}

# Would a new solid base shut something in the room off from the door? (An 8 px grid over the floor and the way out, the
# door's cell the start, the room's other objects the places that must stay reachable.) Cached for a moment while the ghost
# moves.
func blocks_route(extra_base: Rect2, throttled: bool) -> bool:
	var key: String = "%d,%d,%d,%d" % [int(extra_base.position.x), int(extra_base.position.y), int(extra_base.size.x), int(extra_base.size.y)]
	var now: float = Time.get_ticks_msec() / 1000.0
	if throttled and _route_cache.get("key", "") == key:
		return _route_cache["blocks"]
	if throttled and now - float(_route_cache.get("at", -10.0)) < 0.1 and _route_cache.has("blocks"):
		return _route_cache["blocks"]
	var base: Array[Rect2] = solid_rects()
	var with_new: Array[Rect2] = base.duplicate()
	with_new.append(extra_base)
	var before: Dictionary = _flood(base, exit_point_world())
	var after: Dictionary = _flood(with_new, exit_point_world())
	var blocks: bool = false
	for point in _route_points():
		if _flood_reaches(before, point) and not _flood_reaches(after, point):
			blocks = true
			break
	_route_cache = {"key": key, "at": now, "blocks": blocks}
	return blocks

func _route_points() -> Array[Vector2]:
	var out: Array[Vector2] = []
	var rect: Rect2 = rect_world()
	for group in ["beds", "crates", "tables", "storages"]:
		for node in get_tree().get_nodes_in_group(group):
			if node is Node2D and rect.has_point(node.global_position):
				out.append(node.global_position + Vector2(0, 8))
	for other in get_tree().get_nodes_in_group("buildings"):
		if other != building and other.building_type != null and other.building_type.indoor_limit_key != "" and rect.has_point(other.global_position):
			out.append(other.global_position + Vector2(0, 8))
	return out

# Cells (8 px) a walker can reach from `start` over the floor and the corridor to the door, round the obstacles (grown by 4 px).
func _flood(obstacles: Array[Rect2], start: Vector2) -> Dictionary:
	var bounds: Rect2 = floor_rect_world()
	bounds = bounds.expand(Vector2(bounds.position.x, global_position.y + corridor_bottom)).expand(Vector2(bounds.end.x, global_position.y + corridor_bottom))
	var grown: Array[Rect2] = []
	for r in obstacles:
		grown.append(r.grow(4.0))
	var seen: Dictionary = {}
	var queue: Array[Vector2i] = [_cell_of(start)]
	seen[queue[0]] = true
	var head: int = 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if seen.has(n):
				continue
			var centre: Vector2 = _cell_centre(n)
			if not bounds.has_point(centre) or not _walkable(centre):
				continue
			var blocked: bool = false
			for r in grown:
				if r.has_point(centre):
					blocked = true
					break
			if blocked:
				continue
			seen[n] = true
			queue.append(n)
	return seen

func _walkable(world: Vector2) -> bool:
	return clamp_walk(world).distance_to(world) < 0.5

func _cell_of(world: Vector2) -> Vector2i:
	return Vector2i(floori((world.x - global_position.x) / ROUTE_CELL), floori((world.y - global_position.y) / ROUTE_CELL))

func _cell_centre(cell: Vector2i) -> Vector2:
	return global_position + Vector2((cell.x + 0.5) * ROUTE_CELL, (cell.y + 0.5) * ROUTE_CELL)

func _flood_reaches(seen: Dictionary, point: Vector2) -> bool:
	var c: Vector2i = _cell_of(point)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if seen.has(Vector2i(c.x + dx, c.y + dy)):
				return true
	return false

# A place on the floor where someone can stand to work on / hand something to the thing that covers `cover` (the room's pixels, world
# coordinates): `prefer` first, then the other sides, then a ring. It must be on the floor, not on a solid base, not within `apart` of
# one of `avoid` (the spot the player already uses) and reachable from the door round the room's solid things. Vector2.INF = no such place.
func standing_spot(cover: Rect2, prefer: Vector2, avoid: Array = [], apart: float = 12.0) -> Vector2:
	var solids: Array[Rect2] = solid_rects()
	var reach: Dictionary = _flood(solids, exit_point_world())
	var candidates: Array[Vector2] = [prefer]
	var centre: Vector2 = cover.get_center()
	var radius: float = maxf(cover.size.x, cover.size.y) * 0.5 + 8.0
	for angle in [180.0, 0.0, 90.0, 270.0, 135.0, 225.0, 45.0, 315.0]:
		candidates.append(centre + Vector2.from_angle(deg_to_rad(angle)) * radius)
	candidates.append(centre + Vector2(-radius - 8.0, 0.0))
	candidates.append(centre + Vector2(radius + 8.0, 0.0))
	for raw in candidates:
		var p: Vector2 = clamp_walk(raw).round()
		if not _walkable(p):
			continue
		var blocked: bool = false
		for r in solids:
			if r.grow(3.0).has_point(p):
				blocked = true
				break
		if blocked:
			continue
		var near_other: bool = false
		for a in avoid:
			if p.distance_to(a) < apart:
				near_other = true
				break
		if near_other:
			continue
		if _flood_reaches(reach, p):
			return p
	return Vector2.INF

# Things in the room that sort with the player go into the y-sorted world root.
func add_object(node: Node2D) -> void:
	get_parent().add_child(node)

# --- People ---------------------------------------------------------------------------------------------------

# A place in the room for a colonist: awake, standing near the door; asleep, lying on a free bit of floor.
func occupant_spot(sleeping: bool) -> Vector2:
	if not sleeping:
		for i in 6:
			var spot: Vector2 = to_world(Vector2(36 + i * 14, 116))
			if _spot_free(spot):
				return spot
	for y in [82, 104, 66, 94]:
		for x in [30, 54, 78, 96]:
			var spot: Vector2 = to_world(Vector2(x, y))
			if _spot_free(spot):
				return spot
	return to_world(Vector2(64, 90))

func _spot_free(spot: Vector2) -> bool:
	# (not on a crate or a table, wherever they were put: objects stand at any pixel now)
	for r in solid_rects():
		if r.grow(6.0).has_point(spot):
			return false
	for c in shown:
		if is_instance_valid(c) and c.position.distance_to(spot) < 12.0:
			return false
	for group in ["plank_piles", "saw_blades", "hammers", "shovels", "axes", "bundle_piles", "baskets", "ground_items", "dough_boards"]:
		for item in get_tree().get_nodes_in_group(group):
			if item.global_position.distance_to(spot) < 12.0:
				return false
	var player: Node2D = get_tree().get_first_node_in_group("player")
	return player == null or player.global_position.distance_to(spot) > 14.0

# A colonist who is really standing in this room (his position is in it) for a job or a visit: not asleep, not at a crate.
func is_worker_here(c) -> bool:
	return not c.dead and c.state == c.State.ORDERED and rect_world().has_point(c.position)

# The player has come in: the colonists of this house who are inside it show in the room.
func player_entered() -> void:
	player_inside = true
	refresh_stock()
	# Anyone who is working in here (a job inside the building): seen where he stands.
	for c in get_tree().get_nodes_in_group("colonists"):
		if is_worker_here(c) and not shown.has(c):
			shown.append(c)
			c.in_room = true
			c.set_body_visible(&"*", true)
	for c in get_tree().get_nodes_in_group("colonists"):
		if (c.home == building and c.state == c.State.INSIDE) or (c.state == c.State.ON_BED and c.bed != null and is_instance_valid(c.bed) and c.bed.interior_node() == self):
			show_colonist(c)
	# Anyone (a colonist or a worker) eating at a crate of this building.
	for c in get_tree().get_nodes_in_group("eaters"):
		var trip = c.get_meta(&"eat_trip")
		if trip.inside() and trip.crate_building == building:
			show_colonist(c)

func show_colonist(c) -> void:
	if shown.has(c):
		return
	var trip = c.get_meta(&"eat_trip") if c.has_meta(&"eat_trip") else null
	if trip != null and trip.inside():
		# Eating at a crate here: seen standing at it.
		shown.append(c)
		trip.show_in_room(trip.crate_spot())
		return
	if c.state == c.State.ON_BED or c.state == c.State.TO_BED:
		# Asleep on a bed of this room (or walking in to one): shown where he is.
		shown.append(c)
		c.show_in_room(c.position)
		return
	shown.append(c)
	c.show_in_room(occupant_spot(c.rest.sleeping))

# The player has left: they disappear again.
func player_left() -> void:
	player_inside = false
	for c in shown:
		if is_instance_valid(c):
			var trip = c.get_meta(&"eat_trip") if c.has_meta(&"eat_trip") else null
			if trip != null and trip.inside():
				trip.hide_from_room()
			elif is_worker_here(c) and c.order_ai.visiting == null:
				# (He goes on with his job in here, out of sight: his place in the room is the truth, nothing is moved.)
				c.hide_in_place()
			else:
				c.hide_from_room()
	shown.clear()

# The building is going: whatever lies on the floor is put out beside its door, and the room goes.
func close(near: Vector2) -> void:
	player_left()
	_clear_stock()
	var room: Rect2 = rect_world()
	# Bodies that lie in the room go with it.
	for body in get_tree().get_nodes_in_group("bodies"):
		if room.has_point(body.global_position):
			body.remove_from_group("bodies")
			body.queue_free()
	var PlankPiles = load("res://scripts/plank_piles.gd")
	# A blueprint of a Wooden Bed or a Crate gives its planks back outside; a crate gives back its planks too.
	for crate in get_tree().get_nodes_in_group("crates"):
		if room.has_point(crate.global_position):
			crate.spill_outside(near)
	for table in get_tree().get_nodes_in_group("tables"):
		if room.has_point(table.global_position):
			table.spill_outside(near)
	for other in get_tree().get_nodes_in_group("buildings"):
		if other != building and room.has_point(other.global_position) and other.building_type != null and (other.building_type.indoor_only or other.building_type.indoor_ok):
			var planks_back: int = other.planks_ready
			var at: Vector2 = near + Vector2(0, 30)
			while planks_back > 0:
				var n: int = mini(planks_back, 3)
				PlankPiles.spawn_pile(get_parent(), PlankPiles.free_spot(get_tree(), at, Rect2(0, 0, 640, 640), at), n)
				planks_back -= n
			other.remove_from_group("buildings")
			other.remove_from_group("build_blockers")
			other.queue_free()
	# The beds come apart outside (bundles, planks); then every other item is put out beside the door.
	for bed in get_tree().get_nodes_in_group("beds"):
		if room.has_point(bed.global_position):
			bed.spill_outside(near)
	for group in PlankPiles.ITEM_GROUPS:
		for item in get_tree().get_nodes_in_group(group):
			if room.has_point(item.global_position):
				item.global_position = PlankPiles.free_spot(get_tree(), near + Vector2(randf_range(-20, 20), 12), Rect2(0, 0, 640, 640), near)
	# Colonists who were working in here are put out at the door.
	for c in get_tree().get_nodes_in_group("colonists"):
		if is_worker_here(c):
			c.order_ai.on_room_closed(near)
	queue_free()
