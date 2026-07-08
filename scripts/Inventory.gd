extends PanelContainer
class_name Inventory

signal buy_requested(furniture_id: String)
signal view3d_requested(furniture_id: String)
signal builder_tool_selected(tool_id: String)   # "" = no tool (back to select/place mode)

# "Builder" is anything that shapes the room itself rather than furnishing it
# (currently just staircases) — kept as a plain id-flag check so future
# additions (rails, wall pieces, etc., if they ever become buyable catalog
# items) only need to satisfy this one predicate to land in the right tab.
enum Category { FURNITURE, BUILDER }

var _gm: GameManager = null
var _category: int = Category.FURNITURE
var _full_list: Array = []
var _owned_list: Array = []
var _owned_catalog: Array = []

@onready var scroll:    ScrollContainer = $ScrollContainer
@onready var item_list: VBoxContainer   = $ScrollContainer/ItemList

var _filter_box: HBoxContainer = null
var _builder_tool_buttons: Array = []
var _builder_tool: String = ""


func setup(game_manager: GameManager) -> void:
	_gm = game_manager
	_gm.budget_changed.connect(_refresh_affordability)
	_ensure_filter_box()


func _ensure_filter_box() -> void:
	if is_instance_valid(_filter_box):
		return
	_filter_box = HBoxContainer.new()
	_filter_box.name = "CategoryFilter"
	_filter_box.add_theme_constant_override("separation", 4)
	var group := ButtonGroup.new()
	var specs := [
		[Category.FURNITURE, "Furniture"],
		[Category.BUILDER,   "Builder"],
	]
	for spec in specs:
		var cat: int = spec[0]
		var btn := Button.new()
		btn.text           = spec[1]
		btn.toggle_mode    = true
		btn.button_group   = group
		btn.button_pressed = (cat == _category)
		btn.add_theme_font_size_override("font_size", 11)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_set_category.bind(cat))
		_filter_box.add_child(btn)

	# PanelContainer only auto-fills a single child, so wrap the pre-existing
	# ScrollContainer alongside the new filter row in a VBoxContainer instead
	# of trying to lay both out directly as PanelContainer children.
	remove_child(scroll)
	var root := VBoxContainer.new()
	root.name = "Root"
	root.add_theme_constant_override("separation", 4)
	add_child(root)
	root.add_child(_filter_box)
	root.add_child(scroll)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL


func _set_category(cat: int) -> void:
	if _category == cat:
		return
	_category = cat
	if cat != Category.BUILDER and _builder_tool != "":
		_builder_tool = ""
		builder_tool_selected.emit("")
	_render()


func _set_builder_tool(tool_id: String) -> void:
	_builder_tool = tool_id
	# Don't rely solely on ButtonGroup's own exclusivity bookkeeping — it can
	# leave two buttons visually pressed at once when toggled rapidly. Force
	# every button across both tool rows to match _builder_tool explicitly.
	for btn in _builder_tool_buttons:
		if is_instance_valid(btn):
			(btn as Button).button_pressed = ((btn as Button).get_meta("tool_id", "") == tool_id)
	builder_tool_selected.emit(_builder_tool)


func _is_builder(f: Dictionary) -> bool:
	return f.get("is_stair", false) as bool


func populate(furniture_list: Array) -> void:
	_full_list = furniture_list
	_render()


func _render() -> void:
	for child in item_list.get_children():
		child.queue_free()

	if _category == Category.BUILDER:
		item_list.add_child(_build_builder_tool_row())

	var hdr := Label.new()
	hdr.text = ("ITEMS  (place on the floor plan, or open a wall to hang it there)"
		if _category == Category.FURNITURE
		else "STAIRCASES  (room-shaping pieces, bought and placed like furniture)")
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	item_list.add_child(hdr)

	var shown := _full_list.filter(func(f): return _is_builder(f) == (_category == Category.BUILDER))
	for f in shown:
		item_list.add_child(_build_shop_row(f))

	if not _owned_list.is_empty():
		_render_owned_section()


# Free-form building tools (walls, columns, erase, ...) — distinct from the
# buyable staircase items below them: these mutate room geometry directly
# rather than being placed Furniture pieces, so they're driven by a tool
# selector instead of a Buy button.
func _build_builder_tool_row() -> VBoxContainer:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 4)

	var hdr := Label.new()
	hdr.text = "TOOLS  (drag on the floor plan to build)"
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	wrap.add_child(hdr)

	var group := ButtonGroup.new()
	_builder_tool_buttons = []
	var rows := [
		[["", "Select"], ["wall", "Wall"], ["column", "Column"], ["erase", "Erase"]],
		[["balcony", "Balcony"], ["bathroom", "Bathroom"], ["window", "Window"], ["door", "Door"]],
		[["rail", "Rail"], ["reveal", "Reveal Zone"]],
		[["pipe_water", "Pipe: Water"], ["pipe_power", "Pipe: Power"]],
	]
	for row_specs: Array in rows:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		for spec in row_specs:
			var tid: String = spec[0]
			var btn := Button.new()
			btn.text = spec[1]
			btn.toggle_mode = true
			btn.button_group = group
			btn.button_pressed = (tid == _builder_tool)
			btn.set_meta("tool_id", tid)
			btn.add_theme_font_size_override("font_size", 11)
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.pressed.connect(_set_builder_tool.bind(tid))
			row.add_child(btn)
			_builder_tool_buttons.append(btn)
		wrap.add_child(row)

	var sep := HSeparator.new()
	wrap.add_child(sep)
	return wrap


func _build_shop_row(f: Dictionary) -> HBoxContainer:
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

	return row


# Shows pre-owned items (from starting_inventory). Each entry is {id, count}.
# The player can sell them for sell_price or place them for free.
func populate_owned(owned_list: Array, catalog: Array) -> void:
	_owned_list    = owned_list
	_owned_catalog = catalog
	_render_owned_section()


func _render_owned_section() -> void:
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	item_list.add_child(sep)

	var hdr := Label.new()
	hdr.text = "STARTING ITEMS"
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	item_list.add_child(hdr)

	for entry in _owned_list:
		var fid   := (entry as Dictionary)["id"] as String
		var count := (entry as Dictionary)["count"] as int
		var fdata := {}
		for f in _owned_catalog:
			if (f as Dictionary)["id"] == fid:
				fdata = f as Dictionary; break
		if fdata.is_empty() or _is_builder(fdata) != (_category == Category.BUILDER):
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
