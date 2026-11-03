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
const WorkJobsScript = preload("res://scripts/work_jobs.gd")
const LogDragger = preload("res://scripts/log_dragger.gd")
const PlankPiles = preload("res://scripts/plank_piles.gd")
const Items = preload("res://scripts/items.gd")
const BuildingInterior = preload("res://scripts/building_interior.gd")
const Logistics = preload("res://scripts/logistics.gd")

enum Phase { MOVE, WAIT, FIDGET }

var c: Node2D = null
var phase: Phase = Phase.WAIT
var working: bool = false
var job: Dictionary = {}
var board_job = null
var visiting: Node2D = null
# The room (BuildingInterior) he has been put in by his work or a visit: his position is then really in that room (see go()), seen only while
# the player is in it. null = outdoors.
var inside_room: Node2D = null
# He tried to go through a door while dragging a log (said once as "Cannot reach ...").
var door_blocked: bool = false
# How many times he has gone in through a door (for the self-check).
var room_entries: int = 0
var status: String = ""

# The work job he is doing (roles and tasks, work_jobs.gd), what he carries ({"kind", "amount"} or {}), the log he drags, and the book-keeping
# of failures: targets skipped for a while, the last failure and the last "Done ..." report (both shown on the hover line).
var work_job = null
# GETTING READY FOR BED. When he gets sleepy (bedtime, or exhausted) in the middle of his work he does not vanish and nothing is dropped where he stands:
# Colonist asks ready_for_bed() every frame; the first call makes him "sleepy", and _sleepy_step then takes the place of the normal tick until he is ready:
# the swing or step in hand is finished (SLEEPY_SWING_SECONDS at most), a log he drags or a thing he carries goes on to where it is going (storage, a crate, a
# blueprint: the CarryJob, SLEEPY_CARRY_SECONDS at most), the job lets go of its claims (the tree, the plot cell, the blueprint are free for anyone) and a
# tool goes back into a toolbox (ReturnToolJob); whatever is still in his hands after SLEEPY_MAX_SECONDS, or has nowhere to go, is put down beside his house
# (never on its door). Then he walks to his bed in the open like anybody going home.
const SLEEPY_SWING_SECONDS: float = 2.5
const SLEEPY_CARRY_SECONDS: float = 45.0
const SLEEPY_MAX_SECONDS: float = 75.0
var sleepy: bool = false
var _sleepy_time: float = 0.0
var _sleepy_strikes: int = 0
var _prev_working: bool = false
# ASSIST + the Cook's chain (cook_jobs.gd): the step he is doing for me while I grind, make dough or bake, whatever his roles are.
var assist_cook = null
# What the Farmer leaves alone for a while: phase (&"sow") or cell -> the time (seconds) until which it is skipped (farm_jobs.gd).
var farm_skip: Dictionary = {}
# THE ONE HELD-ITEM SLOT (character_hands.gd): the tool in his hands (ColonistTools.held), a plank, the saw blade or an item (`carrying`) are all this one slot,
# so he can never hold two things. `carrying` is a read-only view of it ({"kind", "amount"} for a carried item, {} for nothing or a tool).
var hands: CharacterHands = null
var carrying: Dictionary:
	get:
		return hands.item() if hands != null else {}
	set(_value):
		CharacterHands.report("%s: ColonistOrderAI.carrying is read-only (set_carry / clear_carry change the one hands slot)" % c.display_name)
var carry_sprite: Sprite2D = null
var dragger = null
var drag_tree = null
var stuck_events: int = 0
var fail_text: String = ""
var fail_until: float = 0.0
# The job (instance id; 0 = none) the reason was given on: it goes as soon as he starts a different job, not after its ten seconds.
var fail_for: int = 0
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
# His tools (colonist_tools.gd): what he holds, fetching, returning.
var tools: Node = null
# Strikes he has made (a recall waits for the swing in hand), and the stuck bookkeeping when the AI itself walks for an Assist copy.
var strikes: int = 0
# Logs he has sawn since the last "Done sawing." report, and in all.
var sawn: int = 0
var sawn_total: int = 0
var unreachable: bool = false
var _stuck_base: int = 0
# Prints, once a second, his stance, roles, tasks, the job he picked and why each candidate was not (see explain_jobs): for finding out why a
# colonist does nothing. (Colony.debug_job_log turns it on for everyone.)
@export var debug_job_log: bool = false
var _debug_left: float = 0.0
var _preempt_check: float = 0.0
var _said: Dictionary = {}

