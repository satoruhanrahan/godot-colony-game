extends RefCounted

# THE COOK ROLE: what a colonist with the Cook role does to turn the stored harvest into flatbread (the hand recipe, unchanged):
#     wheat sheaf --grinding stone (grind_presses presses)--> flour --dough board (+ a scoop of water, knead_presses presses)--> dough
#     --campfire stone (hot stone, cook_clock_seconds of hot time)--> flatbread --> a crate (storage) or a table.
# It follows the pattern of the Farmer, Builder and Sawyer (work_jobs.gd): pick() is asked by WorkJobs._role_job, returns ONE claimed job (a CookJob does one step of
# the chain on one set of stations), the order AI runs execute() every frame and calls release() whenever it ends or is interrupted (hunger, sleep, a new order,
# a station gone), so nothing stays reserved. Tools (the bucket, the fire starter) come from ColonistTools.ensure; every other thing he moves is the ONE held
# item (character_hands.gd): he puts down what he holds before he takes the next, and what he holds in the middle of a step that fails is handed to the
# CarryJob (a crate takes flour, sheaves and bread) or put back where it came from (dough goes back on the board).
#
# THE PLAN (planner below), the stage nearest to the bread first, so a half-made loaf is always finished before another is started:
#   1 cooked bread on the stone -> take it off, carry it to a crate (else a table)     2 bread lying about -> carry it to a crate (else a table)
#   3 dough on the board -> a lit campfire with a hot stone is made ready (flat stone, branch, fire starter: ONLY now, so no branch is wasted), the dough goes on
#   4 flour and water on the board -> knead    5 flour on the board -> water (a bucket with a scoop from the creek)    6 flour about -> to the board
#   7 loaves still missing and wheat about -> grind (several loads in a row: each flour goes to the empty board, else beside the stone)
# The target is Colony.bread_target; what counts is bread in crates and on tables (not what he holds), and everything already on its way (so he never
# makes more than the target needs). At the target with nothing under way he says 'Enough bread' once. A step that cannot be done says why once
# ('No wheat', 'No water', 'No branches', 'No flat stone', 'Cannot reach the grinding stone') and is left alone for farm_skip_seconds while the others go on.

const WorkJobs = preload("res://scripts/work_jobs.gd")
const Logistics = preload("res://scripts/logistics.gd")
const FoodConfig = preload("res://scripts/food_config.gd")
const Items = preload("res://scripts/items.gd")
const WaterMap = preload("res://scripts/water_map.gd")

const STAND: Vector2 = Vector2(0, 10)
const RESERVE: StringName = &"cook_reserved_by"
const NO_WATER: Vector2i = Vector2i(-9999, -9999)
# The extra fire time asked for on top of what the dough needs (so the first loaf is not cut short).
const FUEL_MARGIN: float = 10.0

static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

# --- Stations: reserved for a whole job (a meta on the node), on top of their own press claims -----------------------------------------------

static func reserved_by_other(node: Node, who) -> bool:
	if not node.has_meta(RESERVE):
		return false
	var other = node.get_meta(RESERVE)
	return other != null and is_instance_valid(other) and other != who

static func reserve(node: Node, who) -> bool:
	if reserved_by_other(node, who):
		return false
	node.set_meta(RESERVE, who)
	return true

static func unreserve(node: Node, who) -> void:
	if node != null and is_instance_valid(node) and node.has_meta(RESERVE) and node.get_meta(RESERVE) == who:
		node.set_meta(RESERVE, null)

# May this colonist use the station now (nobody else holds it or is in the middle of using it)?
static func free_for(node: Node, who) -> bool:
	if node == null or not is_instance_valid(node) or node.is_queued_for_deletion() or reserved_by_other(node, who):
		return false
	var cl = node.get("claimed_by")
	return cl == null or not is_instance_valid(cl) or cl == who

static func _on_table(n: Node) -> bool:
	return n.get_parent() != null and n.get_parent().is_in_group("tables")

