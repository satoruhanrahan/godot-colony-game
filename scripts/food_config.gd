extends Resource

# Every number of the first food chain (wheat -> flour -> flatbread) in one place: assets/food_config.tres.
# Anything can load it with FoodConfig.cfg() (const FoodConfig = preload("res://scripts/food_config.gd")).

static var _cached: Resource = null

static func cfg() -> Resource:
	if _cached == null:
		var path: String = "res://assets/food_config.tres"
		_cached = load(path) if ResourceLoader.exists(path) else (load("res://scripts/food_config.gd") as GDScript).new()
	return _cached

@export_group("Seed bag")
@export var seed_bag_capacity: int = 6
@export var start_seed_bag_seeds: int = 4

@export_group("Plots")
# The plot grid is its own grid (anchored at the world origin), independent of the 32 px grid.
@export var plot_size_px: int = 11
# How far (px, from his feet to the middle of the cell) a plot can be worked.
@export var reach_px: float = 28.0
@export var till_presses: int = 2
# Clock-seconds from sowing to ripe is wheat_grow_clock_seconds * ripe_at_fraction; the picture changes from
# "sown" to "growing" at growing_at_fraction of it. (1800 s = 3 game days; thirds: sown, growing, ripe.)
@export var wheat_grow_clock_seconds: float = 1800.0
@export var growing_at_fraction: float = 1.0 / 3.0
@export var ripe_at_fraction: float = 2.0 / 3.0
@export var wheat_per_harvest: int = 1
# Harvesting gives only the sheaf. Threshing a sheaf (a seed bag in the hands, E / click on a sheaf on the ground or a table) takes
# thresh_presses presses, destroys the sheaf and puts thresh_seeds_per_sheaf seeds into the bag (it needs room for all of them).
@export var thresh_seeds_per_sheaf: int = 3
@export var thresh_presses: int = 2

@export_group("Grinding Stone")
@export var flour_per_sheaf: int = 1
@export var grind_presses: int = 4

@export_group("Campfire")
@export var fuel_branch: float = 150.0
@export var fuel_plank: float = 600.0
@export var fuel_log: float = 900.0
@export var fire_max_fuel_clock_seconds: float = 1200.0
@export var spark_presses: int = 3
@export var stone_heat_clock_seconds: float = 30.0
# Flour on the stone cooks for this many clock-seconds of HOT stone (it pauses while the stone is cold).
@export var cook_clock_seconds: float = 40.0
# How many things the stone holds at once.
@export var campfire_stone_capacity: int = 1
# The campfire blueprint (BuildingType 'Campfire') asks for this many of each (assets/campfire_type.tres).
# Seconds a half-finished press sequence (grinding, sparking) keeps its claim and its progress.
@export var press_claim_seconds: float = 4.0

@export_group("Eating")
@export var flatbread_hunger_value: float = 8.0
# A colonist or worker this hungry (or hungrier) goes for flatbread first; otherwise berries first.
@export var bread_preferred_below: float = 25.0

@export_group("The map")
@export var flat_stones_on_map: int = 12
@export var branches_on_map: int = 8
@export var branches_per_tree_min: int = 1
@export var branches_per_tree_max: int = 3
# Scattered items keep at least this far (px) from each other, from buildings, trees and bushes.
@export var scatter_spacing_px: float = 48.0
@export var scatter_clearance_px: float = 20.0

@export_group("Water")
# The creek is all shallow, walkable water: it slows walking to this share of normal speed.
@export var creek_speed_multiplier: float = 0.75
# The creek: about creek_width_tiles wide, widening now and then up to creek_max_width_tiles (never more), wandering
# creek_meander_tiles from a straight line. Its layout comes from creek_seed (0 = a different one every run) and
# every tile of it is between creek_cabin_min_tiles and creek_cabin_max_tiles from the cabin (32 px tiles).
@export var creek_width_tiles: float = 2.0
@export var creek_max_width_tiles: float = 3.0
@export var creek_meander_tiles: float = 1.4
@export var creek_seed: int = 31
@export var creek_cabin_min_tiles: float = 15.0
@export var creek_cabin_max_tiles: float = 25.0
# The brook is heard up to this many tiles from the water (and fades smoothly with the distance).
@export var brook_hearing_tiles: float = 10.0
@export var bucket_capacity: int = 6
# Seconds one scoop takes at normal energy (the energy and hunger efficiency slow it), and one pour (onto a plot or
# the dough board).
@export var bucket_scoop_seconds: float = 0.4
@export var bucket_pour_seconds: float = 0.4
# A watered plot stays watered this many clock-seconds (growth only counts while it is).
@export var wheat_water_clock_seconds: float = 900.0
@export var knead_presses: int = 3
