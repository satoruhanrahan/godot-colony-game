extends RefCounted

# Where things may lie on the ground, in ONE place: every drop and every spawn of an item (the player's Q, a swap, a
# harvest, branches from a tree, a tool put down, a seed bag, bread beside the fire, planks from the saw ...) asks
# find_free_ground_near(), so two items never pile on the same spot.
#
#  - PICKUP SHAPES: each item's shape is its sprite's opaque bounds (the picture without its empty canvas), at least 12 x 12
#    px (a 6 px radius). pickup_rect() is what the mouse hits, pickup_radius() what keeps neighbours apart.
#  - find_free_ground_near(): a deterministic outward search (the wanted spot, then rings of growing radius, the same
#    order every time) for ground that is inside the map, off the water, clear of solids and buildings, off tilled plots
#    when the item is large, and clear of the pickup shapes of every other item.

const WaterMap = preload("res://scripts/water_map.gd")

# Everything that lies on the ground as an item (nothing is dropped or built on top of another).
const ITEM_GROUPS: Array[String] = ["plank_piles", "saw_blades", "hammers", "shovels", "axes", "bundle_piles", "beds", "baskets", "ground_items", "dough_boards", "toolboxes"]
const MIN_RADIUS: float = 6.0
const MAP: Rect2 = Rect2(0, 0, 640, 640)

static var _used: Dictionary = {}

# The opaque part of a texture, in its pixels (cached).
static func used_rect(texture: Texture2D) -> Rect2i:
	var id: int = texture.get_instance_id()
	if not _used.has(id):
		var rect: Rect2i = texture.get_image().get_used_rect()
		if rect.size.x <= 0 or rect.size.y <= 0:
			rect = Rect2i(Vector2i.ZERO, Vector2i(texture.get_size()))
		_used[id] = rect
	return _used[id]

# The picture of an item node (the node itself, or its child "Sprite").
static func sprite_of(node: Node) -> Node2D:
	if node is Sprite2D:
		return node
	var child: Node = node.get_node_or_null("Sprite")
	if child is Sprite2D or child is AnimatedSprite2D:
		return child
	for c in node.get_children():
		if c is Sprite2D:
			return c
	return null

# The opaque bounds of an item in the world (at least 12 x 12 px, centred on the picture).
static func pickup_rect(node: Node2D) -> Rect2:
	var sprite: Node2D = sprite_of(node)
	var texture: Texture2D = null
	if sprite is Sprite2D:
		texture = sprite.texture
	elif sprite is AnimatedSprite2D and sprite.sprite_frames != null:
		texture = sprite.sprite_frames.get_frame_texture(sprite.animation, 0)
	if texture == null:
		return Rect2(node.global_position + Vector2(-6, -12), Vector2(12, 12))
	var used: Rect2i = used_rect(texture)
	var size: Vector2 = texture.get_size()
	var centered: bool = sprite.centered if "centered" in sprite else true
	var origin: Vector2 = sprite.global_position + sprite.offset * sprite.global_scale
	# the top-left of the texture in the world
	var top_left: Vector2 = origin - (size * 0.5 if centered else Vector2.ZERO) * sprite.global_scale
	var rect := Rect2(top_left + Vector2(used.position) * sprite.global_scale, Vector2(used.size) * sprite.global_scale)
	var grown: Vector2 = Vector2(maxf(rect.size.x, MIN_RADIUS * 2.0), maxf(rect.size.y, MIN_RADIUS * 2.0))
	return Rect2(rect.get_center() - grown * 0.5, grown)

static func pickup_center(node: Node2D) -> Vector2:
	return pickup_rect(node).get_center()

# The radius that keeps two items apart (at least 6 px).
static func pickup_radius(node: Node2D) -> float:
	var rect: Rect2 = pickup_rect(node)
	return maxf(MIN_RADIUS, maxf(rect.size.x, rect.size.y) * 0.5 * 0.85)

static func is_item(node: Node) -> bool:
	for group in ITEM_GROUPS:
		if node.is_in_group(group):
			return true
	return false

# Is this ground point free for an item of `size` (its footprint on the ground, px) to lie on?
static func is_free(tree: SceneTree, point: Vector2, size: Vector2, map_rect: Rect2 = MAP, ignore: Node = null) -> bool:
	var p: Vector2 = point.round()
	var inset: Rect2 = Rect2(map_rect.position + Vector2(4, 8), map_rect.size - Vector2(8, 8))
	if not inset.has_point(p):
		return false
	var feet := Rect2(p - Vector2(maxf(size.x, 8.0) * 0.5, 3), Vector2(maxf(size.x, 8.0), 4))
	if WaterMap.rect_has_water(feet.grow(1.0)):
		return false
	if Footprints.rect_blocked(tree, feet):
		return false
	for r in Footprints.base_rects(tree):
		if r.grow(2.0).has_point(p):
			return false
	# a large item is not put on tilled ground
	if size.x >= 14.0:
		var plots: Node = tree.get_first_node_in_group("plot_manager")
		if plots != null and plots.has_method("plot_at") and plots.plot_at(p):
			return false
	var radius: float = maxf(MIN_RADIUS, maxf(size.x, size.y) * 0.5 * 0.85)
	var centre: Vector2 = p + Vector2(0, -size.y * 0.5)
	for group in ITEM_GROUPS:
		for item in tree.get_nodes_in_group(group):
			if item == ignore or not item is Node2D or item.is_queued_for_deletion():
				continue
			if item.global_position.distance_to(p) > 60.0:
				continue
			if pickup_center(item).distance_to(centre) < radius + pickup_radius(item):
				return false
	return true

# The spot an item asked for, moved to the nearest free ground when it is out in the world (inside the map and `parent` is in
# the tree); in a room (off the map) it stays where it was asked for.
static func clear_spot(parent: Node, spot: Vector2, size: Vector2 = Vector2(12, 10)) -> Vector2:
	if not MAP.has_point(spot) or not parent.is_inside_tree():
		return spot
	var free: Vector2 = find_free_ground_near(parent.get_tree(), spot, size)
	return spot if free == Vector2.INF else free

# The nearest free ground to `near` for an item of `size`: the spot itself, else an outward search (the same ring order every
# time, 4 px apart) up to `max_radius` px. Returns Vector2.INF when there is none.
static func find_free_ground_near(tree: SceneTree, near: Vector2, size: Vector2 = Vector2(12, 10), map_rect: Rect2 = MAP, max_radius: float = 96.0, ignore: Node = null) -> Vector2:
	var start: Vector2 = near.round()
	if is_free(tree, start, size, map_rect, ignore):
		return start
	var step: float = 4.0
	var ring: int = 1
	while ring * step <= max_radius:
		var radius: float = ring * step
		var count: int = maxi(8, int(ceilf(TAU * radius / 5.0)))
		for k in count:
			var angle: float = TAU * float(k) / float(count) + (PI / float(count) if ring % 2 == 0 else 0.0)
			var p: Vector2 = (start + Vector2.from_angle(angle) * radius).round()
			if is_free(tree, p, size, map_rect, ignore):
				return p
		ring += 1
	return Vector2.INF
