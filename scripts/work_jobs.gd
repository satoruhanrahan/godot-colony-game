extends RefCounted

# THE WORK JOBS OF A COLONIST: what the roles (Lumberjack, Sawyer, Hauler, Builder) and the designated tasks (chop these trees,
# saw logs, haul a zone, build these) actually DO. Every job is a JobBoard.Job (job_board.gd): the colonist's order AI
# (colonist_order_ai.gd) asks the board for one (JobBoard.pick_for -> WorkJobs.pick), runs execute() every frame until it returns
# true, and calls release() whenever the job ends or is interrupted, so a claim can never be left behind.
#
#   pick(): the order the precedence list gives (colonist_orders.gd): something already in his hands first, then the designated TASKS
#   in the order they were given (nearest target first inside a task), then the ROLES in his priority order.
#
# The jobs use the same objects and rules as the player and the NPC workers (Logistics for where things go; WorkActions for the
# hits; tree.claim_log, storage.add_log, pit_saw.accept_log, pile.reserve, building.planks_reserved ...), at friend_work_efficiency of
# the player's own work time, with the same energy and hunger scaling.
#
# Failures never loop: a job that cannot go on says why ONCE (ColonistOrderAI.fail), skips that target for SKIP_SECONDS and lets
# the next one be tried.

const Logistics = preload("res://scripts/logistics.gd")
const WorkActions = preload("res://scripts/work_actions.gd")
const JobBoardScript = preload("res://scripts/job_board.gd")
const PlankPiles = preload("res://scripts/plank_piles.gd")
const Items = preload("res://scripts/items.gd")

const DRAG_MULT: float = 0.5
const PLANK_MULT: float = 0.75
const SKIP_SECONDS: float = 30.0
const ROLE_RADIUS_PX: float = 240.0
const STACK_RADIUS_PX: float = 90.0

# --- The base of every job ---------------------------------------------------------------------------------------------------

class WorkJob extends JobBoardScript.Job:
	var c = null
	var ai = null
	var task: Dictionary = {}
	var role: StringName = &""
	var phase: String = ""
	var failed: bool = false
	var _timer: float = 0.0
	var _stuck_base: int = 0
	var unreachable: bool = false

	func setup(colonist, task_dict: Dictionary, role_name: StringName) -> void:
		c = colonist
		ai = colonist.order_ai
		task = task_dict
		role = role_name
		type = StringName(role_name if role_name != &"" else task_dict.get("type", &""))

	func can_do(_colonist) -> bool:
		return true

	func claim(colonist) -> bool:
		claimed_by = colonist
		return true

	func describe() -> String:
		return "Working"

	# "(3 marked left)" and the like, for the status line.
	func suffix() -> String:
		return ""

	func player() -> Node:
		return c.get_tree().get_first_node_in_group("player")

	# One step towards `point`, slower while dragging a log or carrying a plank. True once he is there; `unreachable` is set when he
	# has been stuck on the way three times.
	func walk(point: Vector2, delta: float, mult: float = 1.0) -> bool:
		var load_mult: float = 1.0
		if ai.dragger.is_dragging():
			load_mult = DRAG_MULT
		elif not ai.carrying.is_empty():
			load_mult = PLANK_MULT
		var arrived: bool = ai.go(point, delta, mult * load_mult)
		if ai.stuck_events - _stuck_base >= 3:
			unreachable = true
		if ai.dragger.is_dragging():
			ai.dragger.update()
		return arrived

	func new_target() -> void:
		_stuck_base = ai.stuck_events
		unreachable = false
		ai.waypoints_reset()

	# True when a strike is due (he stands working; the time between strikes is the player's own, scaled).
	func swing(delta: float, kind: StringName) -> bool:
		ai.working = true
		if c.animation != &"idle":
			c.play("idle")
		_timer -= delta
		if _timer > 0.0:
			return false
		_timer = interval(kind)
		return true

	func interval(kind: StringName) -> float:
		return WorkActions.seconds(kind, player()) / maxf(0.1, c.rest.efficiency() * c.colony.friend_work_efficiency)

	# With friend_needs_tools on he must hold the tool: fetched from the toolbox (1 = he has it, 0 = on his way, -1 = there is none).
	func ensure_tool(kind: StringName, delta: float) -> int:
		if not c.colony.friend_needs_tools:
			return 1
		var tool: StringName = WorkActions.TOOL_OF.get(kind, &"")
		if tool == &"" or ai.has_tool(tool):
			return 1
		var box: Node2D = ai.toolbox_node()
		if box == null or not box.kinds().has(tool):
			ai.fail("tool", "No %s available" % String(tool))
			return -1
		if walk(box.interact_point().round(), delta):
			if not ai.take_tool(tool):
				ai.fail("tool", "No %s available" % String(tool))
				return -1
			new_target()
			return 1
		return -1 if unreachable else 0

	# The job ends as a failure on this target (the reason has been said).
	func abort(node) -> bool:
		failed = true
		ai.skip(node, SKIP_SECONDS)
		return true

	func face(at: Vector2) -> void:
		c.flip_h = at.x < c.position.x

	# The job cannot go on: say why (once), skip the target for a while, and end.
	func give_up(key: String, text: String, node = null) -> bool:
		ai.fail(key, text)
		if node != null:
			ai.skip(node, SKIP_SECONDS)
		failed = true
		return true

	func give_up_unreachable(node, what: String) -> bool:
		return give_up("unreachable_" + what, "Cannot reach the %s." % what, node)

