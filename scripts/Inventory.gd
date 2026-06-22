extends PanelContainer
class_name Inventory

signal buy_requested(furniture_id: String)

var _gm: GameManager = null

@onready var item_list: VBoxContainer = $ScrollContainer/ItemList


func setup(game_manager: GameManager) -> void:
	_gm = game_manager


func populate(furniture_list: Array) -> void:
	for child in item_list.get_children():
		child.queue_free()

	var hdr := Label.new()
	hdr.text = "FLOOR ITEMS"
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

		var buy_btn := Button.new()
		buy_btn.text = "Buy"
		buy_btn.add_theme_font_size_override("font_size", 11)
		buy_btn.pressed.connect(_on_buy_pressed.bind(f["id"]))
		row.add_child(buy_btn)

		item_list.add_child(row)


func _fmt_funcs(funcs: Array) -> String:
	if funcs.is_empty():
		return "décor"
	return ", ".join(funcs)


func _on_buy_pressed(furniture_id: String) -> void:
	buy_requested.emit(furniture_id)
