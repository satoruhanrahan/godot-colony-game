extends RefCounted

# Which shore pictures a water tile gets, and how they are turned, in ONE place (the real map, the debug test patch
# res://debug/shore_test.tscn and the self-check all use it).
#
# THE CONVENTION. A shore piece is drawn ON A WATER TILE (it is a water tile with the sand drawn in), and the sand is the
# land. A tile of the map is "land" or "water"; a water tile sees its 4 edge neighbours and its 4 diagonal neighbours:
#   - 1 land edge neighbour            -> shore_edge      (a straight shore)
#   - 2 land edges that meet at a corner -> shore_corner_in  (an INNER corner: water bulges into the land)
#   - no land edge, 1 land diagonal    -> shore_corner_out (an OUTER corner: land bulges out into the water)
#   - anything else (a one-tile inlet or pond, a one-tile channel, two outer corners on one tile ...) is put together
#     from a plain water tile plus strips of shore_edge and corner pieces of shore_corner_out, so land is always on the
#     land side.
#
# THE ARTIST'S PICTURES (32 x 32, as drawn, before any turning):
#   shore_edge.png        land (grass + sand) along the NORTH edge, water below.
#   shore_corner_in.png   land along the NORTH and the EAST edges, water in the south-west (the water has a rounded corner).
#   shore_corner_out.png  land in the NORTH-WEST corner only (a rounded blob of sand), water everywhere else.
# (The code used to assume that shore_corner_out has its land in the NORTH-EAST corner; that was the bug: every outer
# corner was drawn a quarter turn off, with the land corner out in the water.)
# If the art is redrawn the other way round, change CORNER_OUT_LAND_CORNER in the layer (an export), nothing else.

const WaterMap = preload("res://scripts/water_map.gd")

const TILE: int = 32
# The side a straight shore's land is on, in the unrotated picture (0 N, 1 E, 2 S, 3 W).
const EDGE_LAND_SIDE: int = 0
# The corner the two land edges of shore_corner_in meet in (0 NE, 1 SE, 2 SW, 3 NW).
const CORNER_IN_LAND_CORNER: int = 0
# How deep the sand band of shore_edge is (rows, from the land side), and the size of a corner piece cut from
# shore_corner_out.
const STRIP: int = 11
const QUAD: int = 12

# Directions by index. Sides: 0 N, 1 E, 2 S, 3 W. Corners: 0 NE, 1 SE, 2 SW, 3 NW (the same order as turning clockwise).
const SIDES: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const CORNERS: Array[Vector2i] = [Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1)]
const SIDE_NAMES: Array[String] = ["N", "E", "S", "W"]
const CORNER_NAMES: Array[String] = ["NE", "SE", "SW", "NW"]

