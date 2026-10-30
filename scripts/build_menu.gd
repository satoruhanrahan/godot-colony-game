extends Node

# The build menu: a themed panel docked at the right edge of the window (it leaves the game most visible), opened with B (or
# the "Build (B)" button) and closed with the same key, Esc or right-click. Category tabs (Housing, Storage, Food and Water,
# Workshop: each building's `category`), and a card for every building: its real sprite as a thumbnail in a framed slot, its
# name in the heading font, its one-line `description`, its cost as little item icons with counts, a badge (Indoor /
# Outdoor) and its number key. Cards that cannot be placed now are greyed, with the reason shown on hover. Hovering a
# card raises it with a brass glow; a click (or its number key, or the wheel) chooses it and the ghost follows the mouse
# exactly as before. All the building logic stays in BuildMode.
#
# THE WHEEL, over the menu (it never reaches the world: no zoom, nothing else): over the cards one notch steps the selection to the
# next (wheel down) / previous available card in the order of the layout (tabs left to right, cards top to bottom, locked and
# greyed cards skipped), carrying on into the next / previous enabled tab and wrapping round at the ends; the selection highlight
# moves (a quiet tick) and the list scrolls it into view when it overflows. Over the tab row it switches to the next / previous
# enabled tab. Nothing enters placement until a click (or a number key) as before.
#
# Everything is the UI's (screen space, real resolution) and is rebuilt when the window changes size.

const PLANK_ICON: String = "res://sprites/one_plank.png"
const BLADE_ICON: String = "res://sprites/saw_blade.png"
const CATEGORY_ORDER: Array[String] = ["Housing", "Storage", "Food and Water", "Workshop"]
const Items = preload("res://scripts/items.gd")

var mode: Node2D
var _root: Control
var _panel: PanelContainer
var _hint: Label
var _cards_box: VBoxContainer
var _open_button: Button
var _tab_buttons: Dictionary = {}
var _tabs_row: HBoxContainer
var _scroll: ScrollContainer
var _categories: Array[String] = []
var _current: String = ""
var _open: bool = false
var _hover: int = -1
# The building that was chosen when the tab was last set from it: the tab follows a NEW choice (number key, wheel, opening the
# menu), but a click on a tab stays (this was the bug: every frame put the tab back to the chosen building's).
var _last_chosen: int = -1
var _tween: Tween
# One entry per building type: {index, type, category, wrap, card, glow, slot, desc, name_label, badge, reason}
var cards: Array[Dictionary] = []

func setup(build_mode: Node2D) -> void:
	mode = build_mode
	for type in mode.building_types:
		var category: String = type.category if type.category != "" else "Other"
		if not _categories.has(category):
			_categories.append(category)
	_categories.sort_custom(func(a: String, b: String) -> bool:
		var ia: int = CATEGORY_ORDER.find(a)
		var ib: int = CATEGORY_ORDER.find(b)
		return (ia if ia >= 0 else 99) < (ib if ib >= 0 else 99))
	_current = _categories[0] if not _categories.is_empty() else ""
	_build()
	Ui.ui_changed.connect(_on_ui_changed)

func close_ui() -> void:
	if Ui.ui_changed.is_connected(_on_ui_changed):
		Ui.ui_changed.disconnect(_on_ui_changed)
	if is_instance_valid(_root):
		_root.queue_free()

# How many cards each tab holds (for the self-check).
func card_counts() -> Dictionary:
	var out: Dictionary = {}
	for card in cards:
		out[card["category"]] = int(out.get(card["category"], 0)) + 1
	return out

func is_open() -> bool:
	return _open

func _on_ui_changed() -> void:
	_build()
	set_open(_open, false)

# --- Building the panel ---------------------------------------------------------------------------------------------

func _ignore(node: Node) -> void:
	if node is Control:
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore(child)

