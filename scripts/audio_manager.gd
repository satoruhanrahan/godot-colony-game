extends Node

# Sound effects for the whole game (an autoload: AudioManager.play("chop_hit", position, pitch)).
#
#  - Every sound is a file in res://audio/<name>.wav (or .ogg / .mp3): drop a real sound in with the same
#    name and nothing in the code changes. A name with no file is simply silent.
#  - A sound can have variants (<name>_1.wav, <name>_2.wav, ...): one is picked at random for every play (never the
#    same one twice in a row). A plain <name>.wav / .ogg / .mp3 overrides the variants. The generated sounds are
#    listed in res://audio/generated_manifest.json (see tools/make_sounds.py).
#  - Positional: each sound is an AudioStreamPlayer2D at its place in the world, fading out with distance
#    so only what is near the camera is heard (max_distance, in pixels).
#  - A pool of players, so rapid hits never cut each other off (when every one is busy, the oldest sound
#    makes way).
#  - Buses "Master" and "SFX" (made here if the project has no bus layout), with exported volumes.
#  - M mutes and unmutes everything.
#  - Looping sounds (the saw) are started with play_loop and steered with update_loop / stop_loop.
#  - Sounds follow real time, not the clock-speed multiplier (the pitch and timing come from what is played).

const AUDIO_DIR: String = "res://audio/"
const EXTENSIONS: Array[String] = [".wav", ".ogg", ".mp3"]

# Sounds are heard up to this many pixels from the camera.
@export var max_distance: float = 360.0
@export var master_volume_db: float = 0.0
@export var sfx_volume_db: float = -3.0
@export var pool_size: int = 16
# Quiet footsteps while he walks (off by default).
@export var footsteps: bool = true
# Repeated hits all play at pitch 1.0, varied by up to +-hit_pitch_variation (3%) so they do not sound mechanical.
@export var hit_pitch_variation: float = 0.03
@export var mute_key: Key = KEY_M

var muted: bool = false
# Extra dB taken off the SFX bus (the sleep skip turns the sound down this way, instead of pitching it).
var quiet_db: float = 0.0

var _pool: Array[AudioStreamPlayer2D] = []
var _started: Dictionary = {}
# sound -> the streams it can play (its variants, or the one plain file); [] when there is none
var _streams: Dictionary = {}
var _last_variant: Dictionary = {}
var _loops: Dictionary = {}
var _next_loop: int = 1
var _master: int = 0
var _sfx: int = 0
var _ui: int = 0
# Where the positional players live: this node, or (when the world runs in the Shell's SubViewport) that viewport, so
# the camera there is their listener.
var _host: Node = null
# The sound effects are held (paused game): the SFX bus is muted and loops are paused.
var held: bool = false
var _ui_player: AudioStreamPlayer
# UI sounds are very quiet by default (dB).
@export var ui_volume_db: float = -10.0
# What has played lately, newest last (for tests and tuning): [name, pitch, volume_db].
var log: Array = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_master = AudioServer.get_bus_index("Master")
	_sfx = AudioServer.get_bus_index("SFX")
	if _sfx < 0:
		AudioServer.add_bus()
		_sfx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_sfx, "SFX")
		AudioServer.set_bus_send(_sfx, "Master")
	_ui = AudioServer.get_bus_index("UI")
	if _ui < 0:
		AudioServer.add_bus()
		_ui = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_ui, "UI")
		AudioServer.set_bus_send(_ui, "Master")
	apply_volumes()
	_host = self
	for i in pool_size:
		_pool.append(_make_player())
	_ui_player = AudioStreamPlayer.new()
	_ui_player.bus = "UI"
	add_child(_ui_player)

func set_quiet(db: float) -> void:
	quiet_db = db
	apply_volumes()

func apply_volumes() -> void:
	AudioServer.set_bus_volume_db(_master, master_volume_db)
	# Quieter while the game is fast-forwarded.
	var quieter: float = 0.0
	var fast: Node = get_node_or_null("/root/FastForward")
	if fast != null and fast.is_fast():
		quieter = linear_to_db(maxf(0.01, fast.ff_sfx_volume))
	AudioServer.set_bus_volume_db(_sfx, sfx_volume_db + quieter + quiet_db)

func _make_player() -> AudioStreamPlayer2D:
	var p := AudioStreamPlayer2D.new()
	p.bus = "SFX"
	p.max_distance = max_distance
	p.attenuation = 1.0
	_host.add_child(p)
	return p

# Moves every positional player to `host` (a node of the world's viewport) and makes new ones there.
func set_host(host: Node) -> void:
	_host = host
	var players: Array = _pool.duplicate()
	players.append_array(_step_pool)
	for loop_player in _loops.values():
		players.append(loop_player)
	for p in players:
		if is_instance_valid(p) and p.get_parent() != host:
			p.get_parent().remove_child(p)
			host.add_child(p)

# A quiet interface sound (not positional, on the UI bus, so it still plays while the game is paused).
func play_ui(sound: String, extra_db: float = 0.0) -> void:
	var stream: AudioStream = stream_for(sound)
	if stream == null or _ui_player == null:
		return
	_ui_player.stream = stream
	_ui_player.volume_db = ui_volume_db + extra_db
	_ui_player.pitch_scale = 1.0 + randf_range(-0.02, 0.02)
	_ui_player.play()

# Holds the world's sounds (a paused game): the SFX bus is muted, the loops and the ones playing stop where they are.
func hold(value: bool) -> void:
	held = value
	AudioServer.set_bus_mute(_sfx, value)
	for p in _pool + _step_pool:
		if is_instance_valid(p):
			p.stream_paused = value
	for p in _loops.values():
		p.stream_paused = value

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == mute_key:
		set_muted(not muted)
		var hud: Node = get_tree().get_first_node_in_group("hud")
		if hud != null:
			hud.say("Sound off" if muted else "Sound on")

