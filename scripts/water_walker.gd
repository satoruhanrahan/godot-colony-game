extends RefCounted

# What the Lumberjack, the Hauler and the Builder (who walk in straight lines to their targets) use to keep out of deep
# water: next(position, target) is the point to head for now. When the straight line is clear it is the target; when
# it would enter deep water it is the next waypoint of a route through the water grid (across a ford), remembered until
# the target changes. Nothing else about their movement changes.

const WaterMap = preload("res://scripts/water_map.gd")

var _goal: Vector2 = Vector2.INF
var _path: Array[Vector2] = []

func next(pos: Vector2, target: Vector2) -> Vector2:
	if not WaterMap.active:
		return target
	if target != _goal:
		_goal = target
		_path = []
	while not _path.is_empty() and pos.distance_to(_path[0]) < 0.5:
		_path.pop_front()
	if _path.is_empty():
		if WaterMap.line_clear(pos, target, 4.0):
			return target
		_path = WaterMap.route(pos, target)
		if _path.is_empty():
			return target
	return _path[0]
