class_name Building
extends Sprite2D
const Logistics = preload("res://scripts/logistics.gd")

enum State { WAITING, BUILDING, BUILT }
# What a house has to sleep on. NONE is the bare wooden floor; hay and proper beds are made by the
# player (hay delivered, then planks and the hammer).
enum BedLevel { NONE, STRAW, WOODEN }

# Emitted once, the moment the building becomes BUILT.
signal built(building: Building)

const CELL: int = 32

# When set, the type's texture, offset, plank cost, build time and footprint replace
# the values below (they are what the type is copied into).
@export var building_type: BuildingType
@export var plank_cost: int = 8
@export var build_time: float = 12.0
# Size in grid cells. The node's origin is the bottom-centre of the footprint.
@export var footprint: Vector2i = Vector2i(1, 1)
# Beds for colonists, and where a new resident stands to move in (relative to the origin).
@export var capacity: int = 1
@export var door_offset: Vector2 = Vector2(0, 4)
# A building that is already finished when the game starts (the cabin): it works exactly like one that was built.
@export var starts_built: bool = false
# Hammer blows by hand to finish it (copied from the type).
@export var BUILD_HITS: int = 10
# Where the player stands to hammer, relative to the origin (outside the footprint, on the
# left like the Builder); wider buildings push it further left.
@export var hammer_spot: Vector2 = Vector2(-22, 0)
# The visible door of the cabin (relative to the base) and the small area that triggers going in. The picture is
# 48x48 with the cabin drawn at x 7..38, y 11..38, the door at x 14..21, y 22..37, so with the sprite offset (2, -14)
# that puts the door at about x -9..0, y -16..0 from the base; the resident door_offset is just in front of it.
@export var door_area_rect: Rect2 = Rect2(-9, -17, 10, 17)
# The room inside (made the first time someone goes in, kept afterwards): see BuildingInterior.
var interior: Node2D = null

# Beds are objects (Bed.tscn) standing INSIDE the house, in its room (BuildingInterior). A house holds at most
# house_max_beds of them; its bed_level comes from the best one inside (NONE = the bare floor, STRAW = a grass
# or hay bed, WOODEN). An outdoor bed, even beside the door, does not count.
# 0 = no limit: space is the only limit (the placement rules).
@export var house_max_beds: int = 0
# How many tables a house holds (counted like beds and crates).
@export var house_max_tables: int = 2
# The "This house cannot fit another bed." message has been said (it is said once until a bed is gone).
var no_room_said: bool = false

# The best bed inside (read-only).
var bed_level: BedLevel:
	get:
		return _best_bed_level()

var state: State = State.WAITING
# Colonists who have claimed a bed here (arrived or still walking over).
var residents: Array = []
# Planks delivered so far (never deducted; the cost is paid by finishing the building).
var planks_ready: int = 0
# Other materials (branches, flat stones: item kind -> count): what it costs and what has been delivered by hand.
var materials_cost: Dictionary = {}
var materials_ready: Dictionary = {}
# Planks a Hauler has claimed and is carrying here, so nobody else brings the same ones.
var planks_reserved: int = 0
# Who is working on it (the automated Builder or the player), so two never build the same
# blueprint at once. Released when they stop; progress stays.
var claimed_by = null
# Hammer blows so far. Above zero it shows the "building" look.
var build_progress: int = 0

@onready var shape: CollisionShape2D = $Collision/Shape

