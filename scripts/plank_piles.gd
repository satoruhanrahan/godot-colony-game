extends RefCounted

# Shared rules for putting planks on the ground, used by the player (Q), the Hauler (the
# PlankYard) and the pit saw (its finished pile of three).

const PILE_SCENE: PackedScene = preload("res://scenes/PlankPile.tscn")
const MAX_PER_PILE: int = 3
const GroundPlacement = preload("res://scripts/ground_placement.gd")
# Everything that lies on the ground as an item (nothing is dropped or built on top of another).
const ITEM_GROUPS: Array[String] = GroundPlacement.ITEM_GROUPS
# Two piles are never closer than this (their art is about 20 px wide).
const SPACING: float = 12.0

# The nearest pile within `radius` of `point` that still has room (fewer than 3 planks).
static func nearest_open_pile(tree: SceneTree, point: Vector2, radius: float):
	var best = null
	var best_dist: float = INF
	for pile in tree.get_nodes_in_group("plank_piles"):
		if pile.count >= MAX_PER_PILE:
			continue
		var d: float = pile.global_position.distance_to(point)
		if d <= radius and d < best_dist:
			best_dist = d
			best = pile
	return best

# Planks lying in piles within `radius` of `point`.
static func planks_within(tree: SceneTree, point: Vector2, radius: float) -> int:
	var total: int = 0
	for pile in tree.get_nodes_in_group("plank_piles"):
		if pile.global_position.distance_to(point) <= radius:
			total += pile.count
	return total

# Is this ground point free for an item to lie on (see GroundPlacement.is_free: inside the map, off the water, clear of
# solids and buildings and of every other item's pickup shape)?
static func is_free(tree: SceneTree, point: Vector2, map_rect: Rect2) -> bool:
	return GroundPlacement.is_free(tree, point, Vector2(12, 10), map_rect)

# The nearest free ground to `near` for a new pile or item (GroundPlacement.find_free_ground_near: the spot itself, else an
# outward search). If there is nowhere, returns `fallback`.
static func free_spot(tree: SceneTree, near: Vector2, map_rect: Rect2, fallback: Vector2) -> Vector2:
	var spot: Vector2 = GroundPlacement.find_free_ground_near(tree, near, Vector2(12, 10), map_rect, 84.0)
	return fallback.round() if spot == Vector2.INF else spot

# Is an item (pile, blade, tool) lying within `distance` of this point?
static func _pile_closer_than(tree: SceneTree, p: Vector2, distance: float) -> bool:
	for group in ITEM_GROUPS:
		for item in tree.get_nodes_in_group(group):
			if item.global_position.distance_to(p) < distance:
				return true
	return false

# Is an item (pile, blade, tool) lying inside this ground rectangle (so nothing may be built
# over it)?
static func item_in_rect(tree: SceneTree, rect: Rect2) -> bool:
	for group in ITEM_GROUPS:
		for item in tree.get_nodes_in_group(group):
			if rect.has_point(item.global_position):
				return true
	return false

const BLADE_SCENE: PackedScene = preload("res://scenes/SawBlade.tscn")

# A saw blade put down at `spot` (under the y-sorted `parent`).
static func spawn_blade(parent: Node, spot: Vector2):
	var blade = BLADE_SCENE.instantiate()
	blade.position = GroundPlacement.clear_spot(parent, spot)
	parent.add_child(blade)
	return blade

const HAMMER_SCENE: PackedScene = preload("res://scenes/Hammer.tscn")
const SHOVEL_SCENE: PackedScene = preload("res://scenes/Shovel.tscn")
const AXE_SCENE: PackedScene = preload("res://scenes/Axe.tscn")
const BUNDLE_PILE_SCENE: PackedScene = preload("res://scenes/BundlePile.tscn")

# The hammer put down at `spot` (under the y-sorted `parent`).
static func spawn_hammer(parent: Node, spot: Vector2):
	return _spawn(HAMMER_SCENE, parent, spot)

static func spawn_shovel(parent: Node, spot: Vector2):
	return _spawn(SHOVEL_SCENE, parent, spot)

static func spawn_axe(parent: Node, spot: Vector2):
	return _spawn(AXE_SCENE, parent, spot)

# A bundle of grass (with this age in clock seconds) lying at `spot`, as a pile of 1.
static func spawn_bundle_pile(parent: Node, spot: Vector2, age: float):
	var pile = BUNDLE_PILE_SCENE.instantiate()
	pile.position = GroundPlacement.clear_spot(parent, spot, Vector2(20, 12))
	pile.ages.append(age)
	parent.add_child(pile)
	return pile

# The nearest bundle pile within `radius` of `point` that still has room.
static func nearest_open_bundle_pile(tree: SceneTree, point: Vector2, radius: float):
	var best = null
	var best_dist: float = INF
	for pile in tree.get_nodes_in_group("bundle_piles"):
		if pile.is_full():
			continue
		var d: float = pile.global_position.distance_to(point)
		if d <= radius and d < best_dist:
			best_dist = d
			best = pile
	return best

# One bundle put on the ground at/near `near`: into the nearest pile with room (the third one makes a bed),
# else a new pile of 1.
static func put_bundle(tree: SceneTree, parent: Node, near: Vector2, merge_radius: float, map_rect: Rect2, fallback: Vector2, age: float):
	# A pile of two in a house that cannot fit another bed takes no third bundle (it says so, once).
	for blocked in tree.get_nodes_in_group("bundle_piles"):
		if blocked.global_position.distance_to(near) <= merge_radius and blocked.count() >= 2 and blocked.is_full() and blocked._house_is_full():
			blocked.say_no_room()
			break
	var pile = nearest_open_bundle_pile(tree, near, merge_radius)
	if pile != null:
		pile.add_bundle(age)
		return pile
	return spawn_bundle_pile(parent, free_spot(tree, near, map_rect, fallback), age)

# A tool by name ("hammer", "shovel" or "axe") put down at `spot`.
static func spawn_tool(tool: StringName, parent: Node, spot: Vector2):
	match tool:
		&"shovel":
			return spawn_shovel(parent, spot)
		&"axe":
			return spawn_axe(parent, spot)
	return spawn_hammer(parent, spot)

static func _spawn(scene: PackedScene, parent: Node, spot: Vector2):
	var item = scene.instantiate()
	item.position = GroundPlacement.clear_spot(parent, spot)
	parent.add_child(item)
	return item

# A new pile of `count` planks at `spot` (under the y-sorted `parent`).
static func spawn_pile(parent: Node, spot: Vector2, count: int):
	var pile = PILE_SCENE.instantiate()
	pile.position = GroundPlacement.clear_spot(parent, spot, Vector2(20, 10))
	pile.count = count
	parent.add_child(pile)
	return pile

# One plank put on the ground at/near `near`: into the nearest pile within `merge_radius`
# that has fewer than 3 planks, else a new pile of 1 on the nearest free spot (or at
# `fallback` if there is none).
static func put_plank(tree: SceneTree, parent: Node, near: Vector2, merge_radius: float, map_rect: Rect2, fallback: Vector2):
	var pile = nearest_open_pile(tree, near, merge_radius)
	if pile != null:
		pile.add_plank()
		return pile
	return spawn_pile(parent, free_spot(tree, near, map_rect, fallback), 1)
