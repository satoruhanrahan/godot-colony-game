extends RefCounted

# THE SHARED WORK ACTIONS: one function per kind of work, for ANY worker (the friend now, later settlers). Each takes the target and
# does exactly what the player's own hit does (the same hit on the target, the same sound and particles through WorkFeedback or the
# target's own effects), and returns what the worker needs to carry on. The time one action takes is seconds() = the player's own
# animation length (so the friend's swing is the player's swing), divided by the worker's efficiency (rest and hunger, the same
# RestMeter.efficiency() every character uses) and by the order's work efficiency (friend_work_efficiency 0.8: a bit slower).
#
# (The player's actions still live inside main_character.gd, driven by his animation's strike frame; this module is the same
# hits for a worker without that machinery. Moving the player onto it is a later refactor.)

const WorkFeedback = preload("res://scripts/work_feedback.gd")
const FoodConfig = preload("res://scripts/food_config.gd")
const PlankPiles = preload("res://scripts/plank_piles.gd")
const Items = preload("res://scripts/items.gd")

const ToolConfig = preload("res://scripts/tool_config.gd")

# The tool a kind of work needs (the ONE table is ToolConfig.job_tools), "" = none.
static func tool_of(kind: StringName) -> StringName:
	return ToolConfig.tool_for(kind)

# Seconds one action takes at full efficiency.
static func seconds(kind: StringName, player: Node) -> float:
	match kind:
		&"chop", &"delimb", &"hammer", &"pull", &"dig":
			var anim: StringName = &"chop" if kind == &"delimb" else (&"hammer" if kind == &"hammer" else (&"pull" if kind == &"pull" else kind))
			var frames: SpriteFrames = player.sprite.sprite_frames
			if frames != null and frames.has_animation(anim):
				return float(frames.get_frame_count(anim)) / maxf(1.0, frames.get_animation_speed(anim))
			return 0.8
		&"water":
			return FoodConfig.cfg().bucket_pour_seconds
	return 0.4

# One chop (or delimb) hit on a tree. Returns {"done", "total", "finished"}.
static func chop(scene_tree: SceneTree, tree: Node2D, kind: StringName, hits: int = 1) -> Dictionary:
	for i in hits:
		if (kind == &"chop" and not tree.is_standing()) or (kind == &"delimb" and tree.is_delimbed()):
			break
		tree.receive_hit()
	var total: int = tree.FELL_HITS if kind == &"chop" else tree.DELIMB_HITS
	var remaining: int = tree.fell_hits_remaining if kind == &"chop" else tree.delimb_hits_remaining
	var finished: bool = (not tree.is_standing()) if kind == &"chop" else tree.is_delimbed()
	WorkFeedback.hit(scene_tree, kind, tree, total - remaining, total, finished)
	return {"done": total - remaining, "total": total, "finished": finished}

# One hammer blow on a blueprint.
static func hammer(scene_tree: SceneTree, b: Node2D) -> Dictionary:
	b.hammer_hit()
	var finished: bool = b.is_finished()
	WorkFeedback.hit(scene_tree, &"hammer", b, b.build_progress, b.build_total(), finished)
	return {"done": b.build_progress, "total": b.build_total(), "finished": finished}

# One dig of a hole that is dug by hand (the pit saw): the shovel strike.
static func dig(scene_tree: SceneTree, b: Node2D) -> Dictionary:
	b.dig()
	var finished: bool = not b.needs_digging()
	WorkFeedback.hit(scene_tree, &"dig", b, b.dig_count, b.DIG_HITS, finished)
	return {"done": b.dig_count, "total": b.DIG_HITS, "finished": finished}

# One pull on a patch of tall grass; when it comes up the bundle is put down at `at`.
static func pull(scene_tree: SceneTree, patch: Node2D, player: Node, at: Vector2) -> Dictionary:
	var done: bool = patch.pull_hit()
	WorkFeedback.hit(scene_tree, &"pull", patch, patch.PULL_HITS if done else patch.pull_progress, patch.PULL_HITS, done)
	if done:
		PlankPiles.put_bundle(scene_tree, patch.get_parent(), at, player.pile_merge_radius, player.map_rect, at, 0.0)
	return {"done": patch.PULL_HITS if done else patch.pull_progress, "total": patch.PULL_HITS, "finished": done}

# One press of the hoe on a bare cell (the second makes a plot), or one press turning stubble back into soil. True when the cell is soil now.
static func till(m: Node2D, cell: Vector2i) -> bool:
	if m.has_plot(cell):
		if m.stage(cell) == &"stubble":
			m.retill(cell)
			return true
		return true
	return m.till_press(cell)

# One pour on a sown or growing plot.
static func water(m: Node2D, cell: Vector2i, at: Vector2) -> void:
	m.water(cell)
	AudioManager.play("pour", at)

# Cutting a ripe plot: the sheaf lies beside it (like the player's).
static func harvest(scene_tree: SceneTree, m: Node2D, cell: Vector2i, parent: Node, map_rect: Rect2) -> void:
	m.harvest(cell)
	var beside: Vector2 = m.cell_center(cell) + Vector2(0.0, float(m.size_px()) * 0.5 + 6.0)
	for i in FoodConfig.cfg().wheat_per_harvest:
		Items.put(scene_tree, parent, &"wheat_sheaf", beside + Vector2(i * 4.0, 0.0), map_rect)
