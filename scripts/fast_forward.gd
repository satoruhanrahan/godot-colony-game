extends Node

# Fast forward (an autoload: FastForward). It sets Engine.time_scale to one of speed_steps (1x, 2x, 4x), so
# everything runs faster: walking, work, animations, needs, the clock, colonists, particles. The HUD button
# next to the clock (ClockHud) and the X key cycle it.
#
#  - Audio keeps its normal playback pitch (AudioServer.playback_speed_scale stays 1), and the SFX are
#    played at ff_sfx_volume (a share of normal) while above 1x, so hits at 4x are not painful.
#  - It drops back to 1x by itself when a warning appears (the starving warning; also when someone dies or the
#    game-over screen shows: call FastForward.warning("...") from there), if ff_auto_slow_on_warning is on.
#  - While the player sleeps the sleep skip (sleep_skip.gd) takes over: fast forward is put back to 1x and locked
#    (suspend()), the clock runs at the skip speed, and the previous step is restored when he wakes (resume()).
#  - Physics keeps its fixed 1/60 s step (Engine.time_scale runs more steps per frame, up to
#    max_physics_steps_per_frame), so nothing tunnels through walls or trees at 4x; walking by hand-written
#    moves is at most 4 x 40 px/s / 60 = under 3 px a frame.
#  - Screen fades and the door transition ignore the time scale (they always take 0.3 s of real time).
#  - It is separate from GameClock.clock_speed_multiplier, the debug control, which stays as it was.

signal speed_changed(factor: float)

@export var speed_steps: Array[float] = [1.0, 2.0, 4.0]
# SFX loudness (share of normal) while above 1x.
@export_range(0.0, 1.0) var ff_sfx_volume: float = 0.5
@export var ff_auto_slow_on_warning: bool = true
# The most the engine speed times the clock multiplier may reach while the player sleeps.
@export var max_combined_speed: float = 8.0
@export var hotkey: Key = KEY_X

var index: int = 0
# While true the speed cannot be changed (the sleep fade runs the world its own way).
var locked: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_apply()

func factor() -> float:
	return speed_steps[clampi(index, 0, speed_steps.size() - 1)]

func is_fast() -> bool:
	return factor() > 1.0

func cycle() -> void:
	# (Not while the game is paused: the step is remembered and is back as it was on resume.)
	if locked or get_tree().paused:
		return
	index = (index + 1) % speed_steps.size()
	_apply()

func set_index(i: int) -> void:
	if locked:
		return
	index = clampi(i, 0, speed_steps.size() - 1)
	_apply()

# The sleep skip takes over the speed: back to 1x and locked. Returns the step to give back (see resume).
func suspend() -> int:
	var before: int = index
	index = 0
	locked = true
	_apply()
	return before

func resume(before: int) -> void:
	locked = false
	set_index(before)

# Back to 1x (a warning, a death, the game-over screen).
func drop_to_normal() -> void:
	if index != 0 and not locked:
		index = 0
		_apply()

# Something the player must see: slow down if the setting says so.
func warning(_reason: String = "") -> void:
	if ff_auto_slow_on_warning:
		drop_to_normal()

func _apply() -> void:
	Engine.time_scale = factor()
	AudioServer.playback_speed_scale = 1.0
	var audio: Node = get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.apply_volumes()
	speed_changed.emit(factor())

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == hotkey and not event.ctrl_pressed:
		cycle()
		get_viewport().set_input_as_handled()
