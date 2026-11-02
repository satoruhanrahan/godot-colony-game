extends Node

# The UI of the whole game (an autoload: Ui). Everything you read lives here, in screen space at the REAL window
# resolution: the world is drawn small (480 x 270, whole-number scaled, by the Shell), the text is not.
#
#  - LAYERS (CanvasLayers of the root window, back to front):
#      art    (10)  pixel-art HUD parts (bars, icons, the held slot) in `art_root`, a Control scaled by an integer
#                   (ui_art_pixel_scale x the UI scale, rounded) with nearest filtering, so they are crisp pixel art;
#      text   (12)  every Label: HUD text and the text that belongs to world things (see world_text / adopt);
#      menu   (20)  panels (the build menu, the hover bars of characters);
#      fade   (85)  the sleep fade and the door fade;
#      over   (90)  the game-over screen;
#      pause  (95)  the pause button's dimmer, panel and the pause button.
#  - SCALE: with ui_scale_auto every size is multiplied by window height / 1080 (clamped 0.75 to 2.0).
#  - FONTS: a body font and a heading font from res://fonts/ (the engine default font if they are missing: see
#    fonts_report()), rendered crisply: grayscale antialiasing, light hinting, glyphs placed on whole pixels, cream text
#    with a dark outline.
#  - WORLD TEXT: text that belongs to something in the world is placed at that thing's SCREEN position every frame,
#    snapped to whole screen pixels and kept inside the screen: world_text(key, viewport, world_pos, text) (immediate
#    mode: call it every frame while it should show) or adopt(label) for an existing world Label.

signal ui_changed

const CONFIG_PATH: String = "res://ui/ui_config.tres"
const THEME_PATH: String = "res://ui/theme.tres"

var cfg: Resource
var theme: Theme
var font_body: Font
var font_bold: Font
var font_heading: Font
var fonts_loaded: Array[String] = []
var fonts_missing: Array[String] = []
# The Shell (the world inside a SubViewport), when the game runs through it.
var shell: Node = null

var art_layer: CanvasLayer
var art_root: Control
var text_layer: CanvasLayer
var text_root: Control
var menu_layer: CanvasLayer
var menu_root: Control
var fade_layer: CanvasLayer
var fade_root: Control
var over_layer: CanvasLayer
var over_root: Control
var pause_layer: CanvasLayer
var pause_root: Control

var _styled: Array = []         # [WeakRef(label), kind, color, outline]
var _world_labels: Dictionary = {}
var _touched: Dictionary = {}
var _adopted: Array = []        # [WeakRef(label), anchor, kind]
var _closables: Array[Dictionary] = []
# Room kept free at the top-right of the art area (art pixels) for the pause button.
var top_right_reserve: float = 0.0
# The game-over screen when it is up (pause is not available then), and the pause menu.
var game_over: Node = null
var pause_menu: Node = null
var character_bars: Node = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 1000   # after everything else each frame: labels follow what has just moved
	var path: String = CONFIG_PATH
	cfg = load(path) if ResourceLoader.exists(path) else load("res://scripts/ui_config.gd").new()
	_load_fonts()
	_make_layers()
	if ResourceLoader.exists(THEME_PATH):
		theme = load(THEME_PATH)
	else:
		theme = Theme.new()
	_apply_theme()
	get_tree().root.size_changed.connect(_on_resized)
	_on_resized()
	pause_menu = load("res://scripts/pause_menu.gd").new()
	pause_menu.name = "PauseMenu"
	add_child(pause_menu)
	var bars: Node = load("res://scripts/character_bars.gd").new()
	bars.name = "CharacterBars"
	add_child(bars)
	character_bars = bars

func is_paused() -> bool:
	return pause_menu != null and pause_menu.paused

func pause_menu_close() -> void:
	if pause_menu != null and pause_menu.paused:
		pause_menu.resume()

