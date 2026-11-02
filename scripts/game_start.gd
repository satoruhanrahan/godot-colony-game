extends Node2D

# The main scene's start-up switch.
#
# opening_mode ON (the new opening): the game starts with only the MainCharacter and his
# friend. The Storage, Sawmill and House that sit in the scene, and the Lumberjack, Hauler
# and Builder, are taken out before the game begins (freed, not hidden), so nothing of them
# exists in the world; the pit saw starts as marked ground; the MainCharacter starts at the
# LandingPoint with the friend. The player does everything by hand and builds the rest.
#
# opening_mode OFF: nothing here does anything, so the scene starts exactly as it used to
# (every worker automated, a finished pit saw, Storage, Sawmill and House in place).
@export var opening_mode: bool = true
# (The offsets below that place supplies near the landing point are no longer used: all the supplies are in the starting yard.)
# Where the MainCharacter starts, relative to the LandingPoint (the friend lands on it).
@export var player_start_offset: Vector2 = Vector2(24, 0)
# The only supplies in the opening, lying on the ground near the start (relative to the
# LandingPoint): a pile of 2 planks, a saw blade and the three tools (shovel, hammer, axe). The
# first pit saw needs the shovel to dig, the planks and the blade, and the hammer to finish it;
# the axe is for the trees. Each tool is the only one there is.
@export var starting_planks_offset: Vector2 = Vector2(40, -22)
@export var starting_blade_offset: Vector2 = Vector2(40, 10)
@export var starting_planks: int = 2
# The one hammer of the opening (building needs it in his hands), a short way from the planks
# and the blade.
@export var starting_hammer_offset: Vector2 = Vector2(58, -6)
@export var starting_shovel_offset: Vector2 = Vector2(74, -26)
@export var starting_axe_offset: Vector2 = Vector2(74, 14)
# The basket for picking berries, lying near the start with the other supplies.
@export var starting_basket_offset: Vector2 = Vector2(58, 28)

# The trees (see tree_scatter.gd): natural groves and lone trees instead of a grid, the same every run for the same seed.
@export_group("Trees")
# The scene used to hold this many trees on a regular grid; the new count is this times trees_count_multiplier.
@export var trees_original_count: int = 6
@export var trees_count_multiplier: float = 1.8
# 0 = a different layout every run.
@export var tree_seed: int = 4242
# No tree within this many tiles (32 px) of the cabin.
@export var tree_clear_radius_cabin: float = 6.0
# Spacing between neighbouring trees: close in a grove, far for a lone tree.
@export var tree_min_spacing_tiles: float = 1.5
@export var tree_max_spacing_tiles: float = 8.0
# The nearest tree to the cabin must stand between these (so the first trees are a sensible walk).
@export var tree_nearest_cabin_min_tiles: float = 8.0
@export var tree_nearest_cabin_max_tiles: float = 14.0
@export_group("")

# What the tree placement found, for the self-check and the report: {count, old, attempt, seed, report}.
var tree_layout: Dictionary = {}

const PlankPiles = preload("res://scripts/plank_piles.gd")
const TreeScatter = preload("res://scripts/tree_scatter.gd")
const TreeScene = preload("res://scenes/Tree.tscn")

# The tools of the opening and the export that says where each one starts.
const TOOLS: Dictionary = {&"hammer": &"starting_hammer_offset", &"shovel": &"starting_shovel_offset", &"axe": &"starting_axe_offset"}
const TOOL_GROUPS: Dictionary = {&"hammer": "hammers", &"shovel": "shovels", &"axe": "axes"}

const REMOVED_IN_OPENING: Array[String] = ["Storage", "Sawmill", "House", "Lumberjack", "Hauler", "Builder"]

