class_name PaletteSwap
extends RefCounted

# Puts a CharacterPalette on an AnimatedSprite2D: a ShaderMaterial of shaders/palette_swap.gdshader of its own (one per character, so
# nobody shares a colour), filled with the HAT and PANTS source colours of the player's art (PlayerPalette) and the target colours derived
# from the palette's two colours (CharacterPalette.derive). Nothing is written to disk and no image is made: it is a shader on the node, with
# the node's Scale (1,1), Nearest filter and pixel snapping untouched.
#
#   PaletteSwap.apply(sprite, palette)        creates the material, sets it, and keeps `split_row` right as the animation changes
#   PaletteSwap.make_material(palette)        the material alone (for a preview)
#   PaletteSwap.split_row(frames, animation)  the first sheet row of the pants in this animation (found from the art itself)
#
# THE ROW SPLIT: the art has the same colour for the hat and the pants, so the shader needs to know where the hat ends. For every animation the
# rows that carry a hat/pants source colour are looked at in all its frames (the Image of the sheet, once, cached): the top group of rows is the hat and the bottom group the
# pants (a frame with one group only goes to the nearer of the two); the split is half way between the lowest hat row and the highest pants row. A new animation of
# the player gets its split the first time it plays, with nothing to edit.

const SHADER: Shader = preload("res://shaders/palette_swap.gdshader")
const SLOTS: int = 8

static var _images: Dictionary = {}
static var _splits: Dictionary = {}

# The sprite gets its own material with this palette (`source` is the player's colour lists, the default file when null).
static func apply(sprite: AnimatedSprite2D, palette: CharacterPalette, source: PlayerPalette = null) -> ShaderMaterial:
	var mat: ShaderMaterial = make_material(palette, source)
	sprite.material = mat
	var update := func() -> void:
		mat.set_shader_parameter("split_row", split_row(sprite.sprite_frames, sprite.animation, source))
	sprite.animation_changed.connect(update)
	sprite.sprite_frames_changed.connect(update)
	update.call()
	return mat

static func make_material(palette: CharacterPalette, source: PlayerPalette = null) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.resource_local_to_scene = true
	set_palette(mat, palette, source)
	return mat

# Fills the colour uniforms: sources and targets of the hat group and of the pants group.
static func set_palette(mat: ShaderMaterial, palette: CharacterPalette, source: PlayerPalette = null) -> void:
	var src: PlayerPalette = source if source != null else PlayerPalette.get_default()
	var hat: Dictionary = _group(src.hat_sources(), src.hat_aliases(), palette.hat_color)
	var pants: Dictionary = _group(src.pants_sources(), src.pants_aliases(), palette.pants_color)
	mat.set_shader_parameter("hat_src", hat["src"])
	mat.set_shader_parameter("hat_dst", hat["dst"])
	mat.set_shader_parameter("hat_count", hat["count"])
	mat.set_shader_parameter("pants_src", pants["src"])
	mat.set_shader_parameter("pants_dst", pants["dst"])
	mat.set_shader_parameter("pants_count", pants["count"])

# {"src", "dst" (PackedColorArray of SLOTS), "count"}: the shades, then the aliases (which become the base colour itself).
static func _group(shades: PackedColorArray, aliases: PackedColorArray, base: Color) -> Dictionary:
	var src := PackedColorArray()
	var dst := PackedColorArray()
	var ramp: PackedColorArray = CharacterPalette.derive(shades, base)
	for i in shades.size():
		src.append(shades[i])
		dst.append(ramp[i])
	for a in aliases:
		src.append(a)
		dst.append(Color(base.r, base.g, base.b, 1.0))
	if src.size() > SLOTS:
		push_warning("PaletteSwap: more than %d source colours in a group, the rest is ignored" % SLOTS)
	var count: int = mini(src.size(), SLOTS)
	while src.size() < SLOTS:
		src.append(Color(0, 0, 0, 0))
		dst.append(Color(0, 0, 0, 0))
	src.resize(SLOTS)
	dst.resize(SLOTS)
	return {"src": src, "dst": dst, "count": count}

# --- The row split --------------------------------------------------------------------------------------------------------------------------

