extends RefCounted

# Where the trees of a new game stand: natural clumped placement instead of a regular grid.
#
# A few random GROVE CENTRES (the density map) each get a clump of trees thrown at random PIXEL positions around them
# (a Gaussian scatter, not grid cells); a few LONE trees go anywhere else, far from everything. Spacing is a blue-noise
# (Poisson-disk style) rule with a varying radius: never closer than tree_min_spacing_tiles, stretched a little by slow
# low-frequency noise in a grove so it is not even, and up to tree_max_spacing_tiles from the others for a lone tree
# (in 32 px tiles). That leaves groves, thinner patches, lone trees and open clearings. (With only a dozen trees on the
# 20 x 20 tile map the groves are 3 to 6 trees; a bigger trees_count_multiplier gives bigger groves.)
#
# Rules: no tree on water or on a shore tile (any tile touching water), none within tree_clear_radius_cabin of the cabin,
# none on the places that hold the opening's supplies and the workers' start, none outside the map's margin; a layout is
# rejected when the nearest tree to the cabin is not between tree_nearest_cabin_min_tiles and _max_tiles away. The same
# tree_seed gives the same trees every run (0 = a different layout every run): attempt k of a seed always gives the same
# result, and the first attempt that meets the rules is used.

const WaterMap = preload("res://scripts/water_map.gd")

const TILE: float = 32.0
const MAP: Rect2 = Rect2(0, 0, 640, 640)
# Trees keep this far in from the map's edge (their crowns reach about 30 px up from the foot).
const MARGIN_X: float = 20.0
const MARGIN_TOP: float = 44.0
const MARGIN_BOTTOM: float = 16.0

# `params`: count, seed, cabin (Vector2), clear_radius_tiles, min_spacing_tiles, max_spacing_tiles, nearest_min_tiles,
# nearest_max_tiles, keep_out: Array of [Vector2 centre, float radius_px].
# Returns {points: Array[Vector2], attempt: int, report: String}.
static func generate(params: Dictionary) -> Dictionary:
	var base_seed: int = int(params["seed"]) if int(params["seed"]) != 0 else randi()
	var best: Dictionary = {}
	for attempt in 80:
		var result: Dictionary = _attempt(params, base_seed + attempt * 7919)
		result["attempt"] = attempt
		result["seed"] = base_seed
		if result["points"].size() == int(params["count"]) and result["reason"] == "":
			return result
		if best.is_empty() or result["points"].size() > best["points"].size():
			best = result
	best["report"] = "no layout met every rule; using attempt with %d trees (%s)" % [best["points"].size(), best["reason"]]
	return best

static func _valid(p: Vector2, params: Dictionary) -> bool:
	if p.x < MARGIN_X or p.x > MAP.size.x - MARGIN_X or p.y < MARGIN_TOP or p.y > MAP.size.y - MARGIN_BOTTOM:
		return false
	var cabin: Vector2 = params["cabin"]
	if p.distance_to(cabin) < float(params["clear_radius_tiles"]) * TILE:
		return false
	for k in params["keep_out"]:
		if p.distance_to(k[0]) < float(k[1]):
			return false
	# not on water, not on a shore tile (any tile touching water) and its crown clear of the water as well
	var tile: Vector2i = WaterMap.tile_of(p)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if WaterMap.is_water(tile + Vector2i(dx, dy)):
				return false
	if WaterMap.rect_has_water(Rect2(p + Vector2(-14, -16), Vector2(28, 20))):
		return false
	return true