func _build() -> void:
	if is_instance_valid(_root):
		_root.queue_free()
	cards.clear()
	_tab_buttons.clear()
	_root = Control.new()
	_root.name = "BuildMenu"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.menu_root.add_child(_root)
	# the always-there "Build (B)" button, bottom-centre
	_open_button = Button.new()
	_open_button.text = "Build (%s)" % mode.shortcut_hint
	_open_button.toggle_mode = true
	_open_button.focus_mode = Control.FOCUS_NONE
	_open_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_open_button.custom_minimum_size = Vector2(Ui.px(128), Ui.px(42))
	_open_button.anchor_left = 0.5
	_open_button.anchor_right = 0.5
	_open_button.anchor_top = 1.0
	_open_button.anchor_bottom = 1.0
	_open_button.offset_left = -Ui.px(64)
	_open_button.offset_right = Ui.px(64)
	_open_button.offset_top = -Ui.px(54)
	_open_button.offset_bottom = -Ui.px(12)
	Ui.decorate_button(_open_button)
	_open_button.toggled.connect(func(on: bool) -> void:
		if mode.active != on:
			mode._set_active(on))
	_root.add_child(_open_button)
	# the panel
	_panel = PanelContainer.new()
	_panel.theme_type_variation = &"ParchmentPanel"
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	var width: int = int(Ui.px(Ui.cfg.menu_width))
	_panel.offset_left = -width - Ui.px(16)
	_panel.offset_right = -Ui.px(16)
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size.x = width
	_root.add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Ui.px(8))
	_panel.add_child(column)
	var banner := PanelContainer.new()
	banner.theme_type_variation = &"Banner"
	column.add_child(banner)
	var title := Label.new()
	title.text = "Build"
	title.theme_type_variation = &"HeadingLabel"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_child(title)
	_hint = Label.new()
	_hint.theme_type_variation = &"InkLabel"
	_hint.add_theme_font_size_override("font_size", Ui.font_size("small"))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.text = "Scroll or press 1-%d to choose, click to place, Esc to close" % mode.building_types.size()
	column.add_child(_hint)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", Ui.px(2))
	tabs.mouse_filter = Control.MOUSE_FILTER_STOP
	tabs.gui_input.connect(_on_wheel_input.bind(true))
	column.add_child(tabs)
	_tabs_row = tabs
	var group := ButtonGroup.new()
	for category in _categories:
		var tab := Button.new()
		tab.text = category
		tab.theme_type_variation = &"TabButton"
		tab.toggle_mode = true
		tab.button_group = group
		tab.focus_mode = Control.FOCUS_NONE
		tab.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.add_theme_font_size_override("font_size", Ui.font_size("small"))
		tab.add_theme_color_override("font_color", Ui.cfg.parchment)
		tab.button_pressed = category == _current
		tab.mouse_entered.connect(func() -> void:
			if not tab.disabled:
				Ui.sfx("ui_hover"))
		tab.pressed.connect(_on_tab.bind(category))
		tab.gui_input.connect(_on_wheel_input.bind(true))
		tabs.add_child(tab)
		_tab_buttons[category] = tab
	# the cards in a scroll container (it grows to fit, and scrolls only when the tab is taller than the window)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_scroll)
	_cards_box = VBoxContainer.new()
	_cards_box.add_theme_constant_override("separation", Ui.px(8))
	_cards_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_cards_box)
	_panel.gui_input.connect(_on_wheel_input.bind(false))
	for i in mode.building_types.size():
		_make_card(i, mode.building_types[i])
	_apply_category()
	refresh()

func _on_tab(category: String) -> void:
	if _tab_buttons.has(category) and _tab_buttons[category].disabled:
		_apply_category()
		return
	if category != _current:
		Ui.sfx("ui_click")
	_current = category
	_apply_category()
	refresh()

func _apply_category() -> void:
	var shown: int = 0
	for card in cards:
		card["wrap"].visible = card["category"] == _current
		if card["wrap"].visible:
			shown += 1
	# the list is as tall as its cards, up to what fits under the header
	if is_instance_valid(_scroll) and shown > 0:
		var needed: float = shown * (float(Ui.px(Ui.cfg.card_height)) + Ui.px(6)) + (shown - 1) * Ui.px(8)
		var available: float = maxf(float(Ui.px(120)), Ui.screen_size().y - float(Ui.px(240)))
		_scroll.custom_minimum_size.y = minf(needed, available)
	for category in _tab_buttons:
		_tab_buttons[category].set_pressed_no_signal(category == _current)