# The pieces to draw on one water tile, in order. Each: {tex: &"water"|&"edge"|&"corner_in"|&"corner_out",
# rot: degrees clockwise, src: the part of the picture used (Rect2 in picture pixels), text: a description}.
# `kind_at` is a Callable(Vector2i) -> int (WaterMap.LAND / SHALLOW / DEEP); tiles outside the map are whatever it says.
# `out_land_corner` is the corner of shore_corner_out.png that holds the land (see above).
static func pieces(kind_at: Callable, cell: Vector2i, out_land_corner: int = 3) -> Array:
	var side: Array[bool] = []
	var diag: Array[bool] = []
	for i in 4:
		side.append(int(kind_at.call(cell + SIDES[i])) == WaterMap.LAND)
		diag.append(int(kind_at.call(cell + CORNERS[i])) == WaterMap.LAND)
	var sides: int = int(side[0]) + int(side[1]) + int(side[2]) + int(side[3])
	var diags: int = int(diag[0]) + int(diag[1]) + int(diag[2]) + int(diag[3])
	var full := Rect2(0, 0, TILE, TILE)
	var water := {"tex": &"water", "rot": 0, "src": full, "cells": [], "text": "water"}
	var out: Array = []
	var whole_outer: bool = false
	if sides == 1:
		var i: int = side.find(true)
		out.append({"tex": &"edge", "rot": posmod(i - EDGE_LAND_SIDE, 4) * 90, "src": full, "cells": [SIDES[i]], "text": "edge, land %s" % SIDE_NAMES[i]})
	elif sides == 2 and side[0] != side[2] and side[1] != side[3]:
		# two land edges that meet in a corner: the inner corner they make
		var corner: int = 0
		for i in 4:
			if side[i] and side[(i + 1) % 4]:
				corner = i
		out.append({"tex": &"corner_in", "rot": posmod(corner - CORNER_IN_LAND_CORNER, 4) * 90, "src": full, "cells": [SIDES[corner], SIDES[(corner + 1) % 4]], "text": "inner corner, land %s+%s" % [SIDE_NAMES[corner], SIDE_NAMES[(corner + 1) % 4]]})
	elif sides == 0 and diags == 1:
		var c: int = diag.find(true)
		out.append({"tex": &"corner_out", "rot": posmod(c - out_land_corner, 4) * 90, "src": full, "cells": [CORNERS[c]], "text": "outer corner, land %s" % CORNER_NAMES[c]})
		whole_outer = true
	elif sides >= 2:
		# a one-tile inlet or pond, a one-tile channel: plain water and a strip of shore for every land edge
		out.append(water)
		for i in 4:
			if side[i]:
				out.append({"tex": &"edge", "rot": posmod(i - EDGE_LAND_SIDE, 4) * 90, "src": _strip(), "cells": [SIDES[i]], "text": "strip, land %s" % SIDE_NAMES[i]})
	# an outer corner piece for every land diagonal whose two edges are water (unless the whole picture did it)
	if not whole_outer:
		for c in 4:
			if not diag[c] or side[c] or side[(c + 1) % 4]:
				continue
			if out.is_empty():
				out.append(water)
			out.append({"tex": &"corner_out", "rot": posmod(c - out_land_corner, 4) * 90, "src": _quad(out_land_corner), "cells": [CORNERS[c]], "text": "outer corner piece, land %s" % CORNER_NAMES[c]})
	return out

static func _strip() -> Rect2:
	return Rect2(0, 0, TILE, STRIP)

# The QUAD x QUAD square at one corner of the picture.
static func _quad(corner: int) -> Rect2:
	var far: int = TILE - QUAD
	match corner:
		0:
			return Rect2(far, 0, QUAD, QUAD)
		1:
			return Rect2(far, far, QUAD, QUAD)
		2:
			return Rect2(0, far, QUAD, QUAD)
	return Rect2(0, 0, QUAD, QUAD)

# Draws one piece (not a "water" piece) on `canvas` at the tile whose top-left is `origin`. `textures`: {edge, corner_in,
# corner_out} -> Texture2D (a missing one draws nothing).
static func draw_piece(canvas: CanvasItem, origin: Vector2, piece: Dictionary, textures: Dictionary) -> void:
	var tex: Texture2D = textures.get(piece["tex"])
	if tex == null:
		return
	var src: Rect2 = piece["src"]
	canvas.draw_set_transform(origin + Vector2(TILE * 0.5, TILE * 0.5), deg_to_rad(float(piece["rot"])), Vector2.ONE)
	canvas.draw_texture_rect_region(tex, Rect2(-TILE * 0.5 + src.position.x, -TILE * 0.5 + src.position.y, src.size.x, src.size.y), src)
	canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# --- Checking the orientation from the pictures themselves ------------------------------------------------------------

# Which way the land of a picture lies: the mean position of its land-coloured pixels (red above blue: sand, and grass is
# green over blue) from the picture's centre, as a Vector2 in picture pixels (y down). Region = the part used.
static func land_centroid(image: Image, region: Rect2) -> Vector2:
	var sum := Vector2.ZERO
	var count: int = 0
	for y in range(int(region.position.y), int(region.end.y)):
		for x in range(int(region.position.x), int(region.end.x)):
			var c: Color = image.get_pixel(x, y)
			if c.a < 0.5:
				continue
			var is_land: bool = c.r > c.b + 0.03
			if is_land:
				sum += Vector2(x + 0.5 - TILE * 0.5, y + 0.5 - TILE * 0.5)
				count += 1
	return sum / float(count) if count > 0 else Vector2.ZERO

# Where a piece's land really ends up in the tile after the piece is turned: its centroid rotated by the piece's rotation.
static func land_direction(image: Image, piece: Dictionary) -> Vector2:
	return land_centroid(image, piece["src"]).rotated(deg_to_rad(float(piece["rot"])))