static func _attempt(params: Dictionary, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var count: int = int(params["count"])
	var min_r: float = float(params["min_spacing_tiles"]) * TILE
	var max_r: float = float(params["max_spacing_tiles"]) * TILE
	var cabin: Vector2 = params["cabin"]
	var near_px: float = float(params["nearest_min_tiles"]) * TILE
	# slow low-frequency noise: the local density (it stretches the spacing: tight in the thick of a grove, wider at its edge)
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.01
	# how many are lone, how many go into groves and how big the groves are
	var lone_count: int = int(round(count * 0.2))
	var grove_total: int = count - lone_count
	var grove_count: int = clampi(int(round(grove_total / 5.0)), 1, 5)
	var sizes: Array[int] = []
	for i in grove_count:
		sizes.append(grove_total / grove_count)
	for i in grove_total - (grove_total / grove_count) * grove_count:
		sizes[i] += 1
	for i in grove_count - 1:   # (a grove a little bigger, another a little smaller)
		if sizes[i + 1] > 2 and rng.randf() < 0.6:
			sizes[i] += 1
			sizes[i + 1] -= 1
	var placed: Array[Vector2] = []
	var radii: Array[float] = []
	var centres: Array[Vector2] = []
	for size in sizes:
		# a grove centre: valid ground, well away from the cabin and from the other groves
		var centre: Vector2 = Vector2.INF
		for guard in 600:
			var c := Vector2(rng.randf_range(40.0, 600.0), rng.randf_range(80.0, 610.0)).round()
			if not _valid(c, params) or c.distance_to(cabin) < near_px + 1.5 * TILE:
				continue
			var apart: bool = true
			for other in centres:
				apart = apart and c.distance_to(other) >= 7.0 * TILE
			if apart:
				centre = c
				break
		if centre == Vector2.INF:
			continue
		centres.append(centre)
		var spread: float = 28.0 + 6.0 * size
		var tries: int = 0
		var in_grove: int = 0
		while in_grove < size and tries < 3000:
			tries += 1
			var p: Vector2 = (centre + Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread))).round()
			if not _valid(p, params) or p.distance_to(cabin) < near_px:
				continue
			# tight in the thick of the grove (the noise stretches it a little), never closer than min_spacing_tiles
			var r: float = min_r * (1.0 + 0.9 * (noise.get_noise_2d(p.x, p.y) * 0.5 + 0.5))
			var ok: bool = true
			for i in placed.size():
				if p.distance_to(placed[i]) < maxf(r, radii[i]):
					ok = false
					break
			if ok:
				placed.append(p)
				radii.append(r)
				in_grove += 1
	# the lone trees: far from everything else (the spacing grows toward max_spacing_tiles and gives a little when crowded)
	var relax: float = 1.0
	var darts: int = 0
	var lone_placed: int = 0
	while placed.size() < count and darts < 20000:
		darts += 1
		if darts % 2500 == 0:
			relax *= 0.85
		var p := Vector2(rng.randf_range(MARGIN_X, MAP.size.x - MARGIN_X), rng.randf_range(MARGIN_TOP, MAP.size.y - MARGIN_BOTTOM)).round()
		if not _valid(p, params) or p.distance_to(cabin) < near_px:
			continue
		var r: float = lerpf(0.55, 1.0, noise.get_noise_2d(p.x, p.y) * 0.5 + 0.5) * max_r * relax
		var ok: bool = true
		for i in placed.size():
			if p.distance_to(placed[i]) < maxf(r * (0.6 if radii[i] < max_r * 0.5 else 1.0), radii[i]):
				ok = false
				break
		if ok:
			placed.append(p)
			radii.append(r)
			lone_placed += 1
	var reason: String = ""
	if placed.size() < count:
		reason = "only %d of %d trees fitted" % [placed.size(), count]
	else:
		var nearest: float = INF
		for p in placed:
			nearest = minf(nearest, p.distance_to(cabin))
		nearest /= TILE
		if nearest < float(params["nearest_min_tiles"]) or nearest > float(params["nearest_max_tiles"]):
			reason = "nearest tree %.1f tiles from the cabin" % nearest
	return {"points": placed, "reason": reason, "report": "%d groves %s + %d lone" % [centres.size(), str(sizes), lone_placed]}

# Nearest-neighbour distances (in tiles) of a set of points, sorted.
static func neighbour_distances(points: Array) -> Array[float]:
	var out: Array[float] = []
	for i in points.size():
		var best: float = INF
		for j in points.size():
			if i != j:
				best = minf(best, points[i].distance_to(points[j]))
		out.append(best / TILE)
	out.sort()
	return out
