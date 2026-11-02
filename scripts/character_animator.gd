class_name CharacterAnimator
extends RefCounted

# THE ONE PLACE THAT DECIDES WHICH ANIMATION A CHARACTER PLAYS: the player and every colonist use it, so an animation added for the player (a new
# main_character_carrying_x.png in main_character_frames.tres, a new work animation) is played by the colonists at once. It has two halves:
#
#  THE PICKER (static, from what he holds):  walk_name() / idle_name(). Dragging a log keeps the normal walk; planks, the saw blade, a bundle of hay or
#    grass, and any held item or tool use "carry_<thing>" (walking) and "carry_<thing>_idle" (standing). A thing with no picture yet falls back to the
#    plain walk / idle and says so ONCE in the console ("no animation 'carry_flat_stone'") so you know what to draw.
#  THE WORKER (one per character, wrapping his AnimatedSprite2D): pose() keeps the walk / idle picture right for what he holds; start_work() plays the
#    work animation (chop, dig, hammer, pull) with the offset its 32x32 canvas needs; work_cycle() runs it for a colonist: the animation is played again
#    for every action, stretched to exactly the time one action takes, and the hit comes at the animation's strike frame (the same frame the player's
#    hit comes at), so the animation, the sound and the progress agree. A work with no animation (tilling, harvesting, watering: the player has none
#    either) plays the standing picture with what he holds in his hands, and the hit comes at the end of the action's time.
#
# What a character holds is a small Dictionary (held_state): {"dragging": bool, "planks": int, "blade": bool, "bundle": "hay" / "grass" / "",
# "item": StringName}. Scale, the Nearest filter and pixel snapping are never touched.

const CHOP_STRIKE_FRAME: int = 6
const DIG_STRIKE_FRAME: int = 7
const PULL_STRIKE_FRAME: int = 3
const HAMMER_STRIKE_FRAME: int = 1

# Each work: its animation, the frame its hit comes at, and which sprite shift its canvas needs ("chop" / "dig" are 32x32 canvases drawn so the
# body stands at the offsets below, mirrored with the facing; the 16x16 ones share the walk's canvas: none).
const WORK: Dictionary = {
	&"chop": {"anim": &"chop", "strike": CHOP_STRIKE_FRAME, "shift": &"chop"},
	&"delimb": {"anim": &"chop", "strike": CHOP_STRIKE_FRAME, "shift": &"chop"},
	&"dig": {"anim": &"dig", "strike": DIG_STRIKE_FRAME, "shift": &"dig"},
	&"hammer": {"anim": &"hammer", "strike": HAMMER_STRIKE_FRAME, "shift": &""},
	&"dismantle": {"anim": &"hammer", "strike": HAMMER_STRIKE_FRAME, "shift": &""},
	&"pull": {"anim": &"pull", "strike": PULL_STRIKE_FRAME, "shift": &""},
	&"bedbreak": {"anim": &"pull", "strike": PULL_STRIKE_FRAME, "shift": &""},
	&"pick": {"anim": &"pull", "strike": PULL_STRIKE_FRAME, "shift": &""},
}
const DEFAULT_SHIFT: Dictionary = {&"chop": Vector2(2, -16), &"dig": Vector2(3, -9)}

# What has been said already (once per missing name), and how many warnings in all (for the self-check).
static var _warned: Dictionary = {}
static var warnings_given: int = 0

var sprite: AnimatedSprite2D = null
var base_offset: Vector2 = Vector2.ZERO
# Something that has chop_sprite_offset / dig_sprite_offset (the player's exports); null looks the player up (or uses DEFAULT_SHIFT).
var config: Object = null
var in_work: bool = false
var work_kind: StringName = &""
var _t: float = 0.0
var _struck: bool = false

func _init(animated: AnimatedSprite2D = null, base: Vector2 = Vector2.ZERO) -> void:
	sprite = animated
	base_offset = base

# --- The picker -----------------------------------------------------------------------------------------------------------------------

