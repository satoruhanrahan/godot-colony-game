extends Node2D

# Small Rest indicators drawn above a character (a Colonist, or the MainCharacter): a "z" while he
# sleeps (outdoors or on a bed), a "!" when he is awake and below warn_below rest, and his rest bar only while the
# mouse is over him. Placeholders drawn in code (pixel_icons.gd). Drawn on top of the world at whole
# pixels.

const PixelIcons = preload("res://scripts/pixel_icons.gd")

@export var warn_below: float = 25.0
# The icons float this far above his feet.
@export var icon_height: float = 25.0
@export var bar_width: float = 14.0
@export var bar_height: float = 3.0
@export var fill_color: Color = Color(0.45, 0.6, 1.0)
@export var low_color: Color = Color(1.0, 0.3, 0.25)
@export var back_color: Color = Color(0.12, 0.13, 0.22)
@export var outline_color: Color = Color(0.05, 0.04, 0.07)

# The owner's HungerMeter, if any: an orange "!" shows while he is awake and hungrier than hunger_warn_below.
var hunger: Node = null
# Workers also show a hunger bar under the energy bar while the mouse is over them (hover only, like the energy one).
var hunger_bar: bool = false
@export var hunger_fill_color: Color = Color(0.95, 0.62, 0.2)
@export var hunger_low_color: Color = Color(0.9, 0.25, 0.2)

# Set by the owner: the RestMeter, and a callable that says whether he is asleep out in the open.
var rest: Node
# Whether the rest bar shows while the mouse is over him (colonists yes, the player has his HUD bar).
var hover_bar: bool = true
var asleep_outdoors: Callable = func() -> bool: return false
var awake: Callable = func() -> bool: return true

func _ready() -> void:
	z_index = 100
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	top_level = true
	# (The bars on hover are the shared overlay's, see character_bars.gd; this keeps the icons above the head.)
	if hover_bar:
		add_to_group("char_bars")

# The name or role shown as the heading of the hover bars ("Friend", "Lumberjack" ...).
var display_name: String = "Friend"
# The owner's health meter, if it ever has one (none does yet): its bar is then shown too.
var health: Node = null

func heading() -> String:
	return display_name

func is_hovered() -> bool:
	return _hovered()

# A line the owner adds under the heading on hover (a colonist: "Order: Assist me. Chopping a tree."), or "".
func note() -> String:
	var owner_node: Node = get_parent()
	return owner_node.hover_note() if owner_node.has_method("hover_note") else ""

# The bars the hover overlay shows, always in this order: Energy, Hunger, and Health only if there is a health meter.
func bars() -> Array:
	var out: Array = []
	if rest != null:
		out.append({"name": "Energy", "icon": PixelIcons.bolt(), "value": rest.value, "color": low_color if rest.value < warn_below else fill_color, "back": back_color})
	if hunger != null:
		out.append({"name": "Hunger", "icon": PixelIcons.berry(), "value": hunger.value, "color": hunger_low_color if hunger.value < _hunger_warn() else hunger_fill_color, "back": Color(0.2, 0.13, 0.1)})
	if health != null:
		out.append({"name": "Health", "icon": PixelIcons.bolt(), "value": health.value, "color": Color(0.4, 0.8, 0.4), "back": Color(0.1, 0.2, 0.1)})
	return out

func _process(_delta: float) -> void:
	var owner_node: Node2D = get_parent()
	global_position = owner_node.global_position.round()
	visible = owner_node.visible
	queue_redraw()

func _hunger_warn() -> float:
	var clock: Node = get_tree().get_first_node_in_group("game_clock")
	return clock.hunger_warn_below if clock != null else 25.0

func _hovered() -> bool:
	var m: Vector2 = get_global_mouse_position()
	return Rect2(global_position + Vector2(-8, -18), Vector2(16, 20)).has_point(m)

func _draw() -> void:
	if rest == null:
		return
	var icon: Texture2D = null
	if asleep_outdoors.call():
		icon = PixelIcons.zed()
	elif awake.call() and rest.value < warn_below:
		icon = PixelIcons.bang()
	elif awake.call() and hunger != null and hunger.value < _hunger_warn():
		icon = PixelIcons.bang_hungry()
	if icon != null:
		draw_texture(icon, Vector2(roundf(-icon.get_width() * 0.5), -icon_height - icon.get_height()))
