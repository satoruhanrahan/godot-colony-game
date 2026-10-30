extends Control

# The held-item slot in the bottom-left of the HUD: what the MainCharacter holds (a plank, the saw
# blade, a tool - hammer, shovel or axe - or a dragged log), as its icon and name. The
# "Q / right-click: drop" line shows only while he holds something and only for his first few drops
# (drop_hint_count); after that just the icon and the name. With empty hands the empty slot is shown
# faintly (empty_opacity) with no text. It keeps showing what he holds while he works. It is only a
# display: it takes no mouse input.

const ICON_PLANK: Texture2D = preload("res://sprites/one_plank.png")
const ICON_BLADE: Texture2D = preload("res://sprites/saw_blade.png")
const ICON_HAMMER: Texture2D = preload("res://sprites/hammer.png")
const ICON_LOG: Texture2D = preload("res://sprites/tree_trunk.png")
const ICON_SHOVEL: Texture2D = preload("res://sprites/shovel.png")
const ICON_AXE: Texture2D = preload("res://sprites/axe.png")
const ICON_HAY: Texture2D = preload("res://sprites/hay_bundle.png")
const ICON_GRASS: Texture2D = preload("res://sprites/grass_bundle.png")
const ICON_BASKET: Texture2D = preload("res://sprites/basket.png")
const ICON_BERRY: Texture2D = preload("res://sprites/berry.png")
const Items = preload("res://scripts/items.gd")

# The square the icon is drawn in; each icon is cropped to its drawing and enlarged by the
# biggest whole number that fits (so the pixels stay crisp).
@export var icon_box: float = 36.0
# The drop hint shows for this many drops of the session, then goes.
@export var drop_hint_count: int = 5
# How visible the empty slot is (1 = fully).
@export_range(0.0, 1.0) var empty_opacity: float = 0.3

@onready var player = get_node("../../..")

var _held: String = "?"
var _hint_on: bool = true
var _icon: TextureRect
var _name_label: Label
var _hint_label: Label
var _used_rects: Dictionary = {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0.6), Color(0.85, 0.85, 0.85, 0.8)))
	add_child(panel)
	var well := Panel.new()
	well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	well.position = Vector2(2, 1)
	well.size = Vector2(icon_box, icon_box)
	well.add_theme_stylebox_override("panel", _box(Color(0.12, 0.12, 0.12, 0.9), Color(0.45, 0.45, 0.45, 0.9)))
	add_child(well)
	_icon = TextureRect.new()
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon.stretch_mode = TextureRect.STRETCH_SCALE
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(_icon)
	# (The text is the UI's, crisp at the window's resolution: its labels are in the text layer and follow this slot.)
	_name_label = Ui.screen_label("small")
	_hint_label = Ui.screen_label("small", Color(0.78, 0.74, 0.64))
	_show("")

func _box(fill: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	return box

var _name_at: Vector2 = Vector2.ZERO
var _hint_at: Vector2 = Vector2.ZERO

func _notification(what: int) -> void:
	# (Not in _exit_tree: the slot is moved to the UI layer, which leaves the tree for a moment.)
	if what == NOTIFICATION_PREDELETE:
		for label in [_name_label, _hint_label]:
			if is_instance_valid(label):
				label.queue_free()

func _process(_delta: float) -> void:
	_name_label.position = Ui.snap(Ui.art_point(self, _name_at))
	_hint_label.position = Ui.snap(Ui.art_point(self, _hint_at))
	_name_label.modulate.a = modulate.a
	_hint_label.modulate.a = modulate.a
	var held: String = String(player.held_item())
	if held == "bundle":
		held = "hay" if player.bundle_is_hay() else "grass"
	if held == "basket":
		held = "basket:%d" % player.basket_berries
	if held == "seed_bag":
		held = "seed_bag:%d" % player.held_seeds
	if held == "bucket":
		held = "bucket:%d" % player.held_scoops
	var hint_on: bool = player.drops_made < drop_hint_count
	if held != _held or hint_on != _hint_on:
		_hint_on = hint_on
		_show(held)

func _show(held: String) -> void:
	_held = held
	if held.begins_with("basket"):
		var clock: Node = get_tree().get_first_node_in_group("game_clock")
		_show_item("Basket %d/%d" % [player.basket_berries, clock.basket_capacity if clock != null else 6], ICON_BASKET)
		return
	if held.begins_with("bucket"):
		_show_item(Items.hover_text(&"bucket", player.held_scoops), Items.texture(&"bucket"))
		return
	if held.begins_with("seed_bag"):
		_show_item("Seed bag %d/%d" % [player.held_seeds, load("res://scripts/food_config.gd").cfg().seed_bag_capacity], Items.texture(&"seed_bag"))
		return
	if Items.is_item(StringName(held)):
		_show_item(Items.name_of(StringName(held)), Items.texture(StringName(held)))
		return
	match held:
		"berry":
			_show_item("Berry", ICON_BERRY)
		"log":
			_show_item("Log", ICON_LOG)
		"plank":
			_show_item("Plank", ICON_PLANK)
		"blade":
			_show_item("Saw blade", ICON_BLADE)
		"hammer":
			_show_item("Hammer", ICON_HAMMER)
		"shovel":
			_show_item("Shovel", ICON_SHOVEL)
		"axe":
			_show_item("Axe", ICON_AXE)
		"hay":
			_show_item("Hay", ICON_HAY)
		"grass":
			_show_item("Grass", ICON_GRASS)
		_:
			_show_item("", null)

func _show_item(item_name: String, texture: Texture2D) -> void:
	_icon.visible = texture != null
	_name_label.visible = texture != null and is_visible_in_tree()
	var show_hint: bool = texture != null and _hint_on
	_hint_label.visible = show_hint
	# Empty: just the slot, faint. Holding: fully there.
	modulate.a = 1.0 if texture != null else empty_opacity
	if texture == null:
		size.x = icon_box + 4.0
		return
	_name_label.text = item_name
	_hint_label.text = "Q / right-click: drop"
	var text_x: float = icon_box + 7.0
	var art: float = float(Ui.art_scale())
	var name_h: float = _name_label.get_combined_minimum_size().y / art
	var hint_h: float = _hint_label.get_combined_minimum_size().y / art
	# (art pixels: the name on its own is centred; with the hint the two lines share the slot)
	_name_at = Vector2(text_x, (size.y - name_h) * 0.5 - (hint_h * 0.5 if show_hint else 0.0))
	_hint_at = Vector2(text_x, _name_at.y + name_h)
	var wide: float = maxf(_name_label.get_combined_minimum_size().x / art, (_hint_label.get_combined_minimum_size().x / art) if show_hint else 0.0)
	# Just as wide as what it shows.
	size.x = text_x + wide + 3.0
	var used: Rect2i = _used_rect(texture)
	var scale_by: int = maxi(1, int(floorf(minf(icon_box / used.size.x, icon_box / used.size.y))))
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = Rect2(used)
	_icon.texture = atlas
	_icon.size = Vector2(used.size * scale_by)
	_icon.position = (Vector2(2, 1) + (Vector2(icon_box, icon_box) - _icon.size) * 0.5).round()

# The part of the picture that is drawn (the rest is empty canvas).
func _used_rect(texture: Texture2D) -> Rect2i:
	if not _used_rects.has(texture):
		_used_rects[texture] = texture.get_image().get_used_rect()
	return _used_rects[texture]
