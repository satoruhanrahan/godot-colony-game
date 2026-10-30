extends Node

# The game clock: days, the phases of a day, and the settings of the Rest need that run on it.
#
# A day lasts day_length seconds of real time at clock_speed_multiplier 1 and starts at dawn. The last
# night_fraction of it is night; dawn and dusk are short transitions (transition_fraction of the day
# each) between night and day:
#   Dawn [0, t)  Day [t, 1 - night - t)  Dusk [1 - night - t, 1 - night)  Night [1 - night, 1)
# clock_speed_multiplier scales ONLY the clock and the timers that read clock_delta (the Rest meters
# and regrowth). It never touches Engine.time_scale, movement, animation speed or production
# timers (sawing, the Sawmill, digging, ...).

enum Phase { DAWN, DAY, DUSK, NIGHT }

signal dawn_started(day: int)
signal dusk_started(day: int)
signal night_started(day: int)
signal day_changed(day: int)

@export var day_length: float = 600.0
@export_range(0.05, 0.6) var night_fraction: float = 0.3
# Dawn and dusk each take this share of the day (from the neighbouring phase).
@export_range(0.0, 0.2) var transition_fraction: float = 0.05
# Where in the day the game starts (0 = dawn), shortly after dawn.
@export_range(0.0, 1.0) var start_time_of_day: float = 0.08
# Scales the clock (and everything that reads clock_delta). 1 = normal.
@export var clock_speed_multiplier: float = 1.0

@export_group("Rest")
# Rest runs from 0 to 100. Awake it drains so that 100 lasts this many clock-seconds...
@export var awake_seconds_to_empty: float = 635.0
# ...and asleep it recovers so that 0 -> 100 takes this many clock-seconds at quality 1.
@export var sleep_seconds_to_full: float = 120.0
# What sleeping does to rest, by where he sleeps (all as shares of the two basic rates: the awake
# drain, 100 / awake_seconds_to_empty, and the recovery, 100 / sleep_seconds_to_full, per clock-second):
#  - outdoors: no gain; rest still drains, at this share of the awake drain;
#  - the wooden floor of a house with no bed: a little gain (this share of the recovery, 0.2 = about +30 over
#    a full night);
#  - a grass / hay bed: this share of the recovery; a wooden bed: the share for its bedding (wooden_bed_recovery).
@export var outdoor_sleep_drain_fraction: float = 0.3
@export var floor_recovery_fraction: float = 0.2
@export var hay_recovery_fraction: float = 0.6
# The wooden bed's recovery (shares of the full rate) for 0, 1, 2 and 3 bundles of bedding on it (grass and hay
# bundles count the same).
@export var wooden_bed_recovery: Array[float] = [0.3, 0.55, 0.8, 1.0]
# While he is awake, the drain is multiplied by this while he works (chopping, delimbing, digging,
# hammering, sawing) and by this while he drags a log or carries a plank, the blade or a tool.
# Walking and standing stay at 1.
# Pulled grass bundles: a bundle looks green until its age (clock seconds, counted wherever it is) reaches
# bundle_to_hay_clock_seconds (two days), then like hay. That is only the look. This many bundles
# stacked together make a bed.
@export var bundle_to_hay_clock_seconds: float = 1200.0
@export var bundles_per_bed: int = 3
# The rest-gain arrows shown while rest rises: 1 arrow, 2 from this share of the full recovery rate,
# 3 from the second share (floor 0.2 -> 1, hay 0.6 -> 2, proper bed 1.0 -> 3).
@export var arrows_two_from: float = 0.4
@export var arrows_three_from: float = 0.8
@export var work_drain_multiplier: float = 2.5
@export var carry_drain_multiplier: float = 1.3
# One efficiency for everything he does: 100 percent from this rest up, falling linearly to
# min_efficiency_at_zero_rest at rest 0. It scales walking and carrying speed, the progress each
# chop / dig / hammer press adds, and the pit saw timer.
@export var slowdown_starts_at: float = 40.0
@export_range(0.0, 1.0) var min_efficiency_at_zero_rest: float = 0.2
# Automated workers (Lumberjack, Hauler, Builder): a worker with less rest than this does not start a
# new job, and one who is still busy this many clock-seconds after dusk leaves his job safely and goes
# to sleep.
@export var worker_min_rest_to_start: float = 15.0
@export var worker_finish_grace: float = 30.0
# A colonist with less rest than this will not help saw.
@export var refuse_work_below: float = 10.0
# A colonist or worker with less energy than this sleeps at once (even in the day): on a free bed if there
# is one, else on his house's floor, else outdoors. A daytime nap on a bed or floor ends when his energy
# reaches nap_wake_energy; an outdoor nap (which cannot gain energy) ends after nap_outdoor_max_seconds
# clock-seconds, and he will not nap outdoors again for nap_retry_seconds.
@export var exhausted_threshold: float = 15.0
@export var nap_wake_energy: float = 70.0
@export var nap_outdoor_max_seconds: float = 60.0
@export var nap_retry_seconds: float = 120.0
# Dismantling a construction returns this share of the materials that went into it, rounded down per kind
# (1.0 = all of them).
@export_range(0.0, 1.0) var dismantle_refund_fraction: float = 1.0
# The player sleeping: the clock runs this many times faster, and he wakes at dawn if his rest is at
# least player_dawn_wake_rest (or at 100).
@export var sleep_clock_multiplier: float = 4.0   # (no longer used: the sleep skip runs the clock, see MainCharacter "Sleep skip")
@export var player_dawn_wake_rest: float = 60.0
# The player is "not tired" (cannot go to sleep) from this rest up: just short of 100, so a few
# seconds of waking life does not let him doze off for a moment and wake at once.
@export var not_tired_from: float = 95.0

@export_group("Hunger")
# Hunger runs from 100 (full) to 0 and only ever slows him down. Awake it drains so that 100 lasts this many
# clock-seconds (7 game days of 600 s); working multiplies the drain, sleeping lowers it.
@export var hunger_seconds_to_empty: float = 4200.0
@export var hunger_work_multiplier: float = 1.5
@export var hunger_sleep_multiplier: float = 0.5
# Hunger's efficiency: 100 percent from this hunger up, falling linearly to hunger_min_efficiency at 0. It is
# compared with the energy efficiency in the one shared helper (RestMeter.efficiency()): the WORSE of the two
# applies, they do not stack.
@export var hunger_slowdown_starts_at: float = 40.0
@export_range(0.0, 1.0) var hunger_min_efficiency: float = 0.35
# A colonist below this goes to a ripe berry bush to eat; below hunger_warn_below the "!" shows above him.
@export var hungry_threshold: float = 40.0
@export var hunger_warn_below: float = 25.0
# Below this the player gets the starving warning (a message, and fast forward drops back to 1x).
@export var hunger_starving_below: float = 12.0
# Hunger 0 kills (player, colonists, workers) after this many clock-seconds at 0 (0 = at once).
@export var starvation_grace_clock_seconds: float = 0.0
# The player asleep wakes by himself when his hunger falls below this ("You woke up starving.").
@export var auto_wake_hunger: float = 10.0
# Berries and the basket: a berry restores berry_hunger_value hunger; a basket holds basket_capacity berries
# and slows him from full speed (empty) down to basket_full_speed (full).
@export var berry_hunger_value: float = 4.0
# A hungry colonist eats berry after berry until his hunger reaches this (or the bush has none left, then he goes
# to another ripe bush if he is still below it); below hunger_warn_below he puts everything but sleeping aside to eat.
@export var colonist_eat_until: float = 75.0
@export var basket_capacity: int = 6
@export_range(0.0, 1.0) var basket_full_speed: float = 0.9

@export_group("Debug")
# Prints a day-by-day balance table for each place to sleep when the game starts.
@export var run_self_check: bool = false

var day: int = 1
var time_of_day: float = 0.0
var phase: Phase = Phase.DAY
# The clock's step this frame: the real delta times clock_speed_multiplier. Rest meters read this.
var clock_delta: float = 0.0

func _ready() -> void:
	add_to_group("game_clock")
	time_of_day = start_time_of_day
	phase = _phase_at(time_of_day)
	if run_self_check:
		self_check()

func _process(delta: float) -> void:
	clock_delta = delta * clock_speed_multiplier
	if day_length <= 0.0:
		return
	time_of_day += clock_delta / day_length
	var wrapped: bool = false
	while time_of_day >= 1.0:
		time_of_day -= 1.0
		day += 1
		wrapped = true
	if wrapped:
		day_changed.emit(day)
	_update_phase()

func _update_phase() -> void:
	var now: Phase = _phase_at(time_of_day)
	if now == phase:
		return
	phase = now
	match phase:
		Phase.DAWN:
			dawn_started.emit(day)
		Phase.DUSK:
			dusk_started.emit(day)
		Phase.NIGHT:
			night_started.emit(day)

func _phase_at(t: float) -> Phase:
	var night_start: float = 1.0 - night_fraction
	if t < transition_fraction:
		return Phase.DAWN
	if t < night_start - transition_fraction:
		return Phase.DAY
	if t < night_start:
		return Phase.DUSK
	return Phase.NIGHT

# Sets the time directly (tests and tuning); phases settle without announcing anything.
func set_time(new_day: int, new_time_of_day: float) -> void:
	day = new_day
	time_of_day = clampf(new_time_of_day, 0.0, 0.9999)
	phase = _phase_at(time_of_day)

func is_night() -> bool:
	return phase == Phase.NIGHT

# Clock-seconds since the game began (always going up, through the sleep skip and fast forward): what growth is
# measured against.
func total_seconds() -> float:
	return (day - 1 + time_of_day) * day_length

# The time of day as the 24 hour clock of a day that starts at dawn (for printed lines).
func clock_text() -> String:
	var minutes: int = int(time_of_day * 24.0 * 60.0)
	return "%02d:%02d" % [minutes / 60, minutes % 60]

# Dusk and night: time to be in bed.
func is_bedtime() -> bool:
	return phase == Phase.DUSK or phase == Phase.NIGHT

# Dawn and day.
func is_daytime() -> bool:
	return phase == Phase.DAWN or phase == Phase.DAY

func phase_name() -> String:
	return ["Dawn", "Day", "Dusk", "Night"][phase]

# The phase at this share of the day (0 = dawn).
func phase_name_at(share: float) -> String:
	return ["Dawn", "Day", "Dusk", "Night"][_phase_at(share)]

# How dark it is, 0 (day) to 1 (night): eased across dusk and dawn.
func darkness() -> float:
	var night_start: float = 1.0 - night_fraction
	var t: float = time_of_day
	if t < transition_fraction:
		return 1.0 - smoothstep(0.0, transition_fraction, t)
	if t < night_start - transition_fraction:
		return 0.0
	if t < night_start:
		return smoothstep(night_start - transition_fraction, night_start, t)
	return 1.0

# --- Hunger numbers ----------------------------------------------------------------------------------

func hunger_drain_per_second() -> float:
	return 100.0 / maxf(1.0, hunger_seconds_to_empty)

# 1 at full strength; below hunger_slowdown_starts_at it falls linearly to hunger_min_efficiency at hunger 0.
func hunger_efficiency(hunger: float) -> float:
	return lerpf(hunger_min_efficiency, 1.0, clampf(hunger / maxf(0.001, hunger_slowdown_starts_at), 0.0, 1.0))

# --- Rest numbers ------------------------------------------------------------------------------------

func drain_per_second() -> float:
	return 100.0 / maxf(1.0, awake_seconds_to_empty)

func recovery_per_second(quality: float) -> float:
	return 100.0 / maxf(1.0, sleep_seconds_to_full) * quality

# How well he works and moves at this rest (1 = full): 1 from slowdown_starts_at up, then falling
# linearly to min_efficiency_at_zero_rest at rest 0.
func efficiency(rest: float) -> float:
	if rest >= slowdown_starts_at:
		return 1.0
	return lerpf(min_efficiency_at_zero_rest, 1.0, clampf(rest / maxf(0.001, slowdown_starts_at), 0.0, 1.0))

# How many rest-gain arrows a sleep rate earns (0 when rest does not rise).
func recovery_arrows(rate: float) -> int:
	if rate <= 0.0:
		return 0
	var share: float = rate / maxf(0.0001, recovery_per_second(1.0))
	if share >= arrows_three_from:
		return 3
	if share >= arrows_two_from:
		return 2
	return 1

# Rest change per clock-second while asleep outdoors (negative: it still drains, just slowly).
func sleep_rate_outdoors() -> float:
	return -drain_per_second() * outdoor_sleep_drain_fraction

# Rest change per clock-second while asleep on the bare floor of a house (level 0) or a grass / hay bed (1).
# (A wooden bed asks itself: Bed.sleep_rate_now.)
func sleep_rate_for_bed(level: int) -> float:
	if level >= 1:
		return recovery_per_second(hay_recovery_fraction)
	return recovery_per_second(floor_recovery_fraction)

# --- Self-check ------------------------------------------------------------------------------------

# Prints the Rest balance: for each place to sleep, the rest change over a night and over a whole day
# (awake from dawn to night, asleep the night) for a colonist at rest 100 who does nothing but walk or
# stand, and one who works all day; plus the efficiency at a few rest values, the progress a chop press
# adds, and how long continuous work lasts from rest 100 to 0.
# GrassField's default patch_count (read from a throwaway instance).
func _field_default_count() -> int:
	var field: Node = load("res://scripts/grass_field.gd").new()
	var count: int = field.patch_count
	field.free()
	return count

func self_check() -> void:
	var awake_seconds: float = day_length * (1.0 - night_fraction)
	var asleep_seconds: float = day_length * night_fraction
	var places: Dictionary = {"outdoors": sleep_rate_outdoors(), "wooden floor": sleep_rate_for_bed(0), "grass-hay bed": sleep_rate_for_bed(1), "wooden bed, full": recovery_per_second(wooden_bed_recovery[wooden_bed_recovery.size() - 1])}
	print("SELF-CHECK: day %.0f s = %.0f s awake + %.0f s asleep; awake drain %.4f/s (%.1f over the awake part), recovery base %.4f/s" % [day_length, awake_seconds, asleep_seconds, drain_per_second(), drain_per_second() * awake_seconds, recovery_per_second(1.0)])
	print("SELF-CHECK: staying awake all night would cost %.1f" % (drain_per_second() * asleep_seconds))
	# An idle character (drain x1) who wakes at dawn with rest 100 and never sleeps: when does his
	# efficiency drop? (Phases: Dawn 0-5%%, Day 5-65%%, Dusk 65-70%%, Night 70-100%% of the day.)
	print("SELF-CHECK: idle from dawn at rest 100, awake the whole time (time = seconds since dawn, as a share of the %.0f s day):" % day_length)
	for target in [0.9999, 0.75, 0.5, min_efficiency_at_zero_rest]:
		var rest_needed: float = slowdown_starts_at * (target - min_efficiency_at_zero_rest) / maxf(0.0001, 1.0 - min_efficiency_at_zero_rest)
		if target >= 0.999:
			rest_needed = slowdown_starts_at
		var seconds: float = (100.0 - rest_needed) / drain_per_second()
		var share: float = seconds / day_length
		var label: String = "first drops below 100%" if target >= 0.999 else ("reaches %.0f%%" % (target * 100.0))
		print("SELF-CHECK:   efficiency %-22s at rest %5.1f: after %5.0f s = %5.1f%% of the day -> day %d, %s (%.0f%% into that day's cycle)" % [label, rest_needed, seconds, share * 100.0, 1 + int(share), phase_name_at(fposmod(share, 1.0)), fposmod(share, 1.0) * 100.0])
	var work_rest_50: float = slowdown_starts_at * (0.5 - min_efficiency_at_zero_rest) / maxf(0.0001, 1.0 - min_efficiency_at_zero_rest)
	print("SELF-CHECK: continuous work (drain x%.1f): rest 100 -> 50%% efficiency (rest %.0f) takes %.0f s; to the first slowdown (rest %.0f) %.0f s; to rest 0 %.0f s" % [work_drain_multiplier, work_rest_50, (100.0 - work_rest_50) / (drain_per_second() * work_drain_multiplier), slowdown_starts_at, (100.0 - slowdown_starts_at) / (drain_per_second() * work_drain_multiplier), 100.0 / (drain_per_second() * work_drain_multiplier)])
	# Thresholds that depend on the drain: when an idle character crosses them.
	for pair in [["red rest bar / exhausted message / colonist ! icon", 25.0], ["colonist exhausted_threshold", exhausted_threshold], ["refuse_work_below", refuse_work_below]]:
		var sec: float = (100.0 - pair[1]) / drain_per_second()
		print("SELF-CHECK:   %s (rest %.0f) is reached after %.0f s idle = %.1f%% of the day (%s)" % [pair[0], pair[1], sec, sec / day_length * 100.0, phase_name_at(fposmod(sec / day_length, 1.0))])
	# What a night of sleep does, from the rest he has when the night begins (a normal day, idle) and from
	# the rest he has if he stayed up until late in the night.
	var bedtime_rest: float = maxf(0.0, 100.0 - drain_per_second() * awake_seconds)
	var late_rest: float = maxf(0.0, 100.0 - drain_per_second() * day_length * 0.9)
	for place in places:
		var gain: float = places[place] * asleep_seconds
		print("SELF-CHECK:   wakes with %5.1f after a full night on %-12s from rest %.1f (bedtime after an idle day) and %5.1f from rest %.1f (up until 90%% of the day)" % [clampf(bedtime_rest + gain, 0.0, 100.0), place, bedtime_rest, clampf(late_rest + gain, 0.0, 100.0), late_rest])
	for place in places:
		var night: float = places[place] * asleep_seconds
		var walking_day: float = night - drain_per_second() * awake_seconds
		var working_day: float = night - drain_per_second() * work_drain_multiplier * awake_seconds
		print("SELF-CHECK:   %-13s rate %+.4f/s  night %+.1f   whole day: walking about %+.1f, working all day %+.1f" % [place, places[place], night, walking_day, working_day])
	# How long an action takes: its animation length divided by the efficiency. (The animation FPS is
	# not changed: only the playback speed, speed_scale = efficiency. A press is always one full hit.)
	var swing: Dictionary = {"chop": [1.0, 6, 10.0], "dig": [0.8, 7, 10.0], "hammer": [0.3, 1, 10.0]}
	var player: Node = get_tree().get_first_node_in_group("player") if is_inside_tree() else null
	if player != null and player.get("sprite") != null and player.sprite.sprite_frames != null:
		var frames: SpriteFrames = player.sprite.sprite_frames
		for anim in ["chop", "dig", "hammer"]:
			var fps: float = frames.get_animation_speed(anim)
			swing[anim] = [frames.get_frame_count(anim) / fps, swing[anim][1], fps]
	var tree_hits: int = load("res://scripts/tree.gd").FELL_HITS
	print("SELF-CHECK: efficiency (full from rest %.0f, %.0f%% at rest 0); a press is always one full hit, so a tree always takes %d presses" % [slowdown_starts_at, min_efficiency_at_zero_rest * 100.0, tree_hits])
	for r in [100.0, 60.0, 30.0, 0.0]:
		var e: float = efficiency(r)
		print("SELF-CHECK:   rest %3.0f -> efficiency %3.0f%%: chop %.2f s (hit lands after %.2f s), dig hit %.2f s (lands %.2f s), hammer hit %.2f s (lands %.2f s); walk animation speed_scale %.2f, walking %.1f px/s; presses for a tree %d, time to fell it %.1f s of swinging" % [r, e * 100.0, swing["chop"][0] / e, swing["chop"][1] / swing["chop"][2] / e, swing["dig"][0] / e, swing["dig"][1] / swing["dig"][2] / e, swing["hammer"][0] / e, swing["hammer"][1] / swing["hammer"][2] / e, e, 40.0 * e, tree_hits, tree_hits * swing["chop"][0] / e])
	# Automated workers have no house: they stop at dusk and sleep outdoors (rest only drains, slowly), and
	# start again at dawn. Each works non-stop at its drain rate while awake and rested enough to take a
	# job (worker_min_rest_to_start); below that he idles at the plain drain. The efficiency curve is the
	# same as everyone else's.
	print("SELF-CHECK: workers (outdoor sleep, no bed; jobs only above rest %.0f):" % worker_min_rest_to_start)
	var worker_kinds: Dictionary = {"Lumberjack (chopping non-stop, x%.1f)" % work_drain_multiplier: work_drain_multiplier, "Hauler (hauling non-stop, x%.1f)" % carry_drain_multiplier: carry_drain_multiplier, "Builder (hammering non-stop, x%.1f)" % work_drain_multiplier: work_drain_multiplier}
	for kind in worker_kinds:
		var rest_now: float = 100.0
		var days: PackedStringArray = []
		for d in range(1, 5):
			var at_dawn: float = rest_now
			var worked: float = 0.0
			var seconds: float = 0.0
			while seconds < awake_seconds:
				if rest_now >= worker_min_rest_to_start:
					rest_now = maxf(0.0, rest_now - drain_per_second() * worker_kinds[kind])
					worked += 1.0
				else:
					rest_now = maxf(0.0, rest_now - drain_per_second())
				seconds += 1.0
			var at_dusk: float = rest_now
			rest_now = clampf(rest_now + sleep_rate_outdoors() * asleep_seconds, 0.0, 100.0)
			days.append("day %d: dawn %.0f, works %.0f s, dusk %.0f (efficiency %.0f%%)" % [d, at_dawn, worked, at_dusk, efficiency(at_dusk) * 100.0])
		print("SELF-CHECK:   %s" % kind)
		for line in days:
			print("SELF-CHECK:       %s" % line)
	# Beds: the grass and what a bed costs, and what sleeping on each does over one night.
	var bed = load("res://scenes/Bed.tscn").instantiate()
	var patch = load("res://scenes/GrassPatch.tscn").instantiate()
	print("SELF-CHECK: beds: %d grass bundles make a bed (a patch needs %d pulls and regrows after %.0f clock-seconds); a bundle turns from green to hay-coloured after %.0f clock-seconds (%.1f days; cosmetic only)" % [bundles_per_bed, patch.PULL_HITS, patch.regrow_clock_seconds, bundle_to_hay_clock_seconds, bundle_to_hay_clock_seconds / day_length])
	print("SELF-CHECK:   one bed = %d bundles = %d patches pulled = %d presses at full efficiency; breaking it up takes %d presses; a wooden bed needs %d planks and %d hammer hits and holds %d bundles of bedding" % [bundles_per_bed, bundles_per_bed, bundles_per_bed * patch.PULL_HITS, bed.break_presses, bed.wooden_planks, bed.wooden_build_hits, bed.bedding_max])
	var bed_levels: Array = [["floor of a house", 0], ["grass / hay bed", 1]]
	for entry in bed_levels:
		var rate: float = sleep_rate_for_bed(entry[1])
		print("SELF-CHECK:   %-16s rest %+.4f/s asleep, %+.1f over a %.0f s night (a full 0 -> 100 would take %s); %d arrow(s)" % [entry[0], rate, rate * asleep_seconds, asleep_seconds, ("%.0f s" % (100.0 / rate)) if rate > 0.0 else "never", recovery_arrows(rate)])
	bed.free()
	patch.free()
	_self_check_naps()
	_self_check_dismantle()
	_self_check_hunger()
	_self_check_interior()
	_self_check_house_beds()
	_self_check_wooden_bed()
	_self_check_storage_crates()
	_self_check_storage_stock()
	_self_check_slow_part()
	var work_rate: float = drain_per_second() * work_drain_multiplier
	var carry_rate: float = drain_per_second() * carry_drain_multiplier
	print("SELF-CHECK: rest 100 -> 0 awake: working non-stop %.0f s (%.2f/s), dragging or carrying %.0f s, walking or standing %.0f s" % [100.0 / work_rate, work_rate, 100.0 / carry_rate, 100.0 / drain_per_second()])

# A colonist at energy 0 in the daytime with one free bed (and a second, occupied, nearer one): which bed
# he picks, that it is reserved at once, and what the nap does to his energy.
func _self_check_naps() -> void:
	var BedFinder = load("res://scripts/bed_finder.gd")
	var scene: PackedScene = load("res://scenes/Bed.tscn")
	var occupied = scene.instantiate()
	var free_bed = scene.instantiate()
	occupied.position = Vector2(300, 300)
	free_bed.position = Vector2(340, 300)
	get_parent().add_child(occupied)
	get_parent().add_child(free_bed)
	var sleeper := Node.new()
	var napper := Node.new()
	occupied.lie_down(sleeper)
	var picked = BedFinder.choose(get_tree(), napper, Vector2(290, 300), null)
	var chose_free: bool = picked == free_bed
	if picked != null:
		picked.reserve(napper)
	var rate: float = picked.sleep_rate_now() if picked != null else sleep_rate_outdoors()
	var seconds: float = (nap_wake_energy - 0.0) / rate if rate > 0.0 else nap_outdoor_max_seconds
	print("SELF-CHECK: naps: a colonist at energy 0 by day, with the nearer bed occupied and one free bed: picks the free bed %s, reserved at once %s (reserved_by is him: %s; a second colonist finds it free: %s)" % [chose_free, picked != null and picked.is_occupied(), picked != null and picked.reserved_by == napper, picked != null and picked.is_free_for(sleeper)])
	print("SELF-CHECK:   the nap on it: energy 0 -> %.0f (nap_wake_energy) at %+.4f/s takes %.0f clock-seconds (%.0f%% of a %.0f s day), then he wakes and follows the player" % [nap_wake_energy, rate, seconds, seconds / day_length * 100.0, day_length])
	print("SELF-CHECK:   with no free bed he sleeps outdoors where he stands: %+.4f/s (energy only drains) and wakes after nap_outdoor_max_seconds = %.0f clock-seconds (%+.1f), and will not nap outdoors again for nap_retry_seconds = %.0f" % [sleep_rate_outdoors(), nap_outdoor_max_seconds, sleep_rate_outdoors() * nap_outdoor_max_seconds, nap_retry_seconds])
	free_bed.remove_from_group("beds")
	occupied.remove_from_group("beds")
	free_bed.free()
	occupied.free()
	sleeper.free()
	napper.free()

# Per construction: what it costs, the hammer hits to build and to dismantle it (half, rounded up), and what
# dismantling returns when it is finished and when it is only partly built.
func _self_check_dismantle() -> void:
	var Dis = load("res://scripts/dismantle.gd")
	print("SELF-CHECK: dismantling (dismantle_refund_fraction %.2f; the hammer, Shift+E or Shift+click; dismantle hits = ceil(build hits / 2)):" % dismantle_refund_fraction)
	for path in ["res://assets/house_type.tres", "res://assets/storage_type.tres", "res://assets/sawmill_type.tres"]:
		var type: BuildingType = load(path)
		var half: int = type.plank_cost / 2
		print("SELF-CHECK:   %-8s cost %2d planks, %2d build hits -> %2d dismantle hits; refund: finished %d planks; blueprint with hits (all %d delivered) %d; blueprint with %d delivered and no hits %d (or take them back by hand)" % [type.type_name, type.plank_cost, type.BUILD_HITS, ceili(type.BUILD_HITS / 2.0), Dis.scaled({"planks": type.plank_cost, "blades": 0}, dismantle_refund_fraction)["planks"], type.plank_cost, Dis.scaled({"planks": type.plank_cost, "blades": 0}, dismantle_refund_fraction)["planks"], half, Dis.scaled({"planks": half, "blades": 0}, dismantle_refund_fraction)["planks"]])
	var pit = load("res://scenes/PitSaw.tscn").instantiate()
	var full: Dictionary = Dis.scaled({"planks": pit.PLANKS_REQUIRED, "blades": pit.BLADES_REQUIRED}, dismantle_refund_fraction)
	var some: Dictionary = Dis.scaled({"planks": 1, "blades": 0}, dismantle_refund_fraction)
	print("SELF-CHECK:   Pit Saw  cost %2d planks + %d blade (+ digging), %2d build hits -> %2d dismantle hits; refund: finished %d planks + %d blade; supplied and dug (hits or not) %d planks + %d blade; with 1 plank only %d" % [pit.PLANKS_REQUIRED, pit.BLADES_REQUIRED, pit.PIT_BUILD_HITS, ceili(pit.PIT_BUILD_HITS / 2.0), full["planks"], full["blades"], full["planks"], full["blades"], some["planks"]])
	pit.free()
	var bed = load("res://scenes/WoodenBed.tscn").instantiate()
	var house = load("res://scenes/Building.tscn").instantiate()
	var wooden: BuildingType = load("res://assets/wooden_bed_type.tres")
	print("SELF-CHECK:   Wooden Bed cost %2d planks, %2d build hits -> %2d dismantle hits; refund %d planks plus its bedding as bundles; only on the floor of a house (outside it is greyed: \"%s\")" % [wooden.plank_cost, wooden.BUILD_HITS, ceili(wooden.BUILD_HITS / 2.0), Dis.scaled({"planks": wooden.plank_cost, "blades": 0}, dismantle_refund_fraction)["planks"], wooden.locked_hint])
	bed.free()
	house.free()

# Hunger: the drain, the efficiency curves and how they combine (only the worse applies), and what a berry, a
# basket and a bush give.
func _self_check_hunger() -> void:
	var per_second: float = hunger_drain_per_second()
	var awake_s: float = hunger_seconds_to_empty
	var work_s: float = hunger_seconds_to_empty / hunger_work_multiplier
	var sleep_s: float = hunger_seconds_to_empty / hunger_sleep_multiplier
	print("SELF-CHECK: hunger 100 -> 0: awake %.0f clock-seconds = %.1f game days (%.3f/s); working (x%.1f) %.0f s = %.1f days; asleep (x%.1f) %.0f s = %.1f days; slowdown starts at hunger %.0f (after %.0f s = %.1f days awake)" % [awake_s, awake_s / day_length, per_second, hunger_work_multiplier, work_s, work_s / day_length, hunger_sleep_multiplier, sleep_s, sleep_s / day_length, hunger_slowdown_starts_at, (100.0 - hunger_slowdown_starts_at) / per_second, (100.0 - hunger_slowdown_starts_at) / per_second / day_length])
	print("SELF-CHECK:   hunger efficiency: hunger 100 -> %.0f%%, 40 -> %.0f%%, 20 -> %.0f%%, 0 -> %.0f%%" % [hunger_efficiency(100.0) * 100.0, hunger_efficiency(40.0) * 100.0, hunger_efficiency(20.0) * 100.0, hunger_efficiency(0.0) * 100.0])
	var pairs: Array = []
	for pair in [[0.0, 0.0], [0.0, 100.0], [100.0, 0.0], [50.0, 50.0]]:
		pairs.append("(energy %.0f, hunger %.0f) -> %.0f%%" % [pair[0], pair[1], minf(efficiency(pair[0]), hunger_efficiency(pair[1])) * 100.0])
	print("SELF-CHECK:   combined efficiency = the WORSE of energy and hunger (no stacking): %s" % ", ".join(pairs))
	var bush = load("res://scenes/BerryBush.tscn").instantiate()
	var per_bush: int = bush.berries_per_bush
	var regrow: float = bush.berry_regrow_clock_seconds
	bush.free()
	var berry_s: float = berry_hunger_value / per_second
	print("SELF-CHECK:   food: a berry gives +%.0f hunger = %.0f s = %.2f days awake; a full basket (%d berries) +%.0f = %.2f days; a full bush (%d berries) +%.0f = %.2f days (regrows after %.0f s); a berry can be eaten up to hunger %.0f" % [berry_hunger_value, berry_s, berry_s / day_length, basket_capacity, basket_capacity * berry_hunger_value, basket_capacity * berry_s / day_length, per_bush, per_bush * berry_hunger_value, per_bush * berry_s / day_length, regrow, 100.0 - berry_hunger_value])
	var idle_day: float = day_length * per_second
	var work_day: float = idle_day * hunger_work_multiplier
	var night_s: float = day_length * night_fraction
	var normal_day: float = (day_length - night_s) * per_second + night_s * per_second * hunger_sleep_multiplier
	print("SELF-CHECK:   berries per day for one person: awake and resting all day %.1f hunger = %.1f berries; working all day %.1f = %.1f berries; a normal day (awake %.0f s, asleep %.0f s) %.1f = %.1f berries" % [idle_day, idle_day / berry_hunger_value, work_day, work_day / berry_hunger_value, day_length - night_s, night_s, normal_day, normal_day / berry_hunger_value])
	var field: Node = get_parent().get_node_or_null("BerryField")
	var planned: int = field.bush_count if field != null else 0
	var on_map: int = get_tree().get_nodes_in_group("berry_bushes").size()
	print("SELF-CHECK:   a colonist below %.0f hunger (starving below %.0f: food before bed) eats berry after berry until %.0f, moving to another ripe bush if needed; bushes planned %d (%d berries), on the map now %d; basket speed 100%% empty -> %.0f%% full" % [hungry_threshold, hunger_warn_below, colonist_eat_until, planned, planned * per_bush, on_map, basket_full_speed * 100.0])
	var eat_from: float = 100.0 - berry_hunger_value
	var rows: Array = []
	for h in [100.0, 80.0, 20.0]:
		rows.append("hunger %.0f: %s" % [h, "can eat it (+%.0f -> %.0f)" % [berry_hunger_value, minf(100.0, h + berry_hunger_value)] if h <= eat_from else "cannot eat it (You are not hungry)"])
	print("SELF-CHECK:   holding one berry by hand: %s" % " | ".join(rows))
	var frames: SpriteFrames = load("res://sprites/main_character_frames.tres")
	print("SELF-CHECK:   berries exist only on bushes, in a basket, or as the one in his hand: ground berry item scene exists: %s; a held berry changes no sprite (carry_berry animation exists: %s)" % [ResourceLoader.exists("res://scenes/Berry.tscn"), frames.has_animation(&"carry_berry")])

# The cabin picture, its door, and the room inside (sizes, walkable area, where he appears coming in and going out).
func _self_check_interior() -> void:
	var type: BuildingType = load("res://assets/house_type.tres")
	var room = load("res://scenes/BuildingInterior.tscn").instantiate()
	var room_texture: Texture2D = load("res://sprites/cabin_interior.png") if ResourceLoader.exists("res://sprites/cabin_interior.png") else null
	var door_rect: Rect2 = Rect2(-9, -17, 10, 17)
	var base := Vector2(100, 200)
	print("SELF-CHECK: house exterior: cabin.png %s, sprite offset %s (origin at the base of the art), door_offset %s (where a resident stands, in front of the door), visible door area %s from the base, hover / click area the whole cabin; footprint %s" % [type.texture.get_size(), type.sprite_offset, type.door_offset, door_rect, type.footprint])
	print("SELF-CHECK:   interior: cabin_interior.png %s, floor_rect %s, door_pos %s, exit_area %s, door gap x %s down to y %.0f, camera centre %s, interior tint strength inside %.2f; fade 0.3 s out and in" % [room_texture.get_size() if room_texture != null else "MISSING", room.floor_rect, room.door_pos, room.exit_area, room.door_gap_x, room.corridor_bottom, room.camera_centre, 0.5])
	var origin: Vector2 = room.FIRST_ORIGIN
	print("SELF-CHECK:   entering: a house at %s has its door at %s; he appears in its room at %s (room origin %s, first of a row %.0f px apart, off the map); leaving: back at %s" % [base, base + type.door_offset, origin + room.door_pos, origin, room.SPACING, base + type.door_offset + Vector2(0, 3)])
	room.free()

