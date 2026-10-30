extends Node

# What the player has unlocked: ONE set of keys. A building says what it needs in its data (BuildingType.unlock_requirement: a key,
# "none" = nothing). At the start only what needs nothing is available (the pit saw, the campfire, the grinding stone); the rest needs
# "pit_saw_built": once a pit saw has been built and finished it stays unlocked, even if the saw is dismantled later.
# Later features add keys here (unlock("some_key")) and name them in BuildingType.unlock_requirement.
# Debug: Ctrl+U unlocks everything.

signal changed

# key -> the sentence that says what is needed
const REASONS: Dictionary = {
	"pit_saw_built": "Build a pit saw first.",
}

var unlocked: Dictionary = {}
var everything: bool = false
var _poll: float = 0.0

func _ready() -> void:
	add_to_group("unlock_manager")
	_check_keys()

func is_unlocked(key: String) -> bool:
	return everything or key == "none" or key == "" or unlocked.has(key)

func unlock(key: String) -> void:
	if not unlocked.has(key):
		unlocked[key] = true
		changed.emit()

func unlock_all() -> void:
	if not everything:
		everything = true
		changed.emit()

func reason(key: String) -> String:
	return String(REASONS.get(key, "Not available yet."))

func keys() -> Array:
	return unlocked.keys()

func _process(delta: float) -> void:
	_poll += delta
	if _poll >= 0.25:
		_poll = 0.0
		_check_keys()

# The keys that are earned by something existing in the world.
func _check_keys() -> void:
	if unlocked.has("pit_saw_built"):
		return
	for pit in get_tree().get_nodes_in_group("pit_saws"):
		if pit.is_built():
			unlock("pit_saw_built")
			return

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed and event.keycode == KEY_U:
		unlock_all()
		var hud: Node = get_tree().get_first_node_in_group("hud")
		if hud != null:
			hud.say("Everything is unlocked (debug)")
		get_viewport().set_input_as_handled()
