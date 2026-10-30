extends Node2D

# DESIGNATING TASKS on the main view (from the Orders panel's Work section). One of these lives in the world (group "designation_mode"); it
# also draws the MARKS of every colonist's tasks all the time: a small pixel icon above each marked tree (an axe), assigned blueprint
# (a hammer) and the pit saw that was assigned (a saw), a soft outline round the marked trees and blueprints, and the outline of a
# haul zone. The icons are the UI's (screen space, ui/designation_*.png, placeholders made by tools/make_designation_icons.py).
#
# While a designation is going on (start(colonist, type)) the panel is closed and a themed banner at the top says what to do:
#   chop:  left-click a tree to mark it, left-drag a rectangle to mark every tree inside, right-click / right-drag to unmark
#   build: left-click a blueprint to assign it (drag a rectangle for several), right-click / right-drag to unassign
#   saw:   left-click the pit saw to assign it, right-click to unassign
#   haul:  left-drag a rectangle: the zone (loose logs, planks and food in it go to Storage / crates), right-click / right-drag clears it
# Enter finishes (the marks stay); Esc cancels (the tasks go back to what they were). The mouse and these keys are taken while it runs;
# the player can still walk about to look.

const Orders = preload("res://scripts/colonist_orders.gd")
const Logistics = preload("res://scripts/logistics.gd")

const ICON_PATHS: Dictionary = {&"chop": "res://ui/designation_axe.png", &"build": "res://ui/designation_hammer.png", &"saw": "res://ui/designation_saw.png"}
const HINTS: Dictionary = {
	&"chop": "Chop these trees: click a tree to mark it, drag a box to mark many, right-click or right-drag to unmark.",
	&"build": "Build these: click a blueprint to assign it, drag a box for several, right-click to unassign.",
	&"saw": "Saw logs into planks: click the pit saw to assign it, right-click to unassign.",
	&"haul": "Haul to storage: drag a box over the loose logs, planks and food, right-click to clear it.",
}
const CLICK_PX: float = 5.0

var active: bool = false
var colonist = null
var type: StringName = &""

var _snapshot: Array = []
var _banner: PanelContainer
var _banner_label: Label
var _banner_title: Label
var _overlay: Control
var _zones: ZoneLayer
var _icons: Array = []
var _from: Vector2 = Vector2.INF
var _to: Vector2 = Vector2.INF
var _erase: bool = false
var _outline: ShaderMaterial = null
var _outlined: Array = []

# Draws rectangles in screen space (the zones and the box being dragged).
class ZoneLayer extends Control:
	var rects: Array = []
	var drag: Rect2 = Rect2()
	var drag_erase: bool = false
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)
	func _draw() -> void:
		for r in rects:
			draw_rect(r, Color(1.0, 0.93, 0.55, 0.12), true)
			draw_rect(r, Color(1.0, 0.93, 0.55, 0.7), false, 2.0)
		if drag.size != Vector2.ZERO:
			var color: Color = Color(1.0, 0.45, 0.35) if drag_erase else Color(0.55, 0.95, 0.6)
			draw_rect(drag, Color(color.r, color.g, color.b, 0.15), true)
			draw_rect(drag, color, false, 2.0)

func _ready() -> void:
	add_to_group("designation_mode")
	process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay = Control.new()
	_overlay.name = "Designations"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.menu_root.add_child(_overlay)
	_zones = ZoneLayer.new()
	_overlay.add_child(_zones)
	_banner = PanelContainer.new()
	_banner.theme_type_variation = &"Banner"
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.visible = false
	Ui.menu_root.add_child(_banner)
	var banner_box := VBoxContainer.new()
	banner_box.add_theme_constant_override("separation", Ui.px(2))
	_banner.add_child(banner_box)
	_banner_title = Label.new()
	_banner_title.theme_type_variation = &"HeadingLabel"
	_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_box.add_child(_banner_title)
	_banner_label = Label.new()
	_banner_label.add_theme_font_size_override("font_size", Ui.font_size("small"))
	_banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_banner_label.custom_minimum_size.x = float(Ui.px(380))
	_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_box.add_child(_banner_label)
	_outline = ShaderMaterial.new()
	_outline.shader = load("res://shaders/target_outline.gdshader")
	_outline.set_shader_parameter("outline_color", Color(1.0, 0.93, 0.55, 0.55))
	Ui.register_closable(Callable(self, "is_active"), Callable(self, "cancel"))

func _exit_tree() -> void:
	if is_instance_valid(_overlay):
		_overlay.queue_free()
	if is_instance_valid(_banner):
		_banner.queue_free()

