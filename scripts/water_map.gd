extends RefCounted

# The water of the world, as DATA: one static map of the 20x20 tiles (32 px) saying what each tile is, plus the
# queries everything uses (is_water, is_shallow, nearest_water, speed_factor ...) and the water-aware routing the
# colonists, the workers and the player's click-to-walk share. The pictures and the collision are made from it by
# WaterLayer. Thirst (later) should use the same queries.
#
# The world has ONE small creek: about 2 tiles wide (3 at most), meandering from one map edge to another, all of it
# SHALLOW water you can walk through (slowed to creek_speed_multiplier, with a soft splash). Nothing is built, tilled,
# sown or put down on water (Footprints.rect_blocked says a rectangle touching ANY water is blocked); the bucket fills
# from it.
#  - DEEP is kept as an optional, UNUSED tile type: nothing generates it, but if a map ever holds deep tiles they block
#    everybody (a collision body for the player, routing for everyone else) and water_deep.png is drawn for them.
#  - Routing (only does anything when there is deep water): an A* grid of 16 px cells where deep water is solid.
# All the numbers come from the FoodConfig "Water" group. Cells here are TILE cells (Vector2i of tile x, y).

const FoodConfig = preload("res://scripts/food_config.gd")
const FootstepSounds = preload("res://scripts/footstep_sounds.gd")

const TILE: int = 32
const COLS: int = 20
const ROWS: int = 20
const SUB: int = 16

const LAND: int = 0
const SHALLOW: int = 1
const DEEP: int = 2

static var tiles: PackedByteArray = PackedByteArray()
static var active: bool = false
static var has_deep: bool = false
static var _astar: AStarGrid2D = null
# Every tile of the creek (all shallow), and how the map was found (for the report).
static var creek_tiles: Array[Vector2i] = []
static var creek_report: String = ""

# --- Making the map ---------------------------------------------------------------------------------------------

# A winding creek from the bottom edge to the right edge, far from the cabin (creek_cabin_min_tiles to
# creek_cabin_max_tiles). Several layouts are tried, in a fixed order from creek_seed (0 = a random start), and the
# first that suits wins, so the map is the same every run.
static func generate(cabin: Vector2 = Vector2(160, 73)) -> void:
	var cfg: Resource = FoodConfig.cfg()
	var base_seed: int = cfg.creek_seed if cfg.creek_seed != 0 else randi()
	var found: PackedByteArray = PackedByteArray()
	var used: int = -1
	var why: String = ""
	for attempt in 600:
		var candidate: PackedByteArray = _carve(cfg, base_seed + attempt)
		why = _check(candidate, cabin, cfg)
		if why == "":
			found = candidate
			used = attempt
			break
	if found.is_empty():
		# (Never expected: keep the last layout rather than no creek.)
		found = _carve(cfg, base_seed)
		creek_report = "no layout met the rules (%s)" % why
	else:
		creek_report = "layout %d of seed %d" % [used, base_seed]
	tiles = found
	creek_tiles.clear()
	has_deep = false
	for y in ROWS:
		for x in COLS:
			var k: int = tiles[y * COLS + x]
			if k != LAND:
				creek_tiles.append(Vector2i(x, y))
			if k == DEEP:
				has_deep = true
	active = true
	_astar = null
	if has_deep:
		_build_astar()

