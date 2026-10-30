extends Node2D

# The campfire (built from a "Campfire" blueprint: 3 branches and 3 flat stones, 3 hammer hits). All by hand.
#  - Fuel: holding a branch, a plank or a log, E adds burn time (branch 150, plank 600, log 900 clock-seconds,
#    capped at fire_max_fuel_clock_seconds). The fuel is just the burn time left (burn_left); it is not shown.
#  - Light: with the fire starter (ferro rod), E three times lights a fire that has burn time ("Nothing to burn."
#    if empty, "Already burning." if lit). It burns burn_left down in clock-seconds; at 0 it goes out and the stone
#    cools.
#  - Flat stone: holding one, E puts it on top (one stone); Shift+E with empty hands takes it off.
#  - The stone heats while the fire is lit: after stone_heat_clock_seconds it is hot, and it STAYS hot for as long
#    as the fire stays lit, however many things are baked. When the fire goes out (or the stone is taken off) it is
#    cold again.
#  - Cook: holding DOUGH (made from flour and water on the dough board), E puts it on the stone (hot or cold, lit or not). It only COOKS while the stone is
#    hot, for cook_clock_seconds of hot time (clock time, so it works through the sleep skip); the progress pauses when
#    the stone goes cold and goes on when it is hot again. When done it is a flatbread on the stone; empty hands + E
#    takes it (an uncooked dough comes back as dough). The stone holds campfire_stone_capacity things (1), and the
#    stone cannot be taken off while there is food on it.
#  - It never spreads and never hurts. A half-finished spark sequence keeps its claim and presses while presses keep
#    coming (press_claim_seconds), then starts over.
# Dismantling returns the materials (and puts the stone on the ground).

const FoodConfig = preload("res://scripts/food_config.gd")
const Items = preload("res://scripts/items.gd")
const WorkFx = preload("res://scripts/work_fx.gd")
const UNLIT: Texture2D = preload("res://sprites/campfire_unlit.png")
const ART_DIR: String = "res://sprites/"
# The pictures of the fire: unlit or lit, by what is on it. The file names are campfire_<lit|unlit>[_with_<stone|dough|bread>]
# .png ("bread" is the flatbread). A lit one is a strip of 16x16 frames (with an optional .json for the frame times).
# A missing file falls back, never crashing: unlit_with_X missing -> lit_with_X, darkened (a placeholder); any
# with_X missing -> the stone-only picture. A file named with a space ("campfire_lit_with dough.png") is used for the
# underscore name when only that exists. art_for() says which file a state used and whether it fell back.
static var _art_cache: Dictionary = {}
const DARKEN: Color = Color(0.6, 0.6, 0.6)

@export var building_type: BuildingType

var burn_left: float = 0.0
var lit: bool = false
var stone: bool = false
var stone_heat: float = 0.0
var claimed_by = null
var spark_count: int = 0
# What lies on the stone: [{"kind": &"dough" or &"flatbread", "progress": hot clock-seconds cooked}].
var food: Array[Dictionary] = []
var _claim_left: float = 0.0
var _loop: int = 0
var _t: float = 0.0
var _clock: Node

@onready var sprite: Sprite2D = $Sprite
@onready var glow: Sprite2D = $Glow
@onready var label: Label = $Label

func _ready() -> void:
	Ui.adopt(label)   # (its text is drawn by the UI, crisp, in screen space)
	add_to_group("campfires")
	add_to_group("build_blockers")
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 96
	tex.height = 96
	glow.texture = tex
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow.material = mat
	glow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	glow.visible = false
	_update_look()

# --- The pictures --------------------------------------------------------------------------------------------

# The file for a picture name, or "": the name itself, or with a space instead of the underscore after "with".
static func _find_file(base: String) -> String:
	var plain: String = "%s%s.png" % [ART_DIR, base]
	if ResourceLoader.exists(plain):
		return plain
	var spaced: String = "%s%s.png" % [ART_DIR, base.replace("_with_", "_with ")]
	if base.contains("_with_") and ResourceLoader.exists(spaced):
		return spaced
	return ""

