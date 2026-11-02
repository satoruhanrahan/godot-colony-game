extends Node

# THE ORDERS PANEL: E (or a click) on a colonist opens it, beside him: the UI theme, the pixel UI font, a title with his name ("Friend"), a
# close X, his status line ("Following you", "Chopping a tree (3 marked left)" ...) and two sections:
#   STANCE: Follow me, Assist me, Stay here, Free time (choosing one closes the panel with "Friend: Following you." and a soft click).
#   WORK:   the ROLES (Lumberjack, Sawyer, Hauler, Builder: tick the ones he should do by himself, in priority order with up / down
#           arrows; each has a short description), the TASK buttons that start a designation on the main view (Chop these trees,
#           Saw logs into planks, Haul to storage, Build these; the panel closes and designation_mode.gd takes over), a line saying what
#           is queued, a "Tasks paused while following" note when his stance pauses the work, and Clear all orders.
# Esc, E again, a click outside, or walking more than close_distance_px away closes it. It does not pause the game. It is the same panel for
# every colonist (setup(colonist)): later settlers get the same orders without new code. The content scrolls when it is taller than the window.

const Orders = preload("res://scripts/colonist_orders.gd")

@export var close_distance_px: float = 96.0

var colonist: Node2D = null
var is_open: bool = false
var _root: Control
var _panel: PanelContainer
var _scroll: ScrollContainer
var _column: VBoxContainer
var _status: Label
var _stance_note: Label
var _tasks_label: Label
var _farm_label: Label
var _cook_label: Label
var _target_label: Label
var _paused_label: Label
var _roles_box: VBoxContainer
var _buttons: Dictionary = {}
var _role_state: Array = []

func setup(c: Node2D) -> void:
	colonist = c
	Ui.register_closable(Callable(self, "is_panel_open"), Callable(self, "close"), "the orders panel", Ui.TIER_PANEL)

func is_panel_open() -> bool:
	return is_open

func _exit_tree() -> void:
	if is_instance_valid(_root):
		_root.queue_free()

func open_for(_who: Node) -> void:
	if is_open or colonist == null:
		return
	is_open = true
	Ui.sfx("ui_open")
	_build()

func close() -> void:
	if not is_open:
		return
	is_open = false
	Ui.sfx("ui_close")
	if is_instance_valid(_root):
		_root.queue_free()
	_root = null
	_panel = null
	_scroll = null
	_status = null
	_tasks_label = null
	_farm_label = null
	_cook_label = null
	_target_label = null
	_paused_label = null
	_roles_box = null
	_buttons.clear()
	_role_state = []

func _process(_delta: float) -> void:
	if not is_open:
		return
	var player: Node2D = get_tree().get_first_node_in_group("player")
	if colonist == null or not is_instance_valid(colonist) or colonist.dead or player == null or player.global_position.distance_to(colonist.global_position) > close_distance_px or colonist.talk_block_reason() != "":
		close()
		return
	if is_instance_valid(_status):
		_status.text = colonist.status_text()
	for stance in _buttons:
		_buttons[stance].set_pressed_no_signal(colonist.orders.stance == stance)
	if is_instance_valid(_tasks_label):
		var queued: String = colonist.orders.tasks_text()
		_tasks_label.text = "Queued: %s" % queued if queued != "" else "No tasks queued."
	if is_instance_valid(_farm_label):
		# the farm zones: "2 zones, 38 cells, 12 ripe" (and a farmer with none says so)
		var summary: String = load("res://scripts/plot_manager.gd").get_for(get_tree()).farm_summary()
		if summary == "" and colonist.orders.has_role(&"farmer"):
			summary = "No farm zone"
		_farm_label.text = ("Farm: %s" % summary) if summary != "" else ""
		_farm_label.visible = summary != ""
	if is_instance_valid(_target_label):
		_target_label.text = "Bread target: %d" % colonist.colony.bread_target
	if is_instance_valid(_cook_label):
		_cook_label.text = load("res://scripts/cook_jobs.gd").summary(get_tree(), colonist) if colonist.orders.has_role(&"cook") else ""
		_cook_label.visible = _cook_label.text != ""
	if is_instance_valid(_paused_label):
		_paused_label.text = colonist.paused_text()
		_paused_label.visible = _paused_label.text != ""
	if _role_state != colonist.orders.roles:
		_refresh_roles()
	_place()

