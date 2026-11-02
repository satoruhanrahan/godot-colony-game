extends Node2D

# DESIGNATING TASKS on the main view (from the Orders panel's Work section). One of these lives in the world (group "designation_mode"); it
# also draws the MARKS of every colonist's tasks all the time: a small pixel icon above each marked tree (an axe), assigned blueprint
# (a hammer) and the pit saw that was assigned (a saw), a soft outline round the marked trees and blueprints, and the outline of a
# haul zone. The icons are the UI's (screen space, ui/designation_*.png, placeholders made by tools/make_designation_icons.py).
#
# While a designation is going on (start(colonist, type)) the panel is closed and a themed banner at the top says what to do (HINT: the same for every
# kind): drag a box to mark what is inside, click a marked thing to unmark it, right-click or Esc to finish. There is NOTHING to confirm: letting go of the
# mouse button marks everything in the box (a click, a drag smaller than CLICK_PX, the one thing under the cursor), the marks are permanent, and leaving
# the mode never takes any back. While a drag is going on the things it would mark are outlined; Esc or right-click during a drag cancels only that drag.
# One code path for every kind (chop, build, saw, haul, farm): _apply(). The mouse is taken while it runs; the player can still walk about to look.
#
# THE FARM ZONE is the odd one: it marks plot cells (the 11 x 11 grid of plot_manager.gd), not things, and it is not used up: the cells stay marked until they
# are unmarked (a click on a marked cell), and belong to the field (PlotManager.farm_cells), not to a colonist. They are drawn (a tint, a border round each zone,
# a small pixel sprout on its corner, a faint cross on cells that cannot be farmed) only while this mode is on and while the mouse is over a zone.

const Orders = preload("res://scripts/colonist_orders.gd")
const Logistics = preload("res://scripts/logistics.gd")

const ICON_PATHS: Dictionary = {&"chop": "res://ui/designation_axe.png", &"build": "res://ui/designation_hammer.png", &"saw": "res://ui/designation_saw.png"}
const HINT: String = "Drag to mark, click a marked item to unmark, right-click or Esc to finish."
const CLICK_PX: float = 5.0

var active: bool = false
var colonist = null
var type: StringName = &""

var _banner: PanelContainer
var _banner_label: Label
var _banner_title: Label
var _overlay: Control
var _zones: ZoneLayer
var _icons: Array = []
var _from: Vector2 = Vector2.INF
var _to: Vector2 = Vector2.INF
# What the drag in progress would mark (outlined live).
var _preview: Array = []
# The first thing marked closes the banner (the mode goes on, with the crosshair cursor); true from then until the mode ends.
var _picked: bool = false
var _outline: ShaderMaterial = null
var _outlined: Array = []
# The once-a-second sweep for marks of things that are gone or done (see sweep), and how many it has ever had to remove.
var _farm_preview: Array = []
var _farm_drawn: bool = false
var _sweep_left: float = 1.0
var _sweep_said: Dictionary = {}
var swept_total: int = 0