# The frames of a horizontal strip of 16x16 pictures (one frame for a single picture).
static func _sheet_frames(path: String) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	var sheet: Texture2D = load(path)
	if sheet == null:
		return out
	for i in maxi(1, int(sheet.get_width() / 16)):
		var atlas := AtlasTexture.new()
		atlas.atlas = sheet
		atlas.region = Rect2(i * 16, 0, 16, 16)
		out.append(atlas)
	return out

# Frame times from the picture's .json when it is there; otherwise a gentle flicker of 0.15 s a frame.
static func _json_durations(png_path: String, count: int) -> Array[float]:
	var out: Array[float] = []
	var candidates: Array[String] = [png_path.get_basename() + ".json", png_path.get_basename().replace("_with ", "_with_") + ".json"]
	for path in candidates:
		if FileAccess.file_exists(path):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
			if parsed is Dictionary and parsed.has("frames"):
				for key in parsed["frames"]:
					out.append(float(parsed["frames"][key].get("duration", 150)) / 1000.0)
				break
	while out.size() < count:
		out.append(0.15)
	return out

# The picture set of a state: {"frames": Array[Texture2D], "durations": Array[float], "file": what was used, "dark": drawn
# darkened (a placeholder), "note": "" or why it is not the exact file}. `variant` is "", "stone", "dough" or "bread".
static func art_for(is_lit: bool, variant: String) -> Dictionary:
	var key: String = "%s:%s" % ["lit" if is_lit else "unlit", variant]
	if _art_cache.has(key):
		return _art_cache[key]
	var result: Dictionary = _resolve_art(is_lit, variant)
	_art_cache[key] = result
	return result

static func _base_name(is_lit: bool, variant: String) -> String:
	return ("campfire_lit" if is_lit else "campfire_unlit") + ("" if variant == "" else "_with_" + variant)

static func _resolve_art(is_lit: bool, variant: String) -> Dictionary:
	var wanted: String = _base_name(is_lit, variant)
	var file: String = _find_file(wanted)
	if file != "":
		var frames: Array[Texture2D] = _sheet_frames(file)
		if not frames.is_empty():
			var note: String = "" if file == "%s%s.png" % [ART_DIR, wanted] else "space in the file name: rename it to %s.png" % wanted
			return {"frames": frames if is_lit else [frames[0]], "durations": _json_durations(file, frames.size()), "file": file, "dark": false, "note": note}
	# Missing. An unlit picture with something on it: the lit one, darkened.
	if not is_lit and variant != "":
		var lit_file: String = _find_file(_base_name(true, variant))
		if lit_file != "":
			var lit_frames: Array[Texture2D] = _sheet_frames(lit_file)
			if not lit_frames.is_empty():
				return {"frames": [lit_frames[0]], "durations": [0.15], "file": lit_file, "dark": true, "note": "placeholder: %s.png is missing, the lit one is used darkened" % wanted}
	# Any with_X missing: the stone-only picture of the same state.
	if variant != "stone" and variant != "":
		var fallback: Dictionary = art_for(is_lit, "stone").duplicate()
		fallback["note"] = "%s.png is missing: the stone-only picture is used (%s)" % [wanted, str(fallback["file"]).get_file()]
		return fallback
	if variant == "stone":
		var plain: Dictionary = art_for(is_lit, "").duplicate()
		plain["note"] = "%s.png is missing: the plain picture is used" % wanted
		return plain
	# The plain picture always exists; as a last resort a blank one, so nothing can crash.
	var blank: Array[Texture2D] = [UNLIT]
	return {"frames": blank, "durations": [0.15], "file": "campfire_unlit.png", "dark": false, "note": "%s.png is missing" % wanted}

# For the self-check: one line per state, which file it used and whether it fell back.
static func art_report() -> Array[String]:
	var out: Array[String] = []
	for is_lit in [false, true]:
		for variant in ["", "stone", "dough", "bread"]:
			var art: Dictionary = art_for(is_lit, variant)
			var name: String = _base_name(is_lit, variant)
			out.append("%s -> %s%s%s" % [name, str(art["file"]).get_file(), " (darkened placeholder)" if art["dark"] else "", ("  [FELL BACK: " + art["note"] + "]") if art["note"] != "" else ""])
	return out

