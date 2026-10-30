extends RefCounted

# THE ONE text of a blueprint on hover (drawn by the work overlay in the screen-space pixel text), the same for every kind of
# blueprint:
#   line 1: the building's name
#   line 2: "Needs: Planks 2/4, Stones 1/3" while materials are missing (delivered / required for each; a material that is complete
#           says "done"), then "Ready to build (3/6 hits)" once everything is delivered (hits done / hits needed).
# (There are no filled / unfilled blocks any more.) A wooden bed with bedding reads "Bedding 2/3" in the same place.

const NAMES: Dictionary = {
	"plank": "Planks", "planks": "Planks", "branch": "Branches", "flat_stone": "Stones", "saw_blade": "Saw blade", "blade": "Saw blade",
	"dig": "Digging",
}

static func material_name(kind: String) -> String:
	return NAMES.get(kind, kind.replace("_", " ").capitalize())

# [name, status] for a blueprint node, or [] when it is not one.
static func lines(node: Node) -> Array:
	if node == null or not is_instance_valid(node):
		return []
	if node.is_in_group("pit_saws"):
		if node.is_built():
			return []
		var parts: Array[String] = []
		var missing: bool = false
		parts.append(_part("Digging", node.dig_count, node.DIG_HITS))
		missing = missing or node.dig_count < node.DIG_HITS
		parts.append(_part("Planks", node.planks_delivered, node.PLANKS_REQUIRED))
		missing = missing or node.planks_delivered < node.PLANKS_REQUIRED
		parts.append(_part("Saw blade", node.blades_delivered, node.BLADES_REQUIRED))
		missing = missing or node.blades_delivered < node.BLADES_REQUIRED
		return ["Pit Saw", _status(parts, missing, node.build_progress, node.PIT_BUILD_HITS)]
	if node.is_in_group("buildings") and node.get("state") != null and node.state != node.State.BUILT:
		var parts2: Array[String] = []
		var missing2: bool = false
		if node.plank_cost > 0:
			parts2.append(_part("Planks", node.planks_ready, node.plank_cost))
			missing2 = missing2 or node.planks_ready < node.plank_cost
		for kind in node.materials_cost:
			var have: int = int(node.materials_ready.get(kind, 0))
			var need: int = int(node.materials_cost[kind])
			parts2.append(_part(material_name(String(kind)), have, need))
			missing2 = missing2 or have < need
		return [node.display_name(), _status(parts2, missing2, node.build_progress, node.BUILD_HITS)]
	if node.is_in_group("beds") and node.has_method("is_wooden") and node.is_wooden():
		return ["Wooden Bed", "Bedding %d/%d" % [node.bedding_count(), node.bedding_max]]
	return []

static func _part(label: String, have: int, need: int) -> String:
	return "%s done" % label if have >= need else "%s %d/%d" % [label, have, need]

static func _status(parts: Array[String], missing: bool, hits: int, hits_needed: int) -> String:
	if missing:
		return "Needs: " + ", ".join(parts)
	return "Ready to build (%d/%d hits)" % [hits, hits_needed]