# Runs before any child has been readied, so the removed nodes never start up (the
# Lumberjack, for instance, would otherwise claim a tree) and the pit saw reads its start
# state when it is readied.
func _enter_tree() -> void:
	# The water data first (before any child is readied, so the bushes, grass and everything else placed on the
	# ground keep out of it); its picture and collision are added once the tree is up.
	var cabin_node: Node2D = get_node_or_null("Cabin")
	WaterMap.generate(cabin_node.position if cabin_node != null else Vector2(160, 73))
	_add_water_layer.call_deferred()
	_place_trees()
	if not opening_mode:
		return
	for node_name in REMOVED_IN_OPENING:
		var node: Node = get_node_or_null(node_name)
		if node != null:
			remove_child(node)
			node.free()
	var pit = get_node_or_null("PitSaw")
	if pit != null:
		pit.starts_built = false

# The trees, placed before anything else is readied (the Lumberjack, bushes, grass and the opening's items all look at
# the "trees" group, so the trees come first in the scene). They keep away from the cabin, the creek, the buildings and
# the places the opening puts its supplies and its people.
func _place_trees() -> void:
	var cabin: Node2D = get_node_or_null("Cabin")
	var cabin_at: Vector2 = cabin.position if cabin != null else Vector2(160, 73)
	var keep_out: Array = [[cabin_at + Vector2(0, 18), 60.0]]
	# the buildings of the scene (those the opening removes included), the yard and the people
	for node_name in ["Storage", "Sawmill", "House", "PitSaw", "PlankYard", "Lumberjack", "Hauler", "Builder", "MainCharacter"]:
		var node: Node2D = get_node_or_null(node_name)
		if node != null:
			keep_out.append([node.position, 60.0 if node_name in ["Storage", "Sawmill", "House", "PitSaw"] else 44.0])
	# the opening's supplies lie round the landing point
	var landing: Node2D = get_node_or_null("LandingPoint")
	if landing != null:
		keep_out.append([landing.position + Vector2(48, 0), 72.0])
	var count: int = int(round(trees_original_count * trees_count_multiplier))
	var result: Dictionary = TreeScatter.generate({
		"count": count, "seed": tree_seed, "cabin": cabin_at, "clear_radius_tiles": tree_clear_radius_cabin,
		"min_spacing_tiles": tree_min_spacing_tiles, "max_spacing_tiles": tree_max_spacing_tiles,
		"nearest_min_tiles": tree_nearest_cabin_min_tiles, "nearest_max_tiles": tree_nearest_cabin_max_tiles, "keep_out": keep_out,
	})
	var index: int = 1   # (after the Ground, before everything that looks for trees when it is readied)
	for p in result["points"]:
		var tree: Node2D = TreeScene.instantiate()
		tree.name = "Tree%d" % (index)
		tree.position = p
		add_child(tree)
		move_child(tree, index)
		index += 1
	tree_layout = {"count": result["points"].size(), "old": trees_original_count, "attempt": result["attempt"], "seed": result["seed"], "report": result["report"], "points": result["points"]}

# In the opening the player works with tools: digging needs the shovel in his hands, chopping the
# axe, hammering the hammer. (Without the opening there are no tools and nothing is required.)
func tools_required() -> bool:
	return opening_mode

# True once any pit saw has been finished (it stays true after that).
var _first_pit_built: bool = false

# In the opening, until the first pit saw is built, the planks and the blade are kept for it:
# the plank-cost buildings (House, Storage, Sawmill) are locked in build mode, and planks
# cannot be delivered to another blueprint or stored.
func supplies_locked() -> bool:
	return opening_mode and not _first_pit_built

func _process(_delta: float) -> void:
	if opening_mode and not _first_pit_built:
		for pit in get_tree().get_nodes_in_group("pit_saws"):
			if pit.is_built():
				_first_pit_built = true
	if opening_mode and toolbox != null:
		_keep_the_tools()

# Each tool is the only one there is: if one is neither lying on the ground nor in his hands (it
# should never happen), a new one is put down beside him.
func _in_toolbox(tool: StringName) -> bool:
	return toolbox != null and is_instance_valid(toolbox) and toolbox.kinds().has(tool)

