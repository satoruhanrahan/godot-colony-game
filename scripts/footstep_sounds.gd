extends RefCounted

# Footsteps for everyone who walks (the player, the friend, the Lumberjack, the Hauler, the Builder): called from
# WaterMap.walked() by every mover with the distance it just moved.
#
#  - STRIDE: a step each time the distance walked adds up to STRIDE_LENGTH_PX (14), not by animation frame, so slowed walking
#    (tiredness, hunger, wading) steps slower by itself. Standing, sleeping, hidden (inside a house the player is not in) and
#    jumps (a teleport) make none.
#  - SURFACE under the feet: grass, bare dirt (tilled plots), the wooden floor inside a house or storage, shallow water (a
#    splash) and the shore edge (a soft grass step). Sounds: step_grass, step_dirt, step_wood, step_water (3 variants each, made
#    by tools/make_sounds.py; replace any of them with your own recordings: a plain step_grass.wav overrides its variants).
#  - LOUDNESS: the player at STEP_VOLUME_PLAYER (0.5), everyone else at STEP_VOLUME_OTHER (0.35), positional and heard up to
#    about 10 tiles; x1.2 when carrying a log or planks; the left and the right foot differ a little (volume and variant: v1
#    is the brighter left foot, v2 the darker right one).
#  - At most 6 step voices at once. Fast forward: the ff_sfx_volume share and every other step. None during the sleep skip or
#    while paused.

const WaterMap = preload("res://scripts/water_map.gd")
const STRIDE_LENGTH_PX: float = 14.0
const STEP_VOLUME_PLAYER: float = 0.5
const STEP_VOLUME_OTHER: float = 0.35
const CARRY_FACTOR: float = 1.2
const SOUND_OF: Dictionary = {"grass": "step_grass", "dirt": "step_dirt", "wood": "step_wood", "water": "step_water", "shore": "step_grass"}
# The shore edge is a soft step: a little quieter than the grass.
const SURFACE_DB: Dictionary = {"shore": -4.0}

# What the ground under a character is made of.
static func surface_at(tree: SceneTree, pos: Vector2) -> String:
	if pos.x >= 2400.0:
		return "wood"
	if WaterMap.active:
		if WaterMap.shallow_at(pos):
			return "water"
		var cell: Vector2i = WaterMap.tile_of(pos)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if (dx != 0 or dy != 0) and WaterMap.is_water(cell + Vector2i(dx, dy)):
					return "shore"
	var plots: Node = tree.get_first_node_in_group("plot_manager")
	if plots != null and plots.has_method("plot_at") and plots.plot_at(pos):
		return "dirt"
	return "grass"

# `who` has just moved `step` px. Returns the sound played ("" = none).
static func walked(who: Node2D, step: float) -> String:
	if step <= 0.0 or step > 24.0:
		return ""
	var dist: float = float(who.get_meta(&"stride", 0.0)) + step
	if dist < STRIDE_LENGTH_PX:
		who.set_meta(&"stride", dist)
		return ""
	who.set_meta(&"stride", dist - STRIDE_LENGTH_PX)
	return step_now(who)

# One step of `who` now (the stride has accumulated).
static func step_now(who: Node2D) -> String:
	var tree: SceneTree = who.get_tree()
	if tree == null or tree.paused or not AudioManager.footsteps or not who.visible:
		return ""
	if who.get("dead") == true:
		return ""
	var player: Node2D = tree.get_first_node_in_group("player")
	var is_player: bool = who == player
	# not while the player sleeps through the night (the sleep skip turns the sound down)
	if AudioManager.quiet_db < -0.5 or (player != null and player.get("state") != null and player.state == player.State.SLEEPING):
		return ""
	if not is_player and player != null:
		# inaudible when the character is inside a building the player is not in
		var inside: bool = who.global_position.x >= 2400.0
		var player_inside: bool = player.global_position.x >= 2400.0
		if inside != player_inside or (inside and who.global_position.distance_to(player.global_position) > 300.0):
			return ""
	var fast: Node = tree.root.get_node_or_null("FastForward")
	var db: float = linear_to_db(STEP_VOLUME_PLAYER if is_player else STEP_VOLUME_OTHER)
	if fast != null and fast.is_fast():
		# every other step, at the fast forward volume
		var count: int = int(who.get_meta(&"ff_step", 0)) + 1
		who.set_meta(&"ff_step", count)
		if count % 2 == 0:
			return ""
		db += linear_to_db(maxf(0.01, fast.ff_sfx_volume))
	var heavy: bool = (who.get("carrying_planks") != null and who.carrying_planks > 0) or (who.get("dragger") != null and who.dragger.is_dragging())
	if heavy:
		db += linear_to_db(CARRY_FACTOR)
	var surface: String = surface_at(tree, who.global_position)
	db += float(SURFACE_DB.get(surface, 0.0))
	var left: bool = int(who.get_meta(&"foot", 0)) == 0
	who.set_meta(&"foot", 1 if left else 0)
	var sound: String = SOUND_OF[surface]
	AudioManager.play_step(sound, who.global_position, db + (0.8 if left else -0.8), left)
	return sound