# Draws rectangles in screen space (the zones and the box being dragged).
class ZoneLayer extends Control:
	var rects: Array = []
	var drag: Rect2 = Rect2()
	var drag_erase: bool = false
	# The farm zones in screen space: [{"rect": Rect2, "edges": [top, right, bottom, left] (true = the zone ends there), "kind": 0 farmable / 1 skipped / 2 being marked}]
	# and the sprout on each zone's corner: [{"pos": Vector2, "px": int}].
	var farm: Array = []
	var farm_icons: Array = []
	const SPROUT: Array = [".G.G.", ".GGG.", "..B..", "..B..", ".BBB."]
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)
	func _draw() -> void:
		for fc in farm:
			var fr: Rect2 = fc["rect"]
			match int(fc["kind"]):
				0:
					draw_rect(fr, Color(0.55, 0.85, 0.35, 0.26), true)
				1:
					draw_rect(fr, Color(0.7, 0.7, 0.7, 0.12), true)
					draw_line(fr.position, fr.end, Color(0.95, 0.95, 0.95, 0.3), 1.0)
					draw_line(Vector2(fr.end.x, fr.position.y), Vector2(fr.position.x, fr.end.y), Color(0.95, 0.95, 0.95, 0.3), 1.0)
				2:
					draw_rect(fr, Color(0.8, 0.95, 0.5, 0.2), true)
			if int(fc["kind"]) != 2:
				var edge_color := Color(1.0, 0.95, 0.6, 0.9)
				var e: Array = fc["edges"]
				if e[0]:
					draw_line(fr.position, Vector2(fr.end.x, fr.position.y), edge_color, 1.0)
				if e[1]:
					draw_line(Vector2(fr.end.x, fr.position.y), fr.end, edge_color, 1.0)
				if e[2]:
					draw_line(Vector2(fr.position.x, fr.end.y), fr.end, edge_color, 1.0)
				if e[3]:
					draw_line(fr.position, Vector2(fr.position.x, fr.end.y), edge_color, 1.0)
		for ic in farm_icons:
			for row in SPROUT.size():
				for col in SPROUT[row].length():
					var ch: String = SPROUT[row][col]
					if ch != ".":
						draw_rect(Rect2(ic["pos"] + Vector2(col, row) * float(ic["px"]), Vector2(ic["px"], ic["px"])), Color(0.45, 0.85, 0.3) if ch == "G" else Color(0.6, 0.4, 0.2), true)
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
	Ui.register_closable(Callable(self, "is_active"), Callable(self, "cancel"), "designation mode", Ui.TIER_DESIGNATION)

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
		leave()
	colonist = who
	type = task_type
	active = true
	_picked = false
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)
	var player: Node = get_tree().get_first_node_in_group("player")
	if player != null:
		player.designating = true
	_from = Vector2.INF
	_preview = []
	_banner_title.visible = true
	_banner_title.text = Orders.TASK_NAMES[type]
	_banner_label.text = HINT
	_banner.visible = true
	Ui.sfx("ui_open")

func _end() -> void:
	active = false
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	_from = Vector2.INF
	_preview = []
	_zones.drag = Rect2()
	_zones.queue_redraw()
	_banner.visible = false
	var player: Node = get_tree().get_first_node_in_group("player")
	if player != null:
		player.designating = false

# Leaves the mode (right-click, Esc with nothing being dragged): every mark stays. A task with nothing in it is dropped.
func leave() -> void:
	if not active:
		return
	var task: Dictionary = colonist.orders.task_of(type)
	if not task.is_empty() and _task_empty(task):
		colonist.orders.tasks.erase(task)
	_end()
	Ui.sfx("ui_close")

# (The old name, kept for callers: finishing and leaving are the same thing now.)
func finish() -> void:
	leave()

# Esc / right-click: with a drag going on it cancels only that drag (nothing is marked, the mode goes on); otherwise it leaves the mode.
func cancel() -> void:
	if not active:
		return
	if _from != Vector2.INF:
		cancel_drag()
		return
	leave()

func cancel_drag() -> void:
	_from = Vector2.INF
	_preview = []
	_farm_preview = []
	_zones.drag = Rect2()
	_zones.queue_redraw()
	_say("Selection cancelled")

func is_dragging() -> bool:
	return _from != Vector2.INF

func _task_empty(task: Dictionary) -> bool:
	match task["type"]:
		&"chop":
			return task["trees"].is_empty()
		&"build":
			return task["blueprints"].is_empty()
		&"saw":
			return task["saw"] == null or not is_instance_valid(task["saw"])
		&"haul":
			return task["zone"].size == Vector2.ZERO
	return false

func _say(text: String) -> void:
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null and text != "":
		hud.say(text)

# --- Input ------------------------------------------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not active:
		return
	# (Keys are none of its business: Esc is the Ui's, in one place, and comes here as cancel() through Ui.register_closable.)
	if event is InputEventMouseButton and (event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT):
		get_viewport().set_input_as_handled()
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				cancel()
			return
		if event.pressed:
			drag_begin(get_global_mouse_position())
		else:
			drag_end(get_global_mouse_position())
	elif event is InputEventMouseMotion and _from != Vector2.INF:
		_to = get_global_mouse_position()

# The button goes down: a drag starts (public for the self-check, which cannot move the real cursor).
func drag_begin(at: Vector2) -> void:
	if not active:
		return
	_from = at
	_to = at

# The button comes up: everything in the box is marked at once, and the mode stays for the next selection. A drag that was cancelled has no start: nothing happens.
func drag_end(at: Vector2) -> void:
	if not active or _from == Vector2.INF:
		return
	_to = at
	var a: Vector2 = _from
	_from = Vector2.INF
	_preview = []
	_farm_preview = []
	_zones.drag = Rect2()
	_zones.queue_redraw()
	_apply(a, at, false)

