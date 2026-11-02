class_name CharacterHands
extends RefCounted

# THE HANDS OF ONE CHARACTER: the single slot for whatever he holds. A character holds ONE thing at a time: a tool, a plank, a saw blade, a basket, a
# loaf; a log he drags (the LogDragger, see `dragger`) and a toolbox carried with someone (`carrying_together`) take the hands too. Everything that
# picks something up or puts it down goes through this object, so "two things at once" cannot be represented:
#
#   pick_up(kind, amount, as_tool)  false when the hands are full (nothing is changed); the caller frees them first
#   put_down()                      empties the slot and says what was in it ({"kind", "amount", "tool"}); the CALLER places it (a box, a stack, the ground)
#   swap(kind, amount, as_tool)     takes the new thing and gives back what was held, in one step (the caller places that)
#   is_holding() / holds(kind) / count()
#
# The colonists' ColonistTools.held ("what tool") and ColonistOrderAI.carrying ("what item") and the player's held_tool / carrying_planks / carrying_blade
# are read-through views of this slot, not stores of their own. HeldItemGuard (held_item_guard.gd) checks it every frame in a debug build.

const PLANK: StringName = &"plank"
const BLADE: StringName = &"saw_blade"

var kind: StringName = &""
var amount: int = 0
# Taken from a toolbox / the ground as a tool (a colonist's hammer) rather than carried as a material or item.
var as_tool: bool = false
# The log he drags (a LogDragger, or null) and the toolbox he carries with another (set by the owner): they take the hands as well.
var dragger = null
var together = null
var owner_name: String = ""

static var _said: Dictionary = {}

# A rule broken, said once per text (with the owner's name in it). Returns the text.
static func report(text: String) -> String:
	if not _said.has(text):
		_said[text] = true
		push_warning(text)
		print("HELD-ITEM: ", text)
	return text

func _init(owner: String = "") -> void:
	owner_name = owner

func is_dragging() -> bool:
	return dragger != null and dragger.is_dragging()

func is_carrying_together() -> bool:
	return together != null

# Anything at all in his hands (the slot, a dragged log, a carried toolbox).
func is_holding() -> bool:
	return kind != &"" or is_dragging() or is_carrying_together()

func is_empty() -> bool:
	return not is_holding()

func holds(k: StringName) -> bool:
	return kind != &"" and kind == k

# How many things he holds (always 0 or 1; the guard counts the slot, the log and the toolbox separately so a bug cannot hide here).
func count() -> int:
	return (1 if kind != &"" else 0) + (1 if is_dragging() else 0) + (1 if is_carrying_together() else 0)

# What is in the slot as a carried item ({"kind", "amount"}), {} for nothing or a tool.
func item() -> Dictionary:
	if kind == &"" or as_tool:
		return {}
	return {"kind": kind, "amount": amount}

# The tool in the slot (&"" when it is empty or holds a carried item).
func tool() -> StringName:
	return kind if as_tool else &""

# Takes `k` into the slot. False when the hands are already full (a plank on top of planks is the same kind: it adds).
func pick_up(k: StringName, n: int = 1, tool_flag: bool = false) -> bool:
	if k == &"":
		return true
	# (planks are one kind of thing in a stack; nothing else stacks)
	if k == PLANK and kind == PLANK and not tool_flag and not as_tool and not is_dragging() and not is_carrying_together():
		amount += n
		return true
	if is_holding():
		return false
	kind = k
	amount = n
	as_tool = tool_flag
	return true

# Empties the slot and says what was in it ({} when it was empty). The caller puts that somewhere.
func put_down() -> Dictionary:
	if kind == &"":
		return {}
	var out: Dictionary = {"kind": kind, "amount": amount, "tool": as_tool}
	clear()
	return out

# Takes the new thing and hands back the old in one step (the caller places the old one). The hands must not be busy with a log or a toolbox.
func swap(k: StringName, n: int = 1, tool_flag: bool = false) -> Dictionary:
	if is_dragging() or is_carrying_together():
		return {}
	var old: Dictionary = put_down()
	pick_up(k, n, tool_flag)
	return old

func clear() -> void:
	kind = &""
	amount = 0
	as_tool = false

# Takes `n` of what is in the slot away (a plank delivered); the slot empties at zero.
func use(n: int = 1) -> void:
	amount -= n
	if amount <= 0:
		clear()
