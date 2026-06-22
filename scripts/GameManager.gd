extends Node
class_name GameManager

signal budget_changed(new_budget: int)
signal rent_changed(monthly_rent: int)
signal functions_updated(fulfilled: Array, required: Array)

const RETIRE_GOAL := 3000  # €/Monat bis Rente

var budget: int = 3000
var monthly_rent: int = 0
var current_level: Dictionary = {}
var required_functions: Array = []
var fulfilled_functions: Array = []

var furniture_data: Dictionary = {}
var levels_data: Dictionary = {}

func _ready() -> void:
	add_to_group("game_manager")
	furniture_data = _load_json("res://data/furniture.json")
	levels_data = _load_json("res://data/levels.json")


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Kann nicht laden: " + path)
		return {}
	var json := JSON.new()
	json.parse(file.get_as_text())
	return json.get_data()


func load_level(level_id: String) -> void:
	for level in levels_data["levels"]:
		if level["id"] == level_id:
			current_level = level
			budget = level["starting_budget"]
			required_functions = level["tenant"]["required_functions"].duplicate()
			fulfilled_functions = []
			budget_changed.emit(budget)
			functions_updated.emit(fulfilled_functions, required_functions)
			return
	push_error("Level nicht gefunden: " + level_id)


func get_furniture_by_id(furniture_id: String) -> Dictionary:
	for f in furniture_data["furniture"]:
		if f["id"] == furniture_id:
			return f
	return {}


func buy_furniture(furniture_id: String) -> bool:
	var f := get_furniture_by_id(furniture_id)
	if f.is_empty():
		return false
	if budget < f["buy_price"]:
		return false
	budget -= f["buy_price"]
	budget_changed.emit(budget)
	return true


func sell_furniture(furniture_id: String) -> void:
	var f := get_furniture_by_id(furniture_id)
	if f.is_empty():
		return
	budget += f["buy_price"]
	budget_changed.emit(budget)


func update_functions(placed_furniture_ids: Array) -> void:
	fulfilled_functions = []
	for fid in placed_furniture_ids:
		var f := get_furniture_by_id(fid)
		if f.is_empty():
			continue
		for func_name in f["functions"]:
			if func_name not in fulfilled_functions:
				fulfilled_functions.append(func_name)
	functions_updated.emit(fulfilled_functions, required_functions)


func check_win() -> bool:
	for req in required_functions:
		if req not in fulfilled_functions:
			return false
	return true


func rent_apartment() -> void:
	if not check_win():
		return
	var rent: int = current_level["tenant"]["monthly_rent"]
	monthly_rent += rent
	rent_changed.emit(monthly_rent)


func is_retired() -> bool:
	return monthly_rent >= RETIRE_GOAL
