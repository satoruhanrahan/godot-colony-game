extends Node2D

# Keeps track of the colonists: who is housed, who moves into which finished building,
# and the HUD. Placed in the main scene beside the LandingPoint marker.

const COLONIST_SCENE: PackedScene = preload("res://scenes/Colonist.tscn")

# How many settlers one approved batch brings (see request_settler_batch).
@export var batch_size: int = 1
# The "Colonists / Housed / Free beds" counter: Always, or Useful = only once there is something to
# count (a house to live in, or someone housed) and for counter_linger seconds after it changes.
enum CounterMode { ALWAYS, USEFUL }
@export var counter_mode: CounterMode = CounterMode.USEFUL
@export var counter_linger: float = 4.0
# Free colonists (no house, not inside a building, not busy) wander near the MainCharacter and
# follow him when he leaves. Off: they wander round the LandingPoint as before.
@export var free_colonists_follow_player: bool = true
# The daily routine (replaces the old "come out for a stroll"): housed colonists are out by day and
# behave like free colonists (near the player, following him), go home to sleep at dusk, and wake at
# dawn; unhoused colonists sleep where they stand at night. Off: housed colonists stay inside for good.
@export var colonists_follow_schedule: bool = true
# They wander to points this far (in grid cells) from him...
@export var follow_radius_cells: float = 3.0
# ...and if he gets further away than this they stop and walk after him.
@export var leash_distance_cells: float = 5.0
# More than twice the leash away they hurry (their speed times this).
@export var catch_up_multiplier: float = 1.5
# They keep at least this far (px) from him, and this far (px) from each other.
@export var follow_min_distance: float = 20.0
@export var follow_spread: float = 16.0

@export_group("Orders")
# FOLLOW / ASSIST: he walks after the player once he is further than follow_distance_px and stops at follow_stop_px (plus a little
# random slack). His catch-up speed is at most follow_catchup_multiplier of his own, and never faster than the player walks when the
# player is slowed by tiredness.
@export var follow_distance_px: float = 48.0
@export var follow_stop_px: float = 28.0
@export var follow_catchup_multiplier: float = 1.15
# ASSIST: how far from the player he looks for work to copy, how long after the player's last work he stops copying, and how fast he works
# (his swings take 1 / friend_work_efficiency as long as the player's, on top of his tiredness and hunger).
@export var assist_radius_px: float = 160.0
@export var assist_idle_seconds: float = 4.0
@export var friend_work_efficiency: float = 0.8
# When true he works with the tool from the toolbox (he fetches it, waits with "No axe available" when it is not there); off: no tools.
@export var friend_needs_tools: bool = false
# How many people a room may already show before a following colonist waits at the door instead.
@export var visitor_limit: int = 4
# The quick order key (F): toggles Follow me / Stay here for the colonist within this many pixels (10 tiles).
@export var order_toggle_distance_px: float = 320.0

var colonists: Array = []
# The JobBoard (job_board.gd): roles and designated tasks plug in there.
var job_board: Node = null
var _clock: float = 0.0
var _counter_until: float = 0.0
# Where the MainCharacter was last seen (he is hidden while sawing; they use this then).
var last_player_position: Vector2 = Vector2.ZERO

@onready var landing: Marker2D = get_node("../LandingPoint")
@onready var count_label: Label = $Hud/CountLabel

func _ready() -> void:
	add_to_group("colony")
	job_board = load("res://scripts/job_board.gd").new()
	job_board.name = "JobBoard"
	add_child(job_board)
	# The marks of the colonists' tasks, and the designation mode that makes them (designation_mode.gd).
	var designation: Node2D = load("res://scripts/designation_mode.gd").new()
	designation.name = "Designation"
	add_child(designation)
	# The counter is the UI's crisp text, top-left.
	var old_hud: Node = get_node_or_null("Hud")
	if old_hud != null:
		old_hud.queue_free()
	count_label = Ui.screen_label("small")
	var player: Node2D = get_node_or_null("../MainCharacter")
	if player != null:
		last_player_position = player.global_position
	for building in get_tree().get_nodes_in_group("buildings"):
		_watch(building)
	get_tree().node_added.connect(_on_node_added)
	# The player's friend arrives with the game (deferred: the scene is still being set up).
	_spawn_colonists.call_deferred(1)

func _unhandled_input(event: InputEvent) -> void:
	# N stands in for the Council approving a batch (the real standing system comes later).
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_N:
		request_settler_batch()
		get_viewport().set_input_as_handled()
	# F: the colonist near him follows (Follow me) or stays (Stay here), whichever he was not doing.
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F and not event.ctrl_pressed and not event.shift_pressed and not event.alt_pressed and not Ui.any_panel_open():
		toggle_nearest_order()
		get_viewport().set_input_as_handled()