func setup(colonist: Node2D) -> void:
	c = colonist
	name = "OrderAI"
	dragger = LogDragger.new(colonist, colonist)
	hands = CharacterHands.new(colonist.name)
	hands.dragger = dragger
	tools = preload("res://scripts/colonist_tools.gd").new()
	add_child(tools)
	tools.setup(colonist, self)

func begin() -> void:
	phase = Phase.MOVE if c.orders.stance == c.Orders.Stance.STAY else Phase.WAIT
	_replan = 0.0
	_timer = 0.0
	c._reset_stuck()

func has_claims() -> bool:
	return not job.is_empty() or visiting != null or inside_room != null or tools.reserving() or board_job != null or work_job != null or dragger.is_dragging()

# Gives back everything: claims, a borrowed tool, the room he is visiting, the work job; with `drop`, what he carries is set down where he stands
# (the nearest free ground). Safe to call at any time.
func release_all(drop: bool = false, leave: bool = true) -> void:
	_end_job()
	if board_job != null:
		board_job.release()
		board_job = null
	if work_job != null:
		work_job.release()
		work_job = null
	if assist_cook != null:
		assist_cook.release()
		assist_cook = null
	tools.release_all()
	_leave_visit()
	if leave:
		leave_room_now()
	working = false
	if drop:
		drop_carry()

# He has just been taken out of his order (hunger, sleep, the carry, a task): the job lets go of its claims (a log it dragged is laid down
# where it is); what he carries in his hands stays with him through a meal and is delivered when he is back, unless he is about to starve or
# to sleep, when it is set down where he stands.
func on_interrupted() -> void:
	sleepy = false
	var drop: bool = false
	var asleep_states: Array = [c.State.TO_BED, c.State.ON_BED, c.State.SLEEPING_OUTSIDE, c.State.MOVING_IN, c.State.RETURNING, c.State.INSIDE, c.State.ENTERING, c.State.TO_SLEEP_SPOT]
	match c.state:
		c.State.HELPING_CARRY, c.State.TO_WORK, c.State.AT_WORK:
			drop = true
	release_all(drop)
	if drop and tools.holding():
		tools.drop_here("he was taken off his work (%s)" % str(c.State.keys()[c.state]))
	# Going to bed (or to a meal) with something still in his hands is not a reason to leave it at the work site: the tool goes back into a toolbox, anything else
	# is put down beside his house, and it is said loudly so that nothing is ever lost quietly. (The ready-for-bed walk empties his hands first; this is the safety net.)
	if c.state in asleep_states:
		put_away_for_sleep_now("interrupted by sleep in state %s" % str(c.State.keys()[c.state]))

# What is in his hands goes away at once for a sleep: a tool into a toolbox (else beside his house), a carried thing into a crate / Storage when one has room, else beside
# his house. A debug line says what it was and where it went.
func put_away_for_sleep_now(why: String) -> void:
	if tools.holding():
		var tool_name: String = String(tools.held)
		tools.return_instantly()
		print("SLEEP: %s put the %s away (%s)" % [c.display_name, tool_name, why])
	if dragger.is_dragging():
		dragger.drop()
	if not carrying.is_empty():
		var kind: StringName = carrying.get("kind", &"")
		if not _store_carried_now():
			set_down_near_house()
		print("SLEEP: %s put the %s away (%s)" % [c.display_name, kind, why])