# The bread target of the Cook: one more or less, kept between 0 and 20.
func _change_target(step: int) -> void:
	colonist.colony.bread_target = clampi(int(colonist.colony.bread_target) + step, 0, 20)
	Ui.sfx("ui_click")

func choose(stance: int) -> void:
	colonist.set_stance(stance)
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say("%s: %s" % [colonist.display_name, Orders.ACK[stance]])
	Ui.sfx("ui_click")
	close()

func _small_label(text: String, variation: StringName = &"DimLabel") -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	label.add_theme_font_size_override("font_size", Ui.font_size("small"))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = float(Ui.px(260))
	return label

func _button(text: String, minimum: Vector2 = Vector2.ZERO) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.custom_minimum_size = Vector2(Ui.px(minimum.x), Ui.px(minimum.y if minimum.y > 0.0 else 34.0))
	Ui.decorate_button(button)
	return button

func _build() -> void:
	_root = Control.new()
	_root.name = "OrdersPanel"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.menu_root.add_child(_root)
	var catcher := Control.new()
	catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	catcher.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			close())
	_root.add_child(catcher)
	_panel = PanelContainer.new()
	_panel.theme_type_variation = &"DarkPanel"
	_root.add_child(_panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", Ui.px(6))
	_panel.add_child(outer)
	# the title and the close X stay where they are while the rest scrolls
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", Ui.px(6))
	outer.add_child(top)
	var banner := PanelContainer.new()
	banner.theme_type_variation = &"Banner"
	banner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(banner)
	var title := Label.new()
	title.text = colonist.display_name
	title.theme_type_variation = &"HeadingLabel"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_child(title)
	var close_button := _button("X", Vector2(40, 40))
	close_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	close_button.pressed.connect(close)
	top.add_child(close_button)
	_status = _small_label("", &"BrassLabel")
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(_status)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	outer.add_child(_scroll)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", Ui.px(6))
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_column)
	# --- Stance
	_column.add_child(_small_label("Stance"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Ui.px(6))
	grid.add_theme_constant_override("v_separation", Ui.px(6))
	_column.add_child(grid)
	_stance_note = _small_label("")
	for stance in [Orders.Stance.FOLLOW, Orders.Stance.ASSIST, Orders.Stance.STAY, Orders.Stance.FREE]:
		var button := _button(Orders.NAMES[stance], Vector2(128, 34))
		button.toggle_mode = true
		button.tooltip_text = Orders.DESCRIPTIONS[stance]
		button.pressed.connect(choose.bind(stance))
		button.mouse_entered.connect(func() -> void:
			if is_instance_valid(_stance_note):
				_stance_note.text = Orders.DESCRIPTIONS[stance])
		grid.add_child(button)
		_buttons[stance] = button
	_stance_note.text = Orders.DESCRIPTIONS[colonist.orders.stance]
	_column.add_child(_stance_note)
	# --- Work: roles
	_column.add_child(HSeparator.new())
	_column.add_child(_small_label("Work: roles (he does these by himself while there is work, in this order)"))
	_roles_box = VBoxContainer.new()
	_roles_box.add_theme_constant_override("separation", Ui.px(3))
	_column.add_child(_roles_box)
	_refresh_roles()
	# --- Work: tasks
	_column.add_child(HSeparator.new())
	_column.add_child(_small_label("Work: tasks (one-off orders, done before the roles)"))
	for task_type in Orders.TASK_TYPES:
		var task_button := _button(Orders.TASK_NAMES[task_type], Vector2(260, 34))
		task_button.pressed.connect(_start_task.bind(task_type))
		_column.add_child(task_button)
	_tasks_label = _small_label("")
	_column.add_child(_tasks_label)
	_farm_label = _small_label("")
	_column.add_child(_farm_label)
	# the Cook: the bread target (- and +, 0 to 20) and the stock summary
	var target_row := HBoxContainer.new()
	target_row.add_theme_constant_override("separation", Ui.px(6))
	_column.add_child(target_row)
	var minus := _button("-", Vector2(30, 30))
	minus.tooltip_text = "Bake less bread"
	minus.pressed.connect(_change_target.bind(-1))
	target_row.add_child(minus)
	_target_label = _small_label("")
	target_row.add_child(_target_label)
	var plus := _button("+", Vector2(30, 30))
	plus.tooltip_text = "Bake more bread"
	plus.pressed.connect(_change_target.bind(1))
	target_row.add_child(plus)
	_cook_label = _small_label("")
	_column.add_child(_cook_label)
	_paused_label = _small_label("", &"BrassLabel")
	_column.add_child(_paused_label)
	var clear := _button("Clear all orders", Vector2(260, 34))
	clear.pressed.connect(_clear)
	_column.add_child(clear)
	await get_tree().process_frame
	_place()

# The role rows: the ticked ones first in priority order (with their number and arrows), then the others.
func _refresh_roles() -> void:
	if not is_instance_valid(_roles_box):
		return
	_role_state = colonist.orders.roles.duplicate()
	for child in _roles_box.get_children():
		child.queue_free()
	var order: Array = colonist.orders.roles.duplicate()
	for role in Orders.ROLES:
		if not order.has(role):
			order.append(role)
	for role in order:
		var on: bool = colonist.orders.has_role(role)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Ui.px(4))
		_roles_box.add_child(row)
		var toggle := _button(("%d. %s" % [colonist.orders.roles.find(role) + 1, Orders.ROLE_NAMES[role]]) if on else Orders.ROLE_NAMES[role], Vector2(150, 32))
		toggle.toggle_mode = true
		toggle.set_pressed_no_signal(on)
		toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		toggle.pressed.connect(_toggle_role.bind(role))
		row.add_child(toggle)
		var up := _button("^", Vector2(32, 32))
		up.disabled = not on or colonist.orders.roles.find(role) <= 0
		up.pressed.connect(_move_role.bind(role, -1))
		row.add_child(up)
		var down := _button("v", Vector2(32, 32))
		down.disabled = not on or colonist.orders.roles.find(role) >= colonist.orders.roles.size() - 1
		down.pressed.connect(_move_role.bind(role, 1))
		row.add_child(down)
		_roles_box.add_child(_small_label(Orders.ROLE_DESCRIPTIONS[role]))