# R on the game-over screen (this node keeps running while the world is paused).
func _unhandled_input(event: InputEvent) -> void:
	if game_over != null and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		get_viewport().set_input_as_handled()
		game_over.restart()

# A button of the UI: a quiet sound when the mouse comes over it and when it is pressed.
func decorate_button(button: Button) -> void:
	button.mouse_entered.connect(func() -> void:
		if not button.disabled:
			sfx("ui_hover"))
	button.pressed.connect(func() -> void: sfx("ui_click"))

# --- Fonts ---------------------------------------------------------------------------------------------------------

# Is the pixel-art text in use (ui_pixel_text and its fonts are there)?
var pixel_active: bool = false

func _load_fonts() -> void:
	pixel_active = false
	if cfg.ui_pixel_text and ResourceLoader.exists(cfg.pixel_font_body_path) and ResourceLoader.exists(cfg.pixel_font_heading_path):
		font_body = _load_pixel_font(cfg.pixel_font_body_path)
		font_heading = _load_pixel_font(cfg.pixel_font_heading_path)
		font_bold = font_body
		pixel_active = true
		return
	if cfg.ui_pixel_text:
		fonts_missing.append(cfg.pixel_font_body_path)
		fonts_missing.append(cfg.pixel_font_heading_path)
	font_body = _load_font(cfg.font_body_path, false)
	font_bold = _load_font(cfg.font_body_bold_path, false)
	font_heading = _load_font(cfg.font_heading_path, true)
	if font_bold == null:
		font_bold = font_body
	if font_body == null:
		font_body = ThemeDB.fallback_font
	if font_heading == null:
		font_heading = font_body
	if font_bold == null:
		font_bold = font_body

# A pixel font: no antialiasing, no hinting, no subpixel positioning (crisp, pixel-aligned glyphs).
func _load_pixel_font(path: String) -> Font:
	var font: Font = load(path)
	if font is FontFile:
		font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		font.hinting = TextServer.HINTING_NONE
		font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		font.generate_mipmaps = false
		font.multichannel_signed_distance_field = false
	fonts_loaded.append(path)
	return font

func _load_font(path: String, heading: bool) -> Font:
	if not ResourceLoader.exists(path):
		fonts_missing.append(path)
		return null
	var font: Font = load(path)
	if font is FontFile:
		font.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		font.hinting = TextServer.HINTING_LIGHT
		font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		font.generate_mipmaps = false
	fonts_loaded.append(path)
	if heading and font is FontFile:
		var variation := FontVariation.new()
		variation.base_font = font
		variation.variation_opentype = {2003265652: cfg.heading_weight}   # (the "wght" axis)
		return variation
	return font

func fonts_report() -> String:
	var text: String = "loaded: %s (%s)" % [", ".join(fonts_loaded.map(func(p: String) -> String: return p.get_file())), "pixel text: antialiasing off, hinting off, subpixel off, x%d" % text_pixel_scale() if pixel_active else "smooth text"]
	if not fonts_missing.is_empty():
		text += "; MISSING (engine default font used): %s - download Alegreya Sans and Cinzel (OFL) into res://fonts/" % ", ".join(fonts_missing)
	return text

# --- Scale ---------------------------------------------------------------------------------------------------------

func screen_size() -> Vector2:
	return Vector2(get_tree().root.size)

# The UI scale for a window height (the one in use when none is given).
func scale_for_height(height: float) -> float:
	if not cfg.ui_scale_auto:
		return cfg.ui_scale_manual
	return clampf(height / cfg.ui_reference_height, cfg.ui_scale_min, cfg.ui_scale_max)

func ui_scale() -> float:
	return scale_for_height(screen_size().y)

# A size from the config (for a 1080 px window) in real pixels now.
func px(base: float) -> int:
	return maxi(1, int(round(base * ui_scale())))

# Screen pixels per font pixel for the pixel fonts: a whole number.
func text_pixel_scale() -> int:
	return maxi(1, int(round(cfg.ui_text_pixel_scale * ui_scale())))

