extends Node

const FurnitureScene := preload("res://scenes/Furniture.tscn")

@onready var gm:           GameManager  = $GameManager
@onready var room:         Node2D       = $Room
@onready var minimap:      Minimap      = $UI/BottomBar/Minimap
@onready var budget_label: Label        = $UI/TopBar/Label
@onready var tenant_card:  TenantCard   = $UI/BottomBar/TenantCard
@onready var inventory:    Inventory    = $UI/BottomBar/Inventory
@onready var rent_btn:     Button       = $UI/TopBar/RentButton
@onready var result_screen: ResultScreen = $ResultScreen
@onready var wall_inspector: WallInspector = $UI/WallInspector

const TILE_SIZE := 8          # pixels per grid tile — matches Floor/GridDraw
const TOP_Y     := 46.0       # top bar height
const BOT_Y     := 506.0      # bottom bar start
const FIT_PCT   := 0.95       # fraction of available area to fill

var _floors:            Dictionary = {}
var _current_floor_id:  String = ""
var _current_level_id:  String = ""
var _demolition_mode:   bool = false
var _demo_overlay:      Control = null

var _paint_pieces:      Dictionary = {}  # floor_id -> {type_id: PaintedFurniture}
var _active_paint_type: String     = ""
var _painting:          bool       = false
var _last_paint_tile:   Vector2i   = Vector2i(-1, -1)
var _paint_panel:       Control    = null
var _paint_status_lbl:  Label      = null
var _floor_tile_bounds: Dictionary = {}  # floor_id -> Rect2i of painted tile content


func _ready() -> void:
	if not gm.budget_changed.is_connected(_on_budget_changed):
		gm.budget_changed.connect(_on_budget_changed)
	if not gm.functions_updated.is_connected(_on_functions_updated):
		gm.functions_updated.connect(_on_functions_updated)
	if not gm.moments_updated.is_connected(_on_moments_updated):
		gm.moments_updated.connect(_on_moments_updated)
	if not minimap.wall_selected.is_connected(_switch_floor):
		minimap.wall_selected.connect(_switch_floor)
	if not inventory.buy_requested.is_connected(_on_buy_requested):
		inventory.buy_requested.connect(_on_buy_requested)
	if not rent_btn.pressed.is_connected(_on_rent_pressed):
		rent_btn.pressed.connect(_on_rent_pressed)
	if not result_screen.next_level_requested.is_connected(_on_next_level):
		result_screen.next_level_requested.connect(_on_next_level)
	if not result_screen.retry_requested.is_connected(_on_retry):
		result_screen.retry_requested.connect(_on_retry)
	if not wall_inspector.wall_closed.is_connected(_on_inspector_visibility_changed):
		wall_inspector.wall_closed.connect(_on_inspector_visibility_changed)
	_apply_ui_theme()
	_load_level(GameState.pending_level_id)


func _apply_ui_theme() -> void:
	var t := GameTheme.make()
	minimap.theme       = t
	tenant_card.theme   = t
	inventory.theme     = t
	wall_inspector.theme = t

	if $UI/TopBar is PanelContainer:
		var ts := StyleBoxFlat.new()
		ts.bg_color     = Color(0.09, 0.11, 0.15, 0.97)
		ts.border_color = Color(0.20, 0.26, 0.34)
		ts.set_border_width(SIDE_BOTTOM, 1)
		ts.set_content_margin_all(6)
		($UI/TopBar as PanelContainer).add_theme_stylebox_override("panel", ts)

	budget_label.add_theme_font_size_override("font_size", 15)
	budget_label.add_theme_color_override("font_color", GameTheme.C_AMBER)

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

	# Back button — _go_back() checks GameState.testing_from_editor at press time
	var top := $UI/TopBar as HBoxContainer
	if not top.has_node("BackMapBtn"):
		var back_btn := Button.new()
		back_btn.name = "BackMapBtn"
		back_btn.text = "← City Map"
		back_btn.add_theme_font_size_override("font_size", 12)
		back_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
		back_btn.pressed.connect(_go_back)
		top.add_child(back_btn)
		top.move_child(back_btn, 0)
	var _bbtn := top.get_node("BackMapBtn") as Button
	_bbtn.text = "← Editor" if GameState.testing_from_editor else "← City Map"

	# Test mode button — only visible if level has foldable furniture
	if not top.has_node("TestBtn"):
		var test_btn := Button.new()
		test_btn.name        = "TestBtn"
		test_btn.text        = "Test Layout"
		test_btn.toggle_mode = true
		test_btn.add_theme_font_size_override("font_size", 11)
		test_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
		test_btn.toggled.connect(_on_test_toggled)
		top.add_child(test_btn)
		top.move_child(test_btn, top.get_child_count() - 2)
	if top.has_node("TestBtn"):
		top.get_node("TestBtn").visible = false  # updated after level load


