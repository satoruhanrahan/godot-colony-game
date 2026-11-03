extends Node2D

# The table (built from a "Table" blueprint: 3 planks, 4 hammer hits): a small solid thing, outdoors or inside a house
# (house_max_tables there, counted like the beds and crates). Its surface holds table_surface_capacity things (1).
#  - Holding any carryable item (dough board, bucket, a tool, food, a seed bag, a basket ...), E puts it on the surface,
#    drawn on top of the table at surface_offset (it is a child of the table, so it sorts with it).
#  - Empty hands + E on the item picks it up again by the item's own rules (a dough board holding dough gives the dough
#    first). Anything on the table is used where it stands: a dough board on a table still takes flour, water and
#    kneading.
#  - Hover shows the table and what is on it. Dismantling it is blocked while it holds anything ("Take the item off
#    first."). Colonists and workers ignore tables.

const Items = preload("res://scripts/items.gd")
const Logistics = preload("res://scripts/logistics.gd")
const HoverNames = preload("res://scripts/hover_names.gd")

@export var building_type: BuildingType
# Where the first thing on the table is drawn, from the table's base.
@export var surface_offset: Vector2 = Vector2(0, -7)
@export var table_surface_capacity: int = 1

# The groups an item lying on the table is in (so the table can tell it from its own parts).
const ITEM_GROUPS: Array[String] = ["ground_items", "dough_boards", "baskets", "hammers", "shovels", "axes"]

func _ready() -> void:
	add_to_group("tables")
	add_to_group("build_blockers")

# What lies on the surface now.
func items() -> Array:
	var out: Array = []
	for child in get_children():
		if child.is_queued_for_deletion():
			continue
		for group in ITEM_GROUPS:
			if child.is_in_group(group):
				out.append(child)
				break
	return out

func is_empty() -> bool:
	return items().is_empty()

func has_room() -> bool:
	return items().size() < table_surface_capacity

# Puts an item node (already made, not yet in the tree) on the surface.
func put_node(node: Node2D) -> void:
	node.position = surface_offset + Vector2(5.0 * items().size(), 0.0)
	add_child(node)

func footprint_rect() -> Rect2:
	return Rect2(global_position + Vector2(-16, -32), Vector2(32, 32))

func interact_point() -> Vector2:
	return global_position + Vector2(0, -4)

func hammer_spot_world() -> Vector2:
	return Logistics.beside_spot(global_position, Vector2(-22, 0))

# "Table", or "Table (Bucket 3/6)".
func readout() -> String:
	var names: Array[String] = []
	for item in items():
		names.append(HoverNames.name_of(item, get_tree()))
	return "Table" if names.is_empty() else "Table (%s)" % ", ".join(names)

# The table is going (its building came down): the planks come back and the things on it are put on the floor.
func spill_outside(near: Vector2) -> void:
	var PlankPiles = load("res://scripts/plank_piles.gd")
	for item in items():
		var spot: Vector2 = PlankPiles.free_spot(get_tree(), near + Vector2(randf_range(-12, 12), 14), Rect2(0, 0, 640, 640), near)
		remove_child(item)
		item.position = spot
		get_parent().add_child(item)
	var planks_back: int = building_type.plank_cost if building_type != null else 3
	var at: Vector2 = near + Vector2(0, 30)
	while planks_back > 0:
		var n: int = mini(planks_back, 3)
		PlankPiles.spawn_pile(get_parent(), PlankPiles.free_spot(get_tree(), at, Rect2(0, 0, 640, 640), at), n)
		planks_back -= n
	remove_from_group("tables")
	remove_from_group("build_blockers")
	queue_free()
