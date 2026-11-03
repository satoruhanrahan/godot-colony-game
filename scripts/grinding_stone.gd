extends Node2D

# The grinding stone: a small solid thing on the ground (built from a "Grinding Stone" blueprint: 2 flat stones, 3 hammer hits). It
# holds at most 1 input (a wheat sheaf) and 1 output (flour_per_sheaf flour). Holding a wheat sheaf, E puts it in
# ("The grinding stone is full." if one is already in); with empty hands E grinds: grind_presses presses (a grinding sound at
# one constant pitch each, a different one when it is done; no progress bar), then the flour lies on the grinding stone;
# empty hands + E takes the flour. "Nothing to grind." when there is nothing in it. A half-finished grind keeps its
# presses while the claim is held (press_claim_seconds since the last press), then starts over.
# Dismantling it (Shift+E with the hammer) is blocked while it holds anything.

const FoodConfig = preload("res://scripts/food_config.gd")
const Logistics = preload("res://scripts/logistics.gd")
const Items = preload("res://scripts/items.gd")
const BundleArt = preload("res://scripts/bundle_art.gd")

@export var building_type: BuildingType

var has_sheaf: bool = false
var flour_out: int = 0
var progress: int = 0
var claimed_by = null
var _claim_left: float = 0.0

@onready var sprite: Sprite2D = $Sprite
@onready var input_sprite: Sprite2D = $Input
@onready var output_sprite: Sprite2D = $Output
@onready var label: Label = $Label

func _ready() -> void:
	Ui.adopt(label)   # (its text is drawn by the UI, crisp, in screen space)
	add_to_group("grinding_stones")
	add_to_group("build_blockers")
	input_sprite.texture = Items.texture(&"wheat_sheaf")
	output_sprite.texture = Items.texture(&"flour")
	input_sprite.offset = BundleArt.offset_for(input_sprite.texture)
	output_sprite.offset = BundleArt.offset_for(output_sprite.texture)
	_refresh()

func _process(delta: float) -> void:
	if claimed_by != null:
		if not is_instance_valid(claimed_by):
			claimed_by = null
			progress = 0
		else:
			_claim_left -= delta
			if _claim_left <= 0.0:
				# He walked away mid-grind: the claim goes, and so does the progress.
				progress = 0
				claimed_by = null
	label.visible = footprint_rect().has_point(get_global_mouse_position())
	if label.visible:
		label.text = readout()

func footprint_rect() -> Rect2:
	return Rect2(global_position + Vector2(-16, -32), Vector2(32, 32))

func interact_point() -> Vector2:
	return global_position + Vector2(0, -4)

func hammer_spot_world() -> Vector2:
	return Logistics.beside_spot(global_position, Vector2(-22, 0))

func holds_anything() -> bool:
	return has_sheaf or flour_out > 0

func readout() -> String:
	if flour_out > 0:
		return "Grinding stone: flour ready" + (" (+ sheaf)" if has_sheaf else "")
	if has_sheaf:
		return "Grinding stone: sheaf in" + (" (%d/%d)" % [progress, FoodConfig.cfg().grind_presses] if progress > 0 else "")
	return "Grinding stone: empty"

func _refresh() -> void:
	if input_sprite != null:
		input_sprite.visible = has_sheaf
		output_sprite.visible = flour_out > 0

func try_claim(who) -> bool:
	if claimed_by != null and claimed_by != who and is_instance_valid(claimed_by):
		return false
	claimed_by = who
	_claim_left = FoodConfig.cfg().press_claim_seconds
	return true

func release_claim(who) -> void:
	if claimed_by == who:
		claimed_by = null
		progress = 0

# A wheat sheaf goes in.
func add_sheaf(who) -> String:
	if has_sheaf:
		return "The grinding stone is full."
	if claimed_by != null and claimed_by != who and is_instance_valid(claimed_by):
		return "Someone is using it."
	has_sheaf = true
	progress = 0
	AudioManager.play("pickup", global_position, 1.1)
	_refresh()
	return ""

# One press of grinding.
func grind_press(who) -> String:
	if not has_sheaf:
		return "Nothing to grind."
	if flour_out >= FoodConfig.cfg().flour_per_sheaf:
		return "Take the flour first."
	if not try_claim(who):
		return "Someone is using it."
	progress += 1
	if progress >= FoodConfig.cfg().grind_presses:
		AudioManager.play("grind_done", global_position)
		has_sheaf = false
		flour_out += FoodConfig.cfg().flour_per_sheaf
		progress = 0
		claimed_by = null
	else:
		# (One constant pitch, every press.)
		AudioManager.play("grind", global_position, 1.0)
	_refresh()
	return ""

func take_flour() -> bool:
	if flour_out <= 0:
		return false
	flour_out -= 1
	_refresh()
	return true
