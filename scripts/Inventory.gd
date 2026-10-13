extends PanelContainer
class_name Inventory

signal buy_requested(furniture_id: String)
signal builder_tool_selected(tool_id: String)   # "" = no tool (back to select/place mode)
signal close_requested

const Room3DViewScene := preload("res://scenes/Room3DView.tscn")

# "Builder" is anything that shapes the room itself rather than furnishing it
# (currently just staircases) — kept as a plain id-flag check so future
# additions (rails, wall pieces, etc., if they ever become buyable catalog
# items) only need to satisfy this one predicate to land in the right tab.
enum Category { FURNITURE, BUILDER }

# Sub-categories within the Furniture tab — icon-grid browsing instead of one
# long scrolling list, most valuable once the catalog is 40-60+ pieces.
const SUB_CATEGORIES := ["All", "Bedroom", "Bathroom", "Kitchen", "Living", "Storage", "Transformable", "Rentals"]

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
	"Rentals":       "💰",
}


# A rental box has a negative price: placing it pays the player its rent.
static func price_text(price: int) -> String:
	return ("+%d€" % -price) if price < 0 else ("%d€" % price)

var _gm: GameManager = null
var _category: int = Category.FURNITURE
var _sub_category: String = "All"
var _full_list: Array = []
var _owned_list: Array = []
var _owned_catalog: Array = []

@onready var scroll:    ScrollContainer = $ScrollContainer
@onready var item_list: VBoxContainer   = $ScrollContainer/ItemList

var _filter_box: HBoxContainer = null
var _category_buttons: Dictionary = {}     # Category enum value -> Button
var _sub_filter_box: Container = null
var _sub_filter_separator: HSeparator = null
var _sub_filter_buttons: Dictionary = {}   # category name -> Button
var _search: LineEdit = null
var _row: HBoxContainer = null       # the strip's single row of cards
var _need_filter: String = ""        # set when opened from a need chip: only what provides it
var _last_unmet: Array = []

# The catalogue's left-hand list. "Needed" comes first and is where the
# catalogue opens: the pieces that provide something the tenant still lacks.
const VIEW_NEEDED := "Needed"
const VIEW_BUILDER := "Builder"
const VIEWS := [
	["Needed", "⭐", "Needed"], ["All", "▦", "All"], ["Bedroom", "🛏", "Bedroom"],
	["Bathroom", "🚿", "Bathroom"], ["Kitchen", "🍳", "Kitchen"], ["Living", "🛋", "Living"],
	["Storage", "📦", "Storage"], ["Transformable", "🔀", "Folding"], ["Rentals", "💰", "Rentals"],
	["Builder", "🛠", "Build"],
]
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


