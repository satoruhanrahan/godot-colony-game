extends Node2D

# THE TWO-PERSON CARRY: the player and the friend move the toolbox together ("Move Toolbox" in its panel). One of these exists
# while a move is going on; it owns the whole thing (the toolbox, the friend and the player only keep a reference to it).
#
#  GATHER: the friend walks to the box (cancelled after the toolbox's carry_helper_timeout_seconds); once he stands beside it and
#          the player is by it with free hands they lift it (toolbox_lift).
#  CARRY:  the player leads (walking at carry_together_speed_multiplier of his pace, times his own tiredness / hunger efficiency).
#          They stand at the two SHORT ENDS of the box (its long axis is horizontal), in every direction of travel: a fixed
#          formation relative to the box, not to the way they walk. Each is carry_end_offset_px() from the box centre (half the box
#          width + carry_end_gap_px) and level with it; the friend takes the end he arrived on at the lift and keeps it for the
#          whole carry. Walking left or right they are in line, one in front of the other; walking up or down side by side. The box
#          hangs between them, a little above the ground, sorted with the pair's midpoint. Both drain energy at
#          carry_together_drain_multiplier. The box keeps its contents; its panel cannot open; neither of them can enter a building
#          or do anything but put it down.
#  TETHER: if the friend falls more than carry_tether_px from his place the player slows to his pace (and stops at twice the
#          tether). Stuck that far for carry_stuck_seconds, a friend who is worn out or starving (below carry_min_condition), who is
#          called away, or Esc: the box is put down at the nearest free ground (find_free_ground_near), with a message.
#  PLACE:  a ghost of the box follows the cursor on the exact pixel, at most carry_place_reach_px from the player; green / red by
#          the same rules as a free-standing building (BuildMode.check_object). E or a click on a green ghost puts it down
#          (toolbox_set); Shift snaps to the 32 px grid. The old spot is simply free again (the box was lifted off it).
#  Nothing teleports: the box glides to the pair's midpoint after the lift and settles into its final place after the put-down.

const GroundPlacement = preload("res://scripts/ground_placement.gd")
const WaterMap = preload("res://scripts/water_map.gd")

enum Phase { GATHER, CARRY, DONE }

var box: Node2D
var player: Node2D
var friend: Node2D
var phase: Phase = Phase.GATHER
# Read from the toolbox when it starts.
var speed_multiplier: float = 0.7
var drain_multiplier: float = 1.5
var end_offset_px: float = 15.0
var end_vertical_px: float = 0.0
# Which end of the box the friend holds: -1 the left end, +1 the right one (decided at the lift).
var friend_side: float = 1.0
var tether_px: float = 48.0
var reach_px: float = 48.0
var lift_reach_px: float = 40.0
var stuck_seconds: float = 5.0
var min_condition: float = 15.0
var wait_seconds: float = 15.0
var lift_px: float = 5.0
# The last thing that ended it (for the self-check and the message).
var end_reason: String = ""
var ghost_origin: Vector2 = Vector2.ZERO
var ghost_result: Dictionary = {"ok": true, "amber": false, "text": ""}

var _wait_left: float = 15.0
var _stuck: float = 0.0
var _gap: float = 0.0
var _spot: Vector2 = Vector2.ZERO
var _ghost: Sprite2D
# Set by tests: where the "mouse" is (null = the real one).
var test_mouse: Variant = null

func setup(the_box: Node2D, the_player: Node2D, the_friend: Node2D) -> void:
	box = the_box
	player = the_player
	friend = the_friend
	speed_multiplier = box.carry_together_speed_multiplier
	drain_multiplier = box.carry_together_drain_multiplier
	end_offset_px = box.carry_end_offset_px()
	end_vertical_px = box.carry_end_vertical_px
	tether_px = box.carry_tether_px
	reach_px = box.carry_place_reach_px
	stuck_seconds = box.carry_stuck_seconds
	min_condition = box.carry_min_condition
	wait_seconds = box.carry_helper_timeout_seconds
	lift_px = box.carry_lift_px
	_wait_left = wait_seconds

func start() -> void:
	name = "CarryTogether"
	add_to_group("carry_together")
	Ui.register_closable(Callable(self, "is_active"), Callable(self, "escape"), "carrying the toolbox with the friend", Ui.TIER_CARRY)
	# He stands on the side of the box he comes from.
	var side: float = -1.0 if friend.global_position.x < box.global_position.x else 1.0
	_spot = (box.global_position + Vector2(side * 18.0, 1.0)).round()
	friend.begin_carry_help(self)
	_say("Your friend is coming to help.")