# A carried thing into the place it belongs, without walking: Storage for a plank, a crate for an item. False if none has room.
func _store_carried_now() -> bool:
	var kind: StringName = carrying.get("kind", &"")
	var tree: SceneTree = get_tree()
	if kind == &"plank":
		var dest: Dictionary = Logistics.plank_destination(tree, c.position)
		if not dest.is_empty() and dest["node"].add_planks(1) > 0:
			clear_carry()
			return true
		return false
	if Items.is_item(kind):
		var idest: Dictionary = Logistics.item_destination(tree, kind, c.position)
		if not idest.is_empty():
			var crate: Node2D = idest["node"]
			var ok: bool = crate.add_bag(int(carrying.get("amount", 0))) if kind == &"seed_bag" else crate.add_item(kind, 1) > 0
			if ok:
				clear_carry()
				return true
	return false

# A free spot beside his house, off its door.
func near_house_spot() -> Vector2:
	var base: Vector2 = c.position
	var door: Vector2 = Vector2.INF
	if c.home != null and is_instance_valid(c.home):
		door = c.home.door_position()
		base = door + Vector2(28, 22)
	var spot: Vector2 = load("res://scripts/ground_placement.gd").find_free_ground_near(get_tree(), base, Vector2(14, 10))
	if spot == Vector2.INF:
		spot = base.round()
	if door != Vector2.INF and spot.distance_to(door) < 16.0:
		spot = (door + Vector2(30, 24)).round()
	return spot

# Whatever he carries (a thing or a tool) is put down on the free ground beside his house.
func set_down_near_house() -> void:
	var spot: Vector2 = near_house_spot()
	if tools.holding():
		tools.drop(spot, true)
	if not carrying.is_empty():
		drop_carry(true, spot)

# At once, for the sleep skip: the job lets go of its claims, nothing is left in his hands (a tool into the toolbox, a thing into storage or beside the house).
func prepare_instantly() -> void:
	sleepy = false
	if work_job != null:
		work_job.release()
		work_job = null
	if assist_cook != null:
		assist_cook.release()
		assist_cook = null
	release_all(false, false)
	put_away_for_sleep_now("the sleep skip")

# What the job says it does, and where when that is inside a building ("Hauling planks in the House"; the Build job words it itself).
func _job_status(j) -> String:
	var text: String = j.describe()
	var host = j.location()
	if host != null and is_instance_valid(host) and not text.contains(" in the "):
		text += " in the %s" % Logistics.host_name(host)
	return text

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

# debug_job_log: once a second, one line with his stance, roles, tasks, the job he has, what he holds, and why each candidate job is not possible.
func debug_tick(delta: float) -> void:
	if not (debug_job_log or (c.colony != null and c.colony.debug_job_log)):
		return
	_debug_left -= delta
	if _debug_left > 0.0:
		return
	_debug_left = 1.0
	var roles_text: String = ", ".join(c.orders.roles.map(func(r: StringName) -> String: return String(r)))
	print("JOBLOG %s: stance=%s roles=[%s] tasks=[%s] state=%s job=%s holding=%s carrying=%s | %s" % [c.display_name, c.orders.name_now(), roles_text, c.orders.tasks_text(), str(c.State.keys()[c.state]), work_job.describe() if work_job != null else "none", String(tools.held), str(carrying.get("kind", &"")), " | ".join(WorkJobsScript.explain(c))])

# --- Every frame ----------------------------------------------------------------------------------------------------------

# Called every frame by the colonist who wants to sleep: true once he is ready to leave for his bed (see GETTING READY FOR BED above).
func ready_for_bed() -> bool:
	if not sleepy:
		sleepy = true
		_sleepy_time = 0.0
		_sleepy_strikes = strikes
	return work_job == null and assist_cook == null and not tools.holding() and carrying.is_empty() and not dragger.is_dragging() and not tools.reserving()

