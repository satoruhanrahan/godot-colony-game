extends RefCounted

# What the player sees and hears for every hit of his work now that the progress bars are off: one call per
# hit (at the swing's impact frame, so a tired, slower swing makes the sound and the puff later too).
#
#  - SOUND: the action's own sound at a constant pitch (a tiny random variation, AudioManager.hit_pitch_variation),
#    then the distinct completion sound at the end.
#  - SIGHT: the target reacts to each hit (a shake, a puff of specks), a blueprint flashes and solidifies, and
#    finishing pops a small sparkle at it.
#
# `kind` is the player's work_kind: chop, delimb, dig, hammer, pull, bedbreak, dismantle.

const WorkFx = preload("res://scripts/work_fx.gd")

# Per kind: the sound of one hit, and the sound when the job is done ("" = none).
const HIT_SOUND: Dictionary = {
	&"chop": "chop_hit", &"delimb": "delimb_hit", &"dig": "dig_hit", &"hammer": "hammer_hit",
	&"pull": "grass_pull", &"bedbreak": "grass_pull", &"dismantle": "dismantle_hit", &"pick": "berry_pick",
}
const DONE_SOUND: Dictionary = {
	&"chop": "", &"delimb": "delimb_hit", &"dig": "dig_hit", &"hammer": "",
	&"pull": "grass_pull", &"bedbreak": "bed_break", &"dismantle": "plank_drop", &"pick": "",
}

static func hit(tree: SceneTree, kind: StringName, target: Node2D, done: int, total: int, finished: bool) -> void:
	if target == null or not is_instance_valid(target):
		return
	var at: Vector2 = _contact(kind, target)
	var pitch: float = AudioManager.hit_pitch()
	if HIT_SOUND.has(kind):
		AudioManager.play(HIT_SOUND[kind], at, pitch)
	_react(tree, kind, target, at, done, total)
	if finished:
		# The distinct completion sound and a sparkle at the object. (A felled tree, a finished building, bed or
		# pit saw announce themselves: tree_fall, build_complete.)
		if DONE_SOUND.get(kind, "") != "":
			AudioManager.play(DONE_SOUND[kind], at, 1.0)
		if kind != &"hammer" and kind != &"chop" and kind != &"pick":
			WorkFx.pop(tree, at + Vector2(0, -6))
	elif kind == &"chop" and done == total - 1 and target.is_in_group("trees"):
		# One hit from falling: the tree creaks.
		AudioManager.play("tree_creak", at, 1.0)

# Where the tool meets the thing, in the world.
static func _contact(kind: StringName, target: Node2D) -> Vector2:
	var p: Vector2 = target.global_position
	if target.is_in_group("trees"):
		if kind == &"chop":
			return p + Vector2(0, -10)
		return p + Vector2.UP.rotated(target.global_rotation) * 8.0
	if target.is_in_group("beds"):
		return target.centre_world()
	if target.is_in_group("pit_saws"):
		return p + Vector2(0, -6)
	if target.is_in_group("grass_patches") or target.is_in_group("berry_bushes"):
		return p + Vector2(0, -6)
	return p + Vector2(0, -8)

static func _react(tree: SceneTree, kind: StringName, target: Node2D, at: Vector2, done: int, total: int) -> void:
	match kind:
		&"chop":
			# The tree shakes a few pixels and sheds a speck or two; a chip flies off the cut.
			for part in ["Trunk", "Canopy"]:
				WorkFx.shake(target.get_node_or_null(part), 1.5)
			WorkFx.chips(tree, at, 1.0 if tree_side(tree, target) > 0.0 else -1.0)
			WorkFx.leaves(tree, target.global_position + Vector2(0, -26), 1 + (done % 2))
			if done >= total:
				WorkFx.leaves(tree, target.global_position + Vector2(0, -22), 6)
		&"delimb":
			WorkFx.chips(tree, at, 1.0)
		&"dig":
			WorkFx.dirt(tree, at)
		&"hammer":
			WorkFx.spark(tree, at)
			WorkFx.dust(tree, at, 2)
			if target.is_in_group("beds"):
				WorkFx.shake(target.get("sprite"), 1.0)
			if target.has_method("flash"):
				target.flash()
		&"pull":
			WorkFx.rustle(tree, at)
			WorkFx.shake(target, 1.2)
		&"pick":
			# A berry comes off: it shakes, specks fly; the bush that gives its last berry puffs.
			WorkFx.berries(tree, at)
			WorkFx.shake(target, 1.2)
			if done >= total:
				WorkFx.dust(tree, target.global_position + Vector2(0, -6), 4)
		&"bedbreak":
			WorkFx.dust(tree, at, 4)
			WorkFx.shake(target.get("sprite"), 1.5)
		&"dismantle":
			WorkFx.dust(tree, at, 3)
			if target.is_in_group("beds"):
				WorkFx.shake(target.get("sprite"), 1.2)
			else:
				WorkFx.shake(target, 1.0)

# Which side of the tree he stands on (the chip flies away from him).
static func tree_side(tree: SceneTree, target: Node2D) -> float:
	var player: Node2D = tree.get_first_node_in_group("player")
	if player == null:
		return 1.0
	return 1.0 if player.global_position.x < target.global_position.x else -1.0

# A construction has just been finished (by the player or a Builder): the rising chime and a sparkle at it.
static func completed(tree: SceneTree, at: Vector2) -> void:
	AudioManager.play("build_complete", at, 1.0)
	WorkFx.pop(tree, at + Vector2(0, -8))