func is_active() -> bool:
	return phase != Phase.DONE

# The share of the friend's pace: how fast the player may go while the friend is behind (INF = no limit).
func player_speed_limit() -> float:
	if phase != Phase.CARRY or _gap <= tether_px:
		return INF
	return _friend_pace() * clampf(1.0 - (_gap - tether_px) / tether_px, 0.0, 1.0)

func _friend_pace() -> float:
	return friend.speed * friend.rest.speed_factor() * WaterMap.speed_factor(friend.position)

# The drain multiplier of the friend: only once the box is lifted (before that he is just walking).
func friend_drain() -> float:
	return drain_multiplier if phase == Phase.CARRY else 1.0

func gap() -> float:
	return _gap

# --- Every frame --------------------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if phase == Phase.DONE:
		return
	if not is_instance_valid(box):
		# the toolbox itself is gone: nothing to put down, just let them go
		phase = Phase.DONE
		_release()
		queue_free()
		return
	var broken: String = _broken()
	if broken != "":
		if phase == Phase.CARRY:
			put_down_near(broken)
		else:
			cancel(broken)
		return
	if phase == Phase.GATHER:
		_tick_gather(delta)
	else:
		_tick_carry(delta)

# Why it cannot go on ("" = it can).
func _broken() -> String:
	if not is_instance_valid(box) or not is_instance_valid(player) or not is_instance_valid(friend):
		return "The toolbox move was dropped."
	if player.dead:
		return "The toolbox was put down."
	if friend.dead:
		return "Your friend is gone. You put the toolbox down."
	if friend.state != friend.State.HELPING_CARRY or friend.carry_job != self:
		return "Your friend was called away. You put the toolbox down."
	if phase == Phase.CARRY and (player.state != player.State.FREE or player.transitioning or player.inside_building != null):
		return "You had to stop. The toolbox was put down."
	if friend.rest.value < min_condition:
		return "Your friend is too tired to go on. You put the toolbox down."
	if friend.hunger.value < min_condition:
		return "Your friend is too hungry to go on. You put the toolbox down."
	return ""

func _tick_gather(delta: float) -> void:
	_wait_left -= delta
	friend.carry_walk_to(_spot, delta)
	var arrived: bool = friend.position.distance_to(_spot) < 1.5
	if arrived:
		friend.flip_h = box.global_position.x < friend.position.x
	var close: bool = player.position.distance_to(box.global_position) <= lift_reach_px
	if arrived and close and player.is_free() and not player.hands_occupied():
		_lift()
	elif _wait_left <= 0.0:
		cancel("Your friend could not get to the toolbox." if not arrived else "You walked away from the toolbox.")

func _lift() -> void:
	phase = Phase.CARRY
	_stuck = 0.0
	_gap = 0.0
	friend_side = -1.0 if friend.position.x < box.global_position.x else 1.0
	box.begin_carried(self)
	player.carrying_together = self
	AudioManager.play("toolbox_lift", box.global_position)
	_make_ghost()
	_say("You lift the toolbox together. E or click puts it down.")

func _tick_carry(delta: float) -> void:
	# the friend's place: the other end of the box, 2 x end_offset_px from the player along the box (the formation never turns)
	var target: Vector2 = (player.position + Vector2(friend_side * 2.0 * end_offset_px, 0.0)).round()
	friend.carry_walk_to(target, delta)
	# (they both face the way the player walks)
	friend.flip_h = player.sprite.flip_h
	_gap = friend.position.distance_to(target)
	_stuck = _stuck + delta if _gap > tether_px else 0.0
	if _stuck >= stuck_seconds:
		put_down_near("Your friend is stuck. You put the toolbox down.")
		return
	# the box hangs between them
	var mid: Vector2 = (player.position + friend.position) * 0.5 - Vector2(0.0, end_vertical_px)
	box.global_position = box.global_position.move_toward(mid, 140.0 * delta)
	box.sprite.position.y = move_toward(box.sprite.position.y, -lift_px, 24.0 * delta)
	_update_ghost()

# --- The ghost ----------------------------------------------------------------------------------------------------------

func _make_ghost() -> void:
	_ghost = Sprite2D.new()
	_ghost.texture = box.closed_texture if box.closed_texture != null else box.sprite.texture
	_ghost.offset = box.sprite.offset
	_ghost.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_ghost.z_index = 60
	add_child(_ghost)