func _go_back() -> void:
	if GameState.testing_from_editor:
		GameState.testing_from_editor = false
		GameState.resume_editor       = true
		get_tree().change_scene_to_file("res://scenes/LevelEditor.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/CityMap.tscn")


func _load_level(level_id: String) -> void:
	_current_level_id  = level_id
	gm.load_level(level_id)

	_active_paint_type = ""
	_painting          = false
	_paint_pieces      = {}
	if is_instance_valid(_paint_panel):
		_paint_panel.queue_free()
		_paint_panel = null
	_paint_status_lbl = null

	for fid in _floors:
		(_floors[fid] as Floor).queue_free()
	_floors.clear()

	var level: Dictionary = gm.current_level
	var apt_data: Dictionary = level["apartment"] as Dictionary
	var floors_data: Array = apt_data["floors"]
	var apt_gw: int = apt_data.get("grid_w", 40) as int
	var apt_gh: int = apt_data.get("grid_h", 30) as int

	for fd in floors_data:
		var apt_floor: Floor = load("res://scenes/Wall.tscn").instantiate() as Floor
		apt_floor.name = fd["id"]
		room.add_child(apt_floor)
		# grid_w/h live at apartment level now — inject before setup
		(fd as Dictionary)["grid_w"] = apt_gw
		(fd as Dictionary)["grid_h"] = apt_gh
		apt_floor.setup(fd)
		apt_floor.furniture_changed.connect(_on_furniture_changed)
		apt_floor.wall_edge_clicked.connect(_on_wall_edge_clicked.bind(apt_floor))
		apt_floor.visible = false
		_floors[fd["id"]] = apt_floor

		for sf in fd.get("starting_furniture", []):
			_spawn_furniture(sf["id"], apt_floor, sf["x"], sf["y"])

	# Top-level starting_furniture (from level editor) → place on first floor
	var first_floor_node: Floor = null
	if not _floors.is_empty():
		first_floor_node = _floors[floors_data[0]["id"]] as Floor
	if first_floor_node and not gm.starting_furniture.is_empty():
		for sf in gm.starting_furniture:
			_spawn_furniture((sf as Dictionary)["id"] as String,
				first_floor_node,
				(sf as Dictionary)["x"] as int,
				(sf as Dictionary)["y"] as int)

	# Compute bounding box of painted tiles per floor for focused camera fit
	_floor_tile_bounds.clear()
	for _bfd in floors_data:
		var _bfd_d := _bfd as Dictionary
		var _bfid  := _bfd_d["id"] as String
		var _btype := _bfd_d.get("type", "floor") as String
		var _btiles: Array = []
		match _btype:
			"loft":
				var _bpid := _bfd_d.get("parent_id", "") as String
				for _bpfd in floors_data:
					if (_bpfd as Dictionary)["id"] == _bpid:
						_btiles = (_bpfd as Dictionary).get("mezzanine_tiles", []) as Array; break
			"floor_sub", "ceiling":
				var _bpid := _bfd_d.get("parent_id", "") as String
				for _bpfd in floors_data:
					if (_bpfd as Dictionary)["id"] == _bpid:
						_btiles = (_bpfd as Dictionary).get("floor_tiles", []) as Array; break
			_:
				_btiles = _bfd_d.get("floor_tiles", []) as Array
		if _btiles.is_empty():
			continue
		var _bx0 := 999999; var _by0 := 999999
		var _bx1 := -999999; var _by1 := -999999
		for _bt in _btiles:
			var _btx := (_bt as Array)[0] as int; var _bty := (_bt as Array)[1] as int
			_bx0 = min(_bx0, _btx); _by0 = min(_by0, _bty)
			_bx1 = max(_bx1, _btx); _by1 = max(_by1, _bty)
		_floor_tile_bounds[_bfid] = Rect2i(_bx0, _by0, _bx1 - _bx0 + 1, _by1 - _by0 + 1)

	var hidden_floors: Array = level["apartment"].get("hidden_floors", []) as Array
	minimap.setup(floors_data, hidden_floors)
	tenant_card.setup(level["tenant"])
	tenant_card.setup_moments(gm.moments)
	inventory.setup(gm)
	var shop_list: Array = gm.furniture_data["furniture"].filter(
		func(f): return f.get("placement", "floor") == "floor")
	if not gm.allowed_furniture.is_empty():
		shop_list = shop_list.filter(func(f): return (f["id"] as String) in gm.allowed_furniture)
	inventory.populate(shop_list)
	if not gm.starting_inventory.is_empty():
		inventory.populate_owned(gm.starting_inventory, gm.furniture_data["furniture"])
	budget_label.text = "Budget: %d€" % gm.budget
	wall_inspector.setup(gm.furniture_data["furniture"])

	# Start on the first visible floor (skip hidden ones)
	var first_visible_id := floors_data[0]["id"] as String
	for _fd in floors_data:
		if not ((_fd as Dictionary)["id"] as String in hidden_floors):
			first_visible_id = (_fd as Dictionary)["id"] as String; break
	_switch_floor(first_visible_id)
	_update_floor_locks()
	_refresh_functions()
	_update_accessibility()

	# Auto-enable overlay for subfloor / ceiling floor types (no toggle buttons needed)
	for _afd in floors_data:
		var _aftype := (_afd as Dictionary).get("type", "") as String
		var _afid   := (_afd as Dictionary)["id"] as String
		if not _floors.has(_afid): continue
		var _agd := (_floors[_afid] as Floor).get_node_or_null("GridDraw") as GridDraw
		if _agd:
			if _aftype == "floor_sub": _agd.show_subfloor = true
			elif _aftype == "ceiling": _agd.show_ceiling  = true

	# Update test button visibility now that floors are loaded
	var top_bar := $UI/TopBar as HBoxContainer
	if top_bar.has_node("TestBtn"):
		top_bar.get_node("TestBtn").visible = _has_foldable_furniture()

	var paintable := gm.current_level.get("paintable_furniture", []) as Array
	if not paintable.is_empty():
		_build_paint_panel(paintable)

	if _level_has_demolishable_partitions():
		_enter_demolition_phase()

	_show_mechanic_intro_if_needed()