func _make_card(index: int, type: BuildingType) -> void:
	var height: float = float(Ui.px(Ui.cfg.card_height))
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(0, height + Ui.px(6))
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cards_box.add_child(wrap)
	# the brass glow behind a hovered card
	var glow := Panel.new()
	var glow_box := StyleBoxFlat.new()
	glow_box.bg_color = Color(0, 0, 0, 0)
	glow_box.border_color = Ui.cfg.brass
	glow_box.set_border_width_all(max(2, Ui.px(2)))
	glow_box.shadow_color = Color(Ui.cfg.brass.r, Ui.cfg.brass.g, Ui.cfg.brass.b, 0.55)
	glow_box.shadow_size = Ui.px(9)
	glow_box.set_corner_radius_all(Ui.px(3))
	glow.add_theme_stylebox_override("panel", glow_box)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.visible = false
	wrap.add_child(glow)
	var card := PanelContainer.new()
	card.theme_type_variation = &"DarkPanel"
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	wrap.add_child(card)
	for c in [glow, card]:
		c.anchor_right = 1.0
		c.anchor_bottom = 1.0
		c.offset_top = Ui.px(5)
		c.offset_bottom = -Ui.px(1)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Ui.px(12))
	card.add_child(row)
	# the thumbnail in its framed slot
	var slot := PanelContainer.new()
	slot.theme_type_variation = &"SlotPanel"
	var inner: float = float(Ui.px(66))
	slot.custom_minimum_size = Vector2(inner + Ui.px(12), inner + Ui.px(12))
	slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slot)
	slot.add_child(_thumbnail(type, inner))
	# name, description
	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text_box.add_theme_constant_override("separation", Ui.px(2))
	row.add_child(text_box)
	var name_row := HBoxContainer.new()
	var lock_icon := TextureRect.new()
	name_row.add_theme_constant_override("separation", Ui.px(8))
	text_box.add_child(name_row)
	var name_label := Label.new()
	name_label.text = type.type_name
	name_label.theme_type_variation = &"HeadingLabel"
	name_label.add_theme_font_size_override("font_size", Ui.font_size("heading") if Ui.pixel_active else Ui.px(19))
	name_row.add_child(name_label)
	var key_label := Label.new()
	key_label.text = str(index + 1)
	key_label.theme_type_variation = &"BrassLabel"
	key_label.add_theme_font_size_override("font_size", Ui.font_size("small"))
	name_row.add_child(key_label)
	# a small lock while the building is still locked
	if ResourceLoader.exists("res://ui/icon_lock.png"):
		lock_icon.texture = load("res://ui/icon_lock.png")
	lock_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	lock_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	lock_icon.stretch_mode = TextureRect.STRETCH_SCALE
	lock_icon.custom_minimum_size = Vector2(Ui.art_scale() * 7, Ui.art_scale() * 9)
	lock_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lock_icon.visible = false
	name_row.add_child(lock_icon)
	var desc := Label.new()
	desc.text = type.description
	desc.add_theme_font_size_override("font_size", Ui.font_size("small"))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size.x = Ui.px(150)
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_child(desc)
	# the badge and the cost
	var side := VBoxContainer.new()
	side.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	side.add_theme_constant_override("separation", Ui.px(4))
	row.add_child(side)
	var badge := Label.new()
	badge.text = _badge_text(type)
	badge.theme_type_variation = &"DimLabel"
	badge.add_theme_font_size_override("font_size", Ui.font_size("small"))
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	side.add_child(badge)
	var costs := HFlowContainer.new()
	costs.add_theme_constant_override("h_separation", Ui.px(6))
	costs.alignment = FlowContainer.ALIGNMENT_END
	for item in type.cost_items():
		var pair := HBoxContainer.new()
		pair.add_theme_constant_override("separation", Ui.px(2))
		var icon := TextureRect.new()
		icon.texture = _cost_icon(item[0])
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		var icon_size: Vector2 = icon.texture.get_size() if icon.texture != null else Vector2(8, 8)
		var box: float = float(Ui.px(34))
		icon.custom_minimum_size = icon_size * float(maxi(1, floori(minf(box / icon_size.x, box / icon_size.y))))
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pair.add_child(icon)
		var count := Label.new()
		count.text = "x%d" % item[1]
		count.add_theme_font_size_override("font_size", Ui.font_size("small"))
		pair.add_child(count)
		costs.add_child(pair)
	side.add_child(costs)
	_ignore(card)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_entered.connect(_on_card_hover.bind(index, true))
	card.mouse_exited.connect(_on_card_hover.bind(index, false))
	card.gui_input.connect(_on_card_input.bind(index))
	cards.append({"index": index, "type": type, "category": type.category if type.category != "" else "Other", "wrap": wrap, "card": card,
		"glow": glow, "slot": slot, "desc": desc, "name_label": name_label, "badge": badge, "reason": "", "lock": lock_icon})

