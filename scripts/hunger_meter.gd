extends Node

# A reusable Hunger need, 0 to 100 (never outside it), for the MainCharacter and every Colonist: the same
# pattern as the RestMeter (energy), and it never hurts, it only slows.
#  - Awake it drains at 100 / hunger_seconds_to_empty per clock-second times `activity` (the owner says: 1
#    normally, the clock's hunger_work_multiplier while working). Asleep it drains at
#    hunger_sleep_multiplier of that.
#  - Its efficiency is 1 from hunger_slowdown_starts_at up, falling linearly to hunger_min_efficiency at 0.
#    The RestMeter multiplies it into the ONE shared efficiency (RestMeter.efficiency()), so walking speed,
#    animation speed, the time a work action takes and the pit saw timer all use the combined value.
# It runs on the clock's own delta (GameClock.clock_delta), so clock_speed_multiplier speeds it up.

signal eaten(amount: float)
# Emitted once, when hunger has been 0 for GameClock.starvation_grace_clock_seconds (default 0: the moment it
# reaches 0). THE death check of the game, the same for the player, every colonist and every worker: it runs here, in
# the meter's own update, so it does not depend on what the owner is doing (awake, asleep, inside, eating, carrying,
# fast forward, the sleep skip). The owners connect to it and do the rest (a body, a game-over screen).
signal starved

var value: float = 100.0
# Returns the awake drain multiplier right now (set by the owner).
var activity: Callable = func() -> float: return 1.0
# The owner's RestMeter (so a sleeper's hunger drains slower).
var rest: Node = null

var _clock: Node
var _was_low: bool = false
# Who this is (for the printed line); set by the owner.
var who_name: String = ""
var dead: bool = false
var _zero_for: float = 0.0

func _process(_delta: float) -> void:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
		if _clock == null:
			return
	var multiplier: float = float(activity.call())
	if rest != null and rest.sleeping:
		multiplier = _clock.hunger_sleep_multiplier
	if dead:
		return
	value = clampf(value - _clock.hunger_drain_per_second() * multiplier * _clock.clock_delta, 0.0, 100.0)
	_check_death()

# Hunger at 0 (or below: it is clamped, so exactly 0) for the grace period: he starves. One function for everyone.
func _check_death() -> void:
	if dead:
		return
	if value > 0.0:
		_zero_for = 0.0
		return
	_zero_for += _clock.clock_delta
	if _zero_for < _clock.starvation_grace_clock_seconds:
		return
	dead = true
	var who: String = who_name if who_name != "" else str(get_parent().name)
	print("DEATH: %s starved (cause: hunger reached 0, hunger %.2f, grace %.1f clock-s) on day %d at %s" % [who, value, _clock.starvation_grace_clock_seconds, _clock.day, _clock.clock_text()])
	starved.emit()

func efficiency() -> float:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	if _clock == null:
		return 1.0
	return _clock.hunger_efficiency(value)

func is_hungry() -> bool:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	return _clock != null and value < _clock.hungry_threshold

# Eats: raises hunger by `amount` (at most to 100).
func eat(amount: float) -> void:
	if dead:
		return
	value = minf(100.0, value + amount)
	eaten.emit(amount)