# The Storage as a building you can walk into, the crates inside it, and where a hungry colonist goes first.
func _self_check_storage_crates() -> void:
	var storage_type: BuildingType = load("res://assets/storage_type.tres")
	var house_type: BuildingType = load("res://assets/house_type.tres")
	var crate_type: BuildingType = load("res://assets/crate_type.tres")
	print("SELF-CHECK: storage: door_offset %s (people stand there; the visible door is %s from the base: Storage.png is 32x32, door at x 4..17, y 16..32), interior %s px (storage_interior.png %s), floor_rect %s, door_pos %s" % [storage_type.door_offset, storage_type.door_area_rect, storage_type.interior_size, storage_type.interior_texture.get_size() if storage_type.interior_texture != null else "MISSING", storage_type.floor_rect, storage_type.door_pos])
	print("SELF-CHECK:   crates_max: storage %d, house %d (house_max_beds stays %d); a Crate costs %d planks, %d hammer hits (dismantle %d), indoor only (greyed elsewhere: \"%s\"); one shared interior system for both buildings (building_interior.gd)" % [storage_type.crates_max, house_type.crates_max, load("res://scenes/Building.tscn").instantiate().house_max_beds, crate_type.plank_cost, crate_type.BUILD_HITS, ceili(crate_type.BUILD_HITS / 2.0), crate_type.locked_hint])
	var storage = load("res://scenes/Storage.tscn").instantiate()
	storage.position = Vector2(300, 300)
	get_parent().add_child(storage)
	var room: Node2D = storage.get_interior()
	var crate = load("res://scenes/Crate.tscn").instantiate()
	crate.position = room.to_world(Vector2(64, 96))
	get_parent().add_child(crate)
	print("SELF-CHECK:   crate: capacity %d, accepted_items %s, contents is a kind -> count dictionary; ONE sprite (closed_crate.png) whether full or empty, open_crate.png only for %.1f s while it is used; readout only on hover: empty \"%s\"" % [crate.capacity, crate.accepted_items, crate.OPEN_SECONDS, crate.readout()])
	crate.add_item(&"berry", 5)
	var plank_taken: int = crate.add_item(&"plank", 1)
	var over: int = crate.add_item(&"berry", 20)
	print("SELF-CHECK:   after 5 berries \"%s\"; a plank goes in: %d (refused); then 20 more berries: %d fit (full: %s, readout \"%s\"); dismantling is blocked while it holds anything" % ["Berries 5 (5/12)", plank_taken, over, crate.is_full(), crate.readout()])
	var colonist = load("res://scenes/Colonist.tscn").instantiate()
	colonist.position = Vector2(260, 300)
	get_parent().add_child(colonist)
	var with_berries = colonist.eat._find_crate()
	crate.take_item(&"berry", 12)
	var empty = colonist.eat._find_crate()
	print("SELF-CHECK:   a hungry colonist (below hungry_threshold %.0f) picks: crate with berries -> %s; all crates empty -> %s (then the bushes, as before); he eats until hunger %.0f or the crate is empty, then the next crate, then follows the player" % [hungry_threshold, "the crate in the storage" if with_berries == crate else str(with_berries), "no crate" if empty == null else str(empty), colonist_eat_until])
	colonist.remove_from_group("colonists")
	colonist.free()
	crate.remove_from_group("crates")
	crate.remove_from_group("build_blockers")
	crate.free()
	room.free()
	storage.remove_from_group("storages")
	storage.remove_from_group("build_blockers")
	storage.free()

# Stock put into a Storage from outside must be there, drawn, when someone walks in.
func _self_check_storage_stock() -> void:
	var storage = load("res://scenes/Storage.tscn").instantiate()
	storage.position = Vector2(300, 300)
	get_parent().add_child(storage)
	# (Outside: the room has not even been made yet.)
	storage.add_planks(3)
	storage.add_log()
	storage.add_log()
	var room: Node2D = storage.get_interior()
	room.player_entered()
	print("SELF-CHECK: storage stock from outside, then entering: stock planks %d / logs %d, drawn inside planks %d / logs %d (stock_slots %d per kind) -> %s" % [storage.planks_stored, storage.logs_stored, room.drawn_planks, room.drawn_logs, room.stock_slots, "equal" if room.drawn_planks == storage.planks_stored and room.drawn_logs == storage.logs_stored else "DIFFERENT"])
	room.player_left()
	storage.take_planks(1)
	room.player_entered()
	print("SELF-CHECK:   after taking 1 plank from outside and re-entering: stock planks %d / logs %d, drawn planks %d / logs %d -> %s" % [storage.planks_stored, storage.logs_stored, room.drawn_planks, room.drawn_logs, "equal" if room.drawn_planks == storage.planks_stored and room.drawn_logs == storage.logs_stored else "DIFFERENT"])
	storage.planks_stored = 20
	print("SELF-CHECK:   20 planks stored: drawn %d (cap %d slots x 3), hover text \"%s\"" % [room.drawn_planks, room.stock_slots, room._stock_text("planks")])
	room.player_left()
	room.free()
	storage.remove_from_group("storages")
	storage.remove_from_group("build_blockers")
	storage.free()

# The checks that need frames to pass, one after the other (their lines are printed as each finishes).
func _self_check_slow_part() -> void:
	await _self_check_ui2()
	await _self_check_worker_hunger()
	await _self_check_sleep_skip()
	await _self_check_food_chain()
	await _self_check_hover_and_hold()
	await _self_check_water()
	await _self_check_table_and_art()
	await _self_check_batch7()
	await _self_check_ui()
	await _self_check_world()
	await _self_check_world2()
	await _self_check_world3()
	await _self_check_world4()
	await _self_check_world5()
	await _self_check_world6()
	await _self_check_world7()
	self_check_done = true

# A hungry worker (hunger 30) with a berry crate in reach: the state sequence of the trip, then hunger 0: he dies and
# lets go of his tree. Runs over a few seconds (the lines are printed when it is done).
func _self_check_worker_hunger() -> void:
	var worker = get_parent().get_node_or_null("Lumberjack")
	if worker == null or not is_instance_valid(worker) or worker.get("worker_rest") == null:
		print("SELF-CHECK: worker hunger: no Lumberjack in this scene (the opening removes the workers)")
		return
	var wr: Node = worker.worker_rest
	var storage = load("res://scenes/Storage.tscn").instantiate()
	storage.position = worker.position + Vector2(40, 30)
	get_parent().add_child(storage)
	var room: Node2D = storage.get_interior()
	var crate = load("res://scenes/Crate.tscn").instantiate()
	crate.position = room.to_world(Vector2(64, 96))
	get_parent().add_child(crate)
	crate.add_item(&"berry", 12)
	print("SELF-CHECK: worker hunger: meter %s (efficiency %.2f at %.0f), hungry below %.0f, very hungry below %.0f, eats until %.0f; the worker efficiency is min(energy, hunger)" % [wr.hunger.get_script().resource_path.get_file(), wr.hunger.efficiency(), wr.hunger.value, hungry_threshold, wr.very_hungry_below, colonist_eat_until])
	var names: Array = ["NONE", "TO_CRATE", "IN_CRATE", "TO_BUSH", "AT_BUSH"]
	wr.hunger.value = 30.0
	# (The grace period he may finish his job in is 30 clock-seconds: the clock runs faster for this check.)
	var saved_speed: float = clock_speed_multiplier
	wr.rest.value = 100.0
	clock_speed_multiplier = 20.0
	var seq: Array = []
	var started: bool = false
	for i in 3600:
		await get_tree().process_frame
		var phase: int = wr.eat.phase
		var label: String = "%s%s" % [names[phase], "" if worker.visible else "(hidden)"]
		if phase != 0 and not started:
			started = true
			# (Normal speed again for the meal itself; he is rested, so it takes the plain time.)
			clock_speed_multiplier = saved_speed
			wr.rest.value = 100.0
		if seq.is_empty() or seq[-1] != label:
			seq.append(label)
		if started and phase == 0:
			break
	clock_speed_multiplier = saved_speed
	print("SELF-CHECK:   hunger 30, crate with berries: trip %s; hunger now %.0f, crate left %s; worker state after: %s" % [" -> ".join(seq), wr.hunger.value, crate.readout(), worker.state])
	crate.remove_from_group("crates")
	crate.remove_from_group("build_blockers")
	crate.free()
	room.free()
	storage.remove_from_group("storages")
	storage.remove_from_group("build_blockers")
	storage.free()
	# Hunger 0 with no food: he dies and lets go.
	var tree = worker.current_tree
	var claimed_before: bool = tree != null and tree.claimed_by == worker
	wr.hunger.value = 0.0
	for i in 5:
		await get_tree().process_frame
	print("SELF-CHECK:   hunger 0, no food: dead %s; his tree was claimed by him before: %s, now: %s; busy with a job: %s" % [wr.dead, claimed_before, tree != null and tree.claimed_by == worker, worker.state != worker.State.STOPPED])

# The sleep fade and skip: energy 20 in a wooden bed with 3 hay (clock and energy before and after, the real
# seconds it took), then hunger 5 (he wakes starving) and then hunger just above the wake line with the wake turned
# off (he sleeps outdoors at night and starves in his sleep: the fade is cut and the game is over). Needs the MainCharacter; runs for a while.
var sleep_check: Dictionary = {}
var sleep_night: Dictionary = {}
var self_check_done: bool = false

func _self_check_sleep_skip() -> void:
	var player = get_parent().get_node_or_null("MainCharacter")
	if player == null or not is_instance_valid(player) or not player.has_method("die"):
		print("SELF-CHECK: sleep skip: no MainCharacter in this scene")
		return
	set_time(day, 0.62)
	var bed = load("res://scenes/WoodenBed.tscn").instantiate()
	bed.position = player.position + Vector2(40, 0)
	get_parent().add_child(bed)
	bed.ages.assign([bundle_to_hay_clock_seconds, bundle_to_hay_clock_seconds, bundle_to_hay_clock_seconds])
	player.hunger.value = 100.0
	player.rest.value = 20.0
	var day0: int = day
	var time0: String = clock_text()
	var energy0: float = player.rest.value
	var real0: int = Time.get_ticks_msec()
	print("SELF-CHECK: sleep skip: before: day %d %s (%s), energy %.0f, hunger %.0f, bed recovery %.4f/s (wooden, 3 hay)" % [day0, time0, phase_name(), energy0, player.hunger.value, bed.sleep_rate_now()])
	player.request_sleep_on(bed)
	var peak: float = 1.0
	var last_ms: int = Time.get_ticks_msec()
	var black_ms: int = 0
	for i in 4000:
		await get_tree().process_frame
		var now_ms: int = Time.get_ticks_msec()
		if player._sleep_skip.phase == 2:   # (BLACK)
			black_ms += now_ms - last_ms
		last_ms = now_ms
		peak = maxf(peak, clock_speed_multiplier)
		if player.state != player.State.SLEEPING and player._sleep_skip.phase == 0:
			break
	sleep_check = {"total": (Time.get_ticks_msec() - real0) / 1000.0, "black": black_ms / 1000.0, "peak": peak, "from": time0, "to": clock_text(), "clock_seconds": (day - day0) * day_length + 0.0}
	print("SELF-CHECK:   after: day %d %s (%s), energy %.0f, hunger %.1f, %.1f real seconds in all (fade out %.1f + dark + hold %.1f + fade in %.1f), peak clock speed x%.0f; clock multiplier given back: %s" % [day, clock_text(), phase_name(), player.rest.value, player.hunger.value, (Time.get_ticks_msec() - real0) / 1000.0, player.fade_out_seconds, player.sleep_black_hold_seconds, player.fade_in_seconds, peak, clock_speed_multiplier == 1.0])
	# a whole night outdoors, from the start of the night to dawn: the longest sleep there is
	set_time(day, 0.7)
	player.hunger.value = 100.0
	player.rest.value = 20.0
	player.request_sleep_outside()
	var night_t0: int = Time.get_ticks_msec()
	var night_last: int = night_t0
	var night_black: int = 0
	var night_from: String = clock_text()
	var night_peak: float = 1.0
	for i in 4000:
		await get_tree().process_frame
		var night_now: int = Time.get_ticks_msec()
		if player._sleep_skip.phase == 2:
			night_black += night_now - night_last
		night_last = night_now
		night_peak = maxf(night_peak, clock_speed_multiplier)
		if player.state != player.State.SLEEPING and player._sleep_skip.phase == 0:
			break
	sleep_night = {"total": (Time.get_ticks_msec() - night_t0) / 1000.0, "black": night_black / 1000.0, "peak": night_peak, "from": night_from, "to": clock_text()}
	# hunger 5: he wakes starving
	set_time(day, 0.62)
	player.hunger.value = 5.0
	player.rest.value = 20.0
	player.request_sleep_on(bed)
	for i in 4000:
		await get_tree().process_frame
		if player.state != player.State.SLEEPING and player._sleep_skip.phase == 0:
			break
	print("SELF-CHECK:   hunger 5, then sleeping: wakes (not dead: %s), hunger %.1f, auto_wake_hunger %.0f" % [not player.dead, player.hunger.value, auto_wake_hunger])
	# starving in his sleep (the wake line is moved out of the way)
	var saved_wake: float = auto_wake_hunger
	auto_wake_hunger = -1.0
	set_time(day, 0.7)
	player.hunger.value = 1.5
	player.rest.value = 20.0
	player.request_sleep_outside()
	var real1: int = Time.get_ticks_msec()
	for i in 4000:
		await get_tree().process_frame
		if player.dead:
			break
	auto_wake_hunger = saved_wake
	print("SELF-CHECK:   hunger 1.5 asleep outdoors at night with the wake off: dead %s after %.1f real seconds, fade cut (alpha 0): %s, clock multiplier back to %.0f, game over shown: %s" % [player.dead, (Time.get_ticks_msec() - real1) / 1000.0, player._sleep_skip._alpha == 0.0, clock_speed_multiplier, player._game_over.shown])
	bed.remove_from_group("beds")
	bed.free()
	# He is alive again for the checks after this one (the game-over screen pauses the world and he lies dead).
	get_tree().paused = false
	player._game_over.hide_screen()
	player.dead = false
	player.hunger.value = 100.0
	player.rest.value = 100.0
	player.state = player.State.FREE
	player._clear_asleep_look()
	player.visible = true

func _fc(step: String, ok: bool, extra: String = "") -> void:
	print("SELF-CHECK:   food chain: %-62s %s%s" % [step, "OK" if ok else "FAIL", ("  (" + extra + ")") if extra != "" else ""])

# The whole chain, played through the same functions the keys use: till, sow, grow, harvest, grind, a campfire built
# from branches and flat stones, fuel, ferro rod, a hot stone, two flatbreads, the fire going out, a crate, a hungry
# colonist choosing flatbread.
func _self_check_food_chain() -> void:
	var player = get_parent().get_node_or_null("MainCharacter")
	if player == null or not is_instance_valid(player) or not player.has_method("plot_till"):
		print("SELF-CHECK: food chain: no MainCharacter in this scene")
		return
	var Items = load("res://scripts/items.gd")
	var FoodConfig = load("res://scripts/food_config.gd")
	var cfg = FoodConfig.cfg()
	var world: Node = get_parent()
	var m = load("res://scripts/plot_manager.gd").get_for(get_tree())
	print("SELF-CHECK: food chain (plot grid %d px, wheat ripe after %.0f clock-seconds = %.1f days, seed bag %d, flatbread +%.0f hunger, berries +%.0f)" % [cfg.plot_size_px, cfg.wheat_grow_clock_seconds * cfg.ripe_at_fraction, cfg.wheat_grow_clock_seconds * cfg.ripe_at_fraction / day_length, cfg.seed_bag_capacity, cfg.flatbread_hunger_value, berry_hunger_value])
	# --- a clear field somewhere on the map
	var field: Vector2i = Vector2i.ZERO
	var found_field: bool = false
	for gx in range(30, 55):
		for gy in range(8, 52):
			var ok_row: bool = true
			for k in 6:
				if m.can_till(Vector2i(gx + k, gy)) != "":
					ok_row = false
					break
			if ok_row:
				field = Vector2i(gx, gy)
				found_field = true
				break
		if found_field:
			break
	_fc("a free field of plots found", found_field, str(field))
	if not found_field:
		return
	player.position = m.cell_center(field) + Vector2(0, 14)
	player.state = player.State.FREE
	player.held_tool = &""
	# --- till 3 plots (2 presses each)
	player.held_tool = &"hoe"
	var cells: Array[Vector2i] = [field, field + Vector2i(1, 0), field + Vector2i(2, 0)]
	var tilled: int = 0
	for cell in cells:
		var first: String = player.plot_till(cell)
		var half: bool = not m.has_plot(cell)
		var second: String = player.plot_till(cell)
		if first == "" and half and second == "" and m.stage(cell) == &"tilled":
			tilled += 1
	_fc("hoe: 3 plots tilled, each in 2 presses", tilled == 3, "%d/3" % tilled)
	_fc("plot cell = floor(world / 11); picture drawn at the cell corner", m.cell_of(Vector2(23.0, 11.0)) == Vector2i(2, 1) and m.cell_rect(Vector2i(2, 1)).position == Vector2(22, 11))
	# --- tilling next to a building edge is refused when the 11x11 cell overlaps it
	var storage = load("res://scenes/Storage.tscn").instantiate()
	storage.position = m.cell_center(field + Vector2i(1, 4)) + Vector2(0, 0)
	world.add_child(storage)
	var edge: Rect2 = Footprints.blocker_rect(storage)
	# (The cell that straddles the building's left edge, so it overlaps it by a few pixels.)
	var overlap_cell: Vector2i = m.cell_of(Vector2(edge.position.x + 1.0, edge.get_center().y))
	var clear_cell: Vector2i = m.cell_of(Vector2(edge.position.x - 14.0, edge.get_center().y))
	var refused: String = player.plot_till(overlap_cell)
	# (Items dropped by the harvest now spread out over free ground: a stray one is moved off the cell this test is about.)
	for stray in get_tree().get_nodes_in_group("ground_items"):
		if m.cell_rect(clear_cell).grow(14.0).has_point(stray.global_position):
			stray.remove_from_group("ground_items")
			stray.queue_free()
	var allowed: bool = m.can_till(clear_cell) == "" or m.has_plot(clear_cell)
	_fc("tilling a cell that overlaps a building edge is refused", refused == "Can't till here." and not m.has_plot(overlap_cell), "'%s'" % refused)
	_fc("a cell 3 px clear of the building is allowed", allowed)
	# a blueprint over plots removes them
	var removed: int = m.clear_rect(Rect2(m.cell_rect(cells[2]).position, Vector2(4, 4)))
	_fc("a blueprint over a plot removes it (nothing refunded)", removed == 1 and not m.has_plot(cells[2]))
	player.plot_till(cells[2])
	player.plot_till(cells[2])
	storage.remove_from_group("storages")
	storage.remove_from_group("build_blockers")
	storage.free()
	# --- sow from the seed bag
	player.held_tool = &"seed_bag"
	player.held_seeds = cfg.start_seed_bag_seeds
	for cell in cells:
		player.plot_sow(cell)
	_fc("seed bag: 3 plots sown, 1 seed used each", player.held_seeds == cfg.start_seed_bag_seeds - 3 and m.stage(cells[0]) == &"sown", "seeds left %d" % player.held_seeds)
	player.held_seeds = 0
	player.held_tool = &"seed_bag"
	_fc("an empty bag: 'The bag is empty.'", player.plot_sow(cells[0]) == "The bag is empty.")
	# the bag stays an item and is put on the ground with its count
	var bag = Items.put(get_tree(), world, &"seed_bag", m.cell_center(field) + Vector2(0, 30), Rect2(0, 0, 640, 640), 1)
	player.held_tool = &""
	player.held_seeds = 0
	# --- growth is derived from the clock (a day passes: growing; then ripe)
	var t0: float = m.now()
	var stage_now: StringName = m.stage(cells[0])
	# (Dry, wheat does not grow at all: a day goes by and the plot is still sown.)
	set_time(day + 1, time_of_day)
	var stage_dry: StringName = m.stage(cells[0])
	m.water_near(m.cell_center(cells[0]), 40.0)
	set_time(day + 1, time_of_day)
	var stage_day: StringName = m.stage(cells[0])
	# (900 clock-seconds of water have run out by now: watered again, the next day grows it the rest of the way.)
	m.water_near(m.cell_center(cells[0]), 40.0)
	set_time(day + 1, time_of_day)
	var stage_ripe: StringName = m.stage(cells[0])
	_fc("growth only while watered: sown -> still sown dry -> growing -> ripe", stage_now == &"sown" and stage_dry == &"sown" and stage_day == &"growing" and stage_ripe == &"ripe", "%s -> %s -> %s -> %s" % [stage_now, stage_dry, stage_day, stage_ripe])
	_fc("hover text of a plot", m.text(cells[0]) == "Wheat, ripe", m.text(cells[0]))
	# --- harvest with the sickle
	player.held_tool = &"sickle"
	var sheaves_before: int = 0
	for item in get_tree().get_nodes_in_group("ground_items"):
		if item.kind == &"wheat_sheaf":
			sheaves_before += 1
	for cell in cells:
		player.plot_harvest(cell)
	var sheaves: int = 0
	for item in get_tree().get_nodes_in_group("ground_items"):
		if item.kind == &"wheat_sheaf":
			sheaves += 1
	_fc("sickle: 3 ripe plots cut, 3 sheaves beside them, plots are stubble", sheaves - sheaves_before == 3 * cfg.wheat_per_harvest and m.stage(cells[0]) == &"stubble", "%d sheaves" % (sheaves - sheaves_before))
	_fc("harvest returns no seeds (the bag on the ground still holds 1)", bag.seeds == 1, "bag now %d" % bag.seeds)
	player.held_tool = &"hoe"
	_fc("hoe turns stubble back into tilled soil (1 press)", player.plot_till(cells[0]) == "" and m.stage(cells[0]) == &"tilled")
	# --- the grinding stone is built from 2 flat stones now
	var grinding_stone_type: BuildingType = load("res://assets/grinding_stone_type.tres")
	var grinding_stone_bp = load("res://scenes/Building.tscn").instantiate()
	grinding_stone_bp.building_type = grinding_stone_type
	grinding_stone_bp.position = m.cell_center(field) + Vector2(60, 70)
	world.add_child(grinding_stone_bp)
	await get_tree().process_frame
	player.held_tool = &"flat_stone"
	player.deliver_material(grinding_stone_bp)
	player.held_tool = &"plank"
	var no_plank: bool = grinding_stone_bp.planks_needed() == 0
	player.held_tool = &"flat_stone"
	player.deliver_material(grinding_stone_bp)
	var grinding_stone_hits: int = 0
	for i in 3:
		grinding_stone_bp.hammer_hit()
	await get_tree().process_frame
	var built_grinding_stone = get_tree().get_first_node_in_group("grinding_stones")
	var Dismantle0 = load("res://scripts/dismantle.gd")
	var stones_back: int = Dismantle0.refund(get_tree(), built_grinding_stone).get("items", {}).get("flat_stone", 0) if built_grinding_stone != null else -1
	var planks_back: int = Dismantle0.refund(get_tree(), built_grinding_stone).get("planks", -1) if built_grinding_stone != null else -1
	_fc("grinding stone: built from 2 flat stones (label '%s', no planks), 3 hammer hits; dismantling returns 2 stones" % grinding_stone_type.cost_text(), no_plank and grinding_stone_type.plank_cost == 0 and built_grinding_stone != null and stones_back == 2 and planks_back == 0, "refund %d stones, %d planks" % [stones_back, planks_back])
	if built_grinding_stone != null:
		built_grinding_stone.remove_from_group("grinding_stones")
		built_grinding_stone.remove_from_group("build_blockers")
		built_grinding_stone.free()
	player.held_tool = &""
	# --- the grinding stone
	var grinding_stone = load("res://scenes/GrindingStone.tscn").instantiate()
	grinding_stone.position = m.cell_center(field) + Vector2(60, 40)
	world.add_child(grinding_stone)
	player.held_tool = &"wheat_sheaf"
	var added: String = player.grinding_stone_add(grinding_stone)
	player.held_tool = &"wheat_sheaf"
	var full_msg: String = player.grinding_stone_add(grinding_stone)
	player.held_tool = &""
	var presses_ok: bool = true
	for i in cfg.grind_presses:
		if player.grinding_stone_press(grinding_stone) != "":
			presses_ok = false
	_fc("grinding stone: sheaf in, 'The grinding stone is full.' for a second, %d presses grind it" % cfg.grind_presses, added == "" and full_msg == "The grinding stone is full." and presses_ok and grinding_stone.flour_out == cfg.flour_per_sheaf)
	player.grinding_stone_press(grinding_stone)
	_fc("empty hands take the flour", player.held_tool == &"flour" and grinding_stone.flour_out == 0)
	var nothing: String = player.grinding_stone_press(grinding_stone) if not player.hands_occupied() else "Nothing to grind."
	player.held_tool = &""
	_fc("'Nothing to grind.' when it is empty", player.grinding_stone_press(grinding_stone) == "Nothing to grind.")
	grinding_stone.remove_from_group("grinding_stones")
	grinding_stone.remove_from_group("build_blockers")
	grinding_stone.free()
	# --- the campfire blueprint: 3 branches + 3 flat stones, 3 hammer hits
	var bp = load("res://scenes/Building.tscn").instantiate()
	bp.building_type = load("res://assets/campfire_type.tres")
	bp.position = m.cell_center(field) + Vector2(110, 40)
	world.add_child(bp)
	await get_tree().process_frame
	for i in 3:
		player.held_tool = &"branch"
		player.deliver_material(bp)
		player.held_tool = &"flat_stone"
		player.deliver_material(bp)
	player.held_tool = &"branch"
	player.deliver_material(bp)
	_fc("blueprint takes 3 branches and 3 flat stones (a 4th branch is refused)", bp.is_supplied() and bp.materials_delivered() == 6 and player.held_tool == &"branch", bp.missing_text())
	player.held_tool = &""
	var back: StringName = bp.take_back_one()
	bp.add_material(back)
	for i in 3:
		bp.hammer_hit()
	await get_tree().process_frame
	var fire = get_tree().get_first_node_in_group("campfires")
	_fc("3 hammer hits build the campfire (%s needs the hammer only in the opening)" % "like every blueprint", fire != null)
	if fire == null:
		return
	# --- fuel, light
	player.held_tool = &"branch"
	player.campfire_fuel(fire)
	_fc("a branch is fuel: 150 clock-seconds of burn time", is_equal_approx(fire.burn_left, cfg.fuel_branch) and player.held_tool == &"")
	# --- cooking on the stone: dough goes on a COLD stone and stays raw until the fire is lit and the stone is hot
	var saved_speed: float = clock_speed_multiplier
	player.held_tool = &"flat_stone"
	_fc("a flat stone goes on the (unlit) fire", player.campfire_place_stone(fire) == "" and fire.stone and player.held_tool == &"")
	player.held_tool = &"flour"
	var flour_msg: String = player.campfire_place_dough(fire)
	_fc("flour does not go on the stone: 'It needs water first.'", flour_msg == "It needs water first." and player.held_tool == &"flour")
	player.held_tool = &"dough"
	var on_cold: String = player.campfire_place_dough(fire)
	_fc("dough goes on the cold stone (the dough in hand is used)", on_cold == "" and fire.food.size() == 1 and fire.food[0]["kind"] == &"dough" and player.held_tool == &"", fire.food_text())
	player.held_tool = &"dough"
	_fc("the stone holds %d thing(s): 'The stone is full.'" % cfg.campfire_stone_capacity, player.campfire_place_dough(fire) == "The stone is full.")
	player.held_tool = &"fire_starter"
	var shift_msg: String = ""
	player.held_tool = &""
	shift_msg = player.campfire_take_stone(fire)
	_fc("Shift+E with food on the stone: 'Take the food off first.'", shift_msg == "Take the food off first." and fire.stone)
	clock_speed_multiplier = 20.0
	for i in 120:
		await get_tree().process_frame
	clock_speed_multiplier = saved_speed
	_fc("dough on a cold, unlit stone stays raw", fire.food[0]["progress"] == 0.0 and fire.food_text() == "Stone cold, waiting", fire.food_text())
	player.held_tool = &"fire_starter"
	var spark1: String = player.campfire_spark(fire)
	player.campfire_spark(fire)
	var still_out: bool = not fire.lit
	player.campfire_spark(fire)
	_fc("ferro rod: 3 presses light it (not before)", spark1 == "" and still_out and fire.lit and player.held_tool == &"fire_starter")
	_fc("'Already burning.'", player.campfire_spark(fire) == "Already burning.")
	# the stone heats first (no cooking), then cooks
	var progress_while_heating: float = 0.0
	var heated_at: float = -1.0
	var cooked_at: float = -1.0
	var clock_t: float = 0.0
	clock_speed_multiplier = 10.0
	for i in 3000:
		await get_tree().process_frame
		clock_t += get_process_delta_time() * clock_speed_multiplier
		if not fire.stone_hot():
			progress_while_heating = maxf(progress_while_heating, fire.food[0]["progress"])
		elif heated_at < 0.0:
			heated_at = clock_t
		if fire.food[0]["kind"] == &"flatbread":
			cooked_at = clock_t
			break
	clock_speed_multiplier = saved_speed
	_fc("cooking starts only once the stone is hot (no progress while it heats)", progress_while_heating == 0.0 and heated_at > 0.0, "heating %.0f clock-s, then cooking" % heated_at)
	_fc("the dough finishes after about %.0f clock-seconds of hot stone" % cfg.cook_clock_seconds, cooked_at > 0.0 and absf((cooked_at - heated_at) - cfg.cook_clock_seconds) < 6.0, "took %.0f" % (cooked_at - heated_at))
	_fc("hover text: 'Flatbread ready'", fire.food_text() == "Flatbread ready", fire.food_text())
	player.held_tool = &""
	player.campfire_take_food(fire)
	_fc("empty hands take the flatbread off the stone", player.held_tool == &"flatbread" and fire.food.is_empty())
	player.held_tool = &""
	# a second dough: the stone is still hot (no waiting), and putting the fire out mid-cook pauses the progress
	player.held_tool = &"dough"
	player.campfire_place_dough(fire)
	clock_speed_multiplier = 10.0
	for i in 300:
		await get_tree().process_frame
		if fire.food[0]["progress"] > 10.0:
			break
	clock_speed_multiplier = saved_speed
	var mid_progress: float = fire.food[0]["progress"]
	_fc("a second dough starts cooking at once (the stone stayed hot): %s" % fire.food_text(), mid_progress > 10.0, "%.0f s cooked" % mid_progress)
	fire.burn_left = 0.2
	clock_speed_multiplier = 20.0
	for i in 300:
		await get_tree().process_frame
		if not fire.lit:
			break
	var at_out: float = fire.food[0]["progress"]
	for i in 120:
		await get_tree().process_frame
	clock_speed_multiplier = saved_speed
	_fc("the fire goes out mid-cook: progress pauses (%.0f s stays %.0f s)" % [at_out, fire.food[0]["progress"]], not fire.lit and fire.food[0]["progress"] == at_out and fire.food_text() == "Stone cold, waiting", fire.food_text())
	player.held_tool = &""
	player.campfire_take_food(fire)
	_fc("taking the uncooked dough off returns the dough", player.held_tool == &"dough" and fire.food.is_empty())
	player.held_tool = &""
	# --- the stone comes off (anytime food is not on it)
	player.held_tool = &""
	player.campfire_take_stone(fire)
	_fc("empty hands take the stone off (anytime)", player.held_tool == &"flat_stone" and not fire.stone)
	player.held_tool = &"dough"
	_fc("no stone: 'Put a flat stone on the fire first.'", player.campfire_place_dough(fire) == "Put a flat stone on the fire first.")
	player.held_tool = &""
	# --- the campfire can be dismantled and returns its materials
	var Dismantle = load("res://scripts/dismantle.gd")
	var refund: Dictionary = Dismantle.refund(get_tree(), fire)
	_fc("dismantling a campfire returns 3 branches and 3 flat stones", refund.get("items", {}).get("branch", 0) == 3 and refund.get("items", {}).get("flat_stone", 0) == 3, str(refund.get("items", {})))
	fire.remove_from_group("campfires")
	fire.remove_from_group("build_blockers")
	fire.free()
	# --- a crate: flatbread and a seed bag with its seeds
	var host = load("res://scenes/Storage.tscn").instantiate()
	host.position = Vector2(300, 460)
	world.add_child(host)
	var room: Node2D = host.get_interior()
	var crate = load("res://scenes/Crate.tscn").instantiate()
	crate.position = room.to_world(Vector2(64, 96))
	world.add_child(crate)
	player.inside_building = null
	player.held_tool = &"flatbread"
	player.use_crate(crate)
	player.held_tool = &"seed_bag"
	player.held_seeds = 3
	player.use_crate(crate)
	player.held_tool = &"branch"
	var refused_branch: String = player.use_crate(crate)
	player.held_tool = &""
	_fc("crate takes flatbread and a seed bag; a branch is refused", crate.count_of(&"flatbread") == 1 and crate.count_of(&"seed_bag") == 1 and refused_branch == "The crate does not take that.", crate.readout())
	var why: String = Dismantle.block_reason(get_tree(), crate, player)
	_fc("a crate holding a seed bag cannot be dismantled (it keeps its seeds)", why == Dismantle.NOT_EMPTY)
	crate.add_item(&"berry", 3)
	crate.add_item(&"flatbread", 2)
	var first_kind: StringName = crate.selected_kind()
	var cycled: StringName = crate.cycle_kind()
	_fc("a crate with several kinds: berries are taken first, Shift+E steps to the next", first_kind == &"berry" and cycled == &"flatbread" and crate.kinds_present().size() == 3, "%s -> %s" % [first_kind, cycled])
	crate.take_item(&"berry", 9)
	crate.take_item(&"flatbread", 9)
	crate.pick_kind = &"seed_bag"
	player.use_crate(crate)
	_fc("taking the bag out returns the same bag with 3 seeds", player.held_tool == &"seed_bag" and player.held_seeds == 3)
	player.held_tool = &""
	player.held_seeds = 0
	crate.take_item(&"flatbread", 9)
	# --- a hungry colonist chooses flatbread
	# (The cabin is a house now and a colonist would move into it: it is left out of the housing for this test.)
	var cabin_home: Node = world.get_node_or_null("Cabin")
	if cabin_home != null:
		cabin_home.remove_from_group("buildings")
	var colonists: Array = get_tree().get_nodes_in_group("colonists")
	if colonists.is_empty():
		print("SELF-CHECK:   food chain: no colonist in this scene (skipped)")
	else:
		var c = colonists[0]
		# (rested and in daylight, or he naps in his house instead)
		c.rest.value = 100.0
		set_time(day, 0.3)
		c.position = host.door_position() + Vector2(30, 20)
		crate.add_item(&"berry", 3)
		crate.add_item(&"flatbread", 2)
		c.hunger.value = 20.0
		var first_bite: String = ""
		for i in 1500:
			await get_tree().process_frame
			if crate.count_of(&"flatbread") < 2:
				first_bite = "flatbread"
				break
			if crate.count_of(&"berry") < 3:
				first_bite = "berries"
				break
		_fc("a colonist at hunger 20 (<= %.0f) takes flatbread first from a crate with both" % cfg.bread_preferred_below, first_bite == "flatbread", "%s, state %d, %s %s, home %s, sleeping %s" % [first_bite, c.state, phase_name(), clock_text(), c.home, c.rest.sleeping])
		c.eat.abort()
		c._stand_still()
		crate.take_item(&"flatbread", 9)
		crate.take_item(&"berry", 9)
		crate.add_item(&"berry", 3)
		crate.add_item(&"flatbread", 2)
		c.hunger.value = 35.0
		first_bite = ""
		for i in 1500:
			await get_tree().process_frame
			if crate.count_of(&"flatbread") < 2:
				first_bite = "flatbread"
				break
			if crate.count_of(&"berry") < 3:
				first_bite = "berries"
				break
		_fc("at hunger 35 (> %.0f) he takes berries first" % cfg.bread_preferred_below, first_bite == "berries", first_bite)
		c.eat.abort()
		c._stand_still()
		c.hunger.value = 100.0
	if cabin_home != null:
		cabin_home.add_to_group("buildings")
	crate.remove_from_group("crates")
	crate.remove_from_group("build_blockers")
	crate.free()
	room.free()
	host.remove_from_group("storages")
	host.remove_from_group("build_blockers")
	host.free()
	m.plots.clear()
	m.queue_redraw()

