class_name PlayerPalette
extends Resource

# The colours of the PLAYER'S ART that make up his hat and his pants: the source colours the palette swap replaces
# (res://data/player_palette.tres, written by tools/palette_report.py; correct it by editing the hex strings).
#
# The art has one flat colour for the hat and one for the pants and they are the SAME colour, so it is in both lists: the swap tells hat from
# pants by the pixel's row (PaletteSwap.split_row). More shades in a group are fine (up to 8 per group, including the aliases): the target
# ramp keeps their lightness / saturation offsets (CharacterPalette.derive).

const DEFAULT_PATH: String = "res://data/player_palette.tres"

@export var hat_hex: PackedStringArray = PackedStringArray(["#484a77"])
@export var pants_hex: PackedStringArray = PackedStringArray(["#484a77"])
# The same two roles in other art (the colonist's own colonist_walk.png / colonist_asleep.png): they become the base colour itself.
@export var hat_alias_hex: PackedStringArray = PackedStringArray()
@export var pants_alias_hex: PackedStringArray = PackedStringArray()
# Information only: colours found in two groups or a group and another region.
@export var ambiguous_hex: PackedStringArray = PackedStringArray()

static var _default: PlayerPalette = null

static func get_default() -> PlayerPalette:
	if _default == null:
		_default = load(DEFAULT_PATH) as PlayerPalette
		if _default == null:
			_default = PlayerPalette.new()
	return _default

static func colors_of(hex: PackedStringArray) -> PackedColorArray:
	var out := PackedColorArray()
	for h in hex:
		out.append(Color.html(h))
	return out

func hat_sources() -> PackedColorArray:
	return colors_of(hat_hex)

func pants_sources() -> PackedColorArray:
	return colors_of(pants_hex)

func hat_aliases() -> PackedColorArray:
	return colors_of(hat_alias_hex)

func pants_aliases() -> PackedColorArray:
	return colors_of(pants_alias_hex)

# Every colour that is hat or pants in some art (to find the rows they cover).
func all_sources() -> PackedColorArray:
	var out := PackedColorArray()
	for list in [hat_sources(), pants_sources(), hat_aliases(), pants_aliases()]:
		out.append_array(list)
	return out

func ambiguous_colors() -> PackedColorArray:
	var out := PackedColorArray()
	for c in hat_sources():
		for p in pants_sources():
			if c.is_equal_approx(p) and not out.has(c):
				out.append(c)
	return out
