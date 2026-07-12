extends PanelContainer
class_name Inventory

signal buy_requested(furniture_id: String)
signal builder_tool_selected(tool_id: String)   # "" = no tool (back to select/place mode)

const Room3DViewScene := preload("res://scenes/Room3DView.tscn")

# "Builder" is anything that shapes the room itself rather than furnishing it
# (currently just staircases) — kept as a plain id-flag check so future
# additions (rails, wall pieces, etc., if they ever become buyable catalog
# items) only need to satisfy this one predicate to land in the right tab.
enum Category { FURNITURE, BUILDER }

# Sub-categories within the Furniture tab — icon-grid browsing instead of one
# long scrolling list, most valuable once the catalog is 40-60+ pieces.
const SUB_CATEGORIES := ["All", "Bedroom", "Bathroom", "Kitchen", "Living", "Storage", "Transformable"]

# Icon-only filter tabs — same glyph language as TenantCard's need chips, so
# the sub-category row reads as a compact row of pictograms instead of a wall
# of overlapping text buttons that had to wrap across three lines.
const SUB_CATEGORY_GLYPH := {
	"All":           "▦",
	"Bedroom":       "🛏",
	"Bathroom":      "🚿",
	"Kitchen":       "🍳",
	"Living":        "🛋",
	"Storage":       "📦",
	"Transformable": "🔀",
}

var _gm: GameManager = null
var _category: int = Category.FURNITURE
var _sub_category: String = "All"
var _full_list: Array = []
var _owned_list: Array = []
var _owned_catalog: Array = []

@onready var scroll:    ScrollContainer = $ScrollContainer
@onready var item_list: VBoxContainer   = $ScrollContainer/ItemList

var _filter_box: HBoxContainer = null
var _sub_filter_box: Container = null
var _sub_filter_separator: HSeparator = null
var _sub_filter_buttons: Dictionary = {}   # category name -> Button
var _builder_tool_buttons: Array = []
var _builder_tool: String = ""
var _tooltip: PanelContainer = null
var _tooltip_preview_holder: Control = null
var _tooltip_preview: Node = null
var _tooltip_fdata_id: String = ""   # which item the currently-open tooltip belongs to


func setup(game_manager: GameManager) -> void:
	_gm = game_manager
	if not _gm.budget_changed.is_connected(_refresh_affordability):
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
		[Category.FURNITURE, "🛋", "Furniture"],
		[Category.BUILDER,   "🛠", "Builder"],
	]
	for spec in specs:
		var cat: int = spec[0]
		var btn := Button.new()
		btn.text           = spec[1]
		btn.tooltip_text   = spec[2]
		btn.toggle_mode    = true
		btn.button_group   = group
		btn.button_pressed = (cat == _category)
		btn.add_theme_font_size_override("font_size", 16)
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

	# Fixed 2-column grid — same column count as the item cell grid below, so
	# the icon rows line up with the furniture grid instead of a flowing wrap
	# that broke onto 3-per-row and looked wider than the items underneath.
	var sub_grid := GridContainer.new()
	sub_grid.name = "SubCategoryFilter"
	sub_grid.columns = 2
	sub_grid.add_theme_constant_override("h_separation", 6)
	sub_grid.add_theme_constant_override("v_separation", 6)
	_sub_filter_box = sub_grid
	var sub_group := ButtonGroup.new()
	for sub in SUB_CATEGORIES:
		var sb := Button.new()
		sb.text = SUB_CATEGORY_GLYPH.get(sub, "?") as String
		sb.tooltip_text = sub
		sb.toggle_mode = true
		sb.button_group = sub_group
		sb.button_pressed = (sub == _sub_category)
		sb.custom_minimum_size = Vector2(0, 28)
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.add_theme_font_size_override("font_size", 14)
		var sp := StyleBoxFlat.new()
		sp.bg_color = Color(0.30, 0.26, 0.16)
		sp.border_color = GameTheme.C_AMBER
		sp.set_border_width_all(1)
		sp.set_corner_radius_all(6)
		sp.anti_aliasing = true
		sb.add_theme_stylebox_override("pressed", sp)
		sb.add_theme_color_override("font_pressed_color", GameTheme.C_AMBER)
		sb.pressed.connect(_set_sub_category.bind(sub))
		_sub_filter_box.add_child(sb)
		_sub_filter_buttons[sub] = sb

	# PanelContainer only auto-fills a single child, so wrap the pre-existing
	# ScrollContainer alongside the new filter rows in a VBoxContainer instead
	# of trying to lay both out directly as PanelContainer children.
	remove_child(scroll)
	var root := VBoxContainer.new()
	root.name = "Root"
	root.add_theme_constant_override("separation", 4)
	add_child(root)
	root.add_child(_filter_box)

	# A hairline break between the main Furniture/Builder tabs and the
	# sub-category icon grid — otherwise the two icon rows read as one
	# undifferentiated block.
	_sub_filter_separator = HSeparator.new()
	_sub_filter_separator.add_theme_constant_override("separation", 2)
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color(1, 1, 1, 0.12)
	sep_style.content_margin_top = 1
	sep_style.content_margin_bottom = 1
	_sub_filter_separator.add_theme_stylebox_override("separator", sep_style)
	root.add_child(_sub_filter_separator)
	root.add_child(_sub_filter_box)
	root.add_child(scroll)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL


