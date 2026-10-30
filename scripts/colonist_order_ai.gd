extends Node

# WHAT A COLONIST DOES WHILE HE HAS A STANCE (FOLLOW / ASSIST / STAY): the Colonist's State.ORDERED calls tick() every frame.
# (Needs - eating, sleeping - and the toolbox carry are decided by the Colonist before this runs; see colonist_orders.gd for the
# precedence. After any of them he comes back here through Colonist._stand_still().)
#
#  FOLLOW: keeps within follow_distance_px of the player: once he is further than that he walks after him (catch-up at most
#          follow_catchup_multiplier of his own speed, and never faster than the player walks when the player is slowed), and stops
#          at follow_stop_px plus a little random slack, standing a few pixels differently every time. He never picks a spot in
#          the strip in front of a door (he waits behind). When the player goes into a building he walks to its door and is shown
#          inside near the door (BuildingInterior.show_colonist); when the player leaves he comes out too. A room that already
#          holds visitor_limit people makes him wait at the door.
#  ASSIST: FOLLOW, plus: while the player has worked in the last assist_idle_seconds he does the matching work close by (chop
#          another tree, hammer the same blueprint, pull another patch of grass, till / water / harvest other plots) through
#          the shared WorkActions, at friend_work_efficiency of his speed. Sowing is not copied (he has no seeds): he waters or
#          tills instead. Every claim he takes is released when the job ends, the player stops, he is interrupted or he dies.
#  STAY:   goes to Orders.post, idles there with a small fidget, and walks back after any interruption.
#
# He has no work animations of his own yet (colonist_frames has idle / walk / asleep only): a strike is his idle picture with a
# small bob, plus the real sound and particles of the hit. Drawing colonist_chop / _hammer / _pull / _till is the way to improve it.

const WorkActions = preload("res://scripts/work_actions.gd")
const LogDragger = preload("res://scripts/log_dragger.gd")
const PlankPiles = preload("res://scripts/plank_piles.gd")
const Items = preload("res://scripts/items.gd")

enum Phase { MOVE, WAIT, FIDGET }

var c: Node2D = null
var phase: Phase = Phase.WAIT
var working: bool = false
var job: Dictionary = {}
var board_job = null
var visiting: Node2D = null
var status: String = ""

# The work job he is doing (roles and tasks, work_jobs.gd), what he carries ({"kind", "amount"} or {}), the log he drags, and the book-keeping
# of failures: targets skipped for a while, the last failure and the last "Done ..." report (both shown on the hover line).
var work_job = null
var carrying: Dictionary = {}
var carry_sprite: Sprite2D = null
var dragger = null
var drag_tree = null
var stuck_events: int = 0
var fail_text: String = ""
var fail_until: float = 0.0
var last_report: String = ""
var report_until: float = 0.0
# How many times each failure was actually said on the HUD (a failure is said once, then not again for a minute).
var said_count: Dictionary = {}
var _skips: Dictionary = {}
var _next_pick: float = 0.0
var _slack: float = 0.0
var _replan: float = 0.0
var _timer: float = 0.0
var _fidget_target: Vector2 = Vector2.INF
var _tool: StringName = &""
var _tool_box: Node2D = null
var _said: Dictionary = {}

func setup(colonist: Node2D) -> void:
	c = colonist
	name = "OrderAI"
	dragger = LogDragger.new(colonist, colonist)

func begin() -> void:
	phase = Phase.MOVE if c.orders.stance == c.Orders.Stance.STAY else Phase.WAIT
	_replan = 0.0
	_timer = 0.0
	c._reset_stuck()

func has_claims() -> bool:
	return not job.is_empty() or visiting != null or _tool != &"" or board_job != null or work_job != null or dragger.is_dragging()

# Gives back everything: claims, a borrowed tool, the room he is visiting, the work job; with `drop`, what he carries is set down where he stands
# (the nearest free ground). Safe to call at any time.
func release_all(drop: bool = false) -> void:
	_end_job()
	if board_job != null:
		board_job.release()
		board_job = null
	if work_job != null:
		work_job.release()
		work_job = null
	_return_tool()
	_leave_visit()
	working = false
	if drop:
		drop_carry()