func is_active() -> bool:
	return active

# --- Starting and ending -----------------------------------------------------------------------------------------------------

func start(who, task_type: StringName) -> void:
	if active:
		cancel()
	colonist = who
	type = task_type
	_snapshot = who.orders.tasks.duplicate(true)
	who.orders.ensure_task(type)
	active = true
	var player: Node = get_tree().get_first_node_in_group("player")
	if player != null:
		player.designating = true
	_from = Vector2.INF
	_banner_title.text = Orders.TASK_NAMES[type]
	_banner_label.text = "%s  Esc cancels, Enter finishes." % HINTS[type].substr(HINTS[type].find(":") + 2)
	_banner.visible = true
	Ui.sfx("ui_open")

func _end() -> void:
	active = false
	_from = Vector2.INF
	_zones.drag = Rect2()
	_zones.queue_redraw()
	_banner.visible = false
	var player: Node = get_tree().get_first_node_in_group("player")
	if player != null:
		player.designating = false

# Enter: the marks stay. An empty task is dropped.
func finish() -> void:
	if not active:
		return
	var task: Dictionary = colonist.orders.task_of(type)
	var summary: String = ""
	if not task.is_empty():
		match type:
			&"chop":
				summary = "%d trees marked." % task["trees"].size()
				if task["trees"].is_empty():
					colonist.orders.tasks.erase(task)
			&"build":
				summary = "%d blueprints to build." % task["blueprints"].size()
				if task["blueprints"].is_empty():
					colonist.orders.tasks.erase(task)
			&"saw":
				if task["saw"] == null or not is_instance_valid(task["saw"]):
					colonist.orders.tasks.erase(task)
				else:
					summary = "I will saw logs."
			&"haul":
				if task["zone"].size == Vector2.ZERO:
					colonist.orders.tasks.erase(task)
				else:
					summary = "I will haul what lies there."
	var who = colonist
	_end()
	Ui.sfx("ui_click")
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null and summary != "":
		hud.say("%s: %s" % [who.display_name, summary])

# Esc: the tasks go back to what they were.
func cancel() -> void:
	if not active:
		return
	colonist.orders.tasks = _snapshot
	_end()
	Ui.sfx("ui_close")

# --- Input ------------------------------------------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			cancel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			finish()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and (event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT):
		get_viewport().set_input_as_handled()
		if event.pressed:
			_from = get_global_mouse_position()
			_to = _from
			_erase = event.button_index == MOUSE_BUTTON_RIGHT
		elif _from != Vector2.INF:
			_to = get_global_mouse_position()
			_apply(_from, _to, _erase)
			_from = Vector2.INF
			_zones.drag = Rect2()
			_zones.queue_redraw()
	elif event is InputEventMouseMotion and _from != Vector2.INF:
		_to = get_global_mouse_position()

# --- Marking ------------------------------------------------------------------------------------------------------------------------

# A click (a point) or a dragged rectangle: mark or unmark what is under it. Public for the self-check.
func apply_box(a: Vector2, b: Vector2, erase: bool) -> void:
	_apply(a, b, erase)

func _tree_click_rect(t: Node2D) -> Rect2:
	if t.is_standing():
		return Rect2(t.global_position.x - 12.0, t.global_position.y - 29.0, 24.0, 29.0)
	return load("res://scripts/footprints.gd").tree_rect(t)

func _apply(a: Vector2, b: Vector2, erase: bool) -> void:
	var task: Dictionary = colonist.orders.ensure_task(type)
	var box: Rect2 = Rect2(a, Vector2.ZERO).expand(b)
	var is_click: bool = a.distance_to(b) < CLICK_PX
	match type:
		&"chop":
			var hit: Array = []
			if is_click:
				var best: Node2D = null
				for t in get_tree().get_nodes_in_group("trees"):
					if _tree_click_rect(t).has_point(a) and (best == null or t.position.y > best.position.y):
						best = t
				if best != null:
					hit.append(best)
			else:
				for t in get_tree().get_nodes_in_group("trees"):
					if box.has_point(t.position) or box.has_point(t.position + Vector2(0, -12)):
						hit.append(t)
			for t in hit:
				# one colonist per tree: a tree marked for someone else moves to this one
				for other in get_tree().get_nodes_in_group("colonists"):
					if other != colonist:
						var ot: Dictionary = other.orders.task_of(&"chop")
						if not ot.is_empty():
							ot["trees"].erase(t)
				if erase:
					task["trees"].erase(t)
				elif not task["trees"].has(t) and not (t.is_delimbed() and t.logs_ready == 0):
					task["trees"].append(t)
		&"build":
			var hits: Array = []
			for bp in Logistics.blueprints(get_tree()):
				var rect: Rect2 = load("res://scripts/footprints.gd").blocker_rect(bp)
				if (is_click and rect.has_point(a)) or (not is_click and box.intersects(rect)):
					hits.append(bp)
			for bp in hits:
				if erase:
					task["blueprints"].erase(bp)
				elif not task["blueprints"].has(bp):
					task["blueprints"].append(bp)
		&"saw":
			for pit in get_tree().get_nodes_in_group("pit_saws"):
				var prect: Rect2 = Rect2(pit.global_position.x - 16.0, pit.global_position.y - 14.0, 32.0, 18.0)
				if (is_click and prect.has_point(a)) or (not is_click and box.intersects(prect)):
					task["saw"] = null if erase else pit
		&"haul":
			if erase:
				task["zone"] = Rect2()
			elif not is_click:
				task["zone"] = box