func _badge_text(type: BuildingType) -> String:
	if type.indoor_only:
		return "Indoor"
	if type.indoor_ok:
		return "Indoor / Outdoor"
	return "Outdoor"

func _cost_icon(kind: StringName) -> Texture2D:
	var tex: Texture2D = null
	if kind == &"plank":
		tex = load(PLANK_ICON)
	elif kind == &"blade":
		tex = load(BLADE_ICON)
	elif Items.KINDS.has(kind):
		tex = Items.texture(kind)
	if tex == null:
		return null
	# cropped to what is drawn (the pictures have empty canvas round them)
	var used: Rect2i = tex.get_image().get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return tex
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2(used)
	return atlas

# The real sprite, cropped to what is drawn, at the biggest whole-number scale that fits the slot (half size when even the
# plain sprite is bigger), nearest filter, centred.
func _thumbnail(type: BuildingType, inner: float) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(inner, inner)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex: Texture2D = type.texture
	if tex == null:
		return holder
	var used: Rect2i = tex.get_image().get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		used = Rect2i(Vector2i.ZERO, tex.get_size())
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2(used)
	var fit: float = minf(inner / used.size.x, inner / used.size.y)
	var factor: float = float(floori(fit)) if fit >= 1.0 else 0.5
	var rect := TextureRect.new()
	rect.texture = atlas
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.size = Vector2(used.size) * factor
	rect.position = ((Vector2(inner, inner) - rect.size) * 0.5).round()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(rect)
	return holder

# --- Behaviour ------------------------------------------------------------------------------------------------------

func _on_card_hover(index: int, inside: bool) -> void:
	if inside:
		_hover = index
		Ui.sfx("ui_hover")
	elif _hover == index:
		_hover = -1
	refresh()

func _on_card_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				Ui.sfx("ui_click")
				mode.choose(index)
			MOUSE_BUTTON_WHEEL_DOWN:
				step_card(1)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP:
				step_card(-1)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_RIGHT:
				mode._set_active(false)

# The wheel anywhere on the panel (over the tab row: tabs; elsewhere: the cards).
func _on_wheel_input(event: InputEvent, over_tabs: bool) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	var step: int = 0
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		step = 1
	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		step = -1
	if step == 0:
		return
	if over_tabs:
		step_tab(step)
	else:
		step_card(step)
	get_viewport().set_input_as_handled()

# The cards the wheel can reach, in layout order: enabled tabs left to right, each tab's cards top to bottom, without the ones
# that are locked or cannot be placed now.
func walk_order() -> Array[int]:
	var out: Array[int] = []
	for category in _categories:
		if _tab_buttons.has(category) and _tab_buttons[category].disabled:
			continue
		for card in cards:
			if card["category"] == category and not mode.is_unlock_locked(card["type"]) and mode.unavailable_reason(card["type"]) == "":
				out.append(card["index"])
	return out

# One wheel notch over the cards: +1 the next available card, -1 the previous (wrapping round at the ends).
func step_card(step: int) -> void:
	var order: Array[int] = walk_order()
	if order.is_empty():
		return
	var at: int = order.find(mode.type_index)
	var next: int
	if at < 0:
		next = order[0] if step > 0 else order[order.size() - 1]
	else:
		next = order[(at + step + order.size()) % order.size()]
	Ui.sfx("ui_hover")
	mode.choose(next)
	refresh()
	_scroll_to(next)

# One wheel notch over the tab row: the next / previous enabled tab.
func step_tab(step: int) -> void:
	var count: int = _categories.size()
	var index: int = _categories.find(_current)
	for i in count:
		index = (index + step + count) % count
		if not _tab_buttons[_categories[index]].disabled:
			if _categories[index] != _current:
				Ui.sfx("ui_hover")
				_current = _categories[index]
				_apply_category()
				refresh()
			return

# Scrolls the list so this card is in view (after the layout has caught up).
func _scroll_to(index: int) -> void:
	await get_tree().process_frame
	if not is_instance_valid(_scroll):
		return
	for card in cards:
		if card["index"] == index and card["wrap"].visible:
			_scroll.ensure_control_visible(card["wrap"])

