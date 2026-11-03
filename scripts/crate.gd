extends Node2D
const Logistics = preload("res://scripts/logistics.gd")

# A crate standing on the floor of a building's interior (built from a "Crate" blueprint: 2 planks, 4 hammer
# hits). It is solid (it blocks walking at its base), y-sorted with the people, and it holds goods: a
# dictionary kind -> count, up to `capacity` in all, of the kinds in `accepted_items` (for now only berries).
#
#  - One picture whatever it holds (closed_crate.png). When it is used the lid opens for a moment
#    (open_crate.png, same origin and offset) with the crate_open sound; the contents show only in the hover
#    readout ("Berries 5 (5/12)"), never in the picture.
#  - Berries do not spoil. A colonist who is hungry takes from the crate (see colonist.gd) and claims it only
#    while he is actually taking.
#  - Dismantling it (Shift+E with the hammer) is blocked while it holds anything; an empty one returns its planks.

const OPEN_SECONDS: float = 0.5

# What it costs and how long it takes to build (what the Crate BuildingType is made from).
@export var crate_planks: int = 2
@export var crate_build_hits: int = 4
@export var capacity: int = 12
@export var accepted_items: Array[StringName] = [&"berry", &"seed_bag", &"wheat_sheaf", &"flour", &"flatbread"]
# Set when it was built from a blueprint (what dismantling returns).
@export var building_type: BuildingType
# The readout shows while the mouse is over the crate.
@export var label_name: Dictionary = {"berry": "Berries", "seed_bag": "Seed bag", "wheat_sheaf": "Wheat sheaf", "flour": "Flour", "flatbread": "Flatbread"}

# What is in it: kind -> count. A seed bag keeps its own seed count: bags lists the seeds of each bag in the crate
# (contents["seed_bag"] is how many there are), and taking one out returns the same bag with the same seeds.
var contents: Dictionary = {}
var bags: Array[int] = []
# The kind empty hands take (Shift+E steps to the next kind that is in the crate); berries first by default.
var pick_kind: StringName = &""
const TAKE_ORDER: Array[StringName] = [&"berry", &"flatbread", &"flour", &"wheat_sheaf", &"seed_bag"]
# Whoever is taking from it right now (a colonist), else null.
var claimed_by = null

var _open_left: float = 0.0
@onready var sprite: Sprite2D = $Sprite
@onready var count_label: Label = $CountLabel
var _closed: Texture2D
var _open: Texture2D = preload("res://sprites/open_crate.png")

func _ready() -> void:
	Ui.adopt(count_label)   # (its text is drawn by the UI, crisp, in screen space)
	add_to_group("crates")
	add_to_group("build_blockers")
	_closed = sprite.texture
	_refresh()

func _process(delta: float) -> void:
	if _open_left > 0.0:
		_open_left -= delta
		if _open_left <= 0.0:
			sprite.texture = _closed
			AudioManager.play("crate_close", global_position)
	var hovered: bool = footprint_rect().has_point(get_global_mouse_position())
	count_label.visible = hovered

# --- Contents -------------------------------------------------------------------------------------------------

func total() -> int:
	var n: int = 0
	for kind in contents:
		n += int(contents[kind])
	return n

func count_of(kind: StringName) -> int:
	return int(contents.get(String(kind), 0))

func is_empty() -> bool:
	return total() <= 0

func room_left() -> int:
	return capacity - total()

func is_full() -> bool:
	return room_left() <= 0

func accepts(kind: StringName) -> bool:
	return accepted_items.has(kind)

# Puts in up to `n` of a kind; returns how many went in (0 for a kind it does not take, or when it is full).
func add_item(kind: StringName, n: int) -> int:
	if not accepts(kind) or kind == &"seed_bag":
		return 0
	var added: int = clampi(n, 0, room_left())
	if added > 0:
		contents[String(kind)] = count_of(kind) + added
		_refresh()
	return added

# Takes out up to `n` of a kind; returns how many came out.
func take_item(kind: StringName, n: int) -> int:
	if kind == &"seed_bag":
		# (A bag comes out with its own seeds: use take_bag.)
		return 0
	var taken: int = clampi(n, 0, count_of(kind))
	if taken > 0:
		contents[String(kind)] = count_of(kind) - taken
		if contents[String(kind)] <= 0:
			contents.erase(String(kind))
		_refresh()
	return taken

func has_berries() -> bool:
	return count_of(&"berry") > 0

# Anything a hungry person can eat (berries, flatbread).
func has_food() -> bool:
	return count_of(&"berry") > 0 or count_of(&"flatbread") > 0