# --- Marking ------------------------------------------------------------------------------------------------------------------------

# A click (a point) or a dragged rectangle: mark what is under it. Public for the self-check; `erase` removes instead (the self-check's way to unmark).
func apply_box(a: Vector2, b: Vector2, erase: bool) -> void:
	_apply(a, b, erase)

# The finished buildings with a room you can walk into (houses, storages).
func _room_hosts() -> Array:
	var out: Array = get_tree().get_nodes_in_group("storages").duplicate()
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.state == b.State.BUILT and b.building_type != null and b.building_type.interior_kind != "":
			out.append(b)
	return out

func _tree_click_rect(t: Node2D) -> Rect2:
	if t.is_standing():
		return Rect2(t.global_position.x - 12.0, t.global_position.y - 29.0, 24.0, 29.0)
	return load("res://scripts/footprints.gd").tree_rect(t)

# The things this kind of designation can take under a click / inside a box (shared by the live preview and by marking).
func _targets_at(a: Vector2, b: Vector2) -> Array:
	var box: Rect2 = Rect2(a, Vector2.ZERO).expand(b)
	var is_click: bool = a.distance_to(b) < CLICK_PX
	var hit: Array = []
	match type:
		&"chop":
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
		&"build":
			var all_bps: Array = Logistics.blueprints(get_tree())
			for bp in all_bps:
				var rect: Rect2 = load("res://scripts/footprints.gd").blocker_rect(bp)
				if (is_click and rect.has_point(a)) or (not is_click and box.intersects(rect)):
					hit.append(bp)
			# Outside, a click on a house or a storage (or a box over it) takes every blueprint planned in its room; inside, they are clicked in the room.
			var me: Node = get_tree().get_first_node_in_group("player")
			if me != null and me.inside_building == null:
				for host in _room_hosts():
					var host_rect: Rect2 = load("res://scripts/footprints.gd").blocker_rect(host)
					if (is_click and host_rect.has_point(a)) or (not is_click and box.intersects(host_rect)):
						for bp in all_bps:
							if Logistics.host_of(get_tree(), bp.global_position) == host and not hit.has(bp):
								hit.append(bp)
		&"saw":
			for pit in get_tree().get_nodes_in_group("pit_saws"):
				var prect: Rect2 = Rect2(pit.global_position.x - 16.0, pit.global_position.y - 14.0, 32.0, 18.0)
				if (is_click and prect.has_point(a)) or (not is_click and box.intersects(prect)):
					hit.append(pit)
	return hit

func _is_marked(task: Dictionary, node: Node) -> bool:
	match type:
		&"chop":
			return task["trees"].has(node)
		&"build":
			return task["blueprints"].has(node)
		&"saw":
			return task.get("saw") == node
	return false

# The plot cells (11 px) a box covers, at most 60 x 60 of them.
func _farm_cells_in(a: Vector2, b: Vector2) -> Array:
	var m: Node2D = _plot_manager()
	var c0: Vector2i = m.cell_of(a)
	var c1: Vector2i = m.cell_of(b)
	var out: Array = []
	for x in range(mini(c0.x, c1.x), mini(c0.x, c1.x) + mini(60, absi(c1.x - c0.x) + 1)):
		for y in range(mini(c0.y, c1.y), mini(c0.y, c1.y) + mini(60, absi(c1.y - c0.y) + 1)):
			var cell := Vector2i(x, y)
			if not m.farm_cells.has(cell) and m.map_rect.encloses(m.cell_rect(cell)):
				out.append(cell)
	return out

func _plot_manager() -> Node2D:
	return load("res://scripts/plot_manager.gd").get_for(get_tree())

# The farm zone's selection, the same rules as every kind: a plain click on a marked cell unmarks it, a click on a bare one marks it, a drag only ever adds.
func _apply_farm(a: Vector2, b: Vector2, erase: bool) -> Dictionary:
	var m: Node2D = _plot_manager()
	var is_click: bool = a.distance_to(b) < CLICK_PX
	if is_click:
		var cell: Vector2i = m.cell_of(a)
		if erase or m.farm_cells.has(cell):
			return {"count": 1 if m.unset_farm(cell) else 0, "removing": true}
		return {"count": 1 if m.set_farm(cell) else 0, "removing": false}
	var count: int = 0
	for cell in _farm_cells_in(a, b):
		if m.set_farm(cell):
			count += 1
	return {"count": count, "removing": false}

