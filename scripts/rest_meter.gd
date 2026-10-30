extends Node

# A reusable Rest need, 0 to 100 (never outside it), for the MainCharacter and every Colonist.
#  - Awake it drains at the clock's awake drain times `activity` (the owner says: 1 walking or standing,
#    work_drain_multiplier while working, carry_drain_multiplier while carrying).
#  - Asleep it changes at sleep_rate per clock-second, set by where he sleeps (see GameClock): outdoors
#    a slow loss, on a bare floor none, on a bed a gain.
# It runs on the clock's own delta (GameClock.clock_delta), so clock_speed_multiplier speeds it up and
# nothing else. It also says how efficient a tired body is (see GameClock.efficiency).

var value: float = 100.0
var sleeping: bool = false
# Rest per clock-second while asleep (negative = still losing).
var sleep_rate: float = 0.0
# Returns the awake drain multiplier right now (set by the owner).
var activity: Callable = func() -> float: return 1.0

# The owner's HungerMeter, if he has one: his efficiency is multiplied into efficiency() below.
var hunger: Node = null

var _clock: Node

func _process(_delta: float) -> void:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
		if _clock == null:
			return
	var step: float = _clock.clock_delta
	if sleeping:
		value = clampf(value + sleep_rate * step, 0.0, 100.0)
	else:
		value = clampf(value - _clock.drain_per_second() * float(activity.call()) * step, 0.0, 100.0)

func start_sleep(rate_per_second: float) -> void:
	sleeping = true
	sleep_rate = rate_per_second

func stop_sleep() -> void:
	sleeping = false

# Can sleeping here make it rise at all (a bed)?
func sleep_recovers() -> bool:
	return sleep_rate > 0.0

func is_full() -> bool:
	return value >= 99.99

# Too rested to go to sleep (see GameClock.not_tired_from).
func is_not_tired() -> bool:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	return value >= (_clock.not_tired_from if _clock != null else 99.99)

# The ONE efficiency everything uses (walking speed, animation speed, how long a work action takes, the pit
# saw): the energy efficiency (1 at full strength; below GameClock.slowdown_starts_at it falls linearly to the
# minimum at rest 0) or, when the owner has a hunger meter and it is worse, the hunger efficiency. The penalties
# do NOT stack: only the worse of the two applies.
func efficiency() -> float:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	if _clock == null:
		return 1.0
	var combined: float = _clock.efficiency(value)
	if hunger != null:
		combined = minf(combined, hunger.efficiency())
	return combined

# The playback speed his animations should have: his efficiency, but 1 while asleep. One helper for
# everyone with a Rest meter, so animation speed always follows the same value as movement speed.
func animation_scale() -> float:
	return 1.0 if sleeping else efficiency()

# Sets an AnimatedSprite2D's speed_scale to animation_scale() (a tired body walks and works slower; the
# animation FPS is not touched).
func sync_animation(sprite: AnimatedSprite2D) -> void:
	var scale_now: float = animation_scale()
	if not is_equal_approx(sprite.speed_scale, scale_now):
		sprite.speed_scale = scale_now

# (The old name: used for movement speed.)
func speed_factor() -> float:
	return efficiency()