# The quick toggle: Follow me <-> Stay here for the nearest colonist within order_toggle_distance_px. Returns what it did.
func toggle_nearest_order() -> String:
	var player: Node2D = get_node_or_null("../MainCharacter")
	if player == null:
		return ""
	var best = null
	var best_d: float = order_toggle_distance_px
	for c in get_tree().get_nodes_in_group("colonists"):
		if c.dead:
			continue
		var d: float = c.global_position.distance_to(player.global_position)
		if d <= best_d:
			best_d = d
			best = c
	if best == null:
		return ""
	var hud: Node = get_tree().get_first_node_in_group("hud")
	var why: String = best.talk_block_reason()
	if why != "":
		if hud != null:
			hud.say(why)
		return why
	var Orders = load("res://scripts/colonist_orders.gd")
	var next: int = Orders.Stance.STAY if best.orders.stance == Orders.Stance.FOLLOW else Orders.Stance.FOLLOW
	best.set_stance(next)
	Ui.sfx("ui_click")
	var text: String = "%s: %s" % [best.display_name, Orders.ACK[next]]
	if hud != null:
		hud.say(text)
	return text

# The point free colonists gather round: the MainCharacter, or where he was last seen.
func player_anchor() -> Vector2:
	# While he is inside a house the free colonists wait outside, near its door.
	var player: Node = get_node_or_null("../MainCharacter")
	if player != null and player.inside_building != null and is_instance_valid(player.inside_building):
		return player.inside_building.door_position() + Vector2(0, 14)
	return last_player_position

func _process(delta: float) -> void:
	var player: Node2D = get_node_or_null("../MainCharacter")
	if player != null and player.visible:
		last_player_position = player.global_position
	_clock += delta
	var text: String = "Colonists: %d  Housed: %d  Free beds: %d" % [colonists.size(), _housed_count(), _free_beds()]
	if count_label.text != text:
		count_label.text = text
		# (Not for the start-up changes: the friend landing.)
		if _clock > 1.5:
			_counter_until = _clock + counter_linger
	count_label.position = Ui.snap(Vector2(Ui.px(12), Ui.px(10)))
	var useful: bool = _housed_count() > 0 or _free_beds() > 0
	count_label.visible = counter_mode == CounterMode.ALWAYS or useful or _clock < _counter_until

# PLACEHOLDER for the Council: called when a batch of settlers has been approved. Brings
# `count` colonists (default: batch_size) to the LandingPoint, but only when that many
# beds in finished houses are free and not already earmarked for colonists with no home.
# Returns true if they came.
func request_settler_batch(count: int = 0) -> bool:
	var wanted: int = count if count > 0 else batch_size
	if _free_beds() - _unhoused_count() < wanted:
		var hud = get_tree().get_first_node_in_group("hud")
		if hud != null:
			hud.say("No free houses for new settlers")
		return false
	_spawn_colonists(wanted)
	return true

func _spawn_colonists(count: int) -> void:
	for i in count:
		var colonist: Colonist = COLONIST_SCENE.instantiate()
		colonist.landing_position = landing.global_position
		# A batch spreads out a little so nobody stands exactly on top of another.
		colonist.position = landing.global_position + Vector2(i * 6.0, 0.0)
		# Same y-sorted parent as the other characters.
		get_parent().add_child(colonist)
		colonist.became_unhoused.connect(_on_colonist_unhoused)
		colonist.released.connect(_on_colonist_unhoused)
		colonists.append(colonist)
	print("%d colonist(s) landed" % count)
	_assign_colonists()

func _watch(building: Building) -> void:
	if not building.built.is_connected(_on_building_built):
		building.built.connect(_on_building_built)

func _on_node_added(node: Node) -> void:
	if node is Building:
		_watch(node)

func _on_building_built(_building: Building) -> void:
	_assign_colonists()

func _on_colonist_unhoused(_colonist: Colonist) -> void:
	_assign_colonists()

# A colonist has died: he no longer counts, and his bed (if any) is free for the next.
func colonist_died(colonist: Colonist) -> void:
	colonists.erase(colonist)
	_assign_colonists()

# Every free bed in a finished building gets the nearest colonist who has no home and
# has not been sent anywhere yet. The bed is claimed the moment he is chosen, so no bed
# or colonist is ever claimed twice.
func _assign_colonists() -> void:
	var assigned: bool = true
	while assigned:
		assigned = false
		for building in get_tree().get_nodes_in_group("buildings"):
			if building.free_beds() <= 0:
				continue
			var colonist = _nearest_unhoused(building.door_position())
			if colonist == null:
				return
			building.residents.append(colonist)
			colonist.move_in(building)
			assigned = true

func _nearest_unhoused(from: Vector2):
	var best = null
	var best_dist: float = INF
	for colonist in colonists:
		if not is_instance_valid(colonist) or not colonist.is_unhoused() or colonist.is_claimed():
			continue
		var d: float = colonist.position.distance_squared_to(from)
		if d < best_dist:
			best_dist = d
			best = colonist
	return best

func _unhoused_count() -> int:
	var n: int = 0
	for colonist in colonists:
		if colonist.is_unhoused():
			n += 1
	return n

func _housed_count() -> int:
	return colonists.size() - _unhoused_count()

# Beds in finished buildings that nobody has claimed.
func _free_beds() -> int:
	var n: int = 0
	for building in get_tree().get_nodes_in_group("buildings"):
		n += building.free_beds()
	return n
