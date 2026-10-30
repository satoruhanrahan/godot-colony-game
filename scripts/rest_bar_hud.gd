extends Control

# The player's Energy bar (the Rest need) in the bottom-left of the HUD, just above the held-item slot: a
# lightning-bolt icon (its own node, EnergyIcon) and a thin bar. Faint while energy is high (80 or more),
# normal below that, and red and pulsing gently when it is very low (below 25), with one message the first
# time that happens each day. While energy is rising (asleep on a bed or the floor), small green triangles
# drift left to right inside the bar, clipped to its interior: how many, and how fast, shows how quick the
# recovery is (see GameClock.recovery_arrows). Outlined, no panel.

const EnergyIcon = preload("res://scripts/energy_icon.gd")
const HungerBar = preload("res://scripts/hunger_bar_hud.gd")
const ARROW_ART: String = "res://sprites/energy_arrow.png"
# The triangle drawn in code: column heights from its base to its point (rows centred on the bar).
const TRIANGLE: Array[int] = [4, 4, 2, 2]

@export var bar_width: float = 40.0
@export var bar_height: float = 4.0
@export var faint_from: float = 80.0
@export_range(0.0, 1.0) var faint_opacity: float = 0.35
# Below this energy the bar is red, pulses, and the exhausted message shows (once a day).
@export var exhausted_below: float = 25.0
# Seconds for one gentle pulse.
@export var pulse_period: float = 1.8
@export var fill_color: Color = Color(0.45, 0.6, 1.0)
@export var low_color: Color = Color(1.0, 0.3, 0.25)
@export var back_color: Color = Color(0.12, 0.13, 0.22)
@export var outline_color: Color = Color(0.05, 0.04, 0.07)
@export var exhausted_message: String = "You're exhausted - find somewhere to sleep."
# The recovery triangles: their colour (semi-transparent green over the bar) and the drift speed in
# pixels per second for each triangle in flight (1 triangle: the floor, 2: a grass / hay bed, 3: a proper
# bed), so a faster recovery both shows more triangles and moves them faster.
@export var triangle_color: Color = Color(0.45, 1.0, 0.4, 0.6)
@export var triangle_speed_per_count: float = 9.0

@onready var player = get_node("../../..")

var _clock: float = 0.0
var _icon: TextureRect
var _last_exhausted_day: int = -1
var _arrow_texture: Texture2D = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon = EnergyIcon.new()
	_icon.name = "EnergyIcon"
	add_child(_icon)
	if ResourceLoader.exists(ARROW_ART):
		_arrow_texture = load(ARROW_ART)
	# The Hunger bar sits beside the Energy bar.
	var hunger_bar: Control = HungerBar.new()
	hunger_bar.name = "HungerBar"
	hunger_bar.player = player
	hunger_bar.position = Vector2(bar_width + 21.0, 0.0)
	add_child(hunger_bar)

func _process(delta: float) -> void:
	_clock += delta
	var rest: float = player.rest.value if player.rest != null else 100.0
	var alpha: float = 1.0
	if rest < exhausted_below:
		# Gentle pulse between 70% and 100%.
		alpha = 0.7 + 0.3 * (0.5 + 0.5 * sin(_clock * TAU / pulse_period))
	elif rest >= faint_from:
		alpha = faint_opacity
	modulate.a = alpha
	# One message the first time he is exhausted each day.
	if rest < exhausted_below:
		var clock: Node = get_tree().get_first_node_in_group("game_clock")
		var day: int = clock.day if clock != null else 0
		if day != _last_exhausted_day:
			_last_exhausted_day = day
			var hud: Node = get_tree().get_first_node_in_group("hud")
			if hud != null:
				hud.say(exhausted_message)
	queue_redraw()

# How many triangles: his sleep rate decides (floor 1, grass / hay bed 2, proper bed 3); none while his
# energy is draining or not changing.
func _triangle_count() -> int:
	if player.rest == null or not player.rest.sleeping or player.rest.sleep_rate <= 0.0:
		return 0
	var clock: Node = get_tree().get_first_node_in_group("game_clock")
	return clock.recovery_arrows(player.rest.sleep_rate) if clock != null else 0

func _draw() -> void:
	var rest: float = player.rest.value if player.rest != null else 100.0
	var icon: Texture2D = _icon.texture
	var x: float = icon.get_width() + 2.0
	var y: float = roundf((icon.get_height() - bar_height - 2.0) * 0.5)
	var w: int = int(bar_width)
	draw_rect(Rect2(x, y, w + 2, bar_height + 2), outline_color)
	draw_rect(Rect2(x + 1, y + 1, w, bar_height), back_color)
	var fill_w: int = int(floorf(clampf(rest / 100.0, 0.0, 1.0) * w))
	if fill_w > 0:
		draw_rect(Rect2(x + 1, y + 1, fill_w, bar_height), low_color if rest < exhausted_below else fill_color)
	_draw_triangles(Rect2(x + 1, y + 1, w, bar_height))

func _triangle_width() -> int:
	return _arrow_texture.get_width() if _arrow_texture != null else TRIANGLE.size()

# Triangles pointing right drifting left to right across the bar's interior, looping; each is clipped to
# the interior (it slides in at the left edge and out at the right).
func _draw_triangles(inner: Rect2) -> void:
	var count: int = _triangle_count()
	if count <= 0:
		return
	var tw: int = _triangle_width()
	var span: float = inner.size.x + tw
	var speed: float = triangle_speed_per_count * float(count)
	for i in count:
		var travelled: float = fposmod(_clock * speed + span * float(i) / float(count), span)
		var left: int = int(roundf(inner.position.x - tw + travelled))
		_draw_triangle_clipped(left, int(inner.position.y), inner)

func _draw_triangle_clipped(left: int, top: int, inner: Rect2) -> void:
	var from_x: int = maxi(left, int(inner.position.x))
	var to_x: int = mini(left + _triangle_width(), int(inner.end.x))
	if to_x <= from_x:
		return
	if _arrow_texture != null:
		var src := Rect2(from_x - left, 0, to_x - from_x, _arrow_texture.get_height())
		var dst_y: int = top + int(roundf((inner.size.y - _arrow_texture.get_height()) * 0.5))
		draw_texture_rect_region(_arrow_texture, Rect2(from_x, dst_y, to_x - from_x, _arrow_texture.get_height()), src, Color(1, 1, 1, triangle_color.a))
		return
	for px in range(from_x, to_x):
		var column_height: int = TRIANGLE[px - left]
		var cy: int = top + (int(inner.size.y) - column_height) / 2
		draw_rect(Rect2(px, cy, 1, column_height), triangle_color)