# One candidate layout: a centre line from the bottom edge to the right edge with sideways wobble, and every tile
# whose centre is within the creek's radius of it is water (radius 1 = 2 tiles wide, a little more now and then).
static func _carve(cfg: Resource, seed_value: int) -> PackedByteArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out := PackedByteArray()
	out.resize(COLS * ROWS)
	out.fill(LAND)
	var start := Vector2(rng.randf_range(5.0, 12.0), ROWS + 1.0)
	var end := Vector2(COLS + 1.0, rng.randf_range(5.0, 12.0))
	var along: Vector2 = end - start
	var side: Vector2 = Vector2(-along.y, along.x).normalized()
	var waves: float = rng.randf_range(1.6, 2.6)
	var ph1: float = rng.randf_range(0.0, TAU)
	var ph2: float = rng.randf_range(0.0, TAU)
	var ph3: float = rng.randf_range(0.0, TAU)
	var r_min: float = cfg.creek_width_tiles * 0.5
	var r_max: float = maxf(r_min, cfg.creek_max_width_tiles * 0.5 - 0.1)
	var samples: int = 90
	var pts: Array[Vector2] = []
	var radii: Array[float] = []
	for i in samples + 1:
		var t: float = float(i) / samples
		var wobble: float = (sin(TAU * waves * t + ph1) * 0.7 + sin(TAU * waves * 2.3 * t + ph2) * 0.3) * cfg.creek_meander_tiles
		pts.append(start + along * t + side * wobble)
		# a slowly changing width between the narrow and the wide value
		radii.append(r_min + (r_max - r_min) * clampf(0.5 + 0.9 * sin(TAU * 1.7 * t + ph3), 0.0, 1.0))
	for y in ROWS:
		for x in COLS:
			var centre := Vector2(x + 0.5, y + 0.5)
			for i in pts.size():
				if centre.distance_to(pts[i]) <= radii[i]:
					out[y * COLS + x] = SHALLOW
					break
	return out

# "" when the layout is good: one connected piece, edge to edge (bottom and right), every tile between
# creek_cabin_min_tiles and creek_cabin_max_tiles from the cabin, a sensible size.
static func _check(map: PackedByteArray, cabin: Vector2, cfg: Resource) -> String:
	var list: Array[Vector2i] = []
	for y in ROWS:
		for x in COLS:
			if map[y * COLS + x] != LAND:
				list.append(Vector2i(x, y))
	if list.size() < 28 or list.size() > 90:
		return "%d tiles" % list.size()
	var bottom: bool = false
	var right: bool = false
	var near: float = INF
	var far: float = 0.0
	for c in list:
		bottom = bottom or c.y == ROWS - 1
		right = right or c.x == COLS - 1
		var d: float = (Vector2(c.x + 0.5, c.y + 0.5) * TILE).distance_to(cabin) / TILE
		near = minf(near, d)
		far = maxf(far, d)
	if not bottom or not right:
		return "does not reach both edges"
	if near < cfg.creek_cabin_min_tiles or far > cfg.creek_cabin_max_tiles:
		return "%.1f to %.1f tiles from the cabin" % [near, far]
	# one connected piece
	var seen: Dictionary = {list[0]: true}
	var queue: Array[Vector2i] = [list[0]]
	var head: int = 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if n.x >= 0 and n.y >= 0 and n.x < COLS and n.y < ROWS and map[n.y * COLS + n.x] != LAND and not seen.has(n):
				seen[n] = true
				queue.append(n)
	if seen.size() != list.size():
		return "not one piece"
	return ""

static func clear() -> void:
	tiles = PackedByteArray()
	active = false
	_astar = null

static func _build_astar() -> void:
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(0, 0, COLS * TILE / SUB, ROWS * TILE / SUB)
	_astar.cell_size = Vector2(SUB, SUB)
	_astar.offset = Vector2(SUB * 0.5, SUB * 0.5)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()
	for sy in ROWS * TILE / SUB:
		for sx in COLS * TILE / SUB:
			if kind_at_tile(Vector2i(sx * SUB / TILE, sy * SUB / TILE)) == DEEP:
				_astar.set_point_solid(Vector2i(sx, sy), true)

# --- Queries (the reusable ones: thirst can use them later) ------------------------------------------------------

static func tile_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / TILE), floori(pos.y / TILE))

static func tile_rect(cell: Vector2i) -> Rect2:
	return Rect2(cell.x * TILE, cell.y * TILE, TILE, TILE)

static func kind_at_tile(cell: Vector2i) -> int:
	if not active or cell.x < 0 or cell.y < 0 or cell.x >= COLS or cell.y >= ROWS:
		return LAND
	return tiles[cell.y * COLS + cell.x]

