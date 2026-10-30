extends Sprite2D

# Simple stock counts for the Hauler's overflow trips. The label above the building is
# a temporary readout.
# Set when it was built from a blueprint (what dismantling returns); the one placed in the scene by hand falls
# back to the Storage type.
@export var building_type: BuildingType
# The visible door of the Storage (relative to the base: the picture is 32x32 with the door at x 4..17, y 16..32,
# and the sprite is offset by (0, -16)) and where people stand outside it.
@export var door_area_rect: Rect2 = Rect2(-12, -16, 13, 16)
@export var door_offset: Vector2 = Vector2(-5, 4)
# The room inside (made the first time someone goes in, kept afterwards): see BuildingInterior.
var interior: Node2D = null
@export var log_capacity: int = 10
@export var plank_capacity: int = 10
# The stock readout shows when the player is within this many px, or the mouse is over the Storage
# (Minimal HUD: only the mouse).
@export var label_radius: float = 64.0

# THE stock of this Storage (the single source of truth: the room inside only draws it). Every way of putting
# something in or taking it out (the Hauler, the player outside or inside, any later worker) ends in one of these
# two setters, which also tell the room to redraw.
var logs_stored: int = 0:
	set(value):
		logs_stored = value
		_stock_changed()
var planks_stored: int = 0:
	set(value):
		planks_stored = value
		_stock_changed()

@onready var count_label: Label = $CountLabel

func _ready() -> void:
	Ui.adopt(count_label)   # (its text is drawn by the UI, crisp, in screen space)
	add_to_group("storages")
	add_to_group("build_blockers")
	_refresh_label()

func _process(_delta: float) -> void:
	if count_label == null:
		return
	var hud: Node = get_tree().get_first_node_in_group("hud")
	var player: Node2D = get_tree().get_first_node_in_group("player")
	var hovered: bool = Rect2(global_position + Vector2(-16, -32), Vector2(32, 34)).has_point(get_global_mouse_position())
	var near: bool = player != null and player.global_position.distance_to(global_position) <= label_radius and not (hud != null and hud.is_minimal())
	if hud != null and hud.show_overlays_only_on_hover:
		near = false
	count_label.visible = hovered or near

# Where the player stands near to use it.
func interact_point() -> Vector2:
	return global_position + Vector2(0, -8)

# --- The inside --------------------------------------------------------------------------------------------

func interior_type() -> BuildingType:
	if building_type != null and building_type.interior_kind != "":
		return building_type
	return load("res://assets/storage_type.tres")

# Where people stand to go in.
func door_position() -> Vector2:
	return global_position + door_offset

func door_rect_world() -> Rect2:
	return Rect2(global_position + door_area_rect.position, door_area_rect.size)

func get_interior() -> Node2D:
	if interior == null or not is_instance_valid(interior):
		interior = load("res://scripts/building_interior.gd").create_for(self, get_parent())
	return interior

func player_is_inside() -> bool:
	return interior != null and is_instance_valid(interior) and interior.player_inside

# (A storage holds no beds; this is here so the bundle piles ask the same of every room.)
var no_room_said: bool = false

func has_room_for_bed() -> bool:
	return false

func has_log_room() -> bool:
	return logs_stored < log_capacity

func plank_room() -> int:
	return plank_capacity - planks_stored

# Stores one log; returns false if there is no room.
func add_log() -> bool:
	if not has_log_room():
		return false
	logs_stored += 1
	return true

# Stores up to `count` planks and returns how many fitted.
func add_planks(count: int) -> int:
	var stored: int = clampi(count, 0, plank_room())
	planks_stored += stored
	return stored

func take_log() -> bool:
	if logs_stored <= 0:
		return false
	logs_stored -= 1
	return true

# Removes up to `count` planks and returns how many were taken.
func take_planks(count: int) -> int:
	var taken: int = clampi(count, 0, planks_stored)
	planks_stored -= taken
	return taken

func _stock_changed() -> void:
	_refresh_label()
	if interior != null and is_instance_valid(interior):
		interior.refresh_stock()

func _refresh_label() -> void:
	if count_label != null:
		count_label.text = "Logs %d / Planks %d" % [logs_stored, planks_stored]
