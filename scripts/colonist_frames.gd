class_name ColonistFrames
extends RefCounted

# The SpriteFrames every Colonist uses: the PLAYER'S complete set (main_character_frames.tres: every animation he has now, including the
# carrying, work, pulling and sleeping ones, and every one he gets later) with the colonist's own art laid over it. Whatever animation
# colonist_frames.tres defines (idle, walk, asleep: colonist_walk.png, colonist_asleep.png) is explicit art and WINS, with its own speed and loop;
# everything else is the player's art. The colours come from the PaletteSwap material on the Colonist (the dedicated art's hat / pants colour is
# listed in player_palette.tres as an alias, so it follows the palette too).
#
# Built once and shared by every colonist (SpriteFrames are read-only while they play); to look at the result: ColonistFrames.report().

const PLAYER_FRAMES: String = "res://sprites/main_character_frames.tres"
const OWN_FRAMES: String = "res://sprites/colonist_frames.tres"

static var _merged: SpriteFrames = null

static func get_frames() -> SpriteFrames:
	if _merged == null:
		_merged = build()
	return _merged

static func build() -> SpriteFrames:
	var player: SpriteFrames = load(PLAYER_FRAMES)
	var own: SpriteFrames = load(OWN_FRAMES)
	var out := SpriteFrames.new()
	if out.has_animation(&"default"):
		out.remove_animation(&"default")
	for name in player.get_animation_names():
		if own != null and own.has_animation(name):
			_copy(own, out, name)
		else:
			_copy(player, out, name)
	# (an animation only the colonist has)
	if own != null:
		for name in own.get_animation_names():
			if not out.has_animation(name):
				_copy(own, out, name)
	return out

static func _copy(from: SpriteFrames, to: SpriteFrames, name: StringName) -> void:
	to.add_animation(name)
	to.set_animation_speed(name, from.get_animation_speed(name))
	to.set_animation_loop(name, from.get_animation_loop(name))
	for i in from.get_frame_count(name):
		to.add_frame(name, from.get_frame_texture(name, i), from.get_frame_duration(name, i))

# Where every animation's art comes from, for a check: {animation: "colonist" / "player"}.
static func sources() -> Dictionary:
	var own: SpriteFrames = load(OWN_FRAMES)
	var out: Dictionary = {}
	for name in get_frames().get_animation_names():
		out[name] = "colonist" if own != null and own.has_animation(name) else "player"
	return out
