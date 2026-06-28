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
		required_functions = (current_level.get("tenant", {}) as Dictionary)\
			.get("required_functions", []).duplicate() as Array
		fulfilled_functions = []
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
			required_functions = level["tenant"]["required_functions"].duplicate()
			fulfilled_functions = []
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


func update_functions(placed_furniture_ids: Array, extra_functions: Array = []) -> void:
	fulfilled_functions = []
	for fid in placed_furniture_ids:
		var f := get_furniture_by_id(fid)
		if f.is_empty():
			continue
		for func_name in f["functions"]:
			if func_name not in fulfilled_functions:
				fulfilled_functions.append(func_name)
	for fn in extra_functions:
		if fn not in fulfilled_functions:
			fulfilled_functions.append(fn)

	if not moments.is_empty():
		moment_results.clear()
		for m in moments:
			var mid     := m["id"]    as String
			var m_needs := m["needs"] as Array
			var m_fulfilled: Array = []
			for fid in placed_furniture_ids:
				var f := get_furniture_by_id(fid)
				if f.is_empty():
					continue
				var has_states: bool = not (f.get("folded_functions", []) as Array).is_empty()
				if f.get("foldable", false) and has_states:
					var ext_funcs := f.get("extended_functions", []) as Array
					var fld_funcs := f.get("folded_functions",   []) as Array
					var use_ext := false
					for fn in ext_funcs:
						if fn in m_needs:
							use_ext = true
							break
					var chosen := ext_funcs if use_ext else fld_funcs
					for fn in chosen:
						if fn not in m_fulfilled:
							m_fulfilled.append(fn)
				else:
					for fn in f["functions"] as Array:
						if fn not in m_fulfilled:
							m_fulfilled.append(fn)
			for fn in extra_functions:
				if fn not in m_fulfilled:
					m_fulfilled.append(fn)
			moment_results[mid] = {"fulfilled": m_fulfilled, "required": m_needs}
		moments_updated.emit(moment_results)

	functions_updated.emit(fulfilled_functions, required_functions)


func check_win() -> bool:
	if moments.is_empty():
		for req in required_functions:
			if req not in fulfilled_functions:
				return false
		return true
	for m in moments:
		var mid    := m["id"]    as String
		var m_needs := m["needs"] as Array
		var m_fulfilled := moment_results.get(mid, {}).get("fulfilled", []) as Array
		for need in m_needs:
			if need not in m_fulfilled:
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