static func held_state(dragging: bool = false, planks: int = 0, blade: bool = false, bundle: String = "", item: StringName = &"") -> Dictionary:
	return {"dragging": dragging, "planks": planks, "blade": blade, "bundle": bundle, "item": item}

# The name of what he carries as the animations call it ("plank", "blade", "hay", "grass", "axe", "wheat_sheaf" ...), "" when his hands are free
# (or he drags a log: that keeps the normal walk).
static func carry_key(held: Dictionary) -> StringName:
	if held.get("dragging", false):
		return &""
	if int(held.get("planks", 0)) > 0:
		return &"plank"
	if held.get("blade", false):
		return &"blade"
	var bundle: String = held.get("bundle", "")
	if bundle != "":
		return StringName(bundle)
	var item: StringName = held.get("item", &"")
	if item != &"" and item != &"berry":
		return item
	return &""

static func walk_name(frames: SpriteFrames, held: Dictionary) -> StringName:
	var key: StringName = carry_key(held)
	if key == &"":
		return &"walk"
	return _existing(frames, StringName("carry_" + key), &"walk")

static func idle_name(frames: SpriteFrames, held: Dictionary) -> StringName:
	var key: StringName = carry_key(held)
	if key == &"":
		return &"idle"
	return _existing(frames, StringName("carry_%s_idle" % key), &"idle")

# `wanted` if the frames have it, else `fallback` with a single warning naming what is missing.
static func _existing(frames: SpriteFrames, wanted: StringName, fallback: StringName) -> StringName:
	if frames != null and frames.has_animation(wanted) and frames.get_frame_count(wanted) > 0:
		return wanted
	_warn_once(String(wanted), "CharacterAnimator: no animation '%s' (the player's art has none yet): playing '%s' instead" % [wanted, fallback])
	return fallback

