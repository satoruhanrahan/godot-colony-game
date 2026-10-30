extends Sprite2D

# A berry bush on the ground: ripe (it holds berries_per_bush berries) or picked (bare). The node's origin is
# the base of the bush, so it depth-sorts by its base like everything else; no collision. One berry comes off
# per pick (the player with a basket, or a hungry colonist eating on the spot); a bush with none left turns
# picked and is ripe again after berry_regrow_clock_seconds of clock time (so clock_speed_multiplier speeds the
# regrowth up). Whoever is picking it claims it, so two never pick the same bush.

const BundleArt = preload("res://scripts/bundle_art.gd")
const RIPE: Texture2D = preload("res://sprites/berry_bush.png")
const PICKED: Texture2D = preload("res://sprites/berry_bush_picked.png")

@export var berries_per_bush: int = 3
# One full clock-day and a half by default.
@export var berry_regrow_clock_seconds: float = 900.0

var berries: int = 0
var claimed_by = null
var regrow_left: float = 0.0

func _ready() -> void:
	add_to_group("berry_bushes")
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	berries = berries_per_bush
	_apply_look()

func _apply_look() -> void:
	texture = RIPE if berries > 0 else PICKED
	offset = BundleArt.offset_for(texture)

func is_ripe() -> bool:
	return berries > 0

func try_claim(who) -> bool:
	if berries <= 0 or (claimed_by != null and claimed_by != who):
		return false
	claimed_by = who
	return true

func release_claim(who) -> void:
	if claimed_by == who:
		claimed_by = null

func interact_point() -> Vector2:
	return global_position + Vector2(0, -3)

# Where the player stands to pick (beside it, facing it) and where a colonist stands to eat.
func pick_spot() -> Vector2:
	return global_position + Vector2(-14, 3)

# One berry comes off. Returns true if there was one. The bush turns picked when the last is gone.
func pick_one() -> bool:
	if berries <= 0:
		return false
	berries -= 1
	if berries <= 0:
		regrow_left = berry_regrow_clock_seconds
		claimed_by = null
		_apply_look()
	return true

func _process(delta: float) -> void:
	if berries > 0:
		return
	var clock: Node = get_tree().get_first_node_in_group("game_clock")
	regrow_left -= clock.clock_delta if clock != null else delta
	if regrow_left <= 0.0:
		berries = berries_per_bush
		_apply_look()
