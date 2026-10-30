extends Node2D

# A bed standing on the ground or on a room's floor (a static, y-sorted-below object with no collision for the
# player). It cannot be carried.
#  - STRAW bed (grass / hay bed): made by stacking three bundles anywhere, indoors or out. It looks green (a
#    grass bed) or hay-coloured (a hay bed) from the youngest bundle's age (ages count clock seconds): all
#    three must reach bundle_to_hay_clock_seconds. Both recover at the hay rate (GameClock.hay_recovery_fraction).
#    Break it up (empty hands, break_presses presses) and it falls apart into its three bundles, which keep
#    their ages.
#  - WOODEN bed: built with planks and the hammer from a "Wooden Bed" blueprint (a BuildingType) on the floor
#    of a house, then furnished with up to bedding_max bundles of grass or hay (any mix; each keeps its own age,
#    which is only the look). Its recovery depends on how many bundles lie on it (GameClock.wooden_bed_recovery:
#    bare frame, 1, 2, 3). The hammer (Shift+E) dismantles it into its planks and its bedding.
# One sleeper at a time. A bed is a flat decal on the ground (z_index below every y-sorted thing, above the
# ground tiles), so whoever walks over it or sleeps on it is drawn on top. A colonist or worker who is
# going to sleep on it reserves it (reserved_by) as soon as he starts walking, and becomes its sleeper when he
# lies down; anyone working on it (breaking, dismantling) claims it. Bedding is not changed while it is
# reserved or slept in; a colonist never changes it.

const BundleArt = preload("res://scripts/bundle_art.gd")
const GRASS_BED: Texture2D = preload("res://sprites/grass_bed.png")
const HAY_BED: Texture2D = preload("res://sprites/hay_bed.png")
const WOODEN_BASE: String = "res://sprites/wooden_bed.png"

enum Kind { STRAW, WOODEN }

# The wooden bed's picture for (green bundles, hay bundles); order does not matter. Each entry lists the file
# names to try (the last one is spelled with a space in the artist's file).
const WOODEN_FILES: Dictionary = {
	"0,0": ["wooden_bed.png"],
	"1,0": ["wooden_bed_with_one_grass.png"],
	"0,1": ["wooden_bed_with_one_hay.png"],
	"2,0": ["wooden_bed_with_two_grass.png"],
	"0,2": ["wooden_bed_with_two_hay.png"],
	"1,1": ["wooden_bed_with_one_grass_one_hay.png"],
	"3,0": ["wooden_bed_with_three_grass.png"],
	"0,3": ["wooden_bed_with_three_hay.png"],
	"2,1": ["wooden_bed_with_two_grass_one_hay.png"],
	"1,2": ["wooden_bed_with_two_hay_one_grass.png", "wooden_bed_with_two_hay_one grass.png"],
}
static var _wooden_cache: Dictionary = {}
static var _warned: Dictionary = {}

# Above the ground tiles (z -2), below everything that is depth-sorted (z 0).
const DECAL_Z: int = -1
const NOT_INSIDE: String = "Wooden beds go inside a house."

@export var kind: Kind = Kind.STRAW
@export var break_presses: int = 2
# The wooden bed: its cost in planks, the hammer hits that build it (and, halved, take it down), the most
# bundles that lie on it.
@export var wooden_planks: int = 4
@export var wooden_build_hits: int = 6
@export var bedding_max: int = 3
# Half the height of a character's asleep picture (16 px tall): where his body's middle is above his feet.
@export var sleeper_half_height: float = 8.0

# The ages of the bundles in the bed (clock seconds): three for a straw bed (its youngest decides its look),
# 0 to bedding_max for a wooden one (each decides its own look).
var ages: Array[float] = [0.0, 0.0, 0.0]
var sleeper = null
var reserved_by = null
var claimed_by = null
# Hits made on it (breaking a straw bed up).
var progress: int = 0

var _look: String = ""
var _clock: Node = null

@onready var sprite: Sprite2D = $Sprite

func _ready() -> void:
	add_to_group("beds")
	z_index = DECAL_Z
	_refresh()

func _game_clock() -> Node:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	return _clock

func is_wooden() -> bool:
	return kind == Kind.WOODEN

# A straw bed's level for the houses (1); a wooden one is 2 (its real quality is recovery_fraction()).
func level() -> int:
	return 2 if is_wooden() else 1

func youngest_age() -> float:
	var youngest: float = INF
	for age in ages:
		youngest = minf(youngest, age)
	return youngest

func looks_hay() -> bool:
	var clock: Node = _game_clock()
	return not is_wooden() and clock != null and youngest_age() >= clock.bundle_to_hay_clock_seconds

func _is_hay(age: float) -> bool:
	var clock: Node = _game_clock()
	return clock != null and age >= clock.bundle_to_hay_clock_seconds