func _build_mode() -> Node:
	return get_tree().get_first_node_in_group("build_mode")

func _mouse() -> Vector2:
	return test_mouse if test_mouse != null else get_global_mouse_position()

# The spot the ghost would go: the exact pixel under the cursor (the box's feet a little below it), on the 32 px grid with Shift,
# no further than the reach from the player.
func origin_for(mouse: Vector2, snap: bool) -> Vector2:
	var origin: Vector2 = Vector2(roundf(mouse.x), roundf(mouse.y + 6.0))
	if snap:
		origin = Vector2((floorf(mouse.x / 32.0) + 0.5) * 32.0, (floorf(mouse.y / 32.0) + 1.0) * 32.0)
	var d: Vector2 = origin - player.position
	if d.length() > reach_px:
		origin = (player.position + d.normalized() * reach_px).round()
	return origin

func check_at(origin: Vector2, throttled: bool) -> Dictionary:
	var bm: Node = _build_mode()
	if bm == null:
		return {"ok": true, "amber": false, "text": ""}
	return bm.check_object(box.footprint_at(origin), box.base_at(origin), box, throttled)

func _update_ghost() -> void:
	if _ghost == null:
		return
	ghost_origin = origin_for(_mouse(), Input.is_key_pressed(KEY_SHIFT))
	ghost_result = check_at(ghost_origin, true)
	_ghost.global_position = ghost_origin
	var bm: Node = _build_mode()
	if bm != null:
		_ghost.modulate = bm.amber_tint if ghost_result["ok"] and ghost_result["amber"] else (bm.valid_tint if ghost_result["ok"] else bm.invalid_tint)
	if not ghost_result["ok"]:
		Ui.world_text("carry_reason", get_viewport(), ghost_origin + Vector2(0, -28), ghost_result["text"], "small", Color(1.0, 0.55, 0.45))
	Ui.world_text("carry_hint", get_viewport(), player.position + Vector2(0, 24), "E / click: put it down   Shift: snap   Esc: put down here", "small", Color(1.0, 0.93, 0.7))

# --- Putting it down ----------------------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if phase != Phase.CARRY:
		return
	var pressed_e: bool = event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E
	var clicked: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	if not pressed_e and not clicked:
		return
	get_viewport().set_input_as_handled()
	place()

# E / click: down at the ghost when it is green; red says why.
func place() -> bool:
	if phase != Phase.CARRY:
		return false
	ghost_origin = origin_for(_mouse(), Input.is_key_pressed(KEY_SHIFT))
	ghost_result = check_at(ghost_origin, false)
	if not ghost_result["ok"]:
		_say(ghost_result["text"])
		return false
	_finish(ghost_origin, "You put the toolbox down.", ghost_result["amber"])
	return true

# Esc: cancel the gathering, or put it down where it is.
func escape() -> void:
	if phase == Phase.GATHER:
		cancel("Cancelled.")
	elif phase == Phase.CARRY:
		put_down_near("You put the toolbox down.")

# Down at the nearest free ground to where it hangs now (the abort cases).
func put_down_near(message: String) -> void:
	if phase != Phase.CARRY:
		cancel(message)
		return
	var free: Vector2 = GroundPlacement.find_free_ground_near(get_tree(), box.global_position, Vector2(26, 12), Rect2(0, 0, 640, 640), 96.0, box)
	_finish(box.global_position.round() if free == Vector2.INF else free, message, false)

func _finish(origin: Vector2, message: String, clear_plots: bool) -> void:
	phase = Phase.DONE
	end_reason = message
	if clear_plots:
		var plots: Node = get_tree().get_first_node_in_group("plot_manager")
		if plots != null:
			plots.clear_rect(box.footprint_at(origin))
	box.end_carried(origin)
	AudioManager.play("toolbox_set", origin)
	_release()
	_say(message)
	print("Toolbox put down at %s: %s" % [origin, message])
	queue_free()

# Before the lift: nothing happened to the box.
func cancel(message: String) -> void:
	if phase == Phase.DONE:
		return
	phase = Phase.DONE
	end_reason = message
	_release()
	_say(message)
	queue_free()

func _release() -> void:
	if is_instance_valid(player) and player.carrying_together == self:
		player.carrying_together = null
	if is_instance_valid(friend) and friend.carry_job == self:
		friend.end_carry_help()
	if is_instance_valid(box):
		box.carrier = null
		box.last_carry_end = end_reason
	if is_instance_valid(_ghost):
		_ghost.queue_free()

func _say(text: String) -> void:
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say(text)