func _sleepy_step(delta: float) -> void:
	_sleepy_time += delta
	status = "Getting ready for bed"
	# 1. the job in hand: the swing finishes, a delivery goes on; then the job lets go (its claims go, its target is free for others)
	if assist_cook != null:
		assist_cook.release()
		assist_cook = null
	if work_job != null and not work_job.is_return:
		var delivering: bool = dragger.is_dragging() or not carrying.is_empty()
		var in_swing: bool = _prev_working and strikes == _sleepy_strikes
		if (delivering and _sleepy_time < SLEEPY_CARRY_SECONDS) or (in_swing and _sleepy_time < SLEEPY_SWING_SECONDS):
			status = _job_status(work_job)
			if work_job.execute(c, delta) or work_job.failed:
				work_job.release()
				work_job = null
				waypoints_reset()
			return
		work_job.release()
		work_job = null
		waypoints_reset()
	# 2. what is still in his hands (and a tool he had set out to fetch is let go: nothing may keep him from his bed)
	if work_job == null and tools.reserving() and tools.held == &"":
		tools.release_reservation()
	if work_job == null and _sleepy_time < SLEEPY_MAX_SECONDS:
		if tools.holding():
			tools.force_return = true
			tools.recall_after_strikes = -1
			var rj = WorkJobsScript.ReturnToolJob.new()
			rj.setup(c, {}, &"")
			rj.claim(c)
			work_job = rj
		elif dragger.is_dragging():
			dragger.drop()
		elif not carrying.is_empty():
			var cj = WorkJobsScript.CarryJob.new()
			cj.setup(c, {}, &"")
			if cj.claim(c):
				work_job = cj
	if work_job != null:
		status = _job_status(work_job)
		if work_job.execute(c, delta) or work_job.failed:
			work_job.release()
			work_job = null
			waypoints_reset()
	# 3. out of time, or nowhere for it to go: beside his house, off the door
	if (tools.holding() or not carrying.is_empty()) and (_sleepy_time >= SLEEPY_MAX_SECONDS or (work_job == null and _sleepy_time > 1.0)):
		if work_job != null:
			work_job.release()
			work_job = null
		print("SLEEP: %s could not take what he holds to its place in time: set down beside his house" % c.display_name)
		set_down_near_house()
	if dragger.is_dragging() and work_job == null:
		dragger.drop()

func tick(delta: float) -> void:
	_prev_working = working
	working = false
	var player: Node2D = get_tree().get_first_node_in_group("player")
	if player == null or player.dead:
		status = "Waiting"
		c.play("idle")
		return
	if sleepy:
		_sleepy_step(delta)
		return
	# A job never starts while he holds a tool that is not its own (a hammer when the job is sawing, an axe when it is hauling): the tool goes back first, then
	# the job is picked again.
	if work_job != null and not work_job.is_return and not work_job.start_checked:
		work_job.start_checked = true
		if tools.holding() and tools.held != work_job.primary_tool():
			tools.force_return = true
			tools.recall_after_strikes = -1
	# A tool he no longer needs (or has been asked for) goes back to the toolbox first, whatever his stance.
	if work_job == null or not work_job.is_return:
		if tools.wants_return():
			if work_job != null:
				work_job.release()
				work_job = null
			var rj = WorkJobsScript.ReturnToolJob.new()
			rj.setup(c, {}, &"")
			rj.claim(c)
			work_job = rj
	if work_job != null and work_job.is_return:
		status = _job_status(work_job)
		if work_job.execute(c, delta) or work_job.failed:
			work_job.release()
			work_job = null
			_next_pick = 0.0
			waypoints_reset()
		return
	# (3) designated tasks and roles (work_jobs.gd, through the job board). Following and assisting pause them (the player has him with him);
	# with Free time or Stay he does them first, and goes back to his stance when there is nothing left.
	if not work_allowed():
		if work_job != null or (assist_cook == null and (not carrying.is_empty() or dragger.is_dragging())):
			release_all(true)
	else:
		# a tool he was waiting for is there now: the job in hand (unless he carries something) gives way, and the pick comes round at once
		if work_job != null and _now() >= _preempt_check:
			_preempt_check = _now() + 1.0
			if tools.unblocked_now() and not dragger.is_dragging() and carrying.is_empty() and work_job.get("phase") != "saw":
				work_job.release()
				work_job = null
				_next_pick = 0.0
				waypoints_reset()
		if work_job == null and _now() >= _next_pick and c.colony != null and c.colony.job_board != null:
			_next_pick = _now() + 0.6
			work_job = c.colony.job_board.pick_for(c)
		if work_job != null:
			status = _job_status(work_job)
			if work_job.execute(c, delta) or work_job.failed:
				work_job.release()
				work_job = null
				_next_pick = 0.0
				waypoints_reset()
			return
		# nothing more to do in the building he works in: out through its door (a next job in the same room was taken above, without leaving)
		if _leave_room_step(delta):
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
func fail(key: String, text: String, say: bool = true) -> void:
	fail_text = text
	fail_until = _now() + 10.0
	fail_for = _activity_id()
	if say:
		_say_once(text, key, 60.0)

