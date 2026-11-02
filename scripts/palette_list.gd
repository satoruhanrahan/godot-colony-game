class_name PaletteList
extends Resource

# A list of CharacterPalette looks. res://data/palettes/settler_palettes.tres holds the 8 curated hat + pants combinations the settlers get:
# open it in the editor, add an element to `palettes` and change its two colours to add a look.
#
#   PaletteList.unused_palette(tree)   a look nobody has: not the player's, not the friend's, not one a colonist alive already wears; random
#                                      among the free ones; with all of them taken, the hue of one is turned until it is new.

const SETTLERS_PATH: String = "res://data/palettes/settler_palettes.tres"
const FRIEND_PATH: String = "res://data/palettes/friend.tres"
const PLAYER_PATH: String = "res://data/palettes/player.tres"

@export var palettes: Array[CharacterPalette] = []

static func settlers() -> PaletteList:
	var list := load(SETTLERS_PATH) as PaletteList
	return list if list != null else PaletteList.new()

# The looks that are taken: the player's, the friend's, and those of every colonist except `exclude`.
static func taken(tree: SceneTree, exclude: Node = null) -> Array[CharacterPalette]:
	var out: Array[CharacterPalette] = []
	for path in [PLAYER_PATH, FRIEND_PATH]:
		var p := load(path) as CharacterPalette
		if p != null:
			out.append(p)
	for c in tree.get_nodes_in_group("colonists"):
		if c != exclude and "palette" in c and c.palette != null:
			out.append(c.palette)
	return out

static func _is_taken(candidate: CharacterPalette, used: Array[CharacterPalette]) -> bool:
	for u in used:
		if candidate.same_look(u):
			return true
	return false

static func unused_palette(tree: SceneTree, exclude: Node = null) -> CharacterPalette:
	var used: Array[CharacterPalette] = taken(tree, exclude)
	var free: Array[CharacterPalette] = []
	for p in settlers().palettes:
		if not _is_taken(p, used):
			free.append(p)
	if not free.is_empty():
		return free[randi() % free.size()]
	# all taken: a settler look with its hue turned until nobody wears it
	var pool: Array[CharacterPalette] = settlers().palettes
	var base: CharacterPalette = pool[randi() % pool.size()] if not pool.is_empty() else CharacterPalette.new()
	for step in 24:
		var turn: float = 0.618 * float(step + 1)
		var variant := CharacterPalette.new()
		variant.palette_name = "%s (variant %d)" % [base.palette_name, step + 1]
		variant.hat_color = _turned(base.hat_color, turn)
		variant.pants_color = _turned(base.pants_color, turn * 0.5)
		if not _is_taken(variant, used):
			return variant
	return base

static func _turned(c: Color, turn: float) -> Color:
	var hsl: Vector3 = CharacterPalette.rgb_to_hsl(c)
	return CharacterPalette.hsl_to_rgb(hsl.x + turn, hsl.y, hsl.z)