# He has just been taken out of his order (hunger, sleep, the carry, a task): the job lets go of its claims (a log it dragged is laid down
# where it is); what he carries in his hands stays with him through a meal and is delivered when he is back, unless he is about to starve or
# to sleep, when it is set down where he stands.
func on_interrupted() -> void:
	var clock: Node = c.get_tree().get_first_node_in_group("game_clock")
	var drop: bool = false
	match c.state:
		c.State.TO_BED, c.State.ON_BED, c.State.SLEEPING_OUTSIDE, c.State.MOVING_IN, c.State.RETURNING, c.State.INSIDE, c.State.ENTERING, c.State.HELPING_CARRY, c.State.TO_WORK, c.State.AT_WORK:
			drop = true
		_:
			drop = clock != null and c.hunger.value < clock.hunger_warn_below
	release_all(drop)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

# --- Every frame ----------------------------------------------------------------------------------------------------------

func tick(delta: float) -> void:
	working = false
	var player: Node2D = get_tree().get_first_node_in_group("player")
	if player == null or player.dead:
		status = "Waiting"
		c.play("idle")
		return
	# (3) designated tasks and roles (work_jobs.gd, through the job board). Following and assisting pause them (the player has him with him);
	# with Free time or Stay he does them first, and goes back to his stance when there is nothing left.
	if not work_allowed():
		if work_job != null or not carrying.is_empty() or dragger.is_dragging():
			release_all(true)
	else:
		if work_job == null and _now() >= _next_pick and c.colony != null and c.colony.job_board != null:
			_next_pick = _now() + 0.6
			work_job = c.colony.job_board.pick_for(c)
		if work_job != null:
			status = work_job.describe()
			if work_job.execute(c, delta) or work_job.failed:
				work_job.release()
				work_job = null
				_next_pick = 0.0
				waypoints_reset()
				_return_tool()
			return
		if c.orders.stance == c.Orders.Stance.FREE:
			# nothing to do: free time again (try_take_work asks again soon)
			working = false
			c._stand_still()
			return
	# (4) the stance
	match c.orders.stance:
		c.Orders.Stance.STAY:
			_stay(delta)
		c.Orders.Stance.FOLLOW:
			_follow(delta, player)
		c.Orders.Stance.ASSIST:
			if not _assist(delta, player):
				_follow(delta, player)

# --- Work: carrying, skipping, saying ------------------------------------------------------------------------------------------

# Tasks and roles run with Free time and Stay; Follow me and Assist me pause them.
func work_allowed() -> bool:
	return c.orders.stance == c.Orders.Stance.FREE or c.orders.stance == c.Orders.Stance.STAY

# From the colonist's idle states: is there work for him now (a job is picked and claimed)? Asked at most every 0.6 s.
func try_take_work() -> bool:
	if not c.orders.has_work() or not work_allowed() or c.colony == null or c.colony.job_board == null or _now() < _next_pick:
		return false
	_next_pick = _now() + 0.6
	var j = c.colony.job_board.pick_for(c)
	if j == null:
		return false
	work_job = j
	return true

func skip(node, seconds: float) -> void:
	if node != null and is_instance_valid(node):
		_skips[node.get_instance_id()] = _now() + seconds

func is_skipped(node) -> bool:
	if node == null or not is_instance_valid(node):
		return true
	var id: int = node.get_instance_id()
	if _skips.has(id):
		if _now() < _skips[id]:
			return true
		_skips.erase(id)
	return false

# He cannot do his job: the reason is on his hover line for a while and said once on the HUD (the same reason is not repeated for a minute).
func fail(key: String, text: String) -> void:
	fail_text = text
	fail_until = _now() + 10.0
	_say_once(text, key, 60.0)

# A task list is finished: "Done chopping." on the HUD and on his hover line.
func report(text: String) -> void:
	if text == "":
		return
	last_report = text
	report_until = _now() + 10.0
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say("%s: %s" % [c.display_name, text])

