extends Node

# A THROWAWAY preview (not part of the game): draws the player's animations as drawn and the same frames with the palette swap of the friend and of two
# settler looks, one row per animation, and saves res://tools/swap_preview.png (the frames at 1:1, the image enlarged 3x for looking at only).
# It also checks that the swapped hat and pants pixels have exactly the palettes' colours. Run this scene on its own (not headless: it needs the renderer):
#   Godot --path . res://debug/swap_preview.tscn

const ROWS: Array = ["idle", "walk", "carry_hay", "carry_wheat_sheaf", "carry_basket", "carry_flat_stone", "carry_flat_stone_idle", "hammer", "pull", "chop", "asleep"]
const CELL: int = 34
const LABEL_W: int = 112
const FRAMES_MAX: int = 6
const GAP: int = 14

func _ready() -> void:
	var palettes: Array = [null, load("res://data/palettes/friend.tres") as CharacterPalette]
	var settlers: Array = PaletteList.settlers().palettes
	if settlers.size() >= 2:
		palettes.append(settlers[0])
		palettes.append(settlers[3] if settlers.size() > 3 else settlers[1])
	var player_frames: SpriteFrames = load("res://sprites/main_character_frames.tres")
	var friend_frames: SpriteFrames = ColonistFrames.get_frames()
	var col_w: int = FRAMES_MAX * CELL + GAP
	var width: int = LABEL_W + palettes.size() * col_w + 10
	var height: int = 30 + ROWS.size() * CELL
	var vp := SubViewport.new()
	vp.size = Vector2i(width, height)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var bg := ColorRect.new()
	bg.color = Color(0.26, 0.27, 0.31)
	bg.size = Vector2(width, height)
	vp.add_child(bg)
	for p in palettes.size():
		var head := Label.new()
		var pal: CharacterPalette = palettes[p]
		head.text = "player (as drawn)" if pal == null else "%s: hat %s pants %s" % [pal.palette_name, pal.hat_color.to_html(false), pal.pants_color.to_html(false)]
		head.position = Vector2(LABEL_W + p * col_w, 2)
		head.add_theme_font_size_override("font_size", 9)
		vp.add_child(head)
	var walk_row_y: int = 30 + ROWS.find("walk") * CELL
	for r in ROWS.size():
		var anim: String = ROWS[r]
		var y: int = 30 + r * CELL
		var label := Label.new()
		label.text = anim
		label.position = Vector2(4, y + 10)
		label.add_theme_font_size_override("font_size", 10)
		vp.add_child(label)
		for p in palettes.size():
			var frames: SpriteFrames = player_frames if palettes[p] == null else friend_frames
			for i in mini(FRAMES_MAX, frames.get_frame_count(anim)):
				_sprite(vp, frames, anim, i, Vector2(LABEL_W + p * col_w + i * CELL, y), palettes[p])
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image: Image = vp.get_texture().get_image()
	# the check: of every palette, walk frame 0: hat pixel (5,1), pants pixel (6,12); and of the stone frame: the same pixels are the palette's colours too
	var stone_row_y: int = 30 + ROWS.find("carry_flat_stone") * CELL
	for p in palettes.size():
		var pal: CharacterPalette = palettes[p]
		var x0: int = LABEL_W + p * col_w
		var hat_px: Color = image.get_pixel(x0 + 5, walk_row_y + 1)
		var pants_px: Color = image.get_pixel(x0 + 6, walk_row_y + 12)
		var expected_hat: Color = Color("#484a77") if pal == null else pal.hat_color
		var expected_pants: Color = Color("#484a77") if pal == null else pal.pants_color
		print("SWAP_CHECK %s: walk hat %s (expected %s) pants %s (expected %s)" % ["player" if pal == null else pal.palette_name, hat_px.to_html(false), expected_hat.to_html(false), pants_px.to_html(false), expected_pants.to_html(false)])
		# every pixel of the stone row that is not the outline, skin, shirt or the stone itself must be one of the two palette colours: count the hat/pants-like ones
		var seen: Dictionary = {}
		for yy in CELL:
			for xx in FRAMES_MAX * CELL:
				var px: Color = image.get_pixel(x0 + xx, stone_row_y + yy)
				seen[px.to_html(false)] = int(seen.get(px.to_html(false), 0)) + 1
		print("SWAP_STONE %s: the colours in the stone rows (hex: pixels): %s" % ["player" if pal == null else pal.palette_name, str(seen)])
	var big := image.duplicate() as Image
	big.resize(width * 3, height * 3, Image.INTERPOLATE_NEAREST)
	var path: String = ProjectSettings.globalize_path("res://tools/swap_preview.png")
	big.save_png(path)
	print("SWAP_PREVIEW saved to %s" % path)
	get_tree().quit()

func _sprite(parent: Node, frames: SpriteFrames, anim: String, frame: int, at: Vector2, palette: CharacterPalette) -> AnimatedSprite2D:
	var s := AnimatedSprite2D.new()
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	s.centered = false
	s.sprite_frames = frames
	s.position = at
	parent.add_child(s)
	if palette != null:
		PaletteSwap.apply(s, palette)
	s.animation = anim
	s.frame = frame
	s.stop()
	return s