# The catalogue is a strip docked along the bottom of the screen, the way
# The Sims does it: the apartment stays in view above it, and it stays open
# while the player buys and places one piece after another. Tabs and a search
# box across the top, one row of cards underneath that scrolls sideways.
func _ensure_filter_box() -> void:
	if is_instance_valid(_filter_box):
		return
	remove_child(scroll)
	var paper := StyleBoxFlat.new()
	paper.bg_color = TenantCard.BP_BG.darkened(0.18)
	paper.bg_color.a = 0.97
	paper.set_content_margin(SIDE_LEFT, 12)
	paper.set_content_margin(SIDE_RIGHT, 12)
	paper.set_content_margin(SIDE_TOP, 8)
	paper.set_content_margin(SIDE_BOTTOM, 8)
	add_theme_stylebox_override("panel", paper)
	var root := VBoxContainer.new()
	root.name = "Root"
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	root.add_child(top)
	_filter_box = top
	_sub_filter_box = top
	var group := ButtonGroup.new()
	group.allow_unpress = true   # while searching or filtering by a need, no tab is current
	for spec in VIEWS:
		var id: String = spec[0]
		var b := Button.new()
		b.text = "%s %s" % [spec[1], spec[2]]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(0, 28)
		b.add_theme_font_size_override("font_size", 12)
		var sp := StyleBoxFlat.new()
		sp.bg_color = Color(0.42, 0.36, 0.13)
		sp.border_color = GameTheme.C_AMBER
		sp.set_border_width_all(1)
		sp.set_corner_radius_all(7)
		sp.set_content_margin(SIDE_LEFT, 8)
		sp.set_content_margin(SIDE_RIGHT, 8)
		sp.anti_aliasing = true
		b.add_theme_stylebox_override("pressed", sp)
		b.add_theme_color_override("font_pressed_color", Color(1.0, 0.95, 0.70))
		b.pressed.connect(_set_view.bind(id))
		if id == VIEW_NEEDED:
			b.custom_minimum_size.x = 112   # room for its "(3)" count
		top.add_child(b)
		_sub_filter_buttons[id] = b
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	_search = LineEdit.new()
	_search.placeholder_text = "Search…"
	_search.clear_button_enabled = true
	_search.custom_minimum_size = Vector2(200, 28)
	_search.add_theme_font_size_override("font_size", 12)
	_search.text_changed.connect(func(_t: String):
		_need_filter = ""
		_sync_filter_buttons()
		_render())
	# Enter hands the keyboard back to the game (R to rotate, Q/E, WASD).
	_search.text_submitted.connect(func(_t: String): _search.release_focus())
	top.add_child(_search)
	root.add_child(scroll)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# The mouse wheel moves the row sideways.
	scroll.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			var wheel := (event as InputEventMouseButton).button_index
			if wheel == MOUSE_BUTTON_WHEEL_DOWN or wheel == MOUSE_BUTTON_WHEEL_UP:
				scroll.scroll_horizontal += 140 if wheel == MOUSE_BUTTON_WHEEL_DOWN else -140
				scroll.accept_event())
	if _gm != null and not _gm.functions_updated.is_connected(_on_needs_changed):
		_gm.functions_updated.connect(_on_needs_changed)


# The apartment changed. If the strip is showing "what is still needed", that
# list has just changed too.
func _on_needs_changed(_fulfilled: Array, _required: Array) -> void:
	if not visible or not is_instance_valid(_filter_box):
		return
	var now := unmet_needs()
	if now == _last_unmet:
		return
	_sync_filter_buttons()
	if _search.text.strip_edges() == "" and (_need_filter != "" or (_category == Category.FURNITURE and _sub_category == VIEW_NEEDED)):
		_render()


# Opened from a need chip in the bar ("Sleep ✗"): everything that provides
# that one need, and nothing else.
func show_need(need: String) -> void:
	_ensure_filter_box()
	_category = Category.FURNITURE
	_need_filter = need
	_search.text = ""
	_sync_filter_buttons()
	visible = true
	_render()


# Which view is showing: one of VIEWS' ids.
func _current_view() -> String:
	return VIEW_BUILDER if _category == Category.BUILDER else _sub_category


func _set_view(id: String) -> void:
	_need_filter = ""
	if id == VIEW_BUILDER:
		_category = Category.BUILDER
	else:
		_category = Category.FURNITURE
		_sub_category = id
		if _builder_tool != "":
			_builder_tool = ""
			builder_tool_selected.emit("")
	if is_instance_valid(_search) and _search.text != "":
		_search.text = ""      # picking a tab leaves search mode
	_sync_filter_buttons()
	_render()


# Opens the strip. It starts on "Needed" whenever the tenant still lacks
# something, because that is nearly always what the player came for.
func open_catalog() -> void:
	_ensure_filter_box()
	_category = Category.FURNITURE
	_sub_category = VIEW_NEEDED if not unmet_needs().is_empty() else "All"
	_need_filter = ""
	_builder_tool = ""
	_search.text = ""
	_sync_filter_buttons()
	visible = true
	_render()


# Kept for callers that open on a particular category.
func open_for_category(category: int, sub_category: String) -> void:
	_ensure_filter_box()
	_search.text = ""
	_set_view(VIEW_BUILDER if category == Category.BUILDER else (sub_category if sub_category != "" else "All"))
	visible = true


func _sync_filter_buttons() -> void:
	var view := _current_view()
	var searching := (is_instance_valid(_search) and _search.text.strip_edges() != "") or _need_filter != ""
	var needed := unmet_needs().size()
	for id in _sub_filter_buttons:
		var b := _sub_filter_buttons[id] as Button
		b.button_pressed = (id == view) and not searching
		if id == VIEW_NEEDED:
			b.text = "⭐ Needed" + ((" (%d)" % needed) if needed > 0 else "")


