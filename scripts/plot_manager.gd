extends Node2D

# All the wheat plots of the world, in ONE node. Plots live on their own grid of plot_size_px (11) pixels,
# anchored at the world origin and independent of the 32 px grid: cell = floor(world position / 11), and a
# plot's picture is drawn with its top-left corner at cell * 11 (never centred, so an odd size cannot sit half a
# pixel off). They are a decal layer (z -1) under the characters, never solid, and they are drawn together in
# one _draw(), so hundreds cost nothing.
#
# Data: plots = {cell -> {"state": &"tilled" | &"planted" | &"stubble", "planted_at": clock seconds}}.
# The growth stage is DERIVED from the clock (GameClock.total_seconds()) when it is asked or drawn: there are no
# per-plot timers, so growth carries on correctly through the sleep skip, fast forward and set_time. The node only
# watches for the next moment a stage changes (to redraw).
#
# The pictures are 16x16 canvases with the 11x11 soil block at (5, 0) (tilled, sown, growing) or at (0, 5)
# (ripe, stubble: the wheat stands up out of the top of the cell), so each picture is drawn at cell * 11 minus the
# soil block's corner.

const FoodConfig = preload("res://scripts/food_config.gd")
const PlankPiles = preload("res://scripts/plank_piles.gd")
const Items = preload("res://scripts/items.gd")
const WorkFx = preload("res://scripts/work_fx.gd")

const TILLED: StringName = &"tilled"
const PLANTED: StringName = &"planted"
const STUBBLE: StringName = &"stubble"

# The corner of the soil block in each picture.
const SOIL_TOP_RIGHT: Vector2 = Vector2(5, 0)
const SOIL_BOTTOM_LEFT: Vector2 = Vector2(0, 5)

var plots: Dictionary = {}
# Who is working a cell (a colonist helping): cell -> worker. A cell has one worker at a time; see claim_cell / release_cell.
var claims: Dictionary = {}
# Presses of tilling so far on a bare cell (a transient: the cell becomes a plot at till_presses).
var tilling: Dictionary = {}
@export var map_rect: Rect2 = Rect2(0, 0, 640, 640)
var _next_change: float = INF
var _tex: Dictionary = {}
var _hover: Node2D
var _clock: Node

static func get_for(tree: SceneTree) -> Node2D:
	var found: Node = tree.get_first_node_in_group("plot_manager")
	if found != null:
		return found
	var player: Node = tree.get_first_node_in_group("player")
	var parent: Node = player.get_parent() if player != null else tree.current_scene
	var manager: Node2D = (load("res://scripts/plot_manager.gd") as GDScript).new()
	manager.name = "PlotManager"
	parent.add_child(manager)
	return manager

func _ready() -> void:
	add_to_group("plot_manager")
	z_index = -1
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_tex = {
		"tilled": load("res://sprites/tilled_soil.png"),
		"sown": load("res://sprites/wheat_sown.png"),
		"growing": load("res://sprites/wheat_growing.png"),
		"ripe": load("res://sprites/wheat_ripe.png"),
		"stubble": load("res://sprites/wheat_stubble.png"),
	}
	_hover = PlotHover.new()
	_hover.manager = self
	add_child(_hover)

func _game_clock() -> Node:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	return _clock

func now() -> float:
	var clock: Node = _game_clock()
	return clock.total_seconds() if clock != null else 0.0

func size_px() -> int:
	return FoodConfig.cfg().plot_size_px

# --- Cells ---------------------------------------------------------------------------------------------------

func cell_of(world: Vector2) -> Vector2i:
	var s: float = float(size_px())
	return Vector2i(floori(world.x / s), floori(world.y / s))

func cell_rect(cell: Vector2i) -> Rect2:
	var s: int = size_px()
	return Rect2(cell.x * s, cell.y * s, s, s)

func cell_center(cell: Vector2i) -> Vector2:
	return cell_rect(cell).get_center()

func is_claimed(cell: Vector2i) -> bool:
	if claims.has(cell) and not is_instance_valid(claims[cell]):
		claims.erase(cell)
	return claims.has(cell)

