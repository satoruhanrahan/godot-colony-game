extends RefCounted

# THE FARMER ROLE: what a colonist with the Farmer role does about the farm zones (plot_manager.gd: farm_cells; marked with the "Farm zone" designation).
# It follows exactly the pattern of the Lumberjack, Sawyer and Builder (work_jobs.gd): pick() is asked by WorkJobs._role_job, returns one claimed job (a
# FarmJob works ONE cell; a HaulItemJob carries sheaves to a crate), the order AI runs execute() every frame and calls release() whenever it ends or is
# interrupted (hunger, sleep, a new order), so a claim can never stay behind. The tools come from ColonistTools.ensure like every other tool, and what he holds
# is the ONE held item (character_hands.gd): the hoe, the sickle, the seed bag (hands.amount = its seeds), the bucket (hands.amount = its scoops).
#
# THE CYCLE, in this order of priority:  harvest ripe cells (sickle) and carry the sheaves to a crate  >  water sown or growing cells that are dry (bucket,
# filled at the creek)  >  sow tilled cells (seed bag)  >  till bare cells and stubble (hoe). He works in BATCHES: the phase of the item in his hands comes
# first (all its cells, nearest first), then the next phase's item is fetched (the previous one goes back to the toolbox first). A phase that cannot
# be done (no hoe, no seeds, no water) says why once and is left alone for farm_skip_seconds while the others go on.
#
# SEEDS: from the seed bag (toolbox, crate or lying about). With no seeds in stock he threshes a sheaf into the bag (thresh_presses presses, thresh_seeds_per_sheaf
# seeds, as the player's), but only while the sheaves in stock (lying about + in crates) are more than Colony.farm_seed_reserve.
# Grinding and cooking are not his: sheaves and seeds are stored for later.

const WorkJobs = preload("res://scripts/work_jobs.gd")
const Logistics = preload("res://scripts/logistics.gd")
const WorkActions = preload("res://scripts/work_actions.gd")
const FoodConfig = preload("res://scripts/food_config.gd")
const Items = preload("res://scripts/items.gd")
const WaterMap = preload("res://scripts/water_map.gd")

const PHASES: Array[StringName] = [&"harvest", &"water", &"sow", &"till"]
const ITEM_OF: Dictionary = {&"harvest": &"sickle", &"water": &"bucket", &"sow": &"seed_bag", &"till": &"hoe"}
# The work (WorkActions.seconds / CharacterAnimator.work_cycle) each phase swings.
const SWING_OF: Dictionary = {&"harvest": &"harvest", &"water": &"water", &"sow": &"sow", &"till": &"till"}
const NO_WATER: Vector2i = Vector2i(-9999, -9999)

static func plots(tree: SceneTree) -> Node2D:
	return load("res://scripts/plot_manager.gd").get_for(tree)

static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

# A phase (or a cell) he is leaving alone for a while.
static func skipped(ai, key) -> bool:
	return float(ai.farm_skip.get(key, 0.0)) > _now()

static func skip_for(ai, key, seconds: float) -> void:
	ai.farm_skip[key] = _now() + seconds

# What a cell of a zone needs now: &"harvest", &"water", &"sow", &"till" or &"" (nothing, or it cannot be farmed).
static func cell_need(m: Node2D, cell: Vector2i) -> StringName:
	match m.stage(cell):
		&"ripe":
			return &"harvest"
		&"sown", &"growing":
			return &"water" if not m.is_watered(cell) else &""
		&"tilled":
			return &"sow"
		&"stubble":
			return &"till"
	return &"till" if m.can_farm(cell) == "" else &""

# The phase of the item he holds (&"" when it is none of the four).
static func held_phase(ai) -> StringName:
	for p in PHASES:
		if ITEM_OF[p] == ai.tools.held:
			return p
	return &""

# --- Stock: seeds and sheaves --------------------------------------------------------------------------------------------------------

static func seeds_in_stock(tree: SceneTree, ai) -> int:
	var n: int = ai.hands.amount if ai.tools.held == &"seed_bag" else 0
	for box in tree.get_nodes_in_group("toolboxes"):
		for e in box.contents:
			if e["kind"] == &"seed_bag":
				n += int(e["amount"])
	for item in tree.get_nodes_in_group("ground_items"):
		if item.kind == &"seed_bag" and not item.is_queued_for_deletion() and not _on_table(item):
			n += item.amount()
	for crate in tree.get_nodes_in_group("crates"):
		for s in crate.bags:
			n += int(s)
	return n

static func _on_table(item: Node) -> bool:
	return item.get_parent() != null and item.get_parent().is_in_group("tables")