# What the tenant still lacks: every need the level asks for (in any moment)
# that the apartment does not provide yet.
func unmet_needs() -> Array:
	var out: Array = []
	if _gm == null:
		return out
	var wanted: Array = _gm.required_functions.duplicate()
	if not _gm.moments.is_empty():
		# A level with moments shows one moment's needs at a time in the
		# bar; "Needed" lists what is missing for that same moment.
		wanted = []
		for m in _gm.moments:
			var md := m as Dictionary
			if Furniture.active_moment_id == "" or (md.get("id", "") as String) == Furniture.active_moment_id:
				for need in md.get("needs", []) as Array:
					if need not in wanted:
						wanted.append(need)
	for need in wanted:
		if need not in _gm.fulfilled_functions:
			out.append(need)
	return out


# Everything a piece can provide, folded or unfolded.
static func provides(f: Dictionary) -> Array:
	var out: Array = []
	for key in ["functions", "folded_functions", "extended_functions"]:
		for fn in f.get(key, []) as Array:
			if fn not in out:
				out.append(fn)
	return out


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
	if f.get("rental", false) as bool:
		return "Rentals"
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
	# Taken out at once, not just queued: for a frame the old row and the new
	# one would both count toward the strip's height.
	for child in item_list.get_children():
		item_list.remove_child(child)
		child.queue_free()
	if not is_instance_valid(_filter_box):
		return
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 8)
	item_list.add_child(_row)
	_last_unmet = unmet_needs()
	# Neutral order: smallest footprint first. Not cheapest first, which only
	# invited clicking the first card; what a piece costs in floor is the
	# decision here, and the card shows it.
	var by_size := func(a, b):
		var sa := a.get("size", {}) as Dictionary
		var sb := b.get("size", {}) as Dictionary
		var aa := (sa.get("w", 0) as int) * (sa.get("h", 0) as int)
		var ab := (sb.get("w", 0) as int) * (sb.get("h", 0) as int)
		return aa < ab if aa != ab else (a.get("buy_price", 0) as int) < (b.get("buy_price", 0) as int)
	var furniture := _full_list.filter(func(f): return not _is_builder(f))
	furniture.sort_custom(by_size)
	var query := _search.text.strip_edges().to_lower() if is_instance_valid(_search) else ""

	if query != "":
		var hits := furniture.filter(func(f):
			var hay := (f.get("name", "") as String).to_lower() + " " + " ".join(Inventory.provides(f)) \
				+ " " + _sub_category_of(f).to_lower()
			for word in query.split(" ", false):
				if not hay.contains(word):
					return false
			return true)
		_add_heading("🔎", "%d found" % hits.size())
		_add_cards(hits)
		if hits.is_empty():
			_add_note("Nothing matches. Try a need (sleep, sit, work, storage) or part of a name.")
	elif _need_filter != "":
		var options := furniture.filter(func(f): return _need_filter in Inventory.provides(f))
		_add_heading(TenantCard.NEED_GLYPH.get(_need_filter, "❔") as String, _need_filter.capitalize())
		_add_cards(options)
		if options.is_empty():
			_add_note("No piece in this level provides it.")
	elif _category == Category.BUILDER:
		_row.add_child(_build_builder_tool_row())
		for f in _full_list.filter(func(f): return _is_builder(f)):
			_row.add_child(_build_shop_row(f))
	elif _sub_category == VIEW_NEEDED:
		if _last_unmet.is_empty():
			_add_note("The tenant has everything they asked for. Pick a tab to browse.")
		for need in _last_unmet:
			var options := furniture.filter(func(f): return need in Inventory.provides(f))
			_add_heading(TenantCard.NEED_GLYPH.get(need, "❔") as String, (need as String).capitalize())
			if options.is_empty():
				_add_note("Nothing in this level provides it.")
			else:
				_add_cards(options)
	else:
		var shown := furniture
		if _sub_category != "All":
			shown = furniture.filter(func(f): return _sub_category_of(f) == _sub_category)
		_add_cards(shown)
		if shown.is_empty():
			_add_note("Nothing in this category for this level.")

	if not _owned_list.is_empty():
		_render_owned_section()
	scroll.scroll_horizontal = 0


