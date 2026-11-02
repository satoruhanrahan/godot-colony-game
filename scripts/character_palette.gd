class_name CharacterPalette
extends Resource

# How one character looks different from the next: just two colours, the HAT and the PANTS (everything else of the player's art stays as
# drawn). The full shade ramp is derived from them (see derive()), so the shading of the original art survives. Make a new look by copying a
# .tres of this type (res://data/palettes/) and changing the two colours; the Colonist applies it through PaletteSwap.

@export var palette_name: String = ""
@export var hat_color: Color = Color("#484a77")
@export var pants_color: Color = Color("#484a77")

# Is this (about) the same look as another palette? (Both colours within a few steps of 255.)
func same_look(other: CharacterPalette) -> bool:
	if other == null:
		return false
	return _close(hat_color, other.hat_color) and _close(pants_color, other.pants_color)

static func _close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) < 0.04

# --- The shade ramp ---------------------------------------------------------------------------------------------------------------------

# The target colour for every source shade of a group: the group's MID colour (the one of median lightness) becomes `base`, and every other
# shade keeps its offset in lightness and saturation from the mid (in HSL), applied to `base` (hue is base's). With one source shade the ramp is
# just `base`. Alpha is 1.
static func derive(sources: PackedColorArray, base: Color) -> PackedColorArray:
	var out := PackedColorArray()
	if sources.is_empty():
		return out
	var hsl_base: Vector3 = rgb_to_hsl(base)
	var order: Array = range(sources.size())
	order.sort_custom(func(i: int, j: int) -> bool: return rgb_to_hsl(sources[i]).z < rgb_to_hsl(sources[j]).z)
	var mid: Vector3 = rgb_to_hsl(sources[order[(sources.size() - 1) / 2]])
	for s in sources:
		var hsl: Vector3 = rgb_to_hsl(s)
		var l: float = clampf(hsl_base.z + (hsl.z - mid.z), 0.0, 1.0)
		var sat: float = clampf(hsl_base.y + (hsl.y - mid.y), 0.0, 1.0)
		out.append(hsl_to_rgb(hsl_base.x, sat, l) if not is_equal_approx(hsl.z, mid.z) or not is_equal_approx(hsl.y, mid.y) else Color(base.r, base.g, base.b, 1.0))
	return out

# (h 0..1, s 0..1, l 0..1)
static func rgb_to_hsl(c: Color) -> Vector3:
	var mx: float = maxf(c.r, maxf(c.g, c.b))
	var mn: float = minf(c.r, minf(c.g, c.b))
	var l: float = (mx + mn) * 0.5
	var d: float = mx - mn
	var h: float = 0.0
	var s: float = 0.0
	if d > 0.00001:
		s = d / maxf(0.00001, 1.0 - absf(2.0 * l - 1.0))
		if is_equal_approx(mx, c.r):
			h = fposmod((c.g - c.b) / d, 6.0)
		elif is_equal_approx(mx, c.g):
			h = (c.b - c.r) / d + 2.0
		else:
			h = (c.r - c.g) / d + 4.0
		h /= 6.0
	return Vector3(h, clampf(s, 0.0, 1.0), l)

static func hsl_to_rgb(h: float, s: float, l: float) -> Color:
	var c: float = (1.0 - absf(2.0 * l - 1.0)) * s
	var hp: float = fposmod(h, 1.0) * 6.0
	var x: float = c * (1.0 - absf(fposmod(hp, 2.0) - 1.0))
	var rgb := Vector3.ZERO
	if hp < 1.0:
		rgb = Vector3(c, x, 0.0)
	elif hp < 2.0:
		rgb = Vector3(x, c, 0.0)
	elif hp < 3.0:
		rgb = Vector3(0.0, c, x)
	elif hp < 4.0:
		rgb = Vector3(0.0, x, c)
	elif hp < 5.0:
		rgb = Vector3(x, 0.0, c)
	else:
		rgb = Vector3(c, 0.0, x)
	var m: float = l - c * 0.5
	return Color(rgb.x + m, rgb.y + m, rgb.z + m, 1.0)