# A tool a colonist holds (taken from the toolbox for his work, or picked up) is not lost either.
func _held_by_a_colonist(tool: StringName) -> bool:
	if toolbox != null and is_instance_valid(toolbox) and toolbox.borrowed_by(tool) != null:
		return true
	for c in get_tree().get_nodes_in_group("colonists"):
		if c.get("order_ai") != null and c.order_ai.tools != null and c.order_ai.tools.held == tool:
			return true
	return false

func _keep_the_tools() -> void:
	var player = get_node_or_null("MainCharacter")
	if player == null:
		return
	for tool in TOOLS:
		if player.held_tool == tool or get_tree().get_nodes_in_group(TOOL_GROUPS[tool]).size() > 0 or _in_toolbox(tool) or _held_by_a_colonist(tool):
			continue
		var spot: Vector2 = PlankPiles.free_spot(get_tree(), player.position + Vector2(14, 0), Rect2(0, 0, 640, 640), player.position)
		PlankPiles.spawn_tool(tool, self, spot)
		push_warning("The %s was lost; put a new one down beside the player" % tool)

# The hoe, the sickle, the fire starter and ONE seed bag (4 seeds) lie near the cabin; flat stones and branches are
# scattered loosely over the grass (flat_stones_on_map / branches_on_map in the FoodConfig), away from everything.
const WaterMap = preload("res://scripts/water_map.gd")
const FoodItems = preload("res://scripts/items.gd")
const FoodConfig = preload("res://scripts/food_config.gd")

func _add_water_layer() -> void:
	var layer: Node2D = (load("res://scripts/water_layer.gd") as GDScript).new()
	layer.name = "WaterLayer"
	add_child(layer)

func place_food_start() -> void:
	var cfg: Resource = FoodConfig.cfg()
	var map := Rect2(0, 0, 640, 640)
	var cabin: Node2D = get_node_or_null("Cabin")
	var anchor: Vector2 = cabin.position + Vector2(0, 18) if cabin != null else get_node("LandingPoint").position + Vector2(0, -40)
	# (The hoe, the sickle and the fire starter, like the hammer, the shovel and the axe, are in the toolbox now.)
	_place_toolbox(anchor)
	_place_start_yard(anchor, cfg)
	_scatter(&"flat_stone", cfg.flat_stones_on_map, 1)
	_scatter(&"branch", cfg.branches_on_map, 2)

# THE ONE STARTING YARD: every starting resource lies in tidy rows on the east side of the cabin (the toolbox stands on its west
# side), well clear of the cabin's door and of the toolbox: 2 planks and the saw blade, the basket, the seed bag, the bucket and the
# dough board. Each goes to its place in the grid, or the nearest free ground to it (find_free_ground_near), so nothing overlaps.
# (The loose flat stones and branches scattered over the map are natural finds, not starting resources.)
@export var yard_offset: Vector2 = Vector2(46, 20)
@export var yard_column_px: float = 40.0
@export var yard_row_px: float = 34.0
@export var yard_columns: int = 3
# What was placed: [{kind, position}], for the self-check and the report.
var start_yard: Array = []