# The job he is on now (his work job, or the cook's task he assists with): 0 = none.
func _activity_id() -> int:
	if work_job != null:
		return work_job.get_instance_id()
	if assist_cook != null:
		return assist_cook.get_instance_id()
	return 0

# Every frame: a reason ("Nowhere to store it.") that was true for the job he had stays only while that job goes on; a different job clears it.
func expire_stale_reason() -> void:
	if fail_text != "" and reason_is_stale():
		fail_text = ""
		fail_until = 0.0

# Was the reason given on a job other than the one he is on now? (No job at all: it is still the last thing that went wrong.)
func reason_is_stale() -> bool:
	var now_id: int = _activity_id()
	return now_id != 0 and now_id != fail_for

# A task list is finished: "Done chopping." on the HUD and on his hover line.
func report(text: String) -> void:
	if text == "":
		return
	last_report = text
	report_until = _now() + 10.0
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say("%s: %s" % [c.display_name, text])

# He takes `kind` into his hands. Never on top of something else: the job frees his hands first (free_hands). If one did not, it is reported and what he
# held is put down here, so nothing is ever held twice, lost or doubled.
func set_carry(kind: StringName, amount: int = 1) -> void:
	if not hands.pick_up(kind, amount, false):
		CharacterHands.report("%s took '%s' with his hands full (%s)" % [c.display_name, kind, held_name()])
		_put_everything_down()
		hands.pick_up(kind, amount, false)
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
	elif kind == &"saw_blade":
		tex = load("res://sprites/saw_blade.png")
	carry_sprite.texture = tex
	refresh_overlay()

# What is in his hands, for messages: "the axe", "a plank", "a log" or "nothing".
func held_name() -> String:
	if tools.holding():
		return "the %s" % String(tools.held).replace("_", " ")
	if not carrying.is_empty():
		return "a %s" % String(carrying["kind"]).replace("_", " ")
	if dragger.is_dragging():
		return "a log"
	return "nothing"

# (A bug if it is ever needed: whatever he holds goes on the ground here.)
func _put_everything_down() -> void:
	if tools.holding():
		tools.drop_here()
	if not carrying.is_empty():
		drop_carry()

# The carried item leaves his hands (delivered, stored). A tool is not touched.
func clear_carry() -> void:
	if not hands.as_tool:
		hands.clear()
	if carry_sprite != null:
		carry_sprite.visible = false

# The picture of the carried item above his head: shown only when the animation playing does not already show the item in his arms (the shared rule,
# CharacterAnimator.needs_overlay). Called the moment the item or the animation changes, so the item is never drawn twice, not even for a frame.
func refresh_overlay() -> void:
	if carry_sprite == null:
		return
	carry_sprite.visible = carry_sprite.texture != null and not carrying.is_empty() and CharacterAnimator.needs_overlay(c.animation, c.carried_state())

# Sets what he carries down where he stands (the nearest free ground; a plank joins a stack there). With `force` false and no free ground anywhere near,
# it stays in his hands, "Hands full" is said (once) and this returns false.
func drop_carry(force: bool = true, at: Vector2 = Vector2.INF) -> bool:
	if carrying.is_empty():
		return true
	var kind: StringName = carrying.get("kind", &"")
	var amount: int = int(carrying.get("amount", 0))
	var tree: SceneTree = get_tree()
	var parent: Node = c.get_parent()
	var spot: Vector2 = load("res://scripts/ground_placement.gd").find_free_ground_near(tree, c.position if at == Vector2.INF else at, Vector2(12, 10))
	if spot == Vector2.INF:
		if not force:
			fail("hands_full", "Hands full")
			return false
		spot = c.position.round()
	if kind == &"plank":
		PlankPiles.put_plank(tree, parent, spot, 20.0, Rect2(0, 0, 640, 640), spot)
	elif Items.is_item(kind):
		Items.spawn(kind, parent, spot, amount)
	elif kind == &"saw_blade":
		PlankPiles.spawn_blade(parent, spot)
	clear_carry()
	return true