func _add_cards(items: Array) -> void:
	for f in items:
		_row.add_child(_build_item_cell(f))


# A group's name plate inside the row: a pictogram over a short label.
func _add_heading(glyph: String, text: String) -> void:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.custom_minimum_size.x = 70
	var g := Label.new()
	g.text = glyph
	g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	g.add_theme_font_size_override("font_size", 22)
	box.add_child(g)
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", GameTheme.C_AMBER)
	box.add_child(l)
	_row.add_child(box)


func _add_note(text: String) -> void:
	var note := Label.new()
	note.text = text
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", GameTheme.C_MUTED)
	note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	note.custom_minimum_size = Vector2(260, 0)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_row.add_child(note)


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


static func _make_view_chip(label_text: String, icon: Control) -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	vb.add_child(icon)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(lbl)
	return vb


# Real orthographic render of the item's own 3D model (via the Thumb
# autoload) — top-down for the Floor Plan chip, front elevation for the Wall
# View chip — composited over a blueprint-colored backdrop. Shows the item's
# actual shape (a round toilet bowl, a chair's real silhouette, ...) instead
# of a generic placeholder, using art the game already ships (no licensing
# cost, no per-item hand-drawing). Starts with just the backdrop and fades
# in the real render once Thumb finishes rendering it (shared with — and
# ultimately cached alongside — the same renders Furniture.gd/WallInspector.gd
# use in the live Floor Plan/Wall View).
class OrthoIconChip extends Control:
	var _fdata: Dictionary
	var _mode: String   # "top" or "front"
	var _trect: TextureRect

	func _init(fdata: Dictionary, mode: String, px: float = 72.0) -> void:
		_fdata = fdata
		_mode = mode
		custom_minimum_size = Vector2(px, px)
		clip_contents = true

		var bg := StyleBoxFlat.new()
		bg.bg_color = GridDraw.BP_FLOOR
		bg.set_corner_radius_all(6)
		bg.anti_aliasing = true
		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_theme_stylebox_override("panel", bg)
		panel.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(panel)

		_trect = TextureRect.new()
		_trect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_trect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_trect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_trect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_trect.offset_left = 6; _trect.offset_top = 6
		_trect.offset_right = -6; _trect.offset_bottom = -6
		add_child(_trect)

		var cached := Thumb.get_cached_ortho(_mode, fdata.get("id", "") as String)
		if cached:
			_trect.texture = cached
		else:
			_load()

	func _load() -> void:
		var tex: Texture2D
		if _mode == "top":
			tex = await Thumb.get_topdown_icon_async(_fdata)
		else:
			tex = await Thumb.get_elevation_icon_async(_fdata)
		if is_instance_valid(_trect) and tex:
			_trect.texture = tex


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
		custom_minimum_size = Vector2(116, 132)
		mouse_filter = Control.MOUSE_FILTER_STOP
		var style := GameTheme.make_card_stylebox(Color(0.105, 0.185, 0.290), Color(0.30, 0.44, 0.60), 8)
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
		_icon_holder.custom_minimum_size = Vector2(54, 54)
		_icon_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_icon_holder.add_child(Inventory._make_item_icon(fdata, 54.0))
		var icon_row := CenterContainer.new()
		icon_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_row.add_child(_icon_holder)
		vb.add_child(icon_row)

		# The name, always visible: the picture alone is not enough to tell
		# a nightstand from a side table.
		var name_lbl := Label.new()
		name_lbl.text = fdata.get("name", "?") as String
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_lbl.max_lines_visible = 2
		name_lbl.custom_minimum_size = Vector2(106, 28)
		name_lbl.add_theme_font_size_override("font_size", 11)
		name_lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(name_lbl)

		# What it provides, as the same pictograms the needs bar uses.
		var gives := Label.new()
		var marks: PackedStringArray = []
		for fn in Inventory.provides(fdata):
			if TenantCard.NEED_GLYPH.has(fn):
				marks.append(TenantCard.NEED_GLYPH[fn] as String)
		# ...and what it costs in floor: the footprint, in centimetres.
		var fp := fdata.get("size", {}) as Dictionary
		var size_text := "%d×%d cm" % [(fp.get("w", 0) as int) * 10, (fp.get("h", 0) as int) * 10]
		gives.text = (" ".join(marks) + "  " + size_text) if not marks.is_empty() else size_text
		gives.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		gives.custom_minimum_size.y = 15
		gives.add_theme_font_size_override("font_size", 10)
		gives.add_theme_color_override("font_color", GameTheme.C_MUTED)
		gives.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(gives)

		# A piece that covers two or more of the needs still missing is the
		# kind of answer the puzzle rewards; it gets an amber edge and a mark.
		var missing: Array = owner_inv.call("unmet_needs") if owner_inv.has_method("unmet_needs") else []
		var covers := 0
		for fn in Inventory.provides(fdata):
			if fn in missing:
				covers += 1
		if covers >= 2:
			var gold := GameTheme.make_card_stylebox(Color(0.20, 0.23, 0.22), GameTheme.C_AMBER, 8)
			add_theme_stylebox_override("panel", gold)
			name_lbl.text = "★ " + name_lbl.text
			name_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.62))
			set_meta("covers", covers)

		var price_lbl := Label.new()
		price_lbl.text = Inventory.price_text(fdata.get("buy_price", 0) as int)
		price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		price_lbl.add_theme_font_size_override("font_size", 12)
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
		trect.custom_minimum_size = Vector2(54, 54)
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
	var cell := ItemCell.new(f, self)
	if _gm != null:
		_mark_affordability(cell, _gm.budget)
	return cell


