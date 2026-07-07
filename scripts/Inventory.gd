extends PanelContainer
class_name Inventory

signal buy_requested(furniture_id: String)
signal view3d_requested(furniture_id: String)

var _gm: GameManager = null

@onready var item_list: VBoxContainer = $ScrollContainer/ItemList


func setup(game_manager: GameManager) -> void:
	_gm = game_manager
	_gm.budget_changed.connect(_refresh_affordability)


func populate(furniture_list: Array) -> void:
	for child in item_list.get_children():
		child.queue_free()

	var hdr := Label.new()
	hdr.text = "ITEMS  (place on the floor plan, or open a wall to hang it there)"
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	item_list.add_child(hdr)

	for f in furniture_list:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

		# Color swatch
		var swatch := ColorRect.new()
		swatch.color = Color("#" + (f.get("color", "888888") as String))
		swatch.custom_minimum_size = Vector2(8, 0)
		swatch.size_flags_vertical = Control.SIZE_EXPAND_FILL
		row.add_child(swatch)

		var name_lbl := Label.new()
		name_lbl.text = f["name"]
		name_lbl.custom_minimum_size.x = 108
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(name_lbl)

		var func_lbl := Label.new()
		func_lbl.text = _fmt_funcs(f["functions"])
		func_lbl.custom_minimum_size.x = 100
		func_lbl.add_theme_font_size_override("font_size", 10)
		func_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
		row.add_child(func_lbl)

		var price_lbl := Label.new()
		price_lbl.text = "%d€" % f["buy_price"]
		price_lbl.custom_minimum_size.x = 46
		price_lbl.add_theme_font_size_override("font_size", 11)
		price_lbl.add_theme_color_override("font_color", Color(0.50, 0.76, 0.52))
		row.add_child(price_lbl)

		var view3d_btn := Button.new()
		view3d_btn.text = "3D"
		view3d_btn.tooltip_text = "Preview in 3D"
		view3d_btn.add_theme_font_size_override("font_size", 11)
		view3d_btn.custom_minimum_size.x = 30
		view3d_btn.pressed.connect(func(): view3d_requested.emit(f["id"] as String))
		row.add_child(view3d_btn)

		var buy_btn := Button.new()
		buy_btn.text = "Buy"
		buy_btn.add_theme_font_size_override("font_size", 11)
		buy_btn.set_meta("price", f["buy_price"] as int)
		buy_btn.disabled = _gm != null and _gm.budget < (f["buy_price"] as int)
		buy_btn.pressed.connect(_on_buy_pressed.bind(f["id"]))
		row.add_child(buy_btn)

		item_list.add_child(row)


# Shows pre-owned items (from starting_inventory). Each entry is {id, count}.
# The player can sell them for sell_price or place them for free.
func populate_owned(owned_list: Array, catalog: Array) -> void:
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	item_list.add_child(sep)

	var hdr := Label.new()
	hdr.text = "STARTING ITEMS"
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	item_list.add_child(hdr)

	for entry in owned_list:
		var fid   := (entry as Dictionary)["id"] as String
		var count := (entry as Dictionary)["count"] as int
		var fdata := {}
		for f in catalog:
			if (f as Dictionary)["id"] == fid:
				fdata = f as Dictionary; break
		if fdata.is_empty():
			continue

		for _i in range(count):
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)

			var swatch := ColorRect.new()
			swatch.color = Color("#" + (fdata.get("color", "888888") as String))
			swatch.custom_minimum_size = Vector2(8, 0)
			swatch.size_flags_vertical = Control.SIZE_EXPAND_FILL
			row.add_child(swatch)

			var name_lbl := Label.new()
			name_lbl.text = fdata["name"] as String
			name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_lbl.add_theme_font_size_override("font_size", 11)
			row.add_child(name_lbl)

			var sell_price := fdata.get("sell_price", fdata.get("buy_price", 0)) as int
			var sell_btn := Button.new()
			sell_btn.text = "Sell %d€" % sell_price
			sell_btn.add_theme_font_size_override("font_size", 10)
			sell_btn.add_theme_color_override("font_color", Color(0.76, 0.52, 0.28))
			sell_btn.pressed.connect(func():
				if _gm and _gm.sell_starting_item(fid):
					row.queue_free())
			row.add_child(sell_btn)

			var place_btn := Button.new()
			place_btn.text = "Place"
			place_btn.add_theme_font_size_override("font_size", 10)
			place_btn.pressed.connect(func():
				if _gm:
					_gm.consume_starting_item(fid)
				buy_requested.emit(fid)
				row.queue_free())
			row.add_child(place_btn)

			item_list.add_child(row)


func _fmt_funcs(funcs: Array) -> String:
	if funcs.is_empty():
		return "decor"
	return ", ".join(funcs)


func _refresh_affordability(new_budget: int) -> void:
	for row in item_list.get_children():
		if not (row is HBoxContainer):
			continue
		for ctrl in (row as HBoxContainer).get_children():
			if ctrl is Button and (ctrl as Button).has_meta("price"):
				(ctrl as Button).disabled = new_budget < (ctrl as Button).get_meta("price") as int


func _on_buy_pressed(furniture_id: String) -> void:
	Audio.play("click")
	buy_requested.emit(furniture_id)