func set_carry(kind: StringName, amount: int = 1) -> void:
	carrying = {"kind": kind, "amount": amount}
	if carry_sprite == null:
		carry_sprite = Sprite2D.new()
		carry_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		carry_sprite.position = Vector2(0, -22)
		carry_sprite.z_index = 2
		c.add_child(carry_sprite)
	var tex: Texture2D = null
	if kind == &"plank":
		tex = load("res://sprites/one_plank.png")
	elif Items.is_item(kind):
		tex = Items.texture(kind)
	carry_sprite.texture = tex
	carry_sprite.visible = tex != null

func clear_carry() -> void:
	carrying = {}
	if carry_sprite != null:
		carry_sprite.visible = false

# Sets what he carries down where he stands (the nearest free ground).
func drop_carry() -> void:
	if carrying.is_empty():
		return
	var kind: StringName = carrying.get("kind", &"")
	var amount: int = int(carrying.get("amount", 0))
	var tree: SceneTree = get_tree()
	var parent: Node = c.get_parent()
	var spot: Vector2 = load("res://scripts/ground_placement.gd").find_free_ground_near(tree, c.position, Vector2(12, 10))
	if spot == Vector2.INF:
		spot = c.position.round()
	if kind == &"plank":
		PlankPiles.put_plank(tree, parent, spot, 20.0, Rect2(0, 0, 640, 640), spot)
	elif Items.is_item(kind):
		Items.spawn(kind, parent, spot, amount)
	clear_carry()

# --- Moving ---------------------------------------------------------------------------------------------------------------

func waypoints_reset() -> void:
	c.waypoints.clear()
	_replan = 0.0
	c._reset_stuck()

# One step along a path to `point`; true once he is there. `mult` is relative to his own (tired / wading) speed.
func go(point: Vector2, delta: float, mult: float = 1.0) -> bool:
	_replan -= delta
	if _replan <= 0.0 or c.waypoints.is_empty():
		_replan = 0.5
		c.waypoints = c._path_to(point)
		c._reset_stuck()
	if c.waypoints.is_empty():
		return true
	if c.animation != &"walk":
		c.play("walk")
	var arrived: bool = c._follow_path(delta, mult)
	if c._is_stuck(delta):
		# Stuck behind something: plan again, and a little to the side.
		stuck_events += 1
		c.waypoints = c._path_to(point + Vector2(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0)))
		c._reset_stuck()
	return arrived

func _stand() -> void:
	c.waypoints.clear()
	if c.animation != &"idle":
		c.play("idle")

func _near_door(p: Vector2) -> bool:
	var bm: Node = get_tree().get_first_node_in_group("build_mode")
	if bm == null:
		return false
	for door in bm.door_points():
		if bm.door_strip(door).grow(4.0).has_point(p):
			return true
	return false

# --- Follow ---------------------------------------------------------------------------------------------------------------

func _follow(delta: float, player: Node2D) -> void:
	if player.inside_building != null:
		_visit(delta, player)
		return
	if visiting != null:
		_leave_visit()
	var col: Node = c.colony
	var pp: Vector2 = player.global_position
	var d: float = c.position.distance_to(pp)
	status = "Following you"
	if phase != Phase.MOVE:
		if d > col.follow_distance_px:
			phase = Phase.MOVE
			_replan = 0.0
			c._reset_stuck()
		else:
			_stand()
			c.flip_h = pp.x < c.position.x
			return
	# moving
	if d <= col.follow_stop_px + _slack:
		phase = Phase.WAIT
		_slack = randf_range(-4.0, 8.0)
		_stand()
		return
	if _replan <= 0.0 or c.waypoints.is_empty():
		c.waypoints = c._path_to(_follow_target(pp))
		c._reset_stuck()
		_replan = 0.4
	else:
		_replan -= delta
	var base: float = maxf(1.0, c.speed * c.rest.speed_factor())
	var pspeed: float = maxf(1.0, player._current_speed())
	var mult: float = 1.0
	if d > col.follow_distance_px * 1.5:
		mult = col.follow_catchup_multiplier
	elif d < col.follow_distance_px:
		# close in: match the way he walks rather than dash up and stop
		mult = minf(1.0, pspeed * 1.1 / base)
	# slowed by tiredness: never faster than he walks
	if player.rest.speed_factor() < 1.0:
		mult = minf(mult, maxf(0.3, pspeed / base))
	if c.animation != &"walk":
		c.play("walk")
	c._follow_path(delta, mult)
	if c._is_stuck(delta):
		c.waypoints = c._path_to(_follow_target(pp, true))
		c._reset_stuck()