# The size of the UI pixel grid (screen pixels): everything in the UI is placed on multiples of it.
func pixel() -> int:
	return art_scale() if pixel_active else 1

# A screen position moved onto the UI pixel grid.
func snap(v: Vector2) -> Vector2:
	var u: float = float(pixel())
	return ((v / u).round() * u)

func font_size(kind: String) -> int:
	if pixel_active:
		return (cfg.pixel_heading_native_px if kind == "heading" else cfg.pixel_body_native_px) * text_pixel_scale()
	match kind:
		"small":
			return px(cfg.ui_font_size_small)
		"heading":
			return px(cfg.ui_font_size_heading)
	return px(cfg.ui_font_size_body)

func outline_size() -> int:
	if cfg.ui_text_outline <= 0:
		return 0
	# pixel text: a hard outline one UI pixel wide
	if pixel_active:
		return art_scale()
	return maxi(1, int(round(cfg.ui_text_outline * ui_scale())))

# The whole-number scale of the pixel-art UI parts.
func art_scale() -> int:
	return maxi(1, int(round(cfg.ui_art_pixel_scale * ui_scale())))

# The size of the art area in its own (art) pixels.
func art_size() -> Vector2:
	return (screen_size() / float(art_scale())).floor()

func _on_resized() -> void:
	var s: int = art_scale()
	art_root.scale = Vector2(s, s)
	art_root.size = art_size()
	_apply_theme()
	for entry in _styled:
		var label: Label = entry[0].get_ref()
		if label != null:
			_style(label, entry[1], entry[2], entry[3])
	ui_changed.emit()

func _apply_theme() -> void:
	theme.default_font = font_body
	theme.default_font_size = font_size("body")
	theme.set_font_size("font_size", "Label", font_size("body"))
	theme.set_font_size("font_size", "Button", font_size("body"))
	theme.set_font_size("font_size", "HeadingLabel", font_size("heading"))
	theme.set_font_size("font_size", "InkHeadingLabel", font_size("heading"))
	theme.set_font("font", "HeadingLabel", font_heading)
	theme.set_font("font", "InkHeadingLabel", font_heading)
	for type_name in ["Label", "Button", "TabButton"]:
		theme.set_constant("outline_size", type_name, outline_size() if type_name != "TabButton" else 0)
	for variation in ["InkLabel", "InkHeadingLabel"]:
		theme.set_constant("outline_size", variation, 0)
	theme.set_font("font", "TabButton", font_body)
	theme.set_font_size("font_size", "TabButton", font_size("body"))
	theme.set_font_size("font_size", "BrassLabel", font_size("body"))
	theme.set_font_size("font_size", "DimLabel", font_size("body"))
	theme.set_font_size("font_size", "DangerLabel", font_size("body"))
	theme.set_font_size("font_size", "InkLabel", font_size("body"))
	for root in [menu_root, over_root, pause_root]:
		if root != null:
			root.theme = theme

# --- Layers --------------------------------------------------------------------------------------------------------

func _make_layer(layer_number: int, layer_name: String) -> Array:
	var layer := CanvasLayer.new()
	layer.layer = layer_number
	layer.name = layer_name
	add_child(layer)
	var root := Control.new()
	root.name = layer_name + "Root"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = theme
	root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if cfg.ui_pixel_text else CanvasItem.TEXTURE_FILTER_LINEAR
	layer.add_child(root)
	return [layer, root]

func _make_layers() -> void:
	var made: Array = _make_layer(10, "Art")
	art_layer = made[0]
	art_root = made[1]
	art_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	art_root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	made = _make_layer(12, "Text")
	text_layer = made[0]
	text_root = made[1]
	made = _make_layer(20, "Menu")
	menu_layer = made[0]
	menu_root = made[1]
	made = _make_layer(85, "Fade")
	fade_layer = made[0]
	fade_root = made[1]
	made = _make_layer(90, "Over")
	over_layer = made[0]
	over_root = made[1]
	made = _make_layer(95, "Pause")
	pause_layer = made[0]
	pause_root = made[1]

