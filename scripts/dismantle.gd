extends RefCounted

# Dismantling constructions with the hammer: one shared set of rules for every kind of construction
# (a Building blueprint or finished house, a Storage, a Sawmill, a pit saw, a proper bed, and anything
# later defined through a BuildingType).
#
#  - It takes dismantle_hits(node) = ceil(build_hits / 2) hammer presses (one press per input; the swing
#    takes longer when he is tired, the count never changes). The count so far is kept on the node.
#  - On finishing, the thing disappears and what went into it drops around its footprint as piles of up to
#    three planks (plus the saw blade of a pit saw, as an item). The refund is
#    GameClock.dismantle_refund_fraction of the materials that went in, rounded down per kind: a finished
#    building returns its full cost, a blueprint the materials delivered so far.
#  - Blocked while anyone is using it (claimed by a worker or the player, a pit saw that is sawing or has a
#    log in it), while a colonist is asleep in it, and while a Storage / Sawmill still holds anything.
#  - A house that is dismantled while nobody is inside leaves its residents unhoused.

const PlankPiles = preload("res://scripts/plank_piles.gd")
const Items = preload("res://scripts/items.gd")

const IN_USE: String = "Someone is using it."
const NOT_EMPTY: String = "Empty it first."
# The finished Storage / Sawmill that were placed by hand in the scene have no type of their own.
const FALLBACK_TYPES: Dictionary = {"storage": "res://assets/storage_type.tres", "sawmill": "res://assets/sawmill_type.tres"}
const GROUPS: Array[String] = ["buildings", "build_blockers", "pit_saws", "storages", "sawmills", "beds", "crates", "grinding_stones", "campfires", "tables"]

static func kind(node) -> String:
	if node == null or not is_instance_valid(node) or node.is_queued_for_deletion():
		return ""
	if node.is_in_group("buildings"):
		return "building"
	if node.is_in_group("pit_saws"):
		return "pit"
	if node.is_in_group("storages"):
		return "storage"
	if node.is_in_group("sawmills"):
		return "sawmill"
	if node.is_in_group("beds"):
		return "bed"
	if node.is_in_group("crates"):
		return "crate"
	if node.is_in_group("grinding_stones"):
		return "grinding_stone"
	if node.is_in_group("campfires"):
		return "campfire"
	if node.is_in_group("tables"):
		return "table"
	return ""

# Everything that can be dismantled right now (whether or not it is blocked).
static func all(tree: SceneTree) -> Array:
	var out: Array = []
	for group in ["buildings", "pit_saws", "storages", "sawmills", "beds", "crates", "grinding_stones", "campfires", "tables"]:
		for node in tree.get_nodes_in_group(group):
			if is_dismantlable(node):
				out.append(node)
	return out

# A bed is only dismantled with the hammer when it is a proper bed (a grass / hay bed is broken up by hand)
# or has planks in it for a proper bed.
static func is_dismantlable(node) -> bool:
	var k: String = kind(node)
	if k == "":
		return false
	if k == "bed":
		return node.is_wooden()
	return true

static func type_of(node) -> BuildingType:
	var t = node.get("building_type")
	if t != null:
		return t
	var k: String = kind(node)
	if FALLBACK_TYPES.has(k):
		return load(FALLBACK_TYPES[k])
	return null

static func build_hits(node) -> int:
	match kind(node):
		"building":
			return node.BUILD_HITS
		"pit":
			return node.PIT_BUILD_HITS
		"bed":
			return node.wooden_build_hits
		"crate":
			return node.crate_build_hits
		"storage", "sawmill", "grinding_stone", "campfire", "table":
			var t: BuildingType = type_of(node)
			return t.BUILD_HITS if t != null else 10
	return 10

# Presses to dismantle: half of the build hits, rounded up.
static func hits(node) -> int:
	return maxi(1, ceili(build_hits(node) / 2.0))

static func progress(node) -> int:
	return int(node.get_meta("dismantle_progress", 0))

# The materials that went into it: {"planks": n, "blades": n}.
static func materials(node) -> Dictionary:
	match kind(node):
		"building":
			var n: int = node.plank_cost if node.state == node.State.BUILT else node.planks_ready
			var items: Dictionary = node.materials_cost.duplicate() if node.state == node.State.BUILT else node.materials_ready.duplicate()
			return {"planks": n, "blades": 0, "items": items}
		"pit":
			return {"planks": node.planks_delivered, "blades": node.blades_delivered}
		"bed":
			# Its planks, and its bedding (each bundle with its age) which always comes back whole.
			return {"planks": node.wooden_planks, "blades": 0, "bundles": node.ages.duplicate()}
		"crate":
			return {"planks": node.crate_planks, "blades": 0}
		"storage", "sawmill":
			var t: BuildingType = type_of(node)
			return {"planks": t.plank_cost if t != null else 0, "blades": 0}
		"grinding_stone", "campfire", "table":
			# (The planks and the materials of the CURRENT type: the grinding stone is built from 2 flat stones now, so
			# dismantling one gives 2 flat stones back.)
			var ct: BuildingType = type_of(node)
			return {"planks": ct.plank_cost if ct != null else 0, "blades": 0, "items": ct.materials.duplicate() if ct != null else {}}
	return {"planks": 0, "blades": 0}

