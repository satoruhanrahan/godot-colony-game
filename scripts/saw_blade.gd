extends Sprite2D

# A saw blade lying on the ground: one blade per item (no stacking), no collision. The node's
# origin is the base of the blade (the bottom-centre of its art), so it depth-sorts by its
# base under the same y-sorted parent as everything else. The picture (saw_blade.png) is a
# 32x32 canvas with the blade at x 9-11, y 9-25; the sprite offset in SawBlade.tscn puts the
# bottom-centre of that art on the origin. The player picks it up with E and puts it down with
# Q; the pit saw needs one to be finished.

func _ready() -> void:
	add_to_group("saw_blades")

func interact_point() -> Vector2:
	return global_position + Vector2(0, -2)