# Does a seed bag exist anywhere (held, in a box, lying about, in a crate)?
static func bag_exists(tree: SceneTree, ai) -> bool:
	if ai.tools.held == &"seed_bag":
		return true
	for box in tree.get_nodes_in_group("toolboxes"):
		if box.kinds().has(&"seed_bag"):
			return true
	for item in tree.get_nodes_in_group("ground_items"):
		if item.kind == &"seed_bag" and not item.is_queued_for_deletion() and not _on_table(item):
			return true
	for crate in tree.get_nodes_in_group("crates"):
		if not crate.bags.is_empty():
			return true
	return false

static func ground_sheaves(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group("ground_items").filter(func(i) -> bool: return i.kind == &"wheat_sheaf" and not i.is_queued_for_deletion() and i.visible and not _on_table(i))

static func sheaves_in_stock(tree: SceneTree) -> int:
	var n: int = ground_sheaves(tree).size()
	for crate in tree.get_nodes_in_group("crates"):
		n += crate.count_of(&"wheat_sheaf")
	return n

# May he thresh one more sheaf? Only while more than the reserve stays in stock.
static func may_thresh(tree: SceneTree, colonist) -> bool:
	return sheaves_in_stock(tree) > colonist.colony.farm_seed_reserve

# Can the sowing be done at all: seeds in stock, or a bag and sheaves above the reserve to thresh.
static func sow_possible(tree: SceneTree, colonist) -> bool:
	var ai = colonist.order_ai
	return seeds_in_stock(tree, ai) > 0 or (bag_exists(tree, ai) and may_thresh(tree, colonist))

# --- Picking the job -----------------------------------------------------------------------------------------------------------------

static func pick(colonist) -> RefCounted:
	var ai = colonist.order_ai
	var tree: SceneTree = colonist.get_tree()
	var m: Node2D = plots(tree)
	if m.farm_cells.is_empty():
		ai.fail("no_farm_zone", "No farm zone")
		return null
	var by_phase: Dictionary = {}
	for p in PHASES:
		by_phase[p] = []
	var farmable: int = 0
	var unreachable_cells: int = 0
	for cell in m.farm_cells.keys():
		if m.can_farm(cell) != "" and not m.has_plot(cell):
			continue
		farmable += 1
		if m.is_claimed(cell) and m.claims[cell] != colonist:
			continue
		if skipped(ai, cell):
			unreachable_cells += 1
			continue
		var need: StringName = cell_need(m, cell)
		if need != &"":
			by_phase[need].append(cell)
	if farmable == 0:
		ai.fail("no_farm_zone", "No farm zone")
		return null
	# the order he tries the phases in: the one of the item in his hands first, then the priority order
	var order: Array = []
	var hp: StringName = held_phase(ai)
	if hp != &"":
		order.append(hp)
	for p in PHASES:
		if not order.has(p):
			order.append(p)
	for p in order:
		var cells: Array = by_phase[p]
		# the sheaves lying about are carried away once the harvesting is done (before anything is watered)
		if p == &"harvest" and cells.is_empty():
			var carry: RefCounted = _carry_job(colonist, m)
			if carry != null:
				return carry
		if cells.is_empty() or skipped(ai, p):
			continue
		if p == &"sow" and not sow_possible(tree, colonist):
			ai.fail("farm_seeds", "No seeds")
			skip_for(ai, p, colonist.colony.farm_skip_seconds)
			continue
		cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return colonist.position.distance_squared_to(m.cell_center(a)) < colonist.position.distance_squared_to(m.cell_center(b)))
		for cell in cells:
			var job: FarmJob = FarmJob.new()
			job.setup(colonist, {}, &"farmer")
			job.init_cell(p, cell, m)
			if job.claim(colonist):
				return job
	# nothing to do in the zone: the sheaves lying about still go to a crate
	return _carry_job(colonist, m)

# A sheaf lying within a few cells of a zone, when a crate takes it.
static func _carry_job(colonist, m: Node2D) -> RefCounted:
	var tree: SceneTree = colonist.get_tree()
	var ai = colonist.order_ai
	var near: Array = ground_sheaves(tree).filter(func(i) -> bool: return not ai.is_skipped(i) and (i.get_meta(&"claimed_by") if i.has_meta(&"claimed_by") else null) == null and _near_zone(m, i.global_position))
	if near.is_empty() or Logistics.item_destination(tree, &"wheat_sheaf", colonist.position).is_empty():
		return null
	near.sort_custom(func(a, b) -> bool: return colonist.position.distance_squared_to(a.global_position) < colonist.position.distance_squared_to(b.global_position))
	for item in near:
		var job = WorkJobs.HaulItemJob.new()
		job.setup(colonist, {}, &"farmer")
		job.init_item(item)
		if job.claim(colonist):
			return job
	return null

