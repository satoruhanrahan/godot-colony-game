class_name Footprints
extends RefCounted

const WaterMap = preload("res://scripts/water_map.gd")

# Shared "what is in the way" helpers for build mode and the colonists.
#  - footprint rects: the whole ground area a thing covers (what you can't build or
#    stand a wander target on);
#  - base rects: just the collision shapes at the bottom of things (what you really
#    walk around, so characters can still pass behind the top of a building or tree).

# The ground a Sawmill / Storage / Cabin sprite covers, or a Building's footprint.
static func blocker_rect(node: Node2D) -> Rect2:
	if node.has_method("footprint_rect"):
		return node.footprint_rect()
	var size := Vector2.ZERO
	if node is AnimatedSprite2D:
		size = node.sprite_frames.get_frame_texture(node.animation, 0).get_size()
	elif node is Sprite2D:
		size = node.texture.get_size()
	return Rect2(node.global_position + node.offset - size * 0.5, size)

# A tree's canopy and trunk above its origin; a felled one also lies out to the side.
static func tree_rect(tree: Node2D) -> Rect2:
	var p: Vector2 = tree.global_position
	var rect := Rect2(p.x - 16.0, p.y - 32.0, 32.0, 34.0)
	if not is_zero_approx(tree.rotation):
		rect = rect.merge(Rect2(p.x - 32.0, p.y - 16.0, 64.0, 18.0))
	return rect

# Does this ground rectangle overlap a building, the Sawmill, the Storage or a tree?
# (A tree whose Trunk has been hauled away is gone.)
static func rect_blocked(scene_tree: SceneTree, rect: Rect2) -> bool:
	# Any water (deep or shallow) blocks building, tilling and putting things down.
	if WaterMap.rect_has_water(rect):
		return true
	for node in scene_tree.get_nodes_in_group("build_blockers"):
		if rect.intersects(blocker_rect(node)):
			return true
	for tree in scene_tree.get_nodes_in_group("trees"):
		if tree.has_node("Trunk") and rect.intersects(tree_rect(tree)):
			return true
	return false

# World-space collision rectangles of everything solid (buildings, Sawmill, Storage,
# standing trees), for walking around.
static func base_rects(scene_tree: SceneTree) -> Array[Rect2]:
	var rects: Array[Rect2] = []
	var nodes: Array[Node] = []
	nodes.append_array(scene_tree.get_nodes_in_group("build_blockers"))
	nodes.append_array(scene_tree.get_nodes_in_group("trees"))
	for node in nodes:
		var shape_node: CollisionShape2D = node.get_node_or_null("Collision/Shape")
		if shape_node == null or shape_node.disabled or not shape_node.shape is RectangleShape2D:
			continue
		var size: Vector2 = shape_node.shape.size
		rects.append(Rect2(shape_node.global_position - size * 0.5, size))
	return rects

# Does the straight segment a->b pass through the inside of the rectangle?
static func segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var d: Vector2 = b - a
	var t0: float = 0.0
	var t1: float = 1.0
	for axis in 2:
		var lo: float = r.position[axis]
		var hi: float = r.end[axis]
		if absf(d[axis]) < 0.0001:
			if a[axis] <= lo or a[axis] >= hi:
				return false
		else:
			var ta: float = (lo - a[axis]) / d[axis]
			var tb: float = (hi - a[axis]) / d[axis]
			t0 = maxf(t0, minf(ta, tb))
			t1 = minf(t1, maxf(ta, tb))
			if t0 >= t1:
				return false
	return true

# Waypoints (not including `from`, ending at `to`) that walk round the obstacle rects by
# their corners instead of straight through them. Obstacles that already contain the
# start or end point are ignored, so standing right beside a wall never traps anyone.
# The result is bounded (a worst case just walks the straight line on).
static func path_around(obstacles: Array[Rect2], from: Vector2, to: Vector2, margin: float) -> Array[Vector2]:
	# Where the straight walk would enter deep water, the route goes through the water grid first (so across a ford)
	# and each leg of it is then routed round the obstacles as usual.
	if not WaterMap.active or WaterMap.line_clear(from, to, 4.0):
		return _path_around_plain(obstacles, from, to, margin)
	var out: Array[Vector2] = []
	var cur: Vector2 = from
	for waypoint in WaterMap.route(from, to):
		out.append_array(_path_around_plain(obstacles, cur, waypoint, margin))
		cur = waypoint
	return out

static func _path_around_plain(obstacles: Array[Rect2], from: Vector2, to: Vector2, margin: float) -> Array[Vector2]:
	var grown: Array[Rect2] = []
	for r in obstacles:
		if r.has_point(from) or r.has_point(to):
			continue
		var g: Rect2 = r.grow(margin)
		# Starting or ending inside the clearance band (e.g. at a door): keep the plain
		# rectangle for this one, or no way out of the band would ever be found.
		if g.has_point(from) or g.has_point(to):
			g = r
		grown.append(g)
	var pts: Array[Vector2] = [from, to]
	var i: int = 0
	var guard: int = 0
	while i < pts.size() - 1 and guard < 32:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var hit: int = -1
		for k in grown.size():
			# (Tested a hair inside, so running along a clearance edge is not a hit.)
			if segment_hits_rect(a, b, grown[k].grow(-0.05)):
				hit = k
				break
		if hit == -1:
			i += 1
			continue
		var r: Rect2 = grown[hit]
		var best := Vector2.ZERO
		var best_len: float = INF
		for corner in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
			# Only corners he can reach from here without crossing this rectangle.
			# (A hair inside the rectangle, so a path just touching it at the corner counts.)
			if a.distance_to(corner) < 0.01 or segment_hits_rect(a, corner, r.grow(-0.05)):
				continue
			var inside_other: bool = false
			for k in grown.size():
				if k != hit and grown[k].grow(-0.5).has_point(corner):
					inside_other = true
					break
			var len: float = a.distance_to(corner) + corner.distance_to(b) + (1000.0 if inside_other else 0.0)
			if len < best_len:
				best_len = len
				best = corner
		if best_len == INF:
			i += 1
			continue
		pts.insert(i + 1, best)
		guard += 1
	pts.remove_at(0)
	return pts