func _set_category(cat: int) -> void:
	if _category == cat:
		return
	_category = cat
	if cat != Category.BUILDER and _builder_tool != "":
		_builder_tool = ""
		builder_tool_selected.emit("")
	_sub_filter_box.visible = (cat == Category.FURNITURE)
	_sub_filter_separator.visible = (cat == Category.FURNITURE)
	_render()


func _set_sub_category(sub: String) -> void:
	if _sub_category == sub:
		return
	_sub_category = sub
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


# Which of SUB_CATEGORIES an item belongs to, for the icon-grid filter tabs.
# Priority order matters where an item could plausibly fit more than one
# (e.g. a foldable bed is filed under Transformable first, since that's the
# more useful thing to know about it while browsing).
func _sub_category_of(f: Dictionary) -> String:
	if (f.get("foldable", false) as bool) or (f.get("rail_axis", "") as String) != "":
		return "Transformable"
	var functions := f.get("functions", []) as Array
	if "sleep" in functions:
		return "Bedroom"
	if "hygiene" in functions:
		return "Bathroom"
	if "cook" in functions:
		return "Kitchen"
	if "sit" in functions or "work" in functions:
		return "Living"
	if "storage" in functions:
		return "Storage"
	return "Living"


func populate(furniture_list: Array) -> void:
	_full_list = furniture_list
	_render()


func _render() -> void:
	for child in item_list.get_children():
		child.queue_free()

	if _category == Category.BUILDER:
		item_list.add_child(_build_builder_tool_row())

	# The "ITEMS" caption used to explain click=buy/hover=preview, but it forced
	# the narrow sidebar wider than the 2-column item grid, causing a
	# horizontal scrollbar and clipping the right column — the icon grid is
	# self-explanatory enough (and the item tooltips carry the "hover for
	# details" hint) that the label isn't needed for Furniture. Builder still
	# gets a short caption since its rows are text, not icons.
	if _category == Category.BUILDER:
		var hdr := Label.new()
		hdr.text = "STAIRCASES"
		hdr.add_theme_font_size_override("font_size", 9)
		hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
		item_list.add_child(hdr)

	var shown := _full_list.filter(func(f): return _is_builder(f) == (_category == Category.BUILDER))
	if _category == Category.FURNITURE and _sub_category != "All":
		shown = shown.filter(func(f): return _sub_category_of(f) == _sub_category)

	if _category == Category.FURNITURE:
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 6)
		for f in shown:
			flow.add_child(_build_item_cell(f))
		item_list.add_child(flow)
	else:
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
# aspect ratio — used as the icon-grid placeholder while a real 3D-render
# thumbnail is being fetched, and as the permanent fallback for items with no
# model (or while running with 3D rendering unavailable).
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


