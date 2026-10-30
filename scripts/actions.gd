extends RefCounted

# ACTIONS: what E can do with a thing, as records the E chooser lists. Interaction._candidates() already says which things are in
# reach; get_actions() turns one candidate into its action(s):
#   {verb, target_name, tool, enabled, disabled_reason, priority, execute, node, kind, point, candidate}
#   - verb: "Chop", "Delimb", "Pick up", "Swap for", "Till", "Dismantle" ...   - target_name: what it is done to ("Tree", "Branch")
#   - tool: the tool the action uses ("axe", "hoe", ... or &"" for a plain pick-up) - shown in the row, and a tool-using action
#     ranks above a plain pick-up
#   - enabled / disabled_reason: false with the sentence when it cannot be done now (no axe in the hands: the reason is what
#     the usual tool check says); a disabled action is listed greyed at the bottom of the chooser
#   - priority: the position of its verb in Interaction.verb_priority (lower = earlier), the last tie-break
#   - execute: Callable that does it (the same _do that E and a click run)
# SUPPORTED lists the kinds that join a chooser: pick-ups (and swaps: a pick-up with something in the hands), trees (chop, delimb,
# take the log), berry bushes, plots (till, sow, harvest, water) and dismantle. Every other kind (deliveries, beds, crates, the
# campfire, doors ...) acts at once as before.

const GroundPlacement = preload("res://scripts/ground_placement.gd")
const HoverNames = preload("res://scripts/hover_names.gd")
const FoodConfig = preload("res://scripts/food_config.gd")

const SUPPORTED: Array[String] = [
	"take_item", "take_basket", "take_hammer", "take_shovel", "take_axe", "take_plank", "take_blade", "take_bundle_pile",
	"board_pickup", "merge_seeds", "thresh", "talk", "log", "tree", "pick", "plot_till", "plot_sow", "plot_harvest", "plot_water", "dismantle",
]
# The tool each tool-using kind needs in the hands.
const TOOL_OF: Dictionary = {
	"tree": &"axe", "plot_till": &"hoe", "plot_harvest": &"sickle", "plot_sow": &"seed_bag", "plot_water": &"bucket", "dismantle": &"hammer", "thresh": &"seed_bag",
}
const TOOL_NAMES: Dictionary = {&"axe": "Axe", &"hoe": "Hoe", &"sickle": "Sickle", &"seed_bag": "Seed bag", &"bucket": "Bucket", &"hammer": "Hammer"}

# What KIND of thing a candidate acts on, not which one: every loose plank is "plank_piles", every branch "item:branch", a seed bag is
# "item:seed_bag" whatever it holds, a tool is its own group ("axes", "hammers"), every standing tree is "tree".
const TYPE_GROUPS: Array[String] = ["hammers", "shovels", "axes", "saw_blades", "plank_piles", "bundle_piles", "baskets", "dough_boards", "berry_bushes"]

static func type_key_of(c: Dictionary) -> String:
	var kind: String = c["kind"]
	if kind.begins_with("plot_"):
		return "plot"
	if kind == "tree" or kind == "log":
		return kind
	if kind == "talk":
		return "colonist:%d" % c["node"].get_instance_id()
	var node = c["node"]
	if node == null or not is_instance_valid(node):
		return kind
	if node.is_in_group("ground_items"):
		return "item:%s" % str(node.kind)
	for group in TYPE_GROUPS:
		if node.is_in_group(group):
			return group
	return node.scene_file_path if node.scene_file_path != "" else kind

static func supported(c: Dictionary) -> bool:
	if not SUPPORTED.has(c["kind"]):
		return false
	return c.has("cell") or (c["node"] != null and is_instance_valid(c["node"]))

# The point a candidate is "at" for grouping and ordering: a pick-up's centre, else its working point.
static func centre_of(c: Dictionary) -> Vector2:
	if c["node"] != null and is_instance_valid(c["node"]) and not c.has("cell") and c["kind"] != "tree" and c["kind"] != "log" and c["kind"] != "dismantle" and c["kind"] != "talk":
		return GroundPlacement.pickup_center(c["node"])
	return c["point"]

