extends StaticBody2D

# Collision for a tree's base. Once the Hauler has taken the Trunk away there is
# nothing left to bump into, so the shape is switched off.
@onready var shape: CollisionShape2D = $Shape

func _process(_delta: float) -> void:
	if not shape.disabled and not get_parent().has_node("Trunk"):
		shape.set_deferred("disabled", true)