static func refund_fraction(tree: SceneTree) -> float:
	var clock: Node = tree.get_first_node_in_group("game_clock")
	return clock.dismantle_refund_fraction if clock != null else 1.0

static func scaled(amounts: Dictionary, fraction: float) -> Dictionary:
	var items: Dictionary = {}
	for kind in amounts.get("items", {}):
		var n: int = floori(int(amounts["items"][kind]) * fraction)
		if n > 0:
			items[kind] = n
	return {"planks": floori(amounts["planks"] * fraction), "blades": floori(amounts["blades"] * fraction), "bundles": amounts.get("bundles", []), "items": items}

static func refund(tree: SceneTree, node) -> Dictionary:
	return scaled(materials(node), refund_fraction(tree))

# Why it cannot be dismantled now ("" = it can).
static func block_reason(tree: SceneTree, node, who) -> String:
	match kind(node):
		"building":
			if node.claimed_by != null and node.claimed_by != who:
				return IN_USE
			if someone_inside(tree, node):
				return IN_USE
			if node.planks_reserved > 0:
				return IN_USE
			for c in tree.get_nodes_in_group("colonists"):
				if c.home == node and (c.state == c.State.INSIDE or c.state == c.State.ENTERING):
					return IN_USE
				if (c.state == c.State.ON_BED or c.state == c.State.TO_BED) and c.bed != null and is_instance_valid(c.bed) and c.bed.house_inside() == node:
					return IN_USE
			if "sleep_house" in who and who.sleep_house == node:
				return IN_USE
				if crates_hold_items(tree, node):
					return NOT_EMPTY
		"pit":
			if node.state == node.State.SAWING or node.state == node.State.WAITING_FOR_WORKERS:
				return IN_USE
			if node.state == node.State.LOADED:
				return NOT_EMPTY
		"storage":
			if node.logs_stored > 0 or node.planks_stored > 0 or crates_hold_items(tree, node):
				return NOT_EMPTY
			if someone_inside(tree, node):
				return IN_USE
		"table":
			if not node.is_empty():
				return "Take the item off first."
		"grinding_stone":
			if node.holds_anything():
				return NOT_EMPTY
			if node.claimed_by != null and node.claimed_by != who and is_instance_valid(node.claimed_by):
				return IN_USE
		"campfire":
			if node.claimed_by != null and node.claimed_by != who and is_instance_valid(node.claimed_by):
				return IN_USE
		"crate":
			if not node.is_empty():
				return NOT_EMPTY
			if node.claimed_by != null and node.claimed_by != who and is_instance_valid(node.claimed_by):
				return IN_USE
		"sawmill":
			if node.logs_buffered > 0 or node.planks_ready > 0:
				return NOT_EMPTY
		"bed":
			if node.sleeper != null or node.reserved_by != null:
				return IN_USE
			if node.claimed_by != null and node.claimed_by != who:
				return IN_USE
	if node.has_meta("dismantled_by") and node.get_meta("dismantled_by") != who:
		var other = node.get_meta("dismantled_by")
		if is_instance_valid(other):
			return IN_USE
	return ""

# Does any crate in this building's room hold anything?
static func crates_hold_items(tree: SceneTree, node) -> bool:
	var room = node.get("interior")
	if room == null or not is_instance_valid(room):
		return false
	var rect: Rect2 = room.rect_world()
	for crate in tree.get_nodes_in_group("crates"):
		if rect.has_point(crate.global_position) and not crate.is_empty():
			return true
	return false

# Is a colonist or worker on his way into, or inside, this building to eat from a crate?
static func someone_inside(tree: SceneTree, node) -> bool:
	for c in tree.get_nodes_in_group("eaters"):
		var trip = c.get_meta(&"eat_trip")
		if trip.crate_building == node and trip.crate_active():
			return true
	return false

# --- Claims: only one person works on it ----------------------------------------------------------

static func try_claim(node, who) -> bool:
	if node.has_method("try_claim"):
		return node.try_claim(who)
	if node.has_meta("dismantled_by") and node.get_meta("dismantled_by") != who and is_instance_valid(node.get_meta("dismantled_by")):
		return false
	node.set_meta("dismantled_by", who)
	return true

static func release_claim(node, who) -> void:
	if not is_instance_valid(node):
		return
	if node.has_method("release_claim"):
		node.release_claim(who)
	if node.has_meta("dismantled_by") and node.get_meta("dismantled_by") == who:
		node.remove_meta("dismantled_by")

# Where the player stands to hammer it, and which way he faces.
static func stand_spot(node) -> Vector2:
	if node.has_method("hammer_spot_world"):
		var spot_here: Vector2 = node.hammer_spot_world()
		# (In a room the walls keep him on the floor: stand where he can.)
		var room = room_at(node.get_tree(), node.global_position)
		return room.clamp_walk(spot_here) if room != null else spot_here
	var spot: Vector2 = node.global_position + Vector2(-22, 0)
	if kind(node) == "bed" and node.interior_node() != null:
		spot = node.interior_node().clamp_walk(spot)
	return spot