# --- Chop / delimb / drag a log ------------------------------------------------------------------------------------------------

class ChopJob extends WorkJob:
	var tree_node: Node2D = null
	var deliver: bool = true
	var prefer_storage: bool = false
	var dest: Dictionary = {}
	var trunk: Node2D = null
	var _log_claimed: bool = false
	var _attached: bool = false
	var _claimed: bool = false
	var _spot: Vector2 = Vector2.INF
	var _arrived: bool = false
	var _pickup: Vector2 = Vector2.ZERO

	func init_tree(t: Node2D, deliver_logs: bool, prefer_store: bool = false) -> ChopJob:
		tree_node = t
		deliver = deliver_logs
		prefer_storage = prefer_store
		target = t
		return self

	func claim(colonist) -> bool:
		if tree_node == null or not is_instance_valid(tree_node):
			return false
		if tree_node.is_standing() or tree_node.is_felled():
			if not tree_node.try_claim(colonist):
				return false
			_claimed = true
			phase = "fell" if tree_node.is_standing() else "delimb"
		elif tree_node.is_delimbed() and deliver:
			if tree_node.logs_ready <= 0 or tree_node.log_claimed_by != null:
				return false
			phase = "take"
		else:
			return false
		claimed_by = colonist
		new_target()
		return true

	func describe() -> String:
		var text: String = "Chopping a tree"
		match phase:
			"delimb":
				text = "Delimbing a tree"
			"take":
				text = "Going for a log"
			"deliver":
				text = "Hauling a log"
		return text + suffix()

	func suffix() -> String:
		if task.get("type", &"") == &"chop":
			var left: int = task["trees"].size()
			return " (%d marked left)" % left
		return ""

	func _spot_for(kind: StringName) -> Vector2:
		var pl: Node = player()
		var side: float = 1.0 if c.position.x > tree_node.position.x else -1.0
		var offs: Vector2 = pl.fell_stand_offset if kind == &"chop" else pl.delimb_stand_offset
		return Vector2(tree_node.position.x - side * offs.x, tree_node.position.y + offs.y).round()

	func execute(colonist, delta: float) -> bool:
		if tree_node == null or not is_instance_valid(tree_node):
			return true
		match phase:
			"fell", "delimb":
				if phase == "fell" and not tree_node.is_standing():
					phase = "delimb"
					_spot = Vector2.INF
					_arrived = false
				if phase == "delimb" and not tree_node.is_felled():
					return _after_delimb()
				var tk: int = ensure_tool(StringName(phase), delta)
				if tk == 0:
					return false
				if tk < 0:
					return abort(tree_node)
				if _spot == Vector2.INF:
					_spot = _spot_for(StringName(phase))
					new_target()
					_arrived = false
				if not _arrived:
					if walk(_spot, delta):
						_arrived = true
						face(tree_node.global_position)
						_timer = interval(StringName(phase))
					elif unreachable:
						return give_up_unreachable(tree_node, "tree")
					return false
				face(tree_node.global_position)
				if swing(delta, StringName(phase)):
					var r: Dictionary = WorkActions.chop(c.get_tree(), tree_node, StringName(phase), player().hits_per_chop)
					c.work_bob()
					if r["finished"]:
						if phase == "fell":
							phase = "delimb"
							_spot = Vector2.INF
							_arrived = false
						else:
							return _after_delimb()
				return false
			"take":
				return _take(delta)
			"deliver":
				return _deliver(delta)
		return true

	func _after_delimb() -> bool:
		if _claimed:
			tree_node.release_claim(c)
			_claimed = false
		if not deliver:
			_finish_tree()
			return true
		phase = "take"
		new_target()
		return false

	func _finish_tree() -> void:
		if task.get("type", &"") == &"chop":
			task["trees"].erase(tree_node)
			task["done"] = int(task.get("done", 0)) + 1

	func _take(delta: float) -> bool:
		if tree_node.logs_ready <= 0 and not _log_claimed:
			return true
		dest = Logistics.log_destination(c.get_tree(), c.position, prefer_storage)
		if dest.is_empty() and not _log_claimed:
			return give_up("nowhere", "Nowhere to store it.", tree_node)
		if not _log_claimed:
			trunk = tree_node.claim_log(c)
			if trunk == null:
				return true
			_log_claimed = true
			_pickup = ai.dragger.pickup_point(trunk)
			new_target()
		if walk(_pickup, delta):
			ai.dragger.attach(trunk)
			_attached = true
			ai.drag_tree = tree_node
			c.flip_h = ai.dragger.pickup_away < 0.0
			phase = "deliver"
			new_target()
		elif unreachable:
			return give_up_unreachable(tree_node, "log")
		return false

	func _deliver(delta: float) -> bool:
		if dest.is_empty() or not is_instance_valid(dest["node"]):
			dest = Logistics.log_destination(c.get_tree(), c.position, prefer_storage)
			if dest.is_empty():
				release()
				return give_up("nowhere", "Nowhere to store it.", tree_node)
			new_target()
		if walk(dest["stop"], delta):
			if Logistics.accept_log(dest):
				ai.dragger.release()
				tree_node.finish_log()
				ai.drag_tree = null
				_attached = false
				_log_claimed = false
				_finish_tree()
				return true
			dest = {}
		elif unreachable:
			release()
			return give_up_unreachable(tree_node, "storage")
		return false

	func release() -> void:
		if tree_node != null and is_instance_valid(tree_node):
			if _attached:
				var t: Node2D = ai.dragger.drop()
				tree_node.return_log(t)
				ai.drag_tree = null
			elif _log_claimed and trunk != null and is_instance_valid(trunk):
				tree_node.return_log(trunk)
			if _claimed:
				tree_node.release_claim(c)
		_attached = false
		_log_claimed = false
		_claimed = false
		super.release()

