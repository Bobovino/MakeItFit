extends Node

const FurnitureScene := preload("res://scenes/Furniture.tscn")

@onready var gm: GameManager = $GameManager
@onready var room: Node2D = $Room
@onready var minimap: Minimap = $UI/BottomBar/Minimap
@onready var budget_label: Label = $UI/TopBar/Label
@onready var tenant_card: TenantCard = $UI/BottomBar/TenantCard
@onready var inventory: Inventory = $UI/BottomBar/Inventory
@onready var rent_btn: Button = $UI/TopBar/RentButton
@onready var result_screen: ResultScreen = $ResultScreen
@onready var wall_inspector: WallInspector = $UI/WallInspector

const LEVEL_IDS: Array = [
	"level_01", "level_02", "level_03", "level_04", "level_05", "level_06"
]

var _floors: Dictionary = {}
var _current_floor_id: String = ""
var _current_level_id: String = ""


func _ready() -> void:
	gm.budget_changed.connect(_on_budget_changed)
	gm.functions_updated.connect(_on_functions_updated)
	minimap.wall_selected.connect(_switch_floor)
	inventory.buy_requested.connect(_on_buy_requested)
	rent_btn.pressed.connect(_on_rent_pressed)
	result_screen.next_level_requested.connect(_on_next_level)
	result_screen.retry_requested.connect(_on_retry)
	wall_inspector.visibility_changed.connect(_on_inspector_visibility_changed)
	_apply_ui_theme()
	_load_level(LEVEL_IDS[0])


func _apply_ui_theme() -> void:
	var t := GameTheme.make()
	minimap.theme      = t
	tenant_card.theme  = t
	inventory.theme    = t
	wall_inspector.theme = t

	# TopBar panel background (works if TopBar is a PanelContainer)
	if $UI/TopBar is PanelContainer:
		var ts := StyleBoxFlat.new()
		ts.bg_color = Color(0.09, 0.11, 0.15, 0.97)
		ts.border_color = Color(0.20, 0.26, 0.34)
		ts.set_border_width(SIDE_BOTTOM, 1)
		ts.set_content_margin_all(6)
		($UI/TopBar as PanelContainer).add_theme_stylebox_override("panel", ts)

	# Budget label — amber, readable size
	budget_label.add_theme_font_size_override("font_size", 15)
	budget_label.add_theme_color_override("font_color", GameTheme.C_AMBER)

	# Rent Out button — prominent amber action button
	var rs := GameTheme.make_rent_btn_style()
	rent_btn.add_theme_stylebox_override("normal",   rs[0])
	rent_btn.add_theme_stylebox_override("hover",    rs[1])
	rent_btn.add_theme_stylebox_override("pressed",  rs[1])
	rent_btn.add_theme_stylebox_override("disabled", rs[2])
	rent_btn.add_theme_color_override("font_color",          GameTheme.C_AMBER)
	rent_btn.add_theme_color_override("font_hover_color",    Color(1.0, 0.96, 0.72))
	rent_btn.add_theme_color_override("font_pressed_color",  Color(1.0, 0.96, 0.72))
	rent_btn.add_theme_color_override("font_disabled_color", GameTheme.C_MUTED)
	rent_btn.add_theme_font_size_override("font_size", 13)


func _load_level(level_id: String) -> void:
	_current_level_id = level_id
	gm.load_level(level_id)

	for fid in _floors:
		(_floors[fid] as Floor).queue_free()
	_floors.clear()

	var level: Dictionary = gm.current_level
	var floors_data: Array = level["apartment"]["floors"]

	for fd in floors_data:
		var apt_floor: Floor = load("res://scenes/Wall.tscn").instantiate() as Floor
		apt_floor.name = fd["id"]
		room.add_child(apt_floor)
		apt_floor.setup(fd)
		apt_floor.furniture_changed.connect(_on_furniture_changed)
		apt_floor.wall_edge_clicked.connect(_on_wall_edge_clicked.bind(apt_floor))
		apt_floor.visible = false
		_floors[fd["id"]] = apt_floor

		for sf in fd.get("starting_furniture", []):
			_spawn_furniture(sf["id"], apt_floor, sf["x"], sf["y"])

	minimap.setup(floors_data)
	tenant_card.setup(level["tenant"])
	inventory.setup(gm)
	inventory.populate(
		gm.furniture_data["furniture"].filter(func(f): return f.get("placement", "floor") == "floor")
	)
	budget_label.text = "Budget: %d€" % gm.budget
	wall_inspector.setup(gm.furniture_data["furniture"])

	_switch_floor(floors_data[0]["id"])
	_update_floor_locks()
	_refresh_functions()
	_update_accessibility()