func set_muted(value: bool) -> void:
	muted = value
	AudioServer.set_bus_mute(_master, muted)

func _find_stream(path_base: String) -> AudioStream:
	for ext in EXTENSIONS:
		var path: String = path_base + ext
		if ResourceLoader.exists(path):
			return load(path)
	return null

# The streams a sound can play: the plain file if there is one, else its numbered variants.
func variants_of(sound: String) -> Array:
	if _streams.has(sound):
		return _streams[sound]
	var found: Array = []
	var plain: AudioStream = _find_stream(AUDIO_DIR + sound)
	if plain != null:
		found.append(plain)
	else:
		for i in range(1, 10):
			var v: AudioStream = _find_stream(AUDIO_DIR + sound + "_" + str(i))
			if v == null:
				break
			found.append(v)
	_streams[sound] = found
	return found

# One stream of the sound, chosen at random (not the one played last when there is a choice); null if there is none.
func stream_for(sound: String) -> AudioStream:
	var list: Array = variants_of(sound)
	if list.is_empty():
		return null
	var index: int = randi() % list.size()
	if list.size() > 1 and index == _last_variant.get(sound, -1):
		index = (index + 1 + randi() % (list.size() - 1)) % list.size()
	_last_variant[sound] = index
	return list[index]

# The pitch for one hit of a repeated action: 1.0 with a tiny random variation.
func hit_pitch() -> float:
	return 1.0 + randf_range(-hit_pitch_variation, hit_pitch_variation)

# Footsteps have a pool of their own (6 voices; when all are busy a step is simply skipped), positional, heard up to
# step_max_distance px. `left`: the left foot plays the brighter variants (1 or 3), the right foot the darker (2 or 3).
@export var step_max_distance: float = 320.0
var _step_pool: Array[AudioStreamPlayer2D] = []

func play_step(sound: String, world_position: Vector2, volume_db: float, left: bool) -> AudioStreamPlayer2D:
	log.append([sound, 1.0, snappedf(volume_db, 0.01)])
	if log.size() > 200:
		log.pop_front()
	var list: Array = variants_of(sound)
	if list.is_empty():
		return null
	var index: int = 0
	if list.size() >= 3:
		index = (0 if randf() < 0.65 else 2) if left else (1 if randf() < 0.65 else 2)
	else:
		index = randi() % list.size()
	if _step_pool.is_empty():
		for i in 6:
			var p := AudioStreamPlayer2D.new()
			p.bus = "SFX"
			p.max_distance = step_max_distance
			p.attenuation = 1.0
			_host.add_child(p)
			_step_pool.append(p)
	for p in _step_pool:
		if not is_instance_valid(p):
			continue
		if not p.playing:
			p.stream = list[index]
			p.global_position = world_position
			p.volume_db = volume_db
			p.pitch_scale = 1.0
			p.play()
			return p
	return null

# Plays a sound once at a place in the world. Returns the player (null if there is no such sound).
func play(sound: String, world_position: Vector2, pitch_scale: float = 1.0, volume_db: float = 0.0) -> AudioStreamPlayer2D:
	if sound == "footstep" and not footsteps:
		return null
	log.append([sound, snappedf(pitch_scale, 0.001), volume_db])
	if log.size() > 200:
		log.pop_front()
	var stream: AudioStream = stream_for(sound)
	if stream == null:
		return null
	var player: AudioStreamPlayer2D = _free_player()
	player.stream = stream
	player.global_position = world_position
	player.pitch_scale = maxf(0.05, pitch_scale)
	player.volume_db = volume_db
	player.max_distance = max_distance
	player.play()
	_started[player] = Time.get_ticks_msec()
	return player

func _free_player() -> AudioStreamPlayer2D:
	var oldest: AudioStreamPlayer2D = _pool[0]
	for p in _pool:
		if not p.playing:
			return p
		if _started.get(p, 0) < _started.get(oldest, 0):
			oldest = p
	return oldest

# --- Loops (the saw) ------------------------------------------------------------------------------------

# Starts a looping sound; returns a handle for update_loop / stop_loop (0 if there is no such sound).
func play_loop(sound: String, world_position: Vector2, pitch_scale: float = 1.0, volume_db: float = 0.0) -> int:
	log.append([sound + " (loop)", snappedf(pitch_scale, 0.001), volume_db])
	var stream: AudioStream = stream_for(sound)
	if stream == null:
		return 0
	var player: AudioStreamPlayer2D = _make_player()
	if stream is AudioStreamWAV:
		# loops inside the stream, so there is no gap at the restart
		stream = stream.duplicate()
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = int(stream.get_length() * stream.mix_rate)
	player.stream = stream
	player.global_position = world_position
	player.pitch_scale = maxf(0.05, pitch_scale)
	player.volume_db = volume_db
	# Whatever the file is, it plays again when it ends.
	player.finished.connect(_on_loop_finished.bind(player))
	player.play()
	var handle: int = _next_loop
	_next_loop += 1
	_loops[handle] = player
	return handle

func update_loop(handle: int, pitch_scale: float, volume_db: float) -> void:
	var player: AudioStreamPlayer2D = _loops.get(handle)
	if player != null:
		player.pitch_scale = maxf(0.05, pitch_scale)
		player.volume_db = volume_db

func stop_loop(handle: int) -> void:
	var player: AudioStreamPlayer2D = _loops.get(handle)
	if player == null:
		return
	_loops.erase(handle)
	player.queue_free()

func _on_loop_finished(player: AudioStreamPlayer2D) -> void:
	if is_instance_valid(player) and _loops.values().has(player):
		player.play()