# --- Saw logs at the pit saw (alone) --------------------------------------------------------------------------------------------

class SawJob extends WorkJob:
	var pit: Node2D = null
	var tree_node: Node2D = null
	var store: Node2D = null
	var trunk: Node2D = null
	var _attached: bool = false
	var _have_log: bool = false
	var _pickup: Vector2 = Vector2.ZERO

	func init_pit(p: Node2D) -> SawJob:
		pit = p
		target = p
		return self

	# Gets hold of a log (a loose one, else one out of Storage), or finds the pit already loaded.
	func claim(colonist) -> bool:
		if pit == null or not is_instance_valid(pit) or not pit.is_built():
			return false
		claimed_by = colonist
		if pit.state == pit.State.LOADED and pit.worker == null:
			phase = "to_saw"
			new_target()
			return true
		if pit.state != pit.State.EMPTY:
			return false
		var loose: Array = Logistics.loose_logs(c.get_tree())
		var t: Node2D = Logistics.nearest(loose, c.position)
		if t != null:
			trunk = t.claim_log(colonist)
			if trunk != null:
				tree_node = t
				_have_log = true
				_pickup = ai.dragger.pickup_point(trunk)
				phase = "fetch"
				new_target()
				return true
		var s: Node2D = Logistics.nearest(c.get_tree().get_nodes_in_group("storages").filter(func(st) -> bool: return st.logs_stored > 0), c.position)
		if s != null and s.take_log():
			store = s
			trunk = Logistics.spawn_storage_log(s, c.get_parent())
			_have_log = true
			_pickup = ai.dragger.pickup_point(trunk)
			phase = "fetch"
			new_target()
			return true
		claimed_by = null
		ai.fail("nologs", "No logs to saw.")
		return false

	func describe() -> String:
		match phase:
			"fetch":
				return "Going for a log"
			"carry":
				return "Taking a log to the pit saw"
			"to_saw":
				return "Going to the pit saw"
			"saw":
				return "Sawing"
		return "Sawing"

	func execute(colonist, delta: float) -> bool:
		if pit == null or not is_instance_valid(pit):
			return true
		match phase:
			"fetch":
				if walk(_pickup, delta):
					ai.dragger.attach(trunk)
					_attached = true
					ai.drag_tree = tree_node
					c.flip_h = ai.dragger.pickup_away < 0.0
					phase = "carry"
					new_target()
				elif unreachable:
					return give_up_unreachable(tree_node if tree_node != null else pit, "log")
				return false
			"carry":
				if walk(pit.interact_point().round(), delta):
					if pit.accept_log():
						ai.dragger.release()
						if tree_node != null and is_instance_valid(tree_node):
							tree_node.finish_log()
						ai.drag_tree = null
						_attached = false
						_have_log = false
						phase = "to_saw"
						new_target()
					else:
						release()
						return give_up("pitbusy", "The pit saw is busy.", pit)
				elif unreachable:
					release()
					return give_up_unreachable(pit, "pit saw")
				return false
			"to_saw":
				if pit.state != pit.State.LOADED:
					return true
				if walk(pit.colonist_spot_world().round(), delta):
					if pit.begin_solo(c, c.colony.friend_work_efficiency):
						phase = "saw"
					else:
						return true
				elif unreachable:
					return give_up_unreachable(pit, "pit saw")
				return false
			"saw":
				ai.working = true
				# The pit saw works while he is hidden at it; he is back when it has finished.
				if pit.state != pit.State.SAWING or pit.worker != c:
					return true
				return false
		return true

	func release() -> void:
		if phase == "saw" and pit != null and is_instance_valid(pit):
			pit.cancel_solo(c)
		if _attached:
			var t: Node2D = ai.dragger.drop()
			if tree_node != null and is_instance_valid(tree_node):
				tree_node.return_log(t)
			elif store != null and is_instance_valid(store):
				store.add_log()
				t.queue_free()
			ai.drag_tree = null
		elif _have_log and trunk != null and is_instance_valid(trunk):
			if tree_node != null and is_instance_valid(tree_node):
				tree_node.return_log(trunk)
			elif store != null and is_instance_valid(store):
				store.add_log()
				trunk.queue_free()
		_attached = false
		_have_log = false
		super.release()

