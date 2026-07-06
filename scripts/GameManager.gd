extends Node
class_name GameManager

signal budget_changed(new_budget: int)
signal functions_updated(fulfilled: Array, required: Array)
signal moments_updated(results: Dictionary)

var budget: int = 3000
var current_level: Dictionary = {}
var required_functions: Array = []
var fulfilled_functions: Array = []
var moments: Array = []
var moment_results: Dictionary = {}  # moment_id -> {fulfilled:[], required:[]}
var moment_verified: Dictionary = {}  # moment_id -> bool; true once its needs were met with the real furniture state
var zone_separations: Array = []     # [[ [fnsA], [fnsB] ], ...] — groups that must be in separate zones
var current_zones: Array = []        # latest zone snapshot from the active floor

var furniture_data: Dictionary = {}
var levels_data: Dictionary = {}

var allowed_furniture:   Array = []  # [] = no filter; otherwise ID whitelist
var starting_inventory:  Array = []  # [{id, count}] unplaced items player owns
var starting_furniture:  Array = []  # [{id, x, y}] items pre-placed in the apartment


func _ready() -> void:
	add_to_group("game_manager")
	furniture_data = _load_json("res://data/furniture.json")
	levels_data = _load_json("res://data/levels.json")


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Cannot load: " + path)
		return {}
	var json := JSON.new()
	json.parse(file.get_as_text())
	return json.get_data()


func load_level(level_id: String) -> void:
	# Custom level created in the level editor
	if level_id == "_custom" and not GameState.custom_level_data.is_empty():
		current_level = GameState.custom_level_data
		budget = current_level.get("starting_budget", 2000) as int
		moments = current_level.get("moments", []) as Array
		moment_results = {}
		moment_verified = {}
		var _tenant := (current_level.get("tenant", {}) as Dictionary)
		required_functions = _tenant.get("required_functions", []).duplicate() as Array
		zone_separations   = _tenant.get("zone_separations",   []).duplicate(true) as Array
		fulfilled_functions = []
		current_zones = []
		allowed_furniture  = (current_level.get("allowed_furniture",  []) as Array).duplicate()
		starting_inventory = (current_level.get("starting_inventory", []) as Array).duplicate(true)
		starting_furniture = (current_level.get("starting_furniture", []) as Array).duplicate(true)
		budget_changed.emit(budget)
		functions_updated.emit(fulfilled_functions, required_functions)
		if not moments.is_empty():
			moments_updated.emit(moment_results)
		return

	for level in levels_data["levels"]:
		if level["id"] == level_id:
			current_level = level
			budget = level["starting_budget"]
			moments = level.get("moments", [])
			moment_results = {}
			moment_verified = {}
			required_functions = level["tenant"]["required_functions"].duplicate()
			zone_separations   = (level.get("tenant", {}) as Dictionary).get("zone_separations", []).duplicate(true) as Array
			fulfilled_functions = []
			current_zones = []
			allowed_furniture  = (level.get("allowed_furniture",  []) as Array).duplicate()
			starting_inventory = (level.get("starting_inventory", []) as Array).duplicate(true)
			starting_furniture = (level.get("starting_furniture", []) as Array).duplicate(true)
			budget_changed.emit(budget)
			functions_updated.emit(fulfilled_functions, required_functions)
			if not moments.is_empty():
				moments_updated.emit(moment_results)
			return
	push_error("Level not found: " + level_id)


func get_furniture_by_id(furniture_id: String) -> Dictionary:
	for f in furniture_data["furniture"]:
		if f["id"] == furniture_id:
			return f
	return {}


func buy_furniture(furniture_id: String) -> bool:
	var f := get_furniture_by_id(furniture_id)
	if f.is_empty() or budget < f["buy_price"]:
		return false
	budget -= f["buy_price"]
	budget_changed.emit(budget)
	return true


func spend(amount: int) -> void:
	budget -= amount
	budget_changed.emit(budget)


func sell_furniture(furniture_id: String) -> void:
	var f := get_furniture_by_id(furniture_id)
	if f.is_empty():
		return
	budget += f["buy_price"]
	budget_changed.emit(budget)


# Consume one starting-inventory item and return its data (or {} if unavailable).
# Called when the player places or sells a starting-inventory item.
func consume_starting_item(furniture_id: String) -> Dictionary:
	for i in range(starting_inventory.size()):
		var e := starting_inventory[i] as Dictionary
		if e["id"] == furniture_id:
			e["count"] = (e["count"] as int) - 1
			if (e["count"] as int) <= 0:
				starting_inventory.remove_at(i)
			return get_furniture_by_id(furniture_id)
	return {}


# Sell one starting-inventory item: remove it and credit sell_price to budget.
func sell_starting_item(furniture_id: String) -> bool:
	var f := consume_starting_item(furniture_id)
	if f.is_empty():
		return false
	budget += f.get("sell_price", f.get("buy_price", 0)) as int
	budget_changed.emit(budget)
	return true


