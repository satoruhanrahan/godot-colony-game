extends Node2D

# Bundles of pulled grass lying on the ground, 1 to bundles_per_bed of them (a single bundle on the
# ground is a pile of 1). A bundle has an age (clock seconds, counted wherever it is: here, carried or in
# a bed) and looks green until it reaches bundle_to_hay_clock_seconds, then like hay; that is only the look.
# Bundles the player puts down close together join a pile; when the third one joins, the three become one
# GRASS BED (Bed.tscn) keeping their ages. The node's origin is the base of the pile (depth-sorted by it);
# no collision.

const BundleArt = preload("res://scripts/bundle_art.gd")
const GRASS: Texture2D = preload("res://sprites/grass_bundle.png")
const HAY: Texture2D = preload("res://sprites/hay_bundle.png")
# Where each bundle of the stack sits (on top of the one below), added to the art's own offset.
const STACK_OFFSETS: Array[Vector2] = [Vector2(0, 0), Vector2(1, -3), Vector2(-1, -6)]
# A pile of exactly two bundles has its own pictures: two_grass_bundles.png until both have aged, then
# two_hay_bundles.png (so a green and a hay bundle together still look green).
const TWO_GRASS: Texture2D = preload("res://sprites/two_grass_bundles.png")
const TWO_HAY: Texture2D = preload("res://sprites/two_hay_bundles.png")

# One age per bundle (clock seconds).
var ages: Array[float] = []
var _sprites: Array[Sprite2D] = []
var _pair: Sprite2D
var _hay_look: Array[bool] = []
var _clock: Node = null

func _ready() -> void:
	add_to_group("bundle_piles")
	for i in STACK_OFFSETS.size():
		var sprite := Sprite2D.new()
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(sprite)
		_sprites.append(sprite)
	_pair = Sprite2D.new()
	_pair.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_pair)
	_refresh()

func _game_clock() -> Node:
	if _clock == null:
		_clock = get_tree().get_first_node_in_group("game_clock")
	return _clock

func count() -> int:
	return ages.size()

func _max() -> int:
	var clock: Node = _game_clock() if is_inside_tree() else null
	return clock.bundles_per_bed if clock != null else 3

func is_full() -> bool:
	# (A pile of two in a house that holds all the beds it can stays loose: it takes no third bundle.)
	return count() >= _max() or (count() >= _max() - 1 and _house_is_full())

# The room this pile lies in (null outdoors).
func _room() -> Node2D:
	return load("res://scripts/building_interior.gd").room_at(get_tree(), global_position)

func _house_is_full() -> bool:
	var room: Node2D = _room()
	return room != null and room.building != null and is_instance_valid(room.building) and not room.has_room_for_bed()

# Said once until a bed is gone again.
func say_no_room() -> void:
	var room: Node2D = _room()
	if room == null or room.building.no_room_said:
		return
	room.building.no_room_said = true
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.say(room.cannot_fit_text("bed"))

func interact_point() -> Vector2:
	return global_position + Vector2(0, -2)

func _is_hay(age: float) -> bool:
	var clock: Node = _game_clock()
	return clock != null and age >= clock.bundle_to_hay_clock_seconds

func _process(_delta: float) -> void:
	var clock: Node = _game_clock()
	if clock == null:
		return
	var changed: bool = false
	for i in ages.size():
		ages[i] += clock.clock_delta
		if i < _hay_look.size() and _hay_look[i] != _is_hay(ages[i]):
			changed = true
	if changed:
		_refresh()

func _refresh() -> void:
	_hay_look.clear()
	for age in ages:
		_hay_look.append(_is_hay(age))
	# Two bundles share one picture.
	var pair_texture: Texture2D = null
	if ages.size() == 2:
		pair_texture = TWO_HAY if (_hay_look[0] and _hay_look[1]) else TWO_GRASS
	_pair.visible = pair_texture != null
	if pair_texture != null:
		_pair.texture = pair_texture
		_pair.offset = BundleArt.offset_for(pair_texture)
	for i in _sprites.size():
		_sprites[i].visible = i < ages.size() and pair_texture == null
		if i < ages.size():
			var texture: Texture2D = HAY if _hay_look[i] else GRASS
			_sprites[i].texture = texture
			_sprites[i].offset = BundleArt.offset_for(texture) + STACK_OFFSETS[i]

# One bundle (with this age) joins the pile; the third one turns the pile into a grass bed.
func add_bundle(age: float) -> bool:
	if is_full():
		return false
	ages.append(age)
	if count() >= _max():
		_become_bed()
	else:
		_refresh()
	return true

# Takes the newest bundle out and returns its age (-1 if there was none). The pile is gone when empty.
func take_bundle() -> float:
	if ages.is_empty():
		return -1.0
	var age: float = ages.pop_back()
	if ages.is_empty():
		remove_from_group("bundle_piles")
		queue_free()
	else:
		_refresh()
	return age

func _become_bed() -> void:
	AudioManager.play("bed_make", global_position, 1.0)
	load("res://scripts/work_fx.gd").pop(get_tree(), global_position + Vector2(0, -8))
	var bed: Node2D = (load("res://scenes/Bed.tscn") as PackedScene).instantiate()
	bed.position = position
	bed.ages.assign(ages)
	get_parent().add_child(bed)
	var player: Node = get_tree().get_first_node_in_group("player")
	if player != null:
		player.bed_made = true
	remove_from_group("bundle_piles")
	queue_free()

# Debug: every bundle is hay-old.
func age_to_hay() -> void:
	var clock: Node = _game_clock()
	for i in ages.size():
		ages[i] = maxf(ages[i], clock.bundle_to_hay_clock_seconds)
	_refresh()
