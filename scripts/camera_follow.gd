extends Camera2D

# Standalone camera: copies the target's position each frame, rounded to whole
# pixels, so the character stays centred without sub-pixel shimmer. The target's
# origin is at its feet, so aim at the middle of the sprite (8px above).
@export var target_offset: Vector2 = Vector2(0, -8)

# While the player is inside a house the camera looks at the middle of the room instead (INF = follow him).
var fixed_position: Vector2 = Vector2.INF

@onready var target: Node2D = get_node("../MainCharacter")

func _ready() -> void:
	global_position = (target.global_position + target_offset).round()

func _process(_delta: float) -> void:
	if fixed_position != Vector2.INF:
		global_position = fixed_position.round()
		return
	global_position = (target.global_position + target_offset).round()