# The room (BuildingInterior) a point lies in, or null in the world.
static func room_at(tree: SceneTree, point: Vector2):
	return load("res://scripts/building_interior.gd").room_at(tree, point)

# --- Doing it ------------------------------------------------------------------------------------------

# One press. Returns {"done": presses so far, "total": presses needed, "finished": bool}.
static func hit(tree: SceneTree, node) -> Dictionary:
	var total: int = hits(node)
	var done: int = progress(node) + 1
	if done >= total:
		finish(tree, node)
		return {"done": total, "total": total, "finished": true}
	node.set_meta("dismantle_progress", done)
	return {"done": done, "total": total, "finished": false}

# The thing comes apart: its refund drops around it and it goes. (Also used by the debug key, which does
# not check the blocks: anyone on it is put off.)
static func finish(tree: SceneTree, node) -> void:
	var k: String = kind(node)
	if k == "":
		return
	var parent: Node = node.get_parent()
	var amounts: Dictionary = refund(tree, node)
	var map_rect: Rect2 = Rect2(0, 0, 640, 640)
	var m = node.get("map_rect")
	if m is Rect2:
		map_rect = m
	if k == "bed" or k == "crate":
		map_rect = node.items_rect()
	var rect: Rect2 = _rect_of(node)
	# Whoever was on it is put off, a house's residents are unhoused, and it stops being an obstacle now.
	if k == "bed":
		var sleeper = node.sleeper
		if sleeper != null and is_instance_valid(sleeper) and sleeper.has_method("wake_up"):
			sleeper.wake_up()
		node.sleeper = null
		node.reserved_by = null
	# (Out of the groups first, so the Colony cannot house the unhoused ones in it again.)
	for g in GROUPS:
		node.remove_from_group(g)
	if k == "campfire" and node.stone:
		Items.put(tree, parent, &"flat_stone", node.global_position + Vector2(0, 10), map_rect)
	if k == "campfire":
		# Whatever lies on the stone is put on the ground (a dough as flour): nothing is lost.
		for item in node.food:
			Items.put(tree, parent, &"flatbread" if item["kind"] == &"flatbread" else &"dough", node.global_position + Vector2(8, 12), map_rect)
	if k == "storage":
		if node.interior != null and is_instance_valid(node.interior):
			node.interior.close(node.door_position())
	if k == "building":
		if node.interior != null and is_instance_valid(node.interior):
			node.interior.close(node.door_position())
		for c in node.residents.duplicate():
			if is_instance_valid(c):
				c.become_unhoused()
		for c in tree.get_nodes_in_group("colonists"):
			if c.home == node:
				c.become_unhoused()
	_drop(tree, parent, rect, amounts, map_rect)
	node.queue_free()

static func _rect_of(node) -> Rect2:
	if node.has_method("footprint_rect"):
		return node.footprint_rect()
	if kind(node) == "bed":
		return Rect2(node.global_position + Vector2(-14, -8), Vector2(28, 10))
	return Footprints.blocker_rect(node)

# Piles of up to 3 planks (and the blades) on free ground around `rect`.
static func _drop(tree: SceneTree, parent: Node, rect: Rect2, amounts: Dictionary, map_rect: Rect2) -> void:
	var ring: Rect2 = rect.grow(10.0)
	var corners: Array[Vector2] = [
		Vector2(ring.position.x, ring.end.y), Vector2(ring.end.x, ring.end.y),
		Vector2(ring.position.x, ring.position.y + ring.size.y * 0.5), Vector2(ring.end.x, ring.position.y + ring.size.y * 0.5),
		Vector2(ring.position.x + ring.size.x * 0.5, ring.end.y), ring.position, Vector2(ring.end.x, ring.position.y),
		Vector2(ring.position.x + ring.size.x * 0.5, ring.position.y),
	]
	var i: int = 0
	var left: int = amounts["planks"]
	while left > 0:
		var n: int = mini(left, PlankPiles.MAX_PER_PILE)
		var near: Vector2 = corners[i % corners.size()]
		PlankPiles.spawn_pile(parent, PlankPiles.free_spot(tree, near, map_rect, near), n)
		left -= n
		i += 1
	for b in amounts["blades"]:
		var near: Vector2 = corners[i % corners.size()]
		PlankPiles.spawn_blade(parent, PlankPiles.free_spot(tree, near, map_rect, near))
		i += 1
	# Materials (branches, flat stones) come back as items.
	for kind in amounts.get("items", {}):
		for n in int(amounts["items"][kind]):
			var near_i: Vector2 = corners[i % corners.size()]
			Items.put(tree, parent, StringName(kind), near_i, map_rect)
			i += 1
	# Bedding comes back as bundles (each with its own age).
	for age in amounts.get("bundles", []):
		var near: Vector2 = corners[i % corners.size()]
		PlankPiles.spawn_bundle_pile(parent, PlankPiles.free_spot(tree, near, map_rect, near), age)
		i += 1