func _spawn_furniture(furniture_id: String, apt_floor: Floor, gx: int, gy: int) -> Furniture:
	var fdata := gm.get_furniture_by_id(furniture_id)
	if fdata.is_empty():
		return null
	if fdata.get("placement", "floor") != "floor":
		return null
	var f: Furniture = FurnitureScene.instantiate() as Furniture
	apt_floor.add_child(f)
	f.setup(fdata, apt_floor)
	var at := Vector2i(gx, gy)
	if not apt_floor.can_place(f, at):
		at = apt_floor.find_free_spot(f.grid_w, f.grid_h)
	apt_floor.place_furniture(f, at)
	f.sell_requested.connect(_on_sell_pressed.bind(apt_floor))
	return f


func _switch_floor(floor_id: String) -> void:
	if _current_floor_id in _floors:
		(_floors[_current_floor_id] as Floor).visible = false
	_current_floor_id = floor_id
	if floor_id in _floors:
		(_floors[floor_id] as Floor).visible = true
	minimap.highlight(floor_id)


func _on_wall_edge_clicked(edge: String, apt_floor: Floor) -> void:
	for fid in _floors:
		var fl: Floor = _floors[fid] as Floor
		fl.set_active_wall_edge("" if fl != apt_floor else edge)
	wall_inspector.show_wall(apt_floor, edge)


func _on_inspector_visibility_changed() -> void:
	if not wall_inspector.visible:
		for fid in _floors:
			(_floors[fid] as Floor).set_active_wall_edge("")


func _on_buy_requested(furniture_id: String) -> void:
	if not gm.buy_furniture(furniture_id):
		return
	var apt_floor: Floor = _floors.get(_current_floor_id) as Floor
	if apt_floor:
		_spawn_furniture(furniture_id, apt_floor, 0, 0)
	_refresh_functions()


func _on_sell_pressed(furniture: Furniture, apt_floor: Floor) -> void:  # right-click on furniture
	gm.sell_furniture(furniture.furniture_id)
	apt_floor.remove_furniture(furniture)
	_refresh_functions()


func _on_furniture_changed() -> void:
	_refresh_functions()
	_update_floor_locks()
	_update_accessibility()


func _refresh_functions() -> void:
	var all_ids: Array = []
	for fid in _floors:
		var fl: Floor = _floors[fid] as Floor
		all_ids += fl.get_all_furniture_ids()
		all_ids += fl.get_all_wall_item_ids()
	gm.update_functions(all_ids)


func _on_budget_changed(new_budget: int) -> void:
	budget_label.text = "Budget: %d€" % new_budget


func _on_functions_updated(fulfilled: Array, required: Array) -> void:
	tenant_card.update_checks(fulfilled, required)
	rent_btn.disabled = not gm.check_win() or not _all_furniture_accessible()


func _update_accessibility() -> void:
	var blocked: Array = []
	for fid in _floors:
		blocked += (_floors[fid] as Floor).get_inaccessible_furniture()
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			(f as Furniture).set_accessible(f not in blocked)


func _all_furniture_accessible() -> bool:
	for fid in _floors:
		if (_floors[fid] as Floor).get_inaccessible_furniture().size() > 0:
			return false
	return true


func _on_rent_pressed() -> void:
	if not gm.check_win():
		result_screen.show_failure("Not all tenant requirements are met.\nTry again.")
		return
	if not _all_furniture_accessible():
		result_screen.show_failure("Some furniture is completely blocked.\nLeave at least 1 tile of walking space around it.")
		return
	gm.rent_apartment()
	result_screen.show_success(
		gm.monthly_rent,
		gm.current_level["tenant"]["name"],
		gm.current_level["tenant"]["monthly_rent"]
	)


func _on_next_level() -> void:
	if gm.is_retired():
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")
		return
	var idx := LEVEL_IDS.find(_current_level_id)
	if idx >= 0 and idx < LEVEL_IDS.size() - 1:
		_load_level(LEVEL_IDS[idx + 1])
	else:
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")


func _on_retry() -> void:
	_load_level(_current_level_id)


func _update_floor_locks() -> void:
	var floors_data: Array = gm.current_level["apartment"]["floors"]
	for fd in floors_data:
		var unlock_by: String = fd.get("unlocked_by", "") as String
		if unlock_by == "":
			continue
		var floor_id: String = fd["id"] as String
		var unlocked := _any_floor_has(unlock_by)
		minimap.set_floor_locked(floor_id, not unlocked)
		# If currently on a floor that just got locked, fall back to ground floor
		if not unlocked and _current_floor_id == floor_id:
			_switch_floor(floors_data[0]["id"] as String)


func _any_floor_has(furniture_id: String) -> bool:
	for fid in _floors:
		for placed_id in (_floors[fid] as Floor).get_all_furniture_ids():
			if placed_id == furniture_id:
				return true
	return false