func claim_cell(cell: Vector2i, who) -> bool:
	if is_claimed(cell) and claims[cell] != who:
		return false
	claims[cell] = who
	return true

func release_cell(cell: Vector2i, who) -> void:
	if claims.get(cell) == who:
		claims.erase(cell)

func has_plot(cell: Vector2i) -> bool:
	return plots.has(cell)

# --- Growth (only while watered; derived from the clock) -------------------------------------------------------

# A sown plot is {"state": &"planted", "growth": watered clock-seconds so far (as of "synced"), "synced": the clock
# time that growth was last brought up to, "watered_until": the clock time its water runs out}. Nothing ticks: when
# asked, the growth is the stored growth plus the part of [synced, now] that the water covered (the overlap with
# [.., watered_until]), so it is right through the sleep skip, fast forward and set_time, with no per-plot timer.
# A wheat plot needs wheat_grow_clock_seconds * ripe_at_fraction (1200) seconds of water; one watering gives
# wheat_water_clock_seconds (900). A ripe plot needs no water.

func _grow_time() -> float:
	return FoodConfig.cfg().wheat_grow_clock_seconds

func ripe_growth() -> float:
	return _grow_time() * FoodConfig.cfg().ripe_at_fraction

func _growth_now(plot: Dictionary) -> float:
	var wet_end: float = minf(now(), plot["watered_until"])
	return plot["growth"] + maxf(0.0, wet_end - plot["synced"])

# Brings the stored growth up to now (before the water changes).
func _sync(plot: Dictionary) -> void:
	plot["growth"] = _growth_now(plot)
	plot["synced"] = now()

func growth(cell: Vector2i) -> float:
	return _growth_now(plots[cell]) if plots.has(cell) and plots[cell]["state"] == PLANTED else 0.0

func is_watered(cell: Vector2i) -> bool:
	return plots.has(cell) and plots[cell].get("watered_until", 0.0) > now()

func water_left(cell: Vector2i) -> float:
	return maxf(0.0, plots[cell]["watered_until"] - now()) if plots.has(cell) else 0.0

# What the cell is now: &"" (nothing), &"tilled", &"sown", &"growing", &"ripe" or &"stubble".
func stage(cell: Vector2i) -> StringName:
	if not plots.has(cell):
		return &""
	var plot: Dictionary = plots[cell]
	if plot["state"] != PLANTED:
		return plot["state"]
	var g: float = _growth_now(plot)
	var cfg: Resource = FoodConfig.cfg()
	# (A hundredth of a second of slack: thirds of 1800 are not exact in floating point.)
	if g + 0.01 >= ripe_growth():
		return &"ripe"
	if g + 0.01 >= _grow_time() * cfg.growing_at_fraction:
		return &"growing"
	return &"sown"

# Waters a sown or growing plot now: it stays watered for wheat_water_clock_seconds from this moment.
func water(cell: Vector2i) -> void:
	var plot: Dictionary = plots[cell]
	_sync(plot)
	plot["watered_until"] = now() + FoodConfig.cfg().wheat_water_clock_seconds
	_changed()

# Debug: waters every sown / growing plot within `radius` of `pos`.
func water_near(pos: Vector2, radius: float) -> int:
	var count: int = 0
	for cell in plots.keys():
		var st: StringName = stage(cell)
		if (st == &"sown" or st == &"growing") and cell_center(cell).distance_to(pos) <= radius:
			water(cell)
			count += 1
	return count

# The hover text of a plot, e.g. "Wheat, growing, watered (1d 2h of water left)" or "Wheat, growing, DRY".
func text(cell: Vector2i) -> String:
	match stage(cell):
		&"tilled":
			return "Tilled soil"
		&"sown":
			return "Wheat, sown, %s" % _water_text(cell)
		&"growing":
			return "Wheat, growing, %s" % _water_text(cell)
		&"ripe":
			return "Wheat, ripe"
		&"stubble":
			return "Stubble"
	return ""

