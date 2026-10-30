extends RefCounted

# What every sleeper with an energy meter (colonists, the Lumberjack, Hauler, Builder, ...) shares about
# beds: which bed to go to, and when a nap or a night's sleep ends.
#
# Choosing (choose):
#  - a HOUSED colonist uses the best free bed inside HIS house: the one with the highest recovery (a wooden bed
#    counts by its bedding as it is now, then a grass / hay bed), ties going to the nearest; with none he sleeps on
#    the floor of his house (the caller does that);
#  - an UNHOUSED one treats every free bed as spare: the outdoor ones, and the free beds inside any finished
#    house (he walks to its door and goes in); he picks the nearest by distance (to the bed outdoors, to the door
#    for a bed inside), but a better bed is worth walking further for: each full share of recovery counts as
#    quality_px_per_recovery (60) pixels, so a fully furnished wooden bed beats a grass bed up to about 24 px
#    further away; with none he sleeps outdoors where he stands (the caller does that);
#  - workers (allow_interior false) only ever take beds out in the world.
# A bed is free when nobody is on it, nobody has reserved it and nobody is working on it. `avoid` lists beds
# he has already given up on.

# Pixels of walking one full share of recovery is worth to an unhoused colonist choosing a bed.
const QUALITY_PX_PER_RECOVERY: float = 60.0

enum Reason { NONE, NIGHT, EXHAUSTED }
enum Wake { KEEP, WAKE, WAKE_FULL, WAKE_CAPPED, TO_NIGHT }

static func reachable(tree: SceneTree, bed) -> bool:
	var p: Vector2 = bed.sleep_spot_world()
	return not Footprints.rect_blocked(tree, Rect2(p - Vector2(4, 2), Vector2(8, 4)))

static func choose(tree: SceneTree, who, from: Vector2, home, avoid: Array = [], allow_interior: bool = true):
	var best = null
	var best_key: float = INF
	for bed in tree.get_nodes_in_group("beds"):
		if avoid.has(bed) or not bed.is_free_for(who):
			continue
		var room: Node2D = bed.interior_node()
		var distance: float
		if room != null:
			var h = room.building
			# (Only a finished house has beds that count; a storage's room is no bedroom.)
			if not allow_interior or h == null or not is_instance_valid(h) or h.is_in_group("storages") or h.state != h.State.BUILT:
				continue
			if home != null and h != home:
				continue
			distance = from.distance_to(h.door_position())
		else:
			if home != null or not reachable(tree, bed):
				continue
			distance = from.distance_to(bed.global_position)
		# A housed colonist prefers the better bed whatever the distance.
		var key: float = distance - (1000.0 if home != null else QUALITY_PX_PER_RECOVERY) * bed.recovery_fraction()
		if key < best_key:
			best_key = key
			best = bed
	return best

# Does a sleeper, asleep now, wake? `outdoors` is true on the bare ground; `nap_seconds` is how many
# clock-seconds the sleep has lasted.
#  - A night's sleep ends at dawn, or earlier when he is full on a surface that can reach it.
#  - A nap (exhausted) on a bed or floor ends at nap_wake_energy (then, if it is already bedtime, it carries on
#    as the night's sleep). An outdoor nap, which cannot gain energy, ends after nap_outdoor_max_seconds.
static func step(clock: Node, rest: Node, reason: int, outdoors: bool, nap_seconds: float) -> int:
	if reason == Reason.NIGHT:
		if clock.is_daytime():
			return Wake.WAKE
		if not outdoors and rest.sleep_recovers() and rest.is_full():
			return Wake.WAKE_FULL
		return Wake.KEEP
	if reason == Reason.EXHAUSTED:
		if not clock.is_daytime():
			return Wake.TO_NIGHT
		if outdoors or not rest.sleep_recovers():
			return Wake.WAKE_CAPPED if nap_seconds >= clock.nap_outdoor_max_seconds else Wake.KEEP
		if rest.value >= clock.nap_wake_energy:
			return Wake.WAKE
	return Wake.KEEP