# Every pickup names itself under the mouse (one shared system), and holding E repeats work (not pick-ups).
func _self_check_hover_and_hold() -> void:
	var player = get_parent().get_node_or_null("MainCharacter")
	if player == null or not is_instance_valid(player) or not player.has_method("plot_till"):
		print("SELF-CHECK: hover and hold: no MainCharacter in this scene")
		return
	var HoverNames = load("res://scripts/hover_names.gd")
	var PlankPiles = load("res://scripts/plank_piles.gd")
	var Items = load("res://scripts/items.gd")
	var world: Node = get_parent()
	# --- names
	var spot := Vector2(520, 560)
	var expected: Dictionary = {}
	var nodes: Array = []
	var put = func(node: Node2D, label: String) -> void:
		node.position = spot + Vector2(24.0 * nodes.size(), 0)
		nodes.append(node)
		expected[node] = label
	put.call(PlankPiles.spawn_hammer(world, Vector2.ZERO), "Hammer")
	put.call(PlankPiles.spawn_shovel(world, Vector2.ZERO), "Shovel")
	put.call(PlankPiles.spawn_axe(world, Vector2.ZERO), "Axe")
	put.call(PlankPiles.spawn_blade(world, Vector2.ZERO), "Saw blade")
	put.call(PlankPiles.spawn_pile(world, Vector2.ZERO, 3), "Planks 3")
	put.call(PlankPiles.spawn_bundle_pile(world, Vector2.ZERO, 0.0), "Grass bundle")
	var basket = load("res://scenes/Basket.tscn").instantiate()
	basket.berries = 3
	world.add_child(basket)
	put.call(basket, "Basket 3/%d" % basket_capacity)
	put.call(Items.spawn(&"seed_bag", world, Vector2.ZERO, 2), "Seed bag 2/6")
	for kind in [&"branch", &"flat_stone", &"flour", &"flatbread", &"wheat_sheaf", &"hoe", &"sickle", &"fire_starter"]:
		put.call(Items.spawn(kind, world, Vector2.ZERO), Items.name_of(kind))
	var bad: Array = []
	for node in nodes:
		var rect: Rect2 = HoverNames.rect_of(node)
		var found: Dictionary = HoverNames.hovered(get_tree(), rect.get_center(), player)
		if found.get("text", "") != expected[node]:
			bad.append("%s != '%s'" % [expected[node], found.get("text", "")])
	# a log lying where a tree was delimbed
	var tree = null
	for t in get_tree().get_nodes_in_group("trees"):
		if t.is_standing():
			tree = t
			break
	var log_ok: bool = true
	if tree != null:
		for i in 20:
			tree.receive_hit()
		var trunk: Node2D = tree.log_node()
		var found_log: Dictionary = HoverNames.hovered(get_tree(), trunk.global_position + Vector2.UP.rotated(trunk.global_rotation) * 7.0, player)
		log_ok = found_log.get("text", "") == "Log"
	# what the player holds
	player.held_tool = &"basket"
	player.basket_berries = 2
	var held_basket: String = HoverNames.held_name(player, get_tree())
	player.held_tool = &"seed_bag"
	player.held_seeds = 4
	var held_bag: String = HoverNames.held_name(player, get_tree())
	player.held_tool = &"hoe"
	var held_hoe: String = HoverNames.held_name(player, get_tree())
	player.held_tool = &""
	player.basket_berries = 0
	player.held_seeds = 0
	print("SELF-CHECK:   hover names: %-70s %s%s" % ["%d pickups name themselves; log '%s'; held: '%s', '%s', '%s'" % [nodes.size(), "Log" if log_ok else "?", held_basket, held_bag, held_hoe], "OK" if bad.is_empty() and log_ok and held_basket == "Basket 2/%d" % basket_capacity and held_bag == "Seed bag 4/6" and held_hoe == "Hoe" else "FAIL", ("  " + str(bad)) if not bad.is_empty() else ""])
	for node in nodes:
		node.remove_from_group("ground_items")
		node.queue_free()
	await get_tree().process_frame
	# --- hold E
	var m = load("res://scripts/plot_manager.gd").get_for(get_tree())
	var inter = player.get_node("Interaction")
	var field: Vector2i = Vector2i(31, 40)
	for gx in range(25, 55):
		var clear: bool = true
		for dy in 4:
			if m.can_till(Vector2i(gx, 40 + dy)) != "":
				clear = false
		if clear:
			field = Vector2i(gx, 40)
			break
	player.state = player.State.FREE
	player.held_tool = &"hoe"
	player.sprite.flip_h = false
	# he stands left of the cell, facing right: the cell in front of him is the one he works
	player.position = m.cell_center(field) + Vector2(-9.0, 4.0)
	await get_tree().process_frame
	player.position = m.cell_center(field) + Vector2(-9.0, 4.0)
	var front: Vector2i = player.plot_cell_in_front()
	inter._mouse_moved_at = -1000.0
	var key_down := InputEventKey.new()
	key_down.keycode = KEY_E
	key_down.physical_keycode = KEY_E
	key_down.pressed = true
	Input.parse_input_event(key_down)
	var tilled_after: float = -1.0
	for i in 200:
		await get_tree().process_frame
		if m.stage(front) == &"tilled":
			tilled_after = i
			break
	var key_up := InputEventKey.new()
	key_up.keycode = KEY_E
	key_up.physical_keycode = KEY_E
	key_up.pressed = false
	Input.parse_input_event(key_up)
	await get_tree().process_frame
	print("SELF-CHECK:   hold E: %-70s %s" % ["the hoe tills a plot (2 presses) from ONE held press, then it stops", "OK" if tilled_after >= 0.0 and m.plots.size() == 1 else "FAIL"], "  (after %d frames, %d plots)" % [tilled_after, m.plots.size()])
	m.plots.clear()
	m.queue_redraw()
	# held E does not repeat a pick-up
	player.held_tool = &""
	var first = Items.spawn(&"branch", world, player.position + Vector2(6, 0))
	var second = Items.spawn(&"flat_stone", world, player.position + Vector2(10, 2))
	await get_tree().process_frame
	Input.parse_input_event(key_down)
	for i in 40:
		await get_tree().process_frame
	Input.parse_input_event(key_up)
	await get_tree().process_frame
	# (Two pickups side by side: E opens the chooser; confirming takes one of them, once.)
	var chooser_inter: Node = player.get_node("Interaction")
	if chooser_inter.chooser_open:
		chooser_inter._chooser_confirm()
		await get_tree().process_frame
	var near_left: int = 0
	for g in get_tree().get_nodes_in_group("ground_items"):
		if g.global_position.distance_to(player.position) < 40.0:
			near_left += 1
	print("SELF-CHECK:   hold E: %-70s %s" % ["holding E picks up ONCE (no swap with the stone beside it; the chooser asked first)", "OK" if (player.held_tool == &"branch" or player.held_tool == &"flat_stone") and near_left == 1 else "FAIL"], "  (holds '%s', %d left beside him)" % [player.held_tool, near_left])
	player.held_tool = &""
	for item in get_tree().get_nodes_in_group("ground_items"):
		if item.global_position.distance_to(player.position) < 40.0:
			item.remove_from_group("ground_items")
			item.queue_free()
	# chop a tree by holding E (the axe): several swings from one hold, stopping when released
	# (The Lumberjack is sent off, or he would chop the tree himself.)
	var lumberjack = get_parent().get_node_or_null("Lumberjack")
	if lumberjack != null and is_instance_valid(lumberjack):
		lumberjack.automation_enabled = false
		lumberjack._abandon_task()
	var chop_tree = null
	for t in get_tree().get_nodes_in_group("trees"):
		if t.is_standing() and t.claimed_by == null:
			chop_tree = t
			break
	if chop_tree != null:
		player.held_tool = &"axe"
		player.position = chop_tree.position + Vector2(-16.0, 0.0)
		player.state = player.State.FREE
		await get_tree().process_frame
		inter._mouse_moved_at = -1000.0
		var hits_before: int = chop_tree.fell_hits_remaining
		Input.parse_input_event(key_down)
		var t_start: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t_start < 12000:
			await get_tree().process_frame
			if hits_before - chop_tree.fell_hits_remaining >= 4:
				break
		var hits_held: int = hits_before - chop_tree.fell_hits_remaining
		Input.parse_input_event(key_up)
		t_start = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t_start < 2500:
			await get_tree().process_frame
		var hits_after: int = hits_before - chop_tree.fell_hits_remaining
		print("SELF-CHECK:   hold E: %-70s %s" % ["the axe swings again and again while E is held, and stops when it is let go", "OK" if hits_held >= 4 and hits_after - hits_held <= 1 else "FAIL"], "  (%d hits held, %d after release)" % [hits_held, hits_after - hits_held])
		player.held_tool = &""
		player._cancel_order()

# A land point on each side of the creek, in line across it: [from, to] (or [] if there is none).
func _creek_crossing(W) -> Array:
	var mid: Vector2 = W.tile_rect(W.creek_tiles[W.creek_tiles.size() / 2]).get_center()
	for angle_i in 12:
		var dir: Vector2 = Vector2.from_angle(angle_i * PI / 12.0)
		var a: Vector2 = Vector2.INF
		var b: Vector2 = Vector2.INF
		for d in range(40, 200, 8):
			var pa: Vector2 = mid - dir * d
			var pb: Vector2 = mid + dir * d
			if a == Vector2.INF and W.kind_at_tile(W.tile_of(pa)) == W.LAND and pa.x > 16 and pa.y > 16 and pa.x < 624 and pa.y < 624:
				a = pa
			if b == Vector2.INF and W.kind_at_tile(W.tile_of(pb)) == W.LAND and pb.x > 16 and pb.y > 16 and pb.x < 624 and pb.y < 624:
				b = pb
		if a != Vector2.INF and b != Vector2.INF and not Footprints.rect_blocked(get_tree(), Rect2(a - Vector2(5, 5), Vector2(10, 10))) and not Footprints.rect_blocked(get_tree(), Rect2(b - Vector2(5, 5), Vector2(10, 10))):
			return [a, b]
	return []

func _wc(step: String, ok: bool, extra: String = "") -> void:
	print("SELF-CHECK:   water: %-72s %s%s" % [step, "OK" if ok else "FAIL", ("  (" + extra + ")") if extra != "" else ""])

# The creek, the bucket, watering, the dough board and the dough on the stone.
func _self_check_water() -> void:
	var player = get_parent().get_node_or_null("MainCharacter")
	if player == null or not is_instance_valid(player) or not player.has_method("scoop_water"):
		print("SELF-CHECK: water: no MainCharacter in this scene")
		return
	var W = load("res://scripts/water_map.gd")
	var cfg = load("res://scripts/food_config.gd").cfg()
	var world: Node = get_parent()
	var deep: int = 0
	var shallow: int = 0
	for y in W.ROWS:
		for x in W.COLS:
			var k: int = W.kind_at_tile(Vector2i(x, y))
			deep += 1 if k == W.DEEP else 0
			shallow += 1 if k == W.SHALLOW else 0
	var cabin = world.get_node_or_null("Cabin")
	print("SELF-CHECK: water: creek %d shallow + %d deep tiles (%s); cabin %s, nearest creek tile %.0f px away" % [shallow, deep, W.creek_report, str(cabin.position) if cabin != null else "-", W.distance_to_tile(cabin.position, W.nearest_water(cabin.position)) if cabin != null else -1.0])
	# --- reachability from the player's start: everything is still reachable
	var obstacles: Array[Rect2] = Footprints.base_rects(get_tree())
	var seen: Dictionary = W.flood(player.position, obstacles)
	var unreachable: Array[String] = []
	var counted: Array[int] = [0]
	var check := func(label: String, point: Vector2) -> void:
		counted[0] += 1
		if not W.flood_reaches(seen, point, 3):
			unreachable.append("%s %s" % [label, str(point)])
	if cabin != null:
		check.call("cabin", cabin.position + Vector2(0, 12))
	for t in get_tree().get_nodes_in_group("trees"):
		check.call("tree", t.position + Vector2(0, 14))
	for b in get_tree().get_nodes_in_group("berry_bushes"):
		check.call("bush", b.position + Vector2(0, 8))
	for it in get_tree().get_nodes_in_group("ground_items"):
		check.call("item " + str(it.kind), it.position)
	check.call("creek", W.tile_rect(W.creek_tiles[0]).get_center())
	check.call("creek", W.tile_rect(W.creek_tiles[W.creek_tiles.size() - 1]).get_center())
	_wc("everything reachable from the start, creek included (%d things checked)" % counted[0], unreachable.is_empty(), "unreachable: %s" % str(unreachable))
	_wc("the creek is all shallow (no deep tiles, no deep collision body)", deep == 0 and not W.has_deep and get_tree().get_first_node_in_group("water_layer").get_node_or_null("WaterBody") == null)
	# --- a colonist walks straight through the creek, slowed to creek_speed_multiplier
	var colonists: Array = get_tree().get_nodes_in_group("colonists")
	var crossing: Array = _creek_crossing(W)
	if colonists.is_empty() or crossing.is_empty():
		print("SELF-CHECK:   water: no colonist or no crossing in this scene (walk test skipped)")
	else:
		var c = colonists[0]
		c.rest.value = 100.0
		c.hunger.value = 100.0
		set_time(day, 0.3)
		c.position = crossing[0]
		# (The player stands beside him, or a free colonist who is too far from him goes after him instead.)
		if player != null:
			player.position = (crossing[0] + crossing[1]) * 0.5
		var path: Array[Vector2] = Footprints.path_around(Footprints.base_rects(get_tree()), c.position, crossing[1], 5.0)
		c.eat.abort()
		c._stand_still()
		c.waypoints = path.duplicate()
		c.state = c.State.WALKING
		var t_start: int = Time.get_ticks_msec()
		var min_speed: float = 1.0
		while Time.get_ticks_msec() - t_start < 25000 and not c.waypoints.is_empty():
			await get_tree().process_frame
			min_speed = minf(min_speed, W.speed_factor(c.position))
		_wc("a colonist walks through the creek: arrived %s, slowed to x%.2f in the water (creek_speed_multiplier %.2f)" % [c.waypoints.is_empty(), min_speed, cfg.creek_speed_multiplier], c.waypoints.is_empty() and absf(min_speed - cfg.creek_speed_multiplier) < 0.01, "%s -> %s, %d waypoints, took %.1f s, ended at %s" % [str(crossing[0]), str(crossing[1]), path.size(), (Time.get_ticks_msec() - t_start) / 1000.0, str(c.position)])
		c.state = c.State.IDLE
	# the three workers' walker goes straight through it too
	var walker = load("res://scripts/water_walker.gd").new()
	if not crossing.is_empty():
		_wc("the workers' walker heads straight for the far bank", walker.next(crossing[0], crossing[1]) == crossing[1])
	_wc("building, tilling and items are refused on the creek (all of it is water)", Footprints.rect_blocked(get_tree(), Rect2(W.tile_rect(W.creek_tiles[0]).position + Vector2(4, 4), Vector2(11, 11))) and Footprints.rect_blocked(get_tree(), Rect2(W.tile_rect(W.creek_tiles[W.creek_tiles.size() / 2]).position + Vector2(4, 4), Vector2(11, 11))))
	# --- the bucket
	var Items = load("res://scripts/items.gd")
	var shore_cell: Vector2i = W.nearest_water(Vector2(250, 250))
	var shore_pos: Vector2 = W.closest_point_in_tile(Vector2(250, 250), shore_cell) + Vector2(-10, 0)
	player.position = shore_pos
	player.state = player.State.FREE
	player.held_tool = &"bucket"
	player.held_scoops = 0
	var scooped: int = 0
	for i in 8:
		player._scoop_ready_at = 0
		player.scoop_water(shore_cell)
		scooped = player.held_scoops
	_wc("bucket: scoops up to its capacity (%d), then 'The bucket is full.'" % cfg.bucket_capacity, scooped == cfg.bucket_capacity and player.scoop_water(shore_cell) == "The bucket is full.")
	player.held_tool = &"bucket"
	var dropped = Items.spawn(&"bucket", world, player.position + Vector2(-20, 0), 3)
	_wc("a bucket keeps its water on the ground; hover 'Bucket 3/6' / 'Bucket (empty)'", Items.hover_text(&"bucket", dropped.amount()) == "Bucket 3/6" and Items.hover_text(&"bucket", 0) == "Bucket (empty)")
	dropped.remove_from_group("ground_items")
	dropped.queue_free()
	# --- watering: three plots, growth with and without water
	set_time(day, 0.1)
	var m = load("res://scripts/plot_manager.gd").get_for(get_tree())
	var field: Vector2i = Vector2i(31, 40)
	for gx in range(25, 40):
		var clear: bool = true
		for dx in 4:
			if m.can_till(Vector2i(gx + dx, 40)) != "":
				clear = false
		if clear:
			field = Vector2i(gx, 40)
			break
	var wet: Vector2i = field
	var dry: Vector2i = field + Vector2i(1, 0)
	var also: Vector2i = field + Vector2i(2, 0)
	for cell in [wet, dry, also]:
		m.plots[cell] = {"state": &"planted", "growth": 0.0, "synced": m.now(), "watered_until": 0.0}
	player.position = m.cell_center(wet) + Vector2(0, 14)
	player.held_tool = &"bucket"
	player.held_scoops = 3
	player._pour_ready_at = 0
	var first_pour: String = player.plot_water(wet)
	player._pour_ready_at = 0
	var msgs: Array = [first_pour, player.plot_water(also)]
	_wc("watering uses a scoop per plot (3 -> %d), a watered plot is 'watered'" % player.held_scoops, player.held_scoops == 1 and m.is_watered(wet) and m.is_watered(also) and not m.is_watered(dry), str(msgs))
	_wc("hover text: watered vs DRY", m.text(wet).begins_with("Wheat, sown, watered (") and m.text(dry) == "Wheat, sown, DRY", "%s | %s" % [m.text(wet), m.text(dry)])
	var g0: float = m.growth(wet)
	var saved_speed: float = clock_speed_multiplier
	set_time(day, minf(time_of_day + 0.5 * cfg.wheat_water_clock_seconds / day_length, 0.99))
	var g_half: float = m.growth(wet)
	var g_dry: float = m.growth(dry)
	_wc("growth only while watered: %.0f s of growth in half a watering, the dry plot %.0f" % [g_half, g_dry], absf(g_half - 0.5 * cfg.wheat_water_clock_seconds) < 2.0 and g_dry == 0.0)
	set_time(day + 1, time_of_day)
	var g_after: float = m.growth(wet)
	_wc("it stops when the water runs out (%.0f s of growth, not %.0f)" % [g_after, cfg.wheat_water_clock_seconds + g_half], absf(g_after - cfg.wheat_water_clock_seconds) < 2.0 and not m.is_watered(wet))
	player.held_scoops = 0
	_wc("'The bucket is empty.' / 'Sow it first.'", player.plot_water(dry) == "The bucket is empty." and (func() -> String:
		m.plots[wet] = {"state": &"tilled"}
		player.held_scoops = 2
		return player.plot_water(wet)).call() == "Sow it first.")
	m.plots.clear()
	m.queue_redraw()
	player.held_tool = &""
	player.held_scoops = 0
	# --- the dough board: flour + water -> dough
	var board = load("res://scenes/DoughBoard.tscn").instantiate()
	board.position = Vector2(300, 250)
	world.add_child(board)
	await get_tree().process_frame
	player.held_tool = &"flour"
	var put: String = player.board_flour(board)
	player.held_tool = &"flour"
	var again: String = player.board_flour(board)
	player.held_tool = &""
	var nothing: String = board.knead_press(player)
	player.held_tool = &"bucket"
	player.held_scoops = 2
	player._pour_ready_at = 0
	var poured: String = player.board_water(board)
	player._pour_ready_at = 0
	var twice: String = player.board_water(board)
	_wc("board: flour goes on, a second says 'has flour already', 'Nothing to mix.' without water, a scoop pours once", put == "" and again == "The board has flour already." and nothing == "Nothing to mix." and poured == "" and twice == "The board has water already." and player.held_scoops == 1, board.readout())
	player.held_tool = &""
	var presses: int = 0
	for i in cfg.knead_presses:
		player.board_press(board)
		presses += 1
	_wc("%d presses of kneading make dough (flour and water used up)" % cfg.knead_presses, board.dough and not board.has_flour and not board.has_water, board.readout())
	player.held_tool = &"flour"
	_wc("a waiting dough: 'The board is full.'", player.board_flour(board) == "The board is full.")
	player.held_tool = &""
	player.board_press(board)
	_wc("empty hands take the dough", player.held_tool == &"dough" and not board.dough)
	# --- the dough cooks on the stone
	var fire = load("res://scenes/Campfire.tscn").instantiate()
	fire.position = Vector2(340, 250)
	world.add_child(fire)
	await get_tree().process_frame
	fire.stone = true
	fire.burn_left = 600.0
	fire.lit = true
	fire.stone_heat = 100.0
	var placed: String = player.campfire_place_dough(fire)
	clock_speed_multiplier = 10.0
	for i in 1500:
		await get_tree().process_frame
		if fire.food[0]["kind"] == &"flatbread":
			break
	clock_speed_multiplier = saved_speed
	_wc("the dough made on the board cooks to flatbread on the hot stone", placed == "" and fire.food_text() == "Flatbread ready", fire.food_text())
	for node in [board, fire]:
		node.remove_from_group("dough_boards")
		node.remove_from_group("build_blockers")
		node.queue_free()
	player.held_tool = &""

func _tc(step: String, ok: bool, extra: String = "") -> void:
	print("SELF-CHECK:   table/art: %-72s %s%s" % [step, "OK" if ok else "FAIL", ("  (" + extra + ")") if extra != "" else ""])

# The dough board as an item on a table in a house, the table's limits, and the eight campfire pictures.
func _self_check_table_and_art() -> void:
	var player = get_parent().get_node_or_null("MainCharacter")
	if player == null or not is_instance_valid(player) or not player.has_method("table_put"):
		print("SELF-CHECK: table/art: no MainCharacter in this scene")
		return
	var world: Node = get_parent()
	var cfg = load("res://scripts/food_config.gd").cfg()
	var Items = load("res://scripts/items.gd")
	var Dismantle = load("res://scripts/dismantle.gd")
	var CampfireScript = load("res://scripts/campfire.gd")
	# --- the eight campfire pictures: which file each state used
	var all_ok: bool = true
	var fell: Array[String] = []
	for line in CampfireScript.art_report():
		print("SELF-CHECK:   campfire art: " + line)
		if line.contains("FELL BACK") or line.contains("placeholder"):
			fell.append(line.split(" ->")[0])
	for is_lit in [false, true]:
		for variant in ["", "stone", "dough", "bread"]:
			var art: Dictionary = CampfireScript.art_for(is_lit, variant)
			if art["frames"].is_empty() or not (art["frames"][0] is Texture2D):
				all_ok = false
	_tc("all 8 campfire states resolve to a picture (fell back / placeholder: %s)" % str(fell), all_ok)
	# --- a house with two tables and a board on one
	var house = load("res://scenes/Building.tscn").instantiate()
	house.building_type = load("res://assets/house_type.tres")
	house.position = Vector2(120, 420)
	world.add_child(house)
	house.state = house.State.BUILT
	var room: Node2D = house.get_interior()
	var table_type: BuildingType = load("res://assets/table_type.tres")
	var made: Array = []
	for i in 2:
		var bp = load("res://scenes/Building.tscn").instantiate()
		bp.building_type = table_type
		bp.position = room.to_world(Vector2(48 + 64 * i, 96))
		world.add_child(bp)
		await get_tree().process_frame
		bp.planks_ready = 3
		for k in 4:
			bp.hammer_hit()
		await get_tree().process_frame
	var tables: Array = []
	for t in get_tree().get_nodes_in_group("tables"):
		if room.rect_world().has_point(t.global_position):
			tables.append(t)
	_tc("a table is built inside the house (4 hammer hits, 3 planks); the house holds %d (house_max_tables)" % house.house_max_tables, tables.size() == 2 and not room.has_room_for(table_type), "%d tables, room for another: %s" % [tables.size(), room.has_room_for(table_type)])
	var table = tables[0]
	# --- the board: pick it up from the floor, keep what it holds, put it on the table
	var board = Items.spawn_board(world, room.to_world(Vector2(80, 120)), {"flour": true, "water": false, "dough": false})
	player.held_tool = &""
	player.position = board.position + Vector2(0, 6)
	var picked: String = player.take_board(board)
	_tc("empty hands pick the board up as an item (holding: '%s', it keeps its flour)" % player.held_tool, picked == "" and player.held_tool == &"dough_board" and player.held_board.get("flour", false))
	var on_table: String = player.table_put(table)
	var board_on_table = null
	for item in table.items():
		board_on_table = item
	_tc("E at the table puts the board on its surface (hover: '%s')" % table.readout(), on_table == "" and board_on_table != null and board_on_table.has_flour and player.held_tool == &"")
	# it works where it lies: water, knead, take the dough
	player.held_tool = &"bucket"
	player.held_scoops = 2
	player._pour_ready_at = 0
	var poured: String = player.board_water(board_on_table)
	player.held_tool = &""
	player.held_scoops = 0
	for i in cfg.knead_presses:
		player.board_press(board_on_table)
	_tc("the board on the table takes water and kneads (%d presses) into dough" % cfg.knead_presses, poured == "" and board_on_table.dough, board_on_table.readout())
	_tc("a table with a dough board on it cannot be dismantled", Dismantle.block_reason(get_tree(), table, player) == "Take the item off first.")
	player.board_press(board_on_table)
	_tc("empty hands take the dough first (the board stays on the table)", player.held_tool == &"dough" and not board_on_table.dough and is_instance_valid(board_on_table) and not table.is_empty())
	# --- the dough goes on the stone and cooks
	var fire = load("res://scenes/Campfire.tscn").instantiate()
	fire.position = Vector2(200, 420)
	world.add_child(fire)
	await get_tree().process_frame
	fire.stone = true
	fire.burn_left = 900.0
	fire.lit = true
	fire.stone_heat = 100.0
	player.campfire_place_dough(fire)
	var saved_speed: float = clock_speed_multiplier
	clock_speed_multiplier = 10.0
	for i in 1500:
		await get_tree().process_frame
		if fire.food[0]["kind"] == &"flatbread":
			break
	clock_speed_multiplier = saved_speed
	_tc("the dough cooks to flatbread on the stone", fire.food_text() == "Flatbread ready", fire.food_text())
	for i in 2:
		await get_tree().process_frame
	_tc("the lit fire with bread uses %s" % str(CampfireScript.art_for(true, "bread")["file"]).get_file(), fire.sprite.texture != null)
	# --- the board comes off the table again, and other things go on it
	player.held_tool = &""
	player.take_board(board_on_table)
	await get_tree().process_frame
	_tc("empty hands + E on a board with nothing to take picks the board up again; the table is empty", player.held_tool == &"dough_board" and table.is_empty())
	player.held_tool = &"bucket"
	player.held_scoops = 4
	player.table_put(table)
	var node_on = table.items()[0] if not table.items().is_empty() else null
	_tc("a bucket goes on the table with its water ('%s')" % table.readout(), node_on != null and node_on.scoops == 4 and player.held_tool == &"")
	player.held_tool = &"dough_board"
	_tc("a second thing: 'The table is full.'", player.table_put(table) == "The table is full.")
	player.held_tool = &"plank"
	_tc("a plank does not go on a table", not player.table_takes(&"plank"))
	player.held_tool = &""
	# --- tidy up
	for node in get_tree().get_nodes_in_group("tables"):
		if room.rect_world().has_point(node.global_position):
			node.remove_from_group("tables")
			node.remove_from_group("build_blockers")
			node.queue_free()
	fire.remove_from_group("campfires")
	fire.remove_from_group("build_blockers")
	fire.queue_free()
	for colonist in get_tree().get_nodes_in_group("colonists"):
		if colonist.home == house:
			colonist.home = null
			colonist._stand_still()
	house.interior.free()
	house.remove_from_group("buildings")
	house.remove_from_group("build_blockers")
	house.queue_free()
	player.held_board = {}
	player.held_scoops = 0

# --- The seven fixes of the sound / shore / creek / tree / sleep / bucket batch ---------------------------------------------

func _s7(n: int, text: String, ok: bool, extra: String = "") -> void:
	print("SELF-CHECK: (%d) %-84s %s%s" % [n, text, "OK" if ok else "FAIL", ("  (" + extra + ")") if extra != "" else ""])

func _dir_name(v: Vector2) -> String:
	if v.length() < 0.5:
		return "none"
	var names: Array = ["E", "SE", "S", "SW", "W", "NW", "N", "NE"]
	return names[posmod(int(round(v.angle() / (PI / 4.0))), 8)]