# --- Carry a plank to Storage ---------------------------------------------------------------------------------------------------

class HaulPlankJob extends WorkJob:
	var pile: Node2D = null
	var dest: Dictionary = {}
	var _reserved: bool = false

	func init_pile(p: Node2D) -> HaulPlankJob:
		pile = p
		target = p
		return self

	func claim(colonist) -> bool:
		if pile == null or not is_instance_valid(pile) or not pile.reserve():
			return false
		dest = Logistics.plank_destination(c.get_tree(), c.position)
		if dest.is_empty():
			pile.reserved = maxi(0, pile.reserved - 1)
			ai.fail("nowhere", "Nowhere to store it.")
			return false
		_reserved = true
		claimed_by = colonist
		phase = "to_pile"
		new_target()
		return true

	func describe() -> String:
		return "Fetching a plank" if phase == "to_pile" else "Carrying a plank"

	func execute(colonist, delta: float) -> bool:
		match phase:
			"to_pile":
				if pile == null or not is_instance_valid(pile):
					_reserved = false
					return true
				if walk(pile.interact_point().round(), delta):
					pile.take_reserved()
					_reserved = false
					ai.set_carry(&"plank", 1)
					phase = "to_dest"
					new_target()
				elif unreachable:
					return give_up_unreachable(pile, "planks")
				return false
			"to_dest":
				if dest.is_empty() or not is_instance_valid(dest["node"]) or dest["node"].plank_room() <= 0:
					dest = Logistics.plank_destination(c.get_tree(), c.position)
					new_target()
					if dest.is_empty():
						ai.drop_carry()
						return give_up("nowhere", "Nowhere to store it.")
				if walk(dest["stop"], delta):
					if dest["node"].add_planks(1) > 0:
						AudioManager.play("plank_drop", c.position)
						ai.clear_carry()
						return true
					dest = {}
				elif unreachable:
					return give_up_unreachable(dest["node"], "storage")
				return false
		return true

	func release() -> void:
		if _reserved and pile != null and is_instance_valid(pile):
			pile.reserved = maxi(0, pile.reserved - 1)
		_reserved = false
		super.release()

# --- Carry a loose item to a crate ----------------------------------------------------------------------------------------------

class HaulItemJob extends WorkJob:
	var item: Node2D = null
	var dest: Dictionary = {}
	var _kind: StringName = &""

	func init_item(i: Node2D) -> HaulItemJob:
		item = i
		target = i
		return self

	func claim(colonist) -> bool:
		if item == null or not is_instance_valid(item) or item.get_meta(&"claimed_by", null) != null:
			return false
		dest = Logistics.item_destination(c.get_tree(), item.kind, c.position)
		if dest.is_empty():
			ai.fail("nowhere", "Nowhere to store it.")
			return false
		item.set_meta(&"claimed_by", colonist)
		claimed_by = colonist
		phase = "to_item"
		new_target()
		return true

	func describe() -> String:
		return "Fetching %s" % Items.name_of(item.kind).to_lower() if phase == "to_item" and is_instance_valid(item) else "Carrying it to a crate"

	func execute(colonist, delta: float) -> bool:
		match phase:
			"to_item":
				if item == null or not is_instance_valid(item):
					return true
				if walk(item.interact_point().round(), delta):
					_kind = item.kind
					ai.set_carry(_kind, item.amount())
					item.remove_from_group("ground_items")
					item.queue_free()
					phase = "to_door"
					new_target()
				elif unreachable:
					return give_up_unreachable(item, "item")
				return false
			"to_door":
				if dest.is_empty() or not is_instance_valid(dest["node"]) or dest["node"].is_full():
					dest = Logistics.item_destination(c.get_tree(), _kind, c.position)
					new_target()
					if dest.is_empty():
						ai.drop_carry()
						return give_up("nowhere", "Nowhere to store it.")
				if walk(dest["door"].round(), delta):
					c.visible = false
					_timer = 0.7
					phase = "inside"
				elif unreachable:
					return give_up_unreachable(dest["node"], "crate")
				return false
			"inside":
				_timer -= delta
				if _timer > 0.0:
					return false
				var crate: Node2D = dest["node"]
				var amount: int = int(ai.carrying.get("amount", 0))
				var ok: bool = crate.add_bag(amount) if _kind == &"seed_bag" else crate.add_item(_kind, 1) > 0
				_come_out()
				if ok:
					ai.clear_carry()
					return true
				ai.drop_carry()
				return give_up("nowhere", "Nowhere to store it.")
		return true

	func _come_out() -> void:
		if not c.visible and not c.in_room:
			c.visible = true
			if dest.has("door"):
				c.position = dest["door"] + Vector2(0, 8)

	func release() -> void:
		if phase == "inside":
			_come_out()
		if item != null and is_instance_valid(item):
			item.set_meta(&"claimed_by", null)
		super.release()