func _place_start_yard(anchor: Vector2, cfg: Resource) -> void:
	var GroundPlacement = load("res://scripts/ground_placement.gd")
	var cabin: Node2D = get_node_or_null("Cabin")
	var origin: Vector2 = (cabin.position if cabin != null else anchor) + yard_offset
	var items: Array = [
		[&"planks", starting_planks], [&"saw_blade", 0], [&"basket", 0],
		[&"seed_bag", cfg.start_seed_bag_seeds], [&"bucket", 0], [&"dough_board", 0],
	]
	var map := Rect2(0, 0, 640, 640)
	start_yard.clear()
	for i in items.size():
		var kind: StringName = items[i][0]
		var want: Vector2 = origin + Vector2((i % yard_columns) * yard_column_px, (i / yard_columns) * yard_row_px)
		var spot: Vector2 = GroundPlacement.find_free_ground_near(get_tree(), want, Vector2(24, 12), map, 64.0)
		if spot == Vector2.INF:
			spot = want
		var node: Node2D = null
		match kind:
			&"planks":
				node = PlankPiles.spawn_pile(self, spot, int(items[i][1]))
			&"saw_blade":
				node = PlankPiles.spawn_blade(self, spot)
			&"basket":
				node = (load("res://scenes/Basket.tscn") as PackedScene).instantiate()
				node.position = spot
				add_child(node)
			_:
				node = FoodItems.spawn(kind, self, spot, int(items[i][1]))
		start_yard.append({"kind": kind, "position": node.position})

# The starting toolbox: beside the cabin, holding every tool of the start.
const ToolBoxScene = preload("res://scenes/ToolBox.tscn")
@export var toolbox_offset: Vector2 = Vector2(-70, 4)
@export var starting_tools: Array[StringName] = [&"hammer", &"shovel", &"axe", &"hoe", &"sickle", &"fire_starter"]
var toolbox: Node2D = null

func _place_toolbox(anchor: Vector2) -> void:
	var GroundPlacement = load("res://scripts/ground_placement.gd")
	var box: Node2D = ToolBoxScene.instantiate()
	var spot: Vector2 = GroundPlacement.find_free_ground_near(get_tree(), anchor + toolbox_offset, Vector2(26, 12), Rect2(0, 0, 640, 640), 96.0)
	box.position = (anchor + toolbox_offset) if spot == Vector2.INF else spot
	var list: Array = []
	for tool in starting_tools:
		list.append([tool, 0])
	box.init_contents = list
	add_child(box)
	toolbox = box

# `count` items of a kind on random free grass: not within scatter_clearance_px of a building, tree, bush or item,
# and scatter_spacing_px from each other (spread out, not clustered). A fixed seed keeps the layout repeatable.
func _scatter(kind: StringName, count: int, seed_value: int) -> void:
	var cfg: Resource = FoodConfig.cfg()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7700 + seed_value
	var placed: Array[Vector2] = []
	var landing: Vector2 = get_node("LandingPoint").position
	var tries: int = 0
	while placed.size() < count and tries < 4000:
		tries += 1
		var p := Vector2(rng.randf_range(24.0, 616.0), rng.randf_range(32.0, 616.0)).round()
		var clear: float = cfg.scatter_clearance_px
		if Footprints.rect_blocked(get_tree(), Rect2(p - Vector2(clear, clear), Vector2(clear, clear) * 2.0)):
			continue
		if p.distance_to(landing) < 40.0:
			continue
		var ok: bool = true
		for bush in get_tree().get_nodes_in_group("berry_bushes"):
			if bush.global_position.distance_to(p) < clear + 6.0:
				ok = false
				break
		for q in placed:
			if q.distance_to(p) < cfg.scatter_spacing_px:
				ok = false
				break
		if ok:
			for item in get_tree().get_nodes_in_group("ground_items"):
				if item.global_position.distance_to(p) < cfg.scatter_spacing_px * 0.5:
					ok = false
					break
		if ok and PlankPiles.is_free(get_tree(), p, Rect2(0, 0, 640, 640)):
			placed.append(p)
	for p in placed:
		FoodItems.spawn(kind, self, p)

func _ready() -> void:
	if not opening_mode:
		return
	place_food_start.call_deferred()
	var landing: Marker2D = get_node("LandingPoint")
	var player: Node2D = get_node("MainCharacter")
	player.position = landing.position + player_start_offset
	# The camera would catch up on its own next frame; start on him straight away.
	var camera: Camera2D = get_node("Camera2D")
	camera.global_position = (player.global_position + Vector2(0, -8)).round()
	# (The supplies are in the starting yard beside the cabin: see place_food_start.)
