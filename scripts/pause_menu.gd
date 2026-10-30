extends Node

# Pause. Esc or P toggles it; a small themed button in the top-right corner does too (two bars, "Pause (P)" on hover).
#
# Paused means get_tree().paused: the game clock, the colonists, the workers, the sleep skip, plot growth, everything in the
# world stops and the world's sounds are held (the SFX bus is muted and the loops - the brook, the fire - stop where they
# are). The pause UI, the Ui autoload and the sound manager keep running (process mode Always). Fast forward is
# remembered (nothing changes it while paused) and is back as it was on resume. A sleep skip freezes with the black screen
# up and carries on after. The screen dims behind a themed panel: the day and time, Resume, Sound on/off (the same as M)
# and Restart (which asks first).
#
# Esc closes an open panel first (the build menu, ...: Ui.register_closable) and only then pauses. Pause is not available
# on the game-over screen. Debug keys do nothing while paused (the world is not running).

const PAUSE_KEY: Key = KEY_P

var paused: bool = false
var _button: Button
var _tooltip: PanelContainer
var _dim: ColorRect
var _center: CenterContainer
var _panel: PanelContainer
var _time_label: Label
var _sound_button: Button
var _restart_button: Button
var _confirm_box: VBoxContainer
var _main_box: VBoxContainer
var _tween: Tween

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	Ui.ui_changed.connect(_layout)
	_layout()

func _build() -> void:
	var root: Control = Ui.pause_root
	# the dimmer (over the whole window, under the panel)
	_dim = ColorRect.new()
	_dim.color = Color(0.03, 0.02, 0.015, 0.6)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.visible = false
	root.add_child(_dim)
	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.visible = false
	root.add_child(_center)
	_panel = PanelContainer.new()
	_panel.theme_type_variation = &"DarkPanel"
	_center.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Ui.px(10))
	box.custom_minimum_size.x = Ui.px(360)
	_panel.add_child(box)
	var banner := PanelContainer.new()
	banner.theme_type_variation = &"Banner"
	box.add_child(banner)
	var title := Label.new()
	title.text = "Paused"
	title.theme_type_variation = &"HeadingLabel"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_child(title)
	_time_label = Label.new()
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_time_label)
	box.add_child(HSeparator.new())
	_main_box = VBoxContainer.new()
	_main_box.add_theme_constant_override("separation", Ui.px(8))
	box.add_child(_main_box)
	_main_box.add_child(_make_button("Resume", resume))
	_sound_button = _make_button("Sound: on", _toggle_sound)
	_main_box.add_child(_sound_button)
	_restart_button = _make_button("Restart", _ask_restart)
	_main_box.add_child(_restart_button)
	_confirm_box = VBoxContainer.new()
	_confirm_box.add_theme_constant_override("separation", Ui.px(8))
	_confirm_box.visible = false
	box.add_child(_confirm_box)
	var ask := Label.new()
	ask.text = "Restart from the beginning? This day is lost."
	ask.theme_type_variation = &"BrassLabel"
	ask.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ask.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm_box.add_child(ask)
	_confirm_box.add_child(_make_button("Yes, restart", _restart))
	_confirm_box.add_child(_make_button("Cancel", _cancel_restart))
	# the corner button
	_button = Button.new()
	_button.icon = load("res://ui/icon_pause.png") if ResourceLoader.exists("res://ui/icon_pause.png") else null
	_button.expand_icon = true
	_button.focus_mode = Control.FOCUS_NONE
	_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_button.pressed.connect(toggle)
	_button.mouse_entered.connect(_show_tooltip)
	_button.mouse_exited.connect(func() -> void: _tooltip.visible = false)
	root.add_child(_button)
	_tooltip = PanelContainer.new()
	_tooltip.theme_type_variation = &"DarkPanel"
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.visible = false
	var tip := Label.new()
	tip.text = "Pause (P)"
	tip.theme_type_variation = &"BrassLabel"
	tip.add_theme_font_size_override("font_size", Ui.font_size("small"))
	_tooltip.add_child(tip)
	root.add_child(_tooltip)

func _make_button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.custom_minimum_size = Vector2(0, Ui.px(40))
	Ui.decorate_button(button)
	button.pressed.connect(action)
	return button

# The corner button's place and size follow the window.
func _layout() -> void:
	var side: float = float(Ui.px(40))
	_button.custom_minimum_size = Vector2(side, side)
	_button.size = Vector2(side, side)
	var margin: float = float(Ui.px(8))
	_button.position = Vector2(Ui.screen_size().x - side - margin, margin)
	# keep the clock clear of it (in art pixels)
	Ui.top_right_reserve = (side + margin) / float(Ui.art_scale())
	_tooltip.reset_size()

func _show_tooltip() -> void:
	_tooltip.reset_size()
	_tooltip.position = Vector2(_button.position.x + _button.size.x - _tooltip.size.x, _button.position.y + _button.size.y + 4.0)
	_tooltip.visible = true

func _process(_delta: float) -> void:
	# (Not on the game-over screen.)
	_button.visible = Ui.game_over == null
	if Ui.game_over != null and paused:
		_apply(false)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_ESCAPE:
		if Ui.game_over != null:
			return
		if paused:
			resume()
		elif not Ui.close_top_panel():
			toggle()
		get_viewport().set_input_as_handled()
	elif event.keycode == PAUSE_KEY and not event.ctrl_pressed and not event.alt_pressed:
		if Ui.game_over != null:
			return
		toggle()
		get_viewport().set_input_as_handled()

func toggle() -> void:
	if Ui.game_over != null:
		return
	_apply(not paused)

func resume() -> void:
	_apply(false)

func is_paused() -> bool:
	return paused

func _apply(value: bool) -> void:
	if value == paused:
		return
	paused = value
	_cancel_restart()
	if paused:
		_refresh_text()
		get_tree().paused = true
		AudioManager.hold(true)
		Ui.sfx("ui_open")
	else:
		get_tree().paused = false
		AudioManager.hold(false)
		Ui.sfx("ui_close")
	_show_panel(paused)

func _show_panel(on: bool) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if on:
		_dim.visible = true
		_center.visible = true
		_dim.modulate.a = 0.0
		_center.modulate.a = 0.0
		_tween = create_tween().set_ignore_time_scale(true).set_parallel(true)
		_tween.tween_property(_dim, "modulate:a", 1.0, Ui.cfg.menu_fade_seconds)
		_tween.tween_property(_center, "modulate:a", 1.0, Ui.cfg.menu_fade_seconds)
	else:
		_dim.visible = false
		_center.visible = false

func _refresh_text() -> void:
	var clock: Node = get_tree().get_first_node_in_group("game_clock")
	_time_label.text = ("Day %d   %s" % [clock.day, clock.clock_text()]) if clock != null else ""
	_sound_button.text = "Sound: off" if AudioManager.muted else "Sound: on"

func _toggle_sound() -> void:
	AudioManager.set_muted(not AudioManager.muted)
	_refresh_text()

func _ask_restart() -> void:
	_main_box.visible = false
	_confirm_box.visible = true

func _cancel_restart() -> void:
	_main_box.visible = true
	_confirm_box.visible = false

func _restart() -> void:
	paused = false
	AudioManager.hold(false)
	get_tree().paused = false
	var fast: Node = get_node_or_null("/root/FastForward")
	if fast != null:
		fast.set_index(0)
	_show_panel(false)
	get_tree().reload_current_scene()
