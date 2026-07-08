extends Node

signal company_funds_changed(amount: int)

const RETIRE_GOAL := 10000   # total portfolio rent to retire

var company_funds: int = 0
var portfolio_rent: int = 0
var completed: Dictionary = {}   # level_id -> { stars, first_time }
var owned: Array = []
var pending_level_id: String = "level_01"
var dev_bonus_stars: int = 0
var custom_level_data: Dictionary = {}
var testing_from_editor: bool = false  # set by LevelEditor._test_level(); back btn returns to editor
var resume_editor:       bool = false  # set by Main._go_back(); LevelEditor reloads custom_level_data


func _ready() -> void:
	for _lid in ["tut_basics","debug_moments","debug_rails","debug:_rail_moments","debug:_balcony",
			"debug:_sloped_ceiling",
			"twitch","calle_mayor","el_estudio_de_ana","la_pareja","el_pasillo_de_javi","zona_privada",
			"muchos_electrodomésticos",
			"mif_M","mif_A","mif_K","mif_E","mif_I1","mif_T1","mif_F","mif_I2","mif_T2"]:
		own_level(_lid)


func own_level(level_id: String) -> void:
	if level_id not in owned:
		owned.append(level_id)


func is_owned(level_id: String) -> bool:
	return level_id in owned


func buy_level(level_id: String, cost: int) -> bool:
	if company_funds < cost:
		return false
	company_funds -= cost
	own_level(level_id)
	company_funds_changed.emit(company_funds)
	return true


func complete_level(level_id: String, stars: int, funds_earned: int, monthly_rent: int) -> void:
	var first_time := level_id not in completed
	if first_time or completed[level_id]["stars"] < stars:
		completed[level_id] = {"stars": stars}
	if first_time:
		portfolio_rent += monthly_rent
	company_funds += funds_earned
	company_funds_changed.emit(company_funds)


func get_stars(level_id: String) -> int:
	return completed.get(level_id, {}).get("stars", 0) as int


func total_stars() -> int:
	var n := dev_bonus_stars
	for k in completed:
		n += completed[k]["stars"] as int
	return n


func dev_unlock_all(all_ids: Array) -> void:
	for lid in all_ids:
		own_level(lid as String)
	dev_bonus_stars = 200
	company_funds   = 999999
	company_funds_changed.emit(company_funds)


func is_retired() -> bool:
	return portfolio_rent >= RETIRE_GOAL
