extends Node

# THE COLONIST VIEW GUARD (debug builds only: Colony creates it when OS.is_debug_build()). Two jobs:
#
#  1. Once a second it checks every colonist: he is not hidden without a reason (Colonist.hidden_by names who hid him; the reason of each name is checked here:
#     he is in a room the player is not in, asleep in his house, at the pit saw, eating from a crate, or a job is taking him out of sight for a moment), his
#     picture is not transparent, and the animation he shows exists and has a frame. If not, it prints ONE warning (his state and job) and puts him back:
#     visible, opaque, the plain idle picture. `restored` counts how often it had to (the self-check).
#  2. F8 ("where is he?"): prints where every colonist is and what he is doing, and draws a bright arrow with a ring over each of them for 3 seconds (a node of
#     its own, so it shows even if he himself is hidden or his picture is blank). F9 is the sleep debug key, so this one is F8.

const MARKER_SECONDS: float = 3.0

var restored: int = 0
var last_message: String = ""
var _left: float = 1.0
var _said: Dictionary = {}

class Marker extends Node2D:
	var target: Node2D = null
	var left: float = 3.0

	func _ready() -> void:
		z_index = 4000
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	func _process(delta: float) -> void:
		left -= delta
		if target == null or not is_instance_valid(target) or left <= 0.0:
			queue_free()
			return
		global_position = target.global_position.round()
		queue_redraw()

	func _draw() -> void:
		var pulse: float = 0.5 + 0.5 * sin(left * 9.0)
		var bright := Color(1.0, 0.1 + 0.4 * pulse, 0.9)
		# a ring round his feet, an arrow above him
		draw_arc(Vector2(0, -6), 11.0, 0.0, TAU, 24, bright, 1.0)
		draw_rect(Rect2(-1, -40, 3, 12), bright, true)
		draw_colored_polygon(PackedVector2Array([Vector2(-5, -29), Vector2(6, -29), Vector2(0, -21)]), bright)
		draw_rect(Rect2(-6, -42, 13, 1), Color(0, 0, 0), true)

func _ready() -> void:
	name = "ColonistViewGuard"
	add_to_group("colonist_view_guard")

func _process(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		_left = 1.0
		check_now()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and event.keycode == KEY_F8:
		where_is_everyone()

# --- F8 ---------------------------------------------------------------------------------------------------------------------------

func where_is_everyone() -> void:
	var hud: Node = get_tree().get_first_node_in_group("hud")
	for col in get_tree().get_nodes_in_group("colonists"):
		var line: String = describe(col)
		print("WHERE: ", line)
		if hud != null:
			hud.say("%s is at (%d, %d): %s" % [col.display_name, col.global_position.x, col.global_position.y, col.status_text()])
		var marker := Marker.new()
		marker.target = col
		marker.left = MARKER_SECONDS
		col.get_parent().add_child(marker)
		marker.global_position = col.global_position.round()

func describe(col) -> String:
	var ai = col.order_ai
	return "%s at (%d, %d) visible=%s (in tree %s) hidden_by=%s alpha=%.2f/%.2f anim='%s' frame=%d in_room=%s state=%s job=%s held='%s'" % [col.display_name, col.global_position.x, col.global_position.y, str(col.visible), str(col.is_visible_in_tree()), str(col.hidden_by.keys()), col.modulate.a, col.self_modulate.a, col.animation, col.frame, str(col.in_room), str(col.State.keys()[col.state]), ai.work_job.describe() if ai.work_job != null else "none", ai.tools.held]

# --- The check --------------------------------------------------------------------------------------------------------------------

# Is the colonist out of sight for a reason that still holds?
func explained(col) -> bool:
	if col.dead or col.hidden_by.is_empty():
		return col.dead
	var ai = col.order_ai
	var S = col.State
	for source in col.hidden_by.keys():
		var ok: bool = false
		match source:
			&"room":
				ok = ai.inside_room != null or ai.visiting != null or col.work_claim != null or col.state in [S.TO_BED, S.ON_BED, S.INSIDE, S.ENTERING, S.EATING_CRATE, S.TO_CRATE, S.RETURNING, S.MOVING_IN]
			&"inside":
				ok = col.state in [S.INSIDE, S.ENTERING, S.ON_BED, S.TO_BED, S.MOVING_IN, S.RETURNING]
			&"pose":
				ok = col.work_claim != null or col.state in [S.AT_WORK, S.TO_WORK]
			&"crate":
				ok = col.state in [S.EATING_CRATE, S.TO_CRATE]
			&"job":
				ok = ai.work_job != null or ai.assist_cook != null
		if not ok:
			return false
	return true

# What is wrong with him now ("" = nothing).
func problem(col) -> String:
	if col.dead:
		return ""
	if not col.visible and not explained(col):
		return "hidden without a reason (hidden_by %s)" % str(col.hidden_by.keys())
	if col.modulate.a < 0.05 or col.self_modulate.a < 0.05:
		return "transparent (alpha %.2f / %.2f)" % [col.modulate.a, col.self_modulate.a]
	if not CharacterAnimator.has_picture(col.sprite_frames, col.animation):
		return "no picture: animation '%s' is missing or has no frames" % col.animation
	return ""

# Checks every colonist once; returns how many it had to put back.
func check_now() -> int:
	var fixed: int = 0
	for col in get_tree().get_nodes_in_group("colonists"):
		var why: String = problem(col)
		if why == "":
			continue
		fixed += 1
		restored += 1
		last_message = "%s: %s" % [col.display_name, why]
		var key: String = "%d/%s" % [col.get_instance_id(), why.split(" ")[0]]
		if not _said.has(key):
			_said[key] = true
			push_warning("COLONIST VIEW GUARD: " + describe(col) + " -- " + why + " (restored)")
			print("COLONIST VIEW GUARD: ", describe(col), " -- ", why, " (restored)")
		restore(col)
	return fixed

func restore(col) -> void:
	col.set_body_visible(&"*", true)
	col.modulate = Color(col.modulate.r, col.modulate.g, col.modulate.b, 1.0)
	col.self_modulate = Color(col.self_modulate.r, col.self_modulate.g, col.self_modulate.b, 1.0)
	if not CharacterAnimator.has_picture(col.sprite_frames, col.animation) and col.sprite_frames != null:
		col.play(&"idle")