func _ready() -> void:
	add_to_group("buildings")
	add_to_group("build_blockers")
	if building_type != null:
		texture = building_type.texture
		offset = building_type.sprite_offset
		plank_cost = building_type.plank_cost
		materials_cost = building_type.materials.duplicate()
		build_time = building_type.build_time
		footprint = building_type.footprint
		capacity = building_type.capacity
		door_offset = building_type.door_offset
		BUILD_HITS = building_type.BUILD_HITS
	# A Wooden Bed blueprint is flat on the floor: drawn below characters, nothing to bump into. (A crate
	# blueprint stands solid on it.)
	var indoor_flat: bool = building_type != null and building_type.flat_decal
	if indoor_flat:
		z_index = -1
	# Collision covers only the lower base, so characters can walk behind the top.
	var base := RectangleShape2D.new()
	base.size = Vector2(footprint.x * CELL - 5, 8)
	if building_type != null and building_type.base_size != Vector2.ZERO:
		base.size = building_type.base_size
	shape.shape = base
	shape.position = Vector2(0.5, -base.size.y * 0.5)
	if indoor_flat:
		shape.set_deferred("disabled", true)
	if starts_built:
		state = State.BUILT
		build_progress = BUILD_HITS

# A blueprint is a ghost that solidifies with every hammer hit (ghost_alpha at the start, fully solid when
# finished), and flashes brighter for a moment on each hit (see flash()).
@export var ghost_alpha: float = 0.35
const FLASH_TIME: float = 0.12
const FLASH_BOOST: float = 0.7
var _flash_left: float = 0.0

func flash() -> void:
	_flash_left = FLASH_TIME

func _process(delta: float) -> void:
	var alpha: float = 1.0
	if state != State.BUILT:
		var done: float = clampf(float(build_progress) / float(maxi(1, BUILD_HITS)), 0.0, 1.0)
		alpha = lerpf(ghost_alpha, 1.0, done)
		if state == State.BUILDING and build_progress == 0:
			# (A Builder working by the clock has made no counted hits: it still shows as a bit more solid.)
			alpha = maxf(alpha, 0.5)
	var glow: float = 1.0
	if _flash_left > 0.0:
		_flash_left -= delta
		glow = 1.0 + FLASH_BOOST * clampf(_flash_left / FLASH_TIME, 0.0, 1.0)
	self_modulate = Color(glow, glow, glow, alpha)

func display_name() -> String:
	return building_type.type_name if building_type != null else "Building"

# The ground the footprint covers, in world pixels.
func footprint_rect() -> Rect2:
	var size := Vector2(footprint * CELL)
	return Rect2(global_position + Vector2(-size.x * 0.5, -size.y), size)

# How many more planks still have to be brought (0 once enough are here or on the way).
func planks_needed() -> int:
	if state != State.WAITING:
		return 0
	return maxi(0, plank_cost - planks_ready - planks_reserved)

# All planks delivered and nobody working on it. (A half-hammered one counts too: the
# Builder can carry on from the blows the player made.)
func is_fully_supplied() -> bool:
	return state != State.BUILT and claimed_by == null and is_supplied()

# --- Materials other than planks (delivered by hand) ---

# How many more of this kind (an item kind such as &"branch") it still needs.
func material_missing(kind: StringName) -> int:
	return maxi(0, int(materials_cost.get(String(kind), 0)) - int(materials_ready.get(String(kind), 0)))

func needs_material(kind: StringName) -> bool:
	return state != State.BUILT and build_progress == 0 and material_missing(kind) > 0

func add_material(kind: StringName) -> bool:
	if not needs_material(kind):
		return false
	materials_ready[String(kind)] = int(materials_ready.get(String(kind), 0)) + 1
	return true

func materials_complete() -> bool:
	for kind in materials_cost:
		if int(materials_ready.get(kind, 0)) < int(materials_cost[kind]):
			return false
	return true

func materials_delivered() -> int:
	var n: int = 0
	for kind in materials_ready:
		n += int(materials_ready[kind])
	return n

# Everything it needs is here (planks and the other materials): it can be hammered.
func is_supplied() -> bool:
	return planks_ready >= plank_cost and materials_complete()

# What is still missing, as text ("planks 2/8, branch 1/3").
func missing_text() -> String:
	var parts: Array[String] = []
	if plank_cost > 0:
		parts.append("planks %d/%d" % [planks_ready, plank_cost])
	for kind in materials_cost:
		parts.append("%s %d/%d" % [String(kind).replace("_", " "), int(materials_ready.get(kind, 0)), int(materials_cost[kind])])
	return ", ".join(parts)