# A place near the player on his own side, outside every door strip and not on another colonist.
func _follow_target(pp: Vector2, jitter: bool = false) -> Vector2:
	var away: Vector2 = (c.position - pp).normalized()
	if away == Vector2.ZERO:
		away = Vector2.LEFT
	var stop: float = c.colony.follow_stop_px + _slack
	for dist in [stop, stop + 12.0, stop + 24.0, stop + 40.0]:
		for angle in ([0.0] if not jitter else [0.5, -0.5, 1.0, -1.0, 0.0]) + [0.4, -0.4, 0.9, -0.9]:
			var p: Vector2 = (pp + away.rotated(angle) * dist).round()
			if c._can_stand_at(p) and not _near_door(p) and not c._crowded(p):
				return p
	return pp

# --- Through the doors ------------------------------------------------------------------------------------------------------

func _visit(delta: float, player: Node2D) -> void:
	var b: Node2D = player.inside_building
	if visiting != null and visiting != b:
		_leave_visit()
	if visiting == null:
		var door: Vector2 = b.door_position()
		status = "Following you in"
		if c.position.distance_to(door) > 6.0:
			c.visible = true
			go(door, delta, c.colony.follow_catchup_multiplier)
			return
		var room: Node2D = b.get_interior()
		if room.shown.size() >= c.colony.visitor_limit or player.transitioning:
			status = "Waiting at the door"
			_stand()
			return
		visiting = b
		c.waypoints.clear()
	status = "Waiting inside"
	if not player.transitioning and not c.in_room and is_instance_valid(visiting):
		visiting.get_interior().show_colonist(c)

# Back out of the room he was in: at its door, awake and visible again.
func _leave_visit() -> void:
	if visiting == null:
		return
	var b: Node2D = visiting
	visiting = null
	c.in_room = false
	c.visible = true
	if is_instance_valid(b):
		var room: Node2D = b.get_interior()
		room.shown.erase(c)
		c.position = b.door_position() + Vector2(0, 8)
	c.waypoints.clear()
	c.play("idle")
	phase = Phase.WAIT

# --- Stay -----------------------------------------------------------------------------------------------------------------

func _stay(delta: float) -> void:
	var post: Vector2 = c.orders.post
	if post == Vector2.INF:
		post = c.position
		c.orders.post = post
	var d: float = c.position.distance_to(post)
	match phase:
		Phase.MOVE:
			status = "Going back to his post"
			if d <= 3.0 or go(post, delta, 1.0):
				phase = Phase.WAIT
				_timer = c._random_idle_time()
				_stand()
		Phase.WAIT:
			status = "Staying here"
			_stand()
			if d > 10.0:
				phase = Phase.MOVE
				_replan = 0.0
				return
			_timer -= delta
			if _timer <= 0.0:
				# a small fidget round the post
				for attempt in 8:
					var p: Vector2 = (post + Vector2.from_angle(randf() * TAU) * randf_range(6.0, 14.0)).round()
					if c._can_stand_at(p):
						_fidget_target = p
						phase = Phase.FIDGET
						_replan = 0.0
						return
				_timer = c._random_idle_time()
		Phase.FIDGET:
			status = "Staying here"
			if go(_fidget_target, delta, 0.6):
				phase = Phase.WAIT
				_timer = c._random_idle_time()
				_stand()

# --- Assist ---------------------------------------------------------------------------------------------------------------

