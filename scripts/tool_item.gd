extends Sprite2D

# A tool lying on the ground (the hammer, the shovel or the axe): one per item, no collision. The
# node's origin is the base of the tool (the bottom of its art), so it depth-sorts by its base
# under the same y-sorted parent as everything else; the sprite offset in each scene puts the
# bottom-centre of the art on the origin. The player picks it up with E or a click and puts it
# down with Q or a right-click. The Hauler and the colonists never look at these groups.

# The group that says what it is: "hammers", "shovels" or "axes".
@export var tool_group: StringName = &"hammers"

func _ready() -> void:
	add_to_group(tool_group)

func interact_point() -> Vector2:
	return global_position + Vector2(0, -2)
