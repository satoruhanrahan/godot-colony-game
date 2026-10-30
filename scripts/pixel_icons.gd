extends RefCounted

# Small pixel placeholders for the clock and Rest indicators, made in code (there is no art for them
# yet). Each is drawn from a few rows of characters with a 1 px dark outline, as an ImageTexture to be
# drawn at whole pixels with Nearest filtering. Swap them for real art later by replacing the
# texture() results.

const OUTLINE: Color = Color(0.07, 0.05, 0.09)

const SUN: PackedStringArray = [
	"....Y....",
	".Y..Y..Y.",
	"..YYYYY..",
	"..YYYYY..",
	"YYYYYYYYY",
	"..YYYYY..",
	"..YYYYY..",
	".Y..Y..Y.",
	"....Y....",
]
const MOON: PackedStringArray = [
	"..BBBB...",
	".BBBB....",
	"BBBB.....",
	"BBBB.....",
	"BBBB.....",
	"BBBB.....",
	".BBBB....",
	"..BBBBBB.",
	"....BBB..",
]
const BOLT: PackedStringArray = [
	"...YY",
	"..YY.",
	".YY..",
	"YYYYY",
	"..YY.",
	".YY..",
	".Y...",
	"Y....",
	"Y....",
]
const BERRY: PackedStringArray = [
	"..GG.....",
	"...GG....",
	".RR.G.RR.",
	"RRRR.RRRR",
	"RRRRRRRRR",
	"RRRRRRRRR",
	".RRR.RRR.",
	"..R...R..",
]
const BANG_HUNGRY: PackedStringArray = [
	"OOO",
	"OOO",
	"OOO",
	"OOO",
	".O.",
	"...",
	"OOO",
]
const ZED: PackedStringArray = [
	"WWWWW",
	"...W.",
	"..W..",
	".W...",
	"WWWWW",
]
const BANG: PackedStringArray = [
	"RRR",
	"RRR",
	"RRR",
	"RRR",
	".R.",
	"...",
	"RRR",
]

const COLORS: Dictionary = {
	"G": Color(0.5, 0.95, 0.42),
	"Y": Color(1.0, 0.85, 0.25),
	"B": Color(0.75, 0.82, 1.0),
	"W": Color(0.92, 0.94, 1.0),
	"R": Color(1.0, 0.35, 0.25),
	"O": Color(1.0, 0.62, 0.18),
}

static var _cache: Dictionary = {}

static func sun() -> Texture2D:
	return _make("sun", SUN)

static func moon() -> Texture2D:
	return _make("moon", MOON)

static func bolt() -> Texture2D:
	return _make("bolt", BOLT)

static func berry() -> Texture2D:
	return _make("berry", BERRY)

# The "!" over a hungry colonist (orange, where the tired one is red).
static func bang_hungry() -> Texture2D:
	return _make("bang_hungry", BANG_HUNGRY)

static func zed() -> Texture2D:
	return _make("zed", ZED)

static func bang() -> Texture2D:
	return _make("bang", BANG)

static func _make(key: String, rows: PackedStringArray) -> Texture2D:
	if _cache.has(key):
		return _cache[key]
	var h: int = rows.size()
	var w: int = rows[0].length()
	var image := Image.create(w + 2, h + 2, false, Image.FORMAT_RGBA8)
	# The outline first (every neighbour of a drawn pixel), then the pixels on top.
	for y in h:
		for x in w:
			if rows[y][x] != "." and COLORS.has(rows[y][x]):
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						image.set_pixel(x + 1 + dx, y + 1 + dy, OUTLINE)
	for y in h:
		for x in w:
			var c: String = rows[y][x]
			if c != "." and COLORS.has(c):
				image.set_pixel(x + 1, y + 1, COLORS[c])
	var texture: Texture2D = ImageTexture.create_from_image(image)
	_cache[key] = texture
	return texture
