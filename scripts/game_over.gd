extends CanvasLayer

# The game-over screen: what happened, how many days he survived, and R (or the button) to start again. It pauses the world
# behind it (the tree is paused). The panel is the UI's: themed, in the UI's game-over layer, above the sleep fade, at
# the window's real resolution. (The key R is read by the Ui autoload, which keeps running while the tree is paused.)

var shown: bool = false
var _root: Control
var _title: Label
var _days: Label
var _hint: Label

func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.name = "GameOverScreen"
	_root.process_mode = Node.PROCESS_MODE_ALWAYS
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	Ui.over_root.add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.015, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"DarkPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Ui.px(10))
	box.custom_minimum_size.x = Ui.px(440)
	panel.add_child(box)
	var banner := PanelContainer.new()
	banner.theme_type_variation = &"Banner"
	box.add_child(banner)
	_title = Label.new()
	_title.theme_type_variation = &"HeadingLabel"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_child(_title)
	_days = Label.new()
	_days.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_days)
	box.add_child(HSeparator.new())
	_hint = Label.new()
	_hint.theme_type_variation = &"BrassLabel"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_hint)
	var button := Button.new()
	button.text = "Restart (R)"
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(restart)
	button.mouse_entered.connect(func() -> void: Ui.sfx("ui_hover"))
	box.add_child(button)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_root):
		_root.queue_free()

func show_over(title: String, days_survived: int, day: int) -> void:
	if shown:
		return
	shown = true
	_root.visible = true
	_title.text = title
	_days.text = "Days survived: %d   (you died on day %d)" % [days_survived, day]
	_hint.text = "Press R to restart"
	Ui.game_over = self
	Ui.pause_menu_close()
	get_tree().paused = true

# The player's dead state is undone by a restart only; a test may clear the screen.
func hide_screen() -> void:
	shown = false
	if is_instance_valid(_root):
		_root.visible = false
	if Ui.game_over == self:
		Ui.game_over = null

func restart() -> void:
	get_tree().paused = false
	Ui.game_over = null
	var fast: Node = get_node_or_null("/root/FastForward")
	if fast != null:
		fast.set_index(0)
	get_tree().reload_current_scene()
