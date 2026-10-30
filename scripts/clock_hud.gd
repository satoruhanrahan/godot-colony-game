extends Node

# The clock at the top-right of the HUD: a small sun or moon icon, "Day N", and a thin strip showing
# the time of day (the night part darker, a tick for now). Outlined text, no panel. In the Minimal
# HUD only the icon stays. The icons are placeholders drawn in code (pixel_icons.gd).

const PixelIcons = preload("res://scripts/pixel_icons.gd")

@export var margin: float = 5.0
@export var strip_width: float = 56.0
@export var strip_height: float = 3.0
@export var strip_day_color: Color = Color(0.95, 0.78, 0.35)
@export var strip_dusk_color: Color = Color(0.85, 0.45, 0.3)
@export var strip_night_color: Color = Color(0.12, 0.14, 0.32)
@export var strip_outline_color: Color = Color(0.05, 0.04, 0.07)
@export var strip_now_color: Color = Color(1, 1, 1)

var _clock: Node
var _icon: TextureRect
var _label: Label
var _ff_label: Label
var _strip: Control
# The fast-forward button (drawn in code): a few small triangles, one more for each faster step, and the speed
# as "x2" / "x4" beside them. Click it, or press X, to cycle 1x, 2x, 4x.
var _ff_button: Control
const FF_SIZE: Vector2 = Vector2(26.0, 11.0)

# The pixel-art parts (the icon, the strip, the button) are in the UI's art layer, laid out in art pixels from the
# top-right corner; the text ("Day N", "x2") is the UI's crisp text, placed from them.
func _ready() -> void:
	var layer: Control = Ui.art_root
	_icon = TextureRect.new()
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon.stretch_mode = TextureRect.STRETCH_KEEP
	layer.add_child(_icon)
	_label = Ui.screen_label("body")
	_ff_label = Ui.screen_label("small")
	_strip = Control.new()
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_strip.draw.connect(_draw_strip)
	layer.add_child(_strip)
	_ff_button = Control.new()
	_ff_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_ff_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_ff_button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_ff_button.size = FF_SIZE
	_ff_button.draw.connect(_draw_ff)
	_ff_button.gui_input.connect(_on_ff_input)
	layer.add_child(_ff_button)

func _exit_tree() -> void:
	for node in [_icon, _label, _ff_label, _strip, _ff_button]:
		if is_instance_valid(node):
			node.queue_free()

func _process(_delta: float) -> void:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
		if _clock == null:
			return
	var hud: Node = get_tree().get_first_node_in_group("hud")
	var minimal: bool = hud != null and hud.is_minimal()
	var art: float = float(Ui.art_scale())
	# The moon from dusk to dawn, the sun by day.
	var dark: bool = _clock.is_bedtime()
	_icon.texture = PixelIcons.moon() if dark else PixelIcons.sun()
	_icon.size = _icon.texture.get_size()
	var text: String = "Day %d" % _clock.day
	if _label.text != text:
		_label.text = text
	_label.size = _label.get_combined_minimum_size()
	_label.visible = not minimal
	_strip.visible = not minimal
	# Right-aligned (left of the pause button): the text, the icon to its left; the strip under both. Art pixels.
	var right: float = Ui.art_size().x - margin - Ui.top_right_reserve
	var label_w: float = _label.size.x / art if _label.visible else 0.0
	var label_h: float = _label.size.y / art
	var row_h: float = maxf(_icon.size.y, label_h)
	_label.position = Ui.snap(Vector2((right - label_w) * art, (margin + (row_h - label_h) * 0.5) * art))
	_icon.position = Vector2(roundf(right - label_w - (3.0 if _label.visible else 0.0) - _icon.size.x), margin + roundf((row_h - _icon.size.y) * 0.5))
	_strip.position = Vector2(roundf(right - strip_width), margin + row_h + 2.0)
	_strip.size = Vector2(strip_width, strip_height + 2.0)
	_strip.queue_redraw()
	_ff_button.visible = not minimal
	_ff_button.position = Vector2(roundf(_icon.position.x - FF_SIZE.x - 5.0), margin + roundf((row_h - FF_SIZE.y) * 0.5))
	_ff_button.queue_redraw()
	var fast: Node = get_node_or_null("/root/FastForward")
	_ff_label.visible = not minimal and fast != null
	if fast != null:
		_ff_label.text = "x%d" % int(fast.factor())
		_ff_label.modulate = Color(1.0, 0.85, 0.3) if fast.is_fast() else Color(0.78, 0.74, 0.66)
		_ff_label.size = _ff_label.get_combined_minimum_size()
		var at: Vector2 = Ui.art_point(_ff_button, Vector2(FF_SIZE.x - 11.0, FF_SIZE.y * 0.5))
		_ff_label.position = Ui.snap(Vector2(at.x - 2.0 * art, at.y - _ff_label.size.y * 0.5))

func _on_ff_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var fast: Node = get_node_or_null("/root/FastForward")
		if fast != null:
			fast.cycle()
		_ff_button.accept_event()

func _draw_ff() -> void:
	var fast: Node = get_node_or_null("/root/FastForward")
	if fast == null:
		return
	var outline := Color(0.05, 0.04, 0.07)
	var hovered: bool = Rect2(Vector2.ZERO, FF_SIZE).has_point(_ff_button.get_local_mouse_position())
	var active: bool = fast.is_fast()
	var fill: Color = Color(0.3, 0.22, 0.12, 0.9) if not hovered else Color(0.42, 0.3, 0.16, 0.95)
	_ff_button.draw_rect(Rect2(Vector2.ZERO, FF_SIZE), outline)
	_ff_button.draw_rect(Rect2(1, 1, FF_SIZE.x - 2, FF_SIZE.y - 2), fill)
	# One triangle per step above 1x, plus the first (so 1x shows one dim triangle, 2x two, 4x three).
	var steps: int = fast.index + 1
	var color: Color = Color(1.0, 0.85, 0.3) if active else Color(0.62, 0.58, 0.52)
	for i in steps:
		var x: float = 3.0 + i * 4.0
		_ff_button.draw_colored_polygon(PackedVector2Array([Vector2(x, 2), Vector2(x, FF_SIZE.y - 2), Vector2(x + 3, FF_SIZE.y * 0.5)]), color)

func _draw_strip() -> void:
	if _clock == null:
		return
	var w: int = int(strip_width)
	var h: int = int(strip_height)
	_strip.draw_rect(Rect2(0, 0, w, h + 2), strip_outline_color)
	var night_start: float = 1.0 - _clock.night_fraction
	var dusk_start: float = night_start - _clock.transition_fraction
	for x in range(1, w - 1):
		var t: float = float(x) / float(w)
		var color: Color = strip_day_color
		if t >= night_start:
			color = strip_night_color
		elif t >= dusk_start:
			color = strip_dusk_color
		_strip.draw_rect(Rect2(x, 1, 1, h), color)
	# A tick for now, one pixel wider than the strip is tall.
	var now_x: int = clampi(int(_clock.time_of_day * w), 1, w - 2)
	_strip.draw_rect(Rect2(now_x, 0, 1, h + 2), strip_now_color)
