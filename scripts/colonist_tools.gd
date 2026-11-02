extends Node

# THE TOOLS OF ONE COLONIST: what he holds, where a tool for a job comes from, and when it goes back. A child of the colonist's order AI
# (ai.tools). With Colony.friend_needs_tools on (the default) a job that needs a tool (ToolConfig.job_tools) cannot start without one.
#
#  FETCH (ensure): a tool he is not holding is looked for first in a toolbox (nearest first), then as a loose tool lying within
#    ToolConfig.tool_fetch_radius_px. He RESERVES it (toolbox.reserve_tool / the loose tool's "tool_reserved_by" meta: no other colonist
#    takes it, and the toolbox panel refuses it), walks to it and takes it: from the toolbox in tool_take_seconds with the lid open
#    (it is then lent to him: the panel shows "Axe (with Friend)"), a loose one by picking it up. If I pick a loose tool up first, I win and
#    he looks again.
#  NO TOOL: he does not start that work and says why once: "No axe available.", "The axe is in your hands.", "The toolbox is being
#    carried." The hover line keeps saying it; he looks again whenever the pick of a job comes round (well within tool_recheck_seconds),
#    so he starts the moment the tool turns up (when I put the axe back in the box), and no message is repeated until it has been available.
#  KEEP AND RETURN (wants_return / ReturnToolJob in work_jobs.gd): he keeps it while there is work for it and puts it back in the box it came
#    from (else the nearest box with room, else beside the nearest box, else where he stands) when nothing needed it for
#    tool_return_idle_seconds, when his roles / tasks / stance no longer need it, before he sleeps, or when I ask for it (recall_tool).
#    Dead or collapsed, he drops it where he stands (drop_here).

const ToolConfig = preload("res://scripts/tool_config.gd")
const PlankPiles = preload("res://scripts/plank_piles.gd")
const Items = preload("res://scripts/items.gd")
const GroundPlacement = preload("res://scripts/ground_placement.gd")

# The group a loose tool lies in (the hammer, shovel and axe have their own, the others are ground items of that kind).
const LOOSE_GROUPS: Dictionary = {&"hammer": "hammers", &"shovel": "shovels", &"axe": "axes"}

var c: Node2D = null
var ai: Node = null

# The tool in his hands: a read-only view of the one hands slot (ColonistOrderAI.hands); picking up and putting down go through that slot.
var hands: CharacterHands = null
var held: StringName:
	get:
		return hands.tool() if hands != null else &""
	set(_value):
		CharacterHands.report("ColonistTools.held is read-only (the one hands slot is ColonistOrderAI.hands)")
var source_box: Node2D = null
var idle: float = 0.0
var force_return: bool = false
var recall_after_strikes: int = -1
var return_gave_up: bool = false
var _res: Dictionary = {}
var _taking: float = -1.0
var _blocked: Dictionary = {}

func setup(colonist: Node2D, order_ai: Node) -> void:
	c = colonist
	ai = order_ai
	hands = order_ai.hands
	name = "Tools"

func cfg() -> Resource:
	return ToolConfig.cfg()

func enabled() -> bool:
	return c.colony != null and c.colony.friend_needs_tools

# --- Where a tool can come from ------------------------------------------------------------------------------------------------

func _boxes() -> Array:
	return c.get_tree().get_nodes_in_group("toolboxes")

# Loose tools of this kind lying near him that nobody has reserved.
func _loose(kind: StringName) -> Array:
	var out: Array = []
	var near: float = cfg().tool_fetch_radius_px
	var nodes: Array = c.get_tree().get_nodes_in_group(LOOSE_GROUPS[kind]) if LOOSE_GROUPS.has(kind) else c.get_tree().get_nodes_in_group("ground_items").filter(func(n) -> bool: return n.kind == kind)
	# (a seed bag with seeds in it is better than an empty one)
	if kind == &"seed_bag" and nodes.any(func(n) -> bool: return n.amount() > 0):
		nodes = nodes.filter(func(n) -> bool: return n.amount() > 0)
	for n in nodes:
		if n.is_queued_for_deletion() or (n.get_parent() != null and n.get_parent().is_in_group("tables")):
			continue
		var who = (n.get_meta(&"tool_reserved_by") if n.has_meta(&"tool_reserved_by") else null)
		if who != null and is_instance_valid(who) and who != c:
			continue
		if n.global_position.distance_to(c.position) <= near:
			out.append(n)
	return out