func _show_mechanic_intro_if_needed() -> void:
	var intro: Dictionary = gm.current_level.get("mechanic_intro", {}) as Dictionary
	if intro.is_empty():
		return
	var lid := gm.current_level.get("id", "") as String
	if lid in GameState.completed:
		return  # already played this level — skip intro

	# Build fullscreen CanvasLayer overlay
	var cl := CanvasLayer.new()
	cl.layer = 20
	add_child(cl)

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.05, 0.09, 0.88)
	bg.size  = Vector2(1280, 720)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	cl.add_child(bg)

	# Card panel (480×300, centred)
	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color     = Color(0.09, 0.12, 0.17)
	cs.border_color = Color(0.30, 0.80, 0.60, 0.80)
	cs.set_border_width_all(2)
	cs.set_corner_radius_all(6)
	cs.set_content_margin_all(28)
	card.add_theme_stylebox_override("panel", cs)
	card.position           = Vector2(400, 210)
	card.custom_minimum_size = Vector2(480, 300)
	cl.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	card.add_child(vb)

	# "NEW MECHANIC" chip
	var chip := Label.new()
	chip.text = "  NEW MECHANIC  "
	chip.add_theme_font_size_override("font_size", 9)
	chip.add_theme_color_override("font_color", Color(0.10, 0.10, 0.14))
	var chip_s := StyleBoxFlat.new()
	chip_s.bg_color = Color(0.30, 0.80, 0.60)
	chip_s.set_corner_radius_all(3)
	chip.add_theme_stylebox_override("normal", chip_s)
	vb.add_child(chip)

	# Title
	var title_lbl := Label.new()
	title_lbl.text = intro.get("title", "") as String
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER)
	title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(title_lbl)

	# Body
	var body_lbl := Label.new()
	body_lbl.text = intro.get("body", "") as String
	body_lbl.add_theme_font_size_override("font_size", 13)
	body_lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(body_lbl)

	# Dismiss button
	var btn := Button.new()
	btn.text = "Got it — let's go!"
	btn.add_theme_font_size_override("font_size", 13)
	var rs := GameTheme.make_rent_btn_style()
	btn.add_theme_stylebox_override("normal",  rs[0])
	btn.add_theme_stylebox_override("hover",   rs[1])
	btn.add_theme_stylebox_override("pressed", rs[1])
	btn.add_theme_color_override("font_color", GameTheme.C_AMBER)
	btn.pressed.connect(func(): cl.queue_free())
	vb.add_child(btn)

	# Also dismiss on click outside card
	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			cl.queue_free())