# A seed bag goes in with its seeds (false if the crate is full).
func add_bag(seeds: int) -> bool:
	if is_full() or not accepts(&"seed_bag"):
		return false
	bags.append(seeds)
	contents["seed_bag"] = bags.size()
	_refresh()
	return true

# The oldest bag comes out: returns its seeds, or -1 if there is none.
func take_bag() -> int:
	if bags.is_empty():
		return -1
	var seeds: int = bags.pop_front()
	if bags.is_empty():
		contents.erase("seed_bag")
	else:
		contents["seed_bag"] = bags.size()
	_refresh()
	return seeds

# The kinds in it now, in take order.
func kinds_present() -> Array[StringName]:
	var out: Array[StringName] = []
	for kind in TAKE_ORDER:
		if count_of(kind) > 0:
			out.append(kind)
	return out

# What empty hands take now (&"" when empty).
func selected_kind() -> StringName:
	var present: Array[StringName] = kinds_present()
	if present.is_empty():
		return &""
	if present.has(pick_kind):
		return pick_kind
	return present[0]

# Shift+E: the next kind that is in the crate.
func cycle_kind() -> StringName:
	var present: Array[StringName] = kinds_present()
	if present.is_empty():
		return &""
	var at: int = present.find(selected_kind())
	pick_kind = present[(at + 1) % present.size()]
	return pick_kind

# The hover readout: "Berries 5 (5/12)", or "Empty (0/12)".
func readout() -> String:
	var parts: Array[String] = []
	for kind in contents:
		if int(contents[kind]) > 0:
			parts.append("%s %d" % [label_name.get(kind, String(kind).capitalize()), int(contents[kind])])
	var what: String = ", ".join(parts) if not parts.is_empty() else "Empty"
	return "%s (%d/%d)" % [what, total(), capacity]

func _refresh() -> void:
	if count_label != null:
		count_label.text = readout()

# --- Using it -------------------------------------------------------------------------------------------------

# The lid lifts for a moment, with its sound.
func open_lid() -> void:
	sprite.texture = _open
	_open_left = OPEN_SECONDS
	AudioManager.play("crate_open", global_position)

func is_open() -> bool:
	return _open_left > 0.0

func try_claim(who) -> bool:
	if claimed_by != null and claimed_by != who and is_instance_valid(claimed_by):
		return false
	claimed_by = who
	return true

func release_claim(who) -> void:
	if claimed_by == who:
		claimed_by = null

# --- Where it is ----------------------------------------------------------------------------------------------

func interact_point() -> Vector2:
	return global_position + Vector2(0, -6)

# Where someone stands to use it: in front of it.
func use_spot() -> Vector2:
	return global_position + Vector2(0, 7)

# The ground cell it fills (a Building's footprint is the same 32x32).
func footprint_rect() -> Rect2:
	return Rect2(global_position + Vector2(-16, -32), Vector2(32, 32))

func hammer_spot_world() -> Vector2:
	return Logistics.beside_spot(global_position, Vector2(-22, 0))

# The room (BuildingInterior) it stands in.
func room():
	if not is_inside_tree():
		return null
	return load("res://scripts/building_interior.gd").room_at(get_tree(), global_position)

# The building whose room it stands in (null outside any room).
func host_building():
	var r = room()
	return r.building if r != null else null

func items_rect() -> Rect2:
	var r = room()
	return r.floor_rect_world() if r != null else Rect2(0, 0, 640, 640)

# Its planks come back as a pile outside the door when the building goes (the contents are lost with it; a
# building with anything stored cannot be dismantled by hand).
func spill_outside(near: Vector2) -> void:
	var PlankPiles = load("res://scripts/plank_piles.gd")
	var planks_back: int = crate_planks
	var at: Vector2 = near + Vector2(0, 30)
	while planks_back > 0:
		var n: int = mini(planks_back, 3)
		PlankPiles.spawn_pile(get_parent(), PlankPiles.free_spot(get_tree(), at, Rect2(0, 0, 640, 640), at), n)
		planks_back -= n
	# What it held is put out beside the door too (a seed bag with its seeds; berries have no item to be).
	var Items = load("res://scripts/items.gd")
	for kind in [&"flatbread", &"flour", &"wheat_sheaf"]:
		for i in count_of(kind):
			Items.put(get_tree(), get_parent(), kind, at + Vector2(randf_range(-12, 12), randf_range(0, 8)), Rect2(0, 0, 640, 640))
	for seeds in bags:
		Items.put(get_tree(), get_parent(), &"seed_bag", at + Vector2(randf_range(-12, 12), randf_range(0, 8)), Rect2(0, 0, 640, 640), seeds)
	remove_from_group("crates")
	remove_from_group("build_blockers")
	queue_free()