# --- Build a blueprint: bring what it needs, then hammer ----------------------------------------------------------------------

class BuildJob extends WorkJob:
	var bp: Node2D = null
	var src: Dictionary = {}
	var _item: Node2D = null
	var _plank_reserved: bool = false
	var _hammer_claimed: bool = false
	var _need_kind: StringName = &""
	var _spot: Vector2 = Vector2.INF
	var _arrived: bool = false

	func init_blueprint(b: Node2D) -> BuildJob:
		bp = b
		target = b
		return self

	func claim(colonist) -> bool:
		if bp == null or not is_instance_valid(bp) or bp.state == bp.State.BUILT:
			return false
		claimed_by = colonist
		phase = "decide"
		new_target()
		return true

	# Already holding a plank (after an interruption): deliver it.
	func claim_carried(colonist) -> bool:
		if bp == null or not is_instance_valid(bp) or bp.planks_needed() <= 0:
			return false
		bp.planks_reserved += 1
		_plank_reserved = true
		claimed_by = colonist
		phase = "deliver"
		new_target()
		return true

	func describe() -> String:
		var name_text: String = bp.display_name() if bp != null and is_instance_valid(bp) else "a blueprint"
		match phase:
			"hammer":
				return "Hammering %s%s" % [name_text, suffix()]
			"fetch", "take":
				return "Fetching %s for %s%s" % [String(_need_kind).replace("_", " "), name_text, suffix()]
			"deliver":
				return "Bringing %s to %s%s" % [String(_need_kind).replace("_", " ") if _need_kind != &"" else "a plank", name_text, suffix()]
		return "Building %s%s" % [name_text, suffix()]

	func suffix() -> String:
		if task.get("type", &"") == &"build":
			return " (%d left)" % task["blueprints"].size()
		return ""

	func execute(colonist, delta: float) -> bool:
		if bp == null or not is_instance_valid(bp) or bp.state == bp.State.BUILT:
			_done()
			return true
		match phase:
			"decide":
				return _decide()
			"fetch":
				return _fetch(delta)
			"deliver":
				return _deliver(delta)
			"hammer":
				return _hammer(delta)
		return true

	func _decide() -> bool:
		if bp.is_supplied():
			phase = "hammer"
			_spot = Vector2.INF
			new_target()
			return false
		var tree: SceneTree = c.get_tree()
		if bp.planks_needed() > 0:
			src = Logistics.plank_source(tree, c.position)
			if src.is_empty():
				return give_up("materials", "Out of materials for the blueprint.", bp)
			if src["kind"] == "pile" and not src["node"].reserve():
				return false
			bp.planks_reserved += 1
			_plank_reserved = true
			_need_kind = &"plank"
			phase = "fetch"
			new_target()
			return false
		for kind in bp.materials_cost:
			if bp.material_missing(StringName(kind)) > 0:
				var it: Node2D = Logistics.material_source(tree, StringName(kind), c.position)
				if it == null:
					return give_up("materials", "Out of materials for the blueprint.", bp)
				it.set_meta(&"claimed_by", c)
				_item = it
				_need_kind = StringName(kind)
				src = {"kind": "item", "node": it}
				phase = "fetch"
				new_target()
				return false
		phase = "hammer"
		return false

	func _fetch(delta: float) -> bool:
		var node = src["node"]
		if node == null or not is_instance_valid(node):
			_drop_reservation()
			phase = "decide"
			return false
		var stop: Vector2 = node.global_position
		if src["kind"] == "storage":
			stop = node.global_position + Logistics.STORAGE_STOP_OFFSET
		elif src["kind"] == "sawmill":
			stop = node.global_position + Logistics.SAWMILL_STOP_OFFSET
		if walk(stop.round(), delta):
			var got: bool = false
			match src["kind"]:
				"pile":
					node.take_reserved()
					got = true
				"storage":
					got = node.take_planks(1) > 0
				"sawmill":
					if node.planks_ready > 0:
						node.planks_ready -= 1
						got = true
				"item":
					node.remove_from_group("ground_items")
					node.queue_free()
					_item = null
					got = true
			if not got:
				_drop_reservation()
				phase = "decide"
				return false
			ai.set_carry(_need_kind, 1)
			phase = "deliver"
			new_target()
		elif unreachable:
			_drop_reservation()
			return give_up_unreachable(node, "materials")
		return false

	func _drop_reservation() -> void:
		if _plank_reserved and bp != null and is_instance_valid(bp):
			bp.planks_reserved = maxi(0, bp.planks_reserved - 1)
		_plank_reserved = false
		if _item != null and is_instance_valid(_item):
			_item.set_meta(&"claimed_by", null)
		_item = null

	func _deliver(delta: float) -> bool:
		if walk((bp.global_position + Logistics.BUILDING_STOP_OFFSET).round(), delta):
			var kind: StringName = ai.carrying.get("kind", &"")
			var ok: bool = false
			if kind == &"plank":
				if _plank_reserved:
					bp.planks_reserved = maxi(0, bp.planks_reserved - 1)
					_plank_reserved = false
				bp.planks_ready += 1
				ok = true
				AudioManager.play("plank_drop", c.position)
			else:
				ok = bp.add_material(kind)
				if ok:
					AudioManager.play("pickup", c.position)
			if ok:
				ai.clear_carry()
			else:
				ai.drop_carry()
			phase = "decide"
		elif unreachable:
			return give_up_unreachable(bp, "blueprint")
		return false

	func _hammer(delta: float) -> bool:
		var tk: int = ensure_tool(&"hammer", delta)
		if tk == 0:
			return false
		if tk < 0:
			return abort(bp)
		if not _hammer_claimed:
			if not bp.try_claim(c):
				return give_up("busy", "Someone else is working on that blueprint.", bp)
			_hammer_claimed = true
		if not bp.is_supplied():
			phase = "decide"
			return false
		if _spot == Vector2.INF:
			_spot = bp.hammer_spot_world().round()
			new_target()
			_arrived = false
		if not _arrived:
			if walk(_spot, delta):
				_arrived = true
				face(bp.global_position)
				_timer = interval(&"hammer")
			elif unreachable:
				return give_up_unreachable(bp, "blueprint")
			return false
		face(bp.global_position)
		if swing(delta, &"hammer"):
			var r: Dictionary = WorkActions.hammer(c.get_tree(), bp)
			c.work_bob()
			if r["finished"]:
				_done()
				return true
		return false

	func _done() -> void:
		if task.get("type", &"") == &"build":
			task["blueprints"].erase(bp)
			task["done"] = int(task.get("done", 0)) + 1

	func release() -> void:
		_drop_reservation()
		if _hammer_claimed and bp != null and is_instance_valid(bp):
			bp.release_claim(c)
		_hammer_claimed = false
		super.release()