# entry is either a live Furniture node (floor items — reflects its REAL
# fold state) or a plain furniture-id String (wall items, which don't fold).
# moment_id selects WHICH moment's stored fold state to read for foldable
# furniture; "" means "whatever is currently displayed" (used outside moments).
func _functions_of(entry, moment_id: String = "") -> Array:
	if entry is Furniture:
		var fur := entry as Furniture
		if moment_id != "":
			return fur.functions_for_moment(moment_id)
		return fur.functions
	var f := get_furniture_by_id(entry as String)
	return (f.get("functions", []) as Array) if not f.is_empty() else []


func update_functions(placed_furniture: Array, extra_functions: Array = [], active_moment_id: String = "",
		free_tiles_by_moment: Dictionary = {}) -> void:
	fulfilled_functions = []
	for entry in placed_furniture:
		for fn in _functions_of(entry, active_moment_id):
			if fn not in fulfilled_functions:
				fulfilled_functions.append(fn)
	for fn in extra_functions:
		if fn not in fulfilled_functions:
			fulfilled_functions.append(fn)

	if not moments.is_empty():
		moment_results.clear()
		# Each moment keeps its OWN fold state per piece of furniture (a sofa
		# bed can be folded for Day and unfolded for Night at the same time) —
		# so recompute what's fulfilled separately for every moment, reading
		# THAT moment's stored state, not whichever one is on screen.
		for m in moments:
			var mid     := m["id"]    as String
			var m_needs := m["needs"] as Array
			var m_fulfilled: Array = []
			for entry in placed_furniture:
				for fn in _functions_of(entry, mid):
					if fn not in m_fulfilled:
						m_fulfilled.append(fn)
			for fn in extra_functions:
				if fn not in m_fulfilled:
					m_fulfilled.append(fn)
			# Space needs: a function satisfied by leaving enough floor open
			# (e.g. "sport") rather than by any piece of furniture — checked
			# against this moment's own free-tile count (folded pieces free
			# up more room than unfolded ones).
			var space_needs := m.get("space_needs", {}) as Dictionary
			if not space_needs.is_empty():
				var free := free_tiles_by_moment.get(mid, 0) as int
				for fn in space_needs:
					var min_free := space_needs[fn] as int
					if free >= min_free and fn not in m_fulfilled:
						m_fulfilled.append(fn)
			var currently_met := true
			for need in m_needs:
				if need not in m_fulfilled:
					currently_met = false
					break
			if currently_met:
				moment_verified[mid] = true
			moment_results[mid] = {
				"fulfilled": m_fulfilled,
				"required": m_needs,
				"verified": moment_verified.get(mid, false),
			}
		moments_updated.emit(moment_results)

	functions_updated.emit(fulfilled_functions, required_functions)


func update_zones(zones: Array) -> void:
	current_zones = zones


func _zone_fns_for_moment(zone: Dictionary, m_needs: Array) -> Array:
	var fns: Array = []
	for fid in zone.get("furniture_ids", []) as Array:
		var fd := get_furniture_by_id(fid)
		if fd.is_empty():
			continue
		var use_fns: Array
		var has_states: bool = not (fd.get("folded_functions", []) as Array).is_empty()
		if fd.get("foldable", false) and has_states:
			var ext_funcs := fd.get("extended_functions", []) as Array
			var fld_funcs := fd.get("folded_functions",   []) as Array
			var use_ext   := ext_funcs.any(func(fn): return fn in m_needs)
			use_fns = ext_funcs if use_ext else fld_funcs
		else:
			use_fns = fd.get("functions", []) as Array
		for fn in use_fns:
			if fn not in fns:
				fns.append(fn)
	return fns


func check_zone_separations() -> bool:
	if zone_separations.is_empty():
		return true
	# Build list of (moment_needs) to check — one entry per moment, or a single empty entry if no moments
	var needs_list: Array = []
	if moments.is_empty():
		needs_list.append([])  # no moment filtering
	else:
		for m in moments:
			needs_list.append((m as Dictionary).get("needs", []) as Array)

	for sep in zone_separations:
		var group_a := sep[0] as Array
		var group_b := sep[1] as Array
		for m_needs in needs_list:
			for zone in current_zones:
				var z_fns := _zone_fns_for_moment(zone as Dictionary, m_needs) \
					if not (m_needs as Array).is_empty() \
					else (zone as Dictionary).get("functions", []) as Array
				var has_a := group_a.any(func(fn): return fn in z_fns)
				var has_b := group_b.any(func(fn): return fn in z_fns)
				if has_a and has_b:
					return false
	return true


func check_win() -> bool:
	if not check_zone_separations():
		return false
	if moments.is_empty():
		for req in required_functions:
			if req not in fulfilled_functions:
				return false
		return true
	# Each moment must have been genuinely satisfied at some point — the player
	# actually set the furniture correctly for it (folded for Day, unfolded for
	# Night, etc). Since a shared foldable piece can't be in two states at
	# once, this checks "was ever verified", not "is true right now".
	for m in moments:
		var mid := m["id"] as String
		if not moment_verified.get(mid, false):
			return false
	return true


func calculate_stars() -> int:
	var starting := current_level.get("starting_budget", 1) as int
	if starting <= 0:
		return 1
	var pct := float(budget) / float(starting)
	if pct >= 0.40:
		return 3
	elif pct >= 0.15:
		return 2
	else:
		return 1


func get_funds_reward() -> int:
	var base := current_level.get("funds_base_reward", 0) as int
	var bonus := int(budget * 0.20)
	return base + bonus