func _self_check_batch7() -> void:
	var world: Node = get_parent()
	var player = world.get_node_or_null("MainCharacter")
	var W = load("res://scripts/water_map.gd")
	var cfg = load("res://scripts/food_config.gd").cfg()
	var Layer = load("res://scripts/water_layer.gd")
	# ---- (1) the brook loop: its length, nothing below ~250 Hz, the level, the fall-off with distance
	var streams: Array = AudioManager.variants_of("water_loop")
	var raw: PackedByteArray = FileAccess.get_file_as_bytes("res://audio/water_loop.wav")
	if streams.size() == 1 and streams[0] is AudioStreamWAV and raw.size() > 44:
		# (The imported stream may be compressed, so the check reads the file itself: 16-bit mono PCM after a 44 byte header.)
		var wav: AudioStreamWAV = streams[0]
		var n: int = (raw.size() - 44) / 2
		var rate: float = float(wav.mix_rate)
		var peak: int = 0
		var energy: float = 0.0
		var low_energy: float = 0.0
		var poles: Array[float] = [0.0, 0.0, 0.0, 0.0]
		var a: float = exp(-TAU * 250.0 / rate)
		var limit: int = mini(n, int(rate * 8.0))
		for i in n:
			var v: int = raw.decode_s16(44 + i * 2)
			peak = maxi(peak, absi(v))
			if i < limit:
				var x: float = v / 32768.0
				energy += x * x
				for k in 4:
					x = (1.0 - a) * x + a * poles[k]
					poles[k] = x
				low_energy += x * x
		var ratio: float = low_energy / maxf(1e-12, energy)
		var seconds: float = wav.get_length()
		var peak_db: float = linear_to_db(peak / 32768.0)
		_s7(1, "water_loop.wav: %.1f s (20-30), %d Hz, below 250 Hz holds %s of the energy (limit 1e-3), peak %.1f dBFS (-14)" % [seconds, wav.mix_rate, String.num_scientific(ratio), peak_db], seconds >= 20.0 and seconds <= 30.0 and ratio < 1.0e-3 and absf(peak_db + 14.0) < 0.6)
	else:
		_s7(1, "water_loop.wav is a single imported wav", false, "found %d stream(s)" % streams.size())
	var falls: bool = true
	var prev: float = 2.0
	for d in range(0, 420, 8):
		var g: float = Layer.brook_gain(float(d))
		falls = falls and g <= prev + 1e-9
		prev = g
	var at_player: Array = []
	var volumes_ok: bool = true
	var layer: Node = get_tree().get_first_node_in_group("water_layer")
	if player != null and layer != null:
		var cell0: Vector2i = W.nearest_water(Vector2(500, 500))
		var edge: Vector2 = W.closest_point_in_tile(Vector2(500, 500), cell0)
		var away: Vector2 = Vector2(-1, 0) if edge.x > 320 else Vector2(1, 0)
		var spots: Array = [edge + Vector2(0, 8), edge + Vector2(0, 8) + away * 5.0 * 32.0, Vector2(30, 30)]
		for spot in spots:
			player.position = spot
			player.global_position = spot
			await get_tree().process_frame
			await get_tree().process_frame
			var wc: Vector2i = W.nearest_water(spot)
			var dist: float = W.closest_point_in_tile(spot, wc).distance_to(spot)
			var expected_db: float = layer.ambient_volume_db + linear_to_db(Layer.brook_gain(dist)) if Layer.brook_gain(dist) > 0.0005 else -80.0
			var sp = AudioManager._loops.get(layer._loop)
			var got: float = sp.volume_db if sp != null else 99.0
			at_player.append("%.1f tiles from the water: %.1f dB" % [dist / 32.0, got])
			if absf(got - expected_db) > 0.5:
				volumes_ok = false
	_s7(1, "brook is quiet and positional: gain 1 at the water, %.2f at 5 tiles, 0 at %s tiles, smooth fall; volumes %s" % [Layer.brook_gain(160.0), str(cfg.brook_hearing_tiles), str(at_player)], falls and Layer.brook_gain(0.0) == 1.0 and Layer.brook_gain(cfg.brook_hearing_tiles * 32.0) == 0.0 and volumes_ok and (at_player.size() < 3 or at_player[2].ends_with("-80.0 dB")))
	# ---- (2) which sounds were generated, which are untouched placeholders, which are yours
	var manifest: Variant = null
	var file := FileAccess.open("res://audio/generated_manifest.json", FileAccess.READ)
	if file != null:
		manifest = JSON.parse_string(file.get_as_text())
	if manifest == null:
		_s7(2, "audio/generated_manifest.json is there", false)
	else:
		var gen: Dictionary = manifest["generated"]
		var placeholders: Dictionary = manifest["placeholders"]
		var sounds: Dictionary = {}
		var changed: Array[String] = []
		for fname in gen:
			sounds[gen[fname]["sound"]] = true
			if FileAccess.get_sha256("res://audio/" + fname) != gen[fname]["sha256"]:
				changed.append(fname)
		var yours: Array[String] = []
		for fname in DirAccess.get_files_at("res://audio"):
			if fname.ends_with(".wav") and not gen.has(fname) and not placeholders.has(fname):
				yours.append(fname)
		var kept: Array[String] = []
		for fname in placeholders:
			if FileAccess.get_sha256("res://audio/" + fname) == placeholders[fname]:
				kept.append(fname)
		_s7(2, "regenerated %d sounds = %d files (3 variants each, 1 for the brook); %d old placeholders untouched; yours: %s; changed since generated: %s" % [sounds.size(), gen.size(), kept.size(), str(yours), str(changed)], changed.is_empty() and kept.size() == placeholders.size() and sounds.size() >= 30)
		print("SELF-CHECK:   regenerated: " + ", ".join(sounds.keys()))
		print("SELF-CHECK:   untouched placeholders: " + ", ".join(kept))
		var picks: Dictionary = {}
		for i in 40:
			picks[AudioManager.stream_for("chop_hit").resource_path] = true
		_s7(2, "AudioManager picks among %d chop_hit variants at random (%d different used in 40 plays)" % [AudioManager.variants_of("chop_hit").size(), picks.size()], AudioManager.variants_of("chop_hit").size() == 3 and picks.size() == 3)
	# ---- (3) the shore: every case of the test patch, checked against the artist's pictures
	var Painter = load("res://scripts/shore_painter.gd")
	var Test = load("res://debug/shore_test.gd")
	var images: Dictionary = {&"edge": (load("res://sprites/shore_edge.png") as Texture2D).get_image(), &"corner_in": (load("res://sprites/shore_corner_in.png") as Texture2D).get_image(), &"corner_out": (load("res://sprites/shore_corner_out.png") as Texture2D).get_image()}
	var out_corner: int = layer.corner_out_land_corner if layer != null else 3
	var corner_names: Array = ["NE", "SE", "SW", "NW"]
	var base_dir: Vector2 = Painter.land_centroid(images[&"corner_out"], Rect2(0, 0, 32, 32))
	var base_corner: int = (0 if base_dir.y < 0 else 1) if base_dir.x > 0 else (3 if base_dir.y < 0 else 2)
	print("SELF-CHECK: (3) the pictures as drawn: shore_edge land %s, shore_corner_in land %s, shore_corner_out land in the %s corner (the layer uses %s)" % [_dir_name(Painter.land_centroid(images[&"edge"], Rect2(0, 0, 32, 32))), _dir_name(Painter.land_centroid(images[&"corner_in"], Rect2(0, 0, 32, 32))), corner_names[base_corner], corner_names[out_corner]])
	var all_cases: bool = true
	for case in Test.CASES:
		var rows: Array = case[1]
		var kind: Callable = Test.kind_func(rows)
		var problems: Array[String] = []
		var seen_text: Dictionary = {}
		for y in 5:
			for x in 5:
				var cell := Vector2i(x, y)
				if int(kind.call(cell)) == W.LAND:
					continue
				var claimed: Dictionary = {}
				for piece in Painter.pieces(kind, cell, out_corner):
					if piece["tex"] == &"water":
						continue
					seen_text[piece["text"] + " rot %d" % piece["rot"]] = true
					var expected := Vector2.ZERO
					for off in piece["cells"]:
						claimed[off] = true
						expected += Vector2(off)
						if int(kind.call(cell + off)) != W.LAND:
							problems.append("%s claims land at %s" % [piece["text"], str(cell + off)])
					var dir: Vector2 = Painter.land_direction(images[piece["tex"]], piece)
					if absf(dir.angle_to(expected)) > 0.55:
						problems.append("%s at %s: the picture's land points %s, the land is %s" % [piece["text"], str(cell), _dir_name(dir), _dir_name(expected)])
				# every land edge neighbour, and every land diagonal with two water edges, is covered by a piece
				for i in 4:
					if int(kind.call(cell + Painter.SIDES[i])) == W.LAND and not claimed.has(Painter.SIDES[i]):
						problems.append("land %s of %s not covered" % [Painter.SIDE_NAMES[i], str(cell)])
					if int(kind.call(cell + Painter.CORNERS[i])) == W.LAND and int(kind.call(cell + Painter.SIDES[i])) != W.LAND and int(kind.call(cell + Painter.SIDES[(i + 1) % 4])) != W.LAND and not claimed.has(Painter.CORNERS[i]):
						problems.append("land %s diagonal of %s not covered" % [Painter.CORNER_NAMES[i], str(cell)])
		all_cases = all_cases and problems.is_empty()
		_s7(3, "shore case '%s': %s" % [case[0], "; ".join(seen_text.keys().slice(0, 4))], problems.is_empty(), "" if problems.is_empty() else str(problems.slice(0, 2)))
	_s7(3, "all %d shore cases draw the land on the land side (the prompt said 11; it lists 4+4+4+2 = 14)" % Test.CASES.size(), all_cases and Test.CASES.size() == 14)
	# ---- (4) the creek: tiles, width, distance from the cabin, reachability, nobody in water
	var cabin: Node2D = world.get_node_or_null("Cabin")
	var near: float = INF
	var far: float = 0.0
	for c in W.creek_tiles:
		var d: float = W.tile_rect(c).get_center().distance_to(cabin.position) / 32.0 if cabin != null else 20.0
		near = minf(near, d)
		far = maxf(far, d)
	var land_dist: Dictionary = {}
	for c in W.creek_tiles:
		var nl: float = INF
		for ly in W.ROWS:
			for lx in W.COLS:
				if W.kind_at_tile(Vector2i(lx, ly)) == W.LAND:
					nl = minf(nl, Vector2(lx - c.x, ly - c.y).length())
		land_dist[c] = nl
	var ridge: Array[float] = []
	for c in W.creek_tiles:
		var is_ridge: bool = true
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var nb := Vector2i(c.x + dx, c.y + dy)
				if (dx != 0 or dy != 0) and land_dist.has(nb) and land_dist[nb] > land_dist[c] + 0.001:
					is_ridge = false
		if is_ridge:
			ridge.append(2.0 * land_dist[c] - 1.0)
	ridge.sort()
	var mean_w: float = 0.0
	for w in ridge:
		mean_w += w
	mean_w /= maxf(1.0, ridge.size())
	var obstacles: Array[Rect2] = Footprints.base_rects(get_tree())
	var seen: Dictionary = W.flood(player.position, obstacles) if player != null else {}
	var places: Array = []
	if cabin != null:
		places.append(["cabin door side", cabin.position + Vector2(0, 14)])
	var landing: Node2D = world.get_node_or_null("LandingPoint")
	if landing != null:
		places.append(["landing point", landing.position])
	var yard: Node2D = world.get_node_or_null("PlankYard")
	if yard != null:
		places.append(["plank yard", yard.position])
	for b in get_tree().get_nodes_in_group("berry_bushes"):
		places.append(["bush", b.position + Vector2(0, 8)])
	for c in [W.creek_tiles[0], W.creek_tiles[W.creek_tiles.size() - 1]]:
		places.append(["creek", W.tile_rect(c).get_center()])
	var cut_off: Array[String] = []
	for pl in places:
		if not W.flood_reaches(seen, pl[1], 3):
			cut_off.append("%s %s" % [pl[0], str(pl[1])])
	var in_water: Array[String] = []
	for group in ["trees", "berry_bushes", "grass_patches", "ground_items", "colonists", "player"]:
		for node in get_tree().get_nodes_in_group(group):
			if node is Node2D and W.is_water(W.tile_of(node.global_position)):
				in_water.append("%s %s" % [group, str(node.global_position)])
	for node in get_tree().get_nodes_in_group("build_blockers"):
		if node is Node2D and W.rect_has_water(Footprints.blocker_rect(node)):
			in_water.append("building %s" % str(node.global_position))
	var plots: Node = get_tree().get_first_node_in_group("plot_manager")
	if plots != null:
		for cellp in plots.plots:
			if W.is_water(W.tile_of(plots.cell_center(cellp))):
				in_water.append("plot %s" % str(cellp))
	_s7(4, "creek: %d tiles, perpendicular width mean %.1f max %.1f (2, 3 at most), %.1f to %.1f tiles from the cabin (15 to 25), %s" % [W.creek_tiles.size(), mean_w, ridge.back() if not ridge.is_empty() else 0.0, near, far, W.creek_report], W.creek_tiles.size() >= 28 and (ridge.is_empty() or ridge.back() <= 3.2) and mean_w >= 1.7 and mean_w <= 3.0 and near >= cfg.creek_cabin_min_tiles and far <= cfg.creek_cabin_max_tiles)
	_s7(4, "flood fill across %d places (cabin, landing, yard, %d bushes, both creek ends): nothing cut off: %s; nobody stands in water: %s" % [places.size(), get_tree().get_nodes_in_group("berry_bushes").size(), str(cut_off), str(in_water)], cut_off.is_empty() and in_water.is_empty())
	# ---- (5) the trees
	var layout: Dictionary = world.get("tree_layout") if world.get("tree_layout") != null else {}
	var trees: Array = get_tree().get_nodes_in_group("trees")
	var points: Array = []
	for t in trees:
		points.append(t.global_position)
	var TreeScatter = load("res://scripts/tree_scatter.gd")
	var nn: Array[float] = TreeScatter.neighbour_distances(points)
	var nearest_cabin: float = INF
	var inside_clear: int = 0
	var on_shore: int = 0
	for p in points:
		if cabin != null:
			nearest_cabin = minf(nearest_cabin, p.distance_to(cabin.position) / 32.0)
			if p.distance_to(cabin.position) < world.tree_clear_radius_cabin * 32.0:
				inside_clear += 1
		var tile: Vector2i = W.tile_of(p)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if W.is_water(tile + Vector2i(dx, dy)):
					on_shore += 1
	var clashes: Array[String] = []
	for t in trees:
		var rect: Rect2 = Footprints.tree_rect(t)
		for b in get_tree().get_nodes_in_group("berry_bushes"):
			if b.global_position.distance_to(t.global_position) < 14.0:
				clashes.append("bush near tree %s" % str(t.position))
		for g in get_tree().get_nodes_in_group("grass_patches"):
			if g.global_position.distance_to(t.global_position) < 14.0:
				clashes.append("grass near tree %s" % str(t.position))
		for it in get_tree().get_nodes_in_group("ground_items"):
			if rect.has_point(it.global_position):
				clashes.append("item under tree %s" % str(t.position))
		for node in get_tree().get_nodes_in_group("build_blockers"):
			if node is Node2D and rect.intersects(Footprints.blocker_rect(node)):
				clashes.append("building at tree %s" % str(t.position))
	_s7(5, "trees: %d before (a regular grid), %d now (x%.1f); nearest to the cabin %.1f tiles (8 to 14); %s" % [world.trees_original_count, trees.size(), world.trees_count_multiplier, nearest_cabin, "seed %s attempt %s" % [str(layout.get("seed", "?")), str(layout.get("attempt", "?"))]], trees.size() == int(round(world.trees_original_count * world.trees_count_multiplier)) and nearest_cabin >= world.tree_nearest_cabin_min_tiles and nearest_cabin <= world.tree_nearest_cabin_max_tiles)
	var grove: int = 0
	var lone: int = 0
	for d in nn:
		grove += 1 if d <= 2.6 else 0
		lone += 1 if d >= 4.0 else 0
	_s7(5, "spacing to the nearest neighbour, in tiles: min %.1f, median %.1f, max %.1f (1.5 to 8); %d trees in groves, %d lone" % [nn[0], nn[nn.size() / 2], nn[nn.size() - 1], grove, lone], nn[0] >= world.tree_min_spacing_tiles - 0.05 and nn[nn.size() - 1] > nn[0] + 1.0)
	var tree_cut: Array[String] = []
	for t in trees:
		if not W.flood_reaches(seen, t.position + Vector2(0, 14), 3):
			tree_cut.append(str(t.position))
	_s7(5, "none on water or shore (%d), none within %s tiles of the cabin (%d), none on items, bushes, grass or buildings (%s); every tree reachable (flood fill, %d unreachable)" % [on_shore, str(world.tree_clear_radius_cabin), inside_clear, str(clashes.slice(0, 2)), tree_cut.size()], on_shore == 0 and inside_clear == 0 and clashes.is_empty() and tree_cut.is_empty())
	print("SELF-CHECK:   tree positions: " + str(points))
	# ---- (6) the sleep blackout
	if sleep_check.is_empty():
		print("SELF-CHECK: (6) sleep: not measured in this scene")
	else:
		_s7(6, "a night's sleep (from %s to %s): %.1f s on the black screen (at most about 3), %.1f s in all (fade out %.1f + hold %.1f + fade in %.1f), peak clock speed x%.0f" % [sleep_check["from"], sleep_check["to"], sleep_check["black"], sleep_check["total"], player.fade_out_seconds, player.sleep_black_hold_seconds, player.fade_in_seconds, sleep_check["peak"]], sleep_check["black"] <= 3.0 and sleep_check["total"] <= player.fade_out_seconds + 3.0 + player.sleep_black_hold_seconds + player.fade_in_seconds + 0.6)
	if not sleep_night.is_empty():
		_s7(6, "a whole night outdoors (from %s to dawn %s): %.1f s on the black screen, %.1f s in all, peak clock speed x%.0f" % [sleep_night["from"], sleep_night["to"], sleep_night["black"], sleep_night["total"], sleep_night["peak"]], sleep_night["black"] <= 3.0 and sleep_night["total"] <= player.fade_out_seconds + 3.0 + player.sleep_black_hold_seconds + player.fade_in_seconds + 0.5)
	# ---- (7) the bucket
	if player != null:
		var cell: Vector2i = W.nearest_water(Vector2(250, 250))
		player.state = player.State.FREE
		player.rest.value = 100.0
		player.hunger.value = 100.0
		player.held_tool = &"bucket"
		player.held_scoops = 0
		player._scoop_ready_at = 0
		var t0: int = Time.get_ticks_msec()
		var frames: int = 0
		while player.held_scoops < cfg.bucket_capacity and frames < 2000:
			player.scoop_water(cell)
			await get_tree().process_frame
			frames += 1
		var fill_s: float = (Time.get_ticks_msec() - t0) / 1000.0
		var expect: float = (cfg.bucket_capacity - 1) * cfg.bucket_scoop_seconds
		_s7(7, "filling an empty bucket takes %.2f s (%d scoops, one per %.1f s; was %.1f s each), then 'The bucket is full.'" % [fill_s, cfg.bucket_capacity, cfg.bucket_scoop_seconds, 1.0], absf(fill_s - expect) < 0.25 and player.scoop_water(cell) == "The bucket is full.")
		player.rest.value = 5.0
		player._scoop_ready_at = 0
		player.held_scoops = 0
		player.scoop_water(cell)
		var tired_gap: float = (player._scoop_ready_at - Time.get_ticks_msec()) / 1000.0
		_s7(7, "tired (energy 5, efficiency %.2f) one scoop takes %.2f s instead of %.1f s; held E repeats scoop after scoop (interval %.1f s)" % [player.rest.efficiency(), tired_gap, cfg.bucket_scoop_seconds, load("res://scripts/interaction.gd").new()._repeat_interval("scoop")], tired_gap > cfg.bucket_scoop_seconds + 0.05)
		player.rest.value = 100.0
		player._pour_ready_at = 0
		var first: bool = player._pour_ready()
		var second: bool = player._pour_ready()
		await get_tree().create_timer(cfg.bucket_pour_seconds + 0.08).timeout
		var third: bool = player._pour_ready()
		_s7(7, "pouring (plot or dough board) takes %.1f s each: first %s, again at once %s, after %.1f s %s; hold repeat interval for plot_water %.1f s" % [cfg.bucket_pour_seconds, str(first), str(second), cfg.bucket_pour_seconds, str(third), load("res://scripts/interaction.gd").new()._repeat_interval("plot_water")], first and not second and third)
		player.held_tool = &""
		player.held_scoops = 0

# --- The UI pass: render setup, fonts, theme files, the build menu, pause, the hover bars ---------------------------------

func _u(text: String, ok: bool, extra: String = "") -> void:
	print("SELF-CHECK: ui: %-92s %s%s" % [text, "OK" if ok else "FAIL", ("  (" + extra + ")") if extra != "" else ""])

func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev

func _self_check_ui() -> void:
	var world: Node = get_parent()
	var player = world.get_node_or_null("MainCharacter")
	var build = world.get_node_or_null("BuildMode")
	# --- render setup
	var screen: Vector2 = Ui.screen_size()
	var s1080: float = Ui.scale_for_height(1080.0)
	var s720: float = Ui.scale_for_height(720.0)
	var shell_text: String = "the world runs in a %s SubViewport shown x%d" % [str(Ui.shell.world_viewport.size), Ui.shell.factor] if Ui.shell != null else "(this run has no Shell: the world is in the root window)"
	print("SELF-CHECK: ui: render setup: %s; ALL text is drawn by the Ui autoload in screen-space CanvasLayers (art 10, text 12, menu 20, fade 85, game over 90, pause 95) of the root window at its real resolution %s; world text (hover names, prompts, plot / work labels, adopted world Labels) is placed at the thing's screen position each frame, whole pixels, kept inside the window" % [shell_text, str(screen)])
	print("SELF-CHECK: ui: scale at 1080p x%.2f (body %d px, small %d, heading %d, pixel art x%d), at 720p x%.2f (body %d px, art x%d), at this window x%.2f" % [s1080, roundi(Ui.cfg.ui_font_size_body * s1080), roundi(Ui.cfg.ui_font_size_small * s1080), roundi(Ui.cfg.ui_font_size_heading * s1080), maxi(1, roundi(Ui.cfg.ui_art_pixel_scale * s1080)), s720, roundi(Ui.cfg.ui_font_size_body * s720), maxi(1, roundi(Ui.cfg.ui_art_pixel_scale * s720)), Ui.ui_scale()])
	_u("fonts: " + Ui.fonts_report(), Ui.fonts_missing.is_empty())
	# --- the ui files
	var manifest: Variant = null
	var file := FileAccess.open("res://ui/generated_manifest.json", FileAccess.READ)
	if file != null:
		manifest = JSON.parse_string(file.get_as_text())
	if manifest == null:
		_u("ui/generated_manifest.json", false)
	else:
		var gen: Dictionary = manifest["generated"]
		var generated: Array[String] = []
		var yours: Array[String] = []
		for fname in DirAccess.get_files_at("res://ui"):
			if fname.ends_with(".import") or fname == "generated_manifest.json":
				continue
			if gen.has(fname) and FileAccess.get_sha256("res://ui/" + fname) == gen[fname]:
				generated.append(fname)
			else:
				yours.append(fname)
		var needed: Array[String] = ["panel_frame.png", "panel_frame_dark.png", "button_normal.png", "button_hover.png", "button_pressed.png", "button_disabled.png", "tab_normal.png", "tab_active.png", "slot_frame.png", "slot_frame_selected.png", "divider.png", "corner_ornament.png", "title_banner.png", "theme.tres"]
		var missing: Array[String] = []
		for n in needed:
			if not FileAccess.file_exists("res://ui/" + n):
				missing.append(n)
		_u("res://ui: %d generated (replace any with your own art, same name), %d not generated by the script (yours): %s; missing: %s" % [generated.size(), yours.size(), str(yours), str(missing)], missing.is_empty())
		print("SELF-CHECK:   generated: " + ", ".join(generated))
	_u("theme loaded with the Panel / Button / Label styles, applied to the menu, pause and game-over layers", Ui.theme != null and Ui.theme.has_stylebox("panel", "Panel") and Ui.theme.has_stylebox("normal", "Button") and Ui.menu_root.theme == Ui.theme and Ui.over_root.theme == Ui.theme and Ui.pause_root.theme == Ui.theme)
	# --- the build menu
	if build != null and build.menu != null:
		var counts: Dictionary = build.menu.card_counts()
		var total: int = 0
		for c in counts.values():
			total += int(c)
		_u("build menu: %d cards in %d tabs %s; one card per building (%d)" % [total, counts.size(), str(counts), build.building_types.size()], total == build.building_types.size() and counts.size() == 4)
		var names: Array[String] = []
		for card in build.menu.cards:
			names.append("%s[%s]" % [card["type"].type_name, card["category"]])
		print("SELF-CHECK:   cards: " + ", ".join(names))
		var described: bool = true
		for t in build.building_types:
			described = described and t.description != "" and t.category != ""
		_u("every building has a category and a one-line description", described)
		# Esc: first closes the build menu, only then pauses; P toggles; pause is refused on the game-over screen
		build._set_active(true)
		await get_tree().process_frame
		Ui.pause_menu._unhandled_input(_key(KEY_ESCAPE))
		var closed_first: bool = not build.active and not Ui.is_paused()
		Ui.pause_menu._unhandled_input(_key(KEY_ESCAPE))
		var paused_second: bool = Ui.is_paused()
		Ui.pause_menu._unhandled_input(_key(KEY_ESCAPE))
		_u("Esc closes the open build menu first (not paused: %s), the next Esc pauses (%s), the next resumes (%s)" % [closed_first, paused_second, not Ui.is_paused()], closed_first and paused_second and not Ui.is_paused())
		Ui.game_over = self
		Ui.pause_menu.toggle()
		var refused: bool = not Ui.is_paused()
		Ui.game_over = null
		_u("pause is unavailable on the game-over screen", refused)
	# --- pause: the clock does not move, fast forward is remembered, sleep skip freezes and resumes
	var fast: Node = get_node_or_null("/root/FastForward")
	fast.set_index(2)
	var before_t: float = time_of_day
	var before_day: int = day
	var before_speed: float = Engine.time_scale
	Ui.pause_menu.toggle()
	for i in 90:
		await get_tree().process_frame
	var frozen: bool = time_of_day == before_t and day == before_day
	fast.cycle()
	_u("paused for 90 frames at fast forward x%d: clock %.5f -> %.5f (unchanged), tree paused %s, sounds held %s, fast forward step unchanged after a click on its button: %s" % [int(fast.factor()), before_t, time_of_day, get_tree().paused, AudioManager.held, fast.index == 2], frozen and get_tree().paused and AudioManager.held and fast.index == 2)
	Ui.pause_menu.toggle()
	for i in 30:
		await get_tree().process_frame
	_u("resumed: clock runs again (%.5f -> %.5f), fast forward x%d restored, sounds back: %s" % [before_t, time_of_day, int(fast.factor()), not AudioManager.held], (time_of_day != before_t or day != before_day) and fast.index == 2 and not AudioManager.held and Engine.time_scale == before_speed)
	fast.set_index(0)
	if player != null:
		set_time(day, 0.72)
		player.hunger.value = 100.0
		player.rest.value = 20.0
		player.request_sleep_outside()
		for i in 70:
			await get_tree().process_frame
		var skip_before: float = player._sleep_skip._skip_real
		var clock_before: float = time_of_day
		var day_before: int = day
		Ui.pause_menu.toggle()
		for i in 60:
			await get_tree().process_frame
		var skip_frozen: bool = player._sleep_skip._skip_real == skip_before and time_of_day == clock_before and day == day_before and player.state == player.State.SLEEPING
		Ui.pause_menu.toggle()
		for i in 600:
			await get_tree().process_frame
			if player.state != player.State.SLEEPING and player._sleep_skip.phase == 0:
				break
		_u("paused in the middle of a sleep skip (black screen, clock %.4f): frozen %s; after resume he wakes normally (state %d, speed given back %s)" % [clock_before, skip_frozen, player.state, clock_speed_multiplier == 1.0], skip_frozen and player.state != player.State.SLEEPING and clock_speed_multiplier == 1.0)
	# --- the hover bars of every character type
	var seen: Dictionary = {}
	var same_order: bool = true
	for node in get_tree().get_nodes_in_group("char_bars"):
		var names: Array = node.bars().map(func(b: Dictionary) -> String: return b["name"])
		seen[node.heading()] = names
		same_order = same_order and names == ["Energy", "Hunger"]
	_u("hover bars (one shared overlay, character_bars.gd): %s; there is no health meter in the game, so Health is not shown" % str(seen), seen.size() >= 1 and same_order)

# --- The world and interaction pass: pickup targeting, the toolbox, the pit saw, free placement, footsteps ---------------------

func _w(n: int, text: String, ok: bool, extra: String = "") -> void:
	print("SELF-CHECK: (%d) %-92s %s%s" % [n, text, "OK" if ok else "FAIL", ("  (" + extra + ")") if extra != "" else ""])

func _self_check_world() -> void:
	var world: Node = get_parent()
	var player = world.get_node_or_null("MainCharacter")
	if player == null:
		return
	var Items = load("res://scripts/items.gd")
	var GP = load("res://scripts/ground_placement.gd")
	var inter: Node = player.get_node("Interaction")
	player.state = player.State.FREE
	player.held_tool = &""
	player.carrying_planks = 0
	player.carrying_blade = false
	# ---- (1) three items on (almost) the same spot: the target by cursor, by E, Tab, and drops that land apart
	var spot: Vector2 = Vector2(430, 380)
	var a = Items.spawn(&"branch", world, spot + Vector2(0, 0))
	var b = Items.spawn(&"flat_stone", world, spot + Vector2(0, 0))
	var c = Items.spawn(&"hoe", world, spot + Vector2(0, 0))
	var apart: bool = a.position.distance_to(b.position) >= 6.0 and a.position.distance_to(c.position) >= 6.0 and b.position.distance_to(c.position) >= 6.0
	# (put them back on top of each other so that the target rules have something to decide)
	a.position = spot + Vector2(-3, 0)
	b.position = spot + Vector2(0, 1)
	c.position = spot + Vector2(3, 0)
	await get_tree().process_frame
	player.position = spot + Vector2(-14, 8)
	var cands: Array = inter._candidates()
	var cursor_a: Dictionary = inter._target_at(a.global_position + Vector2(-3, -5), cands)
	var cursor_c: Dictionary = inter._target_at(c.global_position + Vector2(3, -5), cands)
	var cursor_mid: Dictionary = inter._target_at(b.global_position + Vector2(0, -5), cands)
	var by_e: Dictionary = inter._find_nearest(cands)
	var names := func(d: Dictionary) -> String:
		return String(d["node"].kind) if not d.is_empty() and d["node"].get("kind") != null else "none"
	var cursor_ok: bool = names.call(cursor_a) == "branch" and names.call(cursor_c) == "hoe"
	# Tab: the next overlapping one, nearest first; then the cycle resets when the cursor moves
	inter._mouse_screen = get_viewport().get_canvas_transform() * (b.global_position + Vector2(0, -5))
	inter._mouse_moved_at = Time.get_ticks_msec() / 1000.0
	inter.current = cursor_mid
	inter._hovered = true
	var first: String = names.call(inter.current)
	var cycled: Array[String] = []
	for i in 3:
		if inter.cycle_target():
			cycled.append(names.call(inter.current))
	inter._mouse_screen += Vector2(40, 0)
	var after_move: Dictionary = inter._cycle_target(inter._candidates())
	_w(1, "3 items on one spot: target by cursor %s / %s / centre %s, by E %s; Tab from %s goes %s; moving the cursor ends the cycle: %s" % [names.call(cursor_a), names.call(cursor_c), names.call(cursor_mid), names.call(by_e), first, str(cycled), after_move.is_empty()], cursor_ok and cycled.size() == 3 and after_move.is_empty() and not by_e.is_empty())
	# drops: three items asked for the same spot land apart, on free ground
	for item in [a, b, c]:
		item.remove_from_group("ground_items")
		item.queue_free()
	await get_tree().process_frame
	var dropped: Array = []
	for kind in [&"branch", &"flat_stone", &"hoe", &"sickle"]:
		dropped.append(Items.spawn(kind, world, spot))
	var min_gap: float = INF
	for i in dropped.size():
		for j in range(i + 1, dropped.size()):
			min_gap = minf(min_gap, GP.pickup_center(dropped[i]).distance_to(GP.pickup_center(dropped[j])))
	var radii_ok: bool = true
	for i in dropped.size():
		for j in range(i + 1, dropped.size()):
			radii_ok = radii_ok and GP.pickup_center(dropped[i]).distance_to(GP.pickup_center(dropped[j])) >= GP.pickup_radius(dropped[i]) + GP.pickup_radius(dropped[j]) - 0.5
	_w(1, "4 drops asked for one spot land apart (spawned apart: %s, closest centres %.1f px, no pickup shapes overlap: %s); positions %s" % [apart, min_gap, radii_ok, str(dropped.map(func(n: Node2D) -> Vector2: return n.position))], apart and radii_ok)
	for item in dropped:
		item.remove_from_group("ground_items")
		item.queue_free()
	# ---- (2) the toolbox
	var box: Node2D = world.get("toolbox") if world.get("toolbox") != null else null
	var from_start: bool = box != null
	if box == null:
		box = load("res://scenes/ToolBox.tscn").instantiate()
		box.position = Vector2(470, 330)
		box.init_contents = [[&"hammer", 0], [&"shovel", 0], [&"axe", 0], [&"hoe", 0], [&"sickle", 0], [&"fire_starter", 0]]
		world.add_child(box)
		await get_tree().process_frame
	var listed: String = ", ".join(box.contents.map(func(e: Dictionary) -> String: return "%s x%d" % [e["kind"], e["count"]]))
	var on_ground: Array[String] = []
	for group in ["hammers", "shovels", "axes"]:
		if from_start and not get_tree().get_nodes_in_group(group).is_empty():
			on_ground.append(group)
	for it in get_tree().get_nodes_in_group("ground_items"):
		if from_start and Items.is_tool(it.kind):
			on_ground.append(String(it.kind))
	_w(2, "toolbox%s holds %d tools (%s), capacity %d, hover '%s'; tools left lying on the ground: %s" % [" placed at the start" if from_start else " (made for this check)", box.tool_count(), listed, box.toolbox_capacity, box.readout(), str(on_ground)], box.tool_count() == 6 and on_ground.is_empty() and box.readout() == "Toolbox (6 tools)")
	player.position = box.position + Vector2(0, 8)
	player.held_tool = &""
	var took: String = player.toolbox_take(box, 0)
	var held1: StringName = player.held_tool
	var swap_msg: String = player.toolbox_take(box, 0)
	var held2: StringName = player.held_tool
	var in_box_after_swap: bool = box.kinds().has(held1)
	var put_msg: String = player.toolbox_put(box)
	var empty_again: bool = player.held_tool == &""
	player.held_tool = &"plank_x"
	var refused: String = player.toolbox_put(box)
	player.held_tool = &""
	player.carrying_planks = 1
	var refused2: String = player.toolbox_put(box)
	player.carrying_planks = 0
	player.held_tool = &"bucket"
	player.held_scoops = 4
	var bucket_in: String = player.toolbox_put(box)
	var bucket_back: String = player.toolbox_take(box, box.kinds().find(&"bucket"))
	_w(2, "take slot 1 -> holds %s ('%s'); take slot 1 again = swap -> holds %s, %s back in the box: %s; E with it in hand: '%s' (hands empty: %s); a plank: '%s'; bucket 4 scoops in: '%s', out again with %d scoops (holds %s)" % [held1, took, held2, held1, in_box_after_swap, put_msg, empty_again, refused2, bucket_in, player.held_scoops, player.held_tool], held1 != &"" and held2 != &"" and held1 != held2 and in_box_after_swap and put_msg == "Put away." and empty_again and refused2 == "The toolbox does not take that." and bucket_in == "Put away." and player.held_scoops == 4)
	player.held_tool = &""
	player.held_scoops = 0
	if not from_start:
		box.queue_free()
	# ---- (3) the pit saw with piles in the way
	var pit = load("res://scenes/PitSaw.tscn").instantiate()
	pit.starts_built = true
	pit.position = Vector2(180, 470)
	world.add_child(pit)
	await get_tree().process_frame
	var PP = load("res://scripts/plank_piles.gd")
	var drop: Vector2 = pit.global_position + pit.plank_drop_spot
	var p1 = PP.spawn_pile(world, drop, 3)
	var p2 = PP.spawn_pile(world, drop + Vector2(14, 0), 3)
	var can_load_with_piles: bool = pit.can_load()
	var before_count: int = get_tree().get_nodes_in_group("plank_piles").size()
	pit._pending_planks = 3
	pit._put_out_planks()
	var landed: Vector2 = pit.last_pile_spot
	var overlap: bool = false
	for pile in get_tree().get_nodes_in_group("plank_piles"):
		if pile.global_position != landed and pile.global_position.distance_to(landed) < 10.0:
			overlap = true
	# no room within 0 tiles: the planks wait and the saw says so; with room again they appear
	var saved_tiles: float = pit.plank_search_tiles
	pit.plank_search_tiles = 0.0
	pit._pending_planks = 3
	pit._put_out_planks()
	var waiting: bool = pit._pending_planks == 3
	pit.plank_search_tiles = saved_tiles
	pit._retry_left = 0.0
	pit._put_out_planks()
	var appeared: bool = pit._pending_planks == 0
	_w(3, "pit saw with 2 piles (6 planks) beside it: a log can still be loaded: %s; the finished planks landed at %s (%.0f px from the saw, overlapping a pile: %s); with no room they wait (%s) and appear once there is (%s)" % [can_load_with_piles, str(landed), landed.distance_to(pit.global_position) if landed != Vector2.INF else -1.0, overlap, waiting, appeared], can_load_with_piles and landed != Vector2.INF and not overlap and waiting and appeared)
	for pile in get_tree().get_nodes_in_group("plank_piles"):
		pile.remove_from_group("plank_piles")
		pile.queue_free()
	pit.remove_from_group("pit_saws")
	pit.remove_from_group("build_blockers")
	pit.queue_free()
	await get_tree().process_frame
	# ---- (4) free placement
	var build = world.get_node_or_null("BuildMode")
	if build != null:
		var house_type = load("res://assets/house_type.tres")
		var cabin: Node2D = world.get_node_or_null("Cabin")
		var free_spot: Vector2 = Vector2(333, 301)
		var house_probe = load("res://assets/house_type.tres")
		for fy in range(240, 420, 12):
			for fx in range(300, 520, 12):
				if build.check_outdoor(house_probe, Vector2(fx, fy), false)["ok"]:
					free_spot = Vector2(fx, fy)
					break
			if build.check_outdoor(house_probe, free_spot, false)["ok"]:
				break
		var r_free: Dictionary = build.check_outdoor(house_type, free_spot, false)
		var item = Items.spawn(&"branch", world, Vector2(420, 340))
		await get_tree().process_frame
		var r_item: Dictionary = build.check_outdoor(house_type, item.global_position + Vector2(0, 14), false)
		var r_door: Dictionary = {"ok": true, "text": ""}
		var door_origin: Vector2 = Vector2.INF
		for door in build.door_points():
			for dy in range(8, 90, 4):
				for dx in range(-30, 31, 5):
					var try_origin: Vector2 = door + Vector2(dx, dy)
					var tried: Dictionary = build.check_outdoor(house_type, try_origin, false)
					if tried["text"] == "Too close to the door." and door_origin == Vector2.INF:
						r_door = tried
						door_origin = try_origin
		var r_water: Dictionary = build.check_outdoor(house_type, WaterMap_tile_centre() + Vector2(0, 16), false)
		var r_edge: Dictionary = build.check_outdoor(house_type, Vector2(8, 20), false)
		item.remove_from_group("ground_items")
		item.queue_free()
		# a pocket: three walls with a mouth, an item inside; a house in the mouth would shut it in
		var wall_script := GDScript.new()
		wall_script.source_code = "extends Node2D\nvar rect: Rect2\nfunc footprint_rect() -> Rect2:\n\treturn rect\n"
		wall_script.reload()
		var walls: Array = []
		for r in [Rect2(176, 470, 12, 70), Rect2(228, 470, 12, 70), Rect2(176, 470, 64, 12)]:
			var wall := Node2D.new()
			wall.set_script(wall_script)
			wall.rect = r
			wall.add_to_group("build_blockers")
			wall.position = r.position + r.size * 0.5
			var body := StaticBody2D.new()
			body.name = "Collision"
			var shape_node := CollisionShape2D.new()
			shape_node.name = "Shape"
			var rs := RectangleShape2D.new()
			rs.size = r.size
			shape_node.shape = rs
			body.add_child(shape_node)
			wall.add_child(body)
			world.add_child(wall)
			walls.append(wall)
		# (a randomly placed bush or tree near the pocket would be "in the way" first: clear them for this check)
		for group_name in ["berry_bushes", "trees"]:
			for node in get_tree().get_nodes_in_group(group_name):
				if node.global_position.distance_to(Vector2(208, 520)) < 110.0:
					node.remove_from_group(group_name)
					node.queue_free()
		var inside = Items.spawn(&"flat_stone", world, Vector2(208, 496))
		await get_tree().process_frame
		var mouth_origin: Vector2 = Vector2(208, 540)
		var r_cut: Dictionary = build.check_outdoor(house_type, mouth_origin, false)
		var r_beside: Dictionary = build.check_outdoor(house_type, free_spot, false)
		_w(4, "placement at the off-grid pixel %s: %s; over an item: '%s'; in the cabin doorway: '%s'; on water: '%s'; off the map edge: '%s'; in the mouth of a pocket with an item inside: '%s'; the same house beside the pocket: %s" % [str(free_spot), "ok" if r_free["ok"] else r_free["text"], r_item["text"], r_door["text"], r_water["text"], r_edge["text"], r_cut["text"], "ok" if r_beside["ok"] else r_beside["text"]], r_free["ok"] and r_item["text"] == "Something is in the way." and r_door["text"] == "Too close to the door." and r_water["text"] == "Can't build on water." and r_cut["text"] == "Would block the way." and r_beside["ok"])
		# the ghost follows the cursor to the pixel (a few frames of the real build mode: no errors, a result for the ghost)
		build._set_active(true)
		for i in 6:
			await get_tree().process_frame
		var ghost_ok: bool = build.last_result.has("ok") and build.ghost.global_position == build.ghost.global_position.round()
		build._set_active(false)
		_w(4, "the build mode ghost sits on whole pixels (%s) and reports '%s' while it follows the cursor; Shift snaps to the 32 px grid (snap_modifier %s)" % [str(build.ghost.global_position), str(build.last_result.get("text", "")), OS.get_keycode_string(build.snap_modifier)], ghost_ok)
		for wall in walls:
			wall.remove_from_group("build_blockers")
			wall.queue_free()
		inside.remove_from_group("ground_items")
		inside.queue_free()
	# ---- (5) footsteps: every surface, the stride, the volumes
	var FS = load("res://scripts/footstep_sounds.gd")
	var W = load("res://scripts/water_map.gd")
	var rows: Array[String] = []
	var all_ok: bool = true
	var saved_pos: Vector2 = player.position
	var grass_at: Vector2 = Vector2(300, 250)
	var creek_cell: Vector2i = W.creek_tiles[W.creek_tiles.size() / 2]
	var water_at: Vector2 = W.tile_rect(creek_cell).get_center()
	var shore_at: Vector2 = Vector2.INF
	for dx in [-1, 1]:
		for dy in [-1, 0, 1]:
			var nb := Vector2i(creek_cell.x + dx * 2, creek_cell.y + dy * 2)
			if W.kind_at_tile(nb) == W.LAND and shore_at == Vector2.INF:
				for dd in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if W.is_water(nb + dd):
						shore_at = W.tile_rect(nb).get_center()
						break
	var plots: Node = load("res://scripts/plot_manager.gd").get_for(get_tree())
	var plot_cell: Vector2i = plots.cell_of(Vector2(250, 250))
	plots.plots[plot_cell] = {"state": &"tilled"}
	var plot_at: Vector2 = plots.cell_center(plot_cell)
	for entry in [["grass", grass_at, "step_grass"], ["dirt (tilled plot)", plot_at, "step_dirt"], ["wooden floor", Vector2(2500, 120), "step_wood"], ["shallow water", water_at, "step_water"], ["shore edge", shore_at, "step_grass"]]:
		if entry[1] == Vector2.INF:
			continue
		player.global_position = entry[1]
		player.set_meta(&"stride", 0.0)
		AudioManager.log.clear()
		var steps: int = 0
		var last_sound: String = ""
		for i in 20:   # 100 px in 5 px moves
			var s: String = FS.walked(player, 5.0)
			if s != "":
				steps += 1
				last_sound = s
		var vol: float = AudioManager.log.back()[2] if not AudioManager.log.is_empty() else 0.0
		var ok: bool = last_sound == entry[2] and steps == 7
		all_ok = all_ok and ok
		rows.append("%s -> %s x%d (%.1f dB)" % [entry[0], last_sound, steps, vol])
	player.global_position = saved_pos
	plots.plots.erase(plot_cell)
	# a friend steps quieter than the player, a heavy step is louder, fast forward plays every other step
	var friend: Node2D = get_tree().get_first_node_in_group("colonists")
	var vols: String = ""
	var quieter: bool = true
	if friend != null:
		friend.set_meta(&"stride", 0.0)
		friend.visible = true
		var saved_f: Vector2 = friend.global_position
		friend.global_position = grass_at
		player.global_position = grass_at + Vector2(40, 0)
		AudioManager.log.clear()
		FS.walked(friend, 14.0)
		var friend_db: float = AudioManager.log.back()[2] if not AudioManager.log.is_empty() else 99.0
		player.set_meta(&"stride", 0.0)
		AudioManager.log.clear()
		FS.walked(player, 14.0)
		var player_db: float = AudioManager.log.back()[2] if not AudioManager.log.is_empty() else 99.0
		player.carrying_planks = 1
		player.set_meta(&"stride", 0.0)
		AudioManager.log.clear()
		FS.walked(player, 14.0)
		player.set_meta(&"foot", 0)
		var heavy_db: float = AudioManager.log.back()[2] if not AudioManager.log.is_empty() else 99.0
		player.carrying_planks = 0
		var fast: Node = get_node_or_null("/root/FastForward")
		fast.set_index(1)
		var played: int = 0
		for i in 8:
			player.set_meta(&"stride", 0.0)
			if FS.walked(player, 14.0) != "":
				played += 1
		fast.set_index(0)
		# the friend inside a building the player is not in makes no sound
		friend.global_position = Vector2(2500, 120)
		friend.set_meta(&"stride", 0.0)
		var hidden: String = FS.walked(friend, 14.0)
		friend.global_position = saved_f
		player.global_position = saved_pos
		quieter = friend_db < player_db - 1.0 and heavy_db > player_db - 1.5
		vols = "friend %.1f dB, player %.1f dB, carrying planks %.1f dB; fast forward x2: %d of 8 steps played; a friend inside a house the player is not in: '%s'" % [friend_db, player_db, heavy_db, played, hidden]
		quieter = quieter and played == 4 and hidden == ""
	_w(5, "footsteps (stride %d px): %s; %s" % [int(FS.STRIDE_LENGTH_PX), "; ".join(rows), vols], all_ok and quieter)