func _water_text(cell: Vector2i) -> String:
	if not is_watered(cell):
		return "DRY"
	var clock: Node = _game_clock()
	var day: float = clock.day_length if clock != null else 600.0
	var left: float = water_left(cell)
	var days: int = int(left / day)
	var hours: int = int(fmod(left, day) / day * 24.0)
	var t: String = "%dd %dh" % [days, hours] if days > 0 else ("%dh" % hours if hours > 0 else "under 1h")
	return "watered (%s of water left)" % t

# --- Making and changing plots -------------------------------------------------------------------------------

# Why this bare cell cannot be tilled ("" = it can): the whole 11x11 cell must be free grass inside the map.
func can_till(cell: Vector2i) -> String:
	var rect: Rect2 = cell_rect(cell)
	var refuse: String = "Can't till here."
	if not map_rect.encloses(rect):
		return refuse
	if Footprints.rect_blocked(get_tree(), rect):
		return refuse
	for group in ["berry_bushes", "grass_patches"]:
		for node in get_tree().get_nodes_in_group(group):
			if rect.intersects(Rect2(node.global_position + Vector2(-8, -14), Vector2(16, 16))):
				return refuse
	for bed in get_tree().get_nodes_in_group("beds"):
		if rect.intersects(Rect2(bed.global_position + Vector2(-14, -10), Vector2(28, 12))):
			return refuse
	for pit in get_tree().get_nodes_in_group("pit_saws"):
		if rect.intersects(Rect2(pit.global_position + Vector2(-16, -14), Vector2(32, 18))):
			return refuse
	if PlankPiles.item_in_rect(get_tree(), rect.grow(3.0)):
		return refuse
	return ""

# One press of the hoe on a bare cell; the second makes it a tilled plot. Returns true when it became one.
func till_press(cell: Vector2i) -> bool:
	var presses: int = int(tilling.get(cell, 0)) + 1
	AudioManager.play("till", cell_center(cell))
	WorkFx.dirt(get_tree(), cell_center(cell))
	if presses >= FoodConfig.cfg().till_presses:
		tilling.erase(cell)
		plots[cell] = {"state": TILLED}
		_changed()
		return true
	tilling[cell] = presses
	return false

# Stubble back to tilled soil (one press of the hoe).
func retill(cell: Vector2i) -> void:
	AudioManager.play("till", cell_center(cell))
	WorkFx.dirt(get_tree(), cell_center(cell))
	plots[cell] = {"state": TILLED}
	_changed()

func sow(cell: Vector2i) -> void:
	AudioManager.play("sow", cell_center(cell))
	plots[cell] = {"state": PLANTED, "growth": 0.0, "synced": now(), "watered_until": 0.0}
	_changed()

# A ripe plot is cut: it becomes stubble.
func harvest(cell: Vector2i) -> void:
	AudioManager.play("harvest", cell_center(cell))
	WorkFx.leaves(get_tree(), cell_center(cell), 3)
	plots[cell] = {"state": STUBBLE}
	_changed()

# Is there a plot (tilled, sown, growing, ripe or stubble) at this ground point / under this rectangle?
func plot_at(point: Vector2) -> bool:
	return plots.has(cell_of(point))

func plots_in_rect(rect: Rect2) -> bool:
	for cell in plots.keys():
		if rect.intersects(cell_rect(cell)):
			return true
	return false

# Plots under a new building (or anything else) are removed, nothing refunded.
func clear_rect(rect: Rect2) -> int:
	var removed: int = 0
	for cell in plots.keys():
		if rect.intersects(cell_rect(cell)):
			plots.erase(cell)
			removed += 1
	for cell in tilling.keys():
		if rect.intersects(cell_rect(cell)):
			tilling.erase(cell)
	if removed > 0:
		_changed()
	return removed

# Debug: every sown / growing plot within `radius` of `pos` ripens now.
func ripen_near(pos: Vector2, radius: float) -> int:
	var count: int = 0
	for cell in plots.keys():
		if plots[cell]["state"] == PLANTED and cell_center(cell).distance_to(pos) <= radius:
			plots[cell]["growth"] = ripe_growth()
			plots[cell]["synced"] = now()
			count += 1
	if count > 0:
		_changed()
	return count