# Any water (deep or shallow).
static func is_water(cell: Vector2i) -> bool:
	return kind_at_tile(cell) != LAND

static func is_shallow(cell: Vector2i) -> bool:
	return kind_at_tile(cell) == SHALLOW

static func is_deep(cell: Vector2i) -> bool:
	return kind_at_tile(cell) == DEEP

static func deep_at(pos: Vector2) -> bool:
	return kind_at_tile(tile_of(pos)) == DEEP

static func shallow_at(pos: Vector2) -> bool:
	return kind_at_tile(tile_of(pos)) == SHALLOW

# The nearest water tile to a point (by the distance to the tile's rectangle), as a tile cell; Vector2i(-9999, -9999)
# when there is none. `only_shallow` restricts it to the walkable water.
static func nearest_water(pos: Vector2, only_shallow: bool = false) -> Vector2i:
	var best: Vector2i = Vector2i(-9999, -9999)
	var best_d: float = INF
	if not active:
		return best
	for y in ROWS:
		for x in COLS:
			var cell := Vector2i(x, y)
			var kind: int = kind_at_tile(cell)
			if kind == LAND or (only_shallow and kind != SHALLOW):
				continue
			var d: float = distance_to_tile(pos, cell)
			if d < best_d:
				best_d = d
				best = cell
	return best

# The distance from a point to the closest point of a tile's rectangle (0 inside it).
static func distance_to_tile(pos: Vector2, cell: Vector2i) -> float:
	return closest_point_in_tile(pos, cell).distance_to(pos)

static func closest_point_in_tile(pos: Vector2, cell: Vector2i) -> Vector2:
	var r: Rect2 = tile_rect(cell)
	return Vector2(clampf(pos.x, r.position.x, r.end.x), clampf(pos.y, r.position.y, r.end.y))

# How much shallow water slows whoever stands at this point (1 on land).
static func speed_factor(pos: Vector2) -> float:
	if active and shallow_at(pos):
		return FoodConfig.cfg().creek_speed_multiplier
	return 1.0

# Does this ground rectangle touch any water (so nothing is built, tilled or put down on it)?
static func rect_has_water(rect: Rect2) -> bool:
	if not active:
		return false
	var a: Vector2i = tile_of(rect.position)
	var b: Vector2i = tile_of(rect.end - Vector2(0.001, 0.001))
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			if kind_at_tile(Vector2i(x, y)) != LAND:
				return true
	return false

static func rect_has_deep(rect: Rect2) -> bool:
	if not active:
		return false
	var a: Vector2i = tile_of(rect.position)
	var b: Vector2i = tile_of(rect.end - Vector2(0.001, 0.001))
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			if kind_at_tile(Vector2i(x, y)) == DEEP:
				return true
	return false

# --- Routing -----------------------------------------------------------------------------------------------------

# Is the straight line a -> b clear of deep water (with `margin` px of room on both sides)?
static func line_clear(a: Vector2, b: Vector2, margin: float = 4.0) -> bool:
	if not active:
		return true
	var d: Vector2 = b - a
	var length: float = d.length()
	if length < 0.01:
		return not deep_at(a)
	var dir: Vector2 = d / length
	var side: Vector2 = Vector2(-dir.y, dir.x) * margin
	var steps: int = int(ceilf(length / 4.0))
	for i in steps + 1:
		var p: Vector2 = a + dir * minf(length, i * 4.0)
		if deep_at(p) or deep_at(p + side) or deep_at(p - side):
			return false
	return true

static func _sub_of(pos: Vector2) -> Vector2i:
	return Vector2i(clampi(floori(pos.x / SUB), 0, COLS * TILE / SUB - 1), clampi(floori(pos.y / SUB), 0, ROWS * TILE / SUB - 1))

static func _sub_centre(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * SUB + SUB * 0.5, cell.y * SUB + SUB * 0.5)