# One catalog cell: a big icon (real 3D-render thumbnail once available, mini
# blueprint chip until then) with the price underneath. Click = buy & place;
# hover = full stats tooltip near the cursor. This replaces the old text-row
# layout so the panel scans as a parts catalog, not a spreadsheet.
class ItemCell extends PanelContainer:
	var _fdata: Dictionary
	var _icon_holder: Control
	var _owner_inv: Control
	var _hover_timer: Timer

	# Hovering opens the isolated single-item 3D preview after a short delay
	# (so a mouse just passing through the grid doesn't spawn a viewport per
	# cell) instead of requiring a right-click to find out what an item looks
	# like before buying it.
	const HOVER_PREVIEW_DELAY := 0.35

	func _init(fdata: Dictionary, owner_inv: Control) -> void:
		_fdata = fdata
		_owner_inv = owner_inv
		custom_minimum_size = Vector2(60, 78)
		mouse_filter = Control.MOUSE_FILTER_STOP
		var style := GameTheme.make_card_stylebox(Color(0.210, 0.185, 0.150), Color(0.320, 0.270, 0.205), 8)
		add_theme_stylebox_override("panel", style)

		_hover_timer = Timer.new()
		_hover_timer.one_shot = true
		_hover_timer.wait_time = HOVER_PREVIEW_DELAY
		_hover_timer.timeout.connect(_on_hover_preview_timeout)
		add_child(_hover_timer)

		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 2)
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(vb)

		_icon_holder = Control.new()
		_icon_holder.custom_minimum_size = Vector2(48, 48)
		_icon_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_icon_holder.add_child(Inventory._make_item_icon(fdata, 48.0))
		var icon_row := CenterContainer.new()
		icon_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_row.add_child(_icon_holder)
		vb.add_child(icon_row)

		var price_lbl := Label.new()
		price_lbl.text = "%d€" % (fdata.get("buy_price", 0) as int)
		price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		price_lbl.add_theme_font_size_override("font_size", 11)
		price_lbl.add_theme_color_override("font_color", Color(0.62, 0.88, 0.64))
		price_lbl.set_meta("price", fdata.get("buy_price", 0) as int)
		price_lbl.name = "PriceLabel"
		vb.add_child(price_lbl)

		mouse_entered.connect(_on_hover_start)
		mouse_exited.connect(_on_hover_end)
		gui_input.connect(_on_gui_input)

		var cached := Thumb.get_cached(fdata.get("id", "") as String)
		if cached:
			_swap_icon(cached)
		else:
			_fetch_thumbnail()

	func _fetch_thumbnail() -> void:
		var tex: Texture2D = await Thumb.get_icon_async(_fdata)
		if tex and is_instance_valid(self):
			_swap_icon(tex)

	func _swap_icon(tex: Texture2D) -> void:
		for c in _icon_holder.get_children():
			c.queue_free()
		var trect := TextureRect.new()
		trect.texture = tex
		trect.custom_minimum_size = Vector2(48, 48)
		trect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		trect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		trect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_icon_holder.add_child(trect)

	func _on_hover_start() -> void:
		if _owner_inv.has_method("_show_tooltip"):
			_owner_inv.call("_show_tooltip", _fdata, self)
		_hover_timer.start()

	func _on_hover_end() -> void:
		if _owner_inv.has_method("_hide_tooltip"):
			_owner_inv.call("_hide_tooltip")
		_hover_timer.stop()

	func _on_hover_preview_timeout() -> void:
		if _owner_inv.has_method("_embed_tooltip_preview"):
			_owner_inv.call("_embed_tooltip_preview", _fdata)

	func _on_gui_input(event: InputEvent) -> void:
		if not (event is InputEventMouseButton and event.pressed):
			return
		var btn := (event as InputEventMouseButton).button_index
		if btn == MOUSE_BUTTON_LEFT:
			if _owner_inv.has_method("_on_cell_clicked"):
				_owner_inv.call("_on_cell_clicked", _fdata)
		elif btn == MOUSE_BUTTON_RIGHT:
			# Right-click shows the 3D preview immediately instead of waiting
			# out the hover delay.
			if _owner_inv.has_method("_embed_tooltip_preview"):
				_owner_inv.call("_embed_tooltip_preview", _fdata)


func _build_item_cell(f: Dictionary) -> Control:
	return ItemCell.new(f, self)


func _on_cell_clicked(f: Dictionary) -> void:
	var price := f.get("buy_price", 0) as int
	if _gm != null and _gm.budget < price:
		Audio.play("error")
		return
	_on_buy_pressed(f["id"] as String)


# ── Hover tooltip ────────────────────────────────────────────────────────────
# One shared floating panel, positioned near the cursor rather than pinned —
# keeps the player's eyes where they're already looking instead of jumping to
# a fixed info card elsewhere on screen.
func _ensure_tooltip() -> void:
	if is_instance_valid(_tooltip):
		return
	_tooltip = PanelContainer.new()
	_tooltip.top_level = true
	# IGNORE — the tooltip has no interactive content anymore (the 3D preview
	# is a passive diorama, not a button), so it must never intercept mouse
	# input. It used to STOP input to let the cursor travel onto it and click
	# "View in 3D"; left over after that button was removed, STOP silently ate
	# hover events for whatever grid cell happened to sit underneath the
	# (now much bigger) tooltip, which is why some items intermittently
	# couldn't be hovered.
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.z_index = 100
	_tooltip.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.070, 0.150, 0.260, 0.97)
	style.border_color = GameTheme.C_AMBER
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	style.shadow_color = Color(0, 0, 0, 0.4)
	style.shadow_size = 8
	_tooltip.add_theme_stylebox_override("panel", style)
	add_child(_tooltip)