# His hands must be empty before he picks anything up (a tool, a plank, a log, the blade): the tool goes back into the toolbox (ColonistTools.put_away: the
# box it came from, else the nearest, else beside it), a carried item is set down on free ground (a plank joins the stack there), a dragged log is left
# lying. 1 = his hands are free, 0 = he is putting it away, -1 = there is nowhere to put it ("Hands full", said once; the job waits). `who` is the job
# (it needs walk(), unreachable and new_target()).
func free_hands(who, delta: float) -> int:
	if dragger.is_dragging():
		dragger.drop()
	if tools.holding():
		if tools.return_gave_up:
			fail("hands_full", "Hands full")
			return -1
		return 1 if tools.put_away(who, delta) else 0
	if not carrying.is_empty():
		return 1 if drop_carry(false) else -1
	return 1

# --- Moving ---------------------------------------------------------------------------------------------------------------

# The AI as the walker of an Assist copy (the work jobs bring their own): same walk / unreachable / new_target as a WorkJob.
func new_target() -> void:
	_stuck_base = stuck_events
	unreachable = false
	waypoints_reset()

func walk(point: Vector2, delta: float, mult: float = 1.0) -> bool:
	var arrived: bool = go(point, delta, mult)
	if stuck_events - _stuck_base >= 3:
		unreachable = true
	return arrived

func waypoints_reset() -> void:
	if c.state == c.State.ORDERED:
		c.waypoints.clear()
	_replan = 0.0
	door_blocked = false
	c._reset_stuck()

# --- Through the doors ------------------------------------------------------------------------------------------------------

# The room he really stands in (null outdoors).
func room_here() -> Node2D:
	if not BuildingInterior.is_interior_point(c.position):
		return null
	return BuildingInterior.room_at(get_tree(), c.position)

func _room_at(point: Vector2) -> Node2D:
	if not BuildingInterior.is_interior_point(point):
		return null
	return BuildingInterior.room_at(get_tree(), point)

# One step along a path to `point`; true once he is there. `mult` is relative to his own (tired / wading) speed. The point may be in a
# room of a building: then he walks to that building's door, goes in the way the eaters and sleepers do (the door sound; seen coming in
# when the player is in that room) and walks on inside; and from a room to anywhere else he walks to the room's exit first and comes out
# at the door. A log being dragged does not go through a door.
func go(point: Vector2, delta: float, mult: float = 1.0) -> bool:
	var here: Node2D = room_here()
	var there: Node2D = _room_at(point)
	if here != there:
		_through_door(here, there, delta, mult)
		return false
	return _go_local(point, delta, mult)

func _through_door(here: Node2D, there: Node2D, delta: float, mult: float) -> void:
	if here != null:
		if _go_local(here.exit_point_world(), delta, mult):
			_exit_room(here)
		return
	var host = there.building
	if host == null or not is_instance_valid(host):
		stuck_events += 3
		return
	if dragger.is_dragging():
		if not door_blocked:
			door_blocked = true
			stuck_events += 3
		return
	if _go_local(host.door_position(), delta, mult):
		_enter_room(there)

# Through the door in: he is at the room's door (seen walking in when the player is in that room, else out of sight).
func _enter_room(room: Node2D) -> void:
	var host = room.building
	AudioManager.play("door", host.door_position(), 1.0, -4.0)
	c.position = room.door_world()
	inside_room = room
	room_entries += 1
	var seen: bool = room.player_inside
	c.set_body_visible(&"room", seen)
	c.in_room = seen
	if seen and not room.shown.has(c):
		room.shown.append(c)
	c.play("idle")
	waypoints_reset()

