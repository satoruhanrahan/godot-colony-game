extends CanvasLayer

# The sleep fade and the time skip of the MainCharacter (a child of him; he calls begin() when any sleep starts and
# on_woke() when it ends). A full-screen black rect with a small text, above the HUD and the door fade (layer 85),
# below the game-over screen (90).
#
#  OUT   the screen fades to black over fade_out_seconds ("Sleeping...");
#  BLACK the world is simulated at a high speed: the clock runs `speed` clock-seconds per real second, where
#        speed = max(sleep_skip_speed, clock-seconds left to sleep / sleep_skip_target_real_seconds), the second part worked
#        out when it goes dark and kept (so the dark lasts about the target) (only the clock and
#        everything that reads clock_delta: energy, hunger, bushes, grass, plots, colonists and workers' schedules).
#        Engine.time_scale is NOT touched, so walking, animation and physics keep their normal timestep and nothing
#        jumps, and audio is never pitched. No single frame advances the clock by more than sleep_skip_max_clock_step
#        clock-seconds, so each frame's step is a small fixed slice (a night is ~200 clock-seconds: about 2 per frame at
#        60 fps, far below the cap) and no dusk or dawn is skipped over unseen; a slow frame just takes the smaller
#        step. After sleep_skip_max_real_seconds the speed also doubles every half second, so it ends within about that
#        time whatever happens;
#  HOLD  after he wakes: black for sleep_black_hold_seconds with "Day N" (and why, if it was hunger);
#  IN    fades back over fade_in_seconds.
# Any movement key, E or a click while it is dark (also during the fade out) cancels the sleep: he wakes at the
# current time of day and the fade in is four times quicker.
# Fast forward is put back to 1x (and locked) while the sleep runs and restored after; the SFX bus is turned down
# (not pitched) during the black. Death cuts everything at once (abort_now).
# All its numbers are exports of the MainCharacter.

enum Phase { NONE, OUT, BLACK, HOLD, IN }

var player: Node
var phase: Phase = Phase.NONE
var _rect: ColorRect
var _label: Label
var _alpha: float = 0.0
var _hold_left: float = 0.0
var _skip_real: float = 0.0
var _ff_before: int = -1
var _in_seconds: float = 0.7
var _note: String = ""
var _quiet: bool = false
# The speed planned for this sleep: the clock-seconds left to sleep when it went dark / sleep_skip_target_real_seconds
# (a constant speed, so the dark lasts about the target; it is only ever raised if the estimate grows).
var _plan_speed: float = 0.0
# The clock multiplier the black phase asked for last (for tests).
var last_speed: float = 1.0

func _ready() -> void:
	layer = 85
	_rect = ColorRect.new()
	_rect.color = Color(0, 0, 0, 1)
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The black and its text ("Sleeping...", "Day N") are the UI's, over everything, crisp at the window's resolution.
	Ui.fade_root.add_child(_rect)
	_label = Ui.make_label("heading", Color(0.86, 0.82, 0.7))
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Ui.fade_root.add_child(_label)
	_apply()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node in [_rect, _label]:
			if is_instance_valid(node):
				node.queue_free()

func _clock() -> Node:
	return get_tree().get_first_node_in_group("game_clock")

func _fast() -> Node:
	return get_node_or_null("/root/FastForward")

# True while the sleep is running (dark or going dark).
func sleeping_phase() -> bool:
	return phase == Phase.OUT or phase == Phase.BLACK

func begin() -> void:
	if _ff_before < 0:
		var fast: Node = _fast()
		_ff_before = fast.suspend() if fast != null else 0
	phase = Phase.OUT
	_skip_real = 0.0
	_plan_speed = 0.0
	_note = ""
	_label.text = "Sleeping..."
	_apply()

# He has woken (the sleep is over): `cancelled` = he cancelled it; `note` = why, when it matters.
func on_woke(cancelled: bool, note: String = "") -> void:
	if not sleeping_phase():
		return
	_restore()
	var clock: Node = _clock()
	if cancelled:
		phase = Phase.IN
		_in_seconds = maxf(0.05, player.fade_in_seconds * 0.25)
		_label.text = ""
	else:
		phase = Phase.HOLD
		_hold_left = player.sleep_black_hold_seconds
		_note = note
		_label.text = "Day %d" % clock.day + ("\n" + note if note != "" else "")
	_apply()