# {"type": "box" / "loose" / "none", "node"} for the nearest place this tool can be had now.
func source_for(kind: StringName) -> Dictionary:
	var best: Node2D = null
	var best_d: float = INF
	for box in _boxes():
		if box.is_carried():
			continue
		if box.tool_free(kind) or box.reserved_by(kind) == c:
			var d: float = c.position.distance_squared_to(box.global_position)
			if d < best_d:
				best_d = d
				best = box
	if best != null:
		return {"type": "box", "node": best}
	var loose: Array = _loose(kind)
	var nearest: Node2D = null
	best_d = INF
	for n in loose:
		var d2: float = c.position.distance_squared_to(n.global_position)
		if d2 < best_d:
			best_d = d2
			nearest = n
	if nearest != null:
		return {"type": "loose", "node": nearest}
	return {"type": "none", "node": null}

# Why there is none: "No axe available." / "The axe is in your hands." / "The toolbox is being carried."
func why_none(kind: StringName) -> String:
	var tool_name: String = String(kind).replace("_", " ")
	var player: Node = c.get_tree().get_first_node_in_group("player")
	if player != null and player.held_tool == kind:
		return "The %s is in your hands." % tool_name
	for box in _boxes():
		if box.is_carried() and box.kinds().has(kind):
			return "The toolbox is being carried."
	for box in _boxes():
		var other: Node = box.reserved_by(kind)
		if other != null and other != c:
			return "The %s is reserved by %s." % [tool_name, other.display_name]
	if not _boxes().is_empty():
		return "No %s in the toolbox." % tool_name
	return "No %s available." % tool_name

# A tool he was refused earlier is to be had now (the box got it back, I put it down): the order AI then lets a job that does not need it make room
# for the one that does (not while he drags a log or carries something).
func unblocked_now() -> bool:
	var any: bool = false
	for kind in _blocked.keys():
		if source_for(kind)["type"] != "none":
			_blocked.erase(kind)
			any = true
	return any

func has_source(kind: StringName) -> bool:
	return held == kind or source_for(kind)["type"] != "none"

# --- Starting a job that needs a tool ---------------------------------------------------------------------------------------------

# May a job needing `kind` (a tool, "" for none) start now? With none to be had it says why (once) and the answer is no.
func can_start(kind: StringName) -> bool:
	if kind == &"" or not enabled() or held == kind or _res.get("kind", &"") == kind:
		return true
	if source_for(kind)["type"] != "none":
		_blocked.erase(kind)
		return true
	var text: String = why_none(kind)
	var first: bool = not _blocked.has(kind) or _blocked[kind] != text
	_blocked[kind] = text
	# (The message is said once; the hover line keeps it for as long as he cannot start.)
	ai.fail("tool_" + String(kind), text, first)
	ai.fail_until = Time.get_ticks_msec() / 1000.0 + cfg().tool_recheck_seconds + 2.0
	return false

