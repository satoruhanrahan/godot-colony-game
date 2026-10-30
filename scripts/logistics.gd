extends RefCounted

# WHERE THINGS GO AND WHERE THEY COME FROM: the one set of rules the colonists' work jobs (work_jobs.gd) use to move logs, planks
# and loose items about. Everything here is a question about the world (no state of its own), so a Hauler, a Sawyer, a Lumberjack and a
# Builder all ask the same questions and get the same answers; the target objects' own methods do the actual taking and putting
# (tree.claim_log, storage.add_log, pit_saw.accept_log, pile.reserve ...), exactly as the player and the NPC workers use them.

const TRUNK_TEXTURE: Texture2D = preload("res://sprites/tree_trunk.png")
const LogDragger = preload("res://scripts/log_dragger.gd")

# Where a person stands to hand something to each kind of building (the Hauler's offsets).
const STORAGE_STOP_OFFSET: Vector2 = Vector2(0, 16)
const SAWMILL_STOP_OFFSET: Vector2 = Vector2(0, 27)
const BUILDING_STOP_OFFSET: Vector2 = Vector2(0, 31)

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
			return {"node": node, "kind": o[0], "stop": stop.round()}
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

# Blueprints a Builder may work on (outdoors only: the ones in a room are the player's).
static func blueprints(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group("buildings").filter(func(b) -> bool: return b.state != b.State.BUILT and b.global_position.x < 2000.0 and b.building_type != null and not b.building_type.indoor_only)

# Where a plank for a blueprint can come from: {"kind": "storage" / "sawmill" / "pile", "node"} or {}.
static func plank_source(tree: SceneTree, from: Vector2) -> Dictionary:
	var piles: Array = free_piles(tree)
	var pile: Node2D = nearest(piles, from)
	var store: Node2D = nearest(tree.get_nodes_in_group("storages").filter(func(s) -> bool: return s.planks_stored > 0), from)
	var mill: Node2D = nearest(tree.get_nodes_in_group("sawmills").filter(func(m) -> bool: return m.planks_ready > 0), from)
	var best: Dictionary = {}
	var best_d: float = INF
	for o in [["pile", pile], ["storage", store], ["sawmill", mill]]:
		if o[1] != null:
			var d: float = from.distance_squared_to(o[1].global_position)
			if d < best_d:
				best_d = d
				best = {"kind": o[0], "node": o[1]}
	return best

# Where an item of a kind a blueprint needs (a flat stone, a branch) lies: the nearest loose one, or null.
static func material_source(tree: SceneTree, kind: StringName, from: Vector2) -> Node2D:
	return nearest(tree.get_nodes_in_group("ground_items").filter(func(i) -> bool: return i.kind == kind and not i.is_queued_for_deletion() and i.get_meta(&"claimed_by", null) == null), from)