static func split_row(frames: SpriteFrames, anim: StringName, source: PlayerPalette = null) -> float:
	if frames == null or not frames.has_animation(anim):
		return 8.0
	var key: String = "%d:%s" % [frames.get_instance_id(), anim]
	if _splits.has(key):
		return _splits[key]
	var src: PlayerPalette = source if source != null else PlayerPalette.get_default()
	var colors: PackedColorArray = src.all_sources()
	var hat_bottoms: Array = []
	var pants_tops: Array = []
	var singles: Array = []
	var cell: float = 16.0
	for i in frames.get_frame_count(anim):
		var tex: Texture2D = frames.get_frame_texture(anim, i)
		if tex == null:
			continue
		var image: Image
		var region: Rect2i
		if tex is AtlasTexture:
			image = _image_of(tex.atlas)
			region = Rect2i(tex.region)
		else:
			image = _image_of(tex)
			region = Rect2i(Vector2i.ZERO, image.get_size())
		cell = region.size.y
		var clusters: Array = []
		for y in range(region.position.y, region.end.y):
			var has: bool = false
			for x in range(region.position.x, region.end.x):
				var px: Color = image.get_pixel(x, y)
				if px.a > 0.0 and _is_source(px, colors):
					has = true
					break
			if has:
				if not clusters.is_empty() and y - clusters[-1][1] <= 2:
					clusters[-1][1] = y
				else:
					clusters.append([y, y])
		if clusters.size() >= 2:
			# (the top group of rows is the hat, the bottom one the pants)
			hat_bottoms.append(clusters[0][1])
			pants_tops.append(clusters[-1][0])
		elif clusters.size() == 1:
			singles.append(clusters[0])
	# a frame with only one group (bent over, hands in front): it belongs to whichever known group is nearer
	for cl in singles:
		var centre: float = (cl[0] + cl[1]) * 0.5
		if not hat_bottoms.is_empty() and not pants_tops.is_empty():
			if absf(centre - float(hat_bottoms.max())) <= absf(centre - float(pants_tops.min())):
				hat_bottoms.append(cl[1])
			else:
				pants_tops.append(cl[0])
		elif centre < cell * 0.5:
			hat_bottoms.append(cl[1])
		else:
			pants_tops.append(cl[0])
	var split: float = cell * 0.5
	if not hat_bottoms.is_empty() and not pants_tops.is_empty():
		split = (float(hat_bottoms.max()) + float(pants_tops.min())) * 0.5 + 0.5
	elif not hat_bottoms.is_empty():
		split = float(hat_bottoms.max()) + 4.0
	elif not pants_tops.is_empty():
		split = float(pants_tops.min()) - 3.0
	_splits[key] = split
	return split

# For a check: in how many frames of this animation does the split fail to separate the hat rows (above it) from the pants rows (from it down)?
static func bad_split_frames(frames: SpriteFrames, anim: StringName, source: PlayerPalette = null) -> int:
	var src: PlayerPalette = source if source != null else PlayerPalette.get_default()
	var colors: PackedColorArray = src.all_sources()
	var split: float = split_row(frames, anim, source)
	var bad: int = 0
	for i in frames.get_frame_count(anim):
		var tex: Texture2D = frames.get_frame_texture(anim, i)
		var image: Image = _image_of(tex.atlas if tex is AtlasTexture else tex)
		var region: Rect2i = Rect2i(tex.region) if tex is AtlasTexture else Rect2i(Vector2i.ZERO, image.get_size())
		var clusters: Array = []
		for y in range(region.position.y, region.end.y):
			var has: bool = false
			for x in range(region.position.x, region.end.x):
				var px: Color = image.get_pixel(x, y)
				if px.a > 0.0 and _is_source(px, colors):
					has = true
					break
			if has:
				if not clusters.is_empty() and y - clusters[-1][1] <= 2:
					clusters[-1][1] = y
				else:
					clusters.append([y, y])
		if clusters.size() >= 2 and (clusters[0][1] >= split or clusters[-1][0] < split):
			bad += 1
	return bad

static func _is_source(px: Color, colors: PackedColorArray) -> bool:
	for c in colors:
		if absf(px.r - c.r) < 0.004 and absf(px.g - c.g) < 0.004 and absf(px.b - c.b) < 0.004:
			return true
	return false

static func _image_of(tex: Texture2D) -> Image:
	var id: int = tex.get_instance_id()
	if not _images.has(id):
		var image: Image = tex.get_image()
		if image.is_compressed():
			image.decompress()
		image.convert(Image.FORMAT_RGBA8)
		_images[id] = image
	return _images[id]