# One step of getting the tool for the job `who` (a work job, or the order AI for an Assist copy): 1 = he holds it, 0 = on his way,
# -1 = it cannot be had (said). `who` needs walk(point, delta) -> bool, `unreachable` and new_target().
func ensure(who, kind: StringName, delta: float) -> int:
	if kind == &"" or not enabled():
		return 1
	if held == kind:
		touch()
		return 1
	if held != &"":
		# another tool in his hands: it goes back first (the return job runs, then this job is picked again)
		force_return = true
		recall_after_strikes = -1
		return -2
	if _taking < 0.0 and hands.is_holding():
		# an item (a plank, the saw blade) or a log in his hands: it is put down first, then the tool is taken (one thing at a time)
		if ai.free_hands(who, delta) != 1:
			return 0
	# the taking (a short action at the open toolbox)
	if _taking >= 0.0:
		ai.working = true
		c.pose_idle()
		_taking -= delta
		if _taking > 0.0:
			return 0
		_taking = -1.0
		var box: Node2D = _res.get("node")
		if box != null and is_instance_valid(box) and hands.is_empty() and box.take_reserved(kind, c):
			hands.pick_up(kind, 1, true)
			# (a seed bag keeps its seeds, a bucket its water)
			hands.amount = box.last_amount
			source_box = box
			_res = {}
			touch()
			return 1
		_res = {}
		return 0
	# reserve
	if _res.is_empty() or _res.get("kind", &"") != kind:
		var src: Dictionary = source_for(kind)
		if src["type"] == "none":
			ai.fail("tool_" + String(kind), why_none(kind))
			return -1
		if src["type"] == "box":
			if not src["node"].reserve_tool(kind, c):
				return 0
		else:
			src["node"].set_meta(&"tool_reserved_by", c)
		_res = {"kind": kind, "type": src["type"], "node": src["node"]}
		who.new_target()
	# the reservation still stands?
	var node: Node2D = _res["node"]
	if node == null or not is_instance_valid(node) or node.is_queued_for_deletion():
		_res = {}
		return 0
	if _res["type"] == "box":
		if node.is_carried() or node.reserved_by(kind) != c:
			_res = {}
			return 0
	elif (node.get_meta(&"tool_reserved_by") if node.has_meta(&"tool_reserved_by") else null) != c:
		_res = {}
		return 0
	var stop: Vector2 = node.interact_point() if _res["type"] == "box" else node.global_position
	if who.walk(stop.round(), delta):
		if _res["type"] == "box":
			_taking = cfg().tool_take_seconds
			node.flash_open(cfg().tool_take_seconds)
			return 0
		# a loose tool: picked up (it is his now)
		var loose_amount: int = node.amount() if node.has_method("amount") else 1
		node.remove_from_group(LOOSE_GROUPS[kind] if LOOSE_GROUPS.has(kind) else "ground_items")
		node.remove_from_group("ground_items")
		node.queue_free()
		AudioManager.play("pickup", c.position)
		hands.pick_up(kind, 1, true)
		hands.amount = loose_amount
		source_box = null
		_res = {}
		touch()
		return 1
	if who.unreachable:
		release_reservation()
		return -1
	return 0

# A reserved tool he is not going to take after all.
func release_reservation() -> void:
	if not _res.is_empty():
		var node = _res.get("node")
		if node != null and is_instance_valid(node):
			if _res["type"] == "box":
				node.release_tool(_res["kind"], c)
			elif (node.get_meta(&"tool_reserved_by") if node.has_meta(&"tool_reserved_by") else null) == c:
				node.set_meta(&"tool_reserved_by", null)
	_res = {}
	_taking = -1.0

# --- Holding, using, giving back --------------------------------------------------------------------------------------------------

# For tests: whatever is in his hands is replaced by this tool.
func debug_hold(kind: StringName) -> void:
	hands.clear()
	hands.pick_up(kind, 1, true)

func reserving() -> bool:
	return not _res.is_empty()

# What goes into a box with the held thing: the seeds of a bag, the scoops of a bucket (nothing for a tool).
func _box_amount() -> int:
	return hands.amount if held == &"seed_bag" or held == &"bucket" else 0

func holding() -> bool:
	return held != &""

# A job just used the tool.
func touch() -> void:
	idle = 0.0

# Every frame (whatever he is doing): how long since the tool was used; a return that never gets done gives up after a while (he drops it).
var _force_time: float = 0.0