func _noun(count: int) -> String:
	match type:
		&"farm":
			return "cell" if count == 1 else "cells"
		&"chop":
			return "tree" if count == 1 else "trees"
		&"build":
			return "blueprint" if count == 1 else "blueprints"
		&"saw":
			return "pit saw" if count == 1 else "pit saws"
	return "things"

# THE ONE WAY a selection is made, for every kind: marks what is under the click / inside the box (a plain click on ONE thing that is already marked
# unmarks it; a drag only ever adds), says what happened, and returns how many things it touched (0 = nothing there).
func _apply(a: Vector2, b: Vector2, erase: bool) -> int:
	var is_click: bool = a.distance_to(b) < CLICK_PX
	var count: int = 0
	var removing: bool = erase
	if type == &"haul":
		count = _apply_zone(Rect2(a, Vector2.ZERO).expand(b), is_click, erase)
		_say(("Removed the hauling area" if erase else "Designated the hauling area") if count > 0 else ("Nothing to remove here" if erase else "Nothing to designate here"))
	elif type == &"farm":
		var res: Dictionary = _apply_farm(a, b, erase)
		count = res["count"]
		removing = res["removing"]
		if count > 0:
			_say("%s %d %s" % ["Unmarked" if removing else "Marked", count, _noun(count)])
		else:
			_say("Nothing to unmark here" if removing else "Nothing to mark here")
	else:
		var found: Array = _targets_at(a, b)
		var task: Dictionary = colonist.orders.task_of(type)
		if is_click and not erase and found.size() == 1 and not task.is_empty() and _is_marked(task, found[0]):
			removing = true
		if not removing:
			task = colonist.orders.ensure_task(type)
		if not task.is_empty():
			for node in found:
				if _apply_one(task, node, removing):
					count += 1
		if count > 0:
			_say("%s %d %s" % ["Removed" if removing else "Designated", count, _noun(count)])
		else:
			_say("Nothing to remove here" if removing else "Nothing to designate here")
	if count > 0 and not _picked:
		_picked = true
		# (after the first mark the title goes; the hint stays for the next one)
		_banner_title.visible = false
	return count

# Marks or unmarks one thing; true if that changed something.
func _apply_one(task: Dictionary, node: Node, removing: bool) -> bool:
	match type:
		&"chop":
			if removing:
				var had_tree: bool = task["trees"].has(node)
				task["trees"].erase(node)
				return had_tree
			if task["trees"].has(node) or (node.is_delimbed() and node.logs_ready == 0):
				return false
			# one colonist per tree: a tree marked for someone else moves to this one
			for other in get_tree().get_nodes_in_group("colonists"):
				if other != colonist:
					var ot: Dictionary = other.orders.task_of(&"chop")
					if not ot.is_empty():
						ot["trees"].erase(node)
			task["trees"].append(node)
			_watch(node)
			return true
		&"build":
			if removing:
				var had: bool = task["blueprints"].has(node)
				task["blueprints"].erase(node)
				return had
			if task["blueprints"].has(node):
				return false
			task["blueprints"].append(node)
			_watch(node)
			return true
		&"saw":
			if removing:
				var had_saw: bool = task.get("saw") == node
				if had_saw:
					task["saw"] = null
				return had_saw
			if task.get("saw") == node:
				return false
			task["saw"] = node
			_watch(node)
			return true
	return false

func _apply_zone(box: Rect2, is_click: bool, erase: bool) -> int:
	if erase:
		var task: Dictionary = colonist.orders.task_of(type)
		if task.is_empty() or task["zone"].size == Vector2.ZERO:
			return 0
		task["zone"] = Rect2()
		return 1
	if is_click:
		return 0
	var zone_task: Dictionary = colonist.orders.ensure_task(type)
	zone_task["zone"] = box
	return 1