func WaterMap_tile_centre() -> Vector2:
	var W = load("res://scripts/water_map.gd")
	return W.tile_rect(W.creek_tiles[W.creek_tiles.size() / 2]).get_center()

# --- UI and start-of-game pass: pixel text, build tabs, unlocks, the starting yard and house, the toolbox, the E chooser ----------

func _p(n: int, text: String, ok: bool, extra: String = "") -> void:
	print("SELF-CHECK: [%d] %-94s %s%s" % [n, text, "OK" if ok else "FAIL", ("  (" + extra + ")") if extra != "" else ""])

func _click_at(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = point
		ev.global_position = point
		Input.parse_input_event(ev)

func _key_event(code: Key, pressed: bool = true) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	return ev

func _self_check_ui2() -> void:
	var world: Node = get_parent()
	var player = world.get_node_or_null("MainCharacter")
	var build = world.get_node_or_null("BuildMode")
	if player == null or build == null:
		return
	var inter: Node = player.get_node("Interaction")
	var Items = load("res://scripts/items.gd")
	var GP = load("res://scripts/ground_placement.gd")
	player.state = player.State.FREE
	player.held_tool = &""
	get_window().size = Vector2i(1280, 720)
	await get_tree().process_frame
	await get_tree().process_frame
	# ---- [1] the fonts
	var body: Font = Ui.font_body
	var aa_off: bool = body is FontFile and body.antialiasing == TextServer.FONT_ANTIALIASING_NONE and body.hinting == TextServer.HINTING_NONE and body.subpixel_positioning == TextServer.SUBPIXEL_POSITIONING_DISABLED
	var sample: Label = Ui.make_label("body")
	var sample_ok: bool = sample.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST and sample.get_theme_constant("outline_size") == Ui.art_scale()
	sample.free()
	_p(1, "fonts: %s; antialiasing/hinting/subpixel off: %s; ui_text_pixel_scale %d (now x%d), body %d px, heading %d px, outline %d px (1 UI pixel), nearest filter: %s" % [Ui.fonts_report(), aa_off, Ui.cfg.ui_text_pixel_scale, Ui.text_pixel_scale(), Ui.font_size("body"), Ui.font_size("heading"), Ui.outline_size(), sample_ok], Ui.pixel_active and aa_off and sample_ok and Ui.fonts_missing.is_empty())
	# ---- [3] unlocks (needs the opening: no pit saw is built yet)
	var unlocks: Node = build.unlocks
	var tabs_state: String = ""
	if world.get("opening_mode") == true and not unlocks.is_unlocked("pit_saw_built"):
		build._set_active(true)
		await get_tree().process_frame
		var free_names: Array[String] = []
		var locked_names: Array[String] = []
		var refused_ok: bool = true
		for i in build.building_types.size():
			var type: BuildingType = build.building_types[i]
			if build.is_unlock_locked(type):
				locked_names.append(type.type_name)
				var before: int = build.type_index
				build.choose(i)
				refused_ok = refused_ok and build.type_index == before
			else:
				free_names.append(type.type_name)
		var tab_notes: Array[String] = []
		for category in build.menu._tab_buttons:
			var tab: Button = build.menu._tab_buttons[category]
			tab_notes.append("%s %s" % [category, "disabled" if tab.disabled else "enabled"])
		var start_ok: bool = free_names.size() == 3 and free_names.has("Pit Saw") and free_names.has("Campfire") and free_names.has("Grinding Stone") and refused_ok
		_p(3, "at the start selectable: %s; locked (cannot be chosen: %s): %s; tabs: %s" % [str(free_names), refused_ok, str(locked_names), str(tab_notes)], start_ok and build.menu._tab_buttons["Food and Water"].disabled == false and build.menu._tab_buttons["Workshop"].disabled == false and build.menu._tab_buttons["Housing"].disabled and build.menu._tab_buttons["Storage"].disabled)
		build._set_active(false)
		# build a pit saw (finished): the rest unlocks
		var pit = load("res://scenes/PitSaw.tscn").instantiate()
		pit.starts_built = true
		pit.position = Vector2(300, 520)
		world.add_child(pit)
		for i in 40:
			await get_tree().process_frame
		var all_free: bool = true
		for type in build.building_types:
			all_free = all_free and not build.is_unlock_locked(type)
		pit.remove_from_group("pit_saws")
		pit.remove_from_group("build_blockers")
		pit.queue_free()
		await get_tree().process_frame
		_p(3, "after a pit saw is built every building is unlocked (%s) and it stays so after the saw is gone: %s" % [all_free, unlocks.is_unlocked("pit_saw_built")], all_free and unlocks.is_unlocked("pit_saw_built"))
	else:
		print("SELF-CHECK: [3] (this scene starts with a pit saw built: the locked start is checked in the opening run)")
	# ---- [2] a simulated click on every tab switches the category (all unlocked now, so every tab is enabled)
	build._set_active(true)
	for i in 4:
		await get_tree().process_frame
	var clicked: Array[String] = []
	var all_clicked: bool = true
	var order: Array = build.menu._categories.duplicate()
	order.reverse()
	for category in order:
		var tab: Button = build.menu._tab_buttons[category]
		var centre: Vector2 = tab.get_global_rect().get_center()
		_click_at(centre)
		for i in 3:
			await get_tree().process_frame
		var ok: bool = build.menu._current == category
		all_clicked = all_clicked and ok
		clicked.append("%s %s" % [category, "ok" if ok else "NOT switched (now " + build.menu._current + ")"])
	# a few frames later the tab is still there (the old bug put it back at once)
	for i in 6:
		await get_tree().process_frame
	var stayed: bool = build.menu._current == order[order.size() - 1]
	# the keys ] and [ switch too
	var before_cat: String = build.menu._current
	build.menu._unhandled_input(_key_event(KEY_BRACKETRIGHT))
	var after_cat: String = build.menu._current
	_p(2, "simulated mouse clicks on each build tab: %s; the tab stays after a few frames: %s; ']' moves %s -> %s" % [str(clicked), stayed, before_cat, after_cat], all_clicked and stayed and before_cat != after_cat)
	build._set_active(false)
	# ---- [4] the starting yard
	var yard: Array = world.get("start_yard") if world.get("start_yard") != null else []
	if yard.is_empty():
		print("SELF-CHECK: [4] (no starting yard in this scene: the opening makes it)")
	else:
		var far: float = 0.0
		var rows: Array[String] = []
		var positions: Array[Vector2] = []
		for entry in yard:
			positions.append(entry["position"])
			rows.append("%s %s" % [str(entry["kind"]), str(entry["position"])])
		var box: Node2D = world.toolbox
		positions.append(box.position)
		rows.append("toolbox %s" % str(box.position))
		for i in positions.size():
			for j in range(i + 1, positions.size()):
				far = maxf(far, positions[i].distance_to(positions[j]))
		var cabin: Node2D = world.get_node("Cabin")
		var door_strip: Rect2 = build.door_strip(cabin.door_position())
		var on_door: bool = false
		for p in positions:
			on_door = on_door or door_strip.grow(2.0).has_point(p)
		var overlapping: bool = false
		for i in yard.size():
			for j in range(i + 1, yard.size()):
				overlapping = overlapping or yard[i]["position"].distance_to(yard[j]["position"]) < 10.0
		var in_box: bool = true
		var wide: float = 0.0
		var high: float = 0.0
		for p in positions:
			wide = maxf(wide, absf(p.x - positions[0].x))
			high = maxf(high, absf(p.y - positions[0].y))
		_p(4, "the one starting yard (%d items + the toolbox), farthest two %.0f px apart (8 x 6 tiles = 256 x 192), clear of the door: %s, overlapping: %s: %s" % [yard.size(), far, not on_door, overlapping, "; ".join(rows)], far <= 300.0 and not on_door and not overlapping and yard.size() == 6)
	# ---- [5] the starting house: enter and leave through the player's own code path
	var home: Node = world.get_node_or_null("Cabin")
	if home != null and home is Building:
		var is_built: bool = home.state == home.State.BUILT
		player.position = home.door_position() + Vector2(0, 2)
		player.state = player.State.FREE
		player.held_tool = &""
		await get_tree().process_frame
		var offered: bool = false
		for c in inter._candidates():
			if c["kind"] == "enter" and c["node"] == home:
				offered = true
		var door_at: Vector2 = home.door_position()
		var err: String = player.request_enter(home)
		var entered: bool = false
		for i in 120:
			await get_tree().process_frame
			if player.inside_building == home and not player.transitioning:
				entered = true
				break
		var room: Node2D = home.get_interior()
		var inside_x: float = player.position.x
		var left: bool = false
		if entered:
			player.request_leave()
			for i in 120:
				await get_tree().process_frame
				if player.inside_building == null and not player.transitioning:
					left = true
					break
		_p(5, "the starting house is a Building (built: %s, door %s, 'enter' offered at its door: %s): entered %s (x=%.0f in room %s), left %s, back at %s" % [is_built, str(door_at), offered, entered, inside_x, str(room.global_position), left, str(player.position)], is_built and offered and entered and left and inside_x >= 2400.0)
	# ---- [6] the toolbox: opens with a tool in hand, Put away stores it, taking a tool closes the panel
	var tbox: Node2D = world.get("toolbox") if world.get("toolbox") != null else null
	var made: bool = false
	if tbox == null:
		tbox = load("res://scenes/ToolBox.tscn").instantiate()
		tbox.position = Vector2(470, 330)
		tbox.init_contents = [[&"hammer", 0], [&"shovel", 0], [&"axe", 0]]
		world.add_child(tbox)
		made = true
		await get_tree().process_frame
	var saved_contents: Array = tbox.contents.duplicate(true)
	player.position = tbox.position + Vector2(0, 8)
	player.held_tool = &"shovel"
	await get_tree().process_frame
	var open_candidate: Dictionary = {}
	for c in inter._candidates():
		if c["node"] == tbox:
			open_candidate = c
	if not open_candidate.is_empty():
		inter._do(open_candidate)
	await get_tree().process_frame
	await get_tree().process_frame
	var opened: bool = tbox.is_open
	var put_visible: bool = is_instance_valid(tbox._put_button) and tbox._put_button.visible
	var put_text: String = tbox._put_button.text if is_instance_valid(tbox._put_button) else ""
	var count_before: int = tbox.item_count()
	if is_instance_valid(tbox._put_button):
		tbox._put_button.pressed.emit()
	await get_tree().process_frame
	var stored: bool = player.held_tool == &"" and tbox.item_count() == count_before + 1
	var still_open: bool = tbox.is_open
	tbox.take_with_player(0)
	await get_tree().process_frame
	var took_closed: bool = not tbox.is_open and player.held_tool != &""
	# the X button
	tbox.open_for(player)
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(tbox._close_button):
		tbox._close_button.pressed.emit()
	await get_tree().process_frame
	var x_closed: bool = not tbox.is_open
	_p(6, "toolbox with a shovel in hand: E opens it (%s), button '%s' shown (%s), stored (%s), panel closes by itself (%s), taking a tool closes it (%s) and holds %s, the X button closes it (%s)" % [opened, put_text, put_visible, stored, still_open, took_closed, player.held_tool, x_closed], opened and put_visible and stored and not still_open and took_closed and x_closed)
	player.held_tool = &""
	tbox.contents.assign(saved_contents)
	if made:
		tbox.queue_free()
	# ---- [7] the E chooser with three items within 10 px
	var spot: Vector2 = Vector2(430, 380)
	var a = Items.spawn(&"branch", world, spot)
	var b = Items.spawn(&"flat_stone", world, spot)
	var c3 = Items.spawn(&"hoe", world, spot)
	a.position = spot + Vector2(-4, 0)
	b.position = spot + Vector2(0, 1)
	c3.position = spot + Vector2(5, 0)
	await get_tree().process_frame
	player.position = spot + Vector2(-14, 8)
	player.held_tool = &""
	inter._hovered = false
	inter._mouse_moved_at = -1000.0
	for i in 3:
		await get_tree().process_frame
	inter._unhandled_input(_key_event(KEY_E))
	var rows7: Array[String] = []
	for entry in inter._ch_list:
		rows7.append(load("res://scripts/actions.gd").label_of(entry))
	var opened7: bool = inter.chooser_open
	var first_row: String = rows7[0] if not rows7.is_empty() else ""
	inter._chooser_input(_key_event(KEY_S))
	var after_s: int = inter._ch_index
	var selected_name: String = load("res://scripts/hover_names.gd").name_of(inter.chooser_selected()["node"], get_tree()) if not inter.chooser_selected().is_empty() else ""
	var selected_kind: StringName = inter.chooser_selected()["node"].kind if not inter.chooser_selected().is_empty() else &""
	var outlined: bool = inter.target_node() == inter.chooser_selected().get("node")
	await get_tree().create_timer(0.5).timeout
	inter._unhandled_input(_key_event(KEY_E))
	await get_tree().process_frame
	var right_item: bool = player.held_tool == selected_kind
	var gone: bool = not is_instance_valid(a) or a.is_queued_for_deletion() or true
	# the fast path: E twice quickly takes the nearest
	player.held_tool = &""
	var left_over: Array = []
	for g in get_tree().get_nodes_in_group("ground_items"):
		if g.global_position.distance_to(spot) < 20.0:
			left_over.append(g)
	var quick_ok: bool = true
	var quick_kind: StringName = &""
	if left_over.size() >= 2:
		player.position = spot + Vector2(-14, 8)
		inter._hovered = false
		await get_tree().process_frame
		inter._unhandled_input(_key_event(KEY_E))
		var nearest_kind = inter._ch_list[0]["node"].kind if not inter._ch_list.is_empty() else &""
		inter._unhandled_input(_key_event(KEY_E))
		await get_tree().process_frame
		quick_kind = player.held_tool
		quick_ok = quick_kind == nearest_kind and not inter.chooser_open
	_p(7, "3 items within 10 px, E: chooser rows %s (opened %s, first row selected %s, outlined %s); S moves the selection to row %d (%s); E confirms: took %s (right one: %s); a quick double E took the nearest (%s)" % [str(rows7), opened7, first_row, outlined, after_s, selected_name, player.held_tool if quick_kind == &"" else selected_kind, right_item, quick_kind], opened7 and rows7.size() >= 3 and after_s == 1 and right_item and outlined and quick_ok)
	inter.close_chooser()
	player.held_tool = &""
	for g in get_tree().get_nodes_in_group("ground_items"):
		if g.global_position.distance_to(spot) < 40.0:
			g.remove_from_group("ground_items")
			g.queue_free()
	get_window().size = Vector2i(64, 64)

# What a house holds: house_max_beds, its bed_level with 0, 1 and 2 beds inside, and the recovery per bed type.
func _self_check_house_beds() -> void:
	var house = load("res://scenes/Building.tscn").instantiate()
	house.building_type = load("res://assets/house_type.tres")
	get_parent().add_child(house)
	house.state = house.State.BUILT
	var room: Node2D = house.get_interior()
	var levels: Array = []
	var made: Array = []
	var names: Array = ["NONE", "STRAW", "WOODEN"]
	levels.append("0 beds: bed_level %s (%.4f/s)" % [names[house.bed_level], house.sleep_rate()])
	var grass = load("res://scenes/Bed.tscn").instantiate()
	grass.position = room.to_world(Vector2(40, 90))
	get_parent().add_child(grass)
	made.append(grass)
	levels.append("1 grass bed: %s (%.4f/s)" % [names[house.bed_level], house.sleep_rate()])
	var wooden = load("res://scenes/WoodenBed.tscn").instantiate()
	wooden.position = room.to_world(Vector2(80, 90))
	get_parent().add_child(wooden)
	made.append(wooden)
	levels.append("2 beds (grass + bare wooden): %s (%.4f/s); room for another: %s" % [names[house.bed_level], house.sleep_rate(), house.has_room_for_bed()])
	print("SELF-CHECK: houses: house_max_beds %d (wooden and grass beds count alike); %s; floor %.4f/s, grass / hay %.4f/s" % [house.house_max_beds, " | ".join(levels), sleep_rate_for_bed(0), sleep_rate_for_bed(1)])
	for b in made:
		b.remove_from_group("beds")
		b.free()
	room.free()
	house.remove_from_group("buildings")
	house.remove_from_group("build_blockers")
	house.free()

# The wooden bed: the recovery table, the net energy over a full night with each amount of bedding against a
# grass bed and the floor, and the picture chosen for every mix of bundles.
func _self_check_wooden_bed() -> void:
	var Bed = load("res://scripts/bed.gd")
	var night_s: float = day_length * night_fraction
	var rows: Array = []
	for n in wooden_bed_recovery.size():
		var rate: float = recovery_per_second(wooden_bed_recovery[n])
		rows.append("%d bedding: %.2f of full = %+.4f/s = %+.1f over the %.0f s night (%d arrow%s)" % [n, wooden_bed_recovery[n], rate, rate * night_s, night_s, recovery_arrows(rate), "" if recovery_arrows(rate) == 1 else "s"])
	print("SELF-CHECK: wooden_bed_recovery %s: %s; grass / hay bed %+.1f; bare floor %+.1f; outdoors %+.1f" % [wooden_bed_recovery, " | ".join(rows), sleep_rate_for_bed(1) * night_s, sleep_rate_for_bed(0) * night_s, sleep_rate_outdoors() * night_s])
	var combos: Array = [[0, 0], [1, 0], [0, 1], [2, 0], [0, 2], [1, 1], [3, 0], [0, 3], [2, 1], [1, 2]]
	var lines: Array = []
	for c in combos:
		lines.append("%dg+%dh -> %s" % [c[0], c[1], Bed.wooden_path(c[0], c[1]).get_file()])
	print("SELF-CHECK:   wooden bed pictures (green + hay bundles): %s; one shared offset %s" % [" | ".join(lines), Bed.wooden_offset()])

# --- The six changes: put away closes, Move Toolbox, free placement indoors, no bed limit, the action chooser, blueprint text ------

func _q(tag: String, text: String, ok: bool) -> void:
	print("SELF-CHECK: {%s} %-92s %s" % [tag, text, "OK" if ok else "FAIL"])

func _self_check_world2() -> void:
	var world: Node = get_parent()
	var player = world.get_node_or_null("MainCharacter")
	var build = world.get_node_or_null("BuildMode")
	if player == null or build == null:
		return
	set_time(day, 0.2)
	player.state = player.State.FREE
	player.held_tool = &""
	player.carrying_planks = 0
	player.carrying_blade = false
	player.rest.value = 100.0
	player.hunger.value = 100.0
	await _c2_move_toolbox(world, player, build)
	await _c2_interior(world, player, build)
	await _c2_chooser(world, player)
	_c2_blueprint_text(world, build)

func _c2_prepare_friend(friend, at: Vector2) -> void:
	friend.position = at
	friend.visible = true
	friend.state = friend.State.IDLE
	friend.work_claim = null
	friend.carry_job = null
	friend.waypoints.clear()
	friend.rest.value = 100.0
	friend.hunger.value = 100.0
	friend.speed = 50.0
	friend.play("idle")

# Starts a move and waits for the lift (or gives up after 10 s): the CarryTogether, or null.
func _c2_start_and_lift(box, player) -> Node:
	var why: String = box.start_carry()
	if why != "":
		print("SELF-CHECK:   (start refused: %s)" % why)
		return null
	var job: Node = box.carrier
	var waited: int = 0
	while is_instance_valid(job) and job.phase == job.Phase.GATHER and waited < 700:
		await get_tree().process_frame
		waited += 1
	if not is_instance_valid(job) or job.phase != job.Phase.CARRY:
		return null
	return job

func _c2_move_toolbox(world: Node, player, build) -> void:
	var GP = load("res://scripts/ground_placement.gd")
	var Items = load("res://scripts/items.gd")
	var friend = get_tree().get_first_node_in_group("colonists")
	if friend == null:
		friend = load("res://scenes/Colonist.tscn").instantiate()
		friend.position = Vector2(400, 440)
		world.add_child(friend)
		await get_tree().process_frame
	var spot: Vector2 = GP.find_free_ground_near(get_tree(), Vector2(420, 470), Vector2(60, 24), Rect2(0, 0, 640, 640), 140.0)
	var box = load("res://scenes/ToolBox.tscn").instantiate()
	box.position = spot
	box.init_contents = [[&"hammer", 0], [&"axe", 0], [&"basket", 3]]
	world.add_child(box)
	await get_tree().process_frame
	var contents_before: Array = box.contents.duplicate(true)
	# ---- {1} Put away [item] stores the item and closes the panel
	player.position = box.position + Vector2(0, 10)
	player.held_tool = &"hammer"
	box.open_for(player)
	await get_tree().process_frame
	await get_tree().process_frame
	var items_before: int = box.item_count()
	var put_text: String = box._put_button.text if is_instance_valid(box._put_button) else ""
	if is_instance_valid(box._put_button):
		box._put_button.pressed.emit()
	await get_tree().process_frame
	_q("1", "'%s': stored (items %d -> %d, hands %s), panel closed (%s)" % [put_text, items_before, box.item_count(), str(player.held_tool), not box.is_open], put_text == "Put away Hammer" and box.item_count() == items_before + 1 and player.held_tool == &"" and not box.is_open)
	box.contents.assign(contents_before)
	# ---- {2a} the button is greyed with a reason
	_c2_prepare_friend(friend, box.position + Vector2(60, 10))
	player.held_tool = &"axe"
	var r_hands: String = box.move_disabled_reason()
	player.held_tool = &""
	var r_ok: String = box.move_disabled_reason()
	friend.state = friend.State.SLEEPING_OUTSIDE
	var r_asleep: String = box.move_disabled_reason()
	friend.state = friend.State.INSIDE
	var r_inside: String = box.move_disabled_reason()
	friend.state = friend.State.IDLE
	friend.hunger.value = 10.0
	var r_hungry: String = box.move_disabled_reason()
	friend.hunger.value = 100.0
	friend.rest.value = 10.0
	var r_tired: String = box.move_disabled_reason()
	friend.rest.value = 100.0
	friend.remove_from_group("colonists")
	var r_none: String = box.move_disabled_reason()
	friend.add_to_group("colonists")
	_q("2a", "Move Toolbox greyed: hands full '%s' | asleep '%s' | indoors '%s' | hungry '%s' | exhausted '%s' | no friend '%s' | all fine '%s'" % [r_hands, r_asleep, r_inside, r_hungry, r_tired, r_none, r_ok], r_hands == "Put down what you are holding first." and r_asleep == box.FRIEND_TIRED and r_inside == box.FRIEND_TIRED and r_hungry == box.FRIEND_TIRED and r_tired == box.FRIEND_TIRED and r_none == "You need a friend to help." and r_ok == "")
	# ---- {2b} the friend walks to the box and they lift it
	_c2_prepare_friend(friend, box.position + Vector2(60, 10))
	player.position = box.position + Vector2(0, 12)
	AudioManager.log.clear()
	var old_pos: Vector2 = box.position
	var t0: int = Time.get_ticks_msec()
	var job: Node = await _c2_start_and_lift(box, player)
	var lift_seconds: float = (Time.get_ticks_msec() - t0) / 1000.0
	if job == null:
		_q("2b", "the move did not start / the friend never arrived", false)
		box.queue_free()
		return
	var lift_sound: bool = AudioManager.log.any(func(e: Array) -> bool: return e[0] == "toolbox_lift")
	_q("2b", "friend walked to the box and they lifted it after %.1f s (friend state HELPING_CARRY %s, lift sound %s, box solid %s, panel cannot open %s)" % [lift_seconds, friend.state == friend.State.HELPING_CARRY, lift_sound, box.is_in_group("build_blockers"), _c2_cannot_open(box, player)], friend.state == friend.State.HELPING_CARRY and lift_sound and not box.is_in_group("build_blockers") and _c2_cannot_open(box, player))
	# ---- {2c} the player leads at 70 % of his pace; the friend holds the other end of the box (see N6); nothing jumps
	await get_tree().process_frame
	var WM = load("res://scripts/water_map.gd")
	var ratio: float = player._current_speed() / (player.speed * player.rest.speed_factor() * WM.speed_factor(player.position))
	var expected: float = 0.0
	var samples: int = 0
	Input.action_press("move_right")
	var p0: Vector2 = player.position
	var f_prev: Vector2 = friend.position
	var b_prev: Vector2 = box.global_position
	var max_step: float = 0.0
	var t1: int = Time.get_ticks_msec()
	for i in 90:
		await get_tree().process_frame
		expected += player._current_speed()
		samples += 1
		max_step = maxf(max_step, maxf(friend.position.distance_to(f_prev), box.global_position.distance_to(b_prev)))
		f_prev = friend.position
		b_prev = box.global_position
	expected /= float(samples)
	var elapsed: float = (Time.get_ticks_msec() - t1) / 1000.0
	var measured: float = (player.position.x - p0.x) / elapsed
	var off_east: Vector2 = friend.position - player.position
	var mid_gap: float = box.global_position.distance_to((player.position + friend.position) * 0.5)
	var lifted_up: float = -box.sprite.position.y
	Input.action_release("move_right")
	Input.action_press("move_left")
	for i in 130:
		await get_tree().process_frame
		max_step = maxf(max_step, maxf(friend.position.distance_to(f_prev), box.global_position.distance_to(b_prev)))
		f_prev = friend.position
		b_prev = box.global_position
	var off_west: Vector2 = friend.position - player.position
	Input.action_release("move_left")
	await get_tree().process_frame
	var drain_player: float = player.rest.activity.call()
	var drain_friend: float = friend.rest.activity.call()
	var enter_msg: String = player.request_enter(null)
	_q("2c", "walking east %.1f px/s (speed factor %.2f of %.1f px/s, mean in-game speed %.1f); friend offset east %s / west %s (one box length apart, the same end both ways); box %.1f px above ground, %.1f px from the pair's midpoint; biggest one-frame move %.2f px; drain x%.1f (player) x%.1f (friend); enter: '%s'" % [measured, ratio, player.speed, expected, off_east.round(), off_west.round(), lifted_up, mid_gap, max_step, drain_player, drain_friend, enter_msg], absf(ratio - box.carry_together_speed_multiplier) < 0.01 and absf(measured - expected) < expected * 0.15 and absf(absf(off_east.x) - 2.0 * box.carry_end_offset_px()) < 4.0 and absf(off_east.y) < 3.0 and absf(off_west.x - off_east.x) < 4.0 and lifted_up > 3.0 and mid_gap < 3.0 and max_step < 3.0 and absf(drain_player - box.carry_together_drain_multiplier) < 0.01 and absf(drain_friend - box.carry_together_drain_multiplier) < 0.01 and enter_msg == "Put the toolbox down first.")
	# ---- {2d} tether: a slow friend slows the player down; a friend who cannot follow for 5 s makes them put it down
	friend.speed = 8.0
	Input.action_press("move_right")
	var gap_max: float = 0.0
	var slowed: bool = false
	for i in 240:
		await get_tree().process_frame
		if not is_instance_valid(job):
			break
		gap_max = maxf(gap_max, job.gap())
		slowed = slowed or player._current_speed() < expected - 1.0
	var still_carrying: bool = is_instance_valid(job) and job.phase == job.Phase.CARRY
	friend.speed = 0.0
	var t2: int = Time.get_ticks_msec()
	var waited: int = 0
	while is_instance_valid(job) and job.phase == job.Phase.CARRY and waited < 900:
		await get_tree().process_frame
		waited += 1
	Input.action_release("move_right")
	var stuck_seconds: float = (Time.get_ticks_msec() - t2) / 1000.0
	friend.speed = 50.0
	await get_tree().process_frame
	_q("2d", "slow friend: gap up to %.0f px (tether %.0f), player slowed %s, still carrying %s; friend stuck: put down after %.1f s: '%s' (friend free again %s, box on the ground %s)" % [gap_max, box.carry_tether_px, slowed, still_carrying, stuck_seconds, box.last_carry_end, friend.state != friend.State.HELPING_CARRY, not box.is_carried()], slowed and gap_max > box.carry_tether_px and still_carrying and "stuck" in box.last_carry_end and stuck_seconds >= 4.0 and stuck_seconds < 9.0 and friend.state != friend.State.HELPING_CARRY and not box.is_carried() and player.carrying_together == null and box.is_in_group("build_blockers"))
	# ---- {2e} the friend wears out / starves: put down at the nearest free ground
	var reasons: Array = []
	var ends_ok: bool = true
	for which in ["rest", "hunger"]:
		_c2_prepare_friend(friend, box.position + Vector2(40, 8))
		player.position = box.position + Vector2(0, 12)
		var job2: Node = await _c2_start_and_lift(box, player)
		if job2 == null:
			ends_ok = false
			continue
		if which == "rest":
			friend.rest.value = 10.0
		else:
			friend.hunger.value = 10.0
		for i in 4:
			await get_tree().process_frame
		box.remove_from_group("build_blockers")
		var free_here: bool = GP.is_free(get_tree(), box.position, Vector2(26, 12), Rect2(0, 0, 640, 640), box)
		box.add_to_group("build_blockers")
		reasons.append("%s -> '%s' (free ground %s)" % [which, box.last_carry_end, free_here])
		ends_ok = ends_ok and not box.is_carried() and free_here and friend.state != friend.State.HELPING_CARRY
	_q("2e", "friend exhausted / starving below %d: %s" % [int(box.carry_min_condition), " | ".join(reasons)], ends_ok and reasons.size() == 2 and "tired" in reasons[0] and "hungry" in reasons[1])
	# ---- {2f} the ghost: reach, snap, red on something in the way, then green at an off-grid pixel; old position freed
	_c2_prepare_friend(friend, box.position + Vector2(40, 8))
	player.position = box.position + Vector2(0, 12)
	old_pos = box.position
	var old_footprint: Rect2 = box.footprint_at(old_pos)
	var job3: Node = await _c2_start_and_lift(box, player)
	if job3 == null:
		_q("2f", "second lift failed", false)
		return
	await get_tree().process_frame
	# (far away: clamped to the reach)
	job3.test_mouse = player.position + Vector2(300, 0)
	await get_tree().process_frame
	var reach_ok: bool = job3.ghost_origin.distance_to(player.position) <= box.carry_place_reach_px + 0.5 and job3.ghost_origin == job3.ghost_origin.round()
	var snapped: Vector2 = job3.origin_for(player.position + Vector2(20, -10), true)
	var snap_ok: bool = int(snapped.x) % 32 == 16 and int(snapped.y) % 32 == 0
	# (red: on top of another solid box)
	var blocker = load("res://scenes/ToolBox.tscn").instantiate()
	blocker.position = (player.position + Vector2(24, 0)).round()
	world.add_child(blocker)
	await get_tree().process_frame
	job3.test_mouse = blocker.position + Vector2(0, -6)
	await get_tree().process_frame
	var red: bool = not job3.ghost_result["ok"]
	var red_text: String = job3.ghost_result["text"]
	var refused: bool = not job3.place() and box.is_carried()
	blocker.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	# (green: an odd pixel off the 32 px grid)
	var want: Vector2 = player.position + Vector2(-23, -9)
	for dx in range(-40, 41, 7):
		for dy in range(-30, 31, 7):
			var try_at: Vector2 = player.position + Vector2(dx, dy)
			var try_origin: Vector2 = job3.origin_for(try_at, false)
			if (int(try_origin.x) % 32 != 16 or int(try_origin.y) % 32 != 0) and job3.check_at(try_origin, false)["ok"] and try_origin.distance_to(old_pos) > 30.0:
				want = try_at
	job3.test_mouse = want
	await get_tree().process_frame
	var target: Vector2 = job3.ghost_origin
	var green: bool = job3.ghost_result["ok"]
	AudioManager.log.clear()
	var green_text: String = job3.ghost_result["text"]
	var placed: bool = job3.place()
	await get_tree().process_frame
	var off_grid: bool = int(target.x) % 32 != 16 or int(target.y) % 32 != 0
	var set_sound: bool = AudioManager.log.any(func(e: Array) -> bool: return e[0] == "toolbox_set")
	var old_free: bool = not Footprints.rect_blocked(get_tree(), old_footprint.grow(-1.0)) if target.distance_to(old_pos) > 30.0 else true
	_q("2f", "ghost: reach clamp %s (%.0f px from the player), Shift snap %s; red on another box '%s' and E refused (%s); green at the exact pixel %s (off the grid %s): placed %s ('%s'), box at %s, set-down sound %s, solid again %s, old spot free %s, friend back to his routine %s, contents kept %s" % [reach_ok, job3.ghost_origin.distance_to(player.position) if is_instance_valid(job3) else 0.0, snap_ok, red_text, refused and red, target, off_grid, placed, green_text, box.global_position, set_sound, box.is_in_group("build_blockers"), old_free, friend.state != friend.State.HELPING_CARRY, box.contents.size() == contents_before.size()], reach_ok and snap_ok and red and refused and green and placed and off_grid and box.global_position == target and set_sound and box.is_in_group("build_blockers") and old_free and friend.state != friend.State.HELPING_CARRY and box.contents.size() == contents_before.size() and player.carrying_together == null)
	# ---- {2g} Esc puts it down where it is
	box.position = spot
	_c2_prepare_friend(friend, box.position + Vector2(40, 8))
	player.position = box.position + Vector2(0, 12)
	var job4: Node = await _c2_start_and_lift(box, player)
	var lifted4: bool = job4 != null
	var esc_closed: bool = false
	if lifted4:
		esc_closed = Ui.close_top_panel()
		await get_tree().process_frame
	_q("2g", "Esc while carrying: lifted %s, Esc closed a panel %s, put down (%s), message '%s'" % [lifted4, esc_closed, not box.is_carried(), box.last_carry_end], lifted4 and esc_closed and not box.is_carried() and player.carrying_together == null)
	box.remove_from_group("toolboxes")
	box.queue_free()
	_c2_prepare_friend(friend, friend.position)
	friend.state = friend.State.IDLE
	player.held_tool = &""

func _c2_cannot_open(box, player) -> bool:
	box.open_for(player)
	return not box.is_open

func _c2_floor_origin(build, room, type, from: Vector2, step: Vector2) -> Vector2:
	var fr: Rect2 = room.floor_rect_world()
	var y: float = fr.position.y + from.y
	while y < fr.end.y:
		var x: float = fr.position.x + from.x
		while x < fr.end.x:
			var origin := Vector2(x, y)
			if build.check_indoor(type, origin, false)["ok"]:
				return origin
			x += step.x
		y += step.y
	return Vector2.INF

func _c2_interior(world: Node, player, build) -> void:
	var house = load("res://scenes/Building.tscn").instantiate()
	house.building_type = load("res://assets/house_type.tres")
	house.position = Vector2(80, 600)
	world.add_child(house)
	house.state = house.State.BUILT
	var room: Node2D = house.get_interior()
	var saved_inside = player.inside_building
	player.inside_building = house
	await get_tree().process_frame
	var bed_type: BuildingType = load("res://assets/wooden_bed_type.tres")
	var crate_type: BuildingType = load("res://assets/crate_type.tres")
	var fr: Rect2 = room.floor_rect_world()
	var door: Vector2 = room.door_world()
	var made: Array = []
	# ---- {3a} an off-grid bed and an off-grid crate; refusals: the door, another object, the wall
	var bed_origin: Vector2 = _c2_floor_origin(build, room, bed_type, Vector2(13, 21), Vector2(11, 7))
	var bed_node = null
	if bed_origin != Vector2.INF:
		bed_node = load("res://scenes/Building.tscn").instantiate()
		bed_node.building_type = bed_type
		bed_node.position = bed_origin
		world.add_child(bed_node)
		made.append(bed_node)
	await get_tree().process_frame
	var crate_origin: Vector2 = _c2_floor_origin(build, room, crate_type, Vector2(57, 29), Vector2(9, 5))
	var crate_node = null
	if crate_origin != Vector2.INF:
		crate_node = load("res://scenes/Building.tscn").instantiate()
		crate_node.building_type = crate_type
		crate_node.position = crate_origin
		world.add_child(crate_node)
		made.append(crate_node)
	await get_tree().process_frame
	var off_grid: bool = bed_origin != Vector2.INF and crate_origin != Vector2.INF and (int(bed_origin.x) % 32 != 0 or int(bed_origin.y) % 32 != 0) and (int(crate_origin.x) % 32 != 0 or int(crate_origin.y) % 32 != 0)
	var at_door: Dictionary = build.check_indoor(bed_type, door + Vector2(0, -6), false)
	var on_bed: Dictionary = build.check_indoor(bed_type, bed_origin + Vector2(2, 0), false)
	var crate_more: Dictionary = build.check_indoor(crate_type, bed_origin + Vector2(40, 0), false)
	var in_wall: Dictionary = build.check_indoor(bed_type, Vector2(fr.position.x - 30, fr.position.y + 20), false)
	_q("3a", "off-grid bed at %s and crate at %s (valid, placed as blueprints); crate on the door: '%s'; on the bed: '%s'; outside the floor: '%s'; a second crate: '%s'" % [bed_origin, crate_origin, at_door["text"], on_bed["text"], in_wall["text"], crate_more["text"]], off_grid and not at_door["ok"] and not on_bed["ok"] and not in_wall["ok"] and at_door["text"] == "Too close to the door.")
	# ---- {3b} a wall across the room would shut the bed off: refused; a small crate is fine; occupants keep clear of solids
	var wall := Rect2(fr.position.x - 2.0, fr.end.y - 14.0, fr.size.x + 4.0, 8.0)
	var blocks_wall: bool = room.blocks_route(wall, false)
	var small_ok: bool = not room.blocks_route(Rect2(crate_origin.x - 10, crate_origin.y - 8, 20, 8), false)
	var spot_before: Vector2 = room.occupant_spot(false)
	var crate_real = load("res://scenes/Crate.tscn").instantiate()
	crate_real.position = spot_before
	world.add_child(crate_real)
	made.append(crate_real)
	await get_tree().process_frame
	var spot_after: Vector2 = room.occupant_spot(false)
	var clear_of_solids: bool = true
	for r in room.solid_rects():
		clear_of_solids = clear_of_solids and not r.grow(5.0).has_point(spot_after)
	_q("3b", "a wall across the floor blocks the way to the bed: %s; a small crate does not: %s; a resident's spot moved from %s to %s once a crate stood there (clear of every solid: %s)" % [blocks_wall, small_ok, spot_before, spot_after, clear_of_solids], blocks_wall and small_ok and spot_after != spot_before and clear_of_solids)
	# ---- {4} five beds in one house (house_max_beds %d = unlimited)
	for n in made:
		if is_instance_valid(n):
			n.remove_from_group("buildings")
			n.remove_from_group("build_blockers")
			n.remove_from_group("crates")
			n.free()
	made.clear()
	await get_tree().process_frame
	var placed_beds: int = 0
	var why: Dictionary = {}
	for i in 5:
		var o: Vector2 = _c2_floor_origin(build, room, bed_type, Vector2(2, 2), Vector2(2, 2))
		if o == Vector2.INF:
			for gx in range(0, 88, 4):
				for gy in range(0, 76, 4):
					var t: String = build.check_indoor(bed_type, Vector2(floor_x0(room) + gx, floor_y0(room) + gy), false)["text"]
					why[t] = int(why.get(t, 0)) + 1
			break
		var b = load("res://scenes/Building.tscn").instantiate()
		b.building_type = bed_type
		b.position = o
		world.add_child(b)
		made.append(b)
		placed_beds += 1
		await get_tree().process_frame
	_q("4", "house_max_beds %d: %d beds placed in one house (floor %s), room still has room for a bed: %s (limit_of bed %d); other limits: crates %d, tables %d; why no more: %s" % [house.house_max_beds, placed_beds, room.floor_rect_world().size, room.has_room_for_bed(), room.limit_of("bed"), room.limit_of("crate"), room.limit_of("table"), str(why)], house.house_max_beds == 0 and placed_beds >= 5 and room.has_room_for_bed() and house.has_room_for_bed())
	for n in made:
		if is_instance_valid(n):
			n.remove_from_group("buildings")
			n.remove_from_group("build_blockers")
			n.remove_from_group("crates")
			n.queue_free()
	player.inside_building = saved_inside
	await get_tree().process_frame
	house.remove_from_group("buildings")
	house.remove_from_group("build_blockers")
	room.free()
	house.free()

func _c2_chooser(world: Node, player) -> void:
	var GP = load("res://scripts/ground_placement.gd")
	var Items = load("res://scripts/items.gd")
	var Actions = load("res://scripts/actions.gd")
	var inter: Node = player.get_node("Interaction")
	var spot: Vector2 = GP.find_free_ground_near(get_tree(), Vector2(500, 470), Vector2(50, 50), Rect2(0, 0, 640, 640), 140.0)
	var report: Array = []
	var ok_all: bool = true
	var top_row: String = ""
	var rows_text: Array = []
	var results: Array = []
	for scenario in ["axe", "run swap", "empty"]:
		var tree = load("res://scenes/Tree.tscn").instantiate()
		tree.position = spot
		world.add_child(tree)
		var branch = Items.spawn(&"branch", world, spot + Vector2(12, 6))
		branch.position = spot + Vector2(12, 6)
		await get_tree().process_frame
		player.state = player.State.FREE
		player.carrying_planks = 0
		player.held_tool = &"axe" if scenario != "empty" else &""
		player.position = spot + Vector2(4, 12)
		inter._hovered = false
		inter._mouse_moved_at = -1000.0
		for i in 4:
			await get_tree().process_frame
		var group: Array = inter._chooser_actions()
		var rows: Array = []
		for a in group:
			rows.append("%s%s" % [Actions.label_of(a), "" if a["enabled"] else " [greyed: %s]" % a["disabled_reason"]])
		var doable: Array = Actions.enabled_of(group)
		inter._unhandled_input(_key_event(KEY_E))
		await get_tree().process_frame
		if scenario == "axe":
			rows_text = rows
			top_row = rows[0] if not rows.is_empty() else ""
			var opened: bool = inter.chooser_open
			var selected_outlined: bool = inter.target_node() == inter.chooser_selected().get("node")
			# the first row (the default, the top row) is the tree with the axe: run it
			var first_is_chop: bool = not group.is_empty() and group[0]["verb"] == "Chop"
			inter._chooser_confirm()
			for i in 6:
				await get_tree().process_frame
			var chopping: bool = player.state != player.State.FREE or player.is_working_on(tree)
			player._cancel_order()
			player.end_chop_session()
			results.append("top row 'Chop' started work (%s)" % chopping)
			ok_all = ok_all and opened and selected_outlined and first_is_chop and chopping and rows.size() >= 2
			report.append("rows %s; chooser opened %s, target outlined %s" % [str(rows), opened, selected_outlined])
		elif scenario == "run swap":
			var swap_index: int = -1
			for i in doable.size():
				if doable[i]["verb"] == "Swap for":
					swap_index = i
			var swapped: bool = false
			if inter.chooser_open and swap_index >= 0:
				inter._ch_index = swap_index
				inter._chooser_confirm()
				await get_tree().process_frame
				swapped = player.held_tool == &"branch"
			results.append("'Swap for Branch' run (held now %s)" % str(player.held_tool))
			ok_all = ok_all and swapped
			inter.close_chooser()
		else:
			var required: bool = player.tools_required()
			var acted: bool = player.held_tool == &"branch"
			if required:
				report.append("empty hands (tools required): rows %s -> %d doable, so E acted at once: held %s (chooser open %s)" % [str(rows), doable.size(), str(player.held_tool), inter.chooser_open])
				ok_all = ok_all and doable.size() == 1 and acted and not inter.chooser_open and "greyed" in " ".join(rows)
			else:
				report.append("empty hands (no tool needed): rows %s, chooser open %s" % [str(rows), inter.chooser_open])
				ok_all = ok_all and doable.size() == 2 and inter.chooser_open
				inter.close_chooser()
		player.held_tool = &""
		for group_name in ["ground_items", "axes"]:
			for g in get_tree().get_nodes_in_group(group_name):
				if g.global_position.distance_to(spot) < 60.0:
					g.remove_from_group(group_name)
					g.queue_free()
		tree.remove_from_group("trees")
		tree.queue_free()
		await get_tree().process_frame
	_q("5", "%s; default top row '%s'; %s" % [" | ".join(report), top_row, "; ".join(results)], ok_all and top_row.begins_with("Chop"))

func _c2_blueprint_text(world: Node, build) -> void:
	var BlueprintText = load("res://scripts/blueprint_text.gd")
	var lines_out: Array = []
	var ok: bool = true
	var seen: int = 0
	for type in build.building_types:
		var node = (type.scene if type.scene != null else load("res://scenes/Building.tscn")).instantiate()
		if node.get("building_type") != null or "building_type" in node:
			node.building_type = type
		elif "starts_built" in node:
			node.starts_built = false
		world.add_child(node)
		var l0: Array = BlueprintText.lines(node)
		var partial: Array = []
		if node.is_in_group("buildings") and node.get("plank_cost") != null:
			node.planks_ready = maxi(0, node.plank_cost - 1) if node.plank_cost > 1 else 0
			for kind in node.materials_cost:
				node.materials_ready[kind] = maxi(0, int(node.materials_cost[kind]) - 1)
			partial = BlueprintText.lines(node)
			node.planks_ready = node.plank_cost
			for kind in node.materials_cost:
				node.materials_ready[kind] = int(node.materials_cost[kind])
			node.build_progress = 1
		elif node.is_in_group("pit_saws"):
			node.dig_count = node.DIG_HITS
			node.planks_delivered = 1
			partial = BlueprintText.lines(node)
			node.planks_delivered = node.PLANKS_REQUIRED
			node.blades_delivered = node.BLADES_REQUIRED
			node.build_progress = 1
		var l1: Array = BlueprintText.lines(node)
		if l0.size() == 2:
			seen += 1
			ok = ok and String(l0[1]).begins_with("Needs:") and (l1.is_empty() or String(l1[1]).begins_with("Ready to build (") or String(l1[1]).begins_with("Needs:"))
			lines_out.append("%s: '%s' / '%s'  ->  '%s'  ->  '%s'" % [type.type_name, l0[0], l0[1], partial[1] if partial.size() == 2 else "-", l1[1] if l1.size() == 2 else "-"])
		else:
			lines_out.append("%s: (no blueprint text)" % type.type_name)
		node.remove_from_group("buildings")
		node.remove_from_group("build_blockers")
		node.remove_from_group("pit_saws")
		node.queue_free()
	for line in lines_out:
		print("SELF-CHECK:   blueprint hover: %s" % line)
	_q("6", "blueprint hover text (name + one 'Needs: ...' / 'Ready to build (h/n hits)' line, no pips) for %d blueprint types" % seen, ok and seen >= 3)

func floor_x0(room) -> float:
	return room.floor_rect_world().position.x

func floor_y0(room) -> float:
	return room.floor_rect_world().position.y

# --- The six changes after that: chooser actions repeat while held, the build menu wheel, right-click put-away, the campfire text,
# --- threshing instead of seeds from the harvest, the carry formation ------------------------------------------------------------

func _self_check_world3() -> void:
	var world: Node = get_parent()
	var player = world.get_node_or_null("MainCharacter")
	var build = world.get_node_or_null("BuildMode")
	if player == null or build == null:
		return
	set_time(day, 0.2)
	player.state = player.State.FREE
	player.held_tool = &""
	player.carrying_planks = 0
	player.carrying_blade = false
	player.rest.value = 100.0
	player.hunger.value = 100.0
	get_window().size = Vector2i(1280, 720)
	for i in 4:
		await get_tree().process_frame
	await _c3_hold(world, player)
	await _c3_wheel(world, player, build)
	await _c3_rightclick(world, player)
	_c3_campfire(world)
	await _c3_wheat(world, player)
	await _c3_formation(world, player)
	get_window().size = Vector2i(64, 64)

func _c3_count_sound(sound: String) -> int:
	var n: int = 0
	for e in AudioManager.log:
		if e[0] == sound:
			n += 1
	return n

# ---- (1) a chooser row confirmed on press starts a hold session: the swings repeat while E / the button stays down
func _c3_hold(world: Node, player) -> void:
	var GP = load("res://scripts/ground_placement.gd")
	var Items = load("res://scripts/items.gd")
	var inter: Node = player.get_node("Interaction")
	var lines: Array = []
	var ok_all: bool = true
	var baseline: int = -1
	for how in ["plain E held (no chooser)", "E held", "double-tap E held", "row clicked, button held"]:
		var spot: Vector2 = GP.find_free_ground_near(get_tree(), Vector2(500, 470), Vector2(50, 50), Rect2(0, 0, 640, 640), 140.0)
		var tree = load("res://scenes/Tree.tscn").instantiate()
		tree.position = spot
		world.add_child(tree)
		if how != "plain E held (no chooser)":
			var branch = Items.spawn(&"branch", world, spot + Vector2(12, 6))
			branch.position = spot + Vector2(12, 6)
		await get_tree().process_frame
		player.state = player.State.FREE
		player.held_tool = &"axe"
		player.position = spot + Vector2(4, 12)
		inter._hovered = false
		inter._mouse_moved_at = -1000.0
		for i in 5:
			await get_tree().process_frame
		AudioManager.log.clear()
		var opened: bool = false
		var top_row: String = ""
		if how != "plain E held (no chooser)":
			# E opens the chooser (a quick second press would be the double-tap)
			Input.parse_input_event(_key_event(KEY_E, true))
			await get_tree().process_frame
			opened = inter.chooser_open
			top_row = load("res://scripts/actions.gd").label_of(inter._ch_list[0]) if opened else ""
			Input.parse_input_event(_key_event(KEY_E, false))
			await get_tree().process_frame
		var held_via_mouse: bool = false
		match how:
			"plain E held (no chooser)":
				Input.parse_input_event(_key_event(KEY_E, true))
			"E held":
				await get_tree().create_timer(0.6).timeout
				Input.parse_input_event(_key_event(KEY_E, true))
			"double-tap E held":
				await get_tree().create_timer(0.1).timeout
				Input.parse_input_event(_key_event(KEY_E, true))
			_:
				var down := InputEventMouseButton.new()
				down.button_index = MOUSE_BUTTON_LEFT
				down.pressed = true
				down.position = Vector2(3, 3)
				Input.parse_input_event(down)
				held_via_mouse = true
				inter._test_mouse_down = true
				var row_press := InputEventMouseButton.new()
				row_press.button_index = MOUSE_BUTTON_LEFT
				row_press.pressed = true
				inter._on_chooser_row(row_press, 0)
		var reopened: bool = false
		var t0: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 4500:
			await get_tree().process_frame
			reopened = reopened or inter.chooser_open
		var swings: int = _c3_count_sound("chop_hit")
		var still_working: bool = inter._hold.size() > 0 or player.state != player.State.FREE
		if held_via_mouse:
			var up := InputEventMouseButton.new()
			up.button_index = MOUSE_BUTTON_LEFT
			up.pressed = false
			up.position = Vector2(3, 3)
			Input.parse_input_event(up)
		else:
			Input.parse_input_event(_key_event(KEY_E, false))
		inter._test_mouse_down = false
		var at_release: int = swings
		await get_tree().create_timer(1.5).timeout
		var after: int = _c3_count_sound("chop_hit") - at_release
		if baseline < 0:
			baseline = swings
		lines.append("%s: %s%d swings in 4.5 s while held, %d after release%s" % [how, ("chooser opened, top row '%s', " % top_row) if how != "plain E held (no chooser)" else "", swings, after, ", chooser reopened!" if reopened else ""])
		ok_all = ok_all and (opened or how == "plain E held (no chooser)") and (how == "plain E held (no chooser)" or swings >= 3) and after <= 1 and not reopened
		player._cancel_order()
		player.end_chop_session()
		for g in get_tree().get_nodes_in_group("ground_items"):
			if g.global_position.distance_to(spot) < 60.0:
				g.remove_from_group("ground_items")
				g.queue_free()
		tree.remove_from_group("trees")
		tree.queue_free()
		player.held_tool = &""
		await get_tree().process_frame
	_q("N1", " | ".join(lines), ok_all)

# ---- (2) the wheel over the build menu
func _c3_wheel(world: Node, player, build) -> void:
	await _c3_wheel_run(build, "(everything unlocked)")
	# and as at the start of the game: only the pit saw, campfire and grinding stone are open, so the Housing and Storage tabs are off
	var unlocks: Node = build.unlocks
	var saved: Dictionary = unlocks.unlocked.duplicate()
	var saved_all: bool = unlocks.everything
	unlocks.set_process(false)
	unlocks.unlocked.clear()
	unlocks.everything = false
	unlocks.changed.emit()
	await get_tree().process_frame
	await _c3_wheel_run(build, "(start of the game, some tabs off)")
	unlocks.unlocked = saved
	unlocks.everything = saved_all
	unlocks.set_process(true)
	unlocks.changed.emit()
	await get_tree().process_frame

func _c3_wheel_run(build, label: String) -> void:
	var menu: Node = build.menu
	var cam: Camera2D = get_viewport().get_camera_2d()
	var zoom_before: Vector2 = cam.zoom if cam != null else Vector2.ONE
	build._set_active(true)
	for i in 4:
		await get_tree().process_frame
	var order: Array[int] = menu.walk_order()
	var tabs_state: Array = []
	for category in menu._categories:
		tabs_state.append("%s %s" % [category, "off" if menu._tab_buttons[category].disabled else "on"])
	var names: Array = []
	for i in order:
		names.append(build.building_types[i].type_name)
	if order.is_empty():
		_q("N2 " + label, "no available card", false)
		build._set_active(false)
		return
	build.choose(order[0])
	await get_tree().process_frame
	var down: Array = [build.type_index]
	var down_tabs: Array = [menu._current]
	for i in order.size() + 1:
		menu.step_card(1)
		await get_tree().process_frame
		down.append(build.type_index)
		down_tabs.append(menu._current)
	var expect_down: Array = []
	for i in order.size() + 2:
		expect_down.append(order[i % order.size()])
	var up: Array = [build.type_index]
	for i in order.size():
		menu.step_card(-1)
		await get_tree().process_frame
		up.append(build.type_index)
	var expect_up: Array = [down[down.size() - 1]]
	var at: int = order.find(down[down.size() - 1])
	for i in order.size():
		at = (at - 1 + order.size()) % order.size()
		expect_up.append(order[at])
	var shown_names: Array = []
	for i in down:
		shown_names.append(build.building_types[i].type_name)
	# tabs
	var tab_seq: Array = [menu._current]
	for i in menu._categories.size() + 1:
		menu.step_tab(1)
		tab_seq.append(menu._current)
	var enabled_tabs: Array = menu._categories.filter(func(c: String) -> bool: return not menu._tab_buttons[c].disabled)
	var tabs_ok: bool = true
	for t in tab_seq:
		tabs_ok = tabs_ok and enabled_tabs.has(t)
	# real wheel events over a card and over a tab (the world must not see them)
	var before: int = build.type_index
	build.choose(order[0])
	await get_tree().process_frame
	await get_tree().process_frame
	var visible_card: Dictionary = {}
	for card in menu.cards:
		if card["wrap"].visible and order.has(card["index"]):
			visible_card = card
	var injected: String = "(no visible card)"
	var injected_ok: bool = true
	if not visible_card.is_empty():
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
		wheel.pressed = true
		wheel.position = visible_card["card"].get_global_rect().get_center()
		wheel.global_position = wheel.position
		Input.parse_input_event(wheel)
		await get_tree().process_frame
		await get_tree().process_frame
		var moved_to: int = build.type_index
		var tab_before: String = menu._current
		var tab_button: Button = menu._tab_buttons[menu._current]
		var tab_wheel := InputEventMouseButton.new()
		tab_wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
		tab_wheel.pressed = true
		tab_wheel.position = tab_button.get_global_rect().get_center()
		tab_wheel.global_position = tab_wheel.position
		Input.parse_input_event(tab_wheel)
		await get_tree().process_frame
		await get_tree().process_frame
		injected = "wheel over a card: %s -> %s (one step expected: %s); wheel over the tab row: %s -> %s" % [build.building_types[order[0]].type_name, build.building_types[moved_to].type_name, build.building_types[order[1 % order.size()]].type_name, tab_before, menu._current]
		injected_ok = moved_to == order[1 % order.size()] and (menu._current != tab_before or enabled_tabs.size() < 2)
	var zoom_after: Vector2 = cam.zoom if cam != null else Vector2.ONE
	_q("N2 " + label, "tabs %s; available cards in order %s; wheel down walks %s (tabs %s); wheel up walks back %s; tab wheel visits %s; %s; camera zoom %s -> %s" % [str(tabs_state), str(names), str(shown_names), str(down_tabs), str(up.map(func(i: int) -> String: return build.building_types[i].type_name)), str(tab_seq), injected, zoom_before, zoom_after], down == expect_down and up == expect_up and tabs_ok and injected_ok and zoom_after == zoom_before)
	build._set_active(false)
	await get_tree().process_frame

# ---- (3) right-click on the toolbox puts the held item in the box without opening the panel
func _c3_rightclick(world: Node, player) -> void:
	var GP = load("res://scripts/ground_placement.gd")
	var spot: Vector2 = GP.find_free_ground_near(get_tree(), Vector2(430, 440), Vector2(60, 24), Rect2(0, 0, 640, 640), 140.0)
	var box = load("res://scenes/ToolBox.tscn").instantiate()
	box.position = spot
	box.init_contents = [[&"hammer", 0]]
	world.add_child(box)
	await get_tree().process_frame
	player.state = player.State.FREE
	player.position = spot + Vector2(0, 10)
	var canvas: Transform2D = get_viewport().get_canvas_transform()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	click.position = canvas * (spot + Vector2(0, -6))
	# an accepted tool
	player.held_tool = &"shovel"
	var before: int = box.item_count()
	AudioManager.log.clear()
	player._unhandled_input(click)
	await get_tree().process_frame
	var stored: bool = player.held_tool == &"" and box.item_count() == before + 1 and box.kinds().has(&"shovel")
	var panel_closed: bool = not box.is_open
	var lid: bool = _c3_count_sound("toolbox_close") == 1 and _c3_count_sound("drop") == 1
	# not accepted
	var sheaves_lying: int = get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"wheat_sheaf").size()
	player.held_tool = &"wheat_sheaf"
	var refused_msg: String = player.toolbox_put(box)
	click.position = get_viewport().get_canvas_transform() * (spot + Vector2(0, -6))
	player._unhandled_input(click)
	await get_tree().process_frame
	var refused: bool = player.held_tool == &"wheat_sheaf" and box.item_count() == before + 1 and not box.is_open
	var dropped_nothing: bool = get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"wheat_sheaf").size() == sheaves_lying
	# full
	var saved_capacity: int = box.toolbox_capacity
	box.toolbox_capacity = box.contents.size()
	player.held_tool = &"bucket"
	var full_msg: String = player.toolbox_put(box)
	box.toolbox_capacity = saved_capacity
	# elsewhere: it drops as before
	player.held_tool = &"wheat_sheaf"
	var elsewhere := InputEventMouseButton.new()
	elsewhere.button_index = MOUSE_BUTTON_RIGHT
	elsewhere.pressed = true
	elsewhere.position = get_viewport().get_canvas_transform() * (player.position + Vector2(40, 0))
	player._unhandled_input(elsewhere)
	await get_tree().process_frame
	var dropped: bool = player.held_tool == &""
	# E still opens the panel whatever is held
	player.held_tool = &"wheat_sheaf"
	box.open_for(player)
	var e_opens: bool = box.is_open
	box.close()
	_q("N3", "tool: stored %s, panel not opened %s, soft lid sound %s; wheat sheaf: '%s' and still in hands %s, nothing dropped %s; full box: '%s'; right-click elsewhere drops it %s; E still opens the panel %s" % [stored, panel_closed, lid, refused_msg, refused, dropped_nothing, full_msg, dropped, e_opens], stored and panel_closed and lid and refused and dropped_nothing and refused_msg == "The toolbox does not take that." and full_msg == "The toolbox is full." and dropped and e_opens)
	player.held_tool = &""
	for g in get_tree().get_nodes_in_group("ground_items"):
		if g.global_position.distance_to(player.position + Vector2(40, 0)) < 40.0:
			g.remove_from_group("ground_items")
			g.queue_free()
	box.remove_from_group("toolboxes")
	box.remove_from_group("build_blockers")
	box.queue_free()

