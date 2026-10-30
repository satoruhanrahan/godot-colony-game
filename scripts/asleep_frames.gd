extends RefCounted

# The ONE place that decides how a sleeper looks (the player, every colonist, every worker):
#
#   SleepVisual.set_asleep(sprite, true,  extra_offset, rotation_degrees)   -> the asleep picture
#   SleepVisual.set_asleep(sprite, false)                                    -> back to how he was
#
# The asleep picture is an "asleep" animation of one static frame (main_character_asleep.png /
# colonist_asleep.png); ensure() adds it in code when the SpriteFrames resource on disk does not carry it. It
# is drawn on the same canvas as the standing picture, at scale 1 with Nearest filtering, never resized or
# flipped; the way he faced and his normal offset are kept for when he wakes. `extra_offset` nudges it (on a
# bed / on the ground), and `rotation_degrees` (0 = as drawn) can lay it on its side: the picture is then
# turned about its own middle, which stays where the upright picture's middle was (plus the nudge).
# A character whose SpriteFrames has no asleep picture (the automated workers) stays as he is.
#
# Callers put him at the bed's sleeping spot / lying spot themselves; the picture is drawn above a bed (a flat
# decal under everything depth-sorted) because he is a normal depth-sorted node.

# The picture's middle when it is turned on its side, above his feet.
const LYING_CENTRE: Vector2 = Vector2(0, -5)

static func ensure(sprite: AnimatedSprite2D, texture_path: String) -> void:
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var frames: SpriteFrames = sprite.sprite_frames
	if frames == null or frames.has_animation(&"asleep"):
		return
	if not ResourceLoader.exists(texture_path):
		push_warning("Asleep picture missing: %s" % texture_path)
		return
	frames.add_animation(&"asleep")
	frames.set_animation_loop(&"asleep", true)
	frames.set_animation_speed(&"asleep", 5.0)
	frames.add_frame(&"asleep", load(texture_path))

static func has_picture(sprite: AnimatedSprite2D) -> bool:
	return sprite.sprite_frames != null and sprite.sprite_frames.has_animation(&"asleep")

static func is_asleep_shown(sprite: AnimatedSprite2D) -> bool:
	return sprite.has_meta("sleep_visual_on") and sprite.get_meta("sleep_visual_on")

static func set_asleep(sprite: AnimatedSprite2D, asleep: bool, extra_offset: Vector2 = Vector2.ZERO, rotation_degrees: float = 0.0) -> void:
	if asleep:
		if not has_picture(sprite):
			return
		if not is_asleep_shown(sprite):
			sprite.set_meta("sleep_base_offset", sprite.offset)
			sprite.set_meta("sleep_base_flip", sprite.flip_h)
			sprite.set_meta("sleep_visual_on", true)
		var base_offset: Vector2 = sprite.get_meta("sleep_base_offset")
		sprite.flip_h = false
		sprite.rotation_degrees = rotation_degrees
		if rotation_degrees == 0.0:
			sprite.offset = base_offset + extra_offset
		else:
			# Turned about the node's origin (his feet): the offset puts the picture's middle at LYING_CENTRE.
			sprite.offset = (LYING_CENTRE + extra_offset).rotated(-deg_to_rad(rotation_degrees))
		sprite.play(&"asleep")
	elif is_asleep_shown(sprite):
		sprite.set_meta("sleep_visual_on", false)
		sprite.rotation_degrees = 0.0
		sprite.offset = sprite.get_meta("sleep_base_offset")
		sprite.flip_h = sprite.get_meta("sleep_base_flip")