# He died (or the scene ends): everything is put back at once.
func abort_now() -> void:
	_restore()
	phase = Phase.NONE
	_alpha = 0.0
	_label.text = ""
	_apply()

func _restore() -> void:
	if _quiet:
		AudioManager.set_quiet(0.0)
		_quiet = false
	if _ff_before >= 0:
		var fast: Node = _fast()
		if fast != null:
			fast.resume(_ff_before)
		_ff_before = -1

func _apply() -> void:
	_rect.modulate.a = _alpha
	_label.modulate.a = clampf(_alpha * 1.5 - 0.3, 0.0, 1.0) if phase != Phase.IN else clampf(_alpha * 2.0 - 0.5, 0.0, 1.0)
	_rect.visible = _alpha > 0.0
	_label.visible = _alpha > 0.0 and _label.text != ""

func _process(delta: float) -> void:
	# (Real time: the frame step with Engine.time_scale taken out; the fade and the timings never follow the clock.)
	var real: float = clampf(delta / maxf(0.01, Engine.time_scale), 0.0, 0.25)
	match phase:
		Phase.OUT:
			_alpha = minf(1.0, _alpha + real / maxf(0.01, player.fade_out_seconds))
			if _alpha >= 1.0:
				phase = Phase.BLACK
				if not _quiet:
					AudioManager.set_quiet(player.sleep_skip_quiet_db)
					_quiet = true
		Phase.BLACK:
			_skip_real += real
			_drive_clock(real)
		Phase.HOLD:
			_hold_left -= real
			if _hold_left <= 0.0:
				phase = Phase.IN
				_in_seconds = maxf(0.05, player.fade_in_seconds)
				if _note != "":
					var hud: Node = get_tree().get_first_node_in_group("hud")
					if hud != null:
						hud.say(_note)
		Phase.IN:
			_alpha = maxf(0.0, _alpha - real / _in_seconds)
			if _alpha <= 0.0:
				phase = Phase.NONE
				_label.text = ""
	_apply()

# The clock speed while it is dark.
func _drive_clock(real: float) -> void:
	var clock: Node = _clock()
	if clock == null:
		return
	var speed: float = player.sleep_skip_speed
	if player.debug_hold_sleep:
		speed = 1.0
	else:
		_plan_speed = maxf(_plan_speed, remaining_clock_seconds() / maxf(0.1, player.sleep_skip_target_real_seconds))
		speed = maxf(speed, _plan_speed)
		var cap: float = player.sleep_skip_max_real_seconds
		if _skip_real > cap:
			speed *= pow(2.0, (_skip_real - cap) / 0.5)
		# No frame may move the clock by more than the step limit.
		speed = minf(speed, player.sleep_skip_max_clock_step / maxf(real, 1.0 / 120.0))
	last_speed = maxf(1.0, speed)
	clock.clock_speed_multiplier = last_speed

# The clock-seconds until he wakes by himself (an estimate): at dawn once rest is at least player_dawn_wake_rest, or
# when rest is full (where sleeping recovers rest at all).
func remaining_clock_seconds() -> float:
	var clock: Node = _clock()
	if clock == null or player == null:
		return 0.0
	var to_dawn: float = 0.0 if clock.is_daytime() else (1.0 - clock.time_of_day) * clock.day_length
	var rest = player.rest
	if not rest.sleep_recovers():
		return to_dawn
	var rate: float = maxf(0.0001, rest.sleep_rate)
	var to_enough: float = maxf(0.0, (clock.player_dawn_wake_rest - rest.value) / rate)
	var to_full: float = maxf(0.0, (100.0 - rest.value) / rate)
	return minf(to_full, maxf(to_dawn, to_enough))

# A click while it is dark cancels the sleep (movement keys and E are handled by the player and Interaction).
func _input(event: InputEvent) -> void:
	if sleeping_phase() and event is InputEventMouseButton and event.pressed and player.state == player.State.SLEEPING:
		player.wake_up(true)