func _spawn_furniture(furniture_id: String, apt_floor: Floor, gx: int, gy: int) -> Furniture:
	var fdata := gm.get_furniture_by_id(furniture_id)
	if fdata.is_empty() or fdata.get("placement", "floor") != "floor":
		return null
	var f: Furniture = FurnitureScene.instantiate() as Furniture
	apt_floor.add_child(f)
	f.setup(fdata, apt_floor)
	var at := Vector2i(gx, gy)
	if not apt_floor.can_place(f, at):
		at = apt_floor.find_free_spot(f.grid_w, f.grid_h)
	apt_floor.place_furniture(f, at)
	f.sell_requested.connect(_on_sell_pressed.bind(apt_floor))
	f.fold_toggled.connect(_refresh_functions)
	return f


func _switch_floor(floor_id: String) -> void:
	if _current_floor_id in _floors:
		(_floors[_current_floor_id] as Floor).visible = false
	_current_floor_id = floor_id
	if floor_id in _floors:
		var apt_floor := _floors[floor_id] as Floor
		apt_floor.visible = true
		_fit_floor(apt_floor)
	minimap.highlight(floor_id)


func _fit_floor(apt_floor: Floor) -> void:
	const H_PAD  := 32.0
	const V_PAD  := 24.0
	const LEFT_W := 860.0
	const PAD_T  := 3     # tile padding around apartment content

	var avail_w := LEFT_W - H_PAD * 2
	var avail_h := (BOT_Y - TOP_Y) - V_PAD * 2

	var fw: float; var fh: float
	var off_x := 0.0;   var off_y := 0.0

	var fid := apt_floor.name as String
	if _floor_tile_bounds.has(fid):
		var bounds := _floor_tile_bounds[fid] as Rect2i
		fw    = float((bounds.size.x + PAD_T * 2) * TILE_SIZE)
		fh    = float((bounds.size.y + PAD_T * 2) * TILE_SIZE)
		off_x = float((bounds.position.x - PAD_T) * TILE_SIZE)
		off_y = float((bounds.position.y - PAD_T) * TILE_SIZE)
	else:
		fw = apt_floor.grid_w * float(TILE_SIZE)
		fh = apt_floor.grid_h * float(TILE_SIZE)

	var s := minf(avail_w * FIT_PCT / fw, avail_h * FIT_PCT / fh)
	s = minf(s, 5.0)  # prevent over-zoom on tiny apartments

	room.scale    = Vector2(s, s)
	room.position = Vector2(
		H_PAD + (avail_w - fw * s) * 0.5 - off_x * s,
		TOP_Y + V_PAD + (avail_h - fh * s) * 0.5 - off_y * s
	)


