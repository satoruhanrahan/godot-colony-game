extends Node2D

# The dough board: a CARRYABLE ITEM (held kind &"dough_board"; it is not a building). It keeps its state (up to 1 flour,
# 1 scoop of water and 1 dough) when it is carried, dropped or put on a table, and it works wherever it lies: on the
# ground, or on a table (then it is a child of the table). It cannot be used while it is held.
#  - Holding flour, E puts the flour on the board; holding a bucket with water, E pours one scoop on it (both
#    one-shot). "The board has flour already." / "The board has water already." / "The board is full." (dough waits).
#  - With both on it, empty hands + E kneads: knead_presses presses (a soft thud at one constant pitch each, a different
#    sound when done; hold E to repeat), then a dough lies on the board. "Nothing to mix." when it lacks one of them.
#  - Empty hands + E: if it holds dough, takes the dough; if it holds flour AND water, kneads; otherwise picks up the
#    board itself.
# A half-finished kneading keeps its presses while the claim is held (press_claim_seconds since the last press), then
# starts over. The pictures: dough_board.png, dough_board_with_flour.png, dough_board_with_dough.png (each falls back to
# dough_board.png when it is missing; the dough then shows as a small lump on the board).

const FoodConfig = preload("res://scripts/food_config.gd")
const Items = preload("res://scripts/items.gd")
const BundleArt = preload("res://scripts/bundle_art.gd")
const WITH_FLOUR: String = "res://sprites/dough_board_with_flour.png"
const WITH_DOUGH: String = "res://sprites/dough_board_with_dough.png"

var has_flour: bool = false
var has_water: bool = false
var dough: bool = false
var progress: int = 0
var claimed_by = null
# The state it was made with (a board that was carried and put down), applied when it enters the tree.
var init_state: Dictionary = {}
var _claim_left: float = 0.0
var _plain: Texture2D

@onready var sprite: Sprite2D = $Sprite
@onready var dough_sprite: Sprite2D = $Dough

func _ready() -> void:
	add_to_group("dough_boards")
	_plain = sprite.texture
	dough_sprite.texture = Items.texture(&"dough")
	dough_sprite.offset = BundleArt.offset_for(dough_sprite.texture)
	set_state(init_state)

func _process(delta: float) -> void:
	if claimed_by != null:
		if not is_instance_valid(claimed_by):
			claimed_by = null
			progress = 0
		else:
			_claim_left -= delta
			if _claim_left <= 0.0:
				# He walked away mid-knead: the claim goes, and so does the progress.
				progress = 0
				claimed_by = null

# --- State (what a carried board keeps) ----------------------------------------------------------------------

func get_state() -> Dictionary:
	return {"flour": has_flour, "water": has_water, "dough": dough}

func set_state(state: Dictionary) -> void:
	has_flour = bool(state.get("flour", false))
	has_water = bool(state.get("water", false))
	dough = bool(state.get("dough", false))
	progress = 0
	_refresh()

func interact_point() -> Vector2:
	return global_position + Vector2(0, -3)

func holds_anything() -> bool:
	return has_flour or has_water or dough

# The name and state: "Dough board (empty)", "Dough board (flour, water)", "Dough board (dough)".
func readout() -> String:
	if dough:
		return "Dough board (dough)"
	var parts: Array[String] = []
	if has_flour:
		parts.append("flour")
	if has_water:
		parts.append("water")
	var text: String = "Dough board (%s)" % (", ".join(parts) if not parts.is_empty() else "empty")
	if has_flour and has_water and progress > 0:
		text += " kneading %d/%d" % [progress, FoodConfig.cfg().knead_presses]
	return text

func _refresh() -> void:
	if sprite == null:
		return
	var with_flour: Texture2D = load(WITH_FLOUR) if ResourceLoader.exists(WITH_FLOUR) else null
	var with_dough: Texture2D = load(WITH_DOUGH) if ResourceLoader.exists(WITH_DOUGH) else null
	if dough and with_dough != null:
		sprite.texture = with_dough
	elif has_flour and with_flour != null and not dough:
		sprite.texture = with_flour
	else:
		sprite.texture = _plain
	# (No picture of a board with dough: the plain board with a small lump of dough on it.)
	dough_sprite.visible = dough and with_dough == null
	dough_sprite.position = Vector2(0, -3)
	queue_redraw()

func _draw() -> void:
	if has_water:
		draw_rect(Rect2(-4, -7, 3, 2), Color(0.35, 0.65, 0.95))
		draw_rect(Rect2(-3, -8, 1, 1), Color(0.8, 0.92, 1.0))

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

func put_flour() -> String:
	if dough:
		return "The board is full."
	if has_flour:
		return "The board has flour already."
	has_flour = true
	AudioManager.play("drop", global_position, 1.1)
	_refresh()
	return ""

func pour_water() -> String:
	if dough:
		return "The board is full."
	if has_water:
		return "The board has water already."
	has_water = true
	AudioManager.play("pour", global_position)
	_refresh()
	return ""

# One press of kneading.
func knead_press(who) -> String:
	if dough:
		return "The board is full."
	if not (has_flour and has_water):
		return "Nothing to mix."
	if not try_claim(who):
		return "Someone is using it."
	progress += 1
	if progress >= FoodConfig.cfg().knead_presses:
		AudioManager.play("knead_done", global_position)
		has_flour = false
		has_water = false
		dough = true
		progress = 0
		claimed_by = null
	else:
		# (One constant pitch, every press.)
		AudioManager.play("knead", global_position, 1.0)
	_refresh()
	return ""

func take_dough() -> bool:
	if not dough:
		return false
	dough = false
	_refresh()
	return true