static func _warn_once(key: String, text: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	warnings_given += 1
	push_warning(text)

# --- The item above his head -----------------------------------------------------------------------------------------------------------

# THE ONE RULE for the little picture of a carried item drawn above a character (the colonists' carry_sprite): it is only for an item the animation
# that is playing does NOT already show. The player's carrying animations (carry_plank, carry_wheat_sheaf ...) have the item drawn in his arms, so an item with
# baked-in art never gets the overlay; one with none yet (the animation fell back to walk / idle) does, so it is never missing either. It is decided from
# the animation in front of us, and whoever draws the overlay asks this the moment the animation or the item changes.
static func needs_overlay(anim: StringName, carried: Dictionary) -> bool:
	var key: StringName = carry_key(carried)
	if key == &"":
		return false
	return anim != StringName("carry_" + key) and anim != StringName("carry_%s_idle" % key)

# Does the player's art show this carried thing in both its walking and its standing picture?
static func has_baked_art(frames: SpriteFrames, key: StringName) -> bool:
	return frames != null and frames.has_animation(StringName("carry_" + key)) and frames.has_animation(StringName("carry_%s_idle" % key))

# --- Standing and walking -------------------------------------------------------------------------------------------------------------

# The right walk (moving) or idle picture for what he holds: played only when it is not the one already playing (so frames keep running).
func pose(held: Dictionary, moving: bool) -> void:
	if sprite == null:
		return
	if sprite.sprite_frames == null:
		_warn_once("no_frames_" + str(sprite.get_instance_id()), "CharacterAnimator: %s has no sprite_frames: nothing can be drawn" % sprite.name)
		return
	var want: StringName = walk_name(sprite.sprite_frames, held) if moving else idle_name(sprite.sprite_frames, held)
	# (the safety net: whatever is playing must exist and have a picture, else he gets the plain walk / idle, never a blank body)
	if not has_picture(sprite.sprite_frames, sprite.animation):
		_warn_once("blank_" + String(sprite.animation), "CharacterAnimator: the animation '%s' is missing or has no frames: playing '%s' instead" % [sprite.animation, want])
		sprite.play(want)
		return
	if sprite.animation != want:
		sprite.play(want)

# Does this animation exist and have at least one frame?
static func has_picture(frames: SpriteFrames, anim: StringName) -> bool:
	return frames != null and frames.has_animation(anim) and frames.get_frame_count(anim) > 0

# Keeps whatever walk / idle picture is playing right for what he holds, whoever started it (a plain "walk" becomes "carry_axe" when an axe is in his
# hands, and back). Work and sleeping pictures are left alone.
func sync_carry(held: Dictionary) -> void:
	if sprite == null or sprite.sprite_frames == null:
		return
	var s: String = String(sprite.animation)
	var carry: bool = s.begins_with("carry_")
	var moving: bool = s == "walk" or (carry and not s.ends_with("_idle"))
	var standing: bool = s == "idle" or (carry and s.ends_with("_idle"))
	if not moving and not standing:
		return
	pose(held, moving)

# --- Working --------------------------------------------------------------------------------------------------------------------------

static func has_work_anim(frames: SpriteFrames, kind: StringName) -> bool:
	return WORK.has(kind) and frames != null and has_picture(frames, WORK[kind]["anim"])

# The sprite offset a work animation's canvas needs, mirrored with the way he faces.
func work_shift(kind: StringName, flip: bool) -> Vector2:
	var which: StringName = WORK.get(kind, {}).get("shift", &"")
	if which == &"":
		return base_offset
	if config == null and sprite != null and sprite.is_inside_tree():
		config = sprite.get_tree().get_first_node_in_group("player")
	var key: String = "%s_sprite_offset" % which
	var shift: Vector2 = DEFAULT_SHIFT[which]
	if config != null and key in config:
		shift = config.get(key)
	return Vector2(shift.x * (-1.0 if flip else 1.0), shift.y)

# Plays the work animation once (the player's swing): true if there is one. A kind with no animation plays nothing here.
func start_work(kind: StringName, flip: bool) -> bool:
	if sprite == null or not has_work_anim(sprite.sprite_frames, kind):
		return false
	sprite.offset = work_shift(kind, flip)
	sprite.play(WORK[kind]["anim"])
	return true

# One frame of a colonist's work: the animation runs for every action (`interval` seconds long), and this returns true the moment the hit is due.
func work_cycle(kind: StringName, delta: float, interval: float, held: Dictionary) -> bool:
	interval = maxf(0.05, interval)
	var frames: SpriteFrames = sprite.sprite_frames
	var has_anim: bool = has_work_anim(frames, kind)
	if not in_work or kind != work_kind or _t >= interval:
		_t = 0.0 if (not in_work or kind != work_kind) else maxf(0.0, _t - interval)
		_struck = false
		work_kind = kind
		in_work = true
		if has_anim:
			sprite.offset = work_shift(kind, sprite.flip_h)
			# (from the first frame every time, even if the last one has not quite run out)
			sprite.stop()
			sprite.play(WORK[kind]["anim"])
			sprite.set_frame_and_progress(0, 0.0)
		else:
			_warn_once("work:" + String(kind), "CharacterAnimator: no animation for the work '%s' (the player has none yet): standing with what he holds instead" % kind)
			sprite.offset = base_offset
			pose(held, false)
	var strike_at: float = interval
	if has_anim:
		var anim: StringName = WORK[kind]["anim"]
		var count: int = maxi(1, frames.get_frame_count(anim))
		var natural: float = float(count) / maxf(0.1, frames.get_animation_speed(anim))
		# (stretched so that the whole animation takes exactly one action)
		sprite.speed_scale = natural / interval
		strike_at = interval * float(WORK[kind]["strike"]) / float(count)
	_t += delta
	if not _struck and _t >= strike_at:
		_struck = true
		return true
	return false

# The work stopped: back to the normal offset and speed, and the walk / idle picture of what he holds.
func end_work() -> void:
	if not in_work:
		return
	in_work = false
	work_kind = &""
	if sprite != null:
		sprite.offset = base_offset
		sprite.speed_scale = 1.0