func _on_wall_edge_clicked(edge: String, apt_floor: Floor) -> void:
	for fid in _floors:
		var fl := _floors[fid] as Floor
		fl.set_active_wall_edge("" if fl != apt_floor else edge)
	wall_inspector.show_wall(apt_floor, edge)


func _on_inspector_visibility_changed() -> void:
	if not wall_inspector.visible:
		for fid in _floors:
			(_floors[fid] as Floor).set_active_wall_edge("")


func _on_buy_requested(furniture_id: String) -> void:
	if not gm.buy_furniture(furniture_id):
		return
	var apt_floor := _floors.get(_current_floor_id) as Floor
	if apt_floor:
		_spawn_furniture(furniture_id, apt_floor, 0, 0)
	_refresh_functions()


func _on_sell_pressed(furniture: Furniture, apt_floor: Floor) -> void:
	Audio.play("sell")
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
		var fl := _floors[fid] as Floor
		all_ids += fl.get_all_furniture_ids()
		all_ids += fl.get_all_wall_item_ids()
	var extra_fns: Array = []
	for floor_id in _paint_pieces:
		for type_id in _paint_pieces[floor_id]:
			var piece := _paint_pieces[floor_id][type_id] as PaintedFurniture
			if is_instance_valid(piece) and piece.is_valid():
				for fn in piece.functions:
					if fn not in extra_fns:
						extra_fns.append(fn)
	gm.update_functions(all_ids, extra_fns)


func _on_budget_changed(new_budget: int) -> void:
	budget_label.text = "Budget: %d€" % new_budget


func _on_functions_updated(fulfilled: Array, required: Array) -> void:
	tenant_card.update_checks(fulfilled, required)
	rent_btn.disabled = not gm.check_win() or not _all_furniture_accessible()


func _on_moments_updated(results: Dictionary) -> void:
	tenant_card.update_moments(results)
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
		Audio.play("error")
		result_screen.show_failure("Not all tenant requirements are met.\nTry again.")
		return
	if not _all_furniture_accessible():
		Audio.play("error")
		result_screen.show_failure("Some furniture is completely blocked.\nLeave at least 1 tile of walking space around it.")
		return

	Audio.play("success")

	var stars       := gm.calculate_stars()
	var funds       := gm.get_funds_reward()
	var level_rent  := gm.current_level["tenant"]["monthly_rent"] as int

	GameState.complete_level(_current_level_id, stars, funds, level_rent)

	result_screen.show_success(
		stars,
		funds,
		GameState.portfolio_rent,
		gm.current_level["tenant"]["name"],
		level_rent
	)




func _on_test_toggled(pressed: bool) -> void:
	Furniture.test_mode_active = pressed
	for fid in _floors:
		var fl := _floors[fid] as Floor
		for f in fl.get_all_furniture():
			var fur := f as Furniture
			if fur.foldable:
				# Fold all pieces back when exiting test mode
				if not pressed and fur.is_extended:
					fur.toggle_fold()
				fur.set_extended_conflict(fl.check_extended_conflict(fur))
			fur.queue_redraw()
	if not pressed:
		_refresh_functions()


func _has_foldable_furniture() -> bool:
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			if (f as Furniture).foldable:
				return true
	return false


func _level_has_demolishable_partitions() -> bool:
	for fid in _floors:
		var fl := _floors[fid] as Floor
		for p in fl.partitions:
			if not p.get("load_bearing", false):
				return true
	return false