func _changed() -> void:
	_recompute_next_change()
	queue_redraw()

func _recompute_next_change() -> void:
	# The next moment a picture changes: while watered, the growth stages; and when the water runs out (the tint).
	_next_change = INF
	var t: float = now()
	var cfg: Resource = FoodConfig.cfg()
	for plot in plots.values():
		if plot["state"] != PLANTED:
			continue
		var wet_until: float = plot["watered_until"]
		if wet_until <= t:
			continue
		_next_change = minf(_next_change, wet_until)
		var g: float = _growth_now(plot)
		for threshold in [_grow_time() * cfg.growing_at_fraction, ripe_growth()]:
			if threshold > g:
				var at: float = t + (threshold - g)
				if at <= wet_until:
					_next_change = minf(_next_change, at)

func _process(_delta: float) -> void:
	# (A stage changes at a known moment; after a sleep skip several may have passed at once.)
	if now() >= _next_change:
		_recompute_next_change()
		queue_redraw()

# --- Drawing --------------------------------------------------------------------------------------------------

func _texture_for(cell: Vector2i) -> Array:
	match stage(cell):
		&"tilled":
			return [_tex["tilled"], SOIL_TOP_RIGHT]
		&"sown":
			return [_tex["sown"], SOIL_TOP_RIGHT]
		&"growing":
			return [_tex["growing"], SOIL_TOP_RIGHT]
		&"ripe":
			return [_tex["ripe"], SOIL_BOTTOM_LEFT]
		&"stubble":
			return [_tex["stubble"], SOIL_BOTTOM_LEFT]
	return []

func _draw() -> void:
	var cells: Array = plots.keys()
	# Top rows first, so the wheat of a lower plot stands in front of the plot above it.
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	var s: int = size_px()
	for cell in cells:
		var pair: Array = _texture_for(cell)
		if pair.is_empty():
			continue
		# A watered plot is drawn darker (a tint on the picture, no extra art).
		var tint: Color = Color(0.74, 0.74, 0.84) if (stage(cell) == &"sown" or stage(cell) == &"growing") and is_watered(cell) else Color(1, 1, 1)
		draw_texture(pair[0], Vector2(cell.x * s, cell.y * s) - pair[1], tint)

# --- The hover (an 11x11 outline and the plot's text) -----------------------------------------------------------

var hover_cell: Vector2i = Vector2i(-99999, -99999)
var hover_on: bool = false

# Called by the player's Interaction every frame: the cell under the mouse (when it can be worked), or none.
func set_hover(cell: Vector2i, on: bool) -> void:
	if on == hover_on and cell == hover_cell:
		if on and _hover_text != text(cell):
			_hover.queue_redraw()
		return
	hover_on = on
	hover_cell = cell
	_hover.queue_redraw()

var _hover_text: String = ""

class PlotHover extends Node2D:
	var manager: Node2D
	func _ready() -> void:
		z_index = 100
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	func _draw() -> void:
		if manager == null or not manager.hover_on:
			return
		var rect: Rect2 = manager.cell_rect(manager.hover_cell)
		var c := Color(1, 1, 1, 0.9)
		var x: float = rect.position.x
		var y: float = rect.position.y
		var w: float = rect.size.x
		var h: float = rect.size.y
		# One pixel wide, inside the cell.
		draw_rect(Rect2(x, y, w, 1), c)
		draw_rect(Rect2(x, y + h - 1, w, 1), c)
		draw_rect(Rect2(x, y + 1, 1, h - 2), c)
		draw_rect(Rect2(x + w - 1, y + 1, 1, h - 2), c)
		manager._hover_text = manager.text(manager.hover_cell)
	# The text of the plot under the mouse is the UI's (crisp, in screen space), asked for every frame.
	func _process(_delta: float) -> void:
		if manager == null or not manager.hover_on:
			return
		var label: String = manager.text(manager.hover_cell)
		if label != "":
			var rect: Rect2 = manager.cell_rect(manager.hover_cell)
			Ui.world_text("plot_hover", get_viewport(), Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y - 1.0), label, "small")
