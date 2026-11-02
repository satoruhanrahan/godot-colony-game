extends RefCounted

# THE ORDERS OF A COLONIST (any colonist, not only the friend). One of these hangs on every Colonist as `orders`.
#
#   stance : FREE   - free time: the old default (wander, fidget, follow loosely, eat, sleep)
#            FOLLOW - walks after the player (follow_distance_px / follow_stop_px), through doors too
#            ASSIST - follows, and copies the work the player does (see colonist_order_ai.gd)
#            STAY   - stays at `post` (the spot where the order was given) and fidgets there
#   post   : where STAY keeps him
#   roles  : work roles (the next prompt: "Lumberjack", "Farmer" ...), StringNames
#   tasks  : designated tasks (the next prompt: job ids / dictionaries posted on the JobBoard for him)
#
# PRECEDENCE, highest to lowest (the colonist AI in colonist.gd + colonist_order_ai.gd follows exactly this):
#   1. being told to carry the toolbox with the player (state HELPING_CARRY: nothing else touches him)
#   2. survival needs: eat when hungry, go home to sleep when exhausted or at night (the existing thresholds)
#   3. designated tasks and roles (JobBoard, job_board.gd) - hooks only for now
#   4. the stance
# After a need (or a task) interrupts, he resumes his order: every way out of an interruption ends in Colonist._stand_still(), and
# a colonist whose stance is not FREE is put straight back into State.ORDERED from there.
#
# Orders persist across days (they live on the colonist) and are meant to be saved with him: to_dict() / from_dict().

enum Stance { FREE, FOLLOW, ASSIST, STAY }

const NAMES: Dictionary = {Stance.FREE: "Free time", Stance.FOLLOW: "Follow me", Stance.ASSIST: "Assist me", Stance.STAY: "Stay here"}
# What he says when the order is given ("Friend: Following you.").
const ACK: Dictionary = {Stance.FREE: "Enjoying some free time.", Stance.FOLLOW: "Following you.", Stance.ASSIST: "Ready to help.", Stance.STAY: "Staying here."}
# One line under each button of the Orders panel.
const DESCRIPTIONS: Dictionary = {
	Stance.FOLLOW: "Walks after you, through doors too.",
	Stance.ASSIST: "Follows you and copies your work nearby.",
	Stance.STAY: "Waits at this spot, whatever happens.",
	Stance.FREE: "Does as he pleases: wanders, eats, rests.",
}

# The work roles (standing orders): what he does by himself while there is work for it, in this priority order (the order of `roles`).
const ROLES: Array[StringName] = [&"lumberjack", &"sawyer", &"hauler", &"builder", &"farmer", &"cook"]
const ROLE_NAMES: Dictionary = {&"lumberjack": "Lumberjack", &"sawyer": "Sawyer", &"hauler": "Hauler", &"builder": "Builder", &"farmer": "Farmer", &"cook": "Cook"}
const ROLE_DESCRIPTIONS: Dictionary = {
	&"lumberjack": "Fells and trims trees nearby, drags the logs to the saw or Storage.",
	&"sawyer": "Takes logs to the pit saw, saws them into planks and stacks them.",
	&"hauler": "Carries loose logs, planks and food to Storage and crates.",
	&"builder": "Brings materials to blueprints and hammers them.",
	&"farmer": "Works the farm zones: harvests, waters, sows and tills.",
	&"cook": "Grinds wheat, makes dough, bakes flatbread until there is enough.",
}
# The designated tasks (specific, one-off orders; see designation_mode.gd). Each task is a dictionary:
#   {"type": &"chop", "trees": [tree nodes], "done": 0}      {"type": &"saw", "saw": pit saw node, "done": 0}
#   {"type": &"haul", "zone": Rect2, "done": 0}               {"type": &"build", "blueprints": [blueprint nodes], "done": 0}
# ("farm" is a designation too, but its zones belong to the field, not to one colonist: they live in the PlotManager, see plot_manager.gd.)
const TASK_TYPES: Array[StringName] = [&"chop", &"saw", &"haul", &"build", &"farm"]
const TASK_NAMES: Dictionary = {&"chop": "Chop these trees", &"saw": "Saw logs into planks", &"haul": "Haul to storage", &"build": "Build these", &"farm": "Farm zone"}

var stance: Stance = Stance.FREE
var post: Vector2 = Vector2.INF
var roles: Array[StringName] = []
var tasks: Array = []

func has_role(role: StringName) -> bool:
	return roles.has(role)

func toggle_role(role: StringName) -> void:
	if roles.has(role):
		roles.erase(role)
	else:
		roles.append(role)

# Moves a role up (-1) or down (+1) in the priority order.
func move_role(role: StringName, step: int) -> void:
	var i: int = roles.find(role)
	var j: int = i + step
	if i < 0 or j < 0 or j >= roles.size():
		return
	roles[i] = roles[j]
	roles[j] = role

func has_work() -> bool:
	return not roles.is_empty() or not tasks.is_empty()

func task_of(type: StringName) -> Dictionary:
	for t in tasks:
		if t["type"] == type:
			return t
	return {}

# The task of this type (made, empty, when he has none yet).
func ensure_task(type: StringName) -> Dictionary:
	var t: Dictionary = task_of(type)
	if not t.is_empty():
		return t
	match type:
		&"chop":
			t = {"type": type, "trees": [], "done": 0}
		&"saw":
			t = {"type": type, "saw": null, "done": 0}
		&"haul":
			t = {"type": type, "zone": Rect2(), "done": 0}
		&"build":
			t = {"type": type, "blueprints": [], "done": 0}
	tasks.append(t)
	return t

# A short line for the panel: "5 trees marked, hauling a zone ..."
func tasks_text() -> String:
	var parts: Array[String] = []
	for t in tasks:
		match t["type"]:
			&"chop":
				parts.append("%d trees marked" % t["trees"].size())
			&"saw":
				parts.append("saw logs")
			&"haul":
				parts.append("haul a zone")
			&"build":
				parts.append("%d blueprints to build" % t["blueprints"].size())
	return ", ".join(parts)

# "Clear all orders": tasks and roles go (the stance stays).
func clear_work() -> void:
	tasks.clear()
	roles.clear()

static func stance_name(s: int) -> String:
	return NAMES.get(s, "Free time")

func name_now() -> String:
	return stance_name(stance)

# Gives the stance (`here` is where he stands now: the post of STAY).
func set_stance(new_stance: int, here: Vector2) -> void:
	stance = new_stance as Stance
	post = here.round() if new_stance == Stance.STAY else Vector2.INF

func to_dict() -> Dictionary:
	# (A task points at nodes of the world, which cannot be saved as they are: a saved game would store their paths. The counts are
	# kept here so the shape is visible.)
	var saved_tasks: Array = tasks.map(func(t: Dictionary) -> Dictionary: return {"type": String(t["type"]), "done": t.get("done", 0)})
	return {"stance": int(stance), "post": [post.x, post.y] if post != Vector2.INF else [], "roles": roles.map(func(r: StringName) -> String: return String(r)), "tasks": saved_tasks}

func from_dict(d: Dictionary) -> void:
	stance = int(d.get("stance", 0)) as Stance
	var p: Array = d.get("post", [])
	post = Vector2(p[0], p[1]) if p.size() == 2 else Vector2.INF
	roles.clear()
	for r in d.get("roles", []):
		roles.append(StringName(r))
	tasks.clear()
