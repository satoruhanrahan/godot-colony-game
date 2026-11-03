extends RefCounted

# WHERE THINGS GO AND WHERE THEY COME FROM: the one set of rules the colonists' work jobs (work_jobs.gd) use to move logs, planks
# and loose items about. Everything here is a question about the world (no state of its own), so a Hauler, a Sawyer, a Lumberjack and a
# Builder all ask the same questions and get the same answers; the target objects' own methods do the actual taking and putting
# (tree.claim_log, storage.add_log, pit_saw.accept_log, pile.reserve ...), exactly as the player and the NPC workers use them.

const TRUNK_TEXTURE: Texture2D = preload("res://sprites/tree_trunk.png")
const LogDragger = preload("res://scripts/log_dragger.gd")
const BuildingInterior = preload("res://scripts/building_interior.gd")

# Where a person stands to hand something to each kind of building (the Hauler's offsets).
const STORAGE_STOP_OFFSET: Vector2 = Vector2(0, 16)
const SAWMILL_STOP_OFFSET: Vector2 = Vector2(0, 27)
const BUILDING_STOP_OFFSET: Vector2 = Vector2(0, 31)

# The ground a person's feet can be on. A spot of a building that already stands at the edge of the map (new ones cannot be placed there:
# BuildMode.check_outdoor) moves to the nearest point inside it.
const WALK_RECT: Rect2 = Rect2(2, 16, 636, 624)

static func inside_map(spot: Vector2) -> Vector2:
	return spot.clamp(WALK_RECT.position, WALK_RECT.end)

# The place beside a building (`offset` from its origin, the hammer / dig spot): on the other side when this one would be outside the map.
static func beside_spot(origin: Vector2, offset: Vector2) -> Vector2:
	var spot: Vector2 = origin + offset
	if spot.x < WALK_RECT.position.x or spot.x > WALK_RECT.end.x:
		var other: Vector2 = origin + Vector2(-offset.x, offset.y)
		if other.x >= WALK_RECT.position.x and other.x <= WALK_RECT.end.x:
			return other
	return inside_map(spot)

# Where he stands to hand things to a blueprint outdoors (in front of it).
static func front_spot(origin: Vector2) -> Vector2:
	return inside_map(origin + BUILDING_STOP_OFFSET)