func bedding_count() -> int:
	return ages.size() if is_wooden() else 0

# (green bundles, hay bundles) on a wooden bed.
func bedding_mix() -> Vector2i:
	var green: int = 0
	var hay: int = 0
	for age in ages:
		if _is_hay(age):
			hay += 1
		else:
			green += 1
	return Vector2i(green, hay)

func bed_name() -> String:
	if is_wooden():
		return "wooden bed"
	return "hay bed" if looks_hay() else "grass bed"

# How much of the full recovery rate sleeping here gives: the hay rate for a straw bed, the bedding table
# (bare frame, 1, 2, 3 bundles) for a wooden one.
func recovery_fraction() -> float:
	var clock: Node = _game_clock()
	if clock == null:
		return 0.0
	if not is_wooden():
		return clock.hay_recovery_fraction
	var table: Array = clock.wooden_bed_recovery
	return table[clampi(bedding_count(), 0, table.size() - 1)]

# Rest per clock-second while asleep here.
func sleep_rate_now() -> float:
	var clock: Node = _game_clock()
	return clock.recovery_per_second(recovery_fraction()) if clock != null else 0.0

# The message when the player goes to sleep in it.
func sleep_message() -> String:
	if not is_wooden():
		return "You sleep on a %s" % bed_name()
	if bedding_count() == 0:
		return "You sleep on a wooden bed (bare frame)"
	return "You sleep on a wooden bed with %d bedding" % bedding_count()

func interact_point() -> Vector2:
	return global_position + Vector2(0, -6)

# The middle of the bed's picture.
func centre_world() -> Vector2:
	return global_position + Vector2(0, -BundleArt.used_height(sprite.texture) * 0.5)

# Where a sleeper's feet go so that his body is centred on the bed (his lying picture is as tall as he is:
# sleeper_half_height above his feet is his middle). The bed is on the decal layer, so he is drawn on top.
func sleep_spot_world() -> Vector2:
	return (centre_world() + Vector2(0, sleeper_half_height)).round()

func _process(_delta: float) -> void:
	var clock: Node = _game_clock()
	if clock != null:
		for i in ages.size():
			ages[i] += clock.clock_delta
	if _look_key() != _look:
		_refresh()

func _look_key() -> String:
	if is_wooden():
		var mix: Vector2i = bedding_mix()
		return "w%d,%d" % [mix.x, mix.y]
	return "hay" if looks_hay() else "grass"

func _refresh() -> void:
	_look = _look_key()
	if is_wooden():
		var mix: Vector2i = bedding_mix()
		sprite.texture = wooden_texture(mix.x, mix.y)
		# One origin and offset for every wooden picture, so nothing jumps when the bedding changes.
		sprite.offset = wooden_offset()
		return
	var texture: Texture2D = HAY_BED if looks_hay() else GRASS_BED
	sprite.texture = texture
	sprite.offset = BundleArt.offset_for(texture)

# --- The wooden bed's pictures -----------------------------------------------------------------------------------

static func wooden_offset() -> Vector2:
	return BundleArt.offset_for(load(WOODEN_BASE))

# The file for a mix of bundles (the first of its names that exists); with none, the nearest picture by the
# number of bundles (logged once).
static func wooden_path(green: int, hay: int) -> String:
	var key: String = "%d,%d" % [green, hay]
	if _wooden_cache.has(key):
		return _wooden_cache[key]
	var path: String = ""
	for name in WOODEN_FILES.get(key, []):
		if ResourceLoader.exists("res://sprites/" + name):
			path = "res://sprites/" + name
			break
	if path == "":
		if not _warned.has(key):
			_warned[key] = true
			push_warning("Wooden bed picture missing for %d green + %d hay bundles; using the nearest" % [green, hay])
		var best_score: int = 1000
		for other in WOODEN_FILES:
			var parts: PackedStringArray = other.split(",")
			var g: int = int(parts[0])
			var h: int = int(parts[1])
			for name in WOODEN_FILES[other]:
				if ResourceLoader.exists("res://sprites/" + name):
					var score: int = absi(g + h - green - hay) * 10 + absi(h - hay)
					if score < best_score:
						best_score = score
						path = "res://sprites/" + name
	_wooden_cache[key] = path
	return path

static func wooden_texture(green: int, hay: int) -> Texture2D:
	return load(wooden_path(green, hay))

# --- Sleeping --------------------------------------------------------------------------------------------

# Can `who` go to sleep on it now: nobody is on it, nobody else has reserved it, and nobody is working on it.
func is_free_for(who) -> bool:
	if not is_in_group("beds") or is_queued_for_deletion():
		return false
	return (sleeper == null or sleeper == who) and (reserved_by == null or reserved_by == who) and (claimed_by == null or claimed_by == who)

