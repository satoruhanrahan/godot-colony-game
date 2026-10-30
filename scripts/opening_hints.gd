extends Node

# A small label at the top-centre of the HUD that tells a new player the next step of the
# opening, and goes away once the first house is built. It always names the step that matches the
# state of the world right now (and drops the "pick up ..." part once he already holds the tool).

@export var show_hints: bool = true
# After this many seconds a step's hint fades to faded_opacity; a new step brings it back to full
# for another fade_after seconds.
@export var fade_after: float = 6.0
@export_range(0.0, 1.0) var faded_opacity: float = 0.4
# The key that hides and shows the hint for the rest of the session, and the note the very first
# hint carries about it.
@export var toggle_key: Key = KEY_H
@export var first_hint_note: String = "(H hides hints, X: speed)"

var label: Label
@onready var player = get_node("../MainCharacter")

var _hints_on: bool = true
var _step: String = ""
var _step_age: float = 0.0
# The step that carries the note (the first one ever shown), until it changes.
var _note_step: String = ""
var _note_used: bool = false

func _ready() -> void:
	# The hint is the UI's crisp text, at the top-centre of the window.
	var old_layer: Node = get_node_or_null("Layer")
	if old_layer != null:
		old_layer.queue_free()
	label = Ui.screen_label("body")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

func _exit_tree() -> void:
	if is_instance_valid(label):
		label.queue_free()

func _process(delta: float) -> void:
	var screen: Vector2 = Ui.screen_size()
	var width: float = minf(screen.x * 0.5, float(Ui.px(900)))
	label.custom_minimum_size.x = width
	label.size = Vector2(width, label.get_combined_minimum_size().y)
	label.position = Ui.snap(Vector2((screen.x - width) * 0.5, float(Ui.px(10))))
	# Only the new opening has hints; the old start (opening_mode off) never shows them.
	var in_opening: bool = get_parent().opening_mode
	var step: String = _current_hint() if (show_hints and in_opening) else ""
	if step != _step:
		_step = step
		_step_age = 0.0
		_note_step = ""
		if step != "" and not _note_used:
			_note_used = true
			_note_step = step
	var hud: Node = get_tree().get_first_node_in_group("hud")
	var shown: bool = step != "" and _hints_on and not (hud != null and hud.is_minimal())
	var text: String = (step + "  " + first_hint_note) if (shown and step == _note_step) else step
	if label.text != text:
		label.text = text
	label.visible = shown
	if shown:
		_step_age += delta
	label.modulate.a = 1.0 if _step_age < fade_after else faded_opacity

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == toggle_key:
		_hints_on = not _hints_on
		_step_age = 0.0
		get_viewport().set_input_as_handled()

func _holds(tool: StringName) -> bool:
	return player != null and player.held_tool == tool

# Shown from the first grass bundle he pulls until he has made a bed.
const GRASS_HINT: String = "Put three bundles together to make a bed. Sleep on it with E. Break it up to move it."

# The next thing to do, from what exists in the world right now.
func _current_hint() -> String:
	if player != null and player.first_bundle_pulled and not player.bed_made:
		return GRASS_HINT
	var houses: Array = []
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.display_name() == "House":
			houses.append(b)
	for h in houses:
		if h.state == h.State.BUILT:
			return ""
	if not houses.is_empty():
		return "Carry planks to the house, then hammer it"
	var pits: Array = get_tree().get_nodes_in_group("pit_saws")
	if pits.is_empty():
		return "Press B, then 2, to mark a pit saw"
	var built: bool = false
	for pit in pits:
		if pit.is_built():
			built = true
	if not built:
		for pit in pits:
			if pit.ready_to_build():
				if _holds(&"hammer"):
					return "Hammer the pit saw to finish it"
				return "%s and hammer the pit saw to finish it" % _take_text("hammer")
		for pit in pits:
			if pit.can_dig():
				if _holds(&"shovel"):
					return "Dig the pit (E or click), then bring it the 2 planks and the saw blade"
				return "%s and dig the pit (E or click), then bring it the 2 planks and the saw blade" % _take_text("shovel")
		return "Bring the pit the 2 planks and the saw blade"
	if _planks_exist():
		return "Press B, then 1, to place a house"
	if _log_ready():
		return "Drag the log to the pit saw and saw it with your friend"
	if _holds(&"axe"):
		return "Chop a tree down and delimb it"
	return "%s, chop a tree down, and delimb it" % _take_text("axe")

# How he is told to get a tool: from the toolbox (E on it, then click the tool), or from the ground.
func _take_text(tool: String) -> String:
	for box in get_tree().get_nodes_in_group("toolboxes"):
		if box.kinds().has(StringName(tool)):
			return "Open the toolbox (E) and take the %s" % tool
	return "Pick up the %s" % tool

# A delimbed log is lying ready, or he is dragging one, or the pit saw has one loaded or is sawing.
func _log_ready() -> bool:
	if player != null and player.is_dragging():
		return true
	for tree in get_tree().get_nodes_in_group("trees"):
		if tree.is_delimbed() and tree.log_node() != null:
			return true
	for pit in get_tree().get_nodes_in_group("pit_saws"):
		if pit.is_built() and pit.state != pit.State.EMPTY:
			return true
	return false

# Any planks anywhere: waiting at a saw, stored, in his hands, or already on a blueprint.
func _planks_exist() -> bool:
	if player != null and player.carrying_planks > 0:
		return true
	if get_tree().get_nodes_in_group("plank_piles").size() > 0:
		return true
	for mill in get_tree().get_nodes_in_group("sawmills"):
		if mill.planks_ready > 0:
			return true
	for st in get_tree().get_nodes_in_group("storages"):
		if st.planks_stored > 0:
			return true
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.planks_ready > 0:
			return true
	return false
