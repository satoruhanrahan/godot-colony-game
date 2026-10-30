extends Node2D

# The water you see and bump into, made from the WaterMap data:
#  - drawn tile by tile under everything that stands on the ground (z -2, above the grass): shallow water, with its own
#    picture (res://sprites/water_shallow.png; deep water, which the map does not use, has water_deep.png; each can have
#    a .json for a 2 to 4 frame animation: here, until real animation strips exist, a gentle 2-frame shimmer made in
#    code: the same picture and its mirror, swapped in a checkerboard every 0.7 s). Tiles on the shore get their shore
#    pieces from ShorePainter (shore_edge / shore_corner_in / shore_corner_out, turned so the land is on the land side;
#    a thin sandy line drawn in code if those pictures are missing);
#  - a StaticBody2D with a rectangle for each run of DEEP tiles (there are none now, so nothing blocks the creek);
#  - a quiet brook loop (water_loop.wav) that sits at the nearest water to the player and fades smoothly with the
#    distance to it: inaudible beyond brook_hearing_tiles (like all sounds it is muted with M);
#  - cell_center / cell_rect for the interaction code to target a water tile (to fill a bucket).

const WaterMap = preload("res://scripts/water_map.gd")
const ShorePainter = preload("res://scripts/shore_painter.gd")
const FoodConfig = preload("res://scripts/food_config.gd")

@export var shimmer_seconds: float = 0.7
@export var shore_color: Color = Color(0.86, 0.78, 0.55, 0.9)
@export var shore_width: int = 2
# The brook's loudness right at the water (its own level is -14 dBFS; the SFX bus is -3 dB on top).
@export var ambient_volume_db: float = -4.0
# The corner of shore_corner_out.png that holds the land, as drawn (0 NE, 1 SE, 2 SW, 3 NW). The artist's picture has
# its sand in the NORTH-WEST corner; if it is ever redrawn with the land in another corner, set this to match.
@export_range(0, 3) var corner_out_land_corner: int = 3

var _deep: Texture2D
var _shallow: Texture2D
var _shore_textures: Dictionary = {}
var _phase: int = 0
var _t: float = 0.0
var _loop: int = 0
# The pieces of every shore tile, found once (cell -> Array of pieces).
var _pieces: Dictionary = {}

func _ready() -> void:
	add_to_group("water_layer")
	z_index = -2
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_deep = _maybe("res://sprites/water_deep.png")
	_shallow = _maybe("res://sprites/water_shallow.png")
	_shore_textures = {&"edge": _maybe("res://sprites/shore_edge.png"), &"corner_in": _maybe("res://sprites/shore_corner_in.png"), &"corner_out": _maybe("res://sprites/shore_corner_out.png")}
	_find_pieces()
	if WaterMap.has_deep:
		_build_collision()
	queue_redraw()

func _maybe(path: String) -> Texture2D:
	return load(path) if ResourceLoader.exists(path) else null

func _exit_tree() -> void:
	if _loop != 0:
		AudioManager.stop_loop(_loop)
		_loop = 0

func cell_center(cell: Vector2i) -> Vector2:
	return WaterMap.tile_rect(cell).get_center()

func cell_rect(cell: Vector2i) -> Rect2:
	return WaterMap.tile_rect(cell)

# The shore pieces of every shallow tile. (A tile outside the map counts as water going on, not as land.)
func _find_pieces() -> void:
	_pieces.clear()
	var kind_at := func(c: Vector2i) -> int:
		if c.x < 0 or c.y < 0 or c.x >= WaterMap.COLS or c.y >= WaterMap.ROWS:
			return WaterMap.SHALLOW
		return WaterMap.kind_at_tile(c)
	for y in WaterMap.ROWS:
		for x in WaterMap.COLS:
			var cell := Vector2i(x, y)
			if WaterMap.kind_at_tile(cell) == WaterMap.SHALLOW:
				var list: Array = ShorePainter.pieces(kind_at, cell, corner_out_land_corner)
				if not list.is_empty():
					_pieces[cell] = list

