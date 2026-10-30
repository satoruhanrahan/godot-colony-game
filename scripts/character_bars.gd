extends Node

# THE ONE overlay of a character's bars (a Colonist - "Friend" - and the three workers share it): while the mouse is over
# a character it shows a small themed panel above them with their name or role as a heading and all their bars in the
# same order: Energy, Hunger, and Health only for a character that has a health meter (none has one yet: there is no
# health meter in the game, so none is shown). Hover only. The text is the UI's crisp text; the bars are pixel art drawn at
# a whole-number multiple (ui_art_pixel_scale).
#
# A character takes part by having a RestIndicator (rest_indicator.gd) child with hover_bar on: it says the heading and the
# bars (RestIndicator.bars()).

const BAR_W: int = 30
const BAR_H: int = 4

var _panel: PanelContainer
var _heading: Label
var _note: Label
var _rows_box: VBoxContainer
var _rows: Array[Dictionary] = []
var _current: Node = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	Ui.ui_changed.connect(_build)

func _build() -> void:
	if is_instance_valid(_panel):
		_panel.queue_free()
	_rows.clear()
	_panel = PanelContainer.new()
	_panel.theme_type_variation = &"SlotPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	Ui.menu_root.add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Ui.px(3))
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(column)
	_heading = Ui.make_label("bold", Ui.cfg.parchment, true)
	_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_heading)
	_note = Ui.make_label("small", Ui.cfg.parchment, true)
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_note)
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", Ui.px(2))
	_rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_rows_box)

# The rows of the panel are rebuilt when the set of bars changes.
func _rows_for(bars: Array) -> void:
	var same: bool = _rows.size() == bars.size()
	if same:
		for i in bars.size():
			same = same and _rows[i]["name"] == bars[i]["name"]
	if same:
		return
	for child in _rows_box.get_children():
		child.queue_free()
	_rows.clear()
	var art: int = Ui.art_scale()
	for bar in bars:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Ui.px(5))
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var icon := TextureRect.new()
		icon.texture = bar["icon"]
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(bar["icon"].get_width() * art, bar["icon"].get_height() * art)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(icon)
		var name_label := Ui.make_label("small")
		name_label.text = bar["name"]
		name_label.custom_minimum_size.x = Ui.px(46)
		row.add_child(name_label)
		var widget := BarWidget.new()
		widget.custom_minimum_size = Vector2((BAR_W + 2) * art, (BAR_H + 2) * art)
		widget.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		widget.art = art
		row.add_child(widget)
		_rows_box.add_child(row)
		_rows.append({"name": bar["name"], "widget": widget})

# The bar drawn as pixel art at `art` times its size.
class BarWidget extends Control:
	var art: int = 2
	var value: float = 1.0
	var fill: Color = Color(0.45, 0.6, 1.0)
	var back: Color = Color(0.12, 0.13, 0.22)
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	func _draw() -> void:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(art, art))
		draw_rect(Rect2(0, 0, 32, 6), Color(0.05, 0.04, 0.07))
		draw_rect(Rect2(1, 1, 30, 4), back)
		var w: int = int(floorf(clampf(value, 0.0, 1.0) * 30.0))
		if w > 0:
			draw_rect(Rect2(1, 1, w, 4), fill)

# Which character the mouse is over (the lowest one on screen when two overlap).
func hovered_character() -> Node:
	var best: Node = null
	for node in get_tree().get_nodes_in_group("char_bars"):
		if node.visible and node.is_hovered():
			if best == null or node.global_position.y > best.global_position.y:
				best = node
	return best

func _process(_delta: float) -> void:
	var who: Node = hovered_character() if not get_tree().paused else null
	_current = who
	if who == null:
		_panel.visible = false
		return
	var bars: Array = who.bars()
	_rows_for(bars)
	_heading.text = who.heading()
	_note.text = who.note()
	_note.visible = _note.text != ""
	for i in bars.size():
		var widget: BarWidget = _rows[i]["widget"]
		widget.value = bars[i]["value"] / 100.0
		widget.fill = bars[i]["color"]
		widget.back = bars[i]["back"]
		widget.queue_redraw()
	_panel.reset_size()
	var size: Vector2 = _panel.get_combined_minimum_size()
	_panel.size = size
	# above the character's head, in screen space, kept inside the window
	var at: Vector2 = Ui.to_screen(who.get_viewport(), who.global_position + Vector2(0, -who.icon_height - 8))
	var pos: Vector2 = (at - Vector2(size.x * 0.5, size.y)).round()
	var screen: Vector2 = Ui.screen_size()
	pos.x = clampf(pos.x, 2.0, maxf(2.0, screen.x - size.x - 2.0))
	pos.y = clampf(pos.y, 2.0, maxf(2.0, screen.y - size.y - 2.0))
	_panel.position = pos
	_panel.visible = true

# What the overlay shows now, for the self-check: [heading, [bar names]] or [].
func shown() -> Array:
	if _current == null or not is_instance_valid(_current):
		return []
	return [_current.heading(), _current.bars().map(func(b: Dictionary) -> String: return b["name"])]
