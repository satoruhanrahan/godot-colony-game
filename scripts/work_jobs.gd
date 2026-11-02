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
	var is_return: bool = false
	# The order AI checks once, when the job starts, that he holds no tool that is not the job's own (primary_tool), and sends it back first.
	var start_checked: bool = false
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

	# The tool this job works with when it starts (&"" for none): a tool he holds that is not this one goes back to the toolbox before the job begins.
	func primary_tool() -> StringName:
		return &""

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
		# the player's work animation runs for the whole action (stretched to its time) and the hit comes at its strike frame
		if not c.animator.work_cycle(kind, delta, interval(kind), c.carry_state()):
			return false
		ai.strikes += 1
		if WorkActions.tool_of(kind) != &"":
			ai.tools.touch()
		return true

	func interval(kind: StringName) -> float:
		return WorkActions.seconds(kind, player()) / maxf(0.1, c.rest.efficiency() * c.colony.friend_work_efficiency)

	# The tool this kind of work needs (ToolConfig.job_tools) fetched and in his hands: 1 = he holds it, 0 = on his way for it, -1 = it cannot be
	# had (said), -2 = another tool is in his hands and goes back first (the job ends quietly and is picked again).
	func ensure_tool(kind: StringName, delta: float) -> int:
		return ai.tools.ensure(self, WorkActions.tool_of(kind), delta)

	# The job ends as a failure on this target (the reason has been said).
	func abort(_node = null) -> bool:
		failed = true
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
				text = "Putting the %s away" % String(ai.tools.held).replace("_", " ") if ai.tools.holding() else "Going for a log"
			"deliver":
				text = "Hauling a log"
		return text + suffix()

	func suffix() -> String:
		if task.get("type", &"") == &"chop":
			var left: int = task["trees"].size()
			return " (%d marked left)" % left
		return ""

	# The kind of work of the phase: felling is "chop" (the axe, the chop animation's time, the chop sound), trimming "delimb".
	func _kind() -> StringName:
		return &"chop" if phase == "fell" else &"delimb"

	func primary_tool() -> StringName:
		return WorkActions.tool_of(_kind()) if phase == "fell" or phase == "delimb" else &""

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
				var tk: int = ensure_tool(_kind(), delta)
				if tk == 0:
					return false
				if tk == -2:
					return true
				if tk < 0:
					return abort(tree_node)
				if _spot == Vector2.INF:
					_spot = _spot_for(_kind())
					new_target()
					_arrived = false
				if not _arrived:
					if walk(_spot, delta):
						_arrived = true
						face(tree_node.global_position)
						_timer = interval(_kind())
					elif unreachable:
						return give_up_unreachable(tree_node, "tree")
					return false
				face(tree_node.global_position)
				if swing(delta, _kind()):
					var r: Dictionary = WorkActions.chop(c.get_tree(), tree_node, _kind(), player().hits_per_chop)
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
			load("res://scripts/designation_mode.gd").clear_for(c.get_tree(), tree_node)
			task["trees"].erase(tree_node)
			task["done"] = int(task.get("done", 0)) + 1

	func _take(delta: float) -> bool:
		if tree_node.logs_ready <= 0 and not _log_claimed:
			return true
		dest = Logistics.log_destination(c.get_tree(), c.position, prefer_storage)
		if dest.is_empty() and not _log_claimed:
			return give_up("nowhere", "Nowhere to store it.", tree_node)
		# A log needs both hands: the tool goes back in the toolbox first (he fetches it again for the next tree).
		if not _attached and ai.free_hands(self, delta) != 1:
			return false
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
			phase = "wait"
			new_target()
			return true
		if pit.state != pit.State.EMPTY:
			# someone else is using it (the player, or two others at work): he does something else and says so once
			claimed_by = null
			if pit.state == pit.State.SAWING or pit.state == pit.State.WAITING_FOR_WORKERS:
				ai.fail("pitbusy", "The pit saw is in use.")
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
			"wait":
				return "Waiting for you at the saw pit"
		return "Sawing"

	func execute(colonist, delta: float) -> bool:
		if pit == null or not is_instance_valid(pit):
			return true
		match phase:
			"fetch":
				if ai.free_hands(self, delta) != 1:
					return false
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
						phase = "wait"
						new_target()
					else:
						release()
						return give_up("pitbusy", "The pit saw is in use.", pit)
				elif unreachable:
					release()
					return give_up_unreachable(pit, "pit saw")
				return false
			"wait":
				# The pit saw is a two-person tool: he does not saw by himself. He stands at his end of it and waits until the player presses E at it (then the pit
				# takes him as the other operator, and he is let go again when it stops).
				if pit.state != pit.State.LOADED:
					return true
				if walk(pit.colonist_spot_world().round(), delta):
					ai.working = false
					ai.fail("sawwait", "Waiting for you at the saw pit")
					c.flip_h = pit.global_position.x < c.position.x
					ai._stand()
				elif unreachable:
					return give_up_unreachable(pit, "pit saw")
				return false
		return true

	func release() -> void:
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
			ai.skip(pile, SKIP_SECONDS)
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
				if ai.free_hands(self, delta) != 1:
					return false
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
		if item == null or not is_instance_valid(item) or (item.get_meta(&"claimed_by") if item.has_meta(&"claimed_by") else null) != null:
			return false
		dest = Logistics.item_destination(c.get_tree(), item.kind, c.position)
		if dest.is_empty():
			ai.fail("nowhere", "Nowhere to store it.")
			ai.skip(item, SKIP_SECONDS)
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
				if ai.free_hands(self, delta) != 1:
					return false
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
					c.set_body_visible(&"job", false)
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
			c.set_body_visible(&"job", true)
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
	# A blueprint in a room (a bed, a crate, a table planned inside a House or a Storage): the room, and the place on its floor beside the
	# blueprint where he stands to hand things over and hammer (reachable from the door, found when the job is taken).
	var _room: Node2D = null
	var _room_spot: Vector2 = Vector2.INF

	func init_blueprint(b: Node2D) -> BuildJob:
		bp = b
		target = b
		return self

	# For a blueprint in a room: its standing place. False (said once, the blueprint skipped for a while) when there is none he can reach.
	func _find_room_spot() -> bool:
		_room = Logistics.room_of(c.get_tree(), bp.global_position)
		if _room == null:
			return true
		_room_spot = _room.standing_spot(Logistics.cover_rect(c.get_tree(), bp), bp.hammer_spot_world().round())
		if _room_spot == Vector2.INF:
			ai.fail("unreachable_blueprint", "Cannot reach the blueprint.")
			ai.skip(bp, SKIP_SECONDS)
			_room = null
			return false
		return true

	func location():
		return _room.building if _room != null and is_instance_valid(_room) else null

	func claim(colonist) -> bool:
		if bp == null or not is_instance_valid(bp) or bp.is_finished():
			return false
		if not _find_room_spot():
			return false
		claimed_by = colonist
		phase = "decide"
		new_target()
		return true

	# Already holding something the blueprint wants other than a plank (a saw blade): deliver it.
	func claim_carried_item(colonist) -> bool:
		var kind: StringName = ai.carrying.get("kind", &"")
		if bp == null or not is_instance_valid(bp) or bp.material_missing(kind) <= 0:
			return false
		if not _find_room_spot():
			return false
		_need_kind = kind
		claimed_by = colonist
		phase = "deliver"
		new_target()
		return true

	# Already holding a plank (after an interruption): deliver it.
	func claim_carried(colonist) -> bool:
		if bp == null or not is_instance_valid(bp) or bp.planks_needed() <= 0:
			return false
		if not _find_room_spot():
			return false
		bp.planks_reserved += 1
		_plank_reserved = true
		claimed_by = colonist
		phase = "deliver"
		new_target()
		return true

	# The shovel while the blueprint still has to be dug, else the hammer.
	func primary_tool() -> StringName:
		if bp == null or not is_instance_valid(bp):
			return &""
		return WorkActions.tool_of(&"dig" if bp.needs_digging() else &"hammer")

	# "Building a wooden bed in the House": a blueprint in a room says where it is.
	func describe() -> String:
		var name_text: String = bp.display_name() if bp != null and is_instance_valid(bp) else "a blueprint"
		var where: String = ""
		if _room != null and is_instance_valid(_room) and is_instance_valid(_room.building):
			name_text = "a " + name_text.to_lower()
			where = " in the %s" % Logistics.host_name(_room.building)
		match phase:
			"dig":
				return "Digging %s%s%s" % [name_text, where, suffix()]
			"hammer":
				return "Hammering %s%s%s" % [name_text, where, suffix()]
			"fetch", "take":
				return "Fetching %s for %s%s%s" % [String(_need_kind).replace("_", " "), name_text, where, suffix()]
			"deliver":
				return "Bringing %s to %s%s%s" % [String(_need_kind).replace("_", " ") if _need_kind != &"" else "a plank", name_text, where, suffix()]
		return "Building %s%s%s" % [name_text, where, suffix()]

	func suffix() -> String:
		if task.get("type", &"") == &"build":
			return " (%d left)" % task["blueprints"].size()
		return ""

	func execute(colonist, delta: float) -> bool:
		if bp == null or not is_instance_valid(bp) or bp.is_finished():
			_done()
			return true
		match phase:
			"decide":
				return _decide()
			"dig":
				return _dig(delta)
			"fetch":
				return _fetch(delta)
			"deliver":
				return _deliver(delta)
			"hammer":
				return _hammer(delta)
		return true

	# The digging of a blueprint that is dug (the pit saw): the shovel, at the digging spot, until the hole is done; then the shovel goes back.
	func _dig(delta: float) -> bool:
		if not bp.needs_digging():
			if ai.tools.holding() and ai.tools.held == WorkActions.tool_of(&"dig") and not ai.tools.put_away(self, delta):
				return false
			phase = "decide"
			_spot = Vector2.INF
			new_target()
			return false
		var tk: int = ensure_tool(&"dig", delta)
		if tk == 0:
			return false
		if tk == -2:
			return true
		if tk < 0:
			return abort(bp)
		if not _hammer_claimed:
			if not bp.try_claim(c):
				return give_up("busy", "Someone else is working on that blueprint.", bp)
			_hammer_claimed = true
		if _spot == Vector2.INF:
			_spot = bp.dig_spot_world().round()
			new_target()
			_arrived = false
		if not _arrived:
			if walk(_spot, delta):
				_arrived = true
				face(bp.global_position)
				_timer = interval(&"dig")
			elif unreachable:
				return give_up_unreachable(bp, "blueprint")
			return false
		face(bp.global_position)
		if swing(delta, &"dig"):
			WorkActions.dig(c.get_tree(), bp)
		return false

	func _decide() -> bool:
		if bp.needs_digging():
			phase = "dig"
			_spot = Vector2.INF
			new_target()
			return false
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
		# One thing in the hands at a time: a tool (the hammer, the shovel) goes back to the toolbox before a plank or the blade is taken.
		if ai.free_hands(self, delta) != 1:
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
					node.remove_from_group("saw_blades")
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

	# Is what he carries the last thing the blueprint wants (it can be hammered once it is delivered)?
	func _last_piece() -> bool:
		var kind: StringName = ai.carrying.get("kind", &"")
		if bp.planks_ready + (1 if kind == &"plank" else 0) < bp.plank_cost:
			return false
		for k in bp.materials_cost:
			if int(bp.materials_ready.get(k, 0)) + (1 if StringName(k) == kind else 0) < int(bp.materials_cost[k]):
				return false
		return true

	# Where he stands to hand things to the blueprint: beside it on the floor of its room, or in front of it outdoors.
	func _hand_over_spot() -> Vector2:
		if _room != null and is_instance_valid(_room):
			return _room_spot
		return (bp.global_position + Logistics.BUILDING_STOP_OFFSET).round()

	func _deliver(delta: float) -> bool:
		# (His hands hold the piece, so no tool: the hammer is fetched once everything is delivered and the blueprint can be hammered.)
		if walk(_hand_over_spot(), delta):
			var kind: StringName = ai.carrying.get("kind", &"")
			var ok: bool = false
			if kind == &"plank":
				if _plank_reserved:
					bp.planks_reserved = maxi(0, bp.planks_reserved - 1)
					_plank_reserved = false
				ok = bp.deliver_plank()
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
		if tk == -2:
			return true
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
			_spot = _hand_over_spot() if _room != null else bp.hammer_spot_world().round()
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
			if r["finished"]:
				_done()
				return true
		return false

	func _done() -> void:
		if task.get("type", &"") == &"build":
			load("res://scripts/designation_mode.gd").clear_for(c.get_tree(), bp)
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
		elif kind == &"saw_blade":
			# a blueprint that wants it (the pit saw), else it is set down here
			for b in Logistics.blueprints(c.get_tree()):
				if b.material_missing(kind) > 0 and not ai.is_skipped(b):
					var sj: BuildJob = BuildJob.new()
					sj.setup(c, task, role)
					sj.init_blueprint(b)
					if sj.claim_carried_item(colonist):
						inner = sj
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
		# nowhere to put it: set it down here (when he is on his way to bed: beside his house)
		if ai.sleepy:
			ai.set_down_near_house()
		else:
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