# The nearest cell that is not deep water (the cell itself when it is not).
static func _nearest_free_sub(cell: Vector2i) -> Vector2i:
	if not _astar.is_point_solid(cell):
		return cell
	for ring in range(1, 12):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dy)) != ring:
					continue
				var c := Vector2i(cell.x + dx, cell.y + dy)
				if _astar.region.has_point(c) and not _astar.is_point_solid(c):
					return c
	return cell

# The waypoints (ending at `to`, or at the nearest dry spot if `to` is in deep water) of a walk that keeps out of
# deep water: straight when that is clear, else through the A* grid (so across a ford), pulled straight where it can be.
static func route(from: Vector2, to: Vector2) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if not active or _astar == null:
		out.append(to)
		return out
	if line_clear(from, to, 4.0):
		out.append(to)
		return out
	var a: Vector2i = _nearest_free_sub(_sub_of(from))
	var goal_cell: Vector2i = _nearest_free_sub(_sub_of(to))
	var ids: Array[Vector2i] = _astar.get_id_path(a, goal_cell)
	if ids.size() < 2:
		out.append(_sub_centre(goal_cell) if deep_at(to) else to)
		return out
	var points: Array[Vector2] = []
	for i in range(1, ids.size()):
		points.append(_sub_centre(ids[i]))
	# The end: the target itself unless it is in deep water.
	var end: Vector2 = to if not deep_at(to) else _sub_centre(goal_cell)
	points[points.size() - 1] = end if line_clear(points[maxi(0, points.size() - 2)], end, 3.0) else points[points.size() - 1]
	# Pull the route straight: from each point, go to the farthest later point it has a clear line to.
	var cur: Vector2 = from
	var i: int = 0
	while i < points.size():
		var far: int = i
		for j in range(points.size() - 1, i - 1, -1):
			if line_clear(cur, points[j], 4.0):
				far = j
				break
		out.append(points[far])
		cur = points[far]
		i = far + 1
	if out.is_empty() or out[out.size() - 1] != end:
		if line_clear(cur, end, 3.0):
			out.append(end)
	return out

# --- Reachability (for the self-check) ---------------------------------------------------------------------------

# Every 16 px cell a walker can reach from `start` without entering deep water or one of `obstacles` (rectangles),
# as a Dictionary keyed by cell.
static func flood(start: Vector2, obstacles: Array[Rect2]) -> Dictionary:
	var seen: Dictionary = {}
	var queue: Array[Vector2i] = [_sub_of(start)]
	seen[queue[0]] = true
	var head: int = 0
	var cols: int = COLS * TILE / SUB
	var rows: int = ROWS * TILE / SUB
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if n.x < 0 or n.y < 0 or n.x >= cols or n.y >= rows or seen.has(n):
				continue
			var centre: Vector2 = _sub_centre(n)
			if deep_at(centre):
				continue
			var blocked: bool = false
			for r in obstacles:
				if r.has_point(centre):
					blocked = true
					break
			if blocked:
				continue
			seen[n] = true
			queue.append(n)
	return seen

static func flood_reaches(seen: Dictionary, point: Vector2, slack: int = 2) -> bool:
	var c: Vector2i = _sub_of(point)
	for dy in range(-slack, slack + 1):
		for dx in range(-slack, slack + 1):
			if seen.has(Vector2i(c.x + dx, c.y + dy)):
				return true
	return false

# --- Splashing -----------------------------------------------------------------------------------------------------

# Called after someone moves: in shallow water a splash every 12 px of walking.
static func walked(who: Node2D, step: float) -> void:
	# (Every walker reports its step here: the footsteps follow the distance walked.)
	FootstepSounds.walked(who, step)
	if not active or step <= 0.0 or not shallow_at(who.global_position):
		return
	var dist: float = float(who.get_meta(&"splash_dist", 0.0)) + step
	if dist >= 12.0:
		dist = 0.0
		AudioManager.play("splash", who.global_position, randf_range(0.92, 1.08), -8.0)
	who.set_meta(&"splash_dist", dist)