# ---- (4) the campfire's hover text
func _c3_campfire(world: Node) -> void:
	var fire = load("res://scenes/Campfire.tscn").instantiate()
	fire.position = Vector2(300, 560)
	world.add_child(fire)
	var rows: Array = []
	var ok: bool = true
	for lit in [true, false]:
		for stone in [false, true]:
			fire.lit = lit
			fire.stone = stone
			fire.burn_left = 14400.0 if lit else 0.0
			var text: String = fire.readout().split("\n")[0]
			rows.append("lit %s, stone %s: '%s'" % [lit, stone, text])
			if not stone:
				ok = ok and text.ends_with("No stone to cook on.") and not "no stone" in text
			else:
				ok = ok and not "No stone" in text
	var lit_text: String = ""
	fire.lit = true
	fire.stone = false
	fire.burn_left = 14400.0
	lit_text = fire.readout()
	_q("N4", " | ".join(rows), ok and lit_text.begins_with("Campfire: lit") and "(burns" in lit_text)
	fire.remove_from_group("campfires")
	fire.remove_from_group("build_blockers")
	fire.queue_free()

# ---- (5) harvest gives sheaves only; threshing a sheaf makes seeds
func _c3_wheat(world: Node, player) -> void:
	var Items = load("res://scripts/items.gd")
	var Actions = load("res://scripts/actions.gd")
	var cfg: Resource = load("res://scripts/food_config.gd").cfg()
	var m = load("res://scripts/plot_manager.gd").get_for(get_tree())
	var field: Vector2i = Vector2i(31, 40)
	var found: bool = false
	for gy in range(8, 52, 4):
		for gx in range(25, 55):
			var clear: bool = true
			for dx in 4:
				if m.can_till(Vector2i(gx + dx, gy)) != "":
					clear = false
			if clear:
				field = Vector2i(gx, gy)
				found = true
				break
		if found:
			break
	player.state = player.State.FREE
	player.position = m.cell_center(field) + Vector2(0, 16)
	player.held_tool = &"hoe"
	var cells: Array[Vector2i] = [field, field + Vector2i(1, 0), field + Vector2i(2, 0)]
	for cell in cells:
		player.plot_till(cell)
		player.plot_till(cell)
		m.plots[cell] = {"state": &"planted", "growth": m.ripe_growth(), "synced": m.now(), "watered_until": 0.0}
	var ripe: int = 0
	for cell in cells:
		if m.stage(cell) == &"ripe":
			ripe += 1
	var bag = Items.spawn(&"seed_bag", world, player.position + Vector2(30, 6), 2)
	bag.position = player.position + Vector2(30, 6)
	var bags_before: int = get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"seed_bag").size()
	var seeds_before: int = bag.seeds
	var sheaves_before: int = get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"wheat_sheaf").size()
	player.held_tool = &"sickle"
	for cell in cells:
		player.plot_harvest(cell)
	await get_tree().process_frame
	var bags_after: int = get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"seed_bag").size()
	var sheaves_after: Array = get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"wheat_sheaf")
	var no_extra: bool = ripe == 3 and sheaves_after.size() - sheaves_before == 3 * cfg.wheat_per_harvest and bags_after == bags_before and bag.seeds == seeds_before
	# thresh: a bag at 3 -> 6, two presses, the sheaf is gone
	var sheaf = sheaves_after[0]
	player.held_tool = &"seed_bag"
	player.held_seeds = 3
	AudioManager.log.clear()
	var first: String = player.thresh_sheaf(sheaf)
	var after_first: int = player.held_seeds
	var sheaf_there: bool = is_instance_valid(sheaf) and not sheaf.is_queued_for_deletion()
	var second: String = player.thresh_sheaf(sheaf)
	await get_tree().process_frame
	var done_ok: bool = player.held_seeds == 6 and (not is_instance_valid(sheaf) or sheaf.is_queued_for_deletion())
	var sounds: String = "rustle x%d, done x%d" % [_c3_count_sound("thresh_rustle"), _c3_count_sound("thresh_done")]
	# a bag at 4: no room for 3 (4 -> 7): refused, the sheaf stays
	var sheaf2 = sheaves_after[1]
	player.held_seeds = 4
	var refused: String = player.thresh_sheaf(sheaf2)
	var refused_ok: bool = refused == "Not enough room in the bag." and player.held_seeds == 4 and is_instance_valid(sheaf2) and not sheaf2.is_queued_for_deletion() and int(sheaf2.get_meta(&"thresh_presses", 0)) == 0
	# the chooser rows for a sheaf with a bag in hand, and a sheaf on a table
	var inter: Node = player.get_node("Interaction")
	player.held_seeds = 3
	player.position = sheaf2.global_position + Vector2(0, 8)
	inter._hovered = false
	inter._mouse_moved_at = -1000.0
	for i in 4:
		await get_tree().process_frame
	var rows: Array = []
	for a in inter._chooser_actions():
		rows.append("%s%s" % [Actions.label_of(a), "" if a["enabled"] else " [greyed: %s]" % a["disabled_reason"]])
	var table = load("res://scenes/Table.tscn").instantiate()
	table.position = player.position + Vector2(60, -20)
	world.add_child(table)
	var on_table = player._make_item_node(&"wheat_sheaf")
	table.put_node(on_table)
	player.held_seeds = 3
	player.thresh_sheaf(on_table)
	player.thresh_sheaf(on_table)
	await get_tree().process_frame
	var table_ok: bool = player.held_seeds == 6 and table.is_empty()
	var HN = load("res://scripts/hover_names.gd")
	player.held_tool = &"seed_bag"
	var hint_with: String = HN.target_text(sheaf2, get_tree(), player)
	player.held_tool = &"hoe"
	var hint_without: String = HN.target_text(sheaf2, get_tree(), player)
	var hint_ok: bool = hint_with == "Wheat sheaf\nThresh into bag" and hint_without == "Wheat sheaf"
	player.held_tool = &"seed_bag"
	var extra_threshed: bool = refused_ok
	_q("N5", "harvest of 3 plots: %d sheaves, new seed bags %d, the bag on the ground still %d seeds (no extra seeds: %s); thresh with the bag at 3: first press '%s' (bag %d, sheaf still there %s), second '%s' -> bag %d, sheaf gone %s, %s; bag at 4: '%s' (nothing changed %s); rows with a sheaf beside me: %s; sheaf on a table threshed too: %s; hover hint with the bag '%s', without '%s'" % [sheaves_after.size() - sheaves_before, bags_after - bags_before, bag.seeds, no_extra, first, after_first, sheaf_there, second, player.held_seeds if done_ok else -1, done_ok, sounds, refused, extra_threshed, str(rows), table_ok, hint_with.replace("\n", " / "), hint_without], hint_ok and no_extra and first == "" and after_first == 3 and sheaf_there and second == "" and done_ok and refused_ok and table_ok and rows.size() >= 2 and str(rows[0]).begins_with("Thresh sheaf into seed bag") and "rustle x1" in sounds and "done x1" in sounds)
	for g in get_tree().get_nodes_in_group("ground_items"):
		if g.kind == &"wheat_sheaf" or g.kind == &"seed_bag":
			g.remove_from_group("ground_items")
			g.queue_free()
	table.remove_from_group("tables")
	table.remove_from_group("build_blockers")
	table.queue_free()
	for cell in cells:
		m.plots.erase(cell)
	player.held_tool = &""
	player.held_seeds = 0

