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
	item_list.add_theme_constant_override("separation", 5)


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
		btn.add_theme_font_size_override("font_size", 12)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Active tab fills amber like a proper tab selector, instead of relying
		# on the barely-visible default toggle border.
		var tp := StyleBoxFlat.new()
		tp.bg_color = Color(0.42, 0.36, 0.13)
		tp.border_color = GameTheme.C_AMBER
		tp.set_border_width_all(1)
		tp.set_corner_radius_all(9)
		tp.anti_aliasing = true
		tp.set_content_margin(SIDE_TOP, 6)
		tp.set_content_margin(SIDE_BOTTOM, 6)
		btn.add_theme_stylebox_override("pressed", tp)
		btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.95, 0.70))
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
	var tool_panel := VBoxContainer.new()
	tool_panel.add_theme_constant_override("separation", 4)

	var hdr_row := HBoxContainer.new()
	var hdr := Label.new()
	hdr.text = "TOOLS  (drag on the floor plan to build)"
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(hdr)
	tool_panel.add_child(hdr_row)

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
			btn.icon = IconGen.make(tid)
			btn.expand_icon = false
			btn.toggle_mode = true
			btn.button_group = group
			btn.button_pressed = (tid == _builder_tool)
			btn.set_meta("tool_id", tid)
			btn.add_theme_font_size_override("font_size", 11)
			btn.add_theme_constant_override("h_separation", 4)
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.pressed.connect(_set_builder_tool.bind(tid))
			row.add_child(btn)
			_builder_tool_buttons.append(btn)
		tool_panel.add_child(row)

	var sep := HSeparator.new()
	tool_panel.add_child(sep)
	return tool_panel


# Mini blueprint chip showing the item's actual footprint shape at its true
# aspect ratio — the shop reads as a parts catalog for the drawing, and the
# player learns each piece's relative size before buying.
class FootprintIcon extends Control:
	var _fw: int
	var _fh: int
	var _col: Color
	static var _chip_style: StyleBoxFlat = null

	func _init(fw: int, fh: int, col: Color, px: float = 28.0) -> void:
		_fw = maxi(fw, 1)
		_fh = maxi(fh, 1)
		_col = col
		custom_minimum_size = Vector2(px, px)
		if _chip_style == null:
			_chip_style = StyleBoxFlat.new()
			_chip_style.bg_color = GridDraw.BP_FLOOR
			_chip_style.set_corner_radius_all(6)
			_chip_style.anti_aliasing = true

	func _draw() -> void:
		_chip_style.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))
		var inner := Rect2(Vector2(4, 4), size - Vector2(8, 8))
		var s := minf(inner.size.x / _fw, inner.size.y / _fh)
		var rs := Vector2(_fw * s, _fh * s)
		var org := inner.position + (inner.size - rs) * 0.5
		draw_rect(Rect2(org, rs), Color(_col.r, _col.g, _col.b, 0.55))
		var step := 4.0
		var d := step
		while d < rs.x + rs.y:
			draw_line(org + Vector2(maxf(0.0, d - rs.y), minf(d, rs.y)),
				org + Vector2(minf(d, rs.x), maxf(0.0, d - rs.x)),
				Color(_col.r, _col.g, _col.b, 0.45), 1.0, true)
			d += step
		draw_rect(Rect2(org, rs), GridDraw.BP_INK, false, 1.2)


static func _make_item_icon(f: Dictionary, px: float) -> Control:
	var col := Color("#" + (f.get("color", "888888") as String))
	var sz := f.get("size", {}) as Dictionary
	return FootprintIcon.new(sz.get("w", 4) as int, sz.get("h", 4) as int, col, px)


