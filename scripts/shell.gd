extends Control

# The main scene's frame. The WORLD runs in a SubViewport of exactly 480 x 270 (the same pixels as before: art, camera,
# pixel snapping, nearest filtering all untouched) that is shown enlarged by the biggest WHOLE number that fits the
# window, in the middle of it (black bars round it). Everything you read is NOT in there: the UI (the Ui autoload) is
# drawn on top at the real window resolution, so text and UI art are crisp at any window size.
#
# Mouse and key events reach the world through the SubViewportContainer (positions are converted back to the 480 x 270
# view). The world's sounds are positional in that viewport (AudioManager.set_host).

const BASE: Vector2i = Vector2i(480, 270)

@export var world_scene: PackedScene = preload("res://scenes/lumberjack_test.tscn")

var container: SubViewportContainer
var world_viewport: SubViewport
var world: Node
# The whole-number enlargement of the world now.
var factor: int = 2

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# black bars round the world (the world's own background is untouched)
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.03, 0.025, 0.02)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	container = SubViewportContainer.new()
	container.name = "WorldContainer"
	container.stretch = true
	container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	container.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(container)
	world_viewport = SubViewport.new()
	world_viewport.name = "WorldViewport"
	world_viewport.size = BASE
	world_viewport.audio_listener_enable_2d = true
	world_viewport.handle_input_locally = true
	container.add_child(world_viewport)
	Ui.shell = self
	AudioManager.set_host(world_viewport)
	world = world_scene.instantiate()
	world_viewport.add_child(world)
	get_tree().root.size_changed.connect(_layout)
	_layout()

func _exit_tree() -> void:
	if Ui.shell == self:
		Ui.shell = null
	AudioManager.set_host(AudioManager)

# The enlargement and the position of the world in the window.
func _layout() -> void:
	var window: Vector2 = Vector2(get_tree().root.size)
	factor = maxi(1, mini(int(window.x) / BASE.x, int(window.y) / BASE.y))
	container.stretch_shrink = factor
	container.size = Vector2(BASE * factor)
	container.position = ((window - container.size) * 0.5).floor()

# A point of the world's 480 x 270 view as a point of the window.
func viewport_to_screen(p: Vector2) -> Vector2:
	return container.position + p * float(factor)

# A point of the window as a point of the world's view.
func screen_to_viewport(p: Vector2) -> Vector2:
	return (p - container.position) / float(factor)