# --- Deliver what is already in his hands (after an interruption) --------------------------------------------------------------

class CarryJob extends WorkJob:
	var inner: WorkJob = null

	func claim(colonist) -> bool:
		claimed_by = colonist
		var kind: StringName = ai.carrying.get("kind", &"")
		if kind == &"plank":
			# a blueprint that needs it, else Storage
			for b in Logistics.blueprints(c.get_tree()):
				if b.planks_needed() > 0 and not ai.is_skipped(b):
					var bj: BuildJob = BuildJob.new()
					bj.setup(c, task, role)
					bj.init_blueprint(b)
					if bj.claim_carried(colonist):
						inner = bj
						return true
			var dest: Dictionary = Logistics.plank_destination(c.get_tree(), c.position)
			if not dest.is_empty():
				var hj: HaulPlankJob = HaulPlankJob.new()
				hj.setup(c, task, role)
				hj.pile = null
				hj.dest = dest
				hj.phase = "to_dest"
				inner = hj
				hj.claimed_by = colonist
				return true
		elif kind != &"":
			var idest: Dictionary = Logistics.item_destination(c.get_tree(), kind, c.position)
			if not idest.is_empty():
				var ij: HaulItemJob = HaulItemJob.new()
				ij.setup(c, task, role)
				ij.dest = idest
				ij._kind = kind
				ij.phase = "to_door"
				ij.claimed_by = colonist
				inner = ij
				return true
		# nowhere to put it: set it down here
		ai.drop_carry()
		return false

	func describe() -> String:
		return inner.describe() if inner != null else "Carrying"

	func execute(colonist, delta: float) -> bool:
		return inner.execute(colonist, delta) if inner != null else true

	func release() -> void:
		if inner != null:
			inner.release()
		super.release()

# --- Choosing a job ---------------------------------------------------------------------------------------------------------------