# True while the assist work takes his whole frame.
func _assist(delta: float, player: Node2D) -> bool:
	var log: Dictionary = player.work_log
	var recent: bool = _now() - float(log["at"]) <= c.colony.assist_idle_seconds
	if not job.is_empty():
		if not recent:
			_end_job()
			return false
		return _run_job(delta, player)
	if not recent and _tool != &"":
		_return_tool()
	if not recent or player.inside_building != null:
		return false
	if not _pick_job(player, log):
		return false
	return _run_job(delta, player)

func _plots() -> Node2D:
	return load("res://scripts/plot_manager.gd").get_for(get_tree())

func _pick_job(player: Node2D, log: Dictionary) -> bool:
	var col: Node = c.colony
	var kind: StringName = log["kind"]
	var near: Vector2 = player.global_position
	match kind:
		&"chop", &"delimb":
			var best: Node2D = null
			var best_d: float = INF
			for t in get_tree().get_nodes_in_group("trees"):
				if t == log["target"] or t.claimed_by != null:
					continue
				if (kind == &"chop" and not t.is_standing()) or (kind == &"delimb" and not t.is_felled()):
					continue
				if t.global_position.distance_to(near) > col.assist_radius_px:
					continue
				var d: float = c.position.distance_squared_to(t.global_position)
				if d < best_d:
					best_d = d
					best = t
			if best == null or not _tool_ok(kind):
				return false
			if not best.try_claim(c):
				return false
			var side: float = 1.0 if c.position.x > best.position.x else -1.0
			var offs: Vector2 = player.fell_stand_offset if kind == &"chop" else player.delimb_stand_offset
			job = {"kind": kind, "target": best, "side": side, "spot": Vector2(best.position.x - side * offs.x, best.position.y + offs.y).round()}
		&"hammer":
			var b = log["target"]
			if b == null or not is_instance_valid(b) or not b.is_in_group("buildings") or b.state == b.State.BUILT or not b.is_supplied() or not _tool_ok(kind):
				return false
			# (The player holds the claim: he works the same blueprint from its other side, without one of his own.)
			var hs: Vector2 = b.hammer_spot_world()
			var mirrored: Vector2 = Vector2(2.0 * b.global_position.x - hs.x, hs.y).round()
			var spot: Vector2 = mirrored if c._can_stand_at(mirrored) else hs + Vector2(0, 10)
			job = {"kind": kind, "target": b, "side": 1.0 if spot.x < b.global_position.x else -1.0, "spot": spot}
		&"pull":
			var best_p: Node2D = null
			var best_pd: float = INF
			for patch in get_tree().get_nodes_in_group("grass_patches"):
				if patch == log["target"] or not patch.is_tall() or patch.claimed_by != null:
					continue
				if patch.global_position.distance_to(near) > col.assist_radius_px:
					continue
				var pd: float = c.position.distance_squared_to(patch.global_position)
				if pd < best_pd:
					best_pd = pd
					best_p = patch
			if best_p == null or not best_p.try_claim(c):
				return false
			var pside: float = 1.0 if c.position.x > best_p.position.x else -1.0
			job = {"kind": kind, "target": best_p, "side": pside, "spot": Vector2(best_p.position.x + pside * player.pull_stand_offset.x, best_p.position.y + player.pull_stand_offset.y).round()}
		&"till", &"water", &"harvest", &"sow":
			return _pick_plot_job(player, log)
		_:
			return false
	job["phase"] = "walk"
	_prepare_tool(job)
	return true

