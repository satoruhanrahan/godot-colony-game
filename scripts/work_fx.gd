extends RefCounted

# Tiny pixel-style visual effects for work: one-shot particle bursts (a few 1-2 px specks, short-lived,
# Nearest, no smoothing) and a small sideways shake. They follow real time, never the clock-speed multiplier.

const PARTICLE_Z: int = 95

const LEAF: Array[Color] = [Color(0.36, 0.62, 0.26), Color(0.52, 0.78, 0.33), Color(0.28, 0.5, 0.22)]
const CHIP: Array[Color] = [Color(0.78, 0.55, 0.3), Color(0.9, 0.72, 0.45), Color(0.55, 0.38, 0.2)]
const DIRT: Array[Color] = [Color(0.42, 0.29, 0.18), Color(0.55, 0.4, 0.25), Color(0.33, 0.22, 0.14)]
const SPARK: Array[Color] = [Color(1.0, 0.95, 0.6), Color(1.0, 0.8, 0.35), Color(1.0, 1.0, 0.9)]
const DUST: Array[Color] = [Color(0.86, 0.8, 0.66), Color(0.74, 0.68, 0.54)]
const GRASS: Array[Color] = [Color(0.42, 0.72, 0.3), Color(0.6, 0.85, 0.38), Color(0.8, 0.85, 0.4)]
const SAWDUST: Array[Color] = [Color(0.93, 0.85, 0.62), Color(0.82, 0.7, 0.45)]
const BERRY: Array[Color] = [Color(0.85, 0.15, 0.2), Color(0.95, 0.3, 0.3), Color(0.6, 0.1, 0.25)]
const POP: Array[Color] = [Color(1.0, 1.0, 0.85), Color(1.0, 0.92, 0.5), Color(1.0, 1.0, 1.0)]

# A one-shot burst at a world position: `count` specks of the given colours, flying off in `direction`
# (spread in degrees) at about `speed` px/s, falling with `gravity`, gone after `life` seconds.
static func burst(tree: SceneTree, pos: Vector2, colors: Array[Color], count: int, speed: float, life: float, gravity: float, direction: Vector2 = Vector2.UP, spread: float = 60.0, size: float = 1.0) -> void:
	var parent: Node = tree.current_scene
	if parent == null:
		return
	var p := CPUParticles2D.new()
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	gradient.colors = PackedColorArray([colors[0], colors[colors.size() - 1]])
	p.emitting = false
	p.one_shot = true
	p.amount = maxi(1, count)
	p.explosiveness = 1.0
	p.lifetime = life
	p.local_coords = false
	p.direction = direction
	p.spread = spread
	p.gravity = Vector2(0.0, gravity)
	p.initial_velocity_min = speed * 0.5
	p.initial_velocity_max = speed
	p.scale_amount_min = size
	p.scale_amount_max = size * 2.0
	p.color_initial_ramp = gradient
	p.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	p.z_index = PARTICLE_Z
	p.position = pos.round()
	parent.add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)

static func leaves(tree: SceneTree, pos: Vector2, count: int = 2) -> void:
	burst(tree, pos, LEAF, count, 22.0, 0.7, 70.0, Vector2.DOWN, 70.0)

static func chips(tree: SceneTree, pos: Vector2, away: float = 1.0) -> void:
	burst(tree, pos, CHIP, 3, 55.0, 0.35, 160.0, Vector2(away, -0.6), 35.0)

static func dirt(tree: SceneTree, pos: Vector2) -> void:
	burst(tree, pos, DIRT, 4, 45.0, 0.4, 170.0, Vector2.UP, 50.0)

static func spark(tree: SceneTree, pos: Vector2) -> void:
	burst(tree, pos, SPARK, 3, 60.0, 0.18, 60.0, Vector2.UP, 80.0)

static func dust(tree: SceneTree, pos: Vector2, count: int = 3) -> void:
	burst(tree, pos, DUST, count, 16.0, 0.5, -8.0, Vector2.UP, 90.0)

static func rustle(tree: SceneTree, pos: Vector2) -> void:
	burst(tree, pos, GRASS, 4, 30.0, 0.45, 90.0, Vector2.UP, 70.0)

static func sawdust(tree: SceneTree, pos: Vector2) -> void:
	burst(tree, pos, SAWDUST, 4, 24.0, 0.5, 30.0, Vector2.UP, 55.0)

# A berry comes off: a couple of red specks and a leaf or two.
static func berries(tree: SceneTree, pos: Vector2) -> void:
	burst(tree, pos, BERRY, 3, 28.0, 0.4, 120.0, Vector2.UP, 60.0)
	burst(tree, pos, LEAF, 2, 22.0, 0.5, 80.0, Vector2.UP, 90.0)

# A few crumbs when a berry is eaten.
static func crumbs(tree: SceneTree, pos: Vector2) -> void:
	burst(tree, pos, BERRY, 4, 26.0, 0.35, 140.0, Vector2.UP, 70.0)

# The small pop / sparkle when a job is done.
static func pop(tree: SceneTree, pos: Vector2) -> void:
	burst(tree, pos, POP, 7, 42.0, 0.35, 20.0, Vector2.UP, 180.0)

# A small sideways shake of a node (a few pixels, back and forth, settling): its own position afterwards is
# exactly what it was before.
static func shake(node: Node2D, amplitude: float = 1.5, duration: float = 0.16) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not node.has_meta("shake_base"):
		node.set_meta("shake_base", node.position)
	var base: Vector2 = node.get_meta("shake_base")
	if node.has_meta("shake_tween"):
		var old: Tween = node.get_meta("shake_tween")
		if old != null and old.is_valid():
			old.kill()
	node.position = base
	var tw: Tween = node.create_tween()
	node.set_meta("shake_tween", tw)
	var step: float = duration / 4.0
	tw.tween_property(node, "position", base + Vector2(amplitude, 0.0), step)
	tw.tween_property(node, "position", base + Vector2(-amplitude, 0.0), step)
	tw.tween_property(node, "position", base + Vector2(amplitude * 0.5, 0.0), step)
	tw.tween_property(node, "position", base, step)