# --- Labels --------------------------------------------------------------------------------------------------------

# A Label in the UI's style (kind: "small", "body", "bold", "heading"), not yet in the tree. It is restyled when the
# window is resized. `color`: null = cream; `outline`: dark outline on (the default) or off (text on a parchment panel).
func make_label(kind: String = "body", color: Variant = null, outline: bool = true) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if pixel_active else CanvasItem.TEXTURE_FILTER_LINEAR
	_style(label, kind, color, outline)
	_styled.append([weakref(label), kind, color, outline])
	if _styled.size() > 400:
		_styled = _styled.filter(func(e: Array) -> bool: return e[0].get_ref() != null)
	return label

func _style(label: Label, kind: String, color: Variant, outline: bool) -> void:
	# (small text over the world is the bold cut: thin strokes get lost on grass)
	var font: Font = font_heading if kind == "heading" else (font_bold if (kind == "bold" or kind == "small") else font_body)
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", font_size(kind if kind != "bold" else "body"))
	label.add_theme_color_override("font_color", color if color != null else cfg.text_color)
	label.add_theme_color_override("font_outline_color", cfg.text_outline_color)
	label.add_theme_constant_override("outline_size", outline_size() if outline else 0)

# A label in the text layer, for the HUD to place in screen pixels.
func screen_label(kind: String = "body", color: Variant = null) -> Label:
	var label: Label = make_label(kind, color)
	text_root.add_child(label)
	return label

# --- World to screen -----------------------------------------------------------------------------------------------

# A point of a viewport's canvas (world coordinates through its camera) as a point of the window, in real pixels.
func to_screen(viewport: Viewport, world_pos: Vector2) -> Vector2:
	var p: Vector2 = viewport.get_canvas_transform() * world_pos
	if shell != null and viewport == shell.world_viewport:
		return shell.viewport_to_screen(p)
	return p

# A point of the world as a point of the art area (art pixels), for pixel-art parts that follow world things.
func to_art(viewport: Viewport, world_pos: Vector2) -> Vector2:
	return to_screen(viewport, world_pos) / float(art_scale())

# --- World text ----------------------------------------------------------------------------------------------------

# Text for a thing in the world: call it every frame while it should show. `anchor` is the part of the text that sits
# on the point (0.5, 1.0 = bottom centre, just above it). It is snapped to whole screen pixels and kept in the window.
func world_text(key: Variant, viewport: Viewport, world_pos: Vector2, text: String, kind: String = "small", color: Variant = null, anchor: Vector2 = Vector2(0.5, 1.0)) -> void:
	if text == "":
		return
	var label: Label = _world_labels.get(key)
	if label == null or not is_instance_valid(label):
		label = make_label(kind, color)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		text_root.add_child(label)
		_world_labels[key] = label
	if label.text != text:
		label.text = text
		label.reset_size()
	var size: Vector2 = label.get_combined_minimum_size()
	label.size = size
	var at: Vector2 = to_screen(viewport, world_pos)
	var pos: Vector2 = snap(at - size * anchor)
	var screen: Vector2 = screen_size()
	pos.x = clampf(pos.x, 2.0, maxf(2.0, screen.x - size.x - 2.0))
	pos.y = clampf(pos.y, 2.0, maxf(2.0, screen.y - size.y - 2.0))
	label.position = snap(pos)
	label.visible = true
	_touched[key] = Engine.get_process_frames()

# An existing Label that sits in the world (a crate's count, the grinding stone's state ...): it stops drawing itself and its text
# is shown in screen space at the same place instead, whenever it would be visible.
func adopt(label: Label, anchor: Vector2 = Vector2(0.5, 1.0), kind: String = "small") -> void:
	if label.has_meta(&"ui_adopted"):
		return
	label.set_meta(&"ui_adopted", true)
	label.self_modulate = Color(1, 1, 1, 0)
	_adopted.append([weakref(label), anchor, kind])