func _build_shop_row(f: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	var item_col := Color("#" + (f.get("color", "888888") as String))
	var card_style := GameTheme.make_card_stylebox(Color(0.210, 0.185, 0.150), Color(0.320, 0.270, 0.205))
	card.add_theme_stylebox_override("panel", card_style)
	card.mouse_filter = Control.MOUSE_FILTER_PASS
	card.mouse_entered.connect(func():
		card_style.bg_color = Color(0.245, 0.215, 0.175)
		card_style.border_color = item_col.lightened(0.2))
	card.mouse_exited.connect(func():
		card_style.bg_color = Color(0.210, 0.185, 0.150)
		card_style.border_color = Color(0.320, 0.270, 0.205))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	card.add_child(row)

	# Mini blueprint footprint icon (true shape, color-coded)
	row.add_child(_make_item_icon(f, 28.0))

	var name_lbl := Label.new()
	name_lbl.text = f["name"]
	name_lbl.custom_minimum_size.x = 108
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	row.add_child(name_lbl)

	var func_lbl := Label.new()
	func_lbl.text = _fmt_funcs(f["functions"])
	func_lbl.custom_minimum_size.x = 100
	func_lbl.add_theme_font_size_override("font_size", 10)
	func_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	row.add_child(func_lbl)

	var price_lbl := Label.new()
	price_lbl.text = "%d€" % f["buy_price"]
	price_lbl.custom_minimum_size.x = 52
	price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price_lbl.add_theme_font_size_override("font_size", 12)
	price_lbl.add_theme_color_override("font_color", Color(0.62, 0.88, 0.64))
	var pp := StyleBoxFlat.new()
	pp.bg_color = Color(0.10, 0.22, 0.13)
	pp.border_color = Color(0.26, 0.48, 0.30)
	pp.set_border_width_all(1)
	pp.set_corner_radius_all(8)
	pp.anti_aliasing = true
	pp.set_content_margin(SIDE_LEFT, 7)
	pp.set_content_margin(SIDE_RIGHT, 7)
	pp.set_content_margin(SIDE_TOP, 2)
	pp.set_content_margin(SIDE_BOTTOM, 2)
	price_lbl.add_theme_stylebox_override("normal", pp)
	row.add_child(price_lbl)

	var view3d_btn := Button.new()
	view3d_btn.text = "3D"
	view3d_btn.tooltip_text = "Preview in 3D"
	view3d_btn.add_theme_font_size_override("font_size", 11)
	view3d_btn.custom_minimum_size.x = 32
	view3d_btn.pressed.connect(func(): view3d_requested.emit(f["id"] as String))
	row.add_child(view3d_btn)

	var buy_btn := Button.new()
	buy_btn.text = "Buy"
	buy_btn.add_theme_font_size_override("font_size", 11)
	buy_btn.set_meta("price", f["buy_price"] as int)
	buy_btn.disabled = _gm != null and _gm.budget < (f["buy_price"] as int)
	buy_btn.pressed.connect(_on_buy_pressed.bind(f["id"]))
	row.add_child(buy_btn)

	return card


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
			var card := PanelContainer.new()
			card.add_theme_stylebox_override("panel",
				GameTheme.make_card_stylebox(Color(0.210, 0.185, 0.150), Color(0.320, 0.270, 0.205)))

			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			card.add_child(row)

			row.add_child(_make_item_icon(fdata, 24.0))

			var name_lbl := Label.new()
			name_lbl.text = fdata["name"] as String
			name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_lbl.add_theme_font_size_override("font_size", 12)
			name_lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
			row.add_child(name_lbl)

			var sell_price := fdata.get("sell_price", fdata.get("buy_price", 0)) as int
			var sell_btn := Button.new()
			sell_btn.text = "Sell %d€" % sell_price
			sell_btn.add_theme_font_size_override("font_size", 10)
			sell_btn.add_theme_color_override("font_color", Color(0.76, 0.52, 0.28))
			sell_btn.pressed.connect(func():
				if _gm and _gm.sell_starting_item(fid):
					card.queue_free())
			row.add_child(sell_btn)

			var place_btn := Button.new()
			place_btn.text = "Place"
			place_btn.add_theme_font_size_override("font_size", 10)
			place_btn.pressed.connect(func():
				if _gm:
					_gm.consume_starting_item(fid)
				buy_requested.emit(fid)
				card.queue_free())
			row.add_child(place_btn)

			item_list.add_child(card)


func _fmt_funcs(funcs: Array) -> String:
	if funcs.is_empty():
		return "decor"
	return ", ".join(funcs)


func _refresh_affordability(new_budget: int) -> void:
	# Rows are PanelContainer cards wrapping an HBox, so search the whole
	# subtree — iterating only direct HBox children silently skipped every Buy
	# button, leaving them stuck in their level-load disabled state.
	for ctrl in item_list.find_children("*", "Button", true, false):
		if (ctrl as Button).has_meta("price"):
			(ctrl as Button).disabled = new_budget < (ctrl as Button).get_meta("price") as int


func _on_buy_pressed(furniture_id: String) -> void:
	Audio.play("click")
	buy_requested.emit(furniture_id)