func _pick_plot_job(player: Node2D, log: Dictionary) -> bool:
	var m: Node2D = _plots()
	var kind: StringName = log["kind"]
	var near: Vector2 = player.global_position
	var radius: float = c.colony.assist_radius_px
	var origin: Vector2i = log["cell"]
	# what he does: the same, except that sowing (no seeds) becomes watering, or tilling when nothing needs water
	var wanted: Array = [kind] if kind != &"sow" else [&"water", &"till"]
	for want in wanted:
		var best: Vector2i = Vector2i.ZERO
		var best_d: float = INF
		var found: bool = false
		var cells: Array = []
		if want == &"till":
			for dx in range(-4, 5):
				for dy in range(-4, 5):
					cells.append(origin + Vector2i(dx, dy))
		else:
			cells = m.plots.keys()
		for cell in cells:
			if cell == origin or m.is_claimed(cell):
				continue
			var centre: Vector2 = m.cell_center(cell)
			if centre.distance_to(near) > radius or c.position.distance_to(centre) > radius * 1.5:
				continue
			var ok: bool = false
			match want:
				&"till":
					ok = (not m.has_plot(cell) and m.can_till(cell) == "") or (m.has_plot(cell) and m.stage(cell) == &"stubble")
				&"water":
					var st: StringName = m.stage(cell)
					ok = (st == &"sown" or st == &"growing") and not m.is_watered(cell)
				&"harvest":
					ok = m.stage(cell) == &"ripe"
			if not ok:
				continue
			var d: float = c.position.distance_squared_to(centre)
			if d < best_d:
				best_d = d
				best = cell
				found = true
		if found and _tool_ok(want) and m.claim_cell(best, c):
			var centre2: Vector2 = m.cell_center(best)
			var spot: Vector2 = (centre2 + Vector2(-11, 6)).round()
			if not c._can_stand_at(spot):
				spot = (centre2 + Vector2(11, 6)).round()
			job = {"kind": want, "cell": best, "spot": spot, "side": 1.0, "phase": "walk"}
			_prepare_tool(job)
			return true
	return false

func _job_valid() -> bool:
	match job["kind"]:
		&"chop", &"delimb":
			var t = job["target"]
			return is_instance_valid(t) and t.claimed_by == c and ((job["kind"] == &"chop" and t.is_standing()) or (job["kind"] == &"delimb" and t.is_felled()))
		&"hammer":
			var b = job["target"]
			return is_instance_valid(b) and b.state != b.State.BUILT and b.is_supplied()
		&"pull":
			var p = job["target"]
			return is_instance_valid(p) and p.is_tall() and p.claimed_by == c
		&"till", &"water", &"harvest":
			var m: Node2D = _plots()
			var cell: Vector2i = job["cell"]
			match job["kind"]:
				&"till":
					return not m.has_plot(cell) or m.stage(cell) == &"stubble"
				&"water":
					var st: StringName = m.stage(cell)
					return (st == &"sown" or st == &"growing") and not m.is_watered(cell)
				_:
					return m.stage(cell) == &"ripe"
	return false

func _describe_job() -> String:
	match job["kind"]:
		&"chop":
			return "Chopping a tree"
		&"delimb":
			return "Delimbing a tree"
		&"hammer":
			return "Hammering %s" % (job["target"].display_name() if is_instance_valid(job["target"]) else "a blueprint")
		&"pull":
			return "Pulling grass"
		&"till":
			return "Tilling a plot"
		&"water":
			return "Watering a plot"
		&"harvest":
			return "Harvesting wheat"
	return "Working"

# True while he is busy with the job this frame.
func _run_job(delta: float, player: Node2D) -> bool:
	if not _job_valid():
		_end_job()
		return false
	status = _describe_job()
	match job["phase"]:
		"fetch":
			status = "Fetching the %s" % String(_tool_needed(job["kind"]))
			if _tool_box == null or not is_instance_valid(_tool_box):
				_end_job()
				return false
			if go(_tool_box.interact_point(), delta, 1.0) or c.position.distance_to(_tool_box.interact_point()) < 10.0:
				var idx: int = _tool_box.kinds().find(_tool_needed(job["kind"]))
				if idx < 0:
					_say_once("No %s available" % String(_tool_needed(job["kind"])))
					_end_job()
					return false
				_tool_box.take_item(idx)
				_tool = _tool_needed(job["kind"])
				job["phase"] = "walk"
				_replan = 0.0
			return true
		"walk":
			if go(job["spot"], delta, 1.0):
				job["phase"] = "work"
				_timer = _interval(player)
				c.waypoints.clear()
				_face(job)
			return true
		_:
			working = true
			if c.animation != &"idle":
				c.play("idle")
			_face(job)
			_timer -= delta
			if _timer > 0.0:
				return true
			_strike(player)
			if not job.is_empty():
				_timer = _interval(player)
			return true

