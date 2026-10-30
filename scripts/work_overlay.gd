extends Node2D

# The progress bar and the material pips of one target (a tree, a blueprint or the pit saw),
# drawn in the world above everything else (z_index 100, no smoothing) with rectangles on whole
# pixels. Made by WorkProgress, which also holds every setting. It stands at the world origin and
# draws in world coordinates, so it is not turned or moved with the thing it is about (a tree
# falling, a blueprint that is swapped for the real building).

const BlueprintText = preload("res://scripts/blueprint_text.gd")
const PIP_H: int = 6

var cfg: Node
var target: Node2D

var _clock: float = 0.0
# Where the top-centre of the target's sprite was last seen (the overlay carries on without the
# target for the closing flash).
var _anchor: Vector2 = Vector2.ZERO
var _base_y: float = 0.0

# The bar.
var _bar_on: bool = false
var _bar_total: int = 0
var _bar_value: int = 0
# The part of the next hit already earned (a tired player's press adds less than a whole hit).
var _bar_partial: float = 0.0
var _bar_fraction: float = 0.0
var _bar_timed: bool = false
var _bar_tool: StringName = &""
var _bar_last_hit: float = 0.0
var _bar_flash_until: float = 0.0
var _bar_finishing: bool = false
var _bar_finish_until: float = 0.0

# The pips: what was filled last time, and until when a newly filled one is bright.
# The highest row (world y) anything is drawn on, so the interaction prompt can stand above it.
var content_top: float = INF
# How many bars the last draw made: never more than one per target (the work bar).
var bars_drawn: int = 0

var _pip_last: Dictionary = {}
var _pops: Dictionary = {}

func setup(config: Node, new_target: Node2D) -> void:
	cfg = config
	target = new_target

func _ready() -> void:
	z_index = 100
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _alive() -> bool:
	return target != null and is_instance_valid(target) and not target.is_queued_for_deletion()

func _process(delta: float) -> void:
	_clock += delta
	var alive: bool = _alive()
	if alive:
		_measure()
		_watch_pips()
	if _bar_on:
		if _bar_finishing:
			if _clock >= _bar_finish_until:
				_bar_on = false
				_bar_finishing = false
		elif not _bar_timed:
			# A work bar stays only while he is working on this target (and a moment after the
			# last hit); the sawing time bar is the one exception.
			var player: Node = get_tree().get_first_node_in_group("player")
			var working: bool = player != null and alive and player.is_working_on(target)
			if _clock - _bar_last_hit > cfg.linger_time or not working:
				_bar_on = false
			elif _only_on_hover() and alive and not _mouse_over():
				# No lingering when the mouse is not over it: the bar is gone until the next press.
				_bar_on = false
	if not alive and not _bar_on:
		queue_free()
		return
	queue_redraw()

# --- Reports from the player's work ------------------------------------------------------------

func hit(done: int, total: int, tool: StringName, finished: bool, partial: float = 0.0) -> void:
	_bar_on = true
	_bar_timed = false
	_bar_total = maxi(1, total)
	_bar_value = clampi(done, 0, _bar_total)
	_bar_partial = clampf(partial, 0.0, 1.0)
	_bar_tool = tool
	_bar_last_hit = _clock
	_bar_flash_until = _clock + cfg.flash_time
	if finished:
		_bar_value = _bar_total
		_start_finish()
	else:
		_bar_finishing = false

# Puts the work bar away (another target is being worked on). A time bar and a closing flash stay.
func hide_bar() -> void:
	if not _bar_timed and not _bar_finishing:
		_bar_on = false

func time(fraction: float, tool: StringName) -> void:
	_bar_on = true
	_bar_timed = true
	_bar_fraction = clampf(fraction, 0.0, 1.0)
	_bar_tool = tool
	_bar_finishing = false

func end_time(finished: bool) -> void:
	if not _bar_timed:
		return
	_bar_timed = false
	if finished:
		# The closing flash of a time bar is a full smooth bar (it has no hit segments).
		_bar_fraction = 1.0
		_bar_total = cfg.segment_limit + 1
		_bar_value = _bar_total
		_bar_partial = 0.0
		_start_finish()
	else:
		_bar_on = false

func _start_finish() -> void:
	_bar_finishing = true
	_bar_finish_until = _clock + cfg.finish_flash_time