static func nearest(nodes: Array, from: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d: float = INF
	for n in nodes:
		var d: float = from.distance_squared_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best

# A destination for a log: {"node", "kind" ("pit" / "storage" / "sawmill"), "stop"} or {}. The pit saw first (it is where logs become
# planks), then Storage, then the Sawmill; `prefer_storage` puts Storage first (the Hauler's way).
static func log_destination(tree: SceneTree, from: Vector2, prefer_storage: bool = false) -> Dictionary:
	var options: Array = []
	var pits: Array = tree.get_nodes_in_group("pit_saws").filter(func(p) -> bool: return p.can_load())
	var stores: Array = tree.get_nodes_in_group("storages").filter(func(s) -> bool: return s.has_log_room())
	var mills: Array = tree.get_nodes_in_group("sawmills").filter(func(m) -> bool: return m.has_room())
	var pit: Node2D = nearest(pits, from)
	var store: Node2D = nearest(stores, from)
	var mill: Node2D = nearest(mills, from)
	if prefer_storage:
		options = [["storage", store], ["pit", pit], ["sawmill", mill]]
	else:
		options = [["pit", pit], ["storage", store], ["sawmill", mill]]
	for o in options:
		if o[1] != null:
			var node: Node2D = o[1]
			var stop: Vector2 = node.interact_point() if o[0] == "pit" else (node.global_position + (STORAGE_STOP_OFFSET if o[0] == "storage" else SAWMILL_STOP_OFFSET))
			return {"node": node, "kind": o[0], "stop": inside_map(stop).round()}
	return {}

# Hands the log to the destination; false if it was refused (it filled up meanwhile).
static func accept_log(dest: Dictionary) -> bool:
	var node = dest.get("node")
	if node == null or not is_instance_valid(node):
		return false
	match dest["kind"]:
		"pit", "sawmill":
			return node.accept_log()
		"storage":
			return node.add_log()
	return false

# Storage with room for a plank: {"node", "stop"} or {}.
static func plank_destination(tree: SceneTree, from: Vector2) -> Dictionary:
	var store: Node2D = nearest(tree.get_nodes_in_group("storages").filter(func(s) -> bool: return s.plank_room() > 0), from)
	if store == null:
		return {}
	return {"node": store, "stop": (store.global_position + STORAGE_STOP_OFFSET).round()}

# A crate that takes this kind of item and has room: {"node", "host", "door"} or {}. (Crates stand inside buildings: he goes to the door,
# is inside a moment, and comes out.)
static func item_destination(tree: SceneTree, kind: StringName, from: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = INF
	for crate in tree.get_nodes_in_group("crates"):
		if not crate.accepts(kind) or crate.is_full():
			continue
		var host = crate.host_building()
		if host == null or not is_instance_valid(host):
			continue
		var door: Vector2 = host.door_position()
		var d: float = from.distance_squared_to(door)
		if d < best_d:
			best_d = d
			best = {"node": crate, "host": host, "door": door}
	return best

# Trees whose log lies ready for anyone to take.
static func loose_logs(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group("trees").filter(func(t) -> bool: return t.is_delimbed() and t.logs_ready > 0 and t.log_claimed_by == null and t.log_node() != null)

# Plank piles with a plank nobody has claimed.
static func free_piles(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group("plank_piles").filter(func(p) -> bool: return p.available() > 0)

# Loose items some crate would take (a wheat sheaf, flour, flatbread, a seed bag): they lie on the ground (not on a table).
static func crate_items(tree: SceneTree) -> Array:
	var out: Array = []
	for item in tree.get_nodes_in_group("ground_items"):
		if item.is_queued_for_deletion() or not item.visible or item.get_parent() is Node2D and item.get_parent().is_in_group("tables"):
			continue
		if not [&"wheat_sheaf", &"flour", &"flatbread", &"seed_bag"].has(item.kind):
			continue
		out.append(item)
	return out

# A log leaving Storage is made here: lying along x just in front of the door, like the Hauler's.
static func spawn_storage_log(storage: Node2D, parent: Node) -> Sprite2D:
	var stored_log := Sprite2D.new()
	stored_log.texture = TRUNK_TEXTURE
	stored_log.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	stored_log.offset = Vector2(0, -14)
	stored_log.rotation_degrees = -90.0
	stored_log.position = (storage.position + STORAGE_STOP_OFFSET + Vector2(LogDragger.LOG_LENGTH * 0.5, LogDragger.LOG_Y)).round()
	parent.add_child(stored_log)
	return stored_log

# Everything that can be built lives in one of these groups and answers the same questions (is_blueprint(), is_finished(), planks_needed(),
# material_missing(), needs_digging() ... see Building and PitSaw): a new kind of buildable only has to do the same, nothing here is special-cased.
const BUILDABLE_GROUPS: Array[String] = ["buildings", "pit_saws"]

# Blueprints a Builder may work on, of every type: outdoors and in the rooms of buildings (a bed, a crate or a table planned inside a House or a Storage).
static func blueprints(tree: SceneTree) -> Array:
	var out: Array = []
	for group in BUILDABLE_GROUPS:
		for b in tree.get_nodes_in_group(group):
			if b.has_method("is_blueprint") and b.is_blueprint() and not b.is_queued_for_deletion() and not out.has(b):
				out.append(b)
	return out

# The kinds of blueprint the board lists now: {name: count}.
static func blueprint_types(tree: SceneTree) -> Dictionary:
	var out: Dictionary = {}
	for b in blueprints(tree):
		var n: String = b.display_name()
		out[n] = int(out.get(n, 0)) + 1
	return out

# --- Rooms: where a point is, and what the way there costs ----------------------------------------------------------------------------

# The room (BuildingInterior) that holds a world point, or null outdoors.
static func room_of(tree: SceneTree, point: Vector2) -> Node2D:
	if not BuildingInterior.is_interior_point(point):
		return null
	return BuildingInterior.room_at(tree, point)

# The host building (a House, a Storage) of the room at a point, null outdoors.
static func host_of(tree: SceneTree, point: Vector2) -> Node2D:
	var room: Node2D = room_of(tree, point)
	return room.building if room != null and is_instance_valid(room.building) else null

# "House", "Storage": for the status line ("Building a wooden bed in the House").
static func host_name(host) -> String:
	if host != null and is_instance_valid(host):
		if host.has_method("display_name"):
			return host.display_name()
		if "building_type" in host and host.building_type != null:
			return host.building_type.type_name
	return "building"

# A walk from `a` to `b` in pixels, counting the way through the doors when they are not in the same place (outdoors / a room).
# For choosing the nearest of several things; not the exact path.
static func travel_cost(tree: SceneTree, a: Vector2, b: Vector2) -> float:
	var ra: Node2D = room_of(tree, a)
	var rb: Node2D = room_of(tree, b)
	if ra == rb:
		return a.distance_to(b)
	var cost: float = 24.0
	if ra != null:
		cost += a.distance_to(ra.exit_point_world())
		a = ra.building.door_position()
	if rb != null:
		cost += a.distance_to(rb.building.door_position()) + rb.door_world().distance_to(b)
	else:
		cost += a.distance_to(b)
	return cost

# The nearest of `nodes` by the walk (through the doors) from `from`.
static func nearest_by_walk(tree: SceneTree, nodes: Array, from: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d: float = INF
	for n in nodes:
		var d: float = travel_cost(tree, from, n.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best

# What a blueprint covers on the floor (a flat bed its picture, a solid thing its base).
static func cover_rect(tree: SceneTree, bp: Node2D) -> Rect2:
	var bm: Node = tree.get_first_node_in_group("build_mode")
	if bm != null and bp.building_type != null:
		return bm.floor_cover(bp.building_type, bp.global_position)
	return Rect2(bp.global_position + Vector2(-8, -8), Vector2(16, 8))

# Where a plank for a blueprint can come from: {"kind": "storage" / "sawmill" / "pile", "node"} or {}.
static func plank_source(tree: SceneTree, from: Vector2) -> Dictionary:
	var piles: Array = free_piles(tree)
	var pile: Node2D = nearest_by_walk(tree, piles, from)
	var store: Node2D = nearest_by_walk(tree, tree.get_nodes_in_group("storages").filter(func(s) -> bool: return s.planks_stored > 0), from)
	var mill: Node2D = nearest_by_walk(tree, tree.get_nodes_in_group("sawmills").filter(func(m) -> bool: return m.planks_ready > 0), from)
	var best: Dictionary = {}
	var best_d: float = INF
	for o in [["pile", pile], ["storage", store], ["sawmill", mill]]:
		if o[1] != null:
			var d: float = travel_cost(tree, from, o[1].global_position)
			if d < best_d:
				best_d = d
				best = {"kind": o[0], "node": o[1]}
	return best

# Where an item of a kind a blueprint needs (a flat stone, a branch) lies: the nearest loose one, or null.
static func material_source(tree: SceneTree, kind: StringName, from: Vector2) -> Node2D:
	# (a saw blade is an object of its own, not a ground item)
	if kind == &"saw_blade":
		return nearest_by_walk(tree, tree.get_nodes_in_group("saw_blades").filter(func(i) -> bool: return not i.is_queued_for_deletion() and (i.get_meta(&"claimed_by") if i.has_meta(&"claimed_by") else null) == null), from)
	return nearest_by_walk(tree, tree.get_nodes_in_group("ground_items").filter(func(i) -> bool: return i.kind == kind and not i.is_queued_for_deletion() and (i.get_meta(&"claimed_by") if i.has_meta(&"claimed_by") else null) == null), from)