# --- The marks -----------------------------------------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if active and _from != Vector2.INF:
		var vp: Viewport = get_viewport()
		_zones.drag = Rect2(Ui.to_screen(vp, _from), Vector2.ZERO).expand(Ui.to_screen(vp, _to))
		_zones.drag_erase = _erase
		_zones.queue_redraw()
	_banner_place()
	_update_marks()

func _banner_place() -> void:
	if not _banner.visible:
		return
	_banner.reset_size()
	var size: Vector2 = _banner.get_combined_minimum_size()
	_banner.size = size
	_banner.position = Vector2((Ui.screen_size().x - size.x) * 0.5, float(Ui.px(10))).round()

func _update_marks() -> void:
	var vp: Viewport = get_viewport()
	var points: Array = []
	var outlined_now: Array = []
	var zone_rects: Array = []
	for col in get_tree().get_nodes_in_group("colonists"):
		for task in col.orders.tasks:
			match task["type"]:
				&"chop":
					for t in task["trees"]:
						if is_instance_valid(t):
							points.append([&"chop", t.global_position + Vector2(0, -38 if t.is_standing() else -14)])
							outlined_now.append(t)
				&"build":
					for bp in task["blueprints"]:
						if is_instance_valid(bp):
							points.append([&"build", bp.global_position + Vector2(0, -bp.texture.get_height() * 0.8 if bp.texture != null else -30.0)])
							outlined_now.append(bp)
				&"saw":
					var pit = task.get("saw")
					if pit != null and is_instance_valid(pit):
						points.append([&"saw", pit.global_position + Vector2(0, -22)])
				&"haul":
					var zone: Rect2 = task["zone"]
					if zone.size != Vector2.ZERO:
						zone_rects.append(Rect2(Ui.to_screen(vp, zone.position), Vector2.ZERO).expand(Ui.to_screen(vp, zone.end)))
	# icons
	var scale: int = maxi(1, Ui.art_scale() / 2)
	while _icons.size() < points.size():
		var icon := TextureRect.new()
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.stretch_mode = TextureRect.STRETCH_KEEP
		_overlay.add_child(icon)
		_icons.append(icon)
	for i in _icons.size():
		var icon: TextureRect = _icons[i]
		if i < points.size():
			var tex: Texture2D = _icon(points[i][0])
			icon.texture = tex
			icon.visible = tex != null
			if tex != null:
				icon.scale = Vector2(scale, scale)
				icon.position = (Ui.to_screen(vp, points[i][1]) - tex.get_size() * float(scale) * 0.5).round()
		else:
			icon.visible = false
	if _zones.rects != zone_rects:
		_zones.rects = zone_rects
		_zones.queue_redraw()
	# the soft outline
	for n in _outlined:
		if is_instance_valid(n) and not outlined_now.has(n):
			_set_outline(n, false)
	for n in outlined_now:
		if not _outlined.has(n):
			_set_outline(n, true)
	_outlined = outlined_now

var _icon_cache: Dictionary = {}

func _icon(kind: StringName) -> Texture2D:
	if not _icon_cache.has(kind):
		_icon_cache[kind] = load(ICON_PATHS[kind]) if ResourceLoader.exists(ICON_PATHS[kind]) else null
	return _icon_cache[kind]

func _set_outline(node: Node, on: bool) -> void:
	var sprites: Array = []
	if node.is_in_group("trees"):
		for part in ["Canopy", "Trunk"]:
			var s: Node = node.get_node_or_null(part)
			if s is Sprite2D:
				sprites.append(s)
	elif node is Sprite2D:
		sprites.append(node)
	for s in sprites:
		if on:
			s.material = _outline
		elif s.material == _outline:
			s.material = null