# An item the budget can't cover is dimmed, its price turns red, and hovering
# says how far short the budget is. Before, a click on it just played the
# error sound with nothing on screen to say why.
func _mark_affordability(cell: Control, budget: int) -> void:
	var price_lbl := cell.find_child("PriceLabel", true, false) as Label
	if price_lbl == null:
		return
	var price := price_lbl.get_meta("price", 0) as int
	var can_afford := budget >= price
	cell.modulate = Color(1, 1, 1, 1.0) if can_afford else Color(1, 1, 1, 0.5)
	price_lbl.add_theme_color_override("font_color", Color(0.62, 0.88, 0.64) if can_afford else Color(0.95, 0.45, 0.38))
	cell.tooltip_text = "" if can_afford else "Costs %d€ — you have %d€" % [price, budget]


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

	# Mobility tier — how hard the tenant finds this piece to reposition (see
	# Furniture.mobility_tier). "red" is the catalog default (most furniture:
	# sofas, beds, wardrobes, appliances) so it's still worth showing even
	# without an explicit tag, unlike the other tags above which only appear
	# when actually set.
	var tier := f.get("mobility_tier", "red") as String
	var tier_lbl := Label.new()
	match tier:
		"green":
			tier_lbl.text = "🪶 Light — freely movable"
			tier_lbl.add_theme_color_override("font_color", GameTheme.C_GOOD)
		"yellow":
			tier_lbl.text = "🪶🪶 Medium — uncomfortable to move"
			tier_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER)
		_:
			tier_lbl.text = "🪶🪶🪶 Heavy — fixed in place"
			tier_lbl.add_theme_color_override("font_color", GameTheme.C_BAD)
	tier_lbl.add_theme_font_size_override("font_size", 10)
	vb.add_child(tier_lbl)

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
	var hover_price := f.get("buy_price", 0) as int
	price_lbl.text = ("Rent: +%d€ — a tenant pays you for the space" % -hover_price) if hover_price < 0 else ("Buy: %d€" % hover_price)
	price_lbl.add_theme_font_size_override("font_size", 11)
	price_lbl.add_theme_color_override("font_color", Color(0.62, 0.88, 0.64))
	vb.add_child(price_lbl)

	# Floor Plan / Wall View chips — real orthographic renders of the item's
	# own 3D model (top-down and front-elevation), not a generic placeholder
	# shape. Gives a sense of how the piece actually reads in those two views
	# before ever buying it, instead of only the isolated 3D diorama below.
	var views_row := HBoxContainer.new()
	views_row.add_theme_constant_override("separation", 12)
	vb.add_child(views_row)
	views_row.add_child(_make_view_chip("Floor Plan", OrthoIconChip.new(f, "top")))
	views_row.add_child(_make_view_chip("Wall View", OrthoIconChip.new(f, "front")))

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