func _game_clock() -> Node:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	return _clock

func _exit_tree() -> void:
	_stop_loop()

func _process(delta: float) -> void:
	var clock: Node = _game_clock()
	if lit and clock != null:
		burn_left -= clock.clock_delta
		if stone:
			stone_heat += clock.clock_delta
		if burn_left <= 0.0:
			_go_out()
	# Cooking: only while the stone is hot (clock time, so the sleep skip cooks too).
	if clock != null and stone_hot():
		for item in food:
			if item["kind"] == &"dough":
				item["progress"] += clock.clock_delta
				if item["progress"] >= FoodConfig.cfg().cook_clock_seconds:
					item["kind"] = &"flatbread"
					AudioManager.play("bake_done", global_position)
	if claimed_by != null:
		if not is_instance_valid(claimed_by):
			claimed_by = null
			spark_count = 0
		else:
			_claim_left -= delta
			if _claim_left <= 0.0:
				# The presses stopped: the claim and the progress go.
				claimed_by = null
				spark_count = 0
	_t += delta
	_update_look()
	label.visible = footprint_rect().has_point(get_global_mouse_position())
	if label.visible:
		label.text = readout()

func footprint_rect() -> Rect2:
	return Rect2(global_position + Vector2(-16, -32), Vector2(32, 32))

func interact_point() -> Vector2:
	return global_position + Vector2(0, -4)

func hammer_spot_world() -> Vector2:
	return global_position + Vector2(-22, 0)

# --- State ---------------------------------------------------------------------------------------------------

func stone_hot() -> bool:
	return lit and stone and stone_heat >= FoodConfig.cfg().stone_heat_clock_seconds

func _go_out() -> void:
	lit = false
	burn_left = 0.0
	stone_heat = 0.0
	spark_count = 0
	_stop_loop()

func _stop_loop() -> void:
	if _loop != 0:
		AudioManager.stop_loop(_loop)
		_loop = 0

func _time_text(seconds: float) -> String:
	var clock: Node = _game_clock()
	var day: float = clock.day_length if clock != null else 600.0
	var days: int = int(seconds / day)
	var hours: int = int(fmod(seconds, day) / day * 24.0)
	if days > 0:
		return "%dd %dh" % [days, hours]
	return "%dh" % hours if hours > 0 else "under 1h"

# "Campfire: lit, stone hot (burns 1d 4h)", "Campfire: lit, stone heating", "Campfire: out", and without a stone
# "Campfire: lit (burns 4h). No stone to cook on." / "Campfire: out. No stone to cook on."
const NO_STONE_TEXT: String = "No stone to cook on."

func readout() -> String:
	var what: String
	var note: String = ""
	if not stone:
		what = "lit" if lit else "out"
		note = ". " + NO_STONE_TEXT
	elif not lit:
		what = "out"
	elif stone_hot():
		what = "lit, stone hot"
	else:
		what = "lit, stone heating"
	var fuel: String = (" (burns %s)" % _time_text(burn_left)) if burn_left > 0.0 else ""
	var text: String = "Campfire: %s%s%s" % [what, fuel, note]
	if not food.is_empty():
		text += "\n" + food_text()
	return text

# What is on the stone: "Flatbread ready", "Stone hot, cooking (60%)", "Stone cold, waiting" ("" when nothing is).
func food_text() -> String:
	if food.is_empty():
		return ""
	for item in food:
		if item["kind"] == &"dough":
			if stone_hot():
				return "Stone hot, cooking (%d%%)" % int(clampf(item["progress"] / FoodConfig.cfg().cook_clock_seconds, 0.0, 1.0) * 100.0)
			return "Stone cold, waiting"
	return "Flatbread ready"

# Which picture set the fire uses: "" (plain), "stone", "dough" or "bread" (the first thing on the stone).
func _variant() -> String:
	if not food.is_empty():
		return "bread" if food[0]["kind"] == &"flatbread" else "dough"
	return "stone" if stone else ""

