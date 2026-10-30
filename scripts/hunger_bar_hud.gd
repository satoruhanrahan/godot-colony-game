extends Control

# The player's Hunger bar, next to the Energy bar in the bottom-left of the HUD (made by RestBar): a berry icon
# (its own node, HungerIcon) and a thin bar, in the same style. Faint while hunger is high (80 or more), normal
# below that, and red and pulsing gently when it is very low (below 25). One message (and a soft rumble) the first
# time it falls below hungry_threshold each day. It flashes briefly when he eats. No percentage text.

const HungerIcon = preload("res://scripts/hunger_icon.gd")

@export var bar_width: float = 40.0
@export var bar_height: float = 4.0
@export var faint_from: float = 80.0
@export_range(0.0, 1.0) var faint_opacity: float = 0.35
# Below this hunger the bar is red and pulses.
@export var low_below: float = 25.0
@export var pulse_period: float = 1.8
@export var fill_color: Color = Color(0.92, 0.6, 0.2)
@export var low_color: Color = Color(1.0, 0.3, 0.25)
@export var back_color: Color = Color(0.2, 0.13, 0.1)
@export var outline_color: Color = Color(0.05, 0.04, 0.07)
@export var flash_color: Color = Color(1.0, 0.95, 0.7)
@export var flash_time: float = 0.45
@export var hungry_message: String = "You're getting hungry. Pick berries - you need a basket."

# Set by the RestBar that makes it.
var player: Node

var _clock: float = 0.0
var _icon: TextureRect
var _flash_left: float = 0.0
var _last_hungry_day: int = -1
var _was_starving: bool = false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon = HungerIcon.new()
	_icon.name = "HungerIcon"
	add_child(_icon)

var _connected: bool = false

func _process(delta: float) -> void:
	# (The player makes his HungerMeter after this HUD is ready, so connect when it is there.)
	if not _connected and player != null and player.hunger != null:
		_connected = true
		player.hunger.eaten.connect(func(_amount: float) -> void: _flash_left = flash_time)
	_clock += delta
	_flash_left = maxf(0.0, _flash_left - delta)
	var hunger: float = player.hunger.value if player != null and player.hunger != null else 100.0
	var alpha: float = 1.0
	if hunger < low_below:
		alpha = 0.7 + 0.3 * (0.5 + 0.5 * sin(_clock * TAU / pulse_period))
	elif hunger >= faint_from:
		alpha = faint_opacity
	# Eating makes the bar solid for a moment, whatever it was showing.
	modulate.a = 1.0 if _flash_left > 0.0 else alpha
	var game_clock: Node = get_tree().get_first_node_in_group("game_clock")
	if game_clock != null and hunger < game_clock.hungry_threshold and game_clock.day != _last_hungry_day:
		_last_hungry_day = game_clock.day
		var hud: Node = get_tree().get_first_node_in_group("hud")
		if hud != null:
			hud.say(hungry_message)
		AudioManager.play("hunger_low", player.global_position, 1.0, -4.0)
	# The starving warning: once each time he falls below hunger_starving_below; fast forward drops back to 1x.
	if game_clock != null:
		var starving: bool = hunger < game_clock.hunger_starving_below
		if starving and not _was_starving:
			var hud_node: Node = get_tree().get_first_node_in_group("hud")
			if hud_node != null:
				hud_node.say("You are starving! Eat something.")
			var fast: Node = get_node_or_null("/root/FastForward")
			if fast != null:
				fast.warning("starving")
		_was_starving = starving
	queue_redraw()

func _draw() -> void:
	var hunger: float = player.hunger.value if player != null and player.hunger != null else 100.0
	var icon: Texture2D = _icon.texture
	var x: float = icon.get_width() + 2.0
	var y: float = roundf((icon.get_height() - bar_height - 2.0) * 0.5)
	var w: int = int(bar_width)
	var flashing: bool = _flash_left > 0.0
	draw_rect(Rect2(x, y, w + 2, bar_height + 2), flash_color if flashing else outline_color)
	draw_rect(Rect2(x + 1, y + 1, w, bar_height), back_color)
	var fill_w: int = int(floorf(clampf(hunger / 100.0, 0.0, 1.0) * w))
	if fill_w > 0:
		var color: Color = low_color if hunger < low_below else fill_color
		if flashing:
			color = color.lerp(flash_color, 0.6 * (_flash_left / flash_time))
		draw_rect(Rect2(x + 1, y + 1, fill_w, bar_height), color)