# --- Put the tool back ----------------------------------------------------------------------------------------------------------

class ReturnToolJob extends WorkJob:
	func claim(colonist) -> bool:
		claimed_by = colonist
		is_return = true
		phase = "walk"
		new_target()
		return true

	func describe() -> String:
		return "Putting the %s back" % String(ai.tools.held).replace("_", " ")

	func execute(colonist, delta: float) -> bool:
		if not ai.tools.holding():
			return true
		return ai.tools.put_away(self, delta)

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
	# nothing left to saw: "Done sawing." once after a spell of it
	if ai.sawn > 0:
		ai.sawn = 0
		ai.report("Done sawing.")
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
			# (a tree needs the axe unless it is only a log now)
			if not order.is_empty() and order.any(func(t) -> bool: return t.is_standing() or t.is_felled()) and not ai.tools.can_start(WorkActions.tool_of(&"chop")):
				return null
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
				var sawed: bool = int(task.get("done", 0)) > 0 or ai.sawn > 0
				ai.sawn = 0
				_finish_task(colonist, task, "Done sawing." if sawed else "")
		&"haul":
			var zone: Rect2 = task["zone"]
			var hj2: JobBoardScript.Job = _haul_job(colonist, task, &"", zone)
			if hj2 != null:
				return hj2
			if _zone_has_work(tree, zone) == false:
				_finish_task(colonist, task, "Done hauling.")
		&"build":
			task["blueprints"] = task["blueprints"].filter(func(b) -> bool: return is_instance_valid(b) and not b.is_finished())
			if task["blueprints"].is_empty():
				_finish_task(colonist, task, "Done building.")
				return null
			var order2: Array = _live(task["blueprints"], ai)
			order2.sort_custom(func(a: Node2D, b: Node2D) -> bool: return Logistics.travel_cost(tree, colonist.position, a.global_position) < Logistics.travel_cost(tree, colonist.position, b.global_position))
			if not order2.is_empty() and not ai.tools.can_start(WorkActions.tool_of(&"build")):
				return null
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
	# (The planks the pit saw makes lie in a pile beside it, already stacked. Only a colonist who is also a Hauler carries them to Storage.)
	if not colonist.orders.has_role(&"hauler") or Logistics.plank_destination(tree, colonist.position).is_empty():
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
		if zone.has_point(i.global_position) and (i.get_meta(&"claimed_by") if i.has_meta(&"claimed_by") else null) == null:
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
		if not ai.is_skipped(i) and (i.get_meta(&"claimed_by") if i.has_meta(&"claimed_by") else null) == null and (not zoned or zone.has_point(i.global_position)):
			candidates.append({"node": i, "kind": "item", "pos": i.global_position})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return Logistics.travel_cost(tree, colonist.position, a["pos"]) < Logistics.travel_cost(tree, colonist.position, b["pos"]))
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
			if not near.is_empty() and not ai.tools.can_start(WorkActions.tool_of(&"chop")):
				return null
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
			# felled trees are not logs yet: they must be trimmed first (the Lumberjack's work)
			if not pits.is_empty() and Logistics.loose_logs(tree).is_empty() and not _storage_has_logs(tree) and not tree.get_nodes_in_group("trees").filter(func(t) -> bool: return t.is_felled()).is_empty():
				ai.fail("untrimmed", "The trees need delimbing first.")
		&"hauler":
			return _haul_job(colonist, {}, role)
		&"farmer":
			return load("res://scripts/farm_jobs.gd").pick(colonist)
		&"cook":
			return load("res://scripts/cook_jobs.gd").pick(colonist)
		&"builder":
			var bps: Array = _live(Logistics.blueprints(tree), ai)
			bps.sort_custom(func(a: Node2D, b: Node2D) -> bool: return Logistics.travel_cost(tree, colonist.position, a.global_position) < Logistics.travel_cost(tree, colonist.position, b.global_position))
			if not bps.is_empty() and not ai.tools.can_start(WorkActions.tool_of(&"build")):
				return null
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