# --- The marks -----------------------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_sweep_left -= delta
	if _sweep_left <= 0.0:
		_sweep_left = 1.0
		sweep()
	if active and _from != Vector2.INF:
		var vp: Viewport = get_viewport()
		_to = get_global_mouse_position()
		_zones.drag = Rect2(Ui.to_screen(vp, _from), Vector2.ZERO).expand(Ui.to_screen(vp, _to))
		_zones.drag_erase = false
		_zones.queue_redraw()
		# the live highlight: what letting go now would mark
		_preview = _targets_at(_from, _to) if type != &"haul" else []
		_farm_preview = _farm_cells_in(_from, _to) if type == &"farm" else []
	elif not _preview.is_empty():
		_preview = []
	if not (active and _from != Vector2.INF) and not _farm_preview.is_empty():
		_farm_preview = []
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
	if _overlay == null:
		return
	var vp: Viewport = get_viewport()
	var points: Array = []
	var outlined_now: Array = []
	var zone_rects: Array = []
	var player_now: Node = get_tree().get_first_node_in_group("player")
	for n in _preview:
		if is_instance_valid(n):
			outlined_now.append(n)
	for col in get_tree().get_nodes_in_group("colonists"):
		for task in col.orders.tasks:
			match task["type"]:
				&"chop":
					for t in task["trees"]:
						if not target_done(&"chop", t):
							points.append([&"chop", t.global_position + Vector2(0, -38 if t.is_standing() else -14)])
							outlined_now.append(t)
				&"build":
					for bp in task["blueprints"]:
						# (a blueprint in a room is marked only while I am in that room)
						if not target_done(&"build", bp) and (Logistics.room_of(get_tree(), bp.global_position) == null or (player_now != null and player_now.inside_building != null and Logistics.host_of(get_tree(), bp.global_position) == player_now.inside_building)):
							points.append([&"build", bp.global_position + Vector2(0, -(bp.get("texture").get_height() * 0.8) if bp.get("texture") != null else -30.0)])
							outlined_now.append(bp)
				&"saw":
					var pit = task.get("saw")
					if pit != null and not target_done(&"saw", pit):
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
	_update_farm(vp)
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

# --- The one owner of the marks ------------------------------------------------------------------------------------------------
# A mark is an entry in a colonist's task list (a tree, a blueprint, the pit saw) and the icon drawn over it (the icons are drawn from the lists every frame,
# so removing the entry removes the icon). clear_designation(target) is the ONE place a mark goes, and every end of a target's life calls it through clear_for:
# a blueprint finished (by the friend, by me, by both, as Assist: Building.finish_building, PitSaw._update_stage), cancelled (Building.cancel), a tree whose log
# is used up (Tree.finish_log), a job that dealt with its target for good (BuildJob._done, ChopJob._finish_tree). The target leaving the scene tree (tree_exiting,
# connected when it is marked) is the safety net, and so is sweep() once a second. A finished building is a different thing from its blueprint (or the same
# node in a new state) and never has a mark: finishing clears it first.

# Clears every mark of `target` (for every colonist, in the same call) and redraws at once.
static func clear_for(tree: SceneTree, target) -> void:
	var dm: Node = tree.get_first_node_in_group("designation_mode")
	if dm != null:
		dm.clear_designation(target)

# Should this target no longer carry a mark of this task type? Gone or on its way out, finished, or dealt with (the rule the friend's own pick uses).
static func target_done(task_type: StringName, node) -> bool:
	if node == null or not is_instance_valid(node) or node.is_queued_for_deletion():
		return true
	match task_type:
		&"chop":
			return node.is_delimbed() and node.logs_ready == 0 and node.log_claimed_by == null
		&"build":
			return node.is_finished()
	return false

func clear_designation(target) -> int:
	var removed: int = 0
	for col in get_tree().get_nodes_in_group("colonists"):
		for task in col.orders.tasks.duplicate():
			var had: bool = false
			match task["type"]:
				&"chop":
					had = _drop_from(task["trees"], target)
				&"build":
					had = _drop_from(task["blueprints"], target)
				&"saw":
					if task.get("saw") == target:
						task["saw"] = null
						had = true
			if had:
				removed += 1
				_task_emptied(col, task)
	if is_instance_valid(target) and _outlined.has(target):
		_set_outline(target, false)
		_outlined.erase(target)
	_update_marks()
	return removed

func _drop_from(list: Array, target) -> bool:
	var i: int = list.find(target)
	if i < 0:
		return false
	list.remove_at(i)
	return true