func _enter_demolition_phase() -> void:
	_demolition_mode = true
	inventory.visible = false
	rent_btn.visible  = false
	if is_instance_valid(_paint_panel):
		_paint_panel.visible = false

	_demo_overlay = Control.new()
	_demo_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_demo_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$UI.add_child(_demo_overlay)

	# Dark side-panel info card
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color     = Color(0.09, 0.11, 0.15, 0.95)
	sb.border_color = Color(0.78, 0.40, 0.16, 0.80)
	sb.set_border_width_all(2)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	panel.offset_left = 868
	panel.offset_right = -4
	panel.offset_top = 60
	panel.offset_bottom = -4
	_demo_overlay.add_child(panel)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Demolition Phase"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.78, 0.40, 0.16))
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "Click dashed partitions\nto demolish them.\nLoad-bearing walls (hatched)\ncannot be removed."
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.75, 0.72, 0.65))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(hint)

	var budget_lbl := Label.new()
	budget_lbl.name = "DemoBudget"
	budget_lbl.add_theme_font_size_override("font_size", 11)
	budget_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER)
	vbox.add_child(budget_lbl)
	_update_demo_budget_label()

	var done_btn := Button.new()
	done_btn.text = "Start Furnishing →"
	done_btn.add_theme_font_size_override("font_size", 13)
	done_btn.pressed.connect(_exit_demolition_phase)
	vbox.add_child(done_btn)


func _update_demo_budget_label() -> void:
	if not _demo_overlay:
		return
	var lbl := _demo_overlay.find_child("DemoBudget", true, false) as Label
	if lbl:
		lbl.text = "Budget: %d€" % gm.budget


func _exit_demolition_phase() -> void:
	_demolition_mode = false
	if _demo_overlay:
		_demo_overlay.queue_free()
		_demo_overlay = null
	inventory.visible = true
	rent_btn.visible  = true
	if is_instance_valid(_paint_panel):
		_paint_panel.visible = true


func _input(event: InputEvent) -> void:
	if _active_paint_type != "":
		_handle_paint_input(event)
		return
	if not _demolition_mode:
		return
	if not (event is InputEventMouseButton and (event as InputEventMouseButton).pressed
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT):
		return
	var fl := _floors.get(_current_floor_id) as Floor
	if not fl:
		return
	var local := fl.to_local(get_viewport().get_mouse_position())
	var tx := int(local.x / Floor.TILE_SIZE)
	var ty := int(local.y / Floor.TILE_SIZE)

	for i in range(fl.partitions.size()):
		var p: Dictionary = fl.partitions[i]
		if p.get("load_bearing", false) or p.get("demolished", false):
			continue
		var x1: int = p["x1"]; var y1: int = p["y1"]
		var x2: int = p["x2"]; var y2: int = p["y2"]
		var hit := false
		if x1 == x2:
			hit = (tx == x1 and ty >= mini(y1, y2) and ty <= maxi(y1, y2))
		else:
			hit = (ty == y1 and tx >= mini(x1, x2) and tx <= maxi(x1, x2))
		if hit:
			var cost: int = p.get("demolish_cost", 500)
			if gm.budget < cost:
				Audio.play("error")
				return
			fl.demolish_partition(i)
			gm.spend(cost)
			_update_demo_budget_label()
			Audio.play("demolish")
			get_viewport().set_input_as_handled()
			return


func _on_next_level() -> void:
	get_tree().change_scene_to_file("res://scenes/CityMap.tscn")


func _on_retry() -> void:
	_load_level(_current_level_id)


func _update_floor_locks() -> void:
	var floors_data: Array = gm.current_level["apartment"]["floors"]
	for fd in floors_data:
		var unlock_by := fd.get("unlocked_by", "") as String
		if unlock_by.is_empty():
			continue
		var floor_id  := fd["id"] as String
		var unlocked  := _any_floor_has(unlock_by)
		minimap.set_floor_locked(floor_id, not unlocked)
		if not unlocked and _current_floor_id == floor_id:
			_switch_floor((floors_data[0] as Dictionary)["id"] as String)


func _any_floor_has(furniture_id: String) -> bool:
	for fid in _floors:
		for pid in (_floors[fid] as Floor).get_all_furniture_ids():
			if pid == furniture_id:
				return true
	return false


# ─── Paint mode ───────────────────────────────────────────────────────────────