func try_claim(who) -> bool:
	if claimed_by != null and claimed_by != who:
		return false
	claimed_by = who
	return true

func release_claim(who) -> void:
	if claimed_by == who:
		claimed_by = null

# Where to stand to hammer it by hand.
func hammer_spot_world() -> Vector2:
	# (a building that already stands at the edge of the map: the left end of it would be outside the map, so the right end is used)
	return Logistics.beside_spot(global_position, Vector2(hammer_spot.x - (footprint.x - 1) * 16.0, hammer_spot.y))

func interact_point() -> Vector2:
	return global_position + Vector2(0, -6)

# While no hammer hit has been made (and nobody is on it), delivered planks can be taken back, one at a time;
# and a blueprint with nothing left in it can be cancelled. After the first hit it can only be finished or
# dismantled.
func can_take_back() -> bool:
	return state != State.BUILT and build_progress == 0 and (planks_ready > 0 or materials_delivered() > 0) and claimed_by == null

# Takes one delivered thing back: a plank (&"plank") first, else a delivered material (its item kind); &"" if none.
func take_back_plank() -> bool:
	return take_back_one() != &""

func take_back_one() -> StringName:
	if not can_take_back():
		return &""
	if planks_ready > 0:
		planks_ready -= 1
		return &"plank"
	for kind in materials_ready:
		if int(materials_ready[kind]) > 0:
			materials_ready[kind] = int(materials_ready[kind]) - 1
			return StringName(kind)
	return &""

func can_cancel() -> bool:
	return state != State.BUILT and build_progress == 0 and planks_ready == 0 and materials_delivered() == 0 and planks_reserved == 0 and claimed_by == null

# The empty blueprint goes away.
func cancel() -> void:
	_clear_designation()
	remove_from_group("buildings")
	remove_from_group("build_blockers")
	queue_free()

# One hammer blow by hand (the strike frame). Needs all the planks first.
func hammer_hit() -> void:
	if state == State.BUILT or not is_supplied():
		return
	build_progress += 1
	if state == State.WAITING:
		state = State.BUILDING
	if build_progress >= BUILD_HITS:
		finish_building()

# Share of the work still to do (the Builder scales his build time by it).
func remaining_fraction() -> float:
	return 1.0 - clampf(float(build_progress) / float(maxi(1, BUILD_HITS)), 0.0, 1.0)

func is_waiting() -> bool:
	return state == State.WAITING

# --- The common face of everything buildable (a blueprint of any type; the PitSaw has the same methods): Logistics.blueprints() lists what has
# is_blueprint(), the Builder's job (work_jobs.gd BuildJob) and the designation only ever use these. ---
func is_finished() -> bool:
	return state == State.BUILT

# A finished or cancelled blueprint has no mark (designation_mode.gd keeps them in one place).
func _clear_designation() -> void:
	if is_inside_tree():
		load("res://scripts/designation_mode.gd").clear_for(get_tree(), self)

func is_blueprint() -> bool:
	return state != State.BUILT and building_type != null

# Digging (the pit saw's hole) is not part of an ordinary blueprint.
func needs_digging() -> bool:
	return false

func dig_spot_world() -> Vector2:
	return hammer_spot_world()

func build_total() -> int:
	return BUILD_HITS

# One plank brought to it.
func deliver_plank() -> bool:
	planks_ready += 1
	return true

func start_building() -> void:
	state = State.BUILDING

func finish_building() -> void:
	var was_built: bool = state == State.BUILT
	state = State.BUILT
	if not was_built and is_inside_tree():
		var feedback = load("res://scripts/work_feedback.gd")
		feedback.completed(get_tree(), global_position)
	build_progress = BUILD_HITS
	_clear_designation()
	built.emit(self)
	if building_type != null and building_type.built_scene != null:
		_become_built_scene()