func _process(_delta: float) -> void:
	_track_closables()
	for i in range(_adopted.size() - 1, -1, -1):
		var entry: Array = _adopted[i]
		var label: Label = entry[0].get_ref()
		if label == null:
			_adopted.remove_at(i)
			continue
		if label.is_visible_in_tree() and label.text != "":
			var rect: Rect2 = label.get_global_rect()
			var point := Vector2(rect.position.x + rect.size.x * 0.5, rect.end.y)
			world_text(label, label.get_viewport(), point, label.text, entry[2], null, entry[1])
	var frame: int = Engine.get_process_frames()
	if _prompt_box != null and _prompt_box.visible and _prompt_touched < frame - 1:
		_prompt_box.visible = false
	for key in _world_labels.keys():
		var label: Label = _world_labels[key]
		if not is_instance_valid(label):
			_world_labels.erase(key)
			_touched.erase(key)
		elif label.visible and int(_touched.get(key, -10)) < frame - 1:
			label.visible = false

# --- The "E  verb" prompt of the thing under the mouse ---------------------------------------------------------------

var _prompt_box: HBoxContainer
var _prompt_key: Label
var _prompt_verb: Label
var _prompt_touched: int = -10

# Shows the prompt (a key cap and a verb) just above a world point; call it every frame while it should show.
func show_prompt(viewport: Viewport, world_pos: Vector2, key: String, verb: String) -> void:
	if _prompt_box == null:
		_prompt_box = HBoxContainer.new()
		_prompt_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_prompt_box.add_theme_constant_override("separation", px(5))
		var cap := PanelContainer.new()
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var box := StyleBoxFlat.new()
		box.bg_color = cfg.parchment
		box.border_color = cfg.ink
		box.set_border_width_all(max(1, px(1.5)))
		box.border_width_bottom = max(2, px(3))
		box.set_corner_radius_all(px(3))
		box.content_margin_left = px(6)
		box.content_margin_right = px(6)
		box.content_margin_top = px(1)
		box.content_margin_bottom = px(1)
		cap.add_theme_stylebox_override("panel", box)
		_prompt_key = make_label("bold", cfg.ink, false)
		cap.add_child(_prompt_key)
		_prompt_box.add_child(cap)
		_prompt_verb = make_label("small")
		_prompt_box.add_child(_prompt_verb)
		text_root.add_child(_prompt_box)
	_prompt_key.text = key
	_prompt_verb.text = verb
	_prompt_verb.visible = verb != ""
	_prompt_box.reset_size()
	var size: Vector2 = _prompt_box.get_combined_minimum_size()
	_prompt_box.size = size
	var at: Vector2 = to_screen(viewport, world_pos)
	var pos: Vector2 = snap(at - Vector2(size.x * 0.5, size.y))
	var screen: Vector2 = screen_size()
	pos.x = clampf(pos.x, 2.0, maxf(2.0, screen.x - size.x - 2.0))
	pos.y = clampf(pos.y, 2.0, maxf(2.0, screen.y - size.y - 2.0))
	_prompt_box.position = snap(pos)
	_prompt_box.visible = true
	_prompt_touched = Engine.get_process_frames()

# The width of a piece of text in the UI font, in real pixels.
func text_width(text: String, kind: String = "small") -> float:
	var font: Font = font_heading if kind == "heading" else (font_bold if kind == "bold" else font_body)
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size(kind)).x

# A point of an art-area Control (art pixels from its own top-left) as a point of the window.
func art_point(control: Control, offset: Vector2 = Vector2.ZERO) -> Vector2:
	return control.get_global_transform() * offset

# --- Panels that Esc closes ----------------------------------------------------------------------------------------