# --- Where it goes -------------------------------------------------------------------------------

# The first row of a sprite's picture, in the world.
func _sprite_top(sprite: Sprite2D) -> float:
	var texture: Texture2D = sprite.texture
	var half: float = texture.get_height() * 0.5 if sprite.centered else 0.0
	return sprite.global_position.y + sprite.offset.y - half + cfg.used_top(texture)

# The top-centre of the target's picture (for a tree, the canopy; a lying tree has no canopy left
# to stand above, so a fixed height over its base).
func _measure() -> void:
	var p: Vector2 = target.global_position
	_base_y = p.y
	if target.is_in_group("trees"):
		if target.is_standing():
			_anchor = Vector2(p.x, _sprite_top(target.canopy))
		else:
			_anchor = Vector2(p.x, p.y - 14.0)
	elif target.is_in_group("pit_saws"):
		var top: float = _sprite_top(target.static_sprite)
		if target.state == target.State.SAWING:
			# Both sawyers are drawn in the in-use picture, taller than the pit: above them.
			var frames: SpriteFrames = target.in_use.sprite_frames
			var texture: Texture2D = frames.get_frame_texture(target.in_use.animation, 0)
			top = minf(top, p.y + target.in_use.offset.y - texture.get_height() * 0.5 + cfg.used_top(texture))
		_anchor = Vector2(p.x, top - cfg.pit_lift)
	elif target.is_in_group("beds"):
		_anchor = Vector2(p.x, _sprite_top(target.sprite))
	elif target is Sprite2D:
		_anchor = Vector2(p.x + target.offset.x, _sprite_top(target))
	elif target is AnimatedSprite2D:
		var frame: Texture2D = target.sprite_frames.get_frame_texture(target.animation, 0)
		_anchor = Vector2(p.x + target.offset.x, p.y + target.offset.y - frame.get_height() * 0.5 + cfg.used_top(frame))
	else:
		_anchor = Vector2(p.x, p.y - 20.0)

# --- Pips: what exists, and when it is shown -----------------------------------------------------

# What the blueprint text would show now ({} for nothing): {"lines": [name, status]} (see blueprint_text.gd, the ONE text of
# every blueprint). There are no pips / filled blocks any more.
func _pip_state() -> Dictionary:
	if not _alive():
		return {}
	var lines: Array = BlueprintText.lines(target)
	if lines.is_empty():
		return {}
	return {"lines": lines}

# Is the mouse over this target (its picture)?
func _mouse_over() -> bool:
	return Rect2(_anchor.x - 16.0, _anchor.y - 2.0, 32.0, maxf(8.0, _base_y - _anchor.y + 4.0)).has_point(get_global_mouse_position())

# The HUD setting: bars and pips show only while the mouse is over the thing.
func _only_on_hover() -> bool:
	var hud: Node = get_tree().get_first_node_in_group("hud")
	return hud != null and hud.show_overlays_only_on_hover

# Pips show when the mouse is over the blueprint. (With show_overlays_only_on_hover off: also when
# the player is within show_radius and holds something it still needs, or is working on it; the
# Minimal HUD always means the mouse only.)
func _pips_visible() -> bool:
	var state: Dictionary = _pip_state()
	if state.is_empty():
		return false
	if _mouse_over():
		return true
	if _only_on_hover():
		return false
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null and hud.is_minimal():
		return false
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null:
		return false
	if player.is_working_on(target):
		return true
	return player.global_position.distance_to(Vector2(_anchor.x, _base_y)) <= cfg.show_radius and _needs(state, player.held_item())

# Does the blueprint still need what he is holding?
func _needs(state: Dictionary, held: StringName) -> bool:
	if target.is_in_group("pit_saws"):
		if held == &"plank":
			return target.planks_missing() > 0
		if held == &"blade":
			return target.blades_missing() > 0
		return held == &"hammer" and target.ready_to_build()
	if target.is_in_group("beds"):
		return held == &"bundle" and target.bedding_count() < target.bedding_max
	return target.needs_material(held) or (held == &"plank" and target.planks_needed() > 0)

func _watch_pips() -> void:
	pass

# --- Drawing ---------------------------------------------------------------------------------------