# --- Why not: for the job log (colonist_order_ai.debug_job_log) ----------------------------------------------------------------------

static func explain(colonist) -> Array:
	var out: Array = []
	var ai: Node = colonist.order_ai
	var tree: SceneTree = colonist.get_tree()
	if colonist.orders.has_work() and not ai.work_allowed():
		out.append("work paused: stance is %s" % colonist.orders.name_now())
	var pits: Array = tree.get_nodes_in_group("pit_saws").filter(func(p) -> bool: return p.is_built())
	var loose: int = Logistics.loose_logs(tree).size()
	var in_storage: int = 0
	for st in tree.get_nodes_in_group("storages"):
		in_storage += st.logs_stored
	var kinds_needed: Array = []
	for task in colonist.orders.tasks:
		match task["type"]:
			&"chop":
				var claimable: int = task["trees"].filter(func(t) -> bool: return is_instance_valid(t) and t.claimed_by == null and not ai.is_skipped(t)).size()
				out.append("task chop: %d marked, %d free to take" % [task["trees"].size(), claimable])
				kinds_needed.append(&"chop")
			&"saw":
				var pit = task.get("saw")
				out.append("task saw: pit %s, state %s, %d loose logs, %d in Storage" % ["gone" if pit == null or not is_instance_valid(pit) else "ok", str(pit.State.keys()[pit.state]) if pit != null and is_instance_valid(pit) else "-", loose, in_storage])
			&"haul":
				out.append("task haul: zone has work %s" % _zone_has_work(tree, task["zone"]))
			&"build":
				out.append("task build: %d blueprints, %d not skipped" % [task["blueprints"].size(), _live(task["blueprints"], ai).size()])
				kinds_needed.append(&"build")
	for role in colonist.orders.roles:
		match role:
			&"lumberjack":
				var n: int = tree.get_nodes_in_group("trees").filter(func(t) -> bool: return (t.is_standing() or t.is_felled()) and t.claimed_by == null and t.global_position.distance_to(colonist.position) <= ROLE_RADIUS_PX).size()
				out.append("lumberjack: %d trees within %d px" % [n, int(ROLE_RADIUS_PX)])
				kinds_needed.append(&"chop")
			&"sawyer":
				var states: Array = pits.map(func(p) -> String: return str(p.State.keys()[p.state]))
				out.append("sawyer: %d built pit saws %s, %d loose logs, %d logs in Storage, %d felled trees (not trimmed)" % [pits.size(), str(states), loose, in_storage, tree.get_nodes_in_group("trees").filter(func(t) -> bool: return t.is_felled()).size()])
			&"hauler":
				out.append("hauler: %d loose logs, %d free planks, %d crate items; log place %s, plank place %s" % [loose, Logistics.free_piles(tree).size(), Logistics.crate_items(tree).size(), not Logistics.log_destination(tree, colonist.position, true).is_empty(), not Logistics.plank_destination(tree, colonist.position).is_empty()])
			&"cook":
				out.append("cook: %s; target %d; pending loaves %d" % [load("res://scripts/cook_jobs.gd").summary(tree, colonist), colonist.colony.bread_target, load("res://scripts/cook_jobs.gd").pending(load("res://scripts/cook_jobs.gd").tally(tree), ai)])
			&"farmer":
				var fm: Node2D = load("res://scripts/plot_manager.gd").get_for(tree)
				out.append("farmer: %d zone cells (%s); seeds in stock %d, sheaves in stock %d (reserve %d)" % [fm.farm_cells.size(), fm.farm_summary(), load("res://scripts/farm_jobs.gd").seeds_in_stock(tree, ai), load("res://scripts/farm_jobs.gd").sheaves_in_stock(tree), colonist.colony.farm_seed_reserve])
			&"builder":
				var all_bps: Array = Logistics.blueprints(tree)
				out.append("builder: %d blueprints (%d in rooms of buildings)" % [all_bps.size(), all_bps.filter(func(b) -> bool: return Logistics.room_of(tree, b.global_position) != null).size()])
				kinds_needed.append(&"build")
	for k in kinds_needed:
		var tool: StringName = WorkActions.tool_of(k)
		if tool != &"" and colonist.colony.friend_needs_tools and ai.tools.held != tool:
			out.append("%s needs the %s: %s" % [k, tool, ai.tools.why_none(tool) if ai.tools.source_for(tool)["type"] == "none" else "available (%s)" % ai.tools.source_for(tool)["type"]])
	return out