# The next job for this colonist, claimed and ready: what is in his hands, then the tasks, then the roles. null = nothing to do.
static func pick(colonist) -> JobBoardScript.Job:
	var ai: Node = colonist.order_ai
	var orders = colonist.orders
	if not ai.carrying.is_empty():
		var cj: CarryJob = CarryJob.new()
		cj.setup(colonist, {}, &"")
		if cj.claim(colonist):
			return cj
	for task in orders.tasks.duplicate():
		var job: JobBoardScript.Job = _task_job(colonist, task)
		if job != null:
			return job
	for role in orders.roles:
		var rj: JobBoardScript.Job = _role_job(colonist, role)
		if rj != null:
			return rj
	return null

static func _live(list: Array, ai: Node) -> Array:
	return list.filter(func(n) -> bool: return is_instance_valid(n) and not ai.is_skipped(n))

# Is a task's list finished (the colonist reports and the task goes)?
static func _finish_task(colonist, task: Dictionary, text: String) -> void:
	colonist.orders.tasks.erase(task)
	colonist.order_ai.report(text)

static func _task_job(colonist, task: Dictionary) -> JobBoardScript.Job:
	var ai: Node = colonist.order_ai
	var tree: SceneTree = colonist.get_tree()
	match task["type"]:
		&"chop":
			# trees that are gone, or fully dealt with (down, trimmed and their log delivered), leave the list
			task["trees"] = task["trees"].filter(func(t) -> bool: return is_instance_valid(t) and not (t.is_delimbed() and t.logs_ready == 0 and t.log_claimed_by == null))
			if task["trees"].is_empty():
				_finish_task(colonist, task, "Done chopping.")
				return null
			var order: Array = _live(task["trees"], ai)
			order.sort_custom(func(a: Node2D, b: Node2D) -> bool: return colonist.position.distance_squared_to(a.position) < colonist.position.distance_squared_to(b.position))
			for t in order:
				var job: ChopJob = ChopJob.new()
				job.setup(colonist, task, &"")
				job.init_tree(t, true)
				if job.claim(colonist):
					return job
		&"saw":
			var pit = task.get("saw")
			if pit == null or not is_instance_valid(pit):
				_finish_task(colonist, task, "Done sawing.")
				return null
			# the planks it made first, then the next log
			var stack: Node2D = _pile_near(pit, tree, colonist)
			if stack != null:
				var hj: HaulPlankJob = HaulPlankJob.new()
				hj.setup(colonist, task, &"")
				hj.init_pile(stack)
				if hj.claim(colonist):
					return hj
			if not ai.is_skipped(pit):
				var sj: SawJob = SawJob.new()
				sj.setup(colonist, task, &"")
				sj.init_pit(pit)
				if sj.claim(colonist):
					return sj
			if pit.state == pit.State.EMPTY and Logistics.loose_logs(tree).is_empty() and not _storage_has_logs(tree) and stack == null:
				# (finished, or there were no logs at all: SawJob.claim has said so already)
				_finish_task(colonist, task, "Done sawing." if int(task.get("done", 0)) > 0 else "")
		&"haul":
			var zone: Rect2 = task["zone"]
			var hj2: JobBoardScript.Job = _haul_job(colonist, task, &"", zone)
			if hj2 != null:
				return hj2
			if _zone_has_work(tree, zone) == false:
				_finish_task(colonist, task, "Done hauling.")
		&"build":
			task["blueprints"] = task["blueprints"].filter(func(b) -> bool: return is_instance_valid(b) and b.state != b.State.BUILT)
			if task["blueprints"].is_empty():
				_finish_task(colonist, task, "Done building.")
				return null
			var order2: Array = _live(task["blueprints"], ai)
			order2.sort_custom(func(a: Node2D, b: Node2D) -> bool: return colonist.position.distance_squared_to(a.position) < colonist.position.distance_squared_to(b.position))
			for b in order2:
				var bj: BuildJob = BuildJob.new()
				bj.setup(colonist, task, &"")
				bj.init_blueprint(b)
				if bj.claim(colonist):
					return bj
	return null

static func _storage_has_logs(tree: SceneTree) -> bool:
	for s in tree.get_nodes_in_group("storages"):
		if s.logs_stored > 0:
			return true
	return false

# A pile of planks lying by the pit saw (what it made), when Storage has room for them.
static func _pile_near(pit: Node2D, tree: SceneTree, colonist) -> Node2D:
	var ai: Node = colonist.order_ai
	if Logistics.plank_destination(tree, colonist.position).is_empty():
		return null
	var piles: Array = Logistics.free_piles(tree).filter(func(p) -> bool: return p.global_position.distance_to(pit.global_position) <= STACK_RADIUS_PX and not ai.is_skipped(p))
	return Logistics.nearest(piles, colonist.position)

