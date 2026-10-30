extends Node2D

# The ONE hover-name system: while the mouse is over a pickup lying on the ground (any tool, plank pile, saw blade,
# bundle, basket, seed bag, branch, stone, food, a log), its name is drawn just under it, in the same style
# everywhere (8 px font, black outline). Hover only. Things that carry data show it: "Basket 3/6", "Seed bag 2/6",
# "Planks 3". Over the player it names what he holds. It is a child of the player's Interaction; there is one label
# at a time (the thing drawn lowest on screen wins).
#
# To make a new kind of pickup name itself, give it to one of the groups below (or add a group here).

const Items = preload("res://scripts/items.gd")
const GroundPlacement = preload("res://scripts/ground_placement.gd")

# group -> [the rectangle of its picture relative to its origin: x, y, w, h]
const GROUP_RECTS: Dictionary = {
	"dough_boards": Rect2(-8, -12, 16, 14),
	"toolboxes": Rect2(-12, -16, 24, 18),
	"tables": Rect2(-9, -12, 18, 14),
	"grinding_stones": Rect2(-6, -12, 12, 14),
	"hammers": Rect2(-5, -10, 10, 12),
	"shovels": Rect2(-7, -8, 14, 10),
	"axes": Rect2(-5, -11, 10, 13),
	"saw_blades": Rect2(-4, -18, 8, 20),
	"plank_piles": Rect2(-10, -12, 20, 14),
	"bundle_piles": Rect2(-10, -17, 20, 19),
	"baskets": Rect2(-6, -8, 12, 10),
}

var player: Node2D
var _text: String = ""
var _rect: Rect2 = Rect2()

func _ready() -> void:
	top_level = true
	z_index = 100
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

# The name of a pickup node (by the group it is in), or "".
static func name_of(node: Node, tree: SceneTree) -> String:
	if node.is_in_group("ground_items"):
		return Items.hover_text(node.kind, node.amount())
	if node.is_in_group("hammers"):
		return "Hammer"
	if node.is_in_group("shovels"):
		return "Shovel"
	if node.is_in_group("axes"):
		return "Axe"
	if node.is_in_group("saw_blades"):
		return "Saw blade"
	if node.is_in_group("plank_piles"):
		return "Plank" if node.count == 1 else "Planks %d" % node.count
	if node.is_in_group("bundle_piles"):
		var clock: Node = tree.get_first_node_in_group("game_clock")
		var hay: bool = clock != null and not node.ages.is_empty() and node.ages.min() >= clock.bundle_to_hay_clock_seconds
		var label: String = "Hay bundle" if hay else "Grass bundle"
		return label if node.count() == 1 else "%ss %d" % [label, node.count()]
	if node.is_in_group("dough_boards") or node.is_in_group("tables") or node.is_in_group("toolboxes"):
		return node.readout()
	if node.is_in_group("baskets"):
		var cap: int = 6
		var gc: Node = tree.get_first_node_in_group("game_clock")
		if gc != null:
			cap = gc.basket_capacity
		return "Basket %d/%d" % [node.berries, cap]
	return ""

static func rect_of(node: Node2D) -> Rect2:
	if node.is_in_group("ground_items"):
		return node.hover_rect()
	for group in GROUP_RECTS:
		if node.is_in_group(group):
			var r: Rect2 = GROUP_RECTS[group]
			return Rect2(node.global_position + r.position, r.size)
	return Rect2()