func _show_tooltip(f: Dictionary, cell: Control) -> void:
	_ensure_tooltip()
	for c in _tooltip.get_children():
		c.queue_free()

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	vb.custom_minimum_size.x = 180
	_tooltip.add_child(vb)

	var name_lbl := Label.new()
	name_lbl.text = f.get("name", "?") as String
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER)
	vb.add_child(name_lbl)

	var sz := f.get("size", {}) as Dictionary
	var dims := Label.new()
	dims.text = "%.1f × %.1f m" % [(sz.get("w", 0) as int) / 10.0, (sz.get("h", 0) as int) / 10.0]
	dims.add_theme_font_size_override("font_size", 10)
	dims.add_theme_color_override("font_color", GameTheme.C_MUTED)
	vb.add_child(dims)

	var funcs := f.get("functions", []) as Array
	if not funcs.is_empty():
		var func_lbl := Label.new()
		func_lbl.text = "Satisfies: " + ", ".join(funcs)
		func_lbl.add_theme_font_size_override("font_size", 10)
		func_lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
		func_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		func_lbl.custom_minimum_size.x = 180
		vb.add_child(func_lbl)

	var tags: Array = []
	if (f.get("foldable", false) as bool):
		tags.append("Foldable")
	if (f.get("rail_axis", "") as String) != "":
		tags.append("Slides on a rail")
	if (f.get("needs_water", false) as bool):
		tags.append("Needs plumbing")
	if (f.get("needs_power", false) as bool):
		tags.append("Needs power")
	if (f.get("creates_loft", false) as bool):
		tags.append("Creates a loft level")
	if not tags.is_empty():
		var tag_lbl := Label.new()
		tag_lbl.text = " · ".join(tags)
		tag_lbl.add_theme_font_size_override("font_size", 9)
		tag_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER)
		tag_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tag_lbl.custom_minimum_size.x = 180
		vb.add_child(tag_lbl)

	var sep := HSeparator.new()
	vb.add_child(sep)

	var price_lbl := Label.new()
	price_lbl.text = "Buy: %d€" % (f.get("buy_price", 0) as int)
	price_lbl.add_theme_font_size_override("font_size", 11)
	price_lbl.add_theme_color_override("font_color", Color(0.62, 0.88, 0.64))
	vb.add_child(price_lbl)

	# The 3D preview lands here once the hover delay fires (see
	# _embed_tooltip_preview) — starts empty so plain text tooltips stay cheap
	# for a cursor just passing through the grid.
	_tooltip_preview_holder = Control.new()
	_tooltip_preview_holder.custom_minimum_size = Vector2(340, 300)
	vb.add_child(_tooltip_preview_holder)
	_tooltip_preview = null
	_tooltip_fdata_id = f.get("id", "") as String

	_tooltip.visible = true
	call_deferred("_position_tooltip", cell)


# Builds the isolated single-item 3D diorama straight into the currently-open
# tooltip's placeholder, instead of a separate floating modal elsewhere on
# screen — the player sees the stats and the 3D shape together, in one place,
# without the rest of the UI disappearing behind it.
func _embed_tooltip_preview(f: Dictionary) -> void:
	if not is_instance_valid(_tooltip_preview_holder):
		return
	if _tooltip_fdata_id != (f.get("id", "") as String):
		return   # the cursor moved to a different cell before the delay fired
	if is_instance_valid(_tooltip_preview):
		return   # already embedded (e.g. hover timer fired, then right-click)

	var view := Room3DViewScene.instantiate()
	_tooltip_preview_holder.add_child(view)
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	if view.has_node("CloseBtn"):
		(view.get_node("CloseBtn") as Button).visible = false
	_tooltip_preview = view
	view.build_single_item(f)


func _position_tooltip(cell: Control) -> void:
	if not is_instance_valid(_tooltip) or not is_instance_valid(cell):
		return
	var vp_size := get_viewport_rect().size
	var anchor := cell.get_global_rect()
	var pos := Vector2(anchor.position.x + anchor.size.x + 6.0, anchor.position.y)
	if pos.x + _tooltip.size.x > vp_size.x:
		pos.x = anchor.position.x - _tooltip.size.x - 6.0
	if pos.y + _tooltip.size.y > vp_size.y:
		pos.y = vp_size.y - _tooltip.size.y - 4.0
	_tooltip.position = pos


func _hide_tooltip() -> void:
	# The tooltip is mouse-filter IGNORE now (nothing interactive inside it),
	# so there's no need to wait for the cursor to "arrive" on it before
	# hiding — it can never be the thing the cursor is hovering.
	if is_instance_valid(_tooltip):
		_tooltip.visible = false


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
