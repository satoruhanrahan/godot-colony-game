extends CanvasLayer

# A full-screen black fade (above the HUD) for going in and out of a house.

var _rect: ColorRect

func _ready() -> void:
	layer = 80
	_rect = ColorRect.new()
	_rect.color = Color(0, 0, 0, 1)
	_rect.modulate.a = 0.0
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.fade_root.add_child(_rect)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_rect):
		_rect.queue_free()

# Fades to black over `seconds` (real time).
func fade_out(seconds: float = 0.3) -> void:
	var tw: Tween = create_tween().set_ignore_time_scale(true)
	tw.tween_property(_rect, "modulate:a", 1.0, seconds)
	await tw.finished

func fade_in(seconds: float = 0.3) -> void:
	var tw: Tween = create_tween().set_ignore_time_scale(true)
	tw.tween_property(_rect, "modulate:a", 0.0, seconds)
	await tw.finished
