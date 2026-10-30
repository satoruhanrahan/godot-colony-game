extends CanvasModulate

# Tints the world at night, easing through dusk and dawn. It is a CanvasModulate: it colours the game
# world only; the HUD lives on CanvasLayers and is never tinted. It multiplies colours and does not
# touch any texture filtering, so everything stays as crisp as by day.

# The colour the world is multiplied by at full night (a dark blue).
@export var night_color: Color = Color(0.33, 0.4, 0.72)
# The tint is never darker than this brightness (0..1), so the world stays readable at night.
@export_range(0.0, 1.0) var min_brightness: float = 0.55

# Inside a house the night tint is this share of the outside one (0 = none, 1 = the same).
@export_range(0.0, 1.0) var interior_tint_strength: float = 0.5

var _clock: Node

# The night colour with its brightness lifted to at least min_brightness (keeping its hue).
func night_tint() -> Color:
	var c: Color = night_color
	var lum: float = c.get_luminance()
	if lum < min_brightness and lum > 0.001:
		var k: float = min_brightness / lum
		c = Color(minf(1.0, c.r * k), minf(1.0, c.g * k), minf(1.0, c.b * k))
	return c

func _process(_delta: float) -> void:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
		if _clock == null:
			return
	var strength: float = 1.0
	var player: Node = get_tree().get_first_node_in_group("player")
	if player != null and player.get("inside_building") != null:
		strength = interior_tint_strength
	color = Color.WHITE.lerp(night_tint(), _clock.darkness() * strength)