# The picture: chosen from the state alone (lit or unlit, and what is on the stone); a lit one flickers.
func _update_look() -> void:
	var art: Dictionary = art_for(lit, _variant())
	var frames: Array = art["frames"]
	var index: int = 0
	if lit and frames.size() > 1:
		var durations: Array = art["durations"]
		var total: float = 0.0
		for d in durations:
			total += d
		var at: float = fmod(_t, maxf(0.1, total))
		for i in durations.size():
			if at < durations[i]:
				index = i
				break
			at -= durations[i]
	sprite.texture = frames[mini(index, frames.size() - 1)]
	sprite.modulate = DARKEN if art["dark"] else Color(1, 1, 1)
	if lit:
		# The glow: only when it is dark enough to matter.
		var clock: Node = _game_clock()
		var dark: float = clock.darkness() if clock != null else 0.0
		glow.visible = dark > 0.05
		glow.modulate = Color(1.0, 0.62, 0.28, 0.55 * dark * (0.9 + 0.1 * sin(_t * 9.0)))
	else:
		glow.visible = false

# --- Claims ---------------------------------------------------------------------------------------------------

func try_claim(who) -> bool:
	if claimed_by != null and claimed_by != who and is_instance_valid(claimed_by):
		return false
	claimed_by = who
	_claim_left = FoodConfig.cfg().press_claim_seconds
	return true

func release_claim(who) -> void:
	if claimed_by == who:
		claimed_by = null
		spark_count = 0

# --- What he does here --------------------------------------------------------------------------------------

# Adds fuel: kind = &"branch", &"plank" or &"log". False if the fire is already full of it.
func add_fuel(kind: StringName) -> bool:
	var cfg: Resource = FoodConfig.cfg()
	if burn_left >= cfg.fire_max_fuel_clock_seconds - 0.01:
		return false
	var amount: float = cfg.fuel_branch
	if kind == &"plank":
		amount = cfg.fuel_plank
	elif kind == &"log":
		amount = cfg.fuel_log
	burn_left = minf(cfg.fire_max_fuel_clock_seconds, burn_left + amount)
	AudioManager.play("drop", global_position)
	return true

# One press of the fire starter.
func spark_press(who) -> String:
	if lit:
		return "Already burning."
	if burn_left <= 0.0:
		return "Nothing to burn."
	if not try_claim(who):
		return "Someone is using it."
	AudioManager.play("spark", global_position)
	WorkFx.spark(get_tree(), global_position + Vector2(0, -6))
	spark_count += 1
	if spark_count >= FoodConfig.cfg().spark_presses:
		lit = true
		stone_heat = 0.0
		spark_count = 0
		claimed_by = null
		AudioManager.play("fire_light", global_position)
		_loop = AudioManager.play_loop("fire_loop", global_position, 1.0, -8.0)
	return ""

func place_stone() -> bool:
	if stone:
		return false
	stone = true
	stone_heat = 0.0
	AudioManager.play("stone_place", global_position)
	return true

func take_stone() -> bool:
	if not stone or not food.is_empty():
		return false
	stone = false
	stone_heat = 0.0
	AudioManager.play("pickup", global_position)
	return true

# Flour goes on the stone as dough (hot or cold). Returns "" or a message.
func place_dough() -> String:
	if not stone:
		return "Put a flat stone on the fire first."
	if food.size() >= FoodConfig.cfg().campfire_stone_capacity:
		return "The stone is full."
	food.append({"kind": &"dough", "progress": 0.0})
	AudioManager.play("stone_place", global_position, 1.1)
	return ""

# Takes the oldest thing off the stone: &"flatbread" (cooked) or &"dough" (not cooked yet: it comes back as it went on);
# &"" if there is nothing.
func take_food() -> StringName:
	if food.is_empty():
		return &""
	var item: Dictionary = food.pop_front()
	AudioManager.play("pickup", global_position)
	return &"flatbread" if item["kind"] == &"flatbread" else &"dough"
