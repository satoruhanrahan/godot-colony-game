class_name BuildingType
extends Resource

# Data for one kind of building. Add a new .tres of this type (and list it in the
# BuildMode node's building_types) to make a new building.
@export var type_name: String = "House"
# The tab of the build menu it is in ("Housing", "Storage", "Food and Water", "Workshop") and its one-line description.
@export var category: String = ""
@export_multiline var description: String = ""
# What must be unlocked before it can be built: a key of the UnlockManager ("none" = nothing, "pit_saw_built" = a pit saw has been
# built). Change it here to change which buildings are available at the start.
@export var unlock_requirement: String = "none"
@export var texture: Texture2D
# Sprite offset that puts the node's origin at the bottom edge of the art.
@export var sprite_offset: Vector2 = Vector2(0, -9)
# How it gets built: "planks" (the Hauler brings planks, the Builder hammers) or "digging"
# (the player digs it; no planks).
@export var cost_type: String = "planks"
# The scene build mode places. Empty = the plain Building.tscn.
@export var scene: PackedScene
# Hammer blows by hand to finish a fully supplied blueprint of this type.
@export var BUILD_HITS: int = 10
# When set, the finished building is replaced by this scene (a working Storage or
# Sawmill) at the same position. Empty = the Building itself becomes the built thing.
@export var built_scene: PackedScene
# What the build palette shows as the cost ("8 planks" by default; the pit saw says
# "dig + 2 planks + blade").
@export var cost_label: String = ""
@export var plank_cost: int = 8
# Other things the blueprint needs delivered by hand ("branch": 3, "flat_stone": 3 for the campfire), by item kind.
@export var materials: Dictionary = {}
@export var build_time: float = 12.0
# How many colonists can live here (one bed each).
@export var capacity: int = 1
# Where a new resident stands to move in, relative to the building's origin (the bottom
# edge of the sprite): just in front of the door.
@export var door_offset: Vector2 = Vector2(0, 4)
# Size in 32x32 grid cells.
@export var footprint: Vector2i = Vector2i(1, 1)
# Only on the floor of a building's interior (the Wooden Bed, the Crate): elsewhere it is greyed with locked_hint.
@export var indoor_only: bool = false
@export var locked_hint: String = ""
# Which kinds of interior it may go in ("house", "storage"), whether it lies flat on the floor under the people
# (a bed) or stands solid on it (a crate), and which per-interior limit it counts against ("bed", "crate").
@export var indoor_kinds: PackedStringArray = PackedStringArray(["house"])
@export var flat_decal: bool = false
@export var indoor_limit_key: String = ""
# May also be built outdoors AND inside the interiors of indoor_kinds (the Table), unlike indoor_only types.
@export var indoor_ok: bool = false
# The solid base (collision) of the blueprint, when it is not the whole footprint wide and 8 px deep.
@export var base_size: Vector2 = Vector2.ZERO

# --- The inside of a building of this type (only buildings you can walk into) ----------------------------------
# What kind of interior it has ("house", "storage"; empty = none) and its picture (drawn with its top-left at the
# interior's origin; every number below is in its pixels). door_offset (above) is where people stand outside the
# door, door_area_rect the visible door (relative to the base).
@export var interior_kind: String = ""
@export var interior_texture: Texture2D
@export var interior_size: Vector2i = Vector2i(224, 160)
# The walkable rectangle for the feet, where one appears coming in (door_pos), the area that leads out, the gap in
# the bottom wall and how far through it one may walk, and the middle of the room picture (the camera looks there).
@export var floor_rect: Rect2 = Rect2(20, 62, 88, 76)
@export var door_pos: Vector2 = Vector2(64, 126)
@export var exit_area: Rect2 = Rect2(54, 134, 20, 10)
@export var door_gap_x: Vector2 = Vector2(54, 74)
@export var corridor_bottom: float = 142.0
@export var camera_centre: Vector2 = Vector2(64, 78)
@export var door_area_rect: Rect2 = Rect2(-9, -17, 10, 17)
# How many crates the interior holds.
@export var crates_max: int = 0

func cost_text() -> String:
	if cost_label != "":
		return cost_label
	return "%d planks" % plank_cost

# What it costs as a list of [item kind, count] (for the build menu's little icons): planks, then the things delivered by
# hand. The pit saw is dug by hand and takes 2 planks and the blade.
func cost_items() -> Array:
	var out: Array = []
	if cost_type == "planks" and plank_cost > 0:
		out.append([&"plank", plank_cost])
	elif cost_type == "digging":
		out.append([&"plank", 2])
		out.append([&"blade", 1])
	for kind in materials:
		out.append([StringName(kind), int(materials[kind])])
	return out