func _build_paint_panel(types: Array) -> void:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color     = Color(0.09, 0.11, 0.15, 0.97)
	sb.border_color = Color(0.20, 0.26, 0.34)
	sb.set_border_width(SIDE_BOTTOM, 1)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchor(SIDE_LEFT,   0.0)
	panel.set_anchor(SIDE_TOP,    0.0)
	panel.set_anchor(SIDE_RIGHT,  1.0)
	panel.set_anchor(SIDE_BOTTOM, 0.0)
	panel.offset_left   = 868
	panel.offset_right  = -4
	panel.offset_top    = TOP_Y + 6
	panel.offset_bottom = TOP_Y + 92
	$UI.add_child(panel)
	_paint_panel = panel

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vb.add_child(header)

	var chip := Label.new()
	chip.text = "  CUSTOM BUILD  "
	chip.add_theme_font_size_override("font_size", 9)
	chip.add_theme_color_override("font_color", Color(0.08, 0.08, 0.12))
	var cs := StyleBoxFlat.new()
	cs.bg_color = Color(0.36, 0.50, 0.66)
	cs.set_corner_radius_all(3)
	cs.set_content_margin(SIDE_LEFT, 4);  cs.set_content_margin(SIDE_RIGHT, 4)
	cs.set_content_margin(SIDE_TOP, 2);   cs.set_content_margin(SIDE_BOTTOM, 2)
	chip.add_theme_stylebox_override("normal", cs)
	header.add_child(chip)

	var hint := Label.new()
	hint.text = "LMB paint · RMB erase"
	hint.add_theme_font_size_override("font_size", 9)
	hint.add_theme_color_override("font_color", Color(0.45, 0.48, 0.52))
	header.add_child(hint)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	vb.add_child(btn_row)

	var bg_group := ButtonGroup.new()

	var move_btn := Button.new()
	move_btn.text           = "Move"
	move_btn.toggle_mode    = true
	move_btn.button_group   = bg_group
	move_btn.button_pressed = true
	move_btn.add_theme_font_size_override("font_size", 11)
	move_btn.add_theme_color_override("font_color", Color(0.55, 0.55, 0.60))
	move_btn.toggled.connect(func(on: bool):
		if on: _set_paint_tool(""))
	btn_row.add_child(move_btn)

	var paintable_data := gm.furniture_data.get("paintable", []) as Array
	for type_id: String in types:
		var cfg := Dictionary()
		for pd in paintable_data:
			if (pd as Dictionary).get("id", "") == type_id:
				cfg = pd as Dictionary
				break
		if cfg.is_empty():
			continue
		var ca  := cfg.get("color", [0.5, 0.5, 0.5]) as Array
		var col := Color(ca[0] as float, ca[1] as float, ca[2] as float)
		var lbl := cfg.get("label", type_id) as String
		var cpt := cfg.get("cost_per_tile", 30) as int
		var btn := Button.new()
		btn.text         = "%s  %d€/tile" % [lbl, cpt]
		btn.toggle_mode  = true
		btn.button_group = bg_group
		btn.add_theme_font_size_override("font_size", 11)
		btn.add_theme_color_override("font_color", col)
		var tid := type_id
		btn.toggled.connect(func(on: bool):
			if on: _set_paint_tool(tid))
		btn_row.add_child(btn)

	_paint_status_lbl = Label.new()
	_paint_status_lbl.text = ""
	_paint_status_lbl.add_theme_font_size_override("font_size", 9)
	_paint_status_lbl.add_theme_color_override("font_color", Color(0.45, 0.48, 0.52))
	vb.add_child(_paint_status_lbl)


func _set_paint_tool(type_id: String) -> void:
	_active_paint_type = type_id
	_painting          = false
	_last_paint_tile   = Vector2i(-1, -1)
	_update_paint_status()


