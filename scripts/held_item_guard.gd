extends Node

# THE HELD-ITEM GUARD (debug builds only: Colony creates it when OS.is_debug_build()). Every frame it checks the rule "a character holds ONE thing":
#   - the player, every colonist and the NPC workers hold at most one thing (the slot, a dragged log and a carried toolbox count separately);
#   - no tool is both held and lying in the world or in a box, and none is held by two characters: the number of each tool (held + loose + in boxes)
#     never changes after the start (a tool is neither duplicated nor lost).
# A break is printed once, with the offender and where the second reference came from ("HELD-ITEM GUARD: ..."). `violations` counts them (self-check).

const CharacterHandsScript = preload("res://scripts/character_hands.gd")

# Tools that are counted (the ones a toolbox keeps).
const COUNTED: Array[StringName] = [&"hammer", &"shovel", &"axe", &"hoe", &"sickle", &"fire_starter"]
const LOOSE_GROUPS: Dictionary = {&"hammer": "hammers", &"shovel": "shovels", &"axe": "axes"}
const GRACE_SECONDS: float = 3.0

# The counting of tools (held twice / made / lost) can be turned off by a test that makes tools by hand; the hands check always runs.
var count_check: bool = true
var violations: int = 0
var last_message: String = ""
var _age: float = 0.0
var _totals: Dictionary = {}
var _said: Dictionary = {}

func _ready() -> void:
	name = "HeldItemGuard"
	add_to_group("held_item_guard")

func _process(delta: float) -> void:
	_age += delta
	_check_hands()
	if _age >= GRACE_SECONDS and count_check:
		_check_tools()

func _say(key: String, text: String) -> void:
	violations += 1
	last_message = text
	if _said.has(key):
		return
	_said[key] = true
	push_warning("HELD-ITEM GUARD: " + text)
	print("HELD-ITEM GUARD: ", text)

# --- At most one thing in the hands ------------------------------------------------------------------------------------------------

func _check_hands() -> void:
	var tree: SceneTree = get_tree()
	var player: Node = tree.get_first_node_in_group("player")
	if player != null and "hands" in player and player.hands != null:
		var h = player.hands
		var n: int = h.count()
		if n > 1:
			_say("player", "the player holds %d things: slot '%s', dragging a log %s, carrying a toolbox %s" % [n, h.kind, h.is_dragging(), h.is_carrying_together()])
	for col in tree.get_nodes_in_group("colonists"):
		var ai = col.get("order_ai")
		if ai == null or not ("hands" in ai) or ai.hands == null:
			continue
		var n2: int = ai.hands.count()
		var helping: bool = col.state == col.State.HELPING_CARRY and ai.hands.kind != &""
		if n2 > 1 or helping:
			_say("colonist_" + col.display_name, "%s holds %d things: slot '%s' (%s), dragging a log %s%s" % [col.display_name, n2 + (1 if helping else 0), ai.hands.kind, "tool" if ai.hands.as_tool else "item", ai.hands.is_dragging(), ", and is carrying the toolbox" if helping else ""])
	# NPC workers: a plank in the hands and a dragged log at once
	for w in tree.get_nodes_in_group("bodies"):
		if w != player and not w.is_in_group("colonists") and w.get("carrying_planks") != null and w.get("dragger") != null and int(w.carrying_planks) > 0 and w.dragger.is_dragging():
			_say("worker_" + str(w.get_instance_id()), "%s carries planks and drags a log" % w.name)

# --- A tool is never held twice, nor held and lying about, nor made or lost ---------------------------------------------------------------

func _count_tools() -> Dictionary:
	var tree: SceneTree = get_tree()
	var held: Dictionary = {}
	var loose: Dictionary = {}
	var boxed: Dictionary = {}
	for k in COUNTED:
		held[k] = []
		loose[k] = 0
		boxed[k] = 0
	var player: Node = tree.get_first_node_in_group("player")
	if player != null and COUNTED.has(player.held_tool):
		held[player.held_tool].append("the player")
	for col in tree.get_nodes_in_group("colonists"):
		var ai = col.get("order_ai")
		if ai != null and ai.tools != null and COUNTED.has(ai.tools.held):
			held[ai.tools.held].append(col.display_name)
	for k in COUNTED:
		var nodes: Array = tree.get_nodes_in_group(LOOSE_GROUPS[k]) if LOOSE_GROUPS.has(k) else tree.get_nodes_in_group("ground_items").filter(func(n) -> bool: return n.kind == k)
		for n in nodes:
			if not n.is_queued_for_deletion() and not (n.get_parent() != null and n.get_parent().is_in_group("tables")):
				loose[k] += 1
	for box in tree.get_nodes_in_group("toolboxes"):
		for k in box.kinds():
			if boxed.has(k):
				boxed[k] += 1
	return {"held": held, "loose": loose, "boxed": boxed}

func _check_tools() -> void:
	var counts: Dictionary = _count_tools()
	for k in COUNTED:
		var holders: Array = counts["held"][k]
		var total: int = holders.size() + int(counts["loose"][k]) + int(counts["boxed"][k])
		if holders.size() > 1:
			_say("twice_" + str(k), "the %s is held by %d characters at once (%s); %d lying about, %d in boxes" % [k, holders.size(), ", ".join(holders), counts["loose"][k], counts["boxed"][k]])
		if _totals.has(k) and _totals[k] != total:
			_say("count_%s_%d_%d" % [k, _totals[k], total], "the number of %s changed from %d to %d (held by %s, %d lying about, %d in boxes)" % [k, _totals[k], total, holders, counts["loose"][k], counts["boxed"][k]])
		_totals[k] = total

# Called after the world is set up on purpose (a test adds or removes tools): start counting again from what there is now.
func rebase() -> void:
	_totals.clear()
	_age = 0.0