func tick_idle(delta: float) -> void:
	if held != &"":
		idle += delta
		if force_return:
			_force_time += delta
			if _force_time > 40.0:
				return_gave_up = true
				drop_here("he could not put it back for %d seconds" % int(_force_time))
		else:
			_force_time = 0.0
	else:
		_force_time = 0.0

# The tools his roles and tasks can use at all (what he would keep for): empty when his stance pauses the work.
func needed_tools() -> Array:
	var out: Array = []
	if not ai.work_allowed():
		return out
	var orders = c.orders
	var jobs: Array = []
	for role in orders.roles:
		match role:
			&"lumberjack":
				jobs.append(&"chop")
			&"builder":
				jobs.append(&"hammer")
				jobs.append(&"dig")
			&"cook":
				# (the fire starter and the bucket: the other things he moves are carried, not tools)
				for cook_item in [&"fire_starter", &"bucket"]:
					if not out.has(cook_item):
						out.append(cook_item)
			&"farmer":
				# (his four items: the hoe, the sickle, the seed bag and the bucket; the last two are no tools of the table but are fetched, held and returned the same way)
				for farm_item in [&"hoe", &"sickle", &"seed_bag", &"bucket"]:
					if not out.has(farm_item):
						out.append(farm_item)
	for task in orders.tasks:
		match task["type"]:
			&"chop":
				jobs.append(&"chop")
			&"build":
				jobs.append(&"hammer")
				jobs.append(&"dig")
	for j in jobs:
		var t: StringName = ToolConfig.tool_for(j)
		if t != &"" and not out.has(t):
			out.append(t)
	return out

# Should he go and put it back now?
func wants_return() -> bool:
	if held == &"" or return_gave_up:
		return false
	if force_return:
		# a recall waits for the swing in hand to finish
		return recall_after_strikes < 0 or not ai.working or ai.strikes > recall_after_strikes
	if idle >= cfg().tool_return_idle_seconds:
		return true
	# stances that do not use it: Follow, Stay, Free (Assist keeps it while the work he assists with needs it, the idle time decides)
	if c.orders.stance != c.Orders.Stance.ASSIST and not needed_tools().has(held):
		return true
	return false

# The player asks for it back (the greyed row in the toolbox panel).
func recall() -> void:
	if held != &"":
		force_return = true
		recall_after_strikes = ai.strikes

# About to sleep: it must go back first (unless it cannot).
func must_return_first() -> bool:
	return held != &"" and not return_gave_up and source_for_return() != null

func source_for_return() -> Node2D:
	var boxes: Array = _boxes().filter(func(b) -> bool: return not b.is_carried())
	if boxes.is_empty():
		return null
	return boxes[0]

# The box he puts it in: the one it came from, else the nearest with room (null: none has room).
func return_box() -> Node2D:
	if source_box != null and is_instance_valid(source_box) and not source_box.is_carried() and source_box.has_room(held):
		return source_box
	var best: Node2D = null
	var best_d: float = INF
	for box in _boxes():
		if box.is_carried() or not box.has_room(held):
			continue
		var d: float = c.position.distance_squared_to(box.global_position)
		if d < best_d:
			best_d = d
			best = box
	return best

# One step of putting the held tool away, for the job `who` (a work job: it needs walk(), unreachable and new_target()): the box it came from, else
# the nearest with room, else beside the nearest box, else where he stands. True once his hands are free of it. (The return job and the jobs that need
# both hands, such as dragging a log, use this one routine.)
var _pa_box: Node2D = null
var _pa_acting: float = -1.0