# A Storage or Sawmill blueprint is swapped for the real, working scene in the same spot.
func _become_built_scene() -> void:
	var real: Node2D = building_type.built_scene.instantiate()
	real.position = position
	# (A new wooden bed starts as a bare frame.)
	if "ages" in real and "kind" in real and real.kind == 1:
		real.ages.clear()
	# (So it can be dismantled by its type's cost later.)
	if "building_type" in real:
		real.building_type = building_type
	# (This blueprint gives up its name so the real one is called plain "Storage" / "Sawmill".)
	name = str(name) + "_blueprint"
	real.name = building_type.type_name.replace(" ", "")
	# This blueprint stops counting as a building / obstacle right now.
	remove_from_group("buildings")
	remove_from_group("build_blockers")
	get_parent().add_child(real, true)
	print("%s built" % building_type.type_name)
	queue_free()

# Beds nobody has claimed yet (none until the building is built).
func free_beds() -> int:
	if state != State.BUILT:
		return 0
	return maxi(0, capacity - residents.size())

# --- The bed ---------------------------------------------------------------------------------------------

# A finished house.
func has_bedroom() -> bool:
	return state == State.BUILT and capacity > 0

# The beds standing inside it.
func inside_beds() -> Array:
	var out: Array = []
	if interior == null or not is_instance_valid(interior):
		return out
	for bed in get_tree().get_nodes_in_group("beds"):
		if bed.interior_node() == interior:
			out.append(bed)
	return out

func bed_count() -> int:
	var n: int = inside_beds().size()
	if n < house_max_beds:
		no_room_said = false
	return n

# A bed (grass or wooden) or a Wooden Bed blueprint on the floor counts towards house_max_beds.
func has_room_for_bed() -> bool:
	return house_max_beds <= 0 or bed_count() + blueprint_beds() < house_max_beds

# Wooden Bed blueprints standing in the room.
func blueprint_beds() -> int:
	if interior == null or not is_instance_valid(interior):
		return 0
	var n: int = 0
	var room: Rect2 = interior.rect_world()
	for other in get_tree().get_nodes_in_group("buildings"):
		if other != self and other.building_type != null and other.building_type.indoor_limit_key == "bed" and other.state != other.State.BUILT and room.has_point(other.global_position):
			n += 1
	return n

func _best_bed_level() -> int:
	if not has_bedroom():
		return 0
	var best: int = 0
	for bed in inside_beds():
		best = maxi(best, bed.level())
	return best

# The best recovery share any bed inside gives (the floor's when there is none).
func best_recovery() -> float:
	var clock: Node = get_tree().get_first_node_in_group("game_clock")
	if clock == null:
		return 0.0
	var best: float = clock.floor_recovery_fraction
	if has_bedroom():
		for bed in inside_beds():
			best = maxf(best, bed.recovery_fraction())
	return best

# What someone sleeping on this house's floor is told.
func sleep_text() -> String:
	return "You sleep on the floor - you recover a little"

# How a sleeper's rest changes here per clock-second, from the GameClock's exported numbers for this
# bed_level: the bare floor for NONE (energy rises a little), then a grass / hay bed, then a proper bed.
func sleep_rate() -> float:
	var clock: Node = get_tree().get_first_node_in_group("game_clock")
	if clock == null:
		return 0.0
	return clock.recovery_per_second(best_recovery())

# Where a resident stands to move in.
func door_position() -> Vector2:
	return global_position + door_offset

func door_rect_world() -> Rect2:
	return Rect2(global_position + door_area_rect.position, door_area_rect.size)

# What its inside is made from (a House placed by hand in the scene has no type of its own).
func interior_type() -> BuildingType:
	if building_type != null and building_type.interior_kind != "":
		return building_type
	return load("res://assets/house_type.tres")

# The inside of this house, made the first time it is asked for.
func get_interior() -> Node2D:
	if interior == null or not is_instance_valid(interior):
		interior = load("res://scripts/building_interior.gd").create_for(self, get_parent())
	return interior

func player_is_inside() -> bool:
	return interior != null and is_instance_valid(interior) and interior.player_inside
