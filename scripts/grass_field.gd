extends Node

# Scatters patches of grass over the ground when the game starts (in the opening, where hay is needed
# for beds). Each patch keeps a minimum distance from the LandingPoint, from every building and
# blocker, from trees and from the other patches; none is placed on a solid.

const GRASS_SCENE: PackedScene = preload("res://scenes/GrassPatch.tscn")

@export var patch_count: int = 12
@export var min_distance_from_landing: float = 70.0
@export var min_distance_from_buildings: float = 36.0
@export var min_distance_from_trees: float = 22.0
@export var min_spacing: float = 34.0
@export var map_rect: Rect2 = Rect2(0, 0, 640, 640)
# 0 = a different scatter each game.
@export var random_seed: int = 0
# Only the new opening uses grass; the old automated start has no patches.
@export var only_in_opening_mode: bool = true

func _ready() -> void:
	# After the main scene has taken out what the opening removes.
	_spawn.call_deferred()

func _spawn() -> void:
	var root: Node = get_parent()
	if only_in_opening_mode and not root.opening_mode:
		return
	var landing: Node2D = root.get_node_or_null("LandingPoint")
	var rng := RandomNumberGenerator.new()
	if random_seed != 0:
		rng.seed = random_seed
	else:
		rng.randomize()
	var placed: Array[Vector2] = []
	var inside := Rect2(map_rect.position + Vector2(24, 40), map_rect.size - Vector2(48, 64))
	var attempts: int = 0
	while placed.size() < patch_count and attempts < patch_count * 80:
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
		var patch: Node2D = GRASS_SCENE.instantiate()
		patch.position = p
		root.add_child(patch)

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
	return true