func reserve(who) -> bool:
	if not is_free_for(who):
		return false
	reserved_by = who
	return true

func lie_down(who) -> void:
	reserved_by = null
	sleeper = who

# He wakes, gives up, or the reservation is let go.
func release_sleeper(who) -> void:
	if sleeper == who:
		sleeper = null
	if reserved_by == who:
		reserved_by = null

func is_occupied() -> bool:
	return sleeper != null or reserved_by != null

func try_claim(who) -> bool:
	if claimed_by != null and claimed_by != who:
		return false
	claimed_by = who
	return true

func release_claim(who) -> void:
	if claimed_by == who:
		claimed_by = null

func _say(text: String) -> void:
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say(text)

# --- Bedding (the wooden bed) -------------------------------------------------------------------------------

# Bedding is changed only by someone who is not asleep on it, with nobody asleep on it or on his way to it.
func can_edit_bedding(who) -> bool:
	return is_wooden() and sleeper == null and reserved_by == null and (claimed_by == null or claimed_by == who)

func bedding_full() -> bool:
	return bedding_count() >= bedding_max

# One bundle (with its age) is laid on the bed. False if it is full.
func add_bedding(age: float) -> bool:
	if not is_wooden() or bedding_full():
		return false
	ages.append(age)
	_refresh()
	return true

# The newest bundle comes off; returns its age (-1 if there was none).
func take_bedding() -> float:
	if not is_wooden() or ages.is_empty():
		return -1.0
	var age: float = ages.pop_back()
	_refresh()
	return age

# --- Where it stands -----------------------------------------------------------------------------------------

# The room (HouseInterior) this bed stands in, or null when it is out in the world.
func interior_node() -> Node2D:
	if not is_inside_tree():
		return null
	return load("res://scripts/building_interior.gd").room_at(get_tree(), global_position)

# The House it is inside (null outdoors).
func house_inside():
	var room: Node2D = interior_node()
	return room.building if room != null else null

# Where someone walking to this bed goes first: the door of its house for a bed inside, else the bed itself.
func approach_point() -> Vector2:
	var house = house_inside()
	if house != null and is_instance_valid(house):
		return house.door_position()
	return sleep_spot_world()

# The floor rectangle bundles and planks may land on around it (the room, or the map).
func items_rect() -> Rect2:
	var room: Node2D = interior_node()
	return room.floor_rect_world() if room != null else Rect2(0, 0, 640, 640)

# --- Breaking a straw bed up --------------------------------------------------------------------------------

# One press on the bed (empty hands). Returns true when it fell apart.
func break_hit() -> bool:
	if is_wooden() or sleeper != null:
		return false
	progress += 1
	if progress < break_presses:
		return false
	progress = 0
	_break_up()
	return true

# The three bundles drop around the bed, each keeping its age.
func _break_up() -> void:
	var piles = load("res://scripts/plank_piles.gd")
	var scene: PackedScene = load("res://scenes/BundlePile.tscn")
	var offsets: Array[Vector2] = [Vector2(-14, 4), Vector2(14, 4), Vector2(0, 14)]
	for i in 3:
		var pile: Node2D = scene.instantiate()
		var near: Vector2 = global_position + offsets[i]
		pile.position = piles.free_spot(get_tree(), near, items_rect(), near)
		pile.ages.append(ages[i])
		get_parent().add_child(pile)
	remove_from_group("beds")
	queue_free()

# The house is being taken down: the bed comes apart outside, beside the door. A straw bed becomes its three
# bundles (with their ages), a wooden bed its planks (as piles) and its bedding.
func spill_outside(near: Vector2) -> void:
	var piles = load("res://scripts/plank_piles.gd")
	var rect := Rect2(0, 0, 640, 640)
	if is_wooden():
		var left: int = wooden_planks
		var i: int = 0
		while left > 0:
			var n: int = mini(left, 3)
			var at: Vector2 = near + Vector2(-18 + 18 * i, 16)
			piles.spawn_pile(get_parent(), piles.free_spot(get_tree(), at, rect, at), n)
			left -= n
			i += 1
	var scene: PackedScene = load("res://scenes/BundlePile.tscn")
	for k in ages.size():
		var pile: Node2D = scene.instantiate()
		var at: Vector2 = near + Vector2(-22 + 22 * k, 26)
		pile.position = piles.free_spot(get_tree(), at, rect, at)
		pile.ages.append(ages[k])
		get_parent().add_child(pile)
	sleeper = null
	reserved_by = null
	remove_from_group("beds")
	queue_free()

# Debug: every bundle is hay-old.
func age_to_hay() -> void:
	var clock: Node = _game_clock()
	for i in ages.size():
		ages[i] = maxf(ages[i], clock.bundle_to_hay_clock_seconds)
	_refresh()