# What the player holds, as a name ("" for empty hands).
static func held_name(player: Node, tree: SceneTree) -> String:
	if player.dragger.is_dragging():
		return "Log"
	if player.carrying_planks > 0:
		return "Plank" if player.carrying_planks == 1 else "Planks %d" % player.carrying_planks
	if player.carrying_blade:
		return "Saw blade"
	match player.held_tool:
		&"":
			return ""
		&"hammer":
			return "Hammer"
		&"shovel":
			return "Shovel"
		&"axe":
			return "Axe"
		&"berry":
			return "Berry"
		&"basket":
			var clock: Node = tree.get_first_node_in_group("game_clock")
			return "Basket %d/%d" % [player.basket_berries, clock.basket_capacity if clock != null else 6]
		&"dough_board":
			return "Dough board (not usable while held)"
		&"seed_bag":
			return "Seed bag %d/%d" % [player.held_seeds, load("res://scripts/food_config.gd").cfg().seed_bag_capacity]
		&"bucket":
			return Items.hover_text(&"bucket", player.held_scoops)
		&"bundle":
			return "Hay bundle" if player.bundle_is_hay() else "Grass bundle"
	if Items.is_item(player.held_tool):
		return Items.name_of(player.held_tool)
	return ""

# The name and picture rectangle of what is under this world point: {"text", "rect"} (empty when nothing is).
static func hovered(tree: SceneTree, point: Vector2, player: Node, skip_pickups: bool = false) -> Dictionary:
	var best: Dictionary = {}
	# (A lambda cannot reassign a captured variable, so the answer is a dictionary it fills in.)
	var consider := func(text: String, rect: Rect2) -> void:
		if text != "" and rect.has_point(point) and (best.is_empty() or rect.end.y > best["rect"].end.y):
			best["text"] = text
			best["rect"] = rect
	for group in ["ground_items", "hammers", "shovels", "axes", "saw_blades", "plank_piles", "bundle_piles", "baskets", "dough_boards", "tables", "toolboxes"]:
		# (Pickups name themselves only as THE target: see Interaction.)
		if skip_pickups and group in ["ground_items", "hammers", "shovels", "axes", "saw_blades", "plank_piles", "bundle_piles", "baskets", "dough_boards"]:
			continue
		for node in tree.get_nodes_in_group(group):
			if node.is_queued_for_deletion():
				continue
			consider.call(name_of(node, tree), rect_of(node))
	# A log lying where a tree was delimbed.
	for t in tree.get_nodes_in_group("trees"):
		if t.is_delimbed() and t.logs_ready > 0 and t.log_node() != null:
			var trunk: Node2D = t.log_node()
			var top: Vector2 = trunk.global_position + Vector2.UP.rotated(trunk.global_rotation) * 14.0
			consider.call("Log", Rect2(trunk.global_position, Vector2.ZERO).expand(top).grow(6.0))
	# The player: what he holds.
	if player != null:
		consider.call(held_name(player, tree), Rect2(player.global_position + Vector2(-8, -18), Vector2(16, 20)))
	return best

# The text shown for THE target: its name, and where there is one to give a hint: a wheat sheaf with a seed bag in the hands can be
# threshed into it.
static func target_text(target: Node, tree: SceneTree, player: Node) -> String:
	var text: String = name_of(target, tree)
	if text != "" and target.is_in_group("ground_items") and target.kind == &"wheat_sheaf" and player != null and player.held_tool == &"seed_bag":
		text += "\nThresh into bag"
	return text

func _process(_delta: float) -> void:
	var found: Dictionary = hovered(get_tree(), get_global_mouse_position(), player, true)
	# THE target (outlined by Interaction) is the only pickup that shows its name.
	var target: Node2D = get_parent().target_node() if get_parent().has_method("target_node") else null
	if target != null and is_instance_valid(target):
		var text: String = target_text(target, get_tree(), player)
		if text != "":
			found = {"text": text, "rect": GroundPlacement.pickup_rect(target)}
	_text = found.get("text", "")
	_rect = found.get("rect", Rect2())
	# The name is the UI's text, crisp, just under the thing (screen space, kept inside the window).
	if _text != "":
		Ui.world_text("hover_name", get_viewport(), Vector2(_rect.get_center().x, _rect.end.y + 1.0), _text, "small", null, Vector2(0.5, 0.0))
