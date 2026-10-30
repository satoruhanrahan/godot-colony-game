extends TileMapLayer

# Fills the ground with a weighted random mix of the four tiles in ground_tiles.png.
# The mix is driven by a fixed seed, so the layout is identical on every run; change
# layout_seed for a different (but still repeatable) layout.
@export var layout_seed: int = 20260
# Relative weights for atlas tiles 0..3. Tiles 0 and 1 are the plain grass; tiles 2
# (dark tuft) and 3 (flowers) carry extra detail.
# Raw odds for tiles 0..3. Detailed tiles that would touch another detailed tile are
# re-rolled as plain, so the final detailed share ends up lower than these odds
# suggest (about 22%, leaving about 78% plain).
@export var variant_weights: Array[float] = [36.0, 36.0, 90.0, 60.0]
# Index of the first detailed variant.
@export var first_detail_variant: int = 2
# Never place a detailed tile next to another detailed tile (sides or diagonals).
@export var avoid_adjacent_details: bool = true

func _ready() -> void:
	_fill()

func _pick(rng: RandomNumberGenerator, from_index: int, to_index: int) -> int:
	var total: float = 0.0
	for i in range(from_index, to_index):
		total += variant_weights[i]
	var roll: float = rng.randf() * total
	for i in range(from_index, to_index):
		roll -= variant_weights[i]
		if roll < 0.0:
			return i
	return to_index - 1

func _is_detail(cell: Vector2i) -> bool:
	return get_cell_source_id(cell) != -1 and get_cell_atlas_coords(cell).x >= first_detail_variant

func _fill() -> void:
	# Cover exactly the cells the scene already paints, in a fixed row-by-row order
	# so the same seed always gives the same result.
	var cells: Array[Vector2i] = get_used_cells()
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	var rng := RandomNumberGenerator.new()
	rng.seed = layout_seed
	var count: int = variant_weights.size()
	for cell in cells:
		var v: int = _pick(rng, 0, count)
		if avoid_adjacent_details and v >= first_detail_variant:
			# Neighbours already placed this pass: left, and the three above.
			var touching: bool = false
			for offset in [Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]:
				if _is_detail(cell + offset):
					touching = true
					break
			if touching:
				v = _pick(rng, 0, first_detail_variant)
		set_cell(cell, 0, Vector2i(v, 0))
