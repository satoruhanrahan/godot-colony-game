extends RefCounted

# The items of the food chain (and the three new tools): one place that knows their names, pictures and
# what lies on the ground. Each is a normal one-held-item thing: the player holds it in `held_tool` (like the
# hammer or the basket), puts it down with Q, and it lies on the ground as a GroundItem. The seed bag also
# keeps its seed count (held_seeds in his hands, `seeds` on the ground).

const GroundItemScene = preload("res://scenes/GroundItem.tscn")

# kind -> [name, picture]
const KINDS: Dictionary = {
	&"seed_bag": ["Seed bag", "res://sprites/seed_bag.png"],
	&"wheat_sheaf": ["Wheat sheaf", "res://sprites/wheat_sheaf.png"],
	&"flour": ["Flour", "res://sprites/flour_bag.png"],
	&"flatbread": ["Flatbread", "res://sprites/flatbread.png"],
	&"flat_stone": ["Flat stone", "res://sprites/stone.png"],
	&"branch": ["Branch", "res://sprites/branch.png"],
	&"hoe": ["Hoe", "res://sprites/hoe.png"],
	&"sickle": ["Sickle", "res://sprites/sickle.png"],
	&"fire_starter": ["Fire starter", "res://sprites/fire_starter.png"],
	&"bucket": ["Bucket", "res://sprites/bucket.png"],
	&"dough": ["Dough", "res://sprites/dough.png"],
	&"dough_board": ["Dough board", "res://sprites/dough_board.png"],
}
const DoughBoardScene = preload("res://scenes/DoughBoard.tscn")
const TOOLS: Array[StringName] = [&"hoe", &"sickle", &"fire_starter"]

static var _textures: Dictionary = {}

static func is_item(kind: StringName) -> bool:
	return KINDS.has(kind)

static func is_tool(kind: StringName) -> bool:
	return TOOLS.has(kind)

static func name_of(kind: StringName) -> String:
	return KINDS[kind][0] if KINDS.has(kind) else String(kind)

static func texture(kind: StringName) -> Texture2D:
	if not _textures.has(kind):
		_textures[kind] = load(KINDS[kind][1])
	return _textures[kind]

# The hover text of a thing lying on the ground.
static func hover_text(kind: StringName, amount: int) -> String:
	if kind == &"seed_bag":
		var capacity: int = load("res://scripts/food_config.gd").cfg().seed_bag_capacity
		return "Seed bag %d/%d" % [amount, capacity] if amount > 0 else "Seed bag (empty)"
	if kind == &"bucket":
		var cap: int = load("res://scripts/food_config.gd").cfg().bucket_capacity
		return "Bucket %d/%d" % [amount, cap] if amount > 0 else "Bucket (empty)"
	return name_of(kind)

# An item put on the ground at `spot` (under the y-sorted `parent`).
# `seeds` is the item's amount: the seeds of a seed bag, the scoops of water in a bucket.
static func spawn(kind: StringName, parent: Node, spot: Vector2, seeds: int = 0) -> Node2D:
	if kind == &"dough_board":
		return spawn_board(parent, spot, {})
	var item: Node2D = GroundItemScene.instantiate()
	item.kind = kind
	if kind == &"bucket":
		item.scoops = seeds
	else:
		item.seeds = seeds
	# (Items never pile on one spot: the wanted spot moves to the nearest free ground, see GroundPlacement.)
	item.position = load("res://scripts/ground_placement.gd").clear_spot(parent, spot)
	parent.add_child(item)
	return item

# An item put on the nearest free ground to `near`.
static func put(tree: SceneTree, parent: Node, kind: StringName, near: Vector2, map_rect: Rect2, seeds: int = 0) -> Node2D:
	var PlankPiles = load("res://scripts/plank_piles.gd")
	return spawn(kind, parent, PlankPiles.free_spot(tree, near, map_rect, near), seeds)

# A dough board (an item that keeps its state: flour, water, dough) made but not yet put anywhere.
static func make_board(state: Dictionary) -> Node2D:
	var board: Node2D = DoughBoardScene.instantiate()
	board.init_state = state
	return board

static func spawn_board(parent: Node, spot: Vector2, state: Dictionary) -> Node2D:
	var board: Node2D = make_board(state)
	board.position = load("res://scripts/ground_placement.gd").clear_spot(parent, spot, Vector2(16, 12))
	parent.add_child(board)
	return board
