extends Node2D

# A THROWAWAY test patch (not wired to any key, not used by the game): every shore case drawn side by side with the same
# code as the real map (ShorePainter), so the shore corners can be checked by eye. Run this scene on its own.
#
# 14 cases: a straight shore with the land to the north / east / south / west, the four inner corners (water bulges into
# the land), the four outer corners (land bulges out into the water), a one-tile peninsula and a one-tile inlet. In each
# patch 'L' is land (green) and '~' is water; the land is always on the land side of the sand.

const ShorePainter = preload("res://scripts/shore_painter.gd")
const WaterMap = preload("res://scripts/water_map.gd")

const GAP: int = 16
const PATCH_COLUMNS: int = 4

const CASES: Array = [
	["straight, land N", ["LLLLL", "LLLLL", "~~~~~", "~~~~~", "~~~~~"]],
	["straight, land E", ["~~~LL", "~~~LL", "~~~LL", "~~~LL", "~~~LL"]],
	["straight, land S", ["~~~~~", "~~~~~", "~~~~~", "LLLLL", "LLLLL"]],
	["straight, land W", ["LL~~~", "LL~~~", "LL~~~", "LL~~~", "LL~~~"]],
	["inner corner, land N+E", ["LLLLL", "LLLLL", "~~~LL", "~~~LL", "~~~LL"]],
	["inner corner, land E+S", ["~~~LL", "~~~LL", "~~~LL", "LLLLL", "LLLLL"]],
	["inner corner, land S+W", ["LL~~~", "LL~~~", "LL~~~", "LLLLL", "LLLLL"]],
	["inner corner, land W+N", ["LLLLL", "LLLLL", "LL~~~", "LL~~~", "LL~~~"]],
	["outer corner, land NE", ["~~~LL", "~~~LL", "~~~~~", "~~~~~", "~~~~~"]],
	["outer corner, land SE", ["~~~~~", "~~~~~", "~~~~~", "~~~LL", "~~~LL"]],
	["outer corner, land SW", ["~~~~~", "~~~~~", "~~~~~", "LL~~~", "LL~~~"]],
	["outer corner, land NW", ["LL~~~", "LL~~~", "~~~~~", "~~~~~", "~~~~~"]],
	["one-tile peninsula", ["LLLLL", "~~L~~", "~~L~~", "~~~~~", "~~~~~"]],
	["one-tile inlet", ["LLLLL", "LLLLL", "LL~LL", "~~~~~", "~~~~~"]],
]

var _textures: Dictionary = {}
var _water: Texture2D
var _land: Color = Color(0.58, 0.80, 0.36)
var _out_corner: int = 3

# The kind of a cell in a patch (rows of 'L' and '~'); outside the patch counts as the nearest cell inside it, so the
# patch's edges carry on.
static func kind_func(rows: Array) -> Callable:
	return func(c: Vector2i) -> int:
		var y: int = clampi(c.y, 0, rows.size() - 1)
		var x: int = clampi(c.x, 0, rows[y].length() - 1)
		return WaterMap.LAND if rows[y][x] == "L" else WaterMap.SHALLOW

func _ready() -> void:
	# one screen pixel per world pixel, in a window big enough for every patch
	var window: Window = get_window()
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var span: int = PATCH_COLUMNS * (5 * 32 + GAP) + GAP
	window.size = Vector2i(span, span)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# (SHORE_OFFSET=x,y scrolls the patch, for screenshots in a small window)
	var offset: PackedStringArray = OS.get_environment("SHORE_OFFSET").split(",")
	if offset.size() == 2:
		position = -Vector2(float(offset[0]), float(offset[1]))
	_water = load("res://sprites/water_shallow.png")
	_textures = {&"edge": load("res://sprites/shore_edge.png"), &"corner_in": load("res://sprites/shore_corner_in.png"), &"corner_out": load("res://sprites/shore_corner_out.png")}
	var grass: Color = (_textures[&"edge"] as Texture2D).get_image().get_pixel(0, 0)
	_land = grass
	var layer: Node = get_tree().get_first_node_in_group("water_layer")
	if layer != null:
		_out_corner = layer.corner_out_land_corner
	for i in CASES.size():
		var label := Label.new()
		label.text = CASES[i][0]
		label.position = _origin(i) + Vector2(0, -12)
		label.add_theme_font_size_override("font_size", 9)
		add_child(label)
	queue_redraw()

func _origin(i: int) -> Vector2:
	return Vector2(GAP + (i % PATCH_COLUMNS) * (5 * 32 + GAP), GAP + 12 + (i / PATCH_COLUMNS) * (5 * 32 + GAP + 8))

func _draw() -> void:
	for i in CASES.size():
		var rows: Array = CASES[i][1]
		var kind: Callable = kind_func(rows)
		var origin: Vector2 = _origin(i)
		for y in 5:
			for x in 5:
				var at: Vector2 = origin + Vector2(x * 32, y * 32)
				var cell := Vector2i(x, y)
				if int(kind.call(cell)) == WaterMap.LAND:
					draw_rect(Rect2(at, Vector2(32, 32)), _land)
					continue
				var pieces: Array = ShorePainter.pieces(kind, cell, _out_corner)
				if pieces.is_empty() or pieces[0]["tex"] == &"water":
					draw_texture_rect(_water, Rect2(at, Vector2(32, 32)), false)
				for piece in pieces:
					if piece["tex"] != &"water":
						ShorePainter.draw_piece(self, at, piece, _textures)