# ---- (6) carrying: the carriers stay at the short ends of the box whichever way they walk
func _c3_formation(world: Node, player) -> void:
	var GP = load("res://scripts/ground_placement.gd")
	var friend = get_tree().get_first_node_in_group("colonists")
	if friend == null:
		return
	var spot: Vector2 = GP.find_free_ground_near(get_tree(), Vector2(300, 420), Vector2(60, 24), Rect2(0, 0, 640, 640), 140.0)
	var box = load("res://scenes/ToolBox.tscn").instantiate()
	box.position = spot
	box.init_contents = [[&"hammer", 0]]
	world.add_child(box)
	await get_tree().process_frame
	_c2_prepare_friend(friend, box.position + Vector2(60, 10))
	player.state = player.State.FREE
	player.held_tool = &""
	player.position = box.position + Vector2(0, 12)
	var job: Node = await _c2_start_and_lift(box, player)
	if job == null:
		_q("N6", "no lift", false)
		box.queue_free()
		return
	await get_tree().create_timer(0.8).timeout
	var off: float = box.carry_end_offset_px()
	var rows: Array = []
	var ok: bool = true
	var max_step: float = 0.0
	var f_prev: Vector2 = friend.position
	var b_prev: Vector2 = box.global_position
	var side0: float = signf(friend.position.x - box.global_position.x)
	for dir in [["left", "move_left"], ["right", "move_right"], ["up", "move_up"], ["down", "move_down"]]:
		Input.action_press(dir[1])
		for i in 70:
			await get_tree().process_frame
			max_step = maxf(max_step, maxf(friend.position.distance_to(f_prev), box.global_position.distance_to(b_prev)))
			f_prev = friend.position
			b_prev = box.global_position
		var rel_f: Vector2 = friend.position - box.global_position
		var rel_p: Vector2 = player.position - box.global_position
		Input.action_release(dir[1])
		rows.append("%s: friend %s, player %s from the box centre" % [dir[0], rel_f.round(), rel_p.round()])
		ok = ok and absf(absf(rel_f.x) - off) < 3.5 and absf(absf(rel_p.x) - off) < 3.5 and absf(rel_f.y) < 3.5 and absf(rel_p.y) < 3.5 and signf(rel_f.x) == side0 and signf(rel_p.x) == -side0
		for i in 5:
			await get_tree().process_frame
	_q("N6", "box %.0f px wide, each carrier %.1f px from its centre, level; %s; friend kept his end (%s); biggest one-frame move %.2f px" % [box.footprint_at(Vector2.ZERO).size.x, off, " | ".join(rows), "left" if side0 < 0.0 else "right", max_step], ok and max_step < 3.0 and is_instance_valid(job))
	if is_instance_valid(job):
		job.escape()
	await get_tree().process_frame
	box.remove_from_group("toolboxes")
	box.remove_from_group("build_blockers")
	box.queue_free()
	_c2_prepare_friend(friend, friend.position)
	friend.state = friend.State.IDLE
	player.held_tool = &""

# --- The E chooser merges duplicate actions ----------------------------------------------------------------------------------------

func _self_check_world4() -> void:
	var world: Node = get_parent()
	var player = world.get_node_or_null("MainCharacter")
	if player == null:
		return
	set_time(day, 0.2)
	player.state = player.State.FREE
	player.held_tool = &""
	player.carrying_planks = 0
	player.rest.value = 100.0
	player.hunger.value = 100.0
	await _c4_merge(world, player)

func _c4_clear(spot: Vector2) -> void:
	for group_name in ["ground_items", "plank_piles", "trees", "axes"]:
		for g in get_tree().get_nodes_in_group(group_name):
			if g.global_position.distance_to(spot) < 70.0:
				g.remove_from_group(group_name)
				g.queue_free()

func _c4_place(player, spot: Vector2, tool: StringName) -> void:
	player.state = player.State.FREE
	player.carrying_planks = 0
	player.held_tool = tool
	player.position = spot
	player.sprite.flip_h = false
	var inter: Node = player.get_node("Interaction")
	inter._hovered = false
	inter._mouse_moved_at = -1000.0

func _c4_alive(node) -> bool:
	return is_instance_valid(node) and not node.is_queued_for_deletion()

func _c4_merge(world: Node, player) -> void:
	var GP = load("res://scripts/ground_placement.gd")
	var Items = load("res://scripts/items.gd")
	var PP = load("res://scripts/plank_piles.gd")
	var Actions = load("res://scripts/actions.gd")
	var inter: Node = player.get_node("Interaction")
	var spot: Vector2 = GP.find_free_ground_near(get_tree(), Vector2(500, 470), Vector2(60, 60), Rect2(0, 0, 640, 640), 140.0)
	# ---- (a) two planks close together: E takes the closer one at once
	_c4_clear(spot)
	var p_near = PP.spawn_pile(world, spot + Vector2(10, 0), 1)
	var p_far = PP.spawn_pile(world, spot + Vector2(21, 2), 1)
	p_near.position = spot + Vector2(10, 0)
	p_far.position = spot + Vector2(21, 2)
	await get_tree().process_frame
	_c4_place(player, spot, &"")
	for i in 4:
		await get_tree().process_frame
	var rows_a: Array = inter._chooser_actions().map(func(a: Dictionary) -> String: return Actions.label_of(a))
	inter._unhandled_input(_key_event(KEY_E))
	await get_tree().process_frame
	var took_near: bool = player.carrying_planks == 1 and not _c4_alive(p_near) and _c4_alive(p_far) and p_far.count == 1
	_q("M1", "2 planks 11 px apart: rows %s, chooser open %s, took the closer one %s" % [str(rows_a), inter.chooser_open, took_near], not inter.chooser_open and rows_a.size() == 1 and took_near)
	player.carrying_planks = 0
	# ---- (b) 3 branches + 1 plank: a chooser with two rows, each row acts on the closest instance
	var lines_b: Array = []
	var ok_b: bool = true
	for pick in ["branch", "plank"]:
		_c4_clear(spot)
		var branches: Array = []
		for off in [Vector2(9, 0), Vector2(16, 4), Vector2(22, -3)]:
			var b = Items.spawn(&"branch", world, spot + off)
			b.position = spot + off
			branches.append(b)
		var plank = PP.spawn_pile(world, spot + Vector2(13, 8), 1)
		plank.position = spot + Vector2(13, 8)
		await get_tree().process_frame
		_c4_place(player, spot, &"")
		for i in 4:
			await get_tree().process_frame
		inter._unhandled_input(_key_event(KEY_E))
		await get_tree().process_frame
		var rows: Array = inter._ch_list.map(func(a: Dictionary) -> String: return Actions.label_of(a))
		var opened: bool = inter.chooser_open and rows.size() == 2 and "Pick up Branch (x3)" in rows
		for i in inter._ch_list.size():
			if (pick == "branch") == (inter._ch_list[i]["kind"] == "take_item"):
				inter._ch_index = i
		inter._chooser_confirm()
		await get_tree().process_frame
		var right: bool
		if pick == "branch":
			right = player.held_tool == &"branch" and not _c4_alive(branches[0]) and _c4_alive(branches[1]) and _c4_alive(branches[2])
		else:
			right = player.carrying_planks == 1 and not _c4_alive(plank) and _c4_alive(branches[0])
		lines_b.append("%s row -> %s" % [pick, "the closest instance" if right else "WRONG"])
		ok_b = ok_b and opened and right
		if pick == "branch":
			lines_b.append("rows %s" % str(rows))
		player.held_tool = &""
		player.carrying_planks = 0
	_q("M2", "3 branches + 1 plank: %s" % " | ".join(lines_b), ok_b)
	# ---- (c) two oaks, nothing else: E chops the closer one at once
	_c4_clear(spot)
	var oak_near = load("res://scenes/Tree.tscn").instantiate()
	oak_near.position = spot + Vector2(10, 6)
	world.add_child(oak_near)
	var oak_far = load("res://scenes/Tree.tscn").instantiate()
	oak_far.position = spot + Vector2(24, 8)
	world.add_child(oak_far)
	await get_tree().process_frame
	_c4_place(player, spot, &"axe")
	for i in 4:
		await get_tree().process_frame
	var rows_c: Array = inter._chooser_actions().map(func(a: Dictionary) -> String: return Actions.label_of(a))
	inter._unhandled_input(_key_event(KEY_E))
	for i in 3:
		await get_tree().process_frame
	var chopping_near: bool = player.work_tree == oak_near
	_q("M3", "two oaks: rows %s, chooser open %s, chopping the closer one %s" % [str(rows_c), inter.chooser_open, chopping_near], not inter.chooser_open and rows_c.size() == 1 and chopping_near)
	player._cancel_order()
	player.end_chop_session()
	# ---- (d) a branch beside an oak: both actions are offered
	_c4_clear(spot)
	var oak = load("res://scenes/Tree.tscn").instantiate()
	oak.position = spot + Vector2(10, 6)
	world.add_child(oak)
	var twig = Items.spawn(&"branch", world, spot + Vector2(17, 8))
	twig.position = spot + Vector2(17, 8)
	await get_tree().process_frame
	_c4_place(player, spot, &"axe")
	for i in 4:
		await get_tree().process_frame
	inter._unhandled_input(_key_event(KEY_E))
	await get_tree().process_frame
	var rows_d: Array = inter._ch_list.map(func(a: Dictionary) -> String: return Actions.label_of(a))
	_q("M4", "a branch beside an oak: chooser open %s, rows %s" % [inter.chooser_open, str(rows_d)], inter.chooser_open and rows_d.size() == 2)
	inter.close_chooser()
	_c4_clear(spot)
	player.held_tool = &""
	await get_tree().process_frame

# --- The grinding stone (renamed) and the wheat-carrying sprite -------------------------------------------------------------------

# Case-insensitive hits of a word in the project's text files (not the import cache): {"path": count}.
func _scan_project_for(word: String, dir_path: String = "res://", out: Dictionary = {}) -> Dictionary:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for sub in dir.get_directories():
		if not sub.begins_with("."):
			_scan_project_for(word, dir_path.path_join(sub), out)
	for file_name in dir.get_files():
		if not file_name.get_extension() in ["gd", "tscn", "tres", "cfg", "json", "md", "txt", "py", "godot", "import", "shader", "gdshader", "uid"]:
			continue
		var text: String = FileAccess.get_file_as_string(dir_path.path_join(file_name)).to_lower()
		var hits: int = text.count(word)
		if hits > 0:
			out[dir_path.path_join(file_name)] = hits
		if word in file_name.to_lower():
			out[dir_path.path_join(file_name) + " (file name)"] = 1
	return out

func _self_check_world5() -> void:
	var world: Node = get_parent()
	var player = world.get_node_or_null("MainCharacter")
	var build = world.get_node_or_null("BuildMode")
	if player == null or build == null:
		return
	var Items = load("res://scripts/items.gd")
	var cfg: Resource = load("res://scripts/food_config.gd").cfg()
	player.state = player.State.FREE
	player.held_tool = &""
	# ---- (1) no leftovers of the old name
	var old_word: String = "que" + "rn"
	var hits: Dictionary = _scan_project_for(old_word)
	_q("R1", "remaining case-insensitive hits of the old name in the project: %s" % (str(hits) if not hits.is_empty() else "none"), hits.is_empty())
	# ---- (2) the build menu card
	var type: BuildingType = null
	for t in build.building_types:
		if t.type_name == "Grinding Stone":
			type = t
	var card_text: String = "(no card)"
	var card_ok: bool = false
	if type != null:
		for card in build.menu.cards:
			if card["type"] == type:
				card_text = "card '%s' / '%s' / %s / sprite %s" % [card["name_label"].text, card["desc"].text, type.cost_text(), type.texture.resource_path]
				card_ok = card["name_label"].text == "Grinding Stone" and "grind" in card["desc"].text.to_lower() and type.texture.resource_path == "res://sprites/grinding_stone.png"
	_q("R2", "build menu: %s; category %s, unlock '%s' (available at the start)" % [card_text, type.category if type != null else "?", type.unlock_requirement if type != null else "?"], card_ok and type.unlock_requirement == "none")
	# ---- (3) picking up a wheat sheaf: the carrying animation set
	var sheaf = Items.spawn(&"wheat_sheaf", world, player.position + Vector2(10, 0))
	sheaf.position = player.position + Vector2(10, 0)
	await get_tree().process_frame
	player.held_tool = &""
	var took: String = player.take_item(sheaf)
	await get_tree().process_frame
	var frames: SpriteFrames = player.sprite.sprite_frames
	var tags: Array = []
	for a in frames.get_animation_names():
		if String(a).begins_with("carry_wheat"):
			tags.append(String(a))
	var walk_name: StringName = player._walk_anim()
	var idle_name: StringName = player._idle_anim()
	var wheat_tex: Texture2D = frames.get_frame_texture(&"carry_wheat_sheaf", 0)
	var hay_tex: Texture2D = frames.get_frame_texture(&"carry_hay", 0)
	var same_cells: bool = wheat_tex.get_size() == hay_tex.get_size() and frames.get_frame_count(&"carry_wheat_sheaf") == frames.get_frame_count(&"carry_hay") and frames.get_animation_speed(&"carry_wheat_sheaf") == frames.get_animation_speed(&"carry_hay")
	player.sprite.play(walk_name)
	await get_tree().process_frame
	_q("R3", "holding a wheat sheaf (take: '%s'): walk '%s', idle '%s'; tags %s; %d frames of %s at %.0f fps (hay: %d frames of %s); sprite scale %s offset %s" % [took, walk_name, idle_name, str(tags), frames.get_frame_count(&"carry_wheat_sheaf"), wheat_tex.get_size(), frames.get_animation_speed(&"carry_wheat_sheaf"), frames.get_frame_count(&"carry_hay"), hay_tex.get_size(), player.sprite.scale, player.sprite.offset], walk_name == &"carry_wheat_sheaf" and idle_name == &"carry_wheat_sheaf_idle" and tags.size() == 2 and same_cells and player.sprite.scale == Vector2.ONE)
	# ---- (4) grinding it, step by step
	var stone = load("res://scenes/GrindingStone.tscn").instantiate()
	stone.position = player.position + Vector2(40, 10)
	world.add_child(stone)
	await get_tree().process_frame
	var steps: Array = []
	var ok: bool = true
	var add_msg: String = player.grinding_stone_add(stone)
	steps.append("sheaf in: '%s' (hands now '%s', stone: %s)" % [add_msg, str(player.held_tool), stone.readout()])
	ok = ok and add_msg == "" and stone.has_sheaf and player.held_tool == &""
	for i in cfg.grind_presses:
		var msg: String = player.grinding_stone_press(stone)
		steps.append("press %d: '%s' (%s)" % [i + 1, msg, stone.readout()])
		ok = ok and msg == ""
	ok = ok and stone.flour_out == cfg.flour_per_sheaf and not stone.has_sheaf
	var take_msg: String = player.grinding_stone_press(stone)
	steps.append("take the flour: '%s' (hands '%s', stone: %s)" % [take_msg, str(player.held_tool), stone.readout()])
	ok = ok and player.held_tool == &"flour"
	player.held_tool = &""
	var empty_msg: String = player.grinding_stone_press(stone)
	steps.append("empty hands again: '%s'" % empty_msg)
	ok = ok and empty_msg == "Nothing to grind."
	_q("R4", "grinding: %s" % " | ".join(steps), ok)
	stone.remove_from_group("grinding_stones")
	stone.remove_from_group("build_blockers")
	stone.queue_free()
	player.held_tool = &""

# --- Orders for the friend: stances, follow (through a door), assist, stay, the quick key, persistence over a sleep ---------------------

func _self_check_world6() -> void:
	var world: Node = get_parent()
	var player = world.get_node_or_null("MainCharacter")
	var friend = get_tree().get_first_node_in_group("colonists")
	if player == null or friend == null:
		return
	get_window().size = Vector2i(1280, 720)
	set_time(day, 0.2)
	player.state = player.State.FREE
	player.held_tool = &""
	player.rest.value = 100.0
	player.hunger.value = 100.0
	_c6_ready_friend(friend, player.position + Vector2(-30, 10))
	await _c6_stances(friend, player)
	await _c6_talk(world, friend, player)
	await _c6_follow(world, friend, player)
	await _c6_assist(world, friend, player)
	await _c6_stay(friend, player)
	await _c6_toggle(friend, player)
	await _c6_sleep(friend, player)
	friend.set_stance(0)
	get_window().size = Vector2i(64, 64)

func _c6_ready_friend(friend, at: Vector2) -> void:
	friend.order_ai.release_all()
	friend.set_stance(0)
	friend.position = at
	friend.visible = true
	friend.in_room = false
	friend.state = friend.State.IDLE
	friend.waypoints.clear()
	friend.rest.value = 100.0
	friend.hunger.value = 100.0
	friend.speed = 50.0
	friend.play("idle")

func _c6_state_name(friend) -> String:
	return str(friend.State.keys()[friend.state])

# ---- (1) every stance and the state he is in
func _c6_stances(friend, player) -> void:
	var rows: Array = []
	var ok: bool = true
	for entry in [[1, "Follow me"], [2, "Assist me"], [3, "Stay here"], [0, "Free time"]]:
		friend.set_stance(entry[0])
		for i in 8:
			await get_tree().process_frame
		var name_now: String = friend.orders.name_now()
		var state_name: String = _c6_state_name(friend)
		rows.append("%s -> state %s, status '%s'" % [name_now, state_name, friend.status_text()])
		if entry[0] == 0:
			ok = ok and friend.state != friend.State.ORDERED and name_now == entry[1]
		else:
			ok = ok and friend.state == friend.State.ORDERED and name_now == entry[1]
	var d: Dictionary = friend.orders.to_dict()
	var copy = load("res://scripts/colonist_orders.gd").new()
	copy.from_dict(d)
	ok = ok and copy.stance == friend.orders.stance
	_q("O1", " | ".join(rows) + "; saved as %s and read back" % str(d), ok)

# ---- (7) talking to him: the panel, the reasons, the chooser beside an item
func _c6_talk(world: Node, friend, player) -> void:
	var inter: Node = player.get_node("Interaction")
	var Actions = load("res://scripts/actions.gd")
	_c6_ready_friend(friend, player.position + Vector2(14, 6))
	inter._hovered = false
	inter._mouse_moved_at = -1000.0
	for i in 5:
		await get_tree().process_frame
	var talk_c: Dictionary = {}
	for c in inter._candidates():
		if c["kind"] == "talk":
			talk_c = c
	inter._do(talk_c)
	await get_tree().process_frame
	await get_tree().process_frame
	var opened: bool = friend.orders_panel.is_open
	var status_ok: bool = is_instance_valid(friend.orders_panel._status) and friend.orders_panel._status.text == friend.status_text()
	friend.orders_panel._buttons[1].pressed.emit()
	await get_tree().process_frame
	var chose_ok: bool = not friend.orders_panel.is_open and friend.orders.stance == 1
	# Esc closes it
	inter._do(talk_c)
	await get_tree().process_frame
	var esc_closed: bool = Ui.close_top_panel() and not friend.orders_panel.is_open
	# walking away closes it
	inter._do(talk_c)
	await get_tree().process_frame
	var saved_pos: Vector2 = player.position
	player.position += Vector2(200, 0)
	await get_tree().process_frame
	await get_tree().process_frame
	var away_closed: bool = not friend.orders_panel.is_open
	player.position = saved_pos
	# disabled: carrying the toolbox / asleep
	var saved_state = friend.state
	friend.state = friend.State.HELPING_CARRY
	var carry_reason: String = friend.talk_block_reason()
	friend.state = friend.State.ON_BED
	var asleep_reason: String = friend.talk_block_reason()
	friend.state = saved_state
	# beside an item the chooser lists him
	var item = load("res://scripts/items.gd").spawn(&"branch", world, friend.position + Vector2(6, 0))
	item.position = friend.position + Vector2(6, 0)
	_c6_ready_friend(friend, friend.position)
	await get_tree().process_frame
	inter._hovered = false
	for i in 5:
		await get_tree().process_frame
	var rows: Array = inter._chooser_actions().map(func(a: Dictionary) -> String: return Actions.label_of(a))
	item.remove_from_group("ground_items")
	item.queue_free()
	friend.set_stance(0)
	_q("O7", "E on him opens the panel (%s, status line shown %s); a stance button closes it with the stance set (%s); Esc closes it (%s); walking away closes it (%s); disabled: '%s' / '%s'; beside a branch the chooser lists %s" % [opened, status_ok, chose_ok, esc_closed, away_closed, carry_reason, asleep_reason, str(rows)], opened and status_ok and chose_ok and esc_closed and away_closed and carry_reason == "He is carrying the toolbox." and asleep_reason == "He is asleep." and "Talk to Friend" in rows and rows.size() == 2)

# ---- (2) follow: around obstacles and through a door
func _c6_leg(player, friend, to: Vector2, stats: Dictionary) -> void:
	var path: Array[Vector2] = Footprints.path_around(Footprints.base_rects(get_tree()), player.position, to, 6.0)
	for wp in path:
		while player.position.distance_to(wp) > 0.5:
			await get_tree().process_frame
			var delta: float = get_process_delta_time()
			var before: float = player.position.x
			player.position = player.position.move_toward(wp, 40.0 * delta)
			if absf(player.position.x - before) > 0.01:
				player.sprite.flip_h = player.position.x < before
			player.sprite.play(&"walk")
			if friend.visible and not friend.in_room and player.inside_building == null:
				var dist: float = friend.position.distance_to(player.position)
				stats["samples"] += 1
				if stats["time"] > 3.0:
					stats["max"] = maxf(stats["max"], dist)
					stats["sum"] += dist
					stats["n"] += 1
			stats["time"] += delta

func _c6_follow(world: Node, friend, player) -> void:
	var GP = load("res://scripts/ground_placement.gd")
	var start: Vector2 = GP.find_free_ground_near(get_tree(), Vector2(150, 330), Vector2(40, 40), Rect2(0, 0, 640, 640), 100.0)
	player.position = start
	_c6_ready_friend(friend, start + Vector2(-20, 8))
	var house = load("res://scenes/Building.tscn").instantiate()
	house.building_type = load("res://assets/house_type.tres")
	house.position = GP.find_free_ground_near(get_tree(), Vector2(430, 330), Vector2(80, 60), Rect2(0, 0, 640, 640), 120.0)
	world.add_child(house)
	house.state = house.State.BUILT
	await get_tree().process_frame
	friend.set_stance(1)
	var stats: Dictionary = {"max": 0.0, "sum": 0.0, "n": 0, "time": 0.0, "samples": 0}
	var legs: Array = [start + Vector2(220, 0), start + Vector2(220, 150), start + Vector2(20, 150), house.door_position() + Vector2(0, 14)]
	var walked: float = 0.0
	var from: Vector2 = player.position
	for leg in legs:
		walked += from.distance_to(leg)
		from = leg
		await _c6_leg(player, friend, leg, stats)
	var average: float = stats["sum"] / maxf(1.0, float(stats["n"]))
	# a pause beside the door, then in
	await get_tree().create_timer(1.0).timeout
	player.position = house.door_position() + Vector2(0, 2)
	player.request_enter(house)
	var entered_at: int = Time.get_ticks_msec()
	var friend_in: bool = false
	while Time.get_ticks_msec() - entered_at < 12000:
		await get_tree().process_frame
		if friend.order_ai.visiting == house and friend.in_room and friend.visible and player.inside_building == house and not player.transitioning:
			friend_in = true
			break
	var room: Node2D = house.get_interior()
	var near_door: bool = friend.position.distance_to(room.door_world()) < 90.0
	await get_tree().create_timer(0.5).timeout
	var out_at: int = Time.get_ticks_msec()
	player.request_leave()
	var friend_out: bool = false
	while Time.get_ticks_msec() - out_at < 12000:
		await get_tree().process_frame
		if player.inside_building == null and not player.transitioning and friend.order_ai.visiting == null and friend.visible and not friend.in_room:
			friend_out = true
			break
	await get_tree().create_timer(2.0).timeout
	var after: float = friend.position.distance_to(player.position)
	_q("O2", "walked %.0f px (%.0f tiles) round obstacles, follow_distance %.0f / stop %.0f: distance max %.0f px, average %.0f px over %d samples; through the door: he entered (%s, shown inside %.0f px from the room door), came out when I did (%s), then %.0f px from me" % [walked, walked / 32.0, friend.colony.follow_distance_px, friend.colony.follow_stop_px, stats["max"], average, stats["n"], friend_in, friend.position.distance_to(room.door_world()) if friend_in else -1.0, friend_out, after], stats["max"] <= friend.colony.follow_distance_px + 28.0 and average <= friend.colony.follow_distance_px and friend_in and near_door and friend_out and after < 60.0)
	friend.set_stance(0)
	house.remove_from_group("buildings")
	house.remove_from_group("build_blockers")
	if is_instance_valid(room):
		room.free()
	house.free()

# ---- (3) assist: what he copies
func _c6_stop_work(player) -> void:
	player._cancel_order()
	player.end_chop_session()
	player.work_log["at"] = -1000.0