# ESC, IN ONE PLACE (this node, _input, so nothing else sees the key and a press can never do two things):
#   1. the pause menu, when it is up: Esc resumes (and nothing else happens);
#   2. otherwise the TOP-MOST open thing is closed, and only that: things register with a tier (lower = closes first) and, inside a tier, the one opened
#      last closes first. In order: designation mode (1), the action chooser (2), carrying the toolbox with the friend (3), build mode: the build menu and
#      its ghost (4), then the panels: toolbox, orders (5). Esc closes one of them and is consumed;
#   3. with nothing open the pause menu opens.
# The key release and the repeats of a held Esc are swallowed too, and a second Esc event in the same frame is ignored (the one-frame guard), so a
# press cannot leak into the pause menu on its release or on the next frame. Nothing else in the game handles Esc.
const TIER_DESIGNATION: int = 1
const TIER_CHOOSER: int = 2
const TIER_CARRY: int = 3
const TIER_BUILD: int = 4
const TIER_PANEL: int = 5

var _open_seq: int = 0
var _esc_frame: int = -1
# What the last Esc did ("closed designation mode", "closed the toolbox panel", "opened the pause menu", "resumed", "ignored").
var last_escape: String = ""

# A panel / mode registers how to ask "is it open?" and how to close it.
func register_closable(is_open: Callable, close: Callable, label: String = "panel", tier: int = TIER_PANEL) -> void:
	_closables.append({"open": is_open, "close": close, "label": label, "tier": tier, "since": 0, "was_open": false})

func _forget_dead_closables() -> void:
	_closables = _closables.filter(func(c: Dictionary) -> bool: return c["open"].is_valid() and c["close"].is_valid())

# Notes when each thing opens (so the one opened last closes first inside its tier).
func _track_closables() -> void:
	for c in _closables:
		if not c["open"].is_valid():
			continue
		var open: bool = c["open"].call()
		if open and not c["was_open"]:
			_open_seq += 1
			c["since"] = _open_seq
		c["was_open"] = open

# The open ones, the one Esc closes first at the front.
func open_closables() -> Array:
	_forget_dead_closables()
	_track_closables()
	var out: Array = _closables.filter(func(c: Dictionary) -> bool: return c["open"].call())
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["tier"] != b["tier"]:
			return a["tier"] < b["tier"]
		return a["since"] > b["since"])
	return out

# Closes the top-most open thing; true if there was one.
func close_top_panel() -> bool:
	var open: Array = open_closables()
	if open.is_empty():
		return false
	last_escape = "closed " + String(open[0]["label"])
	open[0]["close"].call()
	return true

func any_panel_open() -> bool:
	return not open_closables().is_empty()

# What Esc closes, in order (labels of everything registered, top tier first).
func escape_order() -> Array:
	_forget_dead_closables()
	var all: Array = _closables.duplicate()
	all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["tier"] < b["tier"])
	var out: Array = ["the pause menu (when it is up: Esc resumes)"]
	for c in all:
		var text: String = "%s (tier %d)" % [c["label"], c["tier"]]
		if not out.has(text):
			out.append(text)
	out.append("nothing open: Esc opens the pause menu")
	return out

# One Esc press: exactly one thing happens. Returns what it was.
func escape_pressed() -> String:
	if game_over != null:
		last_escape = "ignored (game over)"
		return last_escape
	if pause_menu != null and pause_menu.paused:
		pause_menu.resume()
		last_escape = "resumed"
		return last_escape
	if close_top_panel():
		return last_escape
	if pause_menu != null:
		pause_menu.toggle()
	last_escape = "opened the pause menu"
	return last_escape

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.keycode == KEY_ESCAPE):
		return
	# every part of the Esc key is ours: nothing below ever sees it
	get_viewport().set_input_as_handled()
	if not event.pressed or event.echo:
		return
	var frame: int = Engine.get_process_frames()
	if frame == _esc_frame:
		return
	_esc_frame = frame
	escape_pressed()

# --- UI sounds -----------------------------------------------------------------------------------------------------

func sfx(sound: String) -> void:
	AudioManager.play_ui(sound)