func _toggle_role(role: StringName) -> void:
	var had: bool = colonist.orders.has_role(role)
	colonist.orders.toggle_role(role)
	if had:
		colonist.orders_changed()
	if not colonist.orders.has_role(role) and colonist.order_ai.work_job != null and colonist.order_ai.work_job.role == role:
		colonist.order_ai.release_all(false)
	Ui.sfx("ui_click")
	_refresh_roles()

func _move_role(role: StringName, step: int) -> void:
	colonist.orders.move_role(role, step)
	Ui.sfx("ui_click")
	_refresh_roles()

func _start_task(task_type: StringName) -> void:
	var mode: Node = get_tree().get_first_node_in_group("designation_mode")
	if mode == null:
		return
	var who = colonist
	close()
	mode.start(who, task_type)

func _clear() -> void:
	colonist.orders_changed()
	colonist.order_ai.release_all(true)
	colonist.orders.clear_work()
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say("%s: All orders cleared." % colonist.display_name)
	Ui.sfx("ui_click")
	_refresh_roles()

func _place() -> void:
	if not is_instance_valid(_panel) or colonist == null or not is_instance_valid(_scroll):
		return
	# the list is as tall as its content, up to what the window leaves
	var screen: Vector2 = Ui.screen_size()
	var content: float = _column.get_combined_minimum_size().y
	var header: float = float(Ui.px(120))
	_scroll.custom_minimum_size = Vector2(_column.get_combined_minimum_size().x + float(Ui.px(12)), minf(content, maxf(float(Ui.px(160)), screen.y - header - float(Ui.px(40)))))
	_panel.reset_size()
	var size: Vector2 = _panel.get_combined_minimum_size()
	_panel.size = size
	var at: Vector2 = Ui.to_screen(colonist.get_viewport(), colonist.global_position + Vector2(14, -10))
	var pos: Vector2 = (at + Vector2(float(Ui.px(24)), -size.y * 0.5)).round()
	pos.x = clampf(pos.x, 6.0, maxf(6.0, screen.x - size.x - 6.0))
	pos.y = clampf(pos.y, 6.0, maxf(6.0, screen.y - size.y - 6.0))
	_panel.position = pos