func _face(j: Dictionary) -> void:
	var at: Vector2 = Vector2.INF
	if j.has("target") and is_instance_valid(j["target"]):
		at = j["target"].global_position
	elif j.has("cell"):
		at = _plots().cell_center(j["cell"])
	if at != Vector2.INF:
		c.flip_h = at.x < c.position.x

# Seconds one action of this job takes him: the player's own time, slower by his efficiency and by friend_work_efficiency.
func _interval(player: Node2D) -> float:
	return WorkActions.seconds(job["kind"], player) / maxf(0.1, c.rest.efficiency() * c.colony.friend_work_efficiency)

func _strike(player: Node2D) -> void:
	var st: SceneTree = get_tree()
	var finished: bool = false
	match job["kind"]:
		&"chop", &"delimb":
			finished = WorkActions.chop(st, job["target"], job["kind"], player.hits_per_chop)["finished"]
		&"hammer":
			finished = WorkActions.hammer(st, job["target"])["finished"]
		&"pull":
			finished = WorkActions.pull(st, job["target"], player, c.position + Vector2(0, 4))["finished"]
		&"till":
			finished = WorkActions.till(_plots(), job["cell"])
		&"water":
			WorkActions.water(_plots(), job["cell"], c.position)
			finished = true
		&"harvest":
			WorkActions.harvest(st, _plots(), job["cell"], c.get_parent(), player.map_rect)
			finished = true
	c.work_bob()
	if finished:
		_end_job()

# Lets go of the job and whatever it holds (a tree, a patch, a plot, a borrowed tool).
func _end_job() -> void:
	if not job.is_empty():
		match job["kind"]:
			&"chop", &"delimb", &"pull":
				if is_instance_valid(job["target"]):
					job["target"].release_claim(c)
			&"till", &"water", &"harvest":
				_plots().release_cell(job["cell"], c)
		job = {}
	working = false
	c.waypoints.clear()

# For the work jobs: does he hold this tool (taken from the toolbox), the toolbox to fetch it from, and taking it.
func has_tool(tool: StringName) -> bool:
	return _tool == tool

func toolbox_node() -> Node2D:
	return _toolbox()

func take_tool(tool: StringName) -> bool:
	var box: Node2D = _toolbox()
	if box == null:
		return false
	var idx: int = box.kinds().find(tool)
	if idx < 0:
		return false
	box.take_item(idx)
	_tool = tool
	_tool_box = box
	return true

# --- Tools (friend_needs_tools; off by default) ---------------------------------------------------------------------------------

func _tool_needed(kind: StringName) -> StringName:
	return WorkActions.TOOL_OF.get(kind, &"")

func _toolbox() -> Node2D:
	for box in get_tree().get_nodes_in_group("toolboxes"):
		if not box.is_carried():
			return box
	return null

# May he do this work: with friend_needs_tools off always; on, the tool must be in the toolbox (he fetches it), else the message.
func _tool_ok(kind: StringName) -> bool:
	if not c.colony.friend_needs_tools:
		return true
	var tool: StringName = _tool_needed(kind)
	if tool == &"" or _tool == tool:
		return true
	var box: Node2D = _toolbox()
	if box == null or not box.kinds().has(tool):
		_say_once("No %s available" % String(tool))
		return false
	return true

func _prepare_tool(j: Dictionary) -> void:
	if c.colony.friend_needs_tools and _tool_needed(j["kind"]) != &"" and _tool != _tool_needed(j["kind"]):
		_return_tool()
		_tool_box = _toolbox()
		j["phase"] = "fetch"

func _return_tool() -> void:
	if _tool != &"":
		var box: Node2D = _tool_box if is_instance_valid(_tool_box) else _toolbox()
		if box != null:
			box.add_item(_tool, 0)
		_tool = &""

func _say_once(text: String, key: String = "", cooldown: float = 20.0) -> void:
	var k: String = key if key != "" else text
	if _now() - float(_said.get(k, -100.0)) < cooldown:
		return
	_said[k] = _now()
	said_count[k] = int(said_count.get(k, 0)) + 1
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say(text)