# Through the door out: at the building's door, visible, the room forgets him.
func _exit_room(room: Node2D) -> void:
	inside_room = null
	if room != null and is_instance_valid(room):
		room.shown.erase(c)
		var host = room.building
		if host != null and is_instance_valid(host):
			c.position = host.door_position() + Vector2(0, 3)
			AudioManager.play("door", c.position, 1.0, -4.0)
			if visiting == host:
				visiting = null
	c.in_room = false
	c.set_body_visible(&"*", true)
	c.play("idle")
	waypoints_reset()

# Out of the room at once (a need, a stance, death): at the door outside.
func leave_room_now() -> void:
	if visiting != null:
		_leave_visit()
	var here: Node2D = room_here()
	if here == null and inside_room != null and is_instance_valid(inside_room):
		here = inside_room
	if here != null:
		_exit_room(here)
	inside_room = null

# He is in a room only for his work (or following the player in): with nothing left to do there he walks out. True while he does.
func _leave_room_step(delta: float) -> bool:
	var here: Node2D = room_here()
	if here == null:
		inside_room = null
		return false
	if visiting != null:
		return false
	status = "Leaving the %s" % Logistics.host_name(here.building).to_lower()
	if _go_local(here.exit_point_world(), delta, 1.0):
		_exit_room(here)
	return true

# The room his building had has gone (it was taken down): he is put out at `door`.
func on_room_closed(door: Vector2) -> void:
	inside_room = null
	if visiting != null:
		visiting = null
	release_all(true, false)
	c.position = door + Vector2(0, 8)
	c.set_body_visible(&"*", true)
	c.in_room = false
	waypoints_reset()

func _go_local(point: Vector2, delta: float, mult: float = 1.0) -> bool:
	_replan -= delta
	if _replan <= 0.0 or c.waypoints.is_empty():
		_replan = 0.5
		c.waypoints = c._path_to(point)
		# (The walls of a room are not obstacles: the places a path turns at are kept on the floor.)
		var floor_room: Node2D = room_here()
		if floor_room != null:
			for i in c.waypoints.size():
				c.waypoints[i] = floor_room.clamp_walk(c.waypoints[i])
		c._reset_stuck()
	if c.waypoints.is_empty():
		return true
	c.pose_walk()
	var arrived: bool = c._follow_path(delta, mult)
	if c._is_stuck(delta):
		# Stuck behind something: plan again, and a little to the side.
		stuck_events += 1
		c.waypoints = c._path_to(point + Vector2(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0)))
		var floor_room2: Node2D = room_here()
		if floor_room2 != null:
			for i in c.waypoints.size():
				c.waypoints[i] = floor_room2.clamp_walk(c.waypoints[i])
		c._reset_stuck()
	return arrived

func _stand() -> void:
	c.waypoints.clear()
	c.pose_idle()

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
	if visiting != null or inside_room != null or room_here() != null:
		leave_room_now()
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
	c.pose_walk()
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
	if visiting == null and room_here() != null:
		if room_here().building == b:
			# (already in this room for his work: he stays, as a visitor now)
			visiting = b
			inside_room = b.get_interior()
		else:
			leave_room_now()
	if visiting == null:
		var door: Vector2 = b.door_position()
		status = "Following you in"
		if c.position.distance_to(door) > 6.0:
			c.set_body_visible(&"*", true)
			go(door, delta, c.colony.follow_catchup_multiplier)
			return
		var room: Node2D = b.get_interior()
		if room.shown.size() >= c.colony.visitor_limit or player.transitioning:
			status = "Waiting at the door"
			_stand()
			return
		visiting = b
		inside_room = b.get_interior()
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
	inside_room = null
	c.in_room = false
	c.set_body_visible(&"*", true)
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
	# the Cook's chain: the step in hand is finished even when my work has stopped; a new one is taken only while I work
	if assist_cook != null:
		return _run_assist_cook(delta)
	if recent and log["kind"] == &"cook" and job.is_empty():
		assist_cook = load("res://scripts/cook_jobs.gd").pick(c)
		if assist_cook != null:
			return _run_assist_cook(delta)
		return false
	if not job.is_empty():
		if not recent:
			_end_job()
			return false
		# a job in a room lasts while I am in that room
		var job_room: Node2D = _room_at(job.get("spot", Vector2.ZERO))
		if job_room != null and player.inside_building != job_room.building:
			_end_job()
			return false
		return _run_job(delta, player)
	if not recent:
		return false
	# In a house with me he copies only the hammering of a blueprint in that very room (the rest of the copied work is outdoors); and out of
	# doors he does not run in to a blueprint I hammered inside.
	var target = log["target"]
	var target_room: Node2D = _room_at(target.global_position) if target != null and is_instance_valid(target) and target is Node2D else null
	if player.inside_building != null:
		if log["kind"] != &"hammer" or target_room == null or target_room.building != player.inside_building:
			return false
	elif target_room != null:
		return false
	if not _pick_job(player, log):
		return false
	return _run_job(delta, player)