static func nearest(nodes: Array, from: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d: float = INF
	for n in nodes:
		var d: float = from.distance_squared_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best

static func skipped(ai, key) -> bool:
	return float(ai.farm_skip.get(key, 0.0)) > _now()

static func skip_for(ai, key, seconds: float) -> void:
	ai.farm_skip[key] = _now() + seconds

# --- Stock ----------------------------------------------------------------------------------------------------------------------------------

# Everything the chain is made of, counted in loaves: bread in storage (crates, tables), and every unit on its way.
static func tally(tree: SceneTree) -> Dictionary:
	var t: Dictionary = {"bread": 0, "loose_bread": 0, "wheat": 0, "flour": 0, "stone_flour": 0, "stone_sheaf": 0, "board_flour": 0, "board_dough": 0, "stone_dough": 0, "stone_bread": 0}
	for crate in tree.get_nodes_in_group("crates"):
		t["bread"] += crate.count_of(&"flatbread")
		t["wheat"] += crate.count_of(&"wheat_sheaf")
		t["flour"] += crate.count_of(&"flour")
	for it in tree.get_nodes_in_group("ground_items"):
		if it.is_queued_for_deletion() or not it.visible:
			continue
		if _on_table(it):
			if it.kind == &"flatbread":
				t["bread"] += 1
			continue
		match it.kind:
			&"flatbread":
				t["loose_bread"] += 1
			&"wheat_sheaf":
				t["wheat"] += 1
			&"flour":
				t["flour"] += 1
	for s in tree.get_nodes_in_group("grinding_stones"):
		t["stone_flour"] += s.flour_out
		t["stone_sheaf"] += 1 if s.has_sheaf else 0
	for b in tree.get_nodes_in_group("dough_boards"):
		if b.is_queued_for_deletion():
			continue
		t["board_flour"] += 1 if b.has_flour else 0
		t["board_dough"] += 1 if b.dough else 0
	for f in tree.get_nodes_in_group("campfires"):
		for e in f.food:
			t["stone_bread" if e["kind"] == &"flatbread" else "stone_dough"] += 1
	return t

# A loaf in his hands (flour, dough, a sheaf for the stone, bread) is on its way too.
static func held_units(ai) -> int:
	return 1 if [&"flour", &"dough", &"wheat_sheaf", &"flatbread"].has(ai.carrying.get("kind", &"")) else 0

static func pending(t: Dictionary, ai) -> int:
	return int(t["loose_bread"]) + int(t["stone_bread"]) + int(t["stone_dough"]) + int(t["board_dough"]) + int(t["board_flour"]) + int(t["flour"]) + int(t["stone_flour"]) + int(t["stone_sheaf"]) + held_units(ai)

# Is something further down the chain waiting for him (cooked bread to take off, bread lying about, dough on the board with a free stone)? A grinding batch
# gives way to it after the load in hand, so a loaf is never left waiting while he grinds on.
static func waiting_work(tree: SceneTree, colonist, t: Dictionary) -> bool:
	if int(t["stone_bread"]) > 0 or int(t["loose_bread"]) > 0:
		return true
	if int(t["board_dough"]) > 0:
		for f in tree.get_nodes_in_group("campfires"):
			if free_for(f, colonist) and f.food.size() < FoodConfig.cfg().campfire_stone_capacity:
				return true
	return false

# How many loaves are still to be started (wheat -> flour) to reach the target.
static func missing(t: Dictionary, ai, colonist) -> int:
	return int(colonist.colony.bread_target) - int(t["bread"]) - pending(t, ai)

# "Bread 4/6, flour 2, wheat 9" for the Orders panel.
static func summary(tree: SceneTree, colonist) -> String:
	var t: Dictionary = tally(tree)
	return "Bread %d/%d, flour %d, wheat %d" % [t["bread"], colonist.colony.bread_target, int(t["flour"]) + int(t["stone_flour"]) + int(t["board_flour"]), int(t["wheat"]) + int(t["stone_sheaf"])]

# --- The plan ----------------------------------------------------------------------------------------------------------------------------

static func _job(colonist, kind: StringName, stone = null, board = null, fire = null, table = null) -> RefCounted:
	var job: CookJob = CookJob.new()
	job.setup(colonist, {}, &"cook")
	job.init_step(kind, stone, board, fire, table)
	return job if job.claim(colonist) else null

static func _try(colonist, kind: StringName, stone = null, board = null, fire = null, table = null) -> RefCounted:
	if skipped(colonist.order_ai, kind):
		return null
	return _job(colonist, kind, stone, board, fire, table)

static func _say(ai, key: String, text: String) -> void:
	ai.fail(key, text)

static func pick(colonist) -> RefCounted:
	var ai = colonist.order_ai
	var tree: SceneTree = colonist.get_tree()
	var pos: Vector2 = colonist.position
	var t: Dictionary = tally(tree)
	var stones: Array = tree.get_nodes_in_group("grinding_stones").filter(func(n) -> bool: return free_for(n, colonist))
	var boards: Array = tree.get_nodes_in_group("dough_boards").filter(func(n) -> bool: return free_for(n, colonist))
	var fires: Array = tree.get_nodes_in_group("campfires").filter(func(n) -> bool: return free_for(n, colonist))
	var tables: Array = tree.get_nodes_in_group("tables").filter(func(n) -> bool: return n.has_room() and not reserved_by_other(n, colonist))
	var stone = nearest(stones, pos)
	var board = nearest(boards, pos)
	var target: int = int(colonist.colony.bread_target)
	var miss: int = missing(t, ai, colonist)
	# the dough board with something on it is the one to use; else the nearest
	for b in boards:
		if b.has_flour or b.dough:
			board = b
			break
	# 1 cooked bread on a stone
	for f in fires:
		if not f.food.is_empty() and f.food[0]["kind"] == &"flatbread":
			var j1 = _try(colonist, &"bread", null, null, f, nearest(tables, f.global_position))
			if j1 != null:
				return j1
	# 2 bread lying about -> a crate (the CarryJob and HaulItemJob do the carrying), else a table
	if int(t["loose_bread"]) > 0:
		var j2 = _loose_bread(colonist, tree, tables)
		if j2 != null:
			return j2
	# 3 dough on a board: the fire is made ready, then the dough goes on
	if board != null and board.dough:
		var fire = _usable_fire(fires, colonist)
		if fire != null:
			var dough_fire = _make_fire_ready(colonist, fire, tree)
			if dough_fire != null:
				return dough_fire
			if fire.stone and fire.lit and fire.food.size() < FoodConfig.cfg().campfire_stone_capacity and not skipped(ai, &"dough"):
				var j3 = _try(colonist, &"dough", null, board, fire)
				if j3 != null:
					return j3
		elif fires.is_empty():
			_say(ai, "cook_no_fire", "No campfire")
	# 3b dough on a stone whose fire has gone out (rained out): the fire is made ready again, the dough stays where it is
	for f in fires:
		if not f.food.is_empty() and f.food[0]["kind"] == &"dough" and not f.lit:
			var j3b = _make_fire_ready(colonist, f, tree)
			if j3b != null:
				return j3b
	# 4 flour and water on the board
	if board != null and board.has_flour and board.has_water and not board.dough:
		var j4 = _try(colonist, &"knead", null, board)
		if j4 != null:
			return j4
	# 5 flour on the board: water
	if board != null and board.has_flour and not board.has_water and not board.dough:
		var j5 = _try(colonist, &"water", null, board)
		if j5 != null:
			return j5
	# 6 flour about, an empty board: to the board (only for loaves that are still to be made)
	var past_flour: int = int(t["loose_bread"]) + int(t["stone_bread"]) + int(t["stone_dough"]) + int(t["board_dough"]) + int(t["board_flour"])
	if board != null and not board.has_flour and not board.dough and int(t["flour"]) + int(t["stone_flour"]) > 0 and target - int(t["bread"]) - past_flour > 0:
		var j6 = _try(colonist, &"flour", stone, board)
		if j6 != null:
			return j6
	# 7 more loaves to start: grind
	if miss > 0:
		if stone == null:
			if stones.is_empty() and tree.get_nodes_in_group("grinding_stones").is_empty():
				_say(ai, "cook_no_stone", "No grinding stone")
		elif int(t["wheat"]) <= 0 and not stone.has_sheaf and stone.flour_out <= 0:
			_say(ai, "cook_no_wheat", "No wheat")
		elif board == null and tree.get_nodes_in_group("dough_boards").is_empty():
			_say(ai, "cook_no_board", "No dough board")
		else:
			var j7 = _try(colonist, &"grind", stone, board)
			if j7 != null:
				return j7
	elif pending(t, ai) == 0:
		_say(ai, "cook_enough", "Enough bread")
	else:
		ai.fail("cook_wait", "Waiting for the bread", false)
	return null

static func _usable_fire(fires: Array, colonist) -> Node2D:
	# a lit fire with a stone first (it is used as it is), else the nearest
	for f in fires:
		if f.lit and f.stone:
			return f
	return nearest(fires, colonist.position)

# The next step to make this fire ready for dough, or null when it is: a flat stone, enough fuel for the dough, a flame.
static func _make_fire_ready(colonist, fire: Node2D, tree: SceneTree) -> RefCounted:
	var ai = colonist.order_ai
	var cfg: Resource = FoodConfig.cfg()
	if not fire.stone:
		if tree.get_nodes_in_group("ground_items").filter(func(i) -> bool: return i.kind == &"flat_stone" and not i.is_queued_for_deletion() and not _on_table(i)).is_empty():
			_say(ai, "cook_no_flat_stone", "No flat stone")
			return null
		return _try(colonist, &"stone", null, null, fire)
	var heat_left: float = 0.0 if (fire.lit and fire.stone_heat >= cfg.stone_heat_clock_seconds) else cfg.stone_heat_clock_seconds - (fire.stone_heat if fire.lit else 0.0)
	var needed: float = cfg.cook_clock_seconds + heat_left + FUEL_MARGIN
	if fire.burn_left < needed and fire.burn_left < cfg.fire_max_fuel_clock_seconds - cfg.fuel_branch:
		if tree.get_nodes_in_group("ground_items").filter(func(i) -> bool: return i.kind == &"branch" and not i.is_queued_for_deletion() and not _on_table(i)).is_empty():
			if fire.burn_left <= 0.0:
				_say(ai, "cook_no_branches", "No branches")
				return null
		else:
			return _try(colonist, &"fuel", null, null, fire)
	if not fire.lit and fire.burn_left > 0.0:
		return _try(colonist, &"light", null, null, fire)
	return null

# Bread lying about: into a crate (HaulItemJob), else onto a table (a CookJob).
static func _loose_bread(colonist, tree: SceneTree, tables: Array) -> RefCounted:
	var ai = colonist.order_ai
	var items: Array = tree.get_nodes_in_group("ground_items").filter(func(i) -> bool: return i.kind == &"flatbread" and not i.is_queued_for_deletion() and i.visible and not _on_table(i) and not ai.is_skipped(i) and (i.get_meta(&"claimed_by") if i.has_meta(&"claimed_by") else null) == null)
	if items.is_empty():
		return null
	var item = nearest(items, colonist.position)
	if not Logistics.item_destination(tree, &"flatbread", colonist.position).is_empty():
		var job = WorkJobs.HaulItemJob.new()
		job.setup(colonist, {}, &"cook")
		job.init_item(item)
		return job if job.claim(colonist) else null
	var table = nearest(tables, item.global_position)
	if table == null or skipped(ai, &"table"):
		return null
	var tj: CookJob = CookJob.new()
	tj.setup(colonist, {}, &"cook")
	tj.init_step(&"table", null, null, null, table)
	tj.loose = item
	return tj if tj.claim(colonist) else null

# --- One step ----------------------------------------------------------------------------------------------------------------------------

class CookJob extends WorkJobs.WorkJob:
	var kind: StringName = &""
	var stone: Node2D = null
	var board: Node2D = null
	var fire: Node2D = null
	var table: Node2D = null
	# The bread lying about that the "table" step carries.
	var loose: Node2D = null
	var _item: StringName = &""
	var _src: Dictionary = {}
	var _hidden: bool = false
	var _door: Vector2 = Vector2.INF
	var _key: String = ""
	var _stage: String = ""
	var _loops: int = 0
	var _water_arrived: bool = false
	var _reserved: Array = []

	func init_step(k: StringName, st, bd, fr, tb) -> CookJob:
		kind = k
		stone = st
		board = bd
		fire = fr
		table = tb
		target = fire if fire != null else (stone if stone != null else (board if board != null else table))
		return self

	func _lib():
		return load("res://scripts/cook_jobs.gd")

	func claim(colonist) -> bool:
		var lib = _lib()
		for n in [stone, board, fire, table]:
			if n != null:
				if not lib.free_for(n, colonist) or not lib.reserve(n, colonist):
					_unreserve_all()
					return false
				_reserved.append(n)
		claimed_by = colonist
		phase = "free"
		match kind:
			&"grind":
				_stage = "start"
			&"flour":
				_item = &"flour"
			&"water":
				_item = &"bucket"
			&"stone":
				_item = &"flat_stone"
			&"fuel":
				_item = &"branch"
			&"light":
				_item = &"fire_starter"
			&"table":
				_item = &"flatbread"
		new_target()
		return true

	func _unreserve_all() -> void:
		var lib = _lib()
		for n in _reserved:
			lib.unreserve(n, c)
		_reserved.clear()

	func describe() -> String:
		match kind:
			&"grind":
				return "Grinding wheat"
			&"flour":
				return "Taking flour to the dough board"
			&"water":
				return "Fetching water" if phase == "fill" else "Adding water to the dough"
			&"knead":
				return "Making dough"
			&"stone":
				return "Putting a stone on the fire"
			&"fuel":
				return "Fetching a branch for the fire"
			&"light":
				return "Lighting the fire"
			&"dough":
				return "Putting the dough on the stone"
			&"bread":
				return "Taking the bread off the stone"
			&"table":
				return "Putting the bread on a table"
		return "Cooking"

	func primary_tool() -> StringName:
		return _item if (kind == &"water" or kind == &"light") else &""

	func release() -> void:
		if _hidden:
			_come_out()
		# dough in his hands goes back on the board; what else he holds is the CarryJob's
		if ai.carrying.get("kind", &"") == &"dough" and board != null and is_instance_valid(board) and not board.dough:
			board.dough = true
			board._refresh()
			ai.clear_carry()
		for n in [stone, board, fire]:
			if n != null and is_instance_valid(n) and n.has_method("release_claim"):
				n.release_claim(c)
		if _src.get("type", "") == "ground" and is_instance_valid(_src.get("node")):
			_src["node"].set_meta(&"claimed_by", null)
		_unreserve_all()
		super.release()

	func _skip(seconds: float = -1.0, message: String = "") -> bool:
		if message != "":
			ai.fail("cook_" + String(kind), message)
		_lib().skip_for(ai, kind, seconds if seconds >= 0.0 else c.colony.farm_skip_seconds)
		failed = true
		return true

	func _unreachable_of(node: Node2D, what: String) -> bool:
		ai.fail("cook_unreachable_" + what, "Cannot reach the %s" % what)
		_lib().skip_for(ai, kind, c.colony.farm_skip_seconds)
		failed = true
		return true

	func _stand(node: Node2D) -> Vector2:
		return (node.global_position + STAND).round()

	# One step towards `point`; the path is renewed whenever the goal changes.
	func _move(point: Vector2, key: String, delta: float) -> bool:
		if _key != key:
			_key = key
			new_target()
		return walk(point, delta)

	func _come_out() -> void:
		if _hidden:
			c.set_body_visible(&"job", true)
			if _door != Vector2.INF:
				c.position = _door + Vector2(0, 8)
			_hidden = false

	func _stations_ok() -> bool:
		for n in [stone, board, fire, table]:
			if n != null and (not is_instance_valid(n) or n.is_queued_for_deletion()):
				return false
		return true

	func execute(_colonist, delta: float) -> bool:
		if not _stations_ok():
			return true
		# (what he holds is in use for as long as this job runs, a long walk to the creek included: the idle clock that sends a tool home must not run out on the way)
		if ai.tools.holding():
			ai.tools.touch()
		match phase:
			"free":
				# (what the step is about to carry may be in his hands already: the bucket, a loaf of flour ...)
				if _item != &"" and (ai.tools.held == _item or ai.carrying.get("kind", &"") == _item):
					phase = "acquire"
					_key = ""
					return false
				var fh: int = ai.free_hands(self, delta)
				if fh != 1:
					return false
				phase = "acquire" if _item != &"" else "walk"
				_key = ""
				return false
			"acquire":
				return _acquire(delta)
			"fill":
				return _fill(delta)
			"crate":
				return _crate_trip(delta)
			"walk":
				return _walk_to_station(delta)
			"act":
				return _act(delta)
		return true

	# --- getting the thing to carry (a tool through ColonistTools.ensure; an item from the ground, a crate or the stone)
	func _acquire(delta: float) -> bool:
		if _item == &"bucket" or _item == &"fire_starter":
			if ai.tools.held == _item or not ai.tools.enabled():
				if not ai.tools.enabled() and ai.tools.held != _item:
					ai.tools.debug_hold(_item)
					ai.hands.amount = FoodConfig.cfg().bucket_capacity if _item == &"bucket" else 0
				phase = "fill" if (_item == &"bucket" and ai.hands.amount <= 0) else "walk"
				_water_arrived = false
				_key = ""
				return false
			var tk: int = ai.tools.ensure(self, _item, delta)
			if tk == 0:
				return false
			if tk == -2:
				return true
			if tk < 0:
				return _skip()
			return false
		if ai.carrying.get("kind", &"") == _item:
			phase = "walk"
			_key = ""
			return false
		if _src.is_empty() and not _find_source():
			return _skip(-1.0, _missing_text())
		var node: Node2D = _src["node"]
		if node == null or not is_instance_valid(node) or node.is_queued_for_deletion():
			_src = {}
			return false
		match _src["type"]:
			"ground":
				if _move(node.interact_point().round(), "src", delta):
					node.remove_from_group("ground_items")
					node.queue_free()
					ai.set_carry(_item, 1)
					_src = {}
					phase = "walk"
					_key = ""
				elif unreachable:
					return _unreachable_of(node, "stuff")
			"stone":
				if _move(_stand(node), "src", delta):
					if node.take_flour():
						ai.set_carry(&"flour", 1)
						AudioManager.play("pickup", c.position)
					_src = {}
					phase = "walk"
					_key = ""
				elif unreachable:
					return _unreachable_of(node, "grinding stone")
			"crate":
				phase = "crate"
				_key = ""
		return false

	func _missing_text() -> String:
		match _item:
			&"wheat_sheaf":
				return "No wheat"
			&"flour":
				return "No flour"
			&"flat_stone":
				return "No flat stone"
			&"branch":
				return "No branches"
		return "Nothing to fetch"

	func _find_source() -> bool:
		var tree: SceneTree = c.get_tree()
		var cands: Array = []
		for it in tree.get_nodes_in_group("ground_items"):
			if it.kind == _item and not it.is_queued_for_deletion() and it.visible and not _lib()._on_table(it) and (it.get_meta(&"claimed_by") if it.has_meta(&"claimed_by") else null) == null:
				cands.append({"type": "ground", "node": it})
		for crate in tree.get_nodes_in_group("crates"):
			if crate.count_of(_item) > 0 and crate.host_building() != null:
				cands.append({"type": "crate", "node": crate})
		if _item == &"flour":
			for s in tree.get_nodes_in_group("grinding_stones"):
				if s.flour_out > 0 and (s == stone or _lib().free_for(s, c)):
					cands.append({"type": "stone", "node": s})
		var best: Dictionary = {}
		var best_d: float = INF
		for cd in cands:
			var d: float = c.position.distance_squared_to(cd["node"].global_position)
			if d < best_d:
				best_d = d
				best = cd
		if best.is_empty():
			return false
		_src = best
		if best["type"] == "ground":
			best["node"].set_meta(&"claimed_by", c)
		return true

	# To a crate's door, a moment inside, then the thing is in his hands.
	func _crate_trip(delta: float) -> bool:
		var crate: Node2D = _src.get("node")
		if crate == null or not is_instance_valid(crate) or crate.host_building() == null:
			return _skip()
		if not _hidden:
			var door: Vector2 = crate.host_building().door_position()
			if _move(door.round(), "crate", delta):
				c.set_body_visible(&"job", false)
				_hidden = true
				_door = door
				_timer = 0.7
			elif unreachable:
				return _unreachable_of(crate, "crate")
			return false
		_timer -= delta
		if _timer > 0.0:
			return false
		var ok: bool = crate.take_item(_item, 1) > 0
		_come_out()
		_src = {}
		if not ok:
			return _skip(-1.0, _missing_text())
		ai.set_carry(_item, 1)
		phase = "walk"
		_key = ""
		return false

	# --- the bucket: a scoop from the creek when it is empty
	func _fill(delta: float) -> bool:
		var tile: Vector2i = WaterMap.nearest_water(c.position, true)
		if tile == NO_WATER:
			return _skip(-1.0, "No water")
		if ai.hands.amount >= 1:
			phase = "walk"
			_key = ""
			return false
		var spot: Vector2 = WaterMap.closest_point_in_tile(c.position, tile)
		if not _water_arrived:
			if _move(spot.round(), "water", delta):
				_water_arrived = true
				face(spot)
			elif unreachable:
				ai.fail("cook_water", "Cannot reach the water")
				return _skip()
			return false
		face(spot)
		if swing(delta, &"scoop"):
			ai.tools.touch()
			ai.hands.amount += 1
			AudioManager.play("scoop", c.position)
		return false

	# --- walking to where the step is done
	func _station_of_step() -> Node2D:
		match kind:
			&"grind":
				return board if _stage == "to_board" else stone
			&"dough":
				return fire if _stage == "to_fire" else board
			&"bread":
				return table if _stage == "to_table" else fire
			&"flour", &"water", &"knead":
				return board
			&"stone", &"fuel", &"light":
				return fire
			&"table":
				return table if _stage == "to_table" else loose
		return null

	func _walk_to_station(delta: float) -> bool:
		var st: Node2D = _station_of_step()
		if st == null:
			return true
		if kind == &"table" and _stage == "":
			# first the bread, then the table
			_stage = "to_bread"
			st = loose
		if _move(_stand(st), "station_" + str(st.get_instance_id()), delta):
			phase = "act"
			_key = ""
			_timer = 0.0
		elif unreachable:
			return _unreachable_of(st, _name_of(st))
		return false

	func _name_of(st: Node2D) -> String:
		if st == stone:
			return "grinding stone"
		if st == board:
			return "dough board"
		if st == fire:
			return "campfire"
		return "table"

	# --- doing it
	func _act(delta: float) -> bool:
		match kind:
			&"grind":
				return _act_grind(delta)
			&"flour":
				var msg: String = board.put_flour()
				ai.clear_carry() if msg == "" else ai.drop_carry()
				return true
			&"water":
				face(board.global_position)
				if swing(delta, &"pour"):
					ai.tools.touch()
					if ai.hands.amount > 0:
						ai.hands.amount -= 1
						board.pour_water()
					return true
				return false
			&"knead":
				return _act_knead(delta)
			&"stone":
				if not fire.place_stone():
					ai.drop_carry()
				else:
					ai.clear_carry()
				return true
			&"fuel":
				if fire.add_fuel(&"branch"):
					ai.clear_carry()
				else:
					ai.drop_carry()
				return true
			&"light":
				face(fire.global_position)
				if not fire.try_claim(c):
					return _skip(5.0)
				if swing(delta, &"spark"):
					ai.tools.touch()
					fire.spark_press(c)
					if fire.lit:
						return true
				return false
			&"dough":
				return _act_dough(delta)
			&"bread":
				return _act_bread(delta)
			&"table":
				return _act_table(delta)
		return true

	func _act_knead(delta: float) -> bool:
		face(board.global_position)
		if board.dough or not (board.has_flour and board.has_water):
			return true
		if swing(delta, &"knead"):
			ai.tools.touch()
			var msg: String = board.knead_press(c)
			if msg != "" and msg != "Someone is using it.":
				return true
		return board.dough

	# Dough: off the board into his hands, then onto the stone.
	func _act_dough(delta: float) -> bool:
		if _stage == "":
			if not board.dough:
				return true
			if ai.free_hands(self, delta) != 1:
				return false
			board.dough = false
			board._refresh()
			ai.set_carry(&"dough", 1)
			AudioManager.play("pickup", c.position)
			_stage = "to_fire"
			phase = "walk"
			_key = ""
			return false
		if _stage == "to_fire":
			var msg: String = fire.place_dough()
			if msg == "":
				ai.clear_carry()
			return true
		return true

	func _act_bread(delta: float) -> bool:
		if _stage == "to_table":
			_put_on_table()
			return true
		if fire.food.is_empty() or fire.food[0]["kind"] != &"flatbread":
			return true
		if ai.free_hands(self, delta) != 1:
			return false
		var got: StringName = fire.take_food()
		if got == &"":
			return true
		ai.set_carry(got, 1)
		# a crate takes it from here (the CarryJob does the carrying); else a table; else it is set down beside the fire
		if not Logistics.item_destination(c.get_tree(), &"flatbread", c.position).is_empty():
			return true
		if table != null and is_instance_valid(table) and table.has_room():
			_stage = "to_table"
			phase = "walk"
			_key = ""
			return false
		ai.drop_carry()
		return true

	func _put_on_table() -> void:
		if table != null and is_instance_valid(table) and table.has_room() and ai.carrying.get("kind", &"") == &"flatbread":
			var node: Node2D = Items.GroundItemScene.instantiate()
			node.kind = &"flatbread"
			table.put_node(node)
			AudioManager.play("table_set", table.global_position)
			ai.clear_carry()
		else:
			ai.drop_carry()

	func _act_table(_delta: float) -> bool:
		# at the bread: pick it up (free hands first), then on to the table
		if _stage == "to_bread" or _stage == "":
			if loose == null or not is_instance_valid(loose) or loose.is_queued_for_deletion():
				return true
			loose.remove_from_group("ground_items")
			loose.queue_free()
			ai.set_carry(&"flatbread", 1)
			_stage = "to_table"
			phase = "walk"
			_key = ""
			return false
		_put_on_table()
		return true

	# GRIND: several loads in a row. A sheaf in, the presses, the flour out and on to the board (an empty one) or beside the stone.
	func _act_grind(delta: float) -> bool:
		var lib = _lib()
		face(stone.global_position)
		match _stage:
			"start":
				_stage = "takeflour" if stone.flour_out > 0 else ("press" if stone.has_sheaf else "need_sheaf")
				return false
			"need_sheaf":
				_item = &"wheat_sheaf"
				_src = {}
				_stage = "sheaf_in"
				phase = "free"
				return false
			"sheaf_in":
				if swing(delta, &"grind_in"):
					var msg: String = stone.add_sheaf(c)
					if msg == "":
						ai.clear_carry()
						_stage = "press"
					else:
						ai.drop_carry()
						return true
				return false
			"press":
				if not stone.has_sheaf:
					_stage = "takeflour"
					return false
				if not stone.try_claim(c):
					return _skip(5.0)
				if swing(delta, &"grind"):
					ai.tools.touch()
					stone.grind_press(c)
					if stone.flour_out > 0:
						_stage = "takeflour"
				return false
			"takeflour":
				if stone.flour_out <= 0:
					_stage = "next"
					return false
				if ai.free_hands(self, delta) != 1:
					return false
				if stone.take_flour():
					ai.set_carry(&"flour", 1)
					AudioManager.play("pickup", c.position)
				_stage = "place"
				phase = "walk"
				_key = ""
				return false
			"place":
				# to the board when it is free for flour and the loaves are wanted, else beside the stone
				var t: Dictionary = lib.tally(c.get_tree())
				var to_board: bool = board != null and is_instance_valid(board) and not board.has_flour and not board.dough and int(c.colony.bread_target) - int(t["bread"]) - (int(t["loose_bread"]) + int(t["stone_bread"]) + int(t["stone_dough"]) + int(t["board_dough"]) + int(t["board_flour"])) > 0
				if to_board:
					_stage = "to_board"
					phase = "walk"
					_key = ""
					return false
				ai.drop_carry()
				_stage = "next"
				return false
			"to_board":
				if board.put_flour() == "":
					ai.clear_carry()
				else:
					ai.drop_carry()
				_stage = "next"
				return false
			"next":
				_loops += 1
				var t2: Dictionary = lib.tally(c.get_tree())
				if lib.waiting_work(c.get_tree(), c, t2):
					return true
				if _loops < 6 and lib.missing(t2, ai, c) > 0 and int(t2["wheat"]) > 0 and lib.free_for(stone, c):
					_stage = "need_sheaf"
					return false
				return true
		return true
