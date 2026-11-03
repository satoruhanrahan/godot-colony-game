extends Node

# THE BUG-BASH (debug only; it never runs in normal play). It plays the colonist systems by script at a high game speed, watches for everything that should never
# happen, and writes the first occurrence of each problem to res://tools/bugbash_log.txt and the console.
#
#   HOW TO RUN (it is a scene of its own, started from the command line; nothing in the game starts it):
#     godot --path . res://tools/bugbash.tscn                         (opens the game window and plays itself)
#     godot --headless --path . res://tools/bugbash.tscn              (no window; the same run)
#   Environment variables (all optional):
#     BB_SCENARIOS=1,2,3,4,5,6,7    which scenarios      BB_STATES=fresh,big    which start states
#     BB_ROLES=lumberjack,sawyer,builder,hauler,farmer,cook   (scenario 1 only)
#     BB_MINUTES=10    game minutes per run (a game minute = 60 clock seconds; a game day is 10 of them)
#     BB_SPEED=5       Engine.time_scale (how much faster than real time)       BB_SEED=1   the random seed
#     BB_LOG=res://tools/bugbash_log.txt    where the log goes                  BB_QUIT=1   quit at the end (default 1)
#     BB_TRACE=1       also logs every job start, every message and a 10-second heartbeat (for chasing a problem down)
#   A full pass is about 20 real minutes with 8 processes side by side (seeds 1 and 2 x fresh/big x [scenario 1] and [scenarios 2-7]; one process runs one log file:
#   give each its own BB_LOG). One run is BB_MINUTES game minutes at BB_SPEED, i.e. 2 real minutes for 10 minutes at the default speed.
#
# SCENARIOS: 1 each role alone with enough work for it, 2 the role changed at random every 20-40 s, 3 the stance changed at random while the scripted player works
# beside him, 4 forced hunger / tiredness / bedtime and the player's own sleep with the fade and the time skip, 5 interruptions (panels, blueprints, designations,
# targets deleted or blocked, the campfire / bed removed), 6 doors and buildings (jobs inside the house and storage, with and without carried things), 7 two-person things
# (pit saw, toolbox carry) with and without Assist.
# START STATES: "fresh" = the game's own start (the starting yard and toolbox, nothing built); "big" = a field, a house with a bed, a storage with a crate, a saw pit, a
# campfire with its stone, a grinding stone, a dough board, a table, a bucket and the creek.
#
# CHECKS (once per frame or once per second; the first occurrence of each problem is printed once with the time, role, task, position and state; every occurrence is
# counted): invisible, stuck, items, claims, jobs, animation, needs, ui, errors. The end of the run prints one OK/FAIL line per category and a total.
# Also checked: a tool (or what he carried) put on the ground by a timeout (the game's "ITEM DROPPED ... N seconds" / "set down beside his house" prints), a reason on the
# hover line that belongs to a job he has left (ui), and, once per world, the placement rule at the map edge ("Too close to the edge." for every outdoor type).
# It uses GameClock's self-check helpers (_c7_*, _c8_*, _c9_*, _c14_*, _c17_*, _c18_*) to build the worlds, so it needs game_clock.gd.

const CATEGORIES: Array = ["invisible", "stuck", "items", "claims", "jobs", "animation", "needs", "ui", "errors"]
const ROLES: Array = [&"lumberjack", &"sawyer", &"builder", &"hauler", &"farmer", &"cook"]
const TOOL_KINDS: Array = [&"axe", &"hammer", &"shovel", &"hoe", &"sickle", &"fire_starter", &"bucket", &"seed_bag", &"dough_board"]
const MAP: Rect2 = Rect2(-16, -16, 672, 672)

var minutes: float = 10.0
var speed: float = 5.0
var scenarios: Array = [1, 2, 3, 4, 5, 6, 7]
var states: Array = ["fresh", "big"]
var roles_s1: Array = ROLES
var log_path: String = "res://tools/bugbash_log.txt"
var quit_at_end: bool = true
var rng := RandomNumberGenerator.new()

var world: Node = null
var clock: Node = null
var friend = null
var player = null
var colony: Node = null
var box = null
var scenario_name: String = ""
var state_name: String = ""
var kit: Dictionary = {}

var counts: Dictionary = {}
var firsts: Dictionary = {}
var by_scenario: Dictionary = {}
var _seen: Dictionary = {}
var _file: FileAccess = null
var _errors_pending: Array = []
var _messages_pending: Array = []
var _mutex := Mutex.new()
var _bug_logger = null
var _t_run: float = 0.0
var _runs: int = 0

# --- per-run bookkeeping for the checks
var _move: Dictionary = {}
var _item_base: Dictionary = {}
var _loose_prev: int = 0
var _claim_since: Dictionary = {}
var _job_starts: Dictionary = {}
var _last_job_id: int = 0
var _idle_for: float = 0.0
var _hidden_since: float = -1.0
var _hidden_state: int = -1
var _said_prev: Dictionary = {}
var _said_at: Dictionary = {}
var _guard_prev: int = 0
var _warn_prev: int = 0
var _sec_left: float = 1.0
var _frame_pos: Vector2 = Vector2.ZERO
var _entering_since: float = -1.0
var _hunger_zero_since: float = -1.0
var _rest_zero_since: float = -1.0
var _stats: Dictionary = {}