func put_away(who, delta: float) -> bool:
	if held == &"":
		_pa_box = null
		_pa_acting = -1.0
		return true
	# (putting it away is handling it: the idle clock that sends a tool home must not run out on the way to the box, or the job in hand is dropped)
	touch()
	if _pa_acting >= 0.0:
		ai.working = false
		_pa_acting -= delta
		if _pa_acting > 0.0:
			return false
		_pa_acting = -1.0
		var box: Node2D = _pa_box
		_pa_box = null
		if box != null and is_instance_valid(box) and box.return_tool(held, c, _box_amount()):
			finish_return()
			return true
		# the box filled up (or went): beside it instead
		return drop(box.global_position if box != null and is_instance_valid(box) else Vector2.INF)
	if _pa_box == null or not is_instance_valid(_pa_box) or _pa_box.is_carried() or not _pa_box.has_room(held):
		_pa_box = return_box()
		who.new_target()
		if _pa_box == null:
			# no box has room (or there is none): beside the nearest box, else where he stands
			var near: Node2D = null
			var near_d: float = INF
			for b in _boxes():
				if not b.is_carried() and c.position.distance_squared_to(b.global_position) < near_d:
					near_d = c.position.distance_squared_to(b.global_position)
					near = b
			if near == null:
				return drop()
			if who.walk(near.global_position + Vector2(0, 18), delta):
				return drop(near.global_position)
			if who.unreachable:
				return drop()
			return false
	if who.walk(_pa_box.interact_point().round(), delta):
		_pa_acting = cfg().tool_take_seconds
		_pa_box.flash_open(_pa_acting)
	elif who.unreachable:
		_pa_box = null
		return drop()
	return false

# The tool is back in a box (or has been put down): he holds nothing.
func finish_return() -> void:
	# (a box that still lists it as lent forgets that, wherever it came back to)
	if held != &"" and source_box != null and is_instance_valid(source_box):
		source_box.forget_borrowed(held, c)
	if hands.as_tool:
		hands.clear()
	source_box = null
	force_return = false
	recall_after_strikes = -1
	return_gave_up = false
	idle = 0.0

# Puts it down where he stands, or beside `near_box` (find_free_ground_near): a loose tool that anyone can find again. With no free ground anywhere near it
# stays in his hands ("Hands full", said once; false) unless `force` (dead, collapsed: it is dropped on the spot).
func drop(near: Vector2 = Vector2.INF, force: bool = false) -> bool:
	if held == &"":
		return true
	var at: Vector2 = c.position if near == Vector2.INF else near
	var spot: Vector2 = GroundPlacement.find_free_ground_near(c.get_tree(), at, Vector2(14, 10))
	if spot == Vector2.INF:
		if not force:
			ai.fail("hands_full", "Hands full")
			return false
		spot = at.round()
	var parent: Node = c.get_parent()
	if LOOSE_GROUPS.has(held):
		PlankPiles.spawn_tool(held, parent, spot)
	elif Items.is_item(held):
		Items.spawn(held, parent, spot, hands.amount if held == &"seed_bag" or held == &"bucket" else 0)
	if source_box != null and is_instance_valid(source_box):
		source_box.forget_borrowed(held, c)
	finish_return()
	return true

# Dropped where he stands because something took him out of the world (death, a task given up): said loudly, with the reason.
func drop_here(why: String = "no reason given") -> void:
	release_reservation()
	if held != &"":
		print("ITEM DROPPED: %s dropped the %s at (%d, %d): %s" % [c.display_name, held, c.position.x, c.position.y, why])
	drop(Vector2.INF, true)

# The tool goes back at once (the toolbox is about to be lifted with the player): into the box it came from, else the nearest with room, else onto the
# ground at his feet. (The walk to the box is skipped: he drops everything to help carry.)
func return_instantly() -> void:
	if held == &"":
		return
	release_reservation()
	var box: Node2D = return_box()
	if box != null and box.return_tool(held, c, _box_amount()):
		finish_return()
		return
	# (no box with room: beside his house, never where he stands)
	drop(ai.near_house_spot(), true)

# Everything the order AI lets go of when a job ends (a reservation not yet used); what he holds stays until it goes back.
func release_all() -> void:
	release_reservation()
