extends Resource

# THE TOOLS OF WORK in one place (assets/tool_config.tres; ToolConfig.cfg() loads it, falling back to these defaults).
#
# job_tools is THE table: which tool each kind of job needs ("" = none). The colonists' work jobs (work_jobs.gd) and the Assist me copies
# (colonist_order_ai.gd) look their tool up here through tool_for(). Jobs that need none (hauling, sawing, pulling grass, following,
# eating, carrying things) say "". There is no handheld saw in the game (the pit saw's blade is part of the pit saw), and the bucket and
# the seed bag are carried items, not tools, so none of them is a row with a tool.

static var _cached: Resource = null

static func cfg() -> Resource:
	if _cached == null:
		var path: String = "res://assets/tool_config.tres"
		_cached = load(path) if ResourceLoader.exists(path) else (load("res://scripts/tool_config.gd") as GDScript).new()
	return _cached

# job -> tool
@export var job_tools: Dictionary = {
	&"chop": &"axe", &"delimb": &"axe",
	&"build": &"hammer", &"hammer": &"hammer", &"dismantle": &"hammer",
	&"dig": &"shovel",
	&"till": &"hoe", &"harvest": &"sickle",
	&"light_fire": &"fire_starter",
	&"saw": &"", &"pull": &"", &"water": &"", &"haul": &"", &"follow": &"", &"eat": &"", &"carry": &"",
}
# A loose tool this close (px) to him may be fetched when no toolbox has one.
@export var tool_fetch_radius_px: float = 400.0
# He puts the tool back after this long with nothing to use it on.
@export var tool_return_idle_seconds: float = 10.0
# While a tool is missing he looks again at least this often (and at once when it turns up) and does not repeat the message.
@export var tool_recheck_seconds: float = 10.0
# Taking a tool out of the toolbox (or putting it back) takes this long, lid open.
@export var tool_take_seconds: float = 0.5

static func tool_for(job: StringName) -> StringName:
	return cfg().job_tools.get(job, &"")