func set_open(on: bool, fade: bool = true) -> void:
	_open = on
	if not is_instance_valid(_panel):
		return
	_open_button.set_pressed_no_signal(on)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_panel.visible = on
	if on:
		# the tab of the chosen building
		var type: BuildingType = mode.building_types[mode.type_index]
		if type.category != "" and type.category != _current and _tab_buttons.has(type.category):
			_current = type.category
			_apply_category()
		_last_chosen = mode.type_index
		_panel.modulate.a = 0.0 if fade else 1.0
		if fade:
			_tween = create_tween().set_ignore_time_scale(true)
			_tween.tween_property(_panel, "modulate:a", 1.0, Ui.cfg.menu_fade_seconds)
		refresh()
	else:
		_hover = -1

# The cards show what is chosen, what is hovered and what cannot be placed now.
func refresh() -> void:
	if not is_instance_valid(_panel) or not _open:
		return
	# the tab follows a NEW choice only (a click on a tab is left alone)
	if mode.type_index != _last_chosen:
		_last_chosen = mode.type_index
		var chosen: BuildingType = mode.building_types[mode.type_index]
		if chosen.category != "" and chosen.category != _current and _tab_buttons.has(chosen.category) and mode.active:
			_current = chosen.category
			_apply_category()
	# a tab with nothing unlocked in it is greyed and cannot be clicked
	for category in _tab_buttons:
		var any: bool = false
		for card in cards:
			if card["category"] == category and not mode.is_unlock_locked(card["type"]):
				any = true
		var tab: Button = _tab_buttons[category]
		tab.disabled = not any
		tab.modulate = Color.WHITE if any else Color(0.6, 0.58, 0.55, 0.8)
		tab.tooltip_text = "" if any else "Nothing available yet"
		tab.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if any else Control.CURSOR_ARROW
	if _tab_buttons.has(_current) and _tab_buttons[_current].disabled:
		for category in _categories:
			if not _tab_buttons[category].disabled:
				_current = category
				_apply_category()
				break
	for card in cards:
		var type: BuildingType = card["type"]
		var reason: String = mode.unavailable_reason(type)
		card["reason"] = reason
		card["lock"].visible = mode.is_unlock_locked(type)
		var selected: bool = card["index"] == mode.type_index
		var hovered: bool = card["index"] == _hover
		card["slot"].theme_type_variation = &"SlotPanelSelected" if selected else &"SlotPanel"
		card["card"].modulate = Color(0.55, 0.52, 0.48, 0.95) if reason != "" else (Color(1.12, 1.08, 1.0) if hovered else Color.WHITE)
		var glow: Panel = card["glow"]
		glow.visible = (hovered and reason == "") or selected
		var box: StyleBoxFlat = glow.get_theme_stylebox("panel")
		var glow_color: Color = Ui.cfg.verdigris if selected and not hovered else Ui.cfg.brass
		box.border_color = glow_color
		box.shadow_color = Color(glow_color.r, glow_color.g, glow_color.b, 0.55 if hovered else 0.35)
		# hovered: raised a few pixels
		var raise: int = Ui.px(4) if hovered and reason == "" else 0
		for c in [glow, card["card"]]:
			c.offset_top = Ui.px(5) - raise
			c.offset_bottom = -Ui.px(1) - raise
		# an unavailable card says why on hover (its description comes back otherwise)
		var desc: Label = card["desc"]
		var text: String = reason if (hovered and reason != "") else type.description
		if desc.text != text:
			desc.text = text
		if hovered and reason != "":
			desc.add_theme_color_override("font_color", Color(0.93, 0.5, 0.42))
		else:
			desc.remove_theme_color_override("font_color")

# [ and ] (or Page Up / Page Down) switch to the previous / next tab while the menu is open (Q, E and the arrows are taken: drop,
# interact and walking). Tabs with nothing available are skipped.
func _unhandled_input(event: InputEvent) -> void:
	if not _open or not (event is InputEventKey and event.pressed and not event.echo):
		return
	var step: int = 0
	if event.keycode == KEY_BRACKETRIGHT or event.keycode == KEY_PAGEDOWN:
		step = 1
	elif event.keycode == KEY_BRACKETLEFT or event.keycode == KEY_PAGEUP:
		step = -1
	if step == 0:
		return
	var count: int = _categories.size()
	var index: int = _categories.find(_current)
	for i in count:
		index = (index + step + count) % count
		if not _tab_buttons[_categories[index]].disabled:
			_on_tab(_categories[index])
			break
	get_viewport().set_input_as_handled()