# The action(s) for a candidate. `ix` is the Interaction (it runs them and holds the verb order), `player` the MainCharacter.
static func get_actions(ix, player: Node, c: Dictionary) -> Array:
	var out: Array = []
	if not supported(c):
		return out
	var kind: String = c["kind"]
	var node = c["node"]
	var verb: String = ""
	var target: String = ""
	match kind:
		"tree":
			verb = "Chop" if node.is_standing() else "Delimb"
			target = "Tree"
		"log":
			verb = "Take"
			target = "Log"
		"pick":
			verb = "Pick"
			target = HoverNames.name_of(node, ix.get_tree())
		"plot_till":
			verb = "Till"
		"plot_sow":
			verb = "Sow"
		"plot_harvest":
			verb = "Harvest"
		"plot_water":
			verb = "Water"
		"dismantle":
			verb = "Dismantle"
			target = HoverNames.name_of(node, ix.get_tree())
		"talk":
			verb = "Talk to"
			target = node.display_name
		"thresh":
			verb = "Thresh"
			target = "Sheaf"
		"merge_seeds":
			verb = "Add seeds to"
			target = HoverNames.name_of(node, ix.get_tree())
		_:
			# a pick-up; with something already in the hands it is a swap
			verb = "Swap for" if player.hands_occupied() else "Pick up"
			target = HoverNames.name_of(node, ix.get_tree())
	if kind.begins_with("plot_"):
		target = "Plot"
	var tool: StringName = TOOL_OF.get(kind, &"")
	var reason: String = ""
	if tool != &"" and kind == "tree":
		reason = player.tool_check(tool, "chop" if verb == "Chop" else "delimb")
	elif tool == &"hammer":
		reason = player.tool_check(tool, "dismantle")
	elif kind == "log" and player.hands_occupied() and not player.swap_on_pickup:
		reason = "Your hands are full."
	elif kind == "talk":
		reason = node.talk_block_reason()
	elif kind == "thresh" and player.held_seeds + FoodConfig.cfg().thresh_seeds_per_sheaf > FoodConfig.cfg().seed_bag_capacity:
		reason = "Not enough room in the bag."
	var verbs: Array = ix.verb_priority
	var rank: int = verbs.find(verb)
	out.append({
		"verb": verb, "target_name": target, "tool": tool, "enabled": reason == "", "disabled_reason": reason,
		"priority": rank if rank >= 0 else verbs.size(), "execute": Callable(ix, "_do").bind(c),
		"node": node, "kind": kind, "point": c["point"], "centre": centre_of(c), "candidate": c,
		"type_key": type_key_of(c), "count": 1,
	})
	if kind == "thresh":
		out[0]["label"] = "Thresh sheaf into seed bag"
	return out

# The row text: "Chop Tree (Axe)", "Pick up Branch".
static func label_of(action: Dictionary) -> String:
	if action.has("label"):
		return action["label"] + (" (x%d)" % action["count"] if int(action.get("count", 1)) > 1 else "")
	var text: String = "%s %s" % [action["verb"], action["target_name"]]
	if action["tool"] != &"":
		text += " (%s)" % TOOL_NAMES.get(action["tool"], String(action["tool"]).capitalize())
	if int(action.get("count", 1)) > 1:
		text += " (x%d)" % action["count"]
	return text

# Merges duplicates: actions with the same verb, the same target TYPE and the same enabled state are ONE action, represented by the
# one with the lowest "score" (the closest to his feet with the facing bonus, or to the cursor); its "count" is how many there
# were (the row says "Pick up Branch (x3)" and acts on the closest one).
static func merge_duplicates(list: Array) -> Array:
	var best: Dictionary = {}
	var counts: Dictionary = {}
	var order: Array[String] = []
	for a in list:
		var key: String = "%s|%s|%s" % [a["verb"], a["type_key"], a["enabled"]]
		if not best.has(key):
			best[key] = a
			counts[key] = 1
			order.append(key)
		else:
			counts[key] += 1
			if a["score"] < best[key]["score"]:
				best[key] = a
	var out: Array = []
	for key in order:
		best[key]["count"] = counts[key]
		out.append(best[key])
	return out

# Enabled first, then the default order: the nearest thing to `reference` (the cursor, else his feet) first, but things within
# `tolerance` px of each other count as equally near; among those a tool-using action comes before a plain pick-up, then the
# exported verb_priority; the exact distance settles the rest. Disabled actions follow, in the same order.
static func sort_actions(list: Array, reference: Vector2, tolerance: float) -> Array:
	for a in list:
		a["distance"] = reference.distance_to(a["centre"])
	var before: Callable = func(a: Dictionary, b: Dictionary) -> bool:
		if a["enabled"] != b["enabled"]:
			return a["enabled"]
		if absf(a["distance"] - b["distance"]) > tolerance:
			return a["distance"] < b["distance"]
		var a_tool: bool = a["tool"] != &""
		var b_tool: bool = b["tool"] != &""
		if a_tool != b_tool:
			return a_tool
		if a["priority"] != b["priority"]:
			return a["priority"] < b["priority"]
		return a["distance"] < b["distance"]
	list.sort_custom(before)
	return list

static func enabled_of(list: Array) -> Array:
	return list.filter(func(a: Dictionary) -> bool: return a["enabled"])