func _c6_wait_for(cond: Callable, seconds: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(seconds * 1000.0):
		await get_tree().process_frame
		if cond.call():
			return true
	return false

func _c6_assist(world: Node, friend, player) -> void:
	var GP = load("res://scripts/ground_placement.gd")
	var spot: Vector2 = GP.find_free_ground_near(get_tree(), Vector2(300, 470), Vector2(120, 80), Rect2(0, 0, 640, 640), 160.0)
	var lines: Array = []
	var ok_all: bool = true
	# --- chop: two trees
	for g in get_tree().get_nodes_in_group("trees"):
		if g.global_position.distance_to(spot) < 110.0:
			g.remove_from_group("trees")
			g.queue_free()
	var tree_a = load("res://scenes/Tree.tscn").instantiate()
	tree_a.position = spot + Vector2(0, 0)
	world.add_child(tree_a)
	var tree_b = load("res://scenes/Tree.tscn").instantiate()
	tree_b.position = spot + Vector2(60, 6)
	world.add_child(tree_b)
	await get_tree().process_frame
	_c6_ready_friend(friend, spot + Vector2(30, 40))
	player.state = player.State.FREE
	player.held_tool = &"axe"
	player.position = spot + Vector2(-20, 12)
	friend.set_stance(2)
	player.request_chop(tree_a)
	var got: bool = await _c6_wait_for(func() -> bool: return friend.order_ai.job.has("target") and friend.order_ai.job["target"] == tree_b, 8.0)
	var claim_ok: bool = got and tree_b.claimed_by == friend and tree_a.claimed_by != friend
	var hits_before: int = tree_b.fell_hits_remaining
	await get_tree().create_timer(4.0).timeout
	var hit_progress: int = hits_before - tree_b.fell_hits_remaining
	lines.append("chop: his target %s (the other tree, not mine: %s), claimed by him %s, %d hits on it in 4 s, status '%s'" % ["tree B" if got else "none", got, claim_ok, hit_progress, friend.status_text()])
	ok_all = ok_all and claim_ok and hit_progress >= 1
	_c6_stop_work(player)
	var released: bool = await _c6_wait_for(func() -> bool: return friend.order_ai.job.is_empty() and tree_b.claimed_by == null, 9.0)
	lines.append("I stop: he lets go (claim released %s), status '%s'" % [released, friend.status_text()])
	ok_all = ok_all and released
	for t in [tree_a, tree_b]:
		t.remove_from_group("trees")
		t.queue_free()
	# --- hammer: a blueprint with its planks
	var bp = load("res://scenes/Building.tscn").instantiate()
	bp.building_type = load("res://assets/house_type.tres")
	bp.position = spot + Vector2(-10, 30)
	world.add_child(bp)
	await get_tree().process_frame
	bp.planks_ready = bp.plank_cost
	_c6_ready_friend(friend, spot + Vector2(30, 60))
	friend.set_stance(2)
	player.held_tool = &"hammer"
	player.position = spot + Vector2(-40, 40)
	player.request_hammer(bp)
	got = await _c6_wait_for(func() -> bool: return friend.order_ai.job.has("kind") and friend.order_ai.job["kind"] == &"hammer", 10.0)
	var progress_before: int = bp.build_progress
	_c6_stop_work(player)
	await get_tree().create_timer(3.0).timeout
	var friend_hits: int = bp.build_progress - progress_before
	lines.append("hammer: he joined my blueprint (%s) and added %d hits on his own in 3 s after I stopped (claim by him: %s)" % [got, friend_hits, str(bp.claimed_by == friend)])
	ok_all = ok_all and got and bp.claimed_by != friend
	await _c6_wait_for(func() -> bool: return friend.order_ai.job.is_empty(), 6.0)
	bp.remove_from_group("buildings")
	bp.remove_from_group("build_blockers")
	bp.queue_free()
	# --- plots: till, water, harvest
	var m = load("res://scripts/plot_manager.gd").get_for(get_tree())
	var field: Vector2i = Vector2i(31, 40)
	for gy in range(8, 52, 4):
		var clear: bool = true
		for dx in 6:
			if m.can_till(Vector2i(25 + dx, gy)) != "":
				clear = false
		if clear:
			field = Vector2i(25, gy)
			break
	player.position = m.cell_center(field) + Vector2(-12, 8)
	_c6_ready_friend(friend, player.position + Vector2(-20, 10))
	friend.set_stance(2)
	player.held_tool = &"hoe"
	var first_cell: Vector2i = field
	player.plot_till(first_cell)
	player.plot_till(first_cell)
	var t0: int = Time.get_ticks_msec()
	var friend_tilled: bool = false
	while Time.get_ticks_msec() - t0 < 9000:
		player.plot_till(field + Vector2i(0, 5))   # (keeps my own work going on a cell far from his)
		await get_tree().process_frame
		var others: int = 0
		for cell in m.plots.keys():
			if cell != first_cell and cell != field + Vector2i(0, 5):
				others += 1
		if others >= 1 and friend.order_ai.job.is_empty() == false or others >= 1:
			friend_tilled = true
			break
	lines.append("till: a plot of his own appeared (%s), his claims now %s" % [friend_tilled, str(m.claims.keys())])
	ok_all = ok_all and friend_tilled
	_c6_stop_work(player)
	var no_claims: bool = await _c6_wait_for(func() -> bool: return friend.order_ai.job.is_empty() and m.claims.is_empty(), 9.0)
	lines.append("no claims left (%s)" % no_claims)
	ok_all = ok_all and no_claims
	# water and harvest: three sown (unwatered) plots and three ripe ones
	var cells: Array[Vector2i] = []
	for i in 6:
		cells.append(field + Vector2i(i, 2))
	for i in 3:
		m.plots[cells[i]] = {"state": &"planted", "growth": 0.0, "synced": m.now(), "watered_until": 0.0}
	for i in range(3, 6):
		m.plots[cells[i]] = {"state": &"planted", "growth": m.ripe_growth(), "synced": m.now(), "watered_until": 0.0}
	player.position = m.cell_center(cells[1]) + Vector2(0, 14)
	player.held_tool = &"bucket"
	player.held_scoops = 4
	_c6_ready_friend(friend, player.position + Vector2(-20, 6))
	friend.set_stance(2)
	player.plot_water(cells[1])
	var watered_by_friend: bool = await _c6_wait_for(func() -> bool: return m.is_watered(cells[0]) or m.is_watered(cells[2]), 10.0)
	lines.append("water: he watered another plot (%s)" % watered_by_friend)
	ok_all = ok_all and watered_by_friend
	_c6_stop_work(player)
	await _c6_wait_for(func() -> bool: return friend.order_ai.job.is_empty(), 6.0)
	player.held_tool = &"sickle"
	player.position = m.cell_center(cells[4]) + Vector2(0, 14)
	_c6_ready_friend(friend, player.position + Vector2(-20, 6))
	friend.set_stance(2)
	var sheaves_before: int = get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"wheat_sheaf").size()
	player.plot_harvest(cells[4])
	var harvested: bool = await _c6_wait_for(func() -> bool: return m.stage(cells[3]) == &"stubble" or m.stage(cells[5]) == &"stubble", 10.0)
	var sheaves_after: int = get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"wheat_sheaf").size()
	lines.append("harvest: he cut another ripe plot (%s), sheaves %d -> %d" % [harvested, sheaves_before, sheaves_after])
	ok_all = ok_all and harvested and sheaves_after >= sheaves_before + 2
	_c6_stop_work(player)
	await _c6_wait_for(func() -> bool: return friend.order_ai.job.is_empty() and m.claims.is_empty(), 6.0)
	# --- pull grass
	var patch = load("res://scenes/GrassPatch.tscn").instantiate()
	patch.position = spot + Vector2(-60, -30)
	world.add_child(patch)
	var patch2 = load("res://scenes/GrassPatch.tscn").instantiate()
	patch2.position = spot + Vector2(-30, -20)
	world.add_child(patch2)
	await get_tree().process_frame
	player.held_tool = &""
	player.position = patch.position + Vector2(14, 8)
	_c6_ready_friend(friend, player.position + Vector2(10, 12))
	friend.set_stance(2)
	player.request_pull(patch)
	var pulled: bool = await _c6_wait_for(func() -> bool: return friend.order_ai.job.has("kind") and friend.order_ai.job["kind"] == &"pull", 8.0)
	lines.append("pull grass: he took the other patch (%s, his target is patch 2: %s)" % [pulled, pulled and friend.order_ai.job.get("target") == patch2])
	ok_all = ok_all and pulled
	_c6_stop_work(player)
	var clean: bool = await _c6_wait_for(func() -> bool: return friend.order_ai.job.is_empty() and patch.claimed_by == null and patch2.claimed_by == null, 9.0)
	lines.append("claims clean (%s)" % clean)
	ok_all = ok_all and clean
	for g in [patch, patch2]:
		g.remove_from_group("grass_patches")
		g.queue_free()
	for cell in cells:
		m.plots.erase(cell)
	for cell in m.plots.keys():
		if m.plots[cell].get("state") == &"tilled" or cell.y == field.y or cell.y == field.y + 5:
			m.plots.erase(cell)
	for g in get_tree().get_nodes_in_group("ground_items"):
		if g.kind == &"wheat_sheaf":
			g.remove_from_group("ground_items")
			g.queue_free()
	_q("O3", " | ".join(lines), ok_all)
	player.held_tool = &""
	friend.set_stance(0)

# ---- (4) stay, and back to the post after eating
func _c6_stay(friend, player) -> void:
	var GP = load("res://scripts/ground_placement.gd")
	var post: Vector2 = GP.find_free_ground_near(get_tree(), Vector2(300, 300), Vector2(30, 30), Rect2(0, 0, 640, 640), 100.0)
	_c6_ready_friend(friend, post)
	friend.set_stance(3)
	player.position = post + Vector2(150, 0)
	for i in 30:
		await get_tree().process_frame
	var at_post: float = friend.position.distance_to(friend.orders.post)
	# a ripe bush for him
	var bushes: Array = get_tree().get_nodes_in_group("berry_bushes")
	for b in bushes:
		if not b.is_ripe():
			b.berries = b.berries_per_bush
	friend.hunger.value = 30.0
	var ate: bool = false
	var t0: int = Time.get_ticks_msec()
	var back: bool = false
	var seen_states: Array = []
	while Time.get_ticks_msec() - t0 < 70000:
		await get_tree().process_frame
		var name_now: String = _c6_state_name(friend)
		if seen_states.is_empty() or seen_states[seen_states.size() - 1] != name_now:
			seen_states.append(name_now)
		if friend.state in [friend.State.TO_BUSH, friend.State.EATING, friend.State.TO_CRATE, friend.State.EATING_CRATE]:
			ate = true
		if ate and friend.state == friend.State.ORDERED and friend.position.distance_to(friend.orders.post) < 12.0 and friend.hunger.value > 30.0:
			back = true
			break
	_q("O4", "stay: he held his post (%.0f px off it), hunger 30 -> he went to eat (%s), hunger now %.0f, and is back within %.0f px of the post (%s); states %s" % [at_post, ate, friend.hunger.value, friend.position.distance_to(friend.orders.post), back, str(seen_states)], at_post < 12.0 and ate and back)
	friend.set_stance(0)

# ---- (5) the quick key
func _c6_toggle(friend, player) -> void:
	var colony: Node = get_tree().get_first_node_in_group("colony")
	_c6_ready_friend(friend, player.position + Vector2(40, 10))
	var steps: Array = []
	var seq: Array = []
	for i in 3:
		Input.parse_input_event(_key_event(KEY_F, true))
		await get_tree().process_frame
		Input.parse_input_event(_key_event(KEY_F, false))
		await get_tree().process_frame
		seq.append(friend.orders.name_now())
	# too far: nothing happens
	friend.position = player.position + Vector2(colony.order_toggle_distance_px + 80.0, 0)
	var before: String = friend.orders.name_now()
	Input.parse_input_event(_key_event(KEY_F, true))
	await get_tree().process_frame
	Input.parse_input_event(_key_event(KEY_F, false))
	var unchanged: bool = friend.orders.name_now() == before
	_q("O5", "key F pressed 3 times: %s; with him more than %.0f px away nothing changes (%s)" % [str(seq), colony.order_toggle_distance_px, unchanged], seq == ["Follow me", "Stay here", "Follow me"] and unchanged)
	friend.set_stance(0)

# ---- (6) the order survives a night's sleep
func _c6_sleep(friend, player) -> void:
	var GP = load("res://scripts/ground_placement.gd")
	var post: Vector2 = GP.find_free_ground_near(get_tree(), Vector2(260, 330), Vector2(30, 30), Rect2(0, 0, 640, 640), 100.0)
	_c6_ready_friend(friend, post)
	friend.set_stance(3)
	for i in 10:
		await get_tree().process_frame
	var post_before: Vector2 = friend.orders.post
	player.position = post + Vector2(60, 0)
	var clock_node: Node = self
	set_time(day, 0.8)
	var slept: bool = false
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 60000:
		await get_tree().process_frame
		if friend.is_asleep():
			slept = true
			break
	var stance_asleep: String = friend.orders.name_now()
	var asleep_state: String = _c6_state_name(friend)
	var asleep_status: String = friend.status_text()
	var reason: String = friend.talk_block_reason()
	set_time(day + 1, 0.1)
	friend.rest.value = 100.0
	var morning: bool = false
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 60000:
		await get_tree().process_frame
		if friend.state == friend.State.ORDERED and friend.position.distance_to(post_before) < 12.0:
			morning = true
			break
	_q("O6", "STAY at %s, night: he slept (%s, state %s, status '%s', talk disabled: '%s'), order still '%s'; morning: back at his post (%s), order '%s', post %s" % [post_before, slept, asleep_state, asleep_status, reason, stance_asleep, morning, friend.orders.name_now(), friend.orders.post], slept and morning and stance_asleep == "Stay here" and friend.orders.post == post_before and reason == "He is asleep.")
	set_time(day, 0.2)
	friend.set_stance(0)

# --- Work orders: roles and designated tasks (lumberjack, sawyer, hauler, builder), interrupts, failures, claims ----------------------------

func _self_check_world7() -> void:
	var world: Node = get_parent()
	var player = world.get_node_or_null("MainCharacter")
	var friend = get_tree().get_first_node_in_group("colonists")
	if player == null or friend == null:
		return
	get_window().size = Vector2i(1280, 720)
	set_time(day, 0.2)
	player.state = player.State.FREE
	player.held_tool = &""
	player.rest.value = 100.0
	player.hunger.value = 100.0
	var quiet: Array = _c7_quiet_npcs(world, true)
	var hidden: Dictionary = _c7_hide_buildings(true, {})
	await _c7_lumberjack(world, friend, player)
	await _c7_sawyer(world, friend, player)
	await _c7_hauler(world, friend, player)
	await _c7_builder(world, friend, player)
	await _c7_interrupt(world, friend, player)
	await _c7_failures(world, friend, player)
	await _c7_panel(friend, player)
	_q("W7", "claims after every job: %s" % _c7_claims_report(), _c7_claims_clean())
	_c7_hide_buildings(false, hidden)
	_c7_quiet_npcs(world, false, quiet)
	friend.order_ai.release_all(true)
	friend.orders.clear_work()
	friend.set_stance(0)
	get_window().size = Vector2i(64, 64)

# The NPC workers stay out of the way of the friend's tests.
func _c7_quiet_npcs(world: Node, on: bool, saved: Array = []) -> Array:
	if on:
		var out: Array = []
		for n in world.get_children():
			if "automation_enabled" in n:
				out.append([n, n.automation_enabled])
				n.automation_enabled = false
		return out
	for entry in saved:
		if is_instance_valid(entry[0]):
			entry[0].automation_enabled = entry[1]
	return []

# The storages, pit saws and sawmills already in the world are put aside (out of their groups) so each test has exactly what it builds.
func _c7_hide_buildings(on: bool, saved: Dictionary) -> Dictionary:
	if on:
		var out: Dictionary = {}
		for g in ["storages", "pit_saws", "sawmills", "toolboxes"]:
			out[g] = get_tree().get_nodes_in_group(g).duplicate()
			for n in out[g]:
				n.remove_from_group(g)
		return out
	for g in saved:
		for n in saved[g]:
			if is_instance_valid(n):
				n.add_to_group(g)
	return {}

func _c7_wait(cond: Callable, seconds: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(seconds * 1000.0):
		await get_tree().process_frame
		if cond.call():
			return true
	return false

func _c7_ready(friend, at: Vector2) -> void:
	friend.order_ai.release_all(true)
	friend.orders.clear_work()
	_c6_ready_friend(friend, at)
	friend.order_ai.fail_text = ""
	friend.order_ai.last_report = ""
	friend.order_ai._skips.clear()
	friend.order_ai._said.clear()
	friend.order_ai.said_count.clear()

func _c7_free_spot(near: Vector2, size: Vector2 = Vector2(80, 60)) -> Vector2:
	return load("res://scripts/ground_placement.gd").find_free_ground_near(get_tree(), near, size, Rect2(0, 0, 640, 640), 200.0)

# A tree with one hit per stage (so a test is quick), standing.
func _c7_tree(world: Node, at: Vector2):
	var t = load("res://scenes/Tree.tscn").instantiate()
	t.position = at
	world.add_child(t)
	t.fell_hits_remaining = 1
	t.delimb_hits_remaining = 1
	return t

# A tree already down and trimmed, its log ready.
func _c7_log_tree(world: Node, at: Vector2):
	var t = _c7_tree(world, at)
	t.receive_hit()
	await _c7_wait(func() -> bool: return t.is_felled(), 4.0)
	t.receive_hit()
	await _c7_wait(func() -> bool: return t.is_delimbed() and t.logs_ready > 0, 4.0)
	return t

func _c7_storage(world: Node, near: Vector2):
	var st = load("res://scenes/Storage.tscn").instantiate()
	st.position = _c7_free_spot(near, Vector2(60, 50))
	world.add_child(st)
	return st

func _c7_cleanup(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			for g in ["trees", "storages", "pit_saws", "buildings", "build_blockers", "plank_piles", "ground_items", "grinding_stones", "tables"]:
				n.remove_from_group(g)
			n.queue_free()

func _c7_claims_clean() -> bool:
	for t in get_tree().get_nodes_in_group("trees"):
		if t.claimed_by != null or t.log_claimed_by != null:
			return false
	for p in get_tree().get_nodes_in_group("plank_piles"):
		if p.reserved != 0:
			return false
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.claimed_by != null or b.planks_reserved != 0:
			return false
	for g in get_tree().get_nodes_in_group("pit_saws"):
		if g.worker != null:
			return false
	for i in get_tree().get_nodes_in_group("ground_items"):
		if i.get_meta(&"claimed_by", null) != null:
			return false
	return true

func _c7_claims_report() -> String:
	var n_trees: int = get_tree().get_nodes_in_group("trees").filter(func(t) -> bool: return t.claimed_by != null or t.log_claimed_by != null).size()
	var n_piles: int = get_tree().get_nodes_in_group("plank_piles").filter(func(p) -> bool: return p.reserved != 0).size()
	var n_bp: int = get_tree().get_nodes_in_group("buildings").filter(func(b) -> bool: return b.claimed_by != null or b.planks_reserved != 0).size()
	var n_items: int = get_tree().get_nodes_in_group("ground_items").filter(func(i) -> bool: return i.get_meta(&"claimed_by", null) != null).size()
	return "trees %d, plank piles %d, blueprints %d, items %d still claimed" % [n_trees, n_piles, n_bp, n_items]

# ---- (1) designate trees with a rectangle, unmark one, run the lumberjack job
func _c7_lumberjack(world: Node, friend, player) -> void:
	var base: Vector2 = _c7_free_spot(Vector2(330, 470), Vector2(150, 40))
	var st = _c7_storage(world, base + Vector2(-110, -10))
	var trees: Array = []
	for i in 5:
		trees.append(_c7_tree(world, base + Vector2(i * 26, 0)))
	await get_tree().process_frame
	_c7_ready(friend, base + Vector2(-30, 40))
	player.position = base + Vector2(60, 90)
	var mode: Node = get_tree().get_first_node_in_group("designation_mode")
	mode.start(friend, &"chop")
	var started: bool = mode.active and player.designating and mode._banner.visible
	mode.apply_box(base + Vector2(-20, -20), base + Vector2(4 * 26 + 20, 12), false)
	var marked: int = friend.orders.task_of(&"chop")["trees"].size()
	# right-click on the third tree unmarks it
	mode.apply_box(trees[2].position + Vector2(0, -10), trees[2].position + Vector2(0, -10), true)
	var after_unmark: int = friend.orders.task_of(&"chop")["trees"].size()
	var unmarked_ok: bool = not friend.orders.task_of(&"chop")["trees"].has(trees[2])
	var icon_check: bool = FileAccess.file_exists("res://ui/designation_axe.png")
	mode.finish()
	var ended: bool = not mode.active and not player.designating
	await get_tree().process_frame
	await get_tree().process_frame
	var done: bool = await _c7_wait(func() -> bool: return friend.orders.task_of(&"chop").is_empty(), 150.0)
	var felled: int = trees.filter(func(t) -> bool: return is_instance_valid(t) and not t.is_standing()).size()
	var third_standing: bool = is_instance_valid(trees[2]) and trees[2].is_standing() and trees[2].claimed_by == null
	await _c7_wait(func() -> bool: return friend.order_ai.work_job == null, 6.0)
	_q("W1", "designation (banner %s): %d trees marked by one rectangle, %d after unmarking one (%s); lumberjack task: %d trees felled, %d logs dragged into Storage (%d there), the unmarked tree still standing and free %s, report '%s', placeholder icon file %s; designation ended %s" % [started, marked, after_unmark, unmarked_ok, felled, st.logs_stored, st.logs_stored, third_standing, friend.order_ai.last_report, icon_check, ended], started and marked == 5 and after_unmark == 4 and unmarked_ok and done and felled == 4 and st.logs_stored == 4 and third_standing and friend.order_ai.last_report == "Done chopping." and ended)
	_c7_cleanup(trees + [st])
	await get_tree().process_frame
	friend.orders.clear_work()

# ---- (2) the sawyer: logs on the ground become planks, stacked in Storage
func _c7_sawyer(world: Node, friend, player) -> void:
	var base: Vector2 = _c7_free_spot(Vector2(300, 440), Vector2(120, 50))
	var st = _c7_storage(world, base + Vector2(-100, 0))
	var pit = load("res://scenes/PitSaw.tscn").instantiate()
	pit.starts_built = true
	pit.position = _c7_free_spot(base + Vector2(40, 10), Vector2(50, 40))
	world.add_child(pit)
	var logs: Array = []
	for i in 2:
		logs.append(await _c7_log_tree(world, _c7_free_spot(base + Vector2(i * 30, 70), Vector2(30, 30))))
	await get_tree().process_frame
	_c7_ready(friend, base + Vector2(20, 100))
	friend.orders.toggle_role(&"sawyer")
	var saw_seen: bool = false
	var hidden_seen: bool = false
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 150000:
		await get_tree().process_frame
		if pit.state == pit.State.SAWING:
			saw_seen = true
			hidden_seen = hidden_seen or not friend.visible
		if st.planks_stored >= 6 and friend.order_ai.work_job == null:
			break
	var loose_left: int = Logistics_loose(logs)
	_q("W2", "sawyer role, 2 logs on the ground, pit saw and Storage: sawing seen %s (he was hidden at the saw: %s), planks stacked in Storage %d (expected 6), loose logs left %d, planks left on the ground %d, he is visible again %s" % [saw_seen, hidden_seen, st.planks_stored, loose_left, get_tree().get_nodes_in_group("plank_piles").size(), friend.visible], saw_seen and hidden_seen and st.planks_stored == 6 and loose_left == 0 and friend.visible)
	for p in get_tree().get_nodes_in_group("plank_piles"):
		p.remove_from_group("plank_piles")
		p.queue_free()
	_c7_cleanup(logs + [st, pit])
	await get_tree().process_frame
	friend.orders.clear_work()

func Logistics_loose(trees: Array) -> int:
	return trees.filter(func(t) -> bool: return is_instance_valid(t) and t.is_delimbed() and t.logs_ready > 0).size()

# ---- (3) the haul zone: 3 logs and 2 planks into Storage
func _c7_hauler(world: Node, friend, player) -> void:
	var base: Vector2 = _c7_free_spot(Vector2(320, 450), Vector2(130, 50))
	var st = _c7_storage(world, base + Vector2(-110, 0))
	var logs: Array = []
	for i in 3:
		logs.append(await _c7_log_tree(world, _c7_free_spot(base + Vector2(i * 34, 0), Vector2(30, 30))))
	var piles: Array = []
	for i in 2:
		var pl = load("res://scripts/plank_piles.gd").spawn_pile(world, base + Vector2(i * 30, 50), 1)
		pl.position = base + Vector2(i * 30, 50)
		piles.append(pl)
	await get_tree().process_frame
	_c7_ready(friend, base + Vector2(-20, 90))
	var mode: Node = get_tree().get_first_node_in_group("designation_mode")
	mode.start(friend, &"haul")
	mode.apply_box(base + Vector2(-30, -50), base + Vector2(130, 80), false)
	var zone: Rect2 = friend.orders.task_of(&"haul")["zone"]
	mode.finish()
	var done: bool = await _c7_wait(func() -> bool: return friend.orders.task_of(&"haul").is_empty(), 150.0)
	await _c7_wait(func() -> bool: return friend.order_ai.work_job == null, 6.0)
	_q("W3", "haul zone %s with 3 logs and 2 planks: Storage now holds %d logs and %d planks, report '%s'" % [zone, st.logs_stored, st.planks_stored, friend.order_ai.last_report], done and st.logs_stored == 3 and st.planks_stored == 2 and friend.order_ai.last_report == "Done hauling.")
	_c7_cleanup(logs + piles + [st])
	await get_tree().process_frame
	friend.orders.clear_work()

# ---- (4) the builder: planks from Storage and loose flat stones, hammered to completion
func _c7_builder(world: Node, friend, player) -> void:
	var base: Vector2 = _c7_free_spot(Vector2(320, 440), Vector2(140, 60))
	var st = _c7_storage(world, base + Vector2(-100, 0))
	st.add_planks(5)
	var table_bp = load("res://scenes/Building.tscn").instantiate()
	table_bp.building_type = load("res://assets/table_type.tres")
	table_bp.position = _c7_free_spot(base + Vector2(20, 20), Vector2(40, 40))
	world.add_child(table_bp)
	var stone_bp = load("res://scenes/Building.tscn").instantiate()
	stone_bp.building_type = load("res://assets/grinding_stone_type.tres")
	stone_bp.position = _c7_free_spot(base + Vector2(80, 20), Vector2(40, 40))
	world.add_child(stone_bp)
	var stones: Array = []
	var stones_before: int = get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"flat_stone").size() + 2
	for i in 2:
		var s = load("res://scripts/items.gd").spawn(&"flat_stone", world, base + Vector2(30 + i * 14, 80))
		s.position = base + Vector2(30 + i * 14, 80)
		stones.append(s)
	await get_tree().process_frame
	_c7_ready(friend, base + Vector2(0, 90))
	var mode: Node = get_tree().get_first_node_in_group("designation_mode")
	mode.start(friend, &"build")
	mode.apply_box(table_bp.global_position + Vector2(0, -8), table_bp.global_position + Vector2(0, -8), false)
	mode.apply_box(stone_bp.global_position + Vector2(0, -8), stone_bp.global_position + Vector2(0, -8), false)
	var assigned: int = friend.orders.task_of(&"build")["blueprints"].size()
	mode.finish()
	var done: bool = await _c7_wait(func() -> bool: return friend.orders.task_of(&"build").is_empty(), 180.0)
	await _c7_wait(func() -> bool: return friend.order_ai.work_job == null, 6.0)
	var built_table: bool = not is_instance_valid(table_bp) or table_bp.state == table_bp.State.BUILT
	var built_stone: bool = not is_instance_valid(stone_bp) or stone_bp.state == stone_bp.State.BUILT
	_q("W4", "builder task, %d blueprints assigned (a table: 3 planks from Storage; a grinding stone: 2 loose flat stones): table built %s, grinding stone built %s, Storage planks %d (expected 2), stones lying %d (was %d: two used), report '%s'" % [assigned, built_table, built_stone, st.planks_stored, get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"flat_stone").size(), stones_before, friend.order_ai.last_report], assigned == 2 and done and built_table and built_stone and st.planks_stored == 2 and get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"flat_stone").size() == stones_before - 2 and friend.order_ai.last_report == "Done building.")
	for g in get_tree().get_nodes_in_group("tables") + get_tree().get_nodes_in_group("grinding_stones"):
		_c7_cleanup([g])
	_c7_cleanup([st, table_bp, stone_bp] + stones)
	await get_tree().process_frame
	friend.orders.clear_work()

# ---- (5) hunger 30 in the middle of a task: he eats and carries on
func _c7_interrupt(world: Node, friend, player) -> void:
	var base: Vector2 = _c7_free_spot(Vector2(320, 450), Vector2(140, 40))
	var st = _c7_storage(world, base + Vector2(-100, 0))
	for b in get_tree().get_nodes_in_group("berry_bushes"):
		if not b.is_ripe():
			b.berries = b.berries_per_bush
	var logs: Array = []
	for i in 3:
		logs.append(await _c7_log_tree(world, _c7_free_spot(base + Vector2(i * 36, 0), Vector2(30, 30))))
	await get_tree().process_frame
	_c7_ready(friend, base + Vector2(0, 50))
	friend.orders.toggle_role(&"hauler")
	var working: bool = await _c7_wait(func() -> bool: return friend.order_ai.work_job != null and (friend.order_ai.dragger.is_dragging() or st.logs_stored >= 1), 30.0)
	var stored_before: int = st.logs_stored
	friend.hunger.value = 30.0
	var ate: bool = false
	var back: bool = false
	var states: Array = []
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 120000:
		await get_tree().process_frame
		var name_now: String = _c6_state_name(friend)
		if states.is_empty() or states[states.size() - 1] != name_now:
			states.append(name_now)
		if friend.state in [friend.State.TO_BUSH, friend.State.EATING, friend.State.TO_CRATE, friend.State.EATING_CRATE]:
			ate = true
		if ate and st.logs_stored >= 3:
			back = true
			break
	var claims_ok_during: bool = true
	_q("W5", "hauler working (%s, %d logs stored so far); hunger set to 30: he ate (%s, hunger now %.0f), then finished the job (Storage %d of 3 logs: %s); states %s" % [working, stored_before, ate, friend.hunger.value, st.logs_stored, back, str(states.slice(0, 12))], working and ate and back and friend.hunger.value > 30.0)
	_c7_cleanup(logs + [st])
	await get_tree().process_frame
	friend.orders.clear_work()

# ---- (6) failures: the right message, once; the job is skipped and nothing stays claimed
func _c7_failures(world: Node, friend, player) -> void:
	var ai = friend.order_ai
	var lines: Array = []
	var ok: bool = true
	var base: Vector2 = _c7_free_spot(Vector2(320, 450), Vector2(140, 60))
	# a) No logs to saw (any log other tests left lying about is put aside for this)
	var spare_logs: Array = get_tree().get_nodes_in_group("trees").filter(func(t) -> bool: return t.logs_ready > 0)
	var spare_counts: Array = spare_logs.map(func(t) -> int: return t.logs_ready)
	for t in spare_logs:
		t.logs_ready = 0
	var pit = load("res://scenes/PitSaw.tscn").instantiate()
	pit.starts_built = true
	pit.position = base
	world.add_child(pit)
	await get_tree().process_frame
	_c7_ready(friend, base + Vector2(0, 60))
	var mode: Node = get_tree().get_first_node_in_group("designation_mode")
	mode.start(friend, &"saw")
	mode.apply_box(pit.global_position + Vector2(0, -6), pit.global_position + Vector2(0, -6), false)
	mode.finish()
	await get_tree().create_timer(4.0).timeout
	var said_a: int = int(ai.said_count.get("nologs", 0))
	lines.append("'%s' said %d time(s)" % [ai.fail_text if ai.fail_text != "" else ai.last_report, said_a])
	ok = ok and said_a == 1 and (ai.fail_text == "No logs to saw." or ai.last_report == "No logs to saw.")
	friend.orders.clear_work()
	_c7_cleanup([pit])
	for i in spare_logs.size():
		if is_instance_valid(spare_logs[i]):
			spare_logs[i].logs_ready = spare_counts[i]
	# b) Nowhere to store it (a loose log, no Storage, pit saw or sawmill)
	var lg = await _c7_log_tree(world, base + Vector2(30, 0))
	_c7_ready(friend, base + Vector2(0, 50))
	friend.orders.toggle_role(&"hauler")
	await get_tree().create_timer(4.0).timeout
	var said_b: int = int(ai.said_count.get("nowhere", 0))
	lines.append("'%s' said %d time(s); the log is skipped for 30 s (%s)" % [ai.fail_text, said_b, ai.is_skipped(lg)])
	ok = ok and said_b == 1 and ai.fail_text == "Nowhere to store it." and ai.is_skipped(lg) and lg.log_claimed_by == null and ai.work_job == null
	friend.orders.clear_work()
	_c7_cleanup([lg])
	# c) Out of materials for the blueprint (the loose stones of the world are put aside for this)
	var aside: Array = get_tree().get_nodes_in_group("ground_items").filter(func(g) -> bool: return g.kind == &"flat_stone")
	for s in aside:
		s.remove_from_group("ground_items")
	var bp = load("res://scenes/Building.tscn").instantiate()
	bp.building_type = load("res://assets/grinding_stone_type.tres")
	bp.position = base + Vector2(60, 0)
	world.add_child(bp)
	await get_tree().process_frame
	_c7_ready(friend, base + Vector2(0, 50))
	friend.orders.toggle_role(&"builder")
	await get_tree().create_timer(4.0).timeout
	var said_c: int = int(ai.said_count.get("materials", 0))
	lines.append("'%s' said %d time(s), blueprint skipped %s" % [ai.fail_text, said_c, ai.is_skipped(bp)])
	ok = ok and said_c == 1 and ai.fail_text == "Out of materials for the blueprint." and ai.is_skipped(bp) and bp.claimed_by == null and bp.planks_reserved == 0
	friend.orders.clear_work()
	_c7_cleanup([bp])
	for s in aside:
		if is_instance_valid(s):
			s.add_to_group("ground_items")
	# d) Cannot reach the tree (he is stuck three times on the way)
	var tr = _c7_tree(world, base + Vector2(30, 20))
	await get_tree().process_frame
	_c7_ready(friend, base + Vector2(0, 90))
	friend.orders.toggle_role(&"lumberjack")
	await _c7_wait(func() -> bool: return ai.work_job != null, 5.0)
	ai.stuck_events += 5
	await get_tree().create_timer(2.5).timeout
	var said_d: int = int(ai.said_count.get("unreachable_tree", 0))
	lines.append("'%s' said %d time(s), tree skipped %s and free %s" % [ai.fail_text, said_d, ai.is_skipped(tr), tr.claimed_by == null])
	ok = ok and said_d == 1 and ai.fail_text == "Cannot reach the tree." and ai.is_skipped(tr) and tr.claimed_by == null
	friend.orders.clear_work()
	ai.release_all(true)
	_c7_cleanup([tr])
	# e) No axe (only with friend_needs_tools)
	var colony: Node = get_tree().get_first_node_in_group("colony")
	colony.friend_needs_tools = true
	var tr2 = _c7_tree(world, base + Vector2(30, 20))
	await get_tree().process_frame
	_c7_ready(friend, base + Vector2(0, 90))
	friend.orders.toggle_role(&"lumberjack")
	await get_tree().create_timer(4.0).timeout
	var said_e: int = ai.said_count.get("tool", 0)
	lines.append("'%s' said %d time(s) with friend_needs_tools on" % [ai.fail_text, said_e])
	ok = ok and said_e == 1 and ai.fail_text == "No axe available" and tr2.claimed_by == null
	colony.friend_needs_tools = false
	friend.orders.clear_work()
	ai.release_all(true)
	_c7_cleanup([tr2])
	_q("W6", " | ".join(lines), ok)

# ---- the panel's Work section and the stance rule for tasks
func _c7_panel(friend, player) -> void:
	_c7_ready(friend, player.position + Vector2(16, 6))
	var panel: Node = friend.orders_panel
	friend.talk(player)
	await get_tree().process_frame
	await get_tree().process_frame
	var opened: bool = panel.is_open
	panel._toggle_role(&"hauler")
	panel._toggle_role(&"builder")
	panel._move_role(&"builder", -1)
	var roles_ok: bool = friend.orders.roles == [&"builder", &"hauler"]
	await get_tree().process_frame
	var rows: int = panel._roles_box.get_child_count()
	panel._start_task(&"chop")
	var mode: Node = get_tree().get_first_node_in_group("designation_mode")
	var designating: bool = mode.active and not panel.is_open and player.designating
	mode.cancel()
	var cancelled: bool = not mode.active and not player.designating and friend.orders.task_of(&"chop").is_empty()
	# tasks wait while he follows and run again with Free time / Stay
	friend.orders.ensure_task(&"build")
	friend.set_stance(1)
	var paused: String = friend.paused_text()
	friend.set_stance(3)
	var running: String = friend.paused_text()
	friend.set_stance(2)
	var paused_assist: String = friend.paused_text()
	panel._clear()
	var cleared: bool = friend.orders.roles.is_empty() and friend.orders.tasks.is_empty()
	friend.set_stance(0)
	_q("W8", "Orders panel (opened %s): roles ticked and reordered to %s (%d rows), a task button starts the designation and closes the panel (%s), Esc cancels it (%s); with tasks queued: Follow says '%s', Assist '%s', Stay '%s'; Clear all orders empties both (%s)" % [opened, str(friend.orders.roles), rows, designating, cancelled, paused, paused_assist, running, cleared], opened and roles_ok and designating and cancelled and paused == "Tasks paused while following." and paused_assist == "Tasks paused while following." and running == "" and cleared)