static func _zone_has_work(tree: SceneTree, zone: Rect2) -> bool:
	for t in Logistics.loose_logs(tree):
		if zone.has_point(t.log_node().global_position):
			return true
	for p in Logistics.free_piles(tree):
		if zone.has_point(p.global_position):
			return true
	for i in Logistics.crate_items(tree):
		if zone.has_point(i.global_position) and i.get_meta(&"claimed_by", null) == null:
			return true
	return false

# The nearest loose log / plank pile / crate item (inside `zone` when given) that has somewhere to go, as a job.
static func _haul_job(colonist, task: Dictionary, role: StringName, zone: Rect2 = Rect2()) -> JobBoardScript.Job:
	var ai: Node = colonist.order_ai
	var tree: SceneTree = colonist.get_tree()
	var zoned: bool = zone.size != Vector2.ZERO
	var candidates: Array = []
	for t in Logistics.loose_logs(tree):
		if not ai.is_skipped(t) and (not zoned or zone.has_point(t.log_node().global_position)):
			candidates.append({"node": t, "kind": "log", "pos": t.log_node().global_position})
	for p in Logistics.free_piles(tree):
		if not ai.is_skipped(p) and (not zoned or zone.has_point(p.global_position)):
			candidates.append({"node": p, "kind": "plank", "pos": p.global_position})
	for i in Logistics.crate_items(tree):
		if not ai.is_skipped(i) and i.get_meta(&"claimed_by", null) == null and (not zoned or zone.has_point(i.global_position)):
			candidates.append({"node": i, "kind": "item", "pos": i.global_position})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return colonist.position.distance_squared_to(a["pos"]) < colonist.position.distance_squared_to(b["pos"]))
	for cand in candidates:
		var job: WorkJob = null
		match cand["kind"]:
			"log":
				var cj: ChopJob = ChopJob.new()
				cj.setup(colonist, task, role)
				cj.init_tree(cand["node"], true, true)
				job = cj
			"plank":
				var pj: HaulPlankJob = HaulPlankJob.new()
				pj.setup(colonist, task, role)
				pj.init_pile(cand["node"])
				job = pj
			"item":
				var ij: HaulItemJob = HaulItemJob.new()
				ij.setup(colonist, task, role)
				ij.init_item(cand["node"])
				job = ij
		if cand["kind"] == "log" and Logistics.log_destination(tree, colonist.position, true).is_empty():
			ai.fail("nowhere", "Nowhere to store it.")
			ai.skip(cand["node"], SKIP_SECONDS)
			continue
		if job.claim(colonist):
			return job
	return null

static func _role_job(colonist, role: StringName) -> JobBoardScript.Job:
	var ai: Node = colonist.order_ai
	var tree: SceneTree = colonist.get_tree()
	match role:
		&"lumberjack":
			var near: Array = _live(tree.get_nodes_in_group("trees").filter(func(t) -> bool: return (t.is_standing() or t.is_felled()) and t.claimed_by == null and t.global_position.distance_to(colonist.position) <= ROLE_RADIUS_PX), ai)
			near.sort_custom(func(a: Node2D, b: Node2D) -> bool: return colonist.position.distance_squared_to(a.position) < colonist.position.distance_squared_to(b.position))
			for t in near:
				var job: ChopJob = ChopJob.new()
				job.setup(colonist, {}, role)
				job.init_tree(t, true)
				if job.claim(colonist):
					return job
		&"sawyer":
			var pits: Array = _live(tree.get_nodes_in_group("pit_saws").filter(func(p) -> bool: return p.is_built()), ai)
			pits.sort_custom(func(a: Node2D, b: Node2D) -> bool: return colonist.position.distance_squared_to(a.position) < colonist.position.distance_squared_to(b.position))
			for pit in pits:
				var stack: Node2D = _pile_near(pit, tree, colonist)
				if stack != null:
					var hj: HaulPlankJob = HaulPlankJob.new()
					hj.setup(colonist, {}, role)
					hj.init_pile(stack)
					if hj.claim(colonist):
						return hj
				var sj: SawJob = SawJob.new()
				sj.setup(colonist, {}, role)
				sj.init_pit(pit)
				if sj.claim(colonist):
					return sj
		&"hauler":
			return _haul_job(colonist, {}, role)
		&"builder":
			var bps: Array = _live(Logistics.blueprints(tree), ai)
			bps.sort_custom(func(a: Node2D, b: Node2D) -> bool: return colonist.position.distance_squared_to(a.position) < colonist.position.distance_squared_to(b.position))
			for b in bps:
				var bj: BuildJob = BuildJob.new()
				bj.setup(colonist, {}, role)
				bj.init_blueprint(b)
				if bj.claim(colonist):
					return bj
	return null

# Counts for the status line of a task: how many things are left.
static func task_left(task: Dictionary) -> int:
	match task["type"]:
		&"chop":
			return task["trees"].size()
		&"build":
			return task["blueprints"].size()
	return 0