func _draw() -> void:
	if cfg == null or not (_bar_on or _alive()):
		return
	var cx: int = roundi(_anchor.x)
	var bottom: int = roundi(_anchor.y) - cfg.anchor_gap
	content_top = INF
	bars_drawn = 0
	if _bar_on and (not _only_on_hover() or _mouse_over()):
		var group_top: int = _draw_bar_group(cx, bottom)
		content_top = group_top
		bottom = group_top - cfg.pip_gap
	if _pips_visible():
		content_top = minf(content_top, _draw_pips(cx, bottom))

# Segment size for a bar: {pitch, inner} (inner = width inside the outline). With one segment per
# hit each is at least 2 px wide (1 px of colour and a 1 px gap).
func _metrics(total: int, segmented: bool) -> Dictionary:
	if not segmented:
		return {"pitch": 0, "inner": cfg.bar_width - 2}
	var pitch: int = maxi(2, (cfg.bar_width - 2 + 1) / total)
	return {"pitch": pitch, "inner": total * pitch - 1}

# The tool icon and the bar, centred on `cx`, sitting on `bottom`. Returns the top of the group.
func _draw_bar_group(cx: int, bottom: int) -> int:
	var segmented: bool = (not _bar_timed) and _bar_total <= cfg.segment_limit
	var m: Dictionary = _metrics(_bar_total, segmented)
	var width: int = m["inner"] + 2
	var icon: Texture2D = cfg.icon(_bar_tool)
	var icon_w: int = icon.get_width() + 2 if icon != null else 0
	var left: int = cx - (icon_w + width) / 2
	var top: int = bottom - cfg.bar_height
	var group_top: int = top
	if icon != null:
		var icon_y: int = top + cfg.bar_height / 2 - icon.get_height() / 2
		draw_texture(icon, Vector2(left, icon_y))
		group_top = mini(top, icon_y)
	var fraction: float = _bar_fraction if _bar_timed else (float(_bar_value) + _bar_partial) / float(_bar_total)
	_draw_bar(left + icon_w, top, _bar_total, _bar_value, fraction, segmented, m, _clock < _bar_flash_until, _bar_finishing)
	return group_top

# One bar with its top-left at (x, y). The only place a bar is drawn (by _draw_bar_group).
func _draw_bar(x: int, y: int, total: int, value: int, fraction: float, segmented: bool, m: Dictionary, flashing: bool, finishing: bool) -> void:
	bars_drawn += 1
	var h: int = cfg.bar_height
	var inner: int = m["inner"]
	draw_rect(Rect2(x, y, inner + 2, h), cfg.outline_color)
	draw_rect(Rect2(x + 1, y + 1, inner, h - 2), cfg.background_color)
	var fill: Color = cfg.flash_color if finishing else cfg.fill_color
	if segmented:
		var pitch: int = m["pitch"]
		for i in total:
			var color: Color = cfg.empty_segment_color
			if i < value:
				color = cfg.flash_color if (finishing or (flashing and i == value - 1)) else cfg.fill_color
			elif i == value and _bar_partial > 0.0 and not _bar_timed:
				# The hit being earned: the segment fills in as the presses add up.
				color = cfg.empty_segment_color.lerp(cfg.fill_color, _bar_partial)
			draw_rect(Rect2(x + 1 + i * pitch, y + 1, pitch - 1, h - 2), color)
	else:
		var fill_w: int = clampi(int(floorf(fraction * inner)), 0, inner)
		if finishing:
			fill_w = inner
		if fill_w > 0:
			draw_rect(Rect2(x + 1, y + 1, fill_w, h - 2), fill)
			if flashing and not finishing:
				var edge: int = mini(2, fill_w)
				draw_rect(Rect2(x + 1 + fill_w - edge, y + 1, edge, h - 2), cfg.flash_color)

# The blueprint text, sitting on `bottom` (two lines of the UI's pixel text); returns the top row it reaches (world px; the text is
# taller on screen than its few world pixels, so the prompt is kept clear of it).
func _draw_pips(cx: int, bottom: int) -> int:
	var state: Dictionary = _pip_state()
	if state.is_empty():
		return bottom
	var lines: Array = state["lines"]
	Ui.world_text(["overlay_blueprint", get_instance_id()], get_viewport(), Vector2(cx, bottom), "%s\n%s" % [lines[0], lines[1]], "small", Color(1.0, 0.93, 0.7))
	return bottom - 19