func _handle_paint_input(event: InputEvent) -> void:
	if not event is InputEventMouse:
		return
	var mp := (event as InputEventMouse).position
	if mp.x > 860.0 or mp.y < TOP_Y or mp.y > BOT_Y:
		return

	get_viewport().set_input_as_handled()

	var fl := _floors.get(_current_floor_id) as Floor
	if not fl:
		return
	var local := fl.to_local(mp)
	var tx    := int(local.x / float(TILE_SIZE))
	var ty    := int(local.y / float(TILE_SIZE))

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_painting = true
				if tx >= 0 and tx < fl.grid_w and ty >= 0 and ty < fl.grid_h:
					_apply_paint(Vector2i(tx, ty), true)
			else:
				_painting          = false
				_last_paint_tile   = Vector2i(-1, -1)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if tx >= 0 and tx < fl.grid_w and ty >= 0 and ty < fl.grid_h:
				_apply_paint(Vector2i(tx, ty), false)
	elif event is InputEventMouseMotion and _painting:
		if tx >= 0 and tx < fl.grid_w and ty >= 0 and ty < fl.grid_h:
			var tile := Vector2i(tx, ty)
			if tile != _last_paint_tile:
				_apply_paint(tile, true)


func _apply_paint(tile: Vector2i, on: bool) -> void:
	var fl := _floors.get(_current_floor_id) as Floor
	if not fl:
		return
	if on and _tile_has_column(fl, tile.x, tile.y):
		return
	var piece := _get_or_create_paint_piece(_active_paint_type, fl)
	if piece.has_tile(tile) == on:
		_last_paint_tile = tile
		return
	if on:
		if gm.budget < piece.cost_per_tile:
			Audio.play("error")
			return
		piece.set_tile(tile, true)
		gm.budget -= piece.cost_per_tile
		gm.budget_changed.emit(gm.budget)
	else:
		piece.set_tile(tile, false)
		gm.budget += piece.cost_per_tile
		gm.budget_changed.emit(gm.budget)
	_last_paint_tile = tile
	_refresh_functions()
	_update_paint_status()


func _get_or_create_paint_piece(type_id: String, fl: Floor) -> PaintedFurniture:
	var floor_id := _current_floor_id
	if floor_id not in _paint_pieces:
		_paint_pieces[floor_id] = {}
	if type_id not in _paint_pieces[floor_id]:
		var piece := PaintedFurniture.new()
		var paintable_data := gm.furniture_data.get("paintable", []) as Array
		for pd in paintable_data:
			var cfg := pd as Dictionary
			if cfg.get("id", "") == type_id:
				piece.type_id        = type_id
				piece.display_label  = cfg.get("label",          type_id) as String
				piece.functions      = cfg.get("functions",      []).duplicate() as Array
				piece.cost_per_tile  = cfg.get("cost_per_tile",  30)  as int
				piece.min_tiles      = cfg.get("min_tiles",      16)  as int
				piece.max_aspect     = cfg.get("max_aspect",     3.5) as float
				piece.min_short_side = cfg.get("min_short_side", 4)   as int
				var ca := cfg.get("color", [0.5, 0.5, 0.5]) as Array
				piece.tile_color     = Color(ca[0] as float, ca[1] as float, ca[2] as float)
				break
		fl.add_child(piece)
		_paint_pieces[floor_id][type_id] = piece
	return _paint_pieces[floor_id][type_id] as PaintedFurniture


func _tile_has_column(fl: Floor, tx: int, ty: int) -> bool:
	for c in fl.columns:
		var cd := c as Dictionary
		if cd.get("x", -1) == tx and cd.get("y", -1) == ty:
			return true
	return false


func _update_paint_status() -> void:
	if not is_instance_valid(_paint_status_lbl):
		return
	if _active_paint_type.is_empty():
		_paint_status_lbl.text = ""
		return
	var floor_id := _current_floor_id
	if floor_id not in _paint_pieces or _active_paint_type not in _paint_pieces[floor_id]:
		_paint_status_lbl.text = "Paint tiles on the floor"
		return
	var piece := _paint_pieces[floor_id][_active_paint_type] as PaintedFurniture
	if not is_instance_valid(piece):
		return
	_paint_status_lbl.text = piece.validation_message()
	var valid := piece.is_valid()
	_paint_status_lbl.add_theme_color_override("font_color",
		Color(0.38, 0.72, 0.48) if valid else Color(0.65, 0.38, 0.30))
