extends Node

# The HUD's shared settings and the one message line.
#
# MESSAGE LINE: every message for the player ("Too far away", "Pick up the axe to chop", ...) goes
# through say(). One message at a time, bottom-centre above the build palette: a new message
# replaces the old one, the same message again within repeat_window seconds is ignored, each stays
# message_time seconds and then fades out over message_fade_time.
#
# UI DETAIL: Full shows everything; Minimal hides the top hint, shortens the interaction prompt to a
# key cap and one word, and shows the material pips only while the mouse is over the blueprint. It
# keeps the progress bars, the held-item slot and the message line. F1 switches between them.

enum UiDetail { FULL, MINIMAL }

signal detail_changed

@export var ui_detail: UiDetail = UiDetail.FULL:
	set(value):
		ui_detail = value
		detail_changed.emit()
# Seconds a message stays at full strength, then how long it takes to fade out.
@export var message_time: float = 2.0
@export var message_fade_time: float = 0.5
# The same message again within this many seconds is not shown again.
@export var repeat_window: float = 1.0
# Where the line sits (top edge, as a share of the window height: message_y / 270): just above the build menu.
@export var message_y: float = 162.0
@export var toggle_detail_key: Key = KEY_F1
# Progress bars, material pips, the [E] verb prompt, the Storage stock readout and colonists' rest bars
# show only while the mouse is over the thing they belong to. (E still acts on the nearest thing in
# reach; only what is drawn changes.) Off: the old rules (the prompt for the nearest target, bars that
# linger, pips by distance).
@export var show_overlays_only_on_hover: bool = true

var _label: Label
var _clock: float = 0.0
var _last_text: String = ""
var _last_shown_at: float = -1000.0
var _left: float = 0.0

func _ready() -> void:
	add_to_group("hud")
	# (The message is the UI's: a crisp label in the text layer, centred, at message_y / 270 of the window's height.)
	_label = Ui.screen_label("body")
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.visible = false

func _exit_tree() -> void:
	if is_instance_valid(_label):
		_label.queue_free()

func _place_label() -> void:
	var screen: Vector2 = Ui.screen_size()
	var width: float = _label.get_combined_minimum_size().x
	_label.size = Vector2(width, _label.get_combined_minimum_size().y)
	_label.position = Ui.snap(Vector2((screen.x - width) * 0.5, screen.y * message_y / 270.0))

func is_minimal() -> bool:
	return ui_detail == UiDetail.MINIMAL

# Shows a message on the message line (see the top of the file for the rules).
func say(text: String) -> void:
	if text == "":
		return
	if text == _last_text and _clock - _last_shown_at < repeat_window:
		return
	_last_text = text
	_last_shown_at = _clock
	_label.text = text
	_label.modulate.a = 1.0
	_label.visible = true
	_left = message_time + message_fade_time

func _process(delta: float) -> void:
	_clock += delta
	if _label.visible:
		_place_label()
	if _left > 0.0:
		_left -= delta
		if _left <= 0.0:
			_label.visible = false
		elif _left < message_fade_time:
			_label.modulate.a = _left / maxf(0.001, message_fade_time)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == toggle_detail_key:
		ui_detail = UiDetail.FULL if is_minimal() else UiDetail.MINIMAL
		say("HUD: Minimal" if is_minimal() else "HUD: Full")
		get_viewport().set_input_as_handled()