# One rectangle for each run of deep tiles in a row (only if the map has any).
func _build_collision() -> void:
	var body := StaticBody2D.new()
	body.name = "WaterBody"
	add_child(body)
	for y in WaterMap.ROWS:
		var x: int = 0
		while x < WaterMap.COLS:
			if WaterMap.kind_at_tile(Vector2i(x, y)) != WaterMap.DEEP:
				x += 1
				continue
			var start: int = x
			while x < WaterMap.COLS and WaterMap.kind_at_tile(Vector2i(x, y)) == WaterMap.DEEP:
				x += 1
			var shape := RectangleShape2D.new()
			shape.size = Vector2((x - start) * WaterMap.TILE, WaterMap.TILE)
			var cs := CollisionShape2D.new()
			cs.shape = shape
			cs.position = Vector2(start * WaterMap.TILE + shape.size.x * 0.5, y * WaterMap.TILE + WaterMap.TILE * 0.5)
			body.add_child(cs)

func _process(delta: float) -> void:
	_t += delta
	var phase: int = int(_t / maxf(0.1, shimmer_seconds)) % 2
	if phase != _phase:
		_phase = phase
		queue_redraw()
	_ambient()

# The brook's gain (0 to 1) at this many pixels from the nearest water: a smooth fall to silence at brook_hearing_tiles.
static func brook_gain(distance_px: float) -> float:
	var reach: float = FoodConfig.cfg().brook_hearing_tiles * WaterMap.TILE
	return pow(clampf(1.0 - distance_px / reach, 0.0, 1.0), 2.0)

# The brook: placed at the water nearest the player, and its volume follows the distance to that water.
func _ambient() -> void:
	var player: Node2D = get_tree().get_first_node_in_group("player")
	if player == null:
		return
	var cell: Vector2i = WaterMap.nearest_water(player.global_position)
	if cell.x < -9000:
		return
	var at: Vector2 = WaterMap.closest_point_in_tile(player.global_position, cell)
	var gain: float = brook_gain(at.distance_to(player.global_position))
	var db: float = ambient_volume_db + linear_to_db(gain) if gain > 0.0005 else -80.0
	if _loop == 0:
		_loop = AudioManager.play_loop("water_loop", at, 1.0, db)
		var fresh = AudioManager._loops.get(_loop)
		if fresh != null:
			# (The fade is done here, by distance to the water, not by the player's own attenuation.)
			fresh.max_distance = 100000.0
	var stream_player = AudioManager._loops.get(_loop)
	if stream_player != null:
		stream_player.global_position = at
		stream_player.volume_db = db

func _draw() -> void:
	var s: int = WaterMap.TILE
	for y in WaterMap.ROWS:
		for x in WaterMap.COLS:
			var cell := Vector2i(x, y)
			var kind: int = WaterMap.kind_at_tile(cell)
			if kind == WaterMap.LAND:
				continue
			var tex: Texture2D = _deep if kind == WaterMap.DEEP else _shallow
			var rect := Rect2(x * s, y * s, s, s)
			if tex == null:
				draw_rect(rect, Color(0.2, 0.4, 0.75) if kind == WaterMap.DEEP else Color(0.4, 0.7, 0.85))
				continue
			var list: Array = _pieces.get(cell, []) if kind == WaterMap.SHALLOW else []
			if list.is_empty() or list[0]["tex"] == &"water":
				# The shimmer: the picture or its mirror, in a checkerboard that swaps every shimmer_seconds.
				var mirrored: bool = (x + y + _phase) % 2 == 1
				if mirrored:
					draw_set_transform(Vector2(x * s + s, y * s), 0.0, Vector2(-1, 1))
					draw_texture_rect(tex, Rect2(0, 0, s, s), false)
					draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
				else:
					draw_texture_rect(tex, rect, false)
			# A shallow tile on the shore gets its shore pieces.
			for piece in list:
				if piece["tex"] != &"water":
					ShorePainter.draw_piece(self, rect.position, piece, _shore_textures)
	# With no shore pictures: a thin sandy line on the land side of every edge between land and water.
	if _shore_textures[&"edge"] == null:
		for y in WaterMap.ROWS:
			for x in WaterMap.COLS:
				if WaterMap.kind_at_tile(Vector2i(x, y)) != WaterMap.LAND:
					continue
				var px: int = x * s
				var py: int = y * s
				if WaterMap.is_water(Vector2i(x - 1, y)):
					draw_rect(Rect2(px, py, shore_width, s), shore_color)
				if WaterMap.is_water(Vector2i(x + 1, y)):
					draw_rect(Rect2(px + s - shore_width, py, shore_width, s), shore_color)
				if WaterMap.is_water(Vector2i(x, y - 1)):
					draw_rect(Rect2(px, py, s, shore_width), shore_color)
				if WaterMap.is_water(Vector2i(x, y + 1)):
					draw_rect(Rect2(px, py + s - shore_width, s, shore_width), shore_color)