# A task with nothing left: while the colonist does his tasks his own pick finishes it ("Done building."); one who is not (Follow, Assist) never would, so it goes.
func _task_emptied(col, task: Dictionary) -> void:
	var empty: bool = false
	match task["type"]:
		&"chop":
			empty = task["trees"].is_empty()
		&"build":
			empty = task["blueprints"].is_empty()
		&"saw":
			empty = task.get("saw") == null
	if empty and not col.order_ai.work_allowed():
		col.orders.tasks.erase(task)

# The marked thing tells the manager when it leaves the scene or is finished.
func _watch(node) -> void:
	if node.has_meta(&"designation_watched"):
		return
	node.set_meta(&"designation_watched", true)
	node.tree_exiting.connect(_on_target_leaving.bind(node))
	if node.has_signal("built"):
		node.built.connect(_on_target_built)

func _on_target_leaving(node) -> void:
	clear_designation(node)

func _on_target_built(building) -> void:
	clear_designation(building)

# Once a second: any mark whose target is freed, on its way out, finished or dealt with is removed (what should already have been cleared by the call above).
# In a debug build it says so, once for each kind of thing: a path that ends a target's life without clear_designation. Returns how many it removed.
func sweep() -> int:
	var removed: int = 0
	for col in get_tree().get_nodes_in_group("colonists"):
		for task in col.orders.tasks.duplicate():
			var found: int = 0
			match task["type"]:
				&"chop":
					found = _prune(task["trees"], &"chop")
				&"build":
					found = _prune(task["blueprints"], &"build")
				&"saw":
					var pit = task.get("saw")
					if pit != null and target_done(&"saw", pit):
						task["saw"] = null
						found = 1
			if found > 0:
				removed += found
				_task_emptied(col, task)
				var key: String = String(task["type"])
				if OS.is_debug_build() and not _sweep_said.has(key):
					_sweep_said[key] = true
					push_warning("DESIGNATION SWEEP: %d mark(s) of a '%s' task referred to a freed, finished or dealt-with target (removed)" % [found, key])
					print("DESIGNATION SWEEP: %d mark(s) of a '%s' task referred to a freed, finished or dealt-with target (removed)" % [found, key])
	var live: Array = _outlined.filter(func(n) -> bool: return is_instance_valid(n))
	if live.size() != _outlined.size():
		_outlined = live
	if removed > 0:
		swept_total += removed
		_update_marks()
	return removed

func _prune(list: Array, task_type: StringName) -> int:
	var n: int = 0
	for i in range(list.size() - 1, -1, -1):
		if target_done(task_type, list[i]):
			list.remove_at(i)
			n += 1
	return n

# The farm zones are drawn only in the farm mode and while the mouse is over one.
func _update_farm(vp: Viewport) -> void:
	var m: Node2D = _plot_manager()
	var show: bool = m != null and (not m.farm_cells.is_empty() or not _farm_preview.is_empty()) and ((active and type == &"farm") or m.farm_cells.has(m.cell_of(get_global_mouse_position())))
	if not show:
		if _farm_drawn:
			_farm_drawn = false
			_zones.farm = []
			_zones.farm_icons = []
			_zones.queue_redraw()
		return
	_farm_drawn = true
	var px: int = maxi(1, Ui.art_scale() / 2)
	var cells: Array = []
	for cell in m.farm_cells.keys():
		var r: Rect2 = m.cell_rect(cell)
		cells.append({"rect": Rect2(Ui.to_screen(vp, r.position), Vector2.ZERO).expand(Ui.to_screen(vp, r.end)), "edges": [not m.farm_cells.has(cell + Vector2i(0, -1)), not m.farm_cells.has(cell + Vector2i(1, 0)), not m.farm_cells.has(cell + Vector2i(0, 1)), not m.farm_cells.has(cell + Vector2i(-1, 0))], "kind": 0 if m.can_farm(cell) == "" else 1})
	for cell in _farm_preview:
		var pr: Rect2 = m.cell_rect(cell)
		cells.append({"rect": Rect2(Ui.to_screen(vp, pr.position), Vector2.ZERO).expand(Ui.to_screen(vp, pr.end)), "edges": [false, false, false, false], "kind": 2})
	var icons: Array = []
	for zone in m.farm_zones():
		var corner: Rect2 = m.cell_rect(zone[0])
		icons.append({"pos": (Ui.to_screen(vp, corner.position) - Vector2(float(px) * 3.0, float(px) * 6.0)).round(), "px": px})
	_zones.farm = cells
	_zones.farm_icons = icons
	_zones.queue_redraw()

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
