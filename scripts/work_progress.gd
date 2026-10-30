extends Node

# Progress shown in the world instead of numbers: a small pixel-art bar above the thing the player
# is working on (felling or delimbing a tree, digging or hammering the pit saw, hammering a
# blueprint, and the pit saw's sawing time), and small material pips above a blueprint or the pit
# saw (a plank icon per plank still to bring, the saw blade, the hammer). One of these nodes sits
# in the main scene and holds the settings; a WorkOverlay (work_overlay.gd) is made for each
# target and draws on top of everything (z_index 100), on whole pixels.
#
# Only the MainCharacter's work is reported here. The automated workers (Lumberjack, Hauler,
# Builder, Sawmill) never call it.

const WorkOverlay = preload("res://scripts/work_overlay.gd")

# The work bars (chopping, delimbing, digging, hammering, sawing, pulling, breaking up, dismantling) are OFF:
# the player sees and hears the progress instead (see WorkFeedback and AudioManager). Switch this on to get
# the bars back exactly as before. The material pips and the energy bar are not affected.
@export var show_progress_bars: bool = false

# Reserved for later: show the automated workers' progress too. Does nothing yet.
@export var show_worker_progress: bool = false

@export_group("Bar")
# The bar's outer size in pixels (outline included); with a few hits it is a little wider so each
# segment is at least 2 px with a 1 px gap.
@export var bar_width: int = 20
@export var bar_height: int = 4
# Up to this many hits the bar has one segment per hit; above it, a smooth fill.
@export var segment_limit: int = 12
# Pixels between the top of the target's sprite (for a tree, the canopy) and the bar.
@export var anchor_gap: int = 4
# The pit saw is low and flat, and the player stands right beside it: its bar and pips are lifted
# this much more so they never cover his head.
@export var pit_lift: int = 6
# The bar stays this long (seconds) after the last hit, then goes.
@export var linger_time: float = 1.5
# The newest segment / the fill's leading edge is lighter for this long after a hit.
@export var flash_time: float = 0.1
# When the work is done the whole bar flashes for this long and goes.
@export var finish_flash_time: float = 0.2
@export var fill_color: Color = Color(0.95, 0.6, 0.18)
@export var flash_color: Color = Color(1.0, 0.93, 0.62)
@export var outline_color: Color = Color(0.09, 0.06, 0.05)
@export var background_color: Color = Color(0.22, 0.15, 0.11)
@export var empty_segment_color: Color = Color(0.32, 0.22, 0.16)

@export_group("Pips")
# Pips show when the mouse is over the blueprint; or when the player is within this many px of it
# and holds something it still needs; or while he works on it. (Minimal HUD: only the mouse.)
@export var show_radius: float = 64.0
# Pixels between the bar (or the sprite's top, with no bar) and the pips.
@export var pip_gap: int = 3
# A pip that fills is brighter for this long.
@export var pip_pop_time: float = 0.25
@export var pip_plank_color: Color = Color(0.82, 0.48, 0.2)
@export var pip_blade_color: Color = Color(0.78, 0.83, 0.9)
@export var pip_hammer_color: Color = Color(0.62, 0.66, 0.74)
@export var pip_outline_color: Color = Color(0.09, 0.06, 0.05)
@export var pip_dim_color: Color = Color(0.4, 0.4, 0.42, 0.55)
@export var pip_dim_outline_color: Color = Color(0.12, 0.12, 0.12, 0.55)
@export var pip_pop_color: Color = Color(1.0, 0.97, 0.8)

var _overlays: Dictionary = {}
var _icons: Dictionary = {}
var _tops: Dictionary = {}
var _scan_left: float = 0.0

func _ready() -> void:
	add_to_group("work_progress")
	# The tool icons: the existing sprites, cropped to their drawing, never scaled (the saw blade
	# lies on its side to fit beside the bar).
	_icons[&"axe"] = _icon("res://sprites/axe.png", false)
	_icons[&"shovel"] = _icon("res://sprites/shovel.png", false)
	_icons[&"hammer"] = _icon("res://sprites/hammer.png", false)
	_icons[&"saw"] = _icon("res://sprites/saw_blade.png", true)
	_icons[&"hay"] = _icon("res://sprites/hay_bundle.png", false)

func _icon(path: String, lay_down: bool) -> Texture2D:
	var image: Image = (load(path) as Texture2D).get_image()
	var crop: Image = image.get_region(image.get_used_rect())
	if lay_down:
		crop.rotate_90(CLOCKWISE)
	return ImageTexture.create_from_image(crop)

# The icon for the tool in use (&"axe", &"shovel", &"hammer" or &"saw").
func icon(tool: StringName) -> Texture2D:
	return _icons.get(tool)

# The first row of a texture that has a picture (so the bar sits at the top of what is seen).
func used_top(texture: Texture2D) -> int:
	if not _tops.has(texture):
		_tops[texture] = texture.get_image().get_used_rect().position.y
	return _tops[texture]

# The one overlay (bar and pips) of a target: asking again for a target that has one gives that
# same overlay, never a second. It is freed when its work completes or the target is gone, and
# then forgotten here.
func overlay_for(target: Node2D) -> Node2D:
	var id: int = target.get_instance_id()
	if _overlays.has(id) and is_instance_valid(_overlays[id]) and not _overlays[id].is_queued_for_deletion():
		return _overlays[id]
	var overlay: Node2D = WorkOverlay.new()
	overlay.setup(self, target)
	get_parent().add_child(overlay)
	_overlays[id] = overlay
	overlay.tree_exited.connect(func() -> void:
		if _overlays.get(id) == overlay:
			_overlays.erase(id))
	return overlay

# The highest world y the progress drawing above `target` reaches now (INF if none), so the
# interaction prompt can stand above it.
func content_top(target) -> float:
	var overlay = _overlays.get(target.get_instance_id())
	if overlay == null or not is_instance_valid(overlay):
		return INF
	return overlay.content_top

# One hit landed on `target` (done of total so far); `finished` when that hit completed the job.
func report_hit(target: Node2D, done: int, total: int, tool: StringName, finished: bool = false, partial: float = 0.0) -> void:
	if not show_progress_bars:
		return
	# Only the thing being worked on shows a bar: starting on another target puts the old bar away.
	for id in _overlays:
		var other = _overlays[id]
		if is_instance_valid(other) and other.target != target:
			other.hide_bar()
	overlay_for(target).hit(done, total, tool, finished, partial)

# A time bar (the pit saw sawing): fraction 0..1 of the time gone; end_time when it is over.
func report_time(target: Node2D, fraction: float, tool: StringName) -> void:
	if not show_progress_bars:
		return
	overlay_for(target).time(fraction, tool)

func end_time(target: Node2D, finished: bool = true) -> void:
	if not show_progress_bars:
		return
	overlay_for(target).end_time(finished)

func _process(delta: float) -> void:
	# Every blueprint and unfinished pit saw gets an overlay for its pips.
	_scan_left -= delta
	if _scan_left > 0.0:
		return
	_scan_left = 0.2
	for group in ["buildings", "pit_saws", "beds"]:
		for node in get_tree().get_nodes_in_group(group):
			overlay_for(node)