func _run_assist_cook(delta: float) -> bool:
	status = _job_status(assist_cook)
	if assist_cook.execute(c, delta) or assist_cook.failed:
		assist_cook.release()
		assist_cook = null
		waypoints_reset()
	return true

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
			if best == null or not tools.can_start(WorkActions.tool_of(kind)):
				return false
			if not best.try_claim(c):
				return false
			var side: float = 1.0 if c.position.x > best.position.x else -1.0
			var offs: Vector2 = player.fell_stand_offset if kind == &"chop" else player.delimb_stand_offset
			job = {"kind": kind, "target": best, "side": side, "spot": Vector2(best.position.x - side * offs.x, best.position.y + offs.y).round()}
		&"hammer":
			var b = log["target"]
			if b == null or not is_instance_valid(b) or not b.is_in_group("buildings") or b.is_finished() or not b.is_supplied() or not tools.can_start(WorkActions.tool_of(kind)):
				return false
			# (The player holds the claim: he works the same blueprint from its other side, without one of his own.)
			var hs: Vector2 = b.hammer_spot_world()
			var mirrored: Vector2 = Vector2(2.0 * b.global_position.x - hs.x, hs.y).round()
			var spot: Vector2 = mirrored if c._can_stand_at(mirrored) else hs + Vector2(0, 10)
			var b_room: Node2D = _room_at(b.global_position)
			if b_room != null:
				# (In a room: a place on the floor, reachable from the door and not the one I stand on.)
				spot = b_room.standing_spot(Logistics.cover_rect(get_tree(), b), mirrored, [player.global_position])
				if spot == Vector2.INF:
					return false
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

# An Assist copy that needs a tool he does not hold starts by fetching it.
func _prepare_tool(j: Dictionary) -> void:
	var tool: StringName = WorkActions.tool_of(j["kind"])
	if c.colony.friend_needs_tools and tool != &"" and not tools.held == tool:
		j["phase"] = "fetch"

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
		if found and tools.can_start(WorkActions.tool_of(want)) and m.claim_cell(best, c):
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
			return is_instance_valid(b) and not b.is_finished() and b.is_supplied()
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
			var tool: StringName = WorkActions.tool_of(job["kind"])
			status = "Fetching the %s" % String(tool)
			var tk: int = tools.ensure(self, tool, delta)
			if tk == 1:
				job["phase"] = "walk"
				new_target()
			elif tk < 0:
				_end_job()
				return false
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
			_face(job)
			# the work animation runs for the whole action and the hit comes at its strike frame
			if c.animator.work_cycle(job["kind"], delta, _interval(player), c.carry_state()):
				_strike(player)
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
	strikes += 1
	if WorkActions.tool_of(job["kind"]) != &"":
		tools.touch()
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
	# (only the walk of the ORDER is cleared: a walk to bed that was set in the same frame belongs to the colonist)
	if c.state == c.State.ORDERED:
		c.waypoints.clear()

func _say_once(text: String, key: String = "", cooldown: float = 20.0) -> void:
	var k: String = key if key != "" else text
	if _now() - float(_said.get(k, -100.0)) < cooldown:
		return
	_said[k] = _now()
	said_count[k] = int(said_count.get(k, 0)) + 1
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say(text)