static func _near_zone(m: Node2D, p: Vector2) -> bool:
	var c0: Vector2i = m.cell_of(p)
	for dx in range(-3, 4):
		for dy in range(-3, 4):
			if m.farm_cells.has(c0 + Vector2i(dx, dy)):
				return true
	return false

# --- One cell ---------------------------------------------------------------------------------------------------------------------

class FarmJob extends WorkJobs.WorkJob:
	var kind: StringName = &""
	var cell: Vector2i = Vector2i.ZERO
	var m: Node2D = null
	var _crate: Node2D = null
	var _crate_what: StringName = &""
	var _sheaf: Node2D = null
	var _presses: int = 0
	var _hidden: bool = false
	var _door: Vector2 = Vector2.INF

	func init_cell(phase_kind: StringName, c_cell: Vector2i, manager: Node2D) -> FarmJob:
		kind = phase_kind
		cell = c_cell
		m = manager
		return self

	func primary_tool() -> StringName:
		return farm_item(kind)

	func farm_item(k: StringName) -> StringName:
		return ITEM_OF[k]

	func claim(colonist) -> bool:
		if not m.claim_cell(cell, colonist):
			return false
		claimed_by = colonist
		phase = "get"
		new_target()
		return true

	func describe() -> String:
		match phase:
			"get":
				# (a job that starts with the item already in his hands is simply at work)
				if ai.tools.held != farm_item(kind):
					return "Fetching the %s" % String(farm_item(kind)).replace("_", " ")
			"crate":
				return "Fetching a %s from the crate" % ("seed bag" if _crate_what == &"bag" else "sheaf")
			"seeds", "thresh":
				return "Threshing wheat for seed"
			"fill":
				return "Filling the bucket at the creek"
		match kind:
			&"harvest":
				return "Harvesting the field"
			&"water":
				return "Watering the field"
			&"sow":
				return "Sowing the field"
		return "Tilling the field"

	func release() -> void:
		if _hidden:
			_come_out()
		if m != null and is_instance_valid(m):
			m.release_cell(cell, c)
		if _sheaf != null and is_instance_valid(_sheaf):
			_sheaf.set_meta(&"claimed_by", null)
		super.release()

	# The cell must still need what this job does (the player may have tilled it meanwhile).
	func _still_needed() -> bool:
		return cell_need_of(cell) == kind and (m.can_farm(cell) == "" or m.has_plot(cell))

	func _skip_phase(seconds: float = -1.0) -> bool:
		load("res://scripts/farm_jobs.gd").skip_for(ai, kind, seconds if seconds >= 0.0 else c.colony.farm_skip_seconds)
		failed = true
		return true

	func _farm_lib():
		return load("res://scripts/farm_jobs.gd")

	func execute(_colonist, delta: float) -> bool:
		if m == null or not is_instance_valid(m):
			return true
		# (what he holds is in use for as long as this job runs, a long walk to the creek included: the idle clock that sends a tool home must not run out on the way)
		if ai.tools.holding():
			ai.tools.touch()
		match phase:
			"get":
				return _fetch_item(delta)
			"crate":
				return _crate_trip(delta)
			"seeds":
				return _seeds(delta)
			"thresh":
				return _thresh(delta)
			"fill":
				return _fill(delta)
			"walk":
				return _walk(delta)
			"work":
				return _work(delta)
		return true

	# The item of the phase in his hands: fetched like every tool (toolbox, else lying about; a seed bag also from a crate).
	func _fetch_item(delta: float) -> bool:
		if not _still_needed():
			return true
		var item: StringName = farm_item(kind)
		if not ai.tools.enabled():
			# (tools switched off: the item is simply in his hands, a bag with seeds and a bucket with water)
			if ai.tools.held != item:
				ai.tools.debug_hold(item)
				ai.hands.amount = FoodConfig.cfg().seed_bag_capacity if item == &"seed_bag" else (FoodConfig.cfg().bucket_capacity if item == &"bucket" else 0)
		if ai.tools.held == item:
			_after_get()
			return false
		if kind == &"sow" and ai.tools.source_for(item)["type"] == "none" and ai.hands.is_empty():
			var crate: Node2D = _crate_with_bag()
			if crate != null:
				_crate = crate
				_crate_what = &"bag"
				phase = "crate"
				new_target()
				return false
		var tk: int = ai.tools.ensure(self, item, delta)
		if tk == 0:
			return false
		if tk == -2:
			return true
		if tk < 0:
			return _skip_phase()
		_after_get()
		return false

	func _after_get() -> void:
		new_target()
		if kind == &"sow" and ai.hands.amount <= 0:
			phase = "seeds"
		elif kind == &"water" and ai.hands.amount <= 0:
			phase = "fill"
		else:
			phase = "walk"

	func _crate_with_bag() -> Node2D:
		var best: Node2D = null
		var best_d: float = INF
		for crate in c.get_tree().get_nodes_in_group("crates"):
			if crate.bags.is_empty() or crate.host_building() == null:
				continue
			var d: float = c.position.distance_squared_to(crate.global_position)
			if d < best_d:
				best_d = d
				best = crate
		return best

	func _crate_with_sheaf() -> Node2D:
		var best: Node2D = null
		var best_d: float = INF
		for crate in c.get_tree().get_nodes_in_group("crates"):
			if crate.count_of(&"wheat_sheaf") <= 0 or crate.host_building() == null:
				continue
			var d: float = c.position.distance_squared_to(crate.global_position)
			if d < best_d:
				best_d = d
				best = crate
		return best

	# To a crate's door, a moment inside (out of sight, like putting something in), then a seed bag in his hands or a sheaf on the ground.
	func _crate_trip(delta: float) -> bool:
		if _crate == null or not is_instance_valid(_crate) or _crate.host_building() == null:
			return _skip_phase()
		if not _hidden:
			var door: Vector2 = _crate.host_building().door_position()
			if walk(door.round(), delta):
				c.set_body_visible(&"job", false)
				_hidden = true
				_door = door
				_timer = 0.7
			elif unreachable:
				return _skip_phase()
			return false
		_timer -= delta
		if _timer > 0.0:
			return false
		var ok: bool = false
		if _crate_what == &"bag":
			var seeds: int = _crate.take_bag()
			if seeds >= 0 and ai.hands.is_empty():
				ai.tools.hands.pick_up(&"seed_bag", 1, true)
				ai.hands.amount = seeds
				ai.tools.source_box = null
				ok = true
		else:
			if _crate.take_item(&"wheat_sheaf", 1) > 0:
				Items.put(c.get_tree(), c.get_parent(), &"wheat_sheaf", _door + Vector2(8, 14), Rect2(0, 0, 640, 640))
				ok = true
		_come_out()
		if not ok:
			return _skip_phase()
		new_target()
		phase = "thresh" if _crate_what == &"sheaf" else ("seeds" if ai.hands.amount <= 0 else "walk")
		return false

	func _come_out() -> void:
		if _hidden:
			c.set_body_visible(&"job", true)
			if _door != Vector2.INF:
				c.position = _door + Vector2(0, 8)
			_hidden = false

	# The bag in his hands is empty: a bag with seeds elsewhere is swapped in; else a sheaf is threshed into it.
	func _seeds(delta: float) -> bool:
		var lib = _farm_lib()
		var tree: SceneTree = c.get_tree()
		var others: int = lib.seeds_in_stock(tree, ai) - ai.hands.amount
		if others > 0:
			# the empty bag goes back; the next pick takes the fuller one (the toolbox hands out the fullest bag first)
			if ai.free_hands(self, delta) == 1:
				return true
			return false
		if not lib.may_thresh(tree, c):
			ai.fail("farm_seeds", "No seeds")
			return _skip_phase()
		phase = "thresh"
		new_target()
		return false

	# Sheaves into the bag: walk to one lying about (or fetch one from a crate), thresh_presses presses each, until the bag has what the cells need or
	# the reserve is reached.
	func _thresh(delta: float) -> bool:
		var cfg: Resource = FoodConfig.cfg()
		var lib = _farm_lib()
		var tree: SceneTree = c.get_tree()
		if ai.tools.held != &"seed_bag":
			return true
		var wanted: int = mini(cfg.seed_bag_capacity, _cells_to_sow())
		if ai.hands.amount >= wanted or ai.hands.amount + cfg.thresh_seeds_per_sheaf > cfg.seed_bag_capacity:
			phase = "walk"
			new_target()
			return false
		if _sheaf == null or not is_instance_valid(_sheaf) or _sheaf.is_queued_for_deletion():
			_sheaf = null
			if not lib.may_thresh(tree, c):
				if ai.hands.amount > 0:
					phase = "walk"
					new_target()
					return false
				ai.fail("farm_seeds", "No seeds")
				return _skip_phase()
			var free: Array = lib.ground_sheaves(tree).filter(func(i) -> bool: return (i.get_meta(&"claimed_by") if i.has_meta(&"claimed_by") else null) == null)
			if free.is_empty():
				var crate: Node2D = _crate_with_sheaf()
				if crate == null:
					if ai.hands.amount > 0:
						phase = "walk"
						new_target()
						return false
					ai.fail("farm_seeds", "No seeds")
					return _skip_phase()
				_crate = crate
				_crate_what = &"sheaf"
				phase = "crate"
				new_target()
				return false
			free.sort_custom(func(a, b) -> bool: return c.position.distance_squared_to(a.global_position) < c.position.distance_squared_to(b.global_position))
			_sheaf = free[0]
			_sheaf.set_meta(&"claimed_by", c)
			_presses = 0
			new_target()
		if not _arrived_at_sheaf:
			if walk(_sheaf.interact_point().round(), delta):
				_arrived_at_sheaf = true
				face(_sheaf.global_position)
				_timer = interval(&"thresh")
			elif unreachable:
				_sheaf.set_meta(&"claimed_by", null)
				ai.skip(_sheaf, 30.0)
				_sheaf = null
				return false
			return false
		face(_sheaf.global_position)
		if swing(delta, &"thresh"):
			ai.tools.touch()
			_presses += 1
			if _presses < cfg.thresh_presses:
				AudioManager.play("thresh_rustle", _sheaf.global_position, 1.0)
			else:
				ai.hands.amount += cfg.thresh_seeds_per_sheaf
				_sheaf.remove_from_group("ground_items")
				_sheaf.queue_free()
				AudioManager.play("thresh_done", _sheaf.global_position, 1.0)
				_sheaf = null
				_arrived_at_sheaf = false
		return false

	var _arrived_at_sheaf: bool = false

	func _cells_to_sow() -> int:
		var n: int = 0
		for fc in m.farm_cells.keys():
			if m.stage(fc) == &"tilled":
				n += 1
		return maxi(1, n)

	# The bucket is empty: to the creek, a scoop at a time, then back to the cells.
	func _fill(delta: float) -> bool:
		var cfg: Resource = FoodConfig.cfg()
		var dry: int = 0
		for fc in m.farm_cells.keys():
			if cell_need_of(fc) == &"water":
				dry += 1
		var wanted: int = mini(cfg.bucket_capacity, maxi(1, dry))
		if ai.hands.amount >= wanted:
			phase = "walk"
			new_target()
			return false
		var tile: Vector2i = WaterMap.nearest_water(c.position, true)
		if tile == NO_WATER:
			ai.fail("farm_water", "No water")
			return _skip_phase()
		var spot: Vector2 = WaterMap.closest_point_in_tile(c.position, tile)
		if not _arrived_water:
			if walk(spot.round(), delta):
				_arrived_water = true
				face(spot)
				_timer = interval(&"scoop")
			elif unreachable:
				ai.fail("farm_water", "Cannot reach the water")
				return _skip_phase()
			return false
		face(spot)
		if swing(delta, &"scoop"):
			ai.tools.touch()
			ai.hands.amount += 1
			AudioManager.play("scoop", c.position)
		return false

	var _arrived_water: bool = false

	func cell_need_of(fc: Vector2i) -> StringName:
		return load("res://scripts/farm_jobs.gd").cell_need(m, fc)

	# To the cell: he stands just below it.
	func _walk(delta: float) -> bool:
		if not _still_needed():
			return true
		if (kind == &"sow" or kind == &"water") and ai.hands.amount <= 0:
			phase = "seeds" if kind == &"sow" else "fill"
			_arrived_water = false
			new_target()
			return false
		var spot: Vector2 = (m.cell_center(cell) + Vector2(0.0, float(m.size_px()) * 0.5 + 4.0)).round()
		if walk(spot, delta):
			phase = "work"
			face(m.cell_center(cell))
			_timer = interval(SWING_OF[kind])
		elif unreachable:
			ai.fail("farm_unreachable", "Cannot reach the field")
			load("res://scripts/farm_jobs.gd").skip_for(ai, cell, c.colony.farm_skip_seconds)
			failed = true
			return true
		return false

	func _work(delta: float) -> bool:
		if not _still_needed():
			return true
		face(m.cell_center(cell))
		if not swing(delta, SWING_OF[kind]):
			return false
		ai.tools.touch()
		match kind:
			&"till":
				if WorkActions.till(m, cell):
					return true
			&"harvest":
				WorkActions.harvest(c.get_tree(), m, cell, c.get_parent(), m.map_rect)
				return true
			&"sow":
				if ai.hands.amount > 0:
					ai.hands.amount -= 1
					m.sow(cell)
				return true
			&"water":
				if ai.hands.amount > 0:
					ai.hands.amount -= 1
					WorkActions.water(m, cell, c.position)
				return true
		return false