class BugLogger extends Logger:
	var owner_node = null
	# (the game's own prints that name a thing dropped by a timer: ColonistTools.drop_here's "ITEM DROPPED ... for N seconds" and the sleep time-out's "set down beside his house")
	func _log_message(message: String, error: bool) -> void:
		if owner_node != null and not error and (message.begins_with("ITEM DROPPED") or message.contains("set down beside his house")):
			owner_node.collect_message(message.strip_edges())
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, backtraces: Array) -> void:
		if owner_node != null:
			var where: String = ""
			for bt in backtraces:
				where += " | " + str(bt).replace("
", " < ")
			owner_node.collect_error(error_type, "%s:%d %s %s%s" % [file.get_file(), line, code, rationale, where])

func collect_message(text: String) -> void:
	_mutex.lock()
	_messages_pending.append(text)
	_mutex.unlock()

func collect_error(error_type: int, text: String) -> void:
	_mutex.lock()
	_errors_pending.append([error_type, text])
	_mutex.unlock()

# --- Logging ---------------------------------------------------------------------------------------------------------------------

func _gtime() -> String:
	if clock == null:
		return "-"
	var tod: float = fposmod(clock.total_seconds(), clock.day_length) / clock.day_length * 24.0
	return "day %d %02d:%02d" % [clock.day, int(tod), int((tod - floorf(tod)) * 60.0)]

func _ctx() -> String:
	if friend == null or not is_instance_valid(friend):
		return "(no friend)"
	var ai = friend.order_ai
	var task: String = friend.orders.tasks_text() if friend.orders != null else ""
	return "%s | %s/%s | %s | role=%s task=[%s] stance=%s pos=(%d,%d) state=%s job='%s' held='%s' carry='%s'" % [_gtime(), scenario_name, state_name, "run %d" % _runs, ",".join(friend.orders.roles.map(func(r) -> String: return String(r))), task, friend.orders.name_now(), int(friend.position.x), int(friend.position.y), friend.State.keys()[friend.state], ai.work_job.describe() if ai.work_job != null else "-", ai.tools.held, ai.carrying.get("kind", &"")]

func _write(line: String) -> void:
	print(line)
	if _file != null:
		_file.store_line(line)
		_file.flush()

func _note(text: String) -> void:
	_write("[bugbash] " + text)

# Counts every occurrence; prints and logs the first of each (category, key) once.
func flag(cat: String, key: String, text: String) -> void:
	counts[cat] = int(counts.get(cat, 0)) + 1
	var bs: Dictionary = by_scenario.get(scenario_name + "/" + state_name, {})
	bs[cat] = int(bs.get(cat, 0)) + 1
	by_scenario[scenario_name + "/" + state_name] = bs
	var id: String = cat + "|" + key
	if _seen.has(id):
		return
	_seen[id] = true
	firsts[cat] = int(firsts.get(cat, 0)) + 1
	_write("PROBLEM [%s] %s\n    %s" % [cat, text, _ctx()])

# --- Start -----------------------------------------------------------------------------------------------------------------------

func _ready() -> void:
	Engine.max_fps = 60
	minutes = float(OS.get_environment("BB_MINUTES")) if OS.get_environment("BB_MINUTES") != "" else 10.0
	speed = float(OS.get_environment("BB_SPEED")) if OS.get_environment("BB_SPEED") != "" else 5.0
	rng.seed = int(OS.get_environment("BB_SEED")) if OS.get_environment("BB_SEED") != "" else 1
	if OS.get_environment("BB_SCENARIOS") != "":
		scenarios = []
		for s in OS.get_environment("BB_SCENARIOS").split(","):
			scenarios.append(int(s))
	if OS.get_environment("BB_STATES") != "":
		states = Array(OS.get_environment("BB_STATES").split(","))
	if OS.get_environment("BB_ROLES") != "":
		roles_s1 = []
		for r in OS.get_environment("BB_ROLES").split(","):
			roles_s1.append(StringName(r))
	if OS.get_environment("BB_LOG") != "":
		log_path = OS.get_environment("BB_LOG")
	quit_at_end = OS.get_environment("BB_QUIT") != "0"
	_file = FileAccess.open(log_path, FileAccess.WRITE)
	_bug_logger = BugLogger.new()
	_bug_logger.owner_node = self
	OS.add_logger(_bug_logger)
	_note("bug-bash start: scenarios %s, states %s, %.0f game minutes each, speed x%.1f, seed %d, log %s" % [str(scenarios), str(states), minutes, speed, rng.seed, log_path])
	await get_tree().create_timer(0.2).timeout
	await _run_all()
	_finish()

func _exit_tree() -> void:
	if _bug_logger != null:
		OS.remove_logger(_bug_logger)
	Engine.time_scale = 1.0

func _run_all() -> void:
	for st in states:
		for sc in scenarios:
			scenario_name = "S%d" % sc
			state_name = st
			match sc:
				1:
					for role in roles_s1:
						scenario_name = "S1-" + String(role)
						await _run_one(st, [role], "roles")
				2:
					await _run_one(st, [], "switching")
				3:
					await _run_one(st, [&"lumberjack", &"builder"], "stances")
				4:
					await _run_one(st, [&"lumberjack", &"farmer"], "needs")
				5:
					await _run_one(st, [&"lumberjack", &"builder", &"farmer", &"cook"], "interruptions")
				6:
					await _run_one(st, [&"builder", &"hauler"], "doors")
				7:
					await _run_one(st, [&"sawyer"], "twoperson")

# --- The worlds --------------------------------------------------------------------------------------------------------------------

func _new_world(st: String) -> void:
	if world != null and is_instance_valid(world):
		world.queue_free()
		world = null
		await get_tree().process_frame
		await get_tree().process_frame
	_runs += 1
	world = load("res://scenes/lumberjack_test.tscn").instantiate()
	if st == "big":
		world.opening_mode = false
	add_child(world)
	await get_tree().create_timer(0.3).timeout
	clock = get_tree().get_first_node_in_group("game_clock")
	friend = get_tree().get_first_node_in_group("colonists")
	player = get_tree().get_first_node_in_group("player")
	colony = get_tree().get_first_node_in_group("colony")
	colony.friend_needs_tools = true
	clock.set_time(clock.day, 0.2)
	player.state = player.State.FREE
	player.hands.clear()
	player.rest.value = 100.0
	player.hunger.value = 100.0
	friend.hunger.value = 100.0
	friend.rest.value = 100.0
	clock._c7_quiet_npcs(world, true)
	# the guards of the game fix what they find: here they only look (the bug-bash reports, it does not hide)
	var vg = get_tree().get_first_node_in_group("colonist_view_guard")
	if vg != null:
		vg.set_process(false)
	kit = {}
	box = get_tree().get_first_node_in_group("toolboxes")
	if st == "big":
		await _build_big()
	if box == null:
		box = clock._c8_box(world, friend.position + Vector2(-40, 30), _standard_tools())
		await get_tree().process_frame
	friend.order_ai.release_all(true)
	friend.orders.clear_work()
	friend.set_stance(0)

func _standard_tools() -> Array:
	return [[&"axe", 0], [&"hammer", 0], [&"shovel", 0], [&"hoe", 0], [&"sickle", 0], [&"fire_starter", 0], [&"bucket", 0], [&"seed_bag", 6]]

func _free(near: Vector2, size: Vector2 = Vector2(70, 50)) -> Vector2:
	var spot: Vector2 = clock._c7_free_spot(near, size)
	if spot == Vector2.INF:
		# (a crowded map: the search finds no place within reach; something placed at INF would send the colonist there, so a wider search, else the nearest point on the map)
		spot = load("res://scripts/ground_placement.gd").find_free_ground_near(get_tree(), near, size, Rect2(0, 0, 640, 640), 600.0)
	if spot == Vector2.INF:
		spot = Vector2(clampf(near.x, 20.0, 620.0), clampf(near.y, 20.0, 620.0))
	return spot

func _build_big() -> void:
	var door: Vector2 = friend.home.door_position() if friend.home != null else friend.position
	box = clock._c8_box(world, _free(door + Vector2(60, 70), Vector2(50, 40)), _standard_tools())
	var m: Node2D = load("res://scripts/plot_manager.gd").get_for(get_tree())
	var origin: Vector2i = clock._c17_field(5, 3)
	kit["field"] = []
	if origin != Vector2i(-1, -1):
		for c in clock._c17_cells(origin, 5, 3):
			m.set_farm(c)
			kit["field"].append(c)
	kit["kitchen"] = await clock._c18_kitchen(world, 12, true, 4, 2, true)
	kit["storage"] = clock._c7_storage(world, _free(door + Vector2(120, 100), Vector2(70, 60)))
	kit["storage"].add_planks(6)
	kit["pit"] = clock._c14_pit(world, _free(door + Vector2(-120, 110), Vector2(70, 60)))
	kit["house"] = clock._c9_house(world, _free(door + Vector2(-150, 40), Vector2(80, 70)))
	var room: Node2D = kit["house"].get_interior()
	var bed = load("res://scenes/Building.tscn").instantiate()
	bed.building_type = load("res://assets/wooden_bed_type.tres")
	bed.position = room.to_world(Vector2(44, 100))
	world.add_child(bed)
	bed.planks_ready = bed.plank_cost
	bed.finish_building()
	await get_tree().process_frame
	kit["bed"] = bed
	friend.position = _free(door + Vector2(20, 60), Vector2(30, 30))

# --- One run ----------------------------------------------------------------------------------------------------------------------

func _run_one(st: String, roles: Array, kind: String) -> void:
	state_name = st
	await _new_world(st)
	Engine.time_scale = speed
	for r in roles:
		friend.orders.toggle_role(r)
	_play_roles = roles if kind != "switching" else ROLES
	_morning_at = -1.0
	_carry_end_at = -1.0
	_panel_end_at = -1.0
	_panel_hold = false
	_placed_bps = []
	_reset_checks()
	var start: float = clock.total_seconds()
	var until: float = start + minutes * 60.0
	_note("run %d: %s on the %s start, roles %s" % [_runs, scenario_name, st, str(roles)])
	_t_run = 0.0
	var next_supply: float = 0.0
	var next_event: float = rng.randf_range(20.0, 40.0)
	var real0: int = Time.get_ticks_msec()
	while clock.total_seconds() < until:
		await get_tree().process_frame
		# (The sleep skip hands the speed back as the game had it, 1x, when the player wakes: the bug-bash takes its own speed again.)
		var ff: Node = get_node_or_null("/root/FastForward")
		if (ff == null or not ff.locked) and not is_equal_approx(Engine.time_scale, speed):
			Engine.time_scale = speed
		var delta: float = get_process_delta_time()
		_t_run += delta
		_check_frame(delta)
		_sec_left -= delta
		if _sec_left <= 0.0:
			_sec_left = 1.0
			_check_second()
		if _t_run >= next_supply:
			next_supply = _t_run + 25.0
			await _supply()
		if _t_run >= next_event:
			await _drive(kind)
			next_event = _t_run + _event_gap(kind)
		_script_player(kind, delta)
		if friend.dead:
			flag("needs", "friend dead", "the friend died (hunger %.0f rest %.0f)" % [friend.hunger.value, friend.rest.value])
			break
		if OS.get_environment("BB_TRACE") != "" and Time.get_ticks_msec() - _beat > 10000:
			_beat = Time.get_ticks_msec()
			_note("beat: clock %.1f speed x%.2f scale %.1f paused %s player %d friend %d hidden %s" % [clock.total_seconds(), clock.clock_speed_multiplier, Engine.time_scale, get_tree().paused, player.state, friend.state, str(friend.hidden_by.keys())])
		if Time.get_ticks_msec() - real0 > 40 * 60 * 1000:
			_note("run stopped: 40 real minutes")
			break
	Engine.time_scale = 1.0
	_collect_errors()
	_note("run %d done: %.0f game seconds in %.0f real seconds" % [_runs, clock.total_seconds() - start, (Time.get_ticks_msec() - real0) / 1000.0])
	_stats[scenario_name + "/" + st] = {"game_s": clock.total_seconds() - start}

func _event_gap(kind: String) -> float:
	match kind:
		"switching":
			return rng.randf_range(20.0, 40.0)
		"stances":
			return rng.randf_range(8.0, 20.0)
		"needs":
			return rng.randf_range(25.0, 50.0)
		"interruptions":
			return rng.randf_range(6.0, 15.0)
		"doors", "twoperson":
			return rng.randf_range(15.0, 30.0)
	return 9999.0

func _finish() -> void:
	Engine.time_scale = 1.0
	_collect_errors()
	_write("")
	_write("[bugbash] === RESULT (%d runs) ===" % _runs)
	var total: int = 0
	var distinct: int = 0
	var failed: int = 0
	for cat in CATEGORIES:
		var n: int = int(counts.get(cat, 0))
		var d: int = int(firsts.get(cat, 0))
		total += n
		distinct += d
		if d > 0:
			failed += 1
		_write("SELF-CHECK: %-10s %s (%d distinct problems, %d occurrences)" % [cat, "OK" if d == 0 else "FAIL", d, n])
	_write("SELF-CHECK: total %d categories failing of %d; %d distinct problems; %d occurrences" % [failed, CATEGORIES.size(), distinct, total])
	_write("[bugbash] per scenario (category: occurrences): " + str(by_scenario))
	if _file != null:
		_file.close()
		_file = null
	if quit_at_end:
		get_tree().quit()

func _collect_errors() -> void:
	_mutex.lock()
	var list: Array = _errors_pending.duplicate()
	_errors_pending.clear()
	var messages: Array = _messages_pending.duplicate()
	_messages_pending.clear()
	_mutex.unlock()
	# a tool (or what he carried) put on the ground by a timeout is never right: it stays in his hands
	for m in messages:
		var text_m: String = String(m)
		if text_m.begins_with("ITEM DROPPED") and not text_m.contains(" seconds"):
			continue
		flag("items", "timeout drop:" + text_m.substr(0, 80), "dropped by a timeout: " + text_m.substr(0, 300))
	for e in list:
		var kind: String = ["error", "warning", "script error", "shader error"][clampi(int(e[0]), 0, 3)]
		var text: String = String(e[1])
		# the warnings that are the game's own polite notes about missing art are listed apart, not counted as problems
		if int(e[0]) == 1 and (text.contains("CharacterAnimator: no animation") or text.contains("the player has none yet")):
			_note("missing art (once): " + text)
			continue
		flag("errors", kind + ": " + text.substr(0, 120), "%s: %s" % [kind, text.substr(0, 900)])

# --- The checks --------------------------------------------------------------------------------------------------------------------

func _reset_checks() -> void:
	_check_edge_rule()
	_move = {"pos": friend.position, "since": 0.0, "key": ""}
	_item_base = _count_items()
	_loose_prev = _loose_ids().size()
	_loose_ids_prev = _loose_ids()
	_claim_since = {}
	_job_starts = {}
	_last_job_id = 0
	_idle_for = 0.0
	_hidden_since = -1.0
	_said_prev = {}
	_said_at = {}
	_guard_prev = 0
	_entering_since = -1.0
	_hunger_zero_since = -1.0
	_rest_zero_since = -1.0
	_overlay_bad = 0
	_anim_bad = 0
	_status_bad = 0
	_pit_bad = 0
	_stale_status_since = -1.0
	_swept_prev = 0
	_stuck_events_prev = friend.order_ai.stuck_events
	_stuck_events_t = 0.0
	var gd = get_tree().get_first_node_in_group("held_item_guard")
	_guard_prev = gd.violations if gd != null else 0
	_warn_prev = CharacterAnimator.warnings_given
	_t_sec = 0.0

var _loose_ids_prev: Dictionary = {}
var _overlay_bad: int = 0
var _anim_bad: int = 0
var _status_bad: int = 0
var _pit_bad: int = 0
var _stale_status_since: float = -1.0
var _swept_prev: int = 0
var _stuck_events_prev: int = 0
var _stuck_events_t: float = 0.0
var _t_sec: float = 0.0
var _supplied_ids: Dictionary = {}

# Every tool-like thing in the world, held or stored, by kind.
func _count_items() -> Dictionary:
	var out: Dictionary = {}
	for k in TOOL_KINDS:
		out[k] = 0
	for g in ["hammers", "shovels", "axes"]:
		var kind: StringName = {"hammers": &"hammer", "shovels": &"shovel", "axes": &"axe"}[g]
		for n in get_tree().get_nodes_in_group(g):
			if not n.is_queued_for_deletion():
				out[kind] += 1
	for it in get_tree().get_nodes_in_group("ground_items"):
		if out.has(it.kind) and not it.is_queued_for_deletion():
			out[it.kind] += 1
	for b in get_tree().get_nodes_in_group("dough_boards"):
		if not b.is_queued_for_deletion():
			out[&"dough_board"] += 1
	for tb in get_tree().get_nodes_in_group("toolboxes"):
		for e in tb.contents:
			if out.has(e["kind"]):
				out[e["kind"]] += int(e.get("count", 1))
	for crate in get_tree().get_nodes_in_group("crates"):
		out[&"seed_bag"] += crate.bags.size()
	if friend != null and out.has(friend.order_ai.tools.held):
		out[friend.order_ai.tools.held] += 1
	if player != null and out.has(player.held_tool):
		out[player.held_tool] += 1
	return out

func _rebase_items() -> void:
	_item_base = _count_items()
	_loose_ids_prev = _loose_ids()

# The loose tools lying in the world (their instance ids).
func _loose_ids() -> Dictionary:
	var out: Dictionary = {}
	for g in ["hammers", "shovels", "axes"]:
		for n in get_tree().get_nodes_in_group(g):
			if not n.is_queued_for_deletion():
				out[n.get_instance_id()] = {"kind": g, "pos": n.global_position}
	for it in get_tree().get_nodes_in_group("ground_items"):
		if TOOL_KINDS.has(it.kind) and not it.is_queued_for_deletion() and not (it.get_parent() != null and it.get_parent().is_in_group("tables")):
			out[it.get_instance_id()] = {"kind": it.kind, "pos": it.global_position}
	return out

func _in_interior(p: Vector2) -> bool:
	return p.x >= 2000.0

func _asleep_or_hidden_ok() -> bool:
	return friend.state in [friend.State.INSIDE, friend.State.ON_BED, friend.State.ENTERING, friend.State.SLEEPING_OUTSIDE]

func _check_frame(delta: float) -> void:
	if friend == null or not is_instance_valid(friend) or friend.dead:
		return
	# --- invisible or missing
	var vg = get_tree().get_first_node_in_group("colonist_view_guard")
	if vg != null:
		var why: String = vg.problem(friend)
		if why != "":
			flag("invisible", "view:" + why.split(" ")[0] + ":" + str(friend.State.keys()[friend.state]), why)
	if not friend.position.is_finite():
		flag("invisible", "position not finite", "his position is %s" % str(friend.position))
	elif not MAP.has_point(friend.position) and not _in_interior(friend.position):
		flag("invisible", "outside map", "he is outside the map at (%d, %d)" % [friend.position.x, friend.position.y])
	if friend.state == friend.State.ENTERING:
		if _entering_since < 0.0:
			_entering_since = _t_run
		elif _t_run - _entering_since > 8.0:
			flag("invisible", "frozen entering", "stuck in the door transition (ENTERING) for %d s" % int(_t_run - _entering_since))
	else:
		_entering_since = -1.0
	# a hide that outlasts its reason is the guard's business; one that just goes on for ever while he awake and "working" is a freeze
	if not friend.visible and not _asleep_or_hidden_ok():
		if _hidden_since < 0.0 or _hidden_state != friend.state:
			_hidden_since = _t_run
			_hidden_state = friend.state
		elif _t_run - _hidden_since > 90.0 * 1.0:
			flag("invisible", "long hide", "hidden for %d s in state %s (hidden_by %s)" % [int(_t_run - _hidden_since), friend.State.keys()[friend.state], str(friend.hidden_by.keys())])
	else:
		_hidden_since = -1.0

func _check_second() -> void:
	if friend == null or not is_instance_valid(friend) or friend.dead:
		return
	_collect_errors()
	var ai = friend.order_ai
	var t_now: float = Time.get_ticks_msec() / 1000.0
	# --- stuck
	_check_stuck(ai)
	# repeated messages
	for key in ai.said_count.keys():
		var n: int = int(ai.said_count[key])
		if n > int(_said_prev.get(key, 0)):
			var last: float = float(_said_at.get(key, -1000.0))
			if _t_run - last < 30.0 * 1.0 and last > 0.0:
				flag("stuck", "repeat:" + str(key), "the message '%s' was said again after %d s" % [str(key), int(_t_run - last)])
			_said_at[key] = _t_run
			_said_prev[key] = n
	# --- items
	var now: Dictionary = _count_items()
	for k in TOOL_KINDS:
		if int(now[k]) != int(_item_base.get(k, 0)):
			flag("items", "count:%s:%d>%d" % [k, int(_item_base.get(k, 0)), int(now[k])], "the number of %s went from %d to %d (held + lying + stored)" % [k, int(_item_base.get(k, 0)), int(now[k])])
			_item_base[k] = now[k]
	var gd = get_tree().get_first_node_in_group("held_item_guard")
	if gd != null and gd.violations > _guard_prev:
		flag("items", "guard:" + gd.last_message.substr(0, 60), "held-item guard: " + gd.last_message)
		_guard_prev = gd.violations
	var loose: Dictionary = _loose_ids()
	for id in loose.keys():
		if not _loose_ids_prev.has(id) and not _supplied_ids.has(id):
			var d: float = (loose[id]["pos"] as Vector2).distance_to(friend.position)
			if d < 120.0 and friend.order_ai.tools.held == &"":
				flag("items", "dropped:" + str(loose[id]["kind"]), "a %s now lies on the ground at (%d, %d), %d px from him, and he holds nothing: dropped or left behind" % [loose[id]["kind"], loose[id]["pos"].x, loose[id]["pos"].y, d])
	_loose_ids_prev = loose
	if ai.hands.count() > 1 or (ai.tools.held != &"" and not ai.carrying.is_empty()):
		flag("items", "two items", "he holds more than one thing: tool '%s', carrying '%s', log %s" % [ai.tools.held, str(ai.carrying), str(ai.dragger.is_dragging())])
	# held item vs animation
	_check_animation(ai)
	# --- claims
	_check_claims(ai)
	# --- jobs
	_check_jobs(ai)
	# --- needs
	_check_needs()
	# --- ui
	_check_ui(ai)

func _check_stuck(ai) -> void:
	var s = friend.State
	var moving_state: bool = friend.state in [s.WALKING, s.MOVING_IN, s.RETURNING, s.TO_BED, s.TO_SLEEP_SPOT, s.TO_BUSH, s.TO_CRATE]
	var job_moving: bool = false
	if friend.state == s.ORDERED and ai.work_job != null and not ai.working and not friend.animator.in_work:
		var ph: String = str(ai.work_job.get("phase")) if "phase" in ai.work_job else ""
		job_moving = not (ph in ["wait", "inside", "crate", "free", "act", "work", "press", "thresh"])
	var key: String = "%s/%s" % [friend.State.keys()[friend.state], ai.work_job.describe() if ai.work_job != null else "-"]
	if (moving_state or job_moving) and friend.visible:
		if friend.position.distance_to(_move["pos"]) > 1.0 or _move["key"] != key:
			_move = {"pos": friend.position, "since": _t_run, "key": key}
		elif _t_run - float(_move["since"]) > 15.0:
			flag("stuck", "nomove:" + key, "no position change for %d s while the state says moving: %s" % [int(_t_run - float(_move["since"])), key])
			_move["since"] = _t_run
	else:
		_move = {"pos": friend.position, "since": _t_run, "key": key}
	# endless path retries
	if ai.stuck_events - _stuck_events_prev > 20 and _t_run - _stuck_events_t < 60.0:
		flag("stuck", "retries", "%d path retries (stuck events) within a minute" % (ai.stuck_events - _stuck_events_prev))
	if _t_run - _stuck_events_t >= 60.0:
		_stuck_events_t = _t_run
		_stuck_events_prev = ai.stuck_events

func _check_animation(ai) -> void:
	if friend.animator.in_work or _asleep_or_hidden_ok() or friend.state == friend.State.HELPING_CARRY or not friend.visible:
		_anim_bad = 0
		return
	var held: Dictionary = friend.carry_state()
	var frames: SpriteFrames = friend.sprite_frames
	var want_walk: StringName = CharacterAnimator.walk_name(frames, held)
	var want_idle: StringName = CharacterAnimator.idle_name(frames, held)
	var anim: StringName = friend.animation
	var standing_pics: Array = [&"walk", &"idle", want_walk, want_idle]
	if not (anim in standing_pics) and not String(anim).begins_with("carry_"):
		_anim_bad += 1
	elif anim != want_walk and anim != want_idle and String(anim).begins_with("carry_"):
		_anim_bad += 1
	else:
		_anim_bad = 0
	if _anim_bad >= 3:
		flag("animation", "mismatch:%s>%s" % [anim, want_walk], "the animation '%s' does not match what he holds (expects '%s' / '%s')" % [anim, want_walk, want_idle])
	# the little picture above his head must not be drawn on top of an animation that already shows the item
	if ai.carry_sprite != null and ai.carry_sprite.visible:
		if not CharacterAnimator.needs_overlay(anim, friend.carried_state()):
			_overlay_bad += 1
			if _overlay_bad >= 2:
				flag("animation", "overlay twice:" + str(anim), "the overlay is shown while the animation '%s' already shows the item (drawn twice)" % anim)
		else:
			_overlay_bad = 0
	else:
		_overlay_bad = 0
	# poses: the pit saw and the bed
	for pit in get_tree().get_nodes_in_group("pit_saws"):
		var pose_hidden: bool = friend.hidden_by.has(&"pose")
		if pose_hidden and pit.state != pit.State.SAWING:
			_pit_bad += 1
			if _pit_bad >= 3:
				flag("animation", "pose without saw", "he is hidden by the saw pose but the pit saw is not sawing (state %s)" % str(pit.State.keys()[pit.state]))
		else:
			_pit_bad = 0
	if friend.state == friend.State.ON_BED and friend.visible and friend.animation != &"asleep":
		flag("animation", "bed pose", "he lies on a bed but shows '%s' instead of the asleep picture" % friend.animation)

func _check_claims(ai) -> void:
	# a tool reservation (the toolbox shows "Reserved by Friend") with no job behind it for several seconds
	if ai.tools.reserving() and ai.work_job == null and ai.job.is_empty() and ai.assist_cook == null and friend.state == friend.State.ORDERED:
		_res_orphan += 1
		if _res_orphan >= 6:
			flag("claims", "tool reservation orphan", "a toolbox reservation (%s) is held with no job behind it for %d s" % [str(ai.tools._res.get("kind", "")), _res_orphan])
	else:
		_res_orphan = 0
	var m: Node2D = load("res://scripts/plot_manager.gd").get_for(get_tree())
	var job = ai.work_job
	var now_t: float = _t_run
	var current: Dictionary = {}
	# claims of freed holders
	for c in m.claims.keys():
		var holder = m.claims[c]
		if not is_instance_valid(holder):
			flag("claims", "freed holder", "a plot cell claim of a freed colonist stays at %s" % str(c))
		elif holder == friend:
			var ok: bool = (job != null and "cell" in job and job.cell == c) or (not ai.job.is_empty() and ai.job.get("cell") == c)
			current["cell%s" % str(c)] = true
			if not ok:
				_claim_orphans["cell%s" % str(c)] = int(_claim_orphans.get("cell%s" % str(c), 0)) + 1
				if _claim_orphans["cell%s" % str(c)] >= 4:
					flag("claims", "cell orphan", "he holds the claim on plot cell %s but is not working it" % str(c))
			else:
				_claim_orphans.erase("cell%s" % str(c))
	for t in get_tree().get_nodes_in_group("trees"):
		if t.claimed_by == friend or t.log_claimed_by == friend:
			var id: String = "tree%d" % t.get_instance_id()
			current[id] = true
			var ok2: bool = (job != null and "tree_node" in job and job.tree_node == t) or (not ai.job.is_empty() and ai.job.get("target") == t) or ai.drag_tree == t or ai.dragger.is_dragging()
			if not ok2:
				_claim_orphans[id] = int(_claim_orphans.get(id, 0)) + 1
				if _claim_orphans[id] >= 4:
					flag("claims", "tree orphan", "he holds the claim on a tree at (%d, %d) but his job is '%s'" % [t.position.x, t.position.y, job.describe() if job != null else "none"])
			else:
				_claim_orphans.erase(id)
		elif (t.claimed_by != null and not is_instance_valid(t.claimed_by)):
			flag("claims", "tree freed holder", "a tree is claimed by a freed object")
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.get("claimed_by") == friend:
			var id2: String = "bp%d" % b.get_instance_id()
			current[id2] = true
			var ok3: bool = job != null and "bp" in job and job.bp == b
			if not ok3:
				_claim_orphans[id2] = int(_claim_orphans.get(id2, 0)) + 1
				if _claim_orphans[id2] >= 4:
					flag("claims", "blueprint orphan", "he holds the claim on a blueprint but his job is '%s'" % (job.describe() if job != null else "none"))
			else:
				_claim_orphans.erase(id2)
	for g in ["grinding_stones", "dough_boards", "campfires", "tables"]:
		for n in get_tree().get_nodes_in_group(g):
			if n.has_meta(&"cook_reserved_by") and n.get_meta(&"cook_reserved_by") == friend:
				var id3: String = "res%d" % n.get_instance_id()
				current[id3] = true
				var ok4: bool = (job != null and "stone" in job and (job.stone == n or job.board == n or job.fire == n or job.table == n)) or (ai.assist_cook != null and (ai.assist_cook.stone == n or ai.assist_cook.board == n or ai.assist_cook.fire == n or ai.assist_cook.table == n))
				if not ok4:
					_claim_orphans[id3] = int(_claim_orphans.get(id3, 0)) + 1
					if _claim_orphans[id3] >= 4:
						flag("claims", "station reserve orphan", "a %s is reserved for him but no cook job uses it" % g)
				else:
					_claim_orphans.erase(id3)
			elif n.has_meta(&"cook_reserved_by") and n.get_meta(&"cook_reserved_by") != null and not is_instance_valid(n.get_meta(&"cook_reserved_by")):
				flag("claims", "station freed holder", "a %s is reserved for a freed colonist" % g)
	# a claim held for over a minute with no progress at all
	for id4 in current.keys():
		if not _claim_since.has(id4):
			_claim_since[id4] = {"t": now_t, "strikes": ai.strikes, "pos": friend.position}
		else:
			var rec: Dictionary = _claim_since[id4]
			if ai.strikes != rec["strikes"] or friend.position.distance_to(rec["pos"]) > 4.0 or _asleep_or_hidden_ok():
				_claim_since[id4] = {"t": now_t, "strikes": ai.strikes, "pos": friend.position}
			elif now_t - float(rec["t"]) > 60.0 and not (friend.state in [friend.State.HELPING_CARRY, friend.State.AT_WORK]) and not ai.working:
				flag("claims", "no progress:" + id4.substr(0, 5), "a claim (%s) has been held for %d s with no progress" % [id4, int(now_t - float(rec["t"]))])
				_claim_since[id4] = {"t": now_t, "strikes": ai.strikes, "pos": friend.position}
	for id5 in _claim_since.keys():
		if not current.has(id5):
			_claim_since.erase(id5)

var _claim_orphans: Dictionary = {}
var _res_orphan: int = 0
var _trace_fail: String = ""
var _beat: int = 0
var _msg_until: float = -1.0

# (A job that carries another one: where that one is going, for the trace.)
func _trace_inner(job) -> String:
	var inner = job.get("inner")
	if inner == null:
		inner = job
	var room = inner.get("_room")
	return " | %s room_spot %s hand_over %s door %s" % [inner.get("phase"), str(inner.get("_room_spot")), str(inner._hand_over_spot()) if inner.has_method("_hand_over_spot") else "-", str(room.door_world()) if room != null and is_instance_valid(room) else "-"]

func _check_jobs(ai) -> void:
	var job = ai.work_job
	if OS.get_environment("BB_TRACE") != "" and ai.fail_text != _trace_fail:
		_trace_fail = ai.fail_text
		_note("trace: message '%s' at %s" % [ai.fail_text, _gtime()])
	if job != null and job.get_instance_id() != _last_job_id:
		_last_job_id = job.get_instance_id()
		var d: String = job.describe() + "#" + str(job.get("target").get_instance_id() if job.get("target") != null and is_instance_valid(job.get("target")) else 0)
		if OS.get_environment("BB_TRACE") != "":
			_note("trace: job '%s' (%s) target %s at %s, pos (%.1f,%.1f)%s" % [d, job.get_script().get_global_name() if job.get_script() != null else "?", str(job.get("target")), _gtime(), friend.position.x, friend.position.y, _trace_inner(job)])
		var rec: Array = _job_starts.get(d, [])
		rec.append({"t": _t_run, "strikes": ai.strikes})
		var recent: Array = rec.filter(func(r) -> bool: return _t_run - float(r["t"]) < 60.0)
		_job_starts[d] = recent
		if recent.size() > 5 and int(recent[-1]["strikes"]) == int(recent[0]["strikes"]):
			flag("jobs", "restart:" + d, "the job '%s' was started %d times in a minute without a single strike" % [d, recent.size()])
	# idle with work available
	var idle_ok: bool = friend.state in [friend.State.IDLE, friend.State.WALKING, friend.State.ORDERED, friend.State.FOLLOWING]
	var msg_fresh: bool = ai.fail_text != "" and Time.get_ticks_msec() / 1000.0 < ai.fail_until
	if idle_ok and job == null and friend.orders.stance == friend.Orders.Stance.FREE and not friend.orders.roles.is_empty() and not _asleep_or_hidden_ok() and friend.hunger.value > 40.0 and friend.rest.value > 25.0 and clock.is_daytime():
		var avail: String = _work_available()
		if avail != "" and not msg_fresh and ai.carrying.is_empty() and ai.tools.held == &"":
			_idle_for += 1.0
			if _idle_for >= 30.0:
				flag("jobs", "idle:" + avail, "he idles 30 s with work available (%s) and no message" % avail)
				_idle_for = 0.0
		else:
			_idle_for = 0.0
	else:
		_idle_for = 0.0
	# a message that is not the real reason
	if msg_fresh:
		_check_message(ai)

func _work_available() -> String:
	var tree: SceneTree = get_tree()
	for role in friend.orders.roles:
		match role:
			&"lumberjack":
				for t in tree.get_nodes_in_group("trees"):
					if (t.is_standing() or t.is_felled()) and t.claimed_by == null and t.global_position.distance_to(friend.position) <= 230.0 and not friend.order_ai.is_skipped(t):
						if friend.order_ai.tools.source_for(&"axe")["type"] != "none" or friend.order_ai.tools.held == &"axe":
							return "lumberjack: a tree"
			&"sawyer":
				for p in tree.get_nodes_in_group("pit_saws"):
					if p.is_built() and p.state == p.State.EMPTY and not load("res://scripts/logistics.gd").loose_logs(tree).is_empty():
						return "sawyer: a log for the pit saw"
			&"builder":
				for b in load("res://scripts/logistics.gd").blueprints(tree):
					if b.is_supplied() and b.claimed_by == null and not friend.order_ai.is_skipped(b) and friend.order_ai.tools.source_for(&"hammer")["type"] != "none":
						return "builder: a supplied blueprint"
			&"farmer":
				var m: Node2D = load("res://scripts/plot_manager.gd").get_for(tree)
				for c in m.farm_cells.keys():
					var need: StringName = load("res://scripts/farm_jobs.gd").cell_need(m, c)
					if need == &"harvest" or need == &"till":
						var item: StringName = load("res://scripts/farm_jobs.gd").ITEM_OF[need]
						if friend.order_ai.tools.source_for(item)["type"] != "none" and not m.is_claimed(c) and not load("res://scripts/farm_jobs.gd").skipped(friend.order_ai, c) and not load("res://scripts/farm_jobs.gd").skipped(friend.order_ai, need):
							return "farmer: a cell to " + String(need)
			&"cook":
				var t: Dictionary = load("res://scripts/cook_jobs.gd").tally(tree)
				if int(t["stone_bread"]) > 0 or int(t["board_dough"]) > 0:
					return "cook: bread or dough waiting"
	return ""

func _check_message(ai) -> void:
	var text: String = ai.fail_text
	var tree: SceneTree = get_tree()
	if text.begins_with("No ") and text.ends_with(" available.") or (text.begins_with("No ") and text.contains(" in the toolbox.")):
		var kind_s: String = text.substr(3).split(" ")[0]
		var kind: StringName = StringName(kind_s.replace(" ", "_"))
		if ["axe", "hammer", "shovel", "hoe", "sickle"].has(kind_s) and ai.tools.source_for(kind)["type"] != "none":
			flag("jobs", "msg:" + text, "he says '%s' but the %s can be had (%s)" % [text, kind_s, ai.tools.source_for(kind)["type"]])
	if text == "Hands full" and ai.hands.is_empty():
		flag("jobs", "msg:hands", "he says 'Hands full' with empty hands")
	if text == "No wheat":
		var t: Dictionary = load("res://scripts/cook_jobs.gd").tally(tree)
		if int(t["wheat"]) > 0:
			flag("jobs", "msg:wheat", "he says 'No wheat' but %d sheaves are about" % int(t["wheat"]))
	# 'Nowhere to store it.' stays on the hover line for 10 s whatever job he starts after it: judged once, when it is new, against everything he could have been
	# trying to store (a plank, a loose item, a log): it is wrong only when every one of them has a place.
	if text == "Nowhere to store it." and ai.fail_until != _msg_until and _now_ai(ai) < ai.fail_until:
		_msg_until = ai.fail_until
		var Logistics = load("res://scripts/logistics.gd")
		var homeless: bool = false
		if not Logistics.free_piles(tree).is_empty() and Logistics.plank_destination(tree, friend.position).is_empty():
			homeless = true
		if not Logistics.loose_logs(tree).is_empty() and Logistics.log_destination(tree, friend.position, true).is_empty():
			homeless = true
		for item in Logistics.crate_items(tree):
			if Logistics.item_destination(tree, item.kind, friend.position).is_empty():
				homeless = true
		if not homeless:
			flag("jobs", "msg:storage", "he says 'Nowhere to store it.' but every plank, item and log about has a place (job '%s')" % (ai.work_job.describe() if ai.work_job != null else "-"))

func _now_ai(ai) -> float:
	return ai._now()

func _check_needs() -> void:
	var tree: SceneTree = get_tree()
	var s = friend.State
	if friend.hunger.value <= 0.5:
		if _hunger_zero_since < 0.0:
			_hunger_zero_since = _t_run
		var food: bool = false
		for b in tree.get_nodes_in_group("berry_bushes"):
			if b.is_ripe():
				food = true
		for c in tree.get_nodes_in_group("crates"):
			if c.has_food():
				food = true
		if food and _t_run - _hunger_zero_since > 6.0 and not (friend.state in [s.TO_BUSH, s.EATING, s.TO_CRATE, s.EATING_CRATE]):
			flag("needs", "hunger zero", "hunger is 0 for %d s with food about and he is not eating" % int(_t_run - _hunger_zero_since))
	else:
		_hunger_zero_since = -1.0
	if friend.rest.value <= 0.5:
		if _rest_zero_since < 0.0:
			_rest_zero_since = _t_run
		# (Starving, food comes before bed, and a meal he set out for is finished even when his energy ran out meanwhile: eating is allowed for 90 s.)
		var eating: bool = friend.state in [s.TO_BUSH, s.EATING, s.TO_CRATE, s.EATING_CRATE] and _t_run - _rest_zero_since <= 90.0
		if _t_run - _rest_zero_since > 12.0 and not eating and not _asleep_or_hidden_ok() and friend.state != s.TO_BED and friend.state != s.RETURNING and friend.state != s.TO_SLEEP_SPOT:
			flag("needs", "rest zero", "energy is 0 for %d s and he is not sleeping or on his way to bed" % int(_t_run - _rest_zero_since))
	else:
		_rest_zero_since = -1.0

# The placement rule at the edge of the map (once per world): the spot in front of a new building is a cell inside the map, else red with 'Too close to the edge.'.
func _check_edge_rule() -> void:
	var bm: Node = world.get_node_or_null("BuildMode") if world != null else null
	if bm == null:
		return
	if OS.get_environment("BB_TRACE") != "":
		_note("edge rule: %d building types" % bm.building_types.size())
	for type in bm.building_types:
		if type.indoor_only:
			continue
		var low: Dictionary = bm.check_outdoor(type, Vector2(320, 590), false)
		if low["ok"] or low["text"] != "Too close to the edge.":
			flag("ui", "edge rule low:" + type.type_name, "a %s at the bottom edge (front spot at y 621) is '%s' (%s), not 'Too close to the edge.'" % [type.type_name, "ok" if low["ok"] else "red", low["text"]])
		var side: Dictionary = bm.check_outdoor(type, Vector2(30, 300), false)
		if side["ok"] or side["text"] != "Too close to the edge.":
			flag("ui", "edge rule side:" + type.type_name, "a %s at the left edge (front spot at x 30) is '%s' (%s), not 'Too close to the edge.'" % [type.type_name, "ok" if side["ok"] else "red", side["text"]])
		var inside: Dictionary = bm.check_outdoor(type, Vector2(320, 570), false)
		if inside["text"] == "Too close to the edge.":
			flag("ui", "edge rule inside:" + type.type_name, "a %s with its front spot at y 601 (inside the margin) is refused as too close to the edge" % type.type_name)

func _check_ui(ai) -> void:
	# a reason on his hover line that was given on a job other than the one he is on (it goes when a different job starts)
	if ai.fail_text != "" and _now_ai(ai) < ai.fail_until and ai.work_job != null and ai.fail_for != ai.work_job.get_instance_id() and friend.hover_note().contains(ai.fail_text):
		flag("ui", "stale reason:" + ai.fail_text, "the hover line still says '%s' while he is on '%s', a different job" % [ai.fail_text, ai.work_job.describe()])
	# a status that names a job he is not doing
	var verbs: Array = ["Chopping", "Delimbing", "Hauling", "Hammering", "Digging", "Sowing", "Tilling", "Watering", "Harvesting", "Grinding", "Making dough", "Lighting", "Taking the bread", "Bringing", "Sawing", "Carrying", "Putting"]
	var shown: String = friend.status_text()
	if friend.state == friend.State.ORDERED and ai.work_job == null and ai.assist_cook == null and ai.job.is_empty():
		var named: bool = false
		for v in verbs:
			if shown.begins_with(v):
				named = true
		if named:
			if _stale_status_since < 0.0:
				_stale_status_since = _t_run
			elif _t_run - _stale_status_since > 4.0:
				flag("ui", "stale status", "the status says '%s' but he has no job" % shown)
		else:
			_stale_status_since = -1.0
	else:
		_stale_status_since = -1.0
	if friend.state == friend.State.ORDERED and ai.work_job != null and (shown == "Waiting" or shown == "Free time" or shown == "Resting"):
		_status_bad += 1
		if _status_bad >= 4:
			flag("ui", "status vs job", "the status says '%s' while his job is '%s'" % [shown, ai.work_job.describe()])
	else:
		_status_bad = 0
	if _asleep_or_hidden_ok() and friend.state != friend.State.ENTERING and not (shown in ["Resting", "Sleeping outside, no free bed"]):
		flag("ui", "asleep status", "he is asleep (%s) but the status says '%s'" % [friend.State.keys()[friend.state], shown])
	# the panel text must be the status
	if friend.orders_panel != null and friend.orders_panel.is_open and is_instance_valid(friend.orders_panel._status):
		if friend.orders_panel._status.text != shown and friend.orders_panel._status.text != "":
			_panel_bad += 1
			if _panel_bad >= 3:
				flag("ui", "panel status", "the Orders panel shows '%s' but he is '%s'" % [friend.orders_panel._status.text, shown])
		else:
			_panel_bad = 0
	# leftover designation icons: a mark whose target is gone or done, found by the manager's own sweep
	var mode: Node = get_tree().get_first_node_in_group("designation_mode")
	if mode != null and mode.swept_total > _swept_prev:
		flag("ui", "stale mark swept", "the designation sweep had to remove %d stale mark(s)" % (mode.swept_total - _swept_prev))
		_swept_prev = mode.swept_total
	# panels that do not close: nothing open should be left open when no event holds one
	if not _panel_hold and ((friend.orders_panel != null and friend.orders_panel.is_open) or (box != null and is_instance_valid(box) and box.is_open)):
		_panel_left += 1
		if _panel_left >= 12:
			flag("ui", "panel left open", "a panel stayed open for %d s after the event that opened it" % _panel_left)
	else:
		_panel_left = 0

var _panel_bad: int = 0
var _panel_left: int = 0
var _panel_hold: bool = false

# --- Work for the roles ------------------------------------------------------------------------------------------------------------

var _play_roles: Array = []
var _morning_at: float = -1.0
var _carry_end_at: float = -1.0
var _event_n: int = 0
var _player_t: float = 0.0
var _pit_t: float = 0.0
var _panel_end_at: float = -1.0
var _placed_bps: Array = []

func _plots() -> Node2D:
	return load("res://scripts/plot_manager.gd").get_for(get_tree())

# Keeps enough work about for the roles in play, so a role never idles for want of anything to do.
func _supply() -> void:
	var tree: SceneTree = get_tree()
	var Logistics = load("res://scripts/logistics.gd")
	var here: Vector2 = friend.position
	if _morning_at > 0.0 and _t_run >= _morning_at:
		_morning_at = -1.0
		clock.set_time(clock.day, 0.2)
	if _play_roles.has(&"lumberjack"):
		var standing: int = tree.get_nodes_in_group("trees").filter(func(t) -> bool: return t.is_standing() and t.global_position.distance_to(here) < 230.0).size()
		for i in maxi(0, 4 - standing):
			var spot: Vector2 = _free(here + Vector2(rng.randf_range(-170.0, 170.0), rng.randf_range(-120.0, 120.0)), Vector2(34, 34))
			if MAP.has_point(spot):
				var t: Node2D = load("res://scenes/Tree.tscn").instantiate()
				t.position = spot
				world.add_child(t)
	if _play_roles.has(&"sawyer") or _play_roles.has(&"hauler"):
		var logs: int = Logistics.loose_logs(tree).size()
		for i in maxi(0, 2 - logs):
			await clock._c7_log_tree(world, _free(here + Vector2(rng.randf_range(-120.0, 120.0), rng.randf_range(20.0, 100.0)), Vector2(34, 34)))
	if _play_roles.has(&"builder") or _play_roles.has(&"hauler"):
		if kit.has("storage") and is_instance_valid(kit["storage"]):
			if kit["storage"].planks_stored < 3:
				kit["storage"].add_planks(5)
		elif Logistics.free_piles(tree).is_empty():
			var pile = load("res://scripts/plank_piles.gd").spawn_pile(world, _free(here + Vector2(40, 60), Vector2(40, 30)), 3)
	if _play_roles.has(&"builder"):
		var open_bps: int = Logistics.blueprints(tree).filter(func(b) -> bool: return not b.is_finished()).size()
		if open_bps < 1:
			var bp = load("res://scenes/Building.tscn").instantiate()
			bp.building_type = load("res://assets/table_type.tres")
			bp.position = _free(here + Vector2(rng.randf_range(-90.0, 90.0), rng.randf_range(40.0, 110.0)), Vector2(50, 40))
			world.add_child(bp)
	if _play_roles.has(&"farmer"):
		_supply_field()
	if _play_roles.has(&"cook") and kit.has("kitchen"):
		var crate = kit["kitchen"]["crate"]
		if is_instance_valid(crate):
			if crate.count_of(&"wheat_sheaf") < 3:
				crate.add_item(&"wheat_sheaf", 6)
			if crate.count_of(&"flatbread") >= colony.bread_target:
				crate.take_item(&"flatbread", 2)
	if _play_roles.has(&"hauler") and kit.has("storage"):
		var Items = load("res://scripts/items.gd")
		var loose_items: int = tree.get_nodes_in_group("ground_items").filter(func(i) -> bool: return [&"wheat_sheaf", &"flour", &"flatbread"].has(i.kind) and not i.is_queued_for_deletion()).size()
		if loose_items < 2:
			Items.put(tree, world, &"wheat_sheaf", _free(here + Vector2(30, 40), Vector2(20, 20)), Rect2(0, 0, 640, 640))

func _supply_field() -> void:
	var m: Node2D = _plots()
	if m.farm_cells.is_empty():
		# the fresh start has no field: a small one beside the cabin
		for r in range(40, 220, 20):
			var origin: Vector2i = m.cell_of(friend.position + Vector2(r, r * 0.4))
			var ok: bool = true
			for dx in 3:
				for dy in 2:
					if m.can_farm(origin + Vector2i(dx, dy)) != "":
						ok = false
			if ok:
				for dx in 3:
					for dy in 2:
						m.set_farm(origin + Vector2i(dx, dy))
				break
	# the wheat ripens at once now and then (its own growth takes two game days)
	if not m.farm_cells.is_empty():
		var centre: Vector2 = m.cell_center(m.farm_cells.keys()[0])
		m.ripen_near(centre, 140.0)

# --- The scripted player ---------------------------------------------------------------------------------------------------------

func _script_player(kind: String, delta: float) -> void:
	_pit_t += delta
	if _pit_t >= 0.5:
		_pit_t = 0.0
		for pit in get_tree().get_nodes_in_group("pit_saws"):
			if pit.is_built() and pit.state == pit.State.LOADED and pit.is_waiting_here(friend):
				player.position = pit.global_position + Vector2(30, 30)
				pit.request_saw(player)
	if _panel_end_at > 0.0 and _t_run >= _panel_end_at:
		_panel_end_at = -1.0
		_panel_hold = false
		if friend.orders_panel != null and friend.orders_panel.is_open:
			friend.orders_panel.close()
		if box != null and is_instance_valid(box) and box.is_open:
			box.close()
	if _carry_end_at > 0.0 and _t_run >= _carry_end_at:
		_carry_end_at = -1.0
		if box != null and is_instance_valid(box) and box.carrier != null:
			box.carrier.escape()
	if kind != "stances":
		return
	_player_t += delta
	if _player_t < 1.5:
		return
	_player_t = 0.0
	player.position = friend.position + Vector2(18, 4)
	var WorkActions = load("res://scripts/work_actions.gd")
	match rng.randi() % 3:
		0:
			player.debug_hold(&"hoe")
			var m: Node2D = _plots()
			var cell: Vector2i = m.cell_of(friend.position + Vector2(rng.randf_range(-50.0, 50.0), rng.randf_range(12.0, 55.0)))
			player.plot_till(cell)
			if m.tilling.has(cell):
				player.plot_till(cell)
			player.hands.clear()
		1:
			var best: Node2D = null
			for t in get_tree().get_nodes_in_group("trees"):
				if t.is_standing() and t.claimed_by == null and (best == null or t.global_position.distance_to(friend.position) < best.global_position.distance_to(friend.position)):
					best = t
			if best != null and best.global_position.distance_to(friend.position) < 200.0:
				WorkActions.chop(get_tree(), best, &"chop", 1)
				player._note_work(&"chop", best)
		2:
			for b in load("res://scripts/logistics.gd").blueprints(get_tree()):
				if b.is_supplied() and not b.is_finished():
					WorkActions.hammer(get_tree(), b)
					player._note_work(&"hammer", b)
					break

# --- The events of the scenarios ---------------------------------------------------------------------------------------------------

func _drive(kind: String) -> void:
	_event_n += 1
	match kind:
		"switching":
			var pick: StringName = ROLES[rng.randi() % ROLES.size()]
			friend.orders.clear_work()
			friend.orders.toggle_role(pick)
			if rng.randf() < 0.4:
				var second: StringName = ROLES[rng.randi() % ROLES.size()]
				if second != pick:
					friend.orders.toggle_role(second)
			friend.orders_changed()
		"stances":
			friend.set_stance(rng.randi() % 4)
		"needs":
			_event_needs()
		"interruptions":
			await _event_interruption()
		"doors":
			await _event_doors()
		"twoperson":
			_event_twoperson()

func _event_needs() -> void:
	var which: int = rng.randi() % 5
	if OS.get_environment("BB_TRACE") != "":
		_note("needs event %d at %s" % [which, clock.get_time_string() if clock.has_method("get_time_string") else str(clock.time_of_day)])
	match which:
		0:
			friend.hunger.value = rng.randf_range(12.0, 28.0)
		1:
			friend.rest.value = rng.randf_range(3.0, 12.0)
		2:
			clock.set_time(clock.day, 0.72)
			_morning_at = _t_run + 70.0
		3:
			if player.state != player.State.SLEEPING:
				player.position = friend.position + Vector2(25, 10)
				player.rest.value = 25.0
				player._begin_sleep(clock.sleep_rate_outdoors(), "bugbash: the player sleeps")
		4:
			friend.hunger.value = rng.randf_range(8.0, 20.0)
			friend.rest.value = rng.randf_range(3.0, 12.0)

func _event_interruption() -> void:
	var tree: SceneTree = get_tree()
	var ai = friend.order_ai
	var Logistics = load("res://scripts/logistics.gd")
	match rng.randi() % 9:
		0:
			# the Orders panel opens and closes; Esc must close it (and not open the pause menu)
			player.position = friend.position + Vector2(20, 4)
			if friend.orders_panel != null and not friend.orders_panel.is_open and friend.talk_block_reason() == "":
				_panel_hold = true
				friend.orders_panel.open_for(player)
				await get_tree().create_timer(0.3).timeout
				var said: String = Ui.escape_pressed()
				if Ui.pause_menu != null and Ui.pause_menu.paused:
					flag("ui", "esc pause", "Esc opened the pause menu with the Orders panel open (escape_pressed said '%s')" % said)
					Ui.pause_menu_close()
				if friend.orders_panel.is_open:
					flag("ui", "panel not closed by esc", "the Orders panel did not close with Esc (escape_pressed said '%s')" % said)
					friend.orders_panel.close()
				_panel_hold = false
		1:
			if box != null and is_instance_valid(box) and not box.is_open:
				player.position = box.global_position + Vector2(0, 14)
				_panel_hold = true
				box.open_for(player)
				_panel_end_at = _t_run + 3.0
		2:
			var bp = load("res://scenes/Building.tscn").instantiate()
			bp.building_type = load("res://assets/table_type.tres")
			bp.position = _free(friend.position + Vector2(rng.randf_range(-70.0, 70.0), rng.randf_range(30.0, 90.0)), Vector2(50, 40))
			world.add_child(bp)
			_placed_bps.append(bp)
		3:
			for b in _placed_bps:
				if is_instance_valid(b) and b.has_method("can_cancel") and b.can_cancel():
					b.cancel()
					break
			_placed_bps = _placed_bps.filter(func(b) -> bool: return is_instance_valid(b))
		4:
			# mark and unmark designations
			var mode: Node = tree.get_first_node_in_group("designation_mode")
			var trees: Array = tree.get_nodes_in_group("trees").filter(func(t) -> bool: return t.is_standing() and t.global_position.distance_to(friend.position) < 220.0)
			if not trees.is_empty():
				var t: Node2D = trees[rng.randi() % trees.size()]
				mode.start(friend, &"chop")
				mode.apply_box(t.global_position + Vector2(0, -8), t.global_position + Vector2(0, -8), false)
				mode.finish()
				if rng.randf() < 0.5:
					mode.start(friend, &"chop")
					mode.apply_box(t.global_position + Vector2(0, -8), t.global_position + Vector2(0, -8), true)
					mode.finish()
		5:
			# delete the target he is walking to
			var job = ai.work_job
			if job != null and job.get("target") != null and is_instance_valid(job.get("target")) and not (job.target is Control) and job.target != friend:
				var tgt = job.target
				if tgt.is_in_group("trees") or tgt.is_in_group("buildings") or tgt.is_in_group("ground_items") or tgt.is_in_group("plank_piles"):
					for g in tgt.get_groups():
						tgt.remove_from_group(g)
					tgt.queue_free()
		6:
			# block his path with a new blueprint right in front of him
			var ahead: Vector2 = friend.position + Vector2(-14.0 if friend.flip_h else 14.0, 4.0)
			var bp2 = load("res://scenes/Building.tscn").instantiate()
			bp2.building_type = load("res://assets/table_type.tres")
			bp2.position = ahead
			world.add_child(bp2)
			_placed_bps.append(bp2)
		7:
			# the campfire goes
			for f in tree.get_nodes_in_group("campfires"):
				for g in f.get_groups():
					f.remove_from_group(g)
				f.queue_free()
				break
		8:
			# a bed goes
			for b in tree.get_nodes_in_group("beds"):
				for g in b.get_groups():
					b.remove_from_group(g)
				b.queue_free()
				break

func _event_doors() -> void:
	var tree: SceneTree = get_tree()
	var host = kit["house"] if kit.has("house") and is_instance_valid(kit["house"]) else friend.home
	if host == null or not is_instance_valid(host):
		return
	var room: Node2D = host.get_interior()
	var Logistics = load("res://scripts/logistics.gd")
	var open_in_room: int = Logistics.blueprints(tree).filter(func(b) -> bool: return not b.is_finished() and Logistics.room_of(tree, b.global_position) == room).size()
	if open_in_room < 1:
		clock._c9_bp_in(world, room, "res://assets/wooden_bed_type.tres", Vector2(rng.randf_range(30.0, 70.0), rng.randf_range(80.0, 110.0)))
	if Logistics.free_piles(tree).is_empty() and not kit.has("storage"):
		load("res://scripts/plank_piles.gd").spawn_pile(world, _free(friend.position + Vector2(40, 50), Vector2(40, 30)), 4)
	# things to carry into the storage crate through its door
	if kit.has("kitchen"):
		load("res://scripts/items.gd").put(tree, world, [&"flour", &"wheat_sheaf", &"flatbread"][rng.randi() % 3], _free(friend.position + Vector2(30, 40), Vector2(20, 20)), Rect2(0, 0, 640, 640))
	# the player walks in and out of the house now and then (he sees or does not see the room)
	if rng.randf() < 0.3 and player.inside_building == null:
		player.position = host.door_position()
		player.request_enter(host)

func _event_twoperson() -> void:
	match rng.randi() % 3:
		0:
			# the toolbox carry with the friend (he helps while his job is let go), ended a few seconds later
			if box != null and is_instance_valid(box) and box.carrier == null and player.state == player.State.FREE:
				player.position = box.global_position + Vector2(0, 14)
				player.hands.clear()
				var why: String = box.start_carry()
				if why == "":
					_carry_end_at = _t_run + rng.randf_range(6.0, 12.0)
		1:
			friend.set_stance(2 if friend.orders.stance == 0 else 0)
		2:
			# a log into the pit saw by the player himself (the pit is two-person: the friend helps)
			for pit in get_tree().get_nodes_in_group("pit_saws"):
				if pit.is_built() and pit.state == pit.State.EMPTY and rng.randf() < 0.7:
					pit.accept_log()