# Previously a single HBoxContainer row (icon + name + functions tag + price
# + Buy button) with minimum widths that added up to ~350px — far wider than
# the Inventory panel's actual fixed 170px (see Main.tscn). It only ever
# looked fine because Containers don't clip their children, so the overflow
# just spilled rightward onto whatever was empty back there in Floor Plan
# mode. In 3D mode that same screen region is the Room3DView viewport, which
# sits on top and swallows both the visual and the clicks — so the Buy
# button for Staircases silently became unreachable in 3D. Two compact rows
# that actually fit inside 170px fixes this for every view mode at once,
# rather than papering over 3D specifically.
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

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	card.add_child(vb)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 6)
	vb.add_child(top_row)

	# Mini blueprint footprint icon (true shape, color-coded)
	top_row.add_child(_make_item_icon(f, 22.0))

	var name_lbl := Label.new()
	name_lbl.text = f["name"]
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	name_lbl.clip_text = true
	top_row.add_child(name_lbl)

	# The functions tag ("loft_access" etc.) moves onto its own line above the
	# price/Buy row instead of sharing a row with them — three items plus a
	# button never fit in the panel's 170px width no matter how much each is
	# shrunk, and price+Buy are the two things that actually must be reachable.
	var func_lbl := Label.new()
	func_lbl.text = _fmt_funcs(f["functions"])
	func_lbl.add_theme_font_size_override("font_size", 9)
	func_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	func_lbl.clip_text = true
	vb.add_child(func_lbl)

	var bottom_row := HBoxContainer.new()
	bottom_row.add_theme_constant_override("separation", 6)
	vb.add_child(bottom_row)

	var price_lbl := Label.new()
	price_lbl.text = Inventory.price_text(f["buy_price"] as int)
	price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price_lbl.add_theme_font_size_override("font_size", 11)
	price_lbl.add_theme_color_override("font_color", Color(0.62, 0.88, 0.64))
	var pp := StyleBoxFlat.new()
	pp.bg_color = Color(0.10, 0.22, 0.13)
	pp.border_color = Color(0.26, 0.48, 0.30)
	pp.set_border_width_all(1)
	pp.set_corner_radius_all(8)
	pp.anti_aliasing = true
	pp.set_content_margin(SIDE_LEFT, 5)
	pp.set_content_margin(SIDE_RIGHT, 5)
	pp.set_content_margin(SIDE_TOP, 1)
	pp.set_content_margin(SIDE_BOTTOM, 1)
	price_lbl.add_theme_stylebox_override("normal", pp)
	bottom_row.add_child(price_lbl)

	var buy_btn := Button.new()
	buy_btn.text = "Buy"
	buy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buy_btn.add_theme_font_size_override("font_size", 10)
	buy_btn.set_meta("price", f["buy_price"] as int)
	buy_btn.disabled = _gm != null and _gm.budget < (f["buy_price"] as int)
	buy_btn.pressed.connect(_on_buy_pressed.bind(f["id"]))
	bottom_row.add_child(buy_btn)

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
	_row.add_child(sep)

	var hdr := Label.new()
	hdr.text = "STARTING ITEMS"
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	_row.add_child(hdr)

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

			_row.add_child(card)


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
			var price := (ctrl as Button).get_meta("price") as int
			(ctrl as Button).disabled = new_budget < price
			(ctrl as Button).tooltip_text = ("Costs %d€ — you have %d€" % [price, new_budget]) if new_budget < price else ""
	for cell in item_list.find_children("PriceLabel", "Label", true, false):
		var owner_cell := (cell as Label).get_parent().get_parent() as Control   # label -> VBox -> ItemCell
		if owner_cell != null:
			_mark_affordability(owner_cell, new_budget)


func _on_buy_pressed(furniture_id: String) -> void:
	if is_instance_valid(_search):
		_search.release_focus()
	Audio.play("click")
	buy_requested.emit(furniture_id)
