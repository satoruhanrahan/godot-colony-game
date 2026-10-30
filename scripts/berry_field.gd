extends Node

# Scatters berry bushes over the ground when the game starts (the same way the grass field scatters grass).
# Each bush keeps a minimum distance from the LandingPoint, every building and blocker, the trees, the grass
# patches and the other bushes; none is placed on a solid. They appear in the old automated start too.

const BUSH_SCENE: PackedScene = preload("res://scenes/BerryBush.tscn")

@export var bush_count: int = 10
@export var min_distance_from_landing: float = 60.0
@export var min_distance_from_buildings: float = 36.0
@export var min_distance_from_trees: float = 24.0
@export var min_distance_from_grass: float = 20.0
@export var min_spacing: float = 40.0
@export var map_rect: Rect2 = Rect2(0, 0, 640, 640)
# 0 = a different scatter each game.
@export var random_seed: int = 0
@export var only_in_opening_mode: bool = false

func _ready() -> void:
	# After the main scene has taken out what the opening removes, and the grass has been scattered.
	_spawn.call_deferred()

func _spawn() -> void:
	var root: Node = get_parent()
	if only_in_opening_mode and not root.opening_mode:
		return
	# (A frame later than the grass field, so the patches exist.)
	await get_tree().process_frame
	var landing: Node2D = root.get_node_or_null("LandingPoint")
	var rng := RandomNumberGenerator.new()
	if random_seed != 0:
		rng.seed = random_seed
	else:
		rng.randomize()
	var placed: Array[Vector2] = []
	var inside := Rect2(map_rect.position + Vector2(24, 40), map_rect.size - Vector2(48, 64))
	var attempts: int = 0
	while placed.size() < bush_count and attempts < bush_count * 100:
		attempts += 1
		var p := Vector2(rng.randf_range(inside.position.x, inside.end.x), rng.randf_range(inside.position.y, inside.end.y)).round()
		if landing != null and p.distance_to(landing.position) < min_distance_from_landing:
			continue
		if not _clear_of_things(p):
			continue
		var too_close: bool = false
		for q in placed:
			if q.distance_to(p) < min_spacing:
				too_close = true
				break
		if too_close:
			continue
		placed.append(p)
		var bush: Node2D = BUSH_SCENE.instantiate()
		bush.position = p
		root.add_child(bush)

func _clear_of_things(p: Vector2) -> bool:
	if Footprints.rect_blocked(get_tree(), Rect2(p - Vector2(12, 8), Vector2(24, 14))):
		return false
	for group in ["buildings", "build_blockers", "pit_saws"]:
		for node in get_tree().get_nodes_in_group(group):
			if node.global_position.distance_to(p) < min_distance_from_buildings:
				return false
	for tree in get_tree().get_nodes_in_group("trees"):
		if tree.global_position.distance_to(p) < min_distance_from_trees:
			return false
	for patch in get_tree().get_nodes_in_group("grass_patches"):
		if patch.global_position.distance_to(p) < min_distance_from_grass:
			return false
	return true
