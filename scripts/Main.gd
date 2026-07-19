extends Node

const FurnitureScene := preload("res://scenes/Furniture.tscn")
const Room3DViewScene := preload("res://scenes/Room3DView.tscn")

@onready var gm:           GameManager  = $GameManager
@onready var room:         Node2D       = $Room
@onready var minimap:      Minimap      = $UI/TopBar/Minimap
@onready var budget_label: Label        = $UI/TopBar/Label
@onready var tenant_card:  TenantCard   = $UI/TenantCard
@onready var inventory:    Inventory    = $UI/Inventory
@onready var rent_btn:     Button       = $UI/TopBar/RentButton
@onready var view3d_btn:   Button       = $UI/TopBar/View3DButton
@onready var result_screen: ResultScreen = $ResultScreen
@onready var wall_inspector: WallInspector = $UI/WallInspector
@onready var divider:      ColorRect     = $UI/Divider
@onready var ui_layer:     CanvasLayer   = $UI

const TILE_SIZE := 8          # pixels per grid tile — matches Floor/GridDraw
const TOP_Y     := 10.0       # slim top margin — the old full-width bar is gone; only a
							   # floating gear icon (and Test Layout, when shown) sit up here now
const BOT_Y     := 720.0      # bottom of the play area — full window height now that
							   # the furniture/tenant panels are side columns, not a bottom bar
const FIT_PCT   := 0.95       # fraction of available area to fill

# ── Left/right sidebars ─────────────────────────────────────────────────────
# Furniture shop (left) and the compact tenant-needs tracker (right) are full-
# height side columns now, so the floor plan / wall view / 3D view get the
# entire remaining width instead of sharing it with a bottom strip.
const LEFT_X  := 170.0    # furniture sidebar width — fits the 2-column item grid plus the panel's own margins and scrollbar
const RIGHT_X := 1280.0   # play area now runs the full width — TenantCard floats as an overlay, not a reserved column

# ── Floor plan / docked-panel resizable split ──────────────────────────────
# The docked panel (Wall Inspector or the 3D preview, depending on mode) is a
# horizontal strip along the BOTTOM of the screen — the top-down plan always
# keeps the full width above it, so the divider only moves vertically.
const MIN_SPLIT_Y := 300.0   # top plan area keeps at least this much height
const MAX_SPLIT_Y := 620.0   # bottom panel keeps at least this much height
var _split_y:          float = 460.0
var _dragging_divider: bool = false
var _undo_btn: Button = null   # floating corner button over the floor plan, top-right of the play area
var _redo_btn: Button = null   # sits directly left of _undo_btn, same floating row
var _test_btn: Button = null   # floating "Test Layout" toggle, top-left — only shown for levels with foldable furniture and no moments
var _settings_btn: Button = null   # floating gear-only menu button, top-right corner
var _view_mode_box: HBoxContainer = null   # floating Floor Plan/3D segmented toggle, stacked directly above the floor-tabs Minimap
var _pending_floor_ghost: Furniture = null   # the floor-placement ghost armed alongside a wall placement

# ── View mode: two ways to look at the same apartment, both reading/writing
# the same Floor data — switching modes never converts or loses anything:
#   TOPDOWN — plan only; click a highlighted wall edge to inspect it or hang items via a popup
#   VIEW3D  — walk around in 3D; drag items onto a wall to hang them there
enum ViewMode { TOPDOWN, VIEW3D }
const SCREEN_W := 1280.0   # design-resolution width every TopBar/Divider/WallInspector offset assumes
var _view_mode: int = ViewMode.TOPDOWN
var _mode3d_view:    Control = null   # persistent 3D view for VIEW3D mode (separate from the "reveal" overlay)
var _watch_done_btn: Button  = null   # floating "back to results" button shown during free-camera Watch Again
var _post_win_view: bool = false      # true during Watch Again — level is already rented out, so editing/shortcuts are locked out; only the camera works
var _last_wall_click_by_floor: Dictionary = {}   # floor_id -> {edge, span_lo, span_hi} — for the "W" reopen-last-wall shortcut
var _modal_backdrop: ColorRect = null # dims the screen behind WallInspector when it's shown as a modal
var _mode_buttons:   Dictionary = {}  # ViewMode -> Button
var _mode_hint_lbl:  Label = null     # "click a wall" / "drag onto a wall" guidance outside the docked-pane modes
var _intro_modal_open: bool = false   # "NEW MECHANIC" card is up — blocks zoom/pan everywhere

# ── Floor plan zoom/pan (layered on top of the auto-fit baseline) ─────────
const MIN_MANUAL_ZOOM := 0.4
const MAX_MANUAL_ZOOM := 4.0
var _base_scale:    float   = 1.0
var _base_position: Vector2 = Vector2.ZERO
var _manual_zoom:   float   = 1.0
var _manual_pan:    Vector2 = Vector2.ZERO
var _panning_floor: bool    = false

var _floors:            Dictionary = {}
var _loft_floors:       Dictionary = {}  # base_floor_id -> dynamically created loft Floor node
var _floor_below_id:    Dictionary = {}  # floor id -> id of the "floor"-type floor stacked below it (for the 3D ghost-floor-below reference layer)
var _current_floor_id:  String = ""
var _current_level_id:  String = ""

# ── Builder tab tools (free-form geometry editing during play) ────────────
var _active_builder_tool: String    = ""    # "", "wall", "column", "erase"
var _builder_drawing:     bool      = false
var _builder_press_tile:  Vector2i  = Vector2i.ZERO
var _builder_cur_tile:    Vector2i  = Vector2i.ZERO
var _builder_ghost:       Line2D    = null
var _builder_press_consumed: bool   = false  # only consume the matching release
var _builder_pipe_tiles:  Array     = []  # Vector2i path being drawn for pipe_water/pipe_power
var _builder_pipe_ghost:  Line2D    = null
# Snapshot-based undo: shared by Builder-tool actions (walls/columns/etc.) and
# furniture actions (buy/sell/move/fold) so one Undo button/shortcut reverts
# whichever kind of change happened most recently. Builder entries are
# {"type":"builder", "floor_id", "data"} (deep copy of the Floor's
# Builder-mutable fields); furniture entries are
# {"type":"furniture", "snapshot"} (see _snapshot_all_furniture). Each is
# captured BEFORE the action it undoes.
const BUILDER_UNDO_MAX := 50
var _builder_undo_stack: Array = []
var _redo_stack: Array = []   # entries popped off _builder_undo_stack by Undo, replayed by Redo
var _last_furniture_state: Dictionary = {}   # cache of furniture state as of the last change
var _restoring_furniture: bool = false       # guards the restore's own mutations from re-triggering a push
var _paint_pieces:      Dictionary = {}  # floor_id -> {type_id: PaintedFurniture}
var _active_paint_type: String     = ""
var _painting:          bool       = false
var _last_paint_tile:   Vector2i   = Vector2i(-1, -1)
var _paint_panel:       Control    = null
var _paint_status_lbl:  Label      = null
var _floor_tile_bounds: Dictionary = {}  # floor_id -> Rect2i of painted tile content
var _active_moment_id:  String = ""


func _ready() -> void:
	# Floor tabs (Ground Floor/Loft/Second Floor/...) read better as a vertical
	# stack — it echoes the actual building elevation (higher floors literally
	# higher on screen) instead of a left-to-right strip, and frees up the
	# TopBar. Pulled out of TopBar entirely and floated bottom-right instead,
	# same corner the Undo/Redo buttons already anchor off of.
	minimap.set_compact(false)
	minimap.get_parent().remove_child(minimap)
	ui_layer.add_child(minimap)
	_position_minimap()
	if not gm.budget_changed.is_connected(_on_budget_changed):
		gm.budget_changed.connect(_on_budget_changed)
	if not gm.functions_updated.is_connected(_on_functions_updated):
		gm.functions_updated.connect(_on_functions_updated)
	if not gm.moments_updated.is_connected(_on_moments_updated):
		gm.moments_updated.connect(_on_moments_updated)
	if not minimap.wall_selected.is_connected(_switch_floor):
		minimap.wall_selected.connect(_switch_floor)
	if not tenant_card.moment_selected.is_connected(_on_moment_selected):
		tenant_card.moment_selected.connect(_on_moment_selected)
	if not inventory.buy_requested.is_connected(_on_buy_requested):
		inventory.buy_requested.connect(_on_buy_requested)
	if not inventory.builder_tool_selected.is_connected(_on_builder_tool_selected):
		inventory.builder_tool_selected.connect(_on_builder_tool_selected)
	if not rent_btn.pressed.is_connected(_on_rent_pressed):
		rent_btn.pressed.connect(_on_rent_pressed)
	if not tenant_card.rent_out_requested.is_connected(_on_rent_pressed):
		tenant_card.rent_out_requested.connect(_on_rent_pressed)
	rent_btn.visible = false   # superseded by the TenantCard's own RENT OUT button
	view3d_btn.visible = false   # superseded by the persistent 3D view mode
	if not result_screen.next_level_requested.is_connected(_on_next_level):
		result_screen.next_level_requested.connect(_on_next_level)
	if not result_screen.retry_requested.is_connected(_on_retry):
		result_screen.retry_requested.connect(_on_retry)
	if not result_screen.watch_again_requested.is_connected(_on_watch_again_reveal):
		result_screen.watch_again_requested.connect(_on_watch_again_reveal)
	if not result_screen.advance_level_requested.is_connected(_on_advance_level):
		result_screen.advance_level_requested.connect(_on_advance_level)
	if not wall_inspector.wall_closed.is_connected(_on_inspector_visibility_changed):
		wall_inspector.wall_closed.connect(_on_inspector_visibility_changed)
	if not wall_inspector.wall_item_placed.is_connected(_on_wall_item_placed):
		wall_inspector.wall_item_placed.connect(_on_wall_item_placed)
	divider.mouse_filter = Control.MOUSE_FILTER_STOP
	divider.mouse_default_cursor_shape = Control.CURSOR_VSPLIT
	if not divider.gui_input.is_connected(_on_divider_gui_input):
		divider.gui_input.connect(_on_divider_gui_input)
	Furniture.is_in_floor_pane = func(pos: Vector2) -> bool:
		return pos.x > LEFT_X and pos.x < RIGHT_X and pos.y > TOP_Y and pos.y < _floor_pane_bottom_y()
	_update_split(_split_y)
	_apply_ui_theme()
	_load_level(GameState.pending_level_id)


func _apply_ui_theme() -> void:
	var t := GameTheme.make()
	minimap.theme       = t
	tenant_card.theme   = t
	inventory.theme     = t
	wall_inspector.theme = t

	var ts := StyleBoxFlat.new()
	ts.bg_color     = Color(0.130, 0.113, 0.095, 0.98)
	ts.border_color = GameTheme.C_BORDER
	ts.set_border_width(SIDE_BOTTOM, 2)
	ts.set_content_margin_all(6)
	ts.shadow_color = Color(0, 0, 0, 0.35)
	ts.shadow_size = 6
	ts.shadow_offset = Vector2(0, 3)
	($UI/TopBarBg as Panel).add_theme_stylebox_override("panel", ts)

	budget_label.add_theme_font_size_override("font_size", 15)
	budget_label.add_theme_color_override("font_color", GameTheme.C_AMBER)
	# Budget reads as the puzzle's primary resource — give it a HUD pill of its
	# own instead of floating bare text in the bar.
	var bp := StyleBoxFlat.new()
	bp.bg_color     = Color(0.22, 0.19, 0.08)
	bp.border_color = Color(0.62, 0.54, 0.24)
	bp.set_border_width_all(1)
	bp.set_corner_radius_all(10)
	bp.anti_aliasing = true
	bp.set_content_margin(SIDE_LEFT, 12)
	bp.set_content_margin(SIDE_RIGHT, 12)
	bp.set_content_margin(SIDE_TOP, 3)
	bp.set_content_margin(SIDE_BOTTOM, 3)
	budget_label.add_theme_stylebox_override("normal", bp)
	budget_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# The old TopBar is gone — Budget now lives at the near (left) end of the
	# bottom TenantCard bar, right alongside the moments/needs it funds.
	var tenant_hbox := tenant_card.get_node("VBox") as HBoxContainer
	if budget_label.get_parent() != tenant_hbox:
		if budget_label.get_parent():
			budget_label.get_parent().remove_child(budget_label)
		tenant_hbox.add_child(budget_label)
		tenant_hbox.move_child(budget_label, 0)

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

	# The old full-width TopBar is gone — Budget/moments moved into the bottom
	# TenantCard bar, and the view-mode toggle/gear menu/Test Layout button
	# below are all floated directly on ui_layer (like Undo/Redo already were)
	# instead of living in that now-empty bar.

	# Test mode button — only visible if level has foldable furniture
	if not is_instance_valid(_test_btn):
		_test_btn = Button.new()
		_test_btn.name        = "TestBtn"
		_test_btn.text        = "Test Layout"
		_test_btn.toggle_mode = true
		_test_btn.add_theme_font_size_override("font_size", 11)
		_test_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
		_test_btn.toggled.connect(_on_test_toggled)
		_test_btn.visible = false   # updated after level load
		ui_layer.add_child(_test_btn)

	# View-mode switcher: two ways to look at the apartment (see the ViewMode
	# enum comment). Mutually exclusive via a ButtonGroup. Floats stacked
	# directly above the floor-tabs Minimap (see _position_view_mode_box).
	if not is_instance_valid(_view_mode_box):
		var box := HBoxContainer.new()
		box.name = "ViewModeBox"
		box.add_theme_constant_override("separation", 0)
		var group := ButtonGroup.new()
		var specs := [
			[ViewMode.TOPDOWN, "Floor Plan", "Blueprint view — click a highlighted wall edge to inspect it or hang items"],
			[ViewMode.VIEW3D,  "3D",         "Walk around and place items in 3D — drag onto a wall to hang them"],
		]
		for i in specs.size():
			var spec: Array = specs[i]
			var mode: int = spec[0]
			var btn := Button.new()
			btn.name          = "ViewMode%d" % mode
			btn.text          = spec[1]
			btn.tooltip_text  = spec[2]
			btn.toggle_mode   = true
			btn.button_group  = group
			btn.button_pressed = (mode == _view_mode)
			btn.add_theme_font_size_override("font_size", 11)
			# Segmented-control look: one connected pill, only the outer ends
			# rounded, with the active segment filled amber.
			var seg_n := _segment_style(Color(0.175, 0.155, 0.125), GameTheme.C_BORDER, i, specs.size())
			var seg_h := _segment_style(Color(0.19, 0.24, 0.31), GameTheme.C_BORDER, i, specs.size())
			var seg_p := _segment_style(Color(0.42, 0.36, 0.13), GameTheme.C_AMBER, i, specs.size())
			btn.add_theme_stylebox_override("normal",  seg_n)
			btn.add_theme_stylebox_override("hover",   seg_h)
			btn.add_theme_stylebox_override("pressed", seg_p)
			btn.add_theme_stylebox_override("focus",   StyleBoxEmpty.new())
			btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.95, 0.70))
			btn.pressed.connect(_set_view_mode.bind(mode))
			box.add_child(btn)
			_mode_buttons[mode] = btn
		_view_mode_box = box
		ui_layer.add_child(box)

	if not is_instance_valid(_settings_btn):
		_settings_btn = Button.new()
		_settings_btn.name = "SettingsBtn"
		# Icon-only now that it floats in its own corner instead of sitting in
		# a labelled bar — "Menu" spelled out next to a gear was needed there
		# to read as a button at all; alone in the corner the gear reads fine
		# by itself, same as any other icon-only HUD button.
		_settings_btn.text = "⚙"
		_settings_btn.tooltip_text = "Menu — settings, back to projects, quit"
		_settings_btn.add_theme_font_size_override("font_size", 16)
		_settings_btn.custom_minimum_size = Vector2(32, 0)
		_settings_btn.pressed.connect(func(): SettingsMenu.open(self))
		ui_layer.add_child(_settings_btn)

	if not is_instance_valid(_undo_btn):
		_undo_btn = Button.new()
		_undo_btn.name = "UndoBtn"
		_undo_btn.text = "↶"
		_undo_btn.tooltip_text = "Undo last action (Ctrl+%s)" % OS.get_keycode_string(GameState.undo_keycode)
		_undo_btn.add_theme_font_size_override("font_size", 16)
		_undo_btn.custom_minimum_size = Vector2(32, 0)
		_undo_btn.offset_top = TOP_Y + 8.0
		_undo_btn.pressed.connect(_undo_builder_action)
		ui_layer.add_child(_undo_btn)
	if not is_instance_valid(_redo_btn):
		_redo_btn = Button.new()
		_redo_btn.name = "RedoBtn"
		_redo_btn.text = "↷"
		_redo_btn.tooltip_text = "Redo (Ctrl+Shift+%s)" % OS.get_keycode_string(GameState.undo_keycode)
		_redo_btn.add_theme_font_size_override("font_size", 16)
		_redo_btn.custom_minimum_size = Vector2(32, 0)
		_redo_btn.offset_top = TOP_Y + 8.0
		_redo_btn.pressed.connect(_redo_builder_action)
		ui_layer.add_child(_redo_btn)
	_position_top_left_icons()
	_position_undo_btn()
	_position_minimap()
	_refresh_undo_redo_buttons()


# Floats Test Layout and the gear menu in the top-left/top-right corners —
# all that's left up here now that Budget/view-mode/tenant info moved off the
# old full-width TopBar.
func _position_top_left_icons() -> void:
	if is_instance_valid(_test_btn):
		_test_btn.offset_left = LEFT_X + 8.0
		_test_btn.offset_top  = TOP_Y
	if is_instance_valid(_settings_btn):
		_settings_btn.offset_right = RIGHT_X - 8.0
		_settings_btn.offset_left  = _settings_btn.offset_right - (_settings_btn.custom_minimum_size.x as float)
		_settings_btn.offset_top   = TOP_Y


static func _segment_style(bg: Color, border: Color, index: int, count: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.anti_aliasing = true
	s.set_content_margin(SIDE_LEFT, 12)
	s.set_content_margin(SIDE_RIGHT, 12)
	s.set_content_margin(SIDE_TOP, 5)
	s.set_content_margin(SIDE_BOTTOM, 5)
	var r_left := 9 if index == 0 else 0
	var r_right := 9 if index == count - 1 else 0
	s.corner_radius_top_left     = r_left
	s.corner_radius_bottom_left  = r_left
	s.corner_radius_top_right    = r_right
	s.corner_radius_bottom_right = r_right
	return s


func _go_back() -> void:
	# Always Projects — a real player only ever reaches Main via CityMap in
	# the first place, and the menu shouldn't offer (or silently take) a path
	# back into the Level Editor even during a designer's Test Level session.
	Transition.change_scene("res://scenes/CityMap.tscn")


# Discoverable escape hatch for a bad layout (spent the budget on the wrong
# things, boxed furniture in unreachably, etc.) — an incomplete level never
# persists its furniture (GameState only saves a layout on a level a player
# has already won at least once), so this is just _load_level() again, same
# as leaving to Projects and re-entering would already do, minus the detour.
func _restart_level() -> void:
	_load_level(_current_level_id)


func _load_level(level_id: String) -> void:
	_current_level_id  = level_id
	gm.load_level(level_id)
	tenant_card.set_rented(false)
	_post_win_view = false
	Furniture.read_only     = false
	WallInspector.read_only = false
	if is_instance_valid(_mode3d_view):
		_mode3d_view.read_only = false
	inventory.visible = true
	_last_wall_click_by_floor.clear()
	_builder_undo_stack.clear()
	_last_furniture_state = {}
	_restoring_furniture  = true   # level-load spawning shouldn't itself become undoable

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
	_loft_floors.clear()
	_floor_below_id.clear()

	var level: Dictionary = gm.current_level
	var apt_data: Dictionary = level["apartment"] as Dictionary
	var floors_data: Array = apt_data["floors"]
	var apt_gw: int = apt_data.get("grid_w", 40) as int
	var apt_gh: int = apt_data.get("grid_h", 30) as int

	var _floor_z := 0  # accumulates global Z as we walk floors bottom→top
	var _last_floor_fd: Dictionary = {}  # most recent "floor"-type data, for floor-stair openings
	for fd in floors_data:
		var apt_floor: Floor = load("res://scenes/Wall.tscn").instantiate() as Floor
		apt_floor.name = fd["id"]
		room.add_child(apt_floor)
		# grid_w/h live at apartment level now — inject before setup
		(fd as Dictionary)["grid_w"] = apt_gw
		(fd as Dictionary)["grid_h"] = apt_gh
		# Subfloor/ceiling floors have floor_tiles cleared at export time —
		# they borrow the parent floor's tiles so they draw the same outline.
		var _ftype := (fd as Dictionary).get("type", "") as String
		if _ftype in ["floor_sub", "ceiling"] and ((fd as Dictionary).get("floor_tiles", []) as Array).is_empty():
			var _pid := (fd as Dictionary).get("parent_id", "") as String
			for _pfd in floors_data:
				if (_pfd as Dictionary).get("id", "") == _pid:
					(fd as Dictionary)["floor_tiles"] = (_pfd as Dictionary).get("floor_tiles", [])
					break
		# Loft floors inherit from their parent floor:
		#  • floor_tiles    ← parent's mezzanine_tiles
		#  • stair_openings ← parent's loft-targeted stairs only
		#  • segments = []  ← forces _use_new_format = true
		if _ftype == "loft":
			var _lpid := (fd as Dictionary).get("parent_id", "") as String
			for _lpfd in floors_data:
				if (_lpfd as Dictionary).get("id", "") == _lpid:
					(fd as Dictionary)["floor_tiles"] = (_lpfd as Dictionary).get("mezzanine_tiles", [])
					var _all := (_lpfd as Dictionary).get("stairs", []) as Array
					(fd as Dictionary)["stair_openings"] = _all.filter(func(s) -> bool:
						return (s as Dictionary).get("target", "loft") != "floor")
					if not (fd as Dictionary).has("segments"):
						(fd as Dictionary)["segments"] = []
					break
			_floor_below_id[fd["id"]] = _lpid
		# Regular floors above the ground floor get floor-stair openings from the floor below
		elif _ftype == "floor" and not _last_floor_fd.is_empty():
			var _below_stairs := _last_floor_fd.get("stairs", []) as Array
			var _fso := _below_stairs.filter(func(s) -> bool:
				return (s as Dictionary).get("target", "loft") == "floor")
			if not _fso.is_empty():
				if not (fd as Dictionary).has("stair_openings"):
					(fd as Dictionary)["stair_openings"] = []
				((fd as Dictionary)["stair_openings"] as Array).append_array(_fso)
			_floor_below_id[fd["id"]] = _last_floor_fd["id"] as String
		if _ftype == "floor":
			_last_floor_fd = fd
		apt_floor.setup(fd)
		apt_floor.floor_z_offset = _floor_z
		if _ftype == "floor": _floor_z += Floor.FLOOR_HEIGHT_TILES
		apt_floor.furniture_changed.connect(_on_furniture_changed)
		apt_floor.wall_edge_clicked.connect(_on_wall_edge_clicked.bind(apt_floor))
		apt_floor.visible = false
		_floors[fd["id"]] = apt_floor
		if fd["id"] in _floor_below_id:
			apt_floor.below_floor = _floors.get(_floor_below_id[fd["id"]] as String) as Floor

		for sf in fd.get("starting_furniture", []):
			_spawn_furniture(sf["id"], apt_floor, sf["x"], sf["y"], sf as Dictionary)

	# Top-level starting_furniture (from level editor) → place on first ground floor
	var first_floor_node: Floor = null
	for _ffd in floors_data:
		if (_ffd as Dictionary).get("type", "") == "floor":
			var _ffid := (_ffd as Dictionary)["id"] as String
			if _ffid in _floors:
				first_floor_node = _floors[_ffid] as Floor
				break
	if first_floor_node and not gm.starting_furniture.is_empty():
		for sf in gm.starting_furniture:
			_spawn_furniture((sf as Dictionary)["id"] as String,
				first_floor_node,
				(sf as Dictionary)["x"] as int,
				(sf as Dictionary)["y"] as int,
				sf as Dictionary)

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
	_position_minimap()
	_active_moment_id = ""
	Furniture.test_mode_active = false
	Furniture.active_moment_id = ""
	tenant_card.setup(level["tenant"])
	tenant_card.setup_moments(gm.moments)
	if not gm.moments.is_empty():
		var _first_mid := (gm.moments[0] as Dictionary)["id"] as String
		_on_moment_selected(_first_mid)
	inventory.setup(gm)
	var shop_list: Array = gm.furniture_data["furniture"]
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

	# Update test button visibility now that floors are loaded.
	# Levels with moments drive fold interaction via the moment selector instead —
	# the manual Test Layout toggle would be redundant there.
	if is_instance_valid(_test_btn):
		_test_btn.visible = _has_foldable_furniture() and gm.moments.is_empty()

	# "Revisar Plano Actual" — CityMap sets this one-shot flag right before
	# switching scenes when the player picks up a previously-won level instead
	# of a fresh one. Consumed here regardless of outcome so it never leaks
	# into the next level load.
	var _use_saved := GameState.pending_use_saved_layout
	GameState.pending_use_saved_layout = false
	if _use_saved and GameState.has_level_layout(level_id):
		_restore_furniture_snapshot(GameState.get_level_layout(level_id))
	else:
		_restoring_furniture  = false
		_last_furniture_state = _snapshot_all_furniture()

	# _set_view_mode is normally only triggered by clicking a mode button —
	# applying it once here makes the default mode's layout (hidden/docked
	# Wall Inspector, 3D pane, divider) actually match on first load instead
	# of relying on whatever Main.tscn's static node visibility happens to be.
	_set_view_mode(_view_mode)

	var paintable := gm.current_level.get("paintable_furniture", []) as Array
	if not paintable.is_empty():
		_build_paint_panel(paintable)

	_show_mechanic_intro_if_needed()
	_refresh_undo_redo_buttons()


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
	_intro_modal_open = true
	cl.tree_exited.connect(func(): _intro_modal_open = false)

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.05, 0.09, 0.88)
	bg.size  = Vector2(1280, 720)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	cl.add_child(bg)

	# Card panel (480×300, centred)
	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color     = Color(0.115, 0.100, 0.085)
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
	chip.add_theme_color_override("font_color", Color(0.120, 0.100, 0.080))
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

	# Also dismiss on click outside card (a real click, not a wheel tick —
	# InputEventMouseButton covers both, and wheel scroll must never dismiss
	# or otherwise affect anything behind this modal)
	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			cl.queue_free())


func _spawn_furniture(furniture_id: String, apt_floor: Floor, gx: int, gy: int, rail_data: Dictionary = {}) -> Furniture:
	var fdata := gm.get_furniture_by_id(furniture_id)
	if fdata.is_empty():
		return null
	# Apply per-instance rail overrides (axis + extents set by level editor)
	var rail_keys := ["rail_axis", "rail_start", "rail_end", "reveal_start", "reveal_end", "reveal_functions"]
	for key in rail_keys:
		if rail_data.has(key):
			fdata = fdata.duplicate()
			break
	for key in rail_keys:
		if rail_data.has(key):
			fdata[key] = rail_data[key]
	var f: Furniture = FurnitureScene.instantiate() as Furniture
	apt_floor.add_child(f)
	f.setup(fdata, apt_floor)
	# Trust the explicit coordinates from the level editor; skip can_place so the
	# furniture lands exactly where the designer placed it regardless of floor-tile
	# bounds checks (the editor validated the position visually).
	apt_floor.place_furniture(f, Vector2i(gx, gy))
	f.sell_requested.connect(_on_sell_pressed.bind(apt_floor))
	f.fold_toggled.connect(_refresh_functions)
	f.fold_toggled.connect(_on_furniture_action_changed)
	f.placed.connect(func(_n): _on_furniture_action_changed())
	if f.rail_axis != "":
		f.placed.connect(func(_n): _refresh_functions())
	if fdata.get("creates_loft", false):
		_promote_to_loft(f, apt_floor)
	return f


# ─── Runtime loft/mezzanine floors ────────────────────────────────────────────
# Loft/bunk beds carve out a mezzanine: the bed itself moves onto its own
# navigable "loft" floor (so it can be furnished around, from above), while the
# base floor keeps only a mezzanine-tile shadow marking where the slab sits —
# freeing those tiles for other furniture (desk, sofa, wardrobe...) underneath.

func _get_or_create_loft_floor(base_floor: Floor) -> Floor:
	var loft_id := base_floor.floor_id + "_loft"
	if loft_id in _floors and is_instance_valid(_floors[loft_id]):
		return _floors[loft_id] as Floor

	var floor_tiles: Array = []
	if not base_floor.floor_mask.is_empty():
		for t in base_floor.floor_mask:
			floor_tiles.append([(t as Vector2i).x, (t as Vector2i).y])
	else:
		var b := base_floor.get_room_bounds()
		for x in range(b.position.x, b.position.x + b.size.x):
			for y in range(b.position.y, b.position.y + b.size.y):
				floor_tiles.append([x, y])

	# Perimeter segments so wall edges can be clicked/inspected like any other floor
	var rb := base_floor.get_room_bounds()
	var rx0 := rb.position.x; var ry0 := rb.position.y
	var rx1 := rb.position.x + rb.size.x; var ry1 := rb.position.y + rb.size.y
	var loft_segments := [
		{"x1": rx0, "y1": ry0, "x2": rx1, "y2": ry0, "primary": true, "demolished": false},
		{"x1": rx1, "y1": ry0, "x2": rx1, "y2": ry1, "primary": true, "demolished": false},
		{"x1": rx1, "y1": ry1, "x2": rx0, "y2": ry1, "primary": true, "demolished": false},
		{"x1": rx0, "y1": ry1, "x2": rx0, "y2": ry0, "primary": true, "demolished": false},
	]

	var fd := {
		"id": loft_id,
		"label": base_floor.floor_label + " (Loft)",
		"type": "loft",
		"parent_id": base_floor.floor_id,
		"grid_w": base_floor.grid_w,
		"grid_h": base_floor.grid_h,
		"floor_tiles": floor_tiles,
		"segments": loft_segments,
	}

	var loft_floor: Floor = load("res://scenes/Wall.tscn").instantiate() as Floor
	loft_floor.name = loft_id
	room.add_child(loft_floor)
	loft_floor.setup(fd)
	loft_floor.floor_z_offset = base_floor.floor_z_offset + Floor.FLOOR_HEIGHT_TILES / 2
	loft_floor.furniture_changed.connect(_on_furniture_changed)
	loft_floor.furniture_changed.connect(_on_loft_furniture_changed.bind(base_floor, loft_floor))
	loft_floor.wall_edge_clicked.connect(_on_wall_edge_clicked.bind(loft_floor))
	loft_floor.visible = false
	_floors[loft_id] = loft_floor
	_loft_floors[base_floor.floor_id] = loft_floor

	if _floor_tile_bounds.has(base_floor.floor_id):
		_floor_tile_bounds[loft_id] = _floor_tile_bounds[base_floor.floor_id]
	else:
		_floor_tile_bounds[loft_id] = base_floor.get_room_bounds()

	minimap.add_floor({"id": loft_id, "label": fd["label"]}, base_floor.floor_id)
	_position_minimap()
	return loft_floor


func _promote_to_loft(f: Furniture, base_floor: Floor) -> void:
	var loft_floor := _get_or_create_loft_floor(base_floor)
	var at := f.grid_pos
	if not loft_floor.can_place(f, at):
		return  # leave it on the base floor rather than risk an overlap up top

	base_floor._remove_from_grid(f)
	base_floor.remove_child(f)
	loft_floor.add_child(f)
	f._wall_ref = loft_floor
	loft_floor.place_furniture(f, at)

	if f.sell_requested.is_connected(_on_sell_pressed.bind(base_floor)):
		f.sell_requested.disconnect(_on_sell_pressed.bind(base_floor))
	f.sell_requested.connect(_on_sell_pressed.bind(loft_floor))


func _sync_loft_masks(base_floor: Floor, loft_floor: Floor) -> void:
	var tiles: Dictionary = {}
	for item in loft_floor.get_all_furniture():
		var f := item as Furniture
		var fdata := gm.get_furniture_by_id(f.furniture_id)
		if fdata.get("creates_loft", false):
			for t in f.get_occupied_tiles():
				tiles[t] = true
	base_floor.mezzanine_mask = tiles.duplicate()
	if base_floor.grid_draw:
		base_floor.grid_draw.queue_redraw()
	if tiles.is_empty():
		_remove_loft_floor(base_floor)


func _remove_loft_floor(base_floor: Floor) -> void:
	var loft_id := base_floor.floor_id + "_loft"
	if not (loft_id in _floors):
		return
	var loft_floor := _floors[loft_id] as Floor
	if not loft_floor.get_all_furniture().is_empty():
		return
	if _current_floor_id == loft_id:
		_switch_floor(base_floor.floor_id)
	_floors.erase(loft_id)
	_loft_floors.erase(base_floor.floor_id)
	_floor_tile_bounds.erase(loft_id)
	minimap.remove_floor(loft_id)
	loft_floor.queue_free()


func _on_loft_furniture_changed(base_floor: Floor, loft_floor: Floor) -> void:
	_sync_loft_masks(base_floor, loft_floor)


func _switch_floor(floor_id: String) -> void:
	if _current_floor_id in _floors:
		(_floors[_current_floor_id] as Floor).visible = false
	_current_floor_id = floor_id
	if floor_id in _floors:
		var apt_floor := _floors[floor_id] as Floor
		apt_floor.visible = true
		_fit_floor(apt_floor, true)
	minimap.highlight(floor_id)
	# The 2D `room` node's per-floor visibility toggle above does nothing for
	# the 3D view — it only ever shows whatever floor it was last built from,
	# so switching floor tabs (e.g. base <-> the loft a bunk/loft bed creates)
	# while already in 3D mode silently kept showing the stale floor. Rebuild
	# it for the newly-selected floor.
	if _view_mode == ViewMode.VIEW3D:
		_ensure_mode3d_view()


# Recomputes the "fit to view" baseline (scale/position) for the given floor.
# `reset_view`: true on an actual floor switch (snaps back to fit, clearing
# any manual zoom/pan); false when only the available width changed (e.g.
# dragging the floor/wall split), which re-fits without losing the player's
# current zoom/pan.
func _fit_floor(apt_floor: Floor, reset_view: bool = false) -> void:
	const H_PAD  := 32.0
	const V_PAD  := 24.0
	const PAD_T  := 3     # tile padding around apartment content

	var avail_w := (RIGHT_X - LEFT_X) - H_PAD * 2
	var avail_h := (_floor_pane_bottom_y() - TOP_Y) - V_PAD * 2

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

	_base_scale    = s
	_base_position = Vector2(
		LEFT_X + H_PAD + (avail_w - fw * s) * 0.5 - off_x * s,
		TOP_Y + V_PAD + (avail_h - fh * s) * 0.5 - off_y * s
	)
	if reset_view:
		_manual_zoom = 1.0
		_manual_pan  = Vector2.ZERO
	_apply_room_transform()


func _apply_room_transform() -> void:
	var total := _base_scale * _manual_zoom
	room.scale    = Vector2(total, total)
	room.position = _base_position + _manual_pan


# ── Floor plan / docked-panel split divider drag ───────────────────────────
func _on_divider_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_dragging_divider = (event as InputEventMouseButton).pressed


func _update_split(y: float) -> void:
	_split_y = clampf(y, MIN_SPLIT_Y, MAX_SPLIT_Y)
	var fl := _floors.get(_current_floor_id) as Floor
	if fl:
		_fit_floor(fl, false)
	_position_undo_btn()
	_position_minimap()


# Pins the floor-tab stack to the bottom-right corner of the play area, just
# left of the floating TenantCard column (same right_edge math as the Undo/
# Redo buttons). Sized generously tall and bottom-aligned (see Minimap.gd's
# set_compact) so it stays flush with that corner whether the level has 2
# floors or 6, instead of resizing itself and drifting around.
func _position_minimap() -> void:
	if not is_instance_valid(minimap):
		return
	_position_tenant_card()
	# Stacked bottom-right, directly above the TenantCard bar now that it
	# spans the bottom edge instead of sitting in a right-hand column.
	var right_edge := RIGHT_X - 8.0
	minimap.offset_right  = right_edge
	minimap.offset_left   = right_edge - 100.0
	# Shrink-wrapped to however many floor buttons the current level actually
	# has (reset_size() forces a fresh layout pass first) — a fixed tall box
	# left a big empty panel above a short 2-floor stack.
	minimap.reset_size()
	var content_h := maxf(minimap.size.y, 40.0)
	minimap.offset_bottom = tenant_card.offset_top - 8.0
	minimap.offset_top    = minimap.offset_bottom - content_h
	ui_layer.move_child(minimap, ui_layer.get_child_count() - 1)
	_position_view_mode_box()


# TenantCard is now a bottom status bar (moments/needs + Budget) spanning the
# play area's width, instead of a floating right-hand column — sized to
# whatever height its own content needs (like Minimap's shrink-wrap below).
func _position_tenant_card() -> void:
	if not is_instance_valid(tenant_card):
		return
	tenant_card.offset_left  = LEFT_X
	tenant_card.offset_right = RIGHT_X
	# NOT reset_size() here — unlike Minimap/ViewModeBox (which want to shrink
	# to their natural content width), this bar's whole point is to STAY the
	# full LEFT_X..RIGHT_X width. reset_size() calls size = Vector2(), and
	# Control's size setter always recomputes offset_right from offset_left +
	# minimum width — silently overwriting the RIGHT_X just set above and
	# collapsing the bar down to a tiny shrink-wrapped cluster (which also
	# forced the checklist to wrap into extra rows it then had no height
	# budget for, clipping off the bottom of the screen).
	# get_combined_minimum_size() alone re-measures children at the CURRENT
	# (already-fixed-width) rect without touching offsets.
	var content_h := maxf(tenant_card.get_combined_minimum_size().y, 36.0)
	tenant_card.offset_bottom = BOT_Y - 8.0
	tenant_card.offset_top    = BOT_Y - 8.0 - content_h


# The Floor Plan/3D segmented toggle floats directly above the Minimap floor
# tabs, same right edge, now that both moved off the old TopBar.
func _position_view_mode_box() -> void:
	if not is_instance_valid(_view_mode_box):
		return
	# Same approach as _position_minimap(): fix left/right BEFORE reset_size()
	# (which recomputes size from offset_left, so reading offset_right back
	# out afterward isn't reliable) and only use the post-reset_size() height.
	var right_edge := RIGHT_X - 8.0
	_view_mode_box.offset_right = right_edge
	_view_mode_box.offset_left  = right_edge - 180.0
	_view_mode_box.reset_size()
	var content_h := maxf(_view_mode_box.size.y, 24.0)
	_view_mode_box.offset_bottom = minimap.offset_top - 8.0
	_view_mode_box.offset_top    = _view_mode_box.offset_bottom - content_h
	ui_layer.move_child(_view_mode_box, ui_layer.get_child_count() - 1)


# Keeps the floating Undo/Redo buttons pinned to the top-right corner of the
# play area, just left of the gear menu button (both float independently now
# that the old full-width TopBar is gone).
func _position_undo_btn() -> void:
	if not is_instance_valid(_undo_btn):
		return
	var right_edge := RIGHT_X - 8.0
	if is_instance_valid(_settings_btn):
		right_edge = _settings_btn.offset_left - 8.0
	_undo_btn.offset_right = right_edge
	_undo_btn.offset_left  = right_edge - (_undo_btn.custom_minimum_size.x as float)
	_undo_btn.offset_top   = TOP_Y
	# The 3D view (and other full-width overlays) get added to ui_layer after
	# this button, which would otherwise draw over it and block its clicks.
	ui_layer.move_child(_undo_btn, ui_layer.get_child_count() - 1)
	if is_instance_valid(_redo_btn):
		_redo_btn.offset_right = _undo_btn.offset_left - 6.0
		_redo_btn.offset_left  = _redo_btn.offset_right - (_redo_btn.custom_minimum_size.x as float)
		_redo_btn.offset_top   = _undo_btn.offset_top
		ui_layer.move_child(_redo_btn, ui_layer.get_child_count() - 1)


# ── View mode switcher ──────────────────────────────────────────────────────
func _set_view_mode(mode: int) -> void:
	# Switching is still allowed during post-win "View Apartment" — the player
	# should be able to look at the Floor Plan/Wall view same as 3D, just not
	# edit anything there. Furniture.read_only/WallInspector.read_only (set
	# alongside _post_win_view) are what actually lock out editing in those
	# views; this function only ever controls which view is showing.
	_view_mode = mode
	for m in _mode_buttons:
		(_mode_buttons[m] as Button).button_pressed = (m == mode)

	match mode:
		ViewMode.TOPDOWN:
			_teardown_mode3d_view()
			room.visible    = true
			divider.visible = false
			# `.visible` stays true for the idle placeholder panel too (it's only
			# ever hidden by its own close button) — is_showing_wall() is the
			# actual "a wall is open" check, otherwise the modal+backdrop would
			# cover the top-down plan immediately on switching into this mode.
			if wall_inspector.is_showing_wall():
				_position_wall_inspector_modal()
				_set_mode_hint("")
			else:
				wall_inspector.hide()
				_hide_modal_backdrop()
				_set_mode_hint("Click a highlighted wall edge on the plan to inspect it or hang items")
		ViewMode.VIEW3D:
			# Wall items are placed/moved directly in the 3D view here (drag onto
			# a wall) — there's no 2D Wall Inspector panel in this mode at all.
			room.visible    = false
			divider.visible = false
			wall_inspector.hide()
			_hide_modal_backdrop()
			_ensure_mode3d_view()
			_set_mode_hint("Drop items on the floor, or drag them onto a wall to hang them · Press R to rotate")

	var fl := _floors.get(_current_floor_id) as Floor
	if fl and mode != ViewMode.VIEW3D:
		_fit_floor(fl, false)
	_position_undo_btn()
	_position_minimap()


# Persistent 3D view used by VIEW3D mode — distinct from the quick full-screen
# "reveal" opened by the 3D-view TopBar button, which stays a one-off overlay.
# This one fits the same TOP_Y..BOT_Y band the 2D floor plan normally uses, so
# budget/inventory/tenant-needs stay visible and usable while working in 3D.
func _ensure_mode3d_view() -> void:
	var fl := _floors.get(_current_floor_id) as Floor
	if not fl:
		return
	if not is_instance_valid(_mode3d_view):
		_mode3d_view = Room3DViewScene.instantiate()
		ui_layer.add_child(_mode3d_view)
		_mode3d_view.anchor_left   = 0.0
		_mode3d_view.anchor_top    = 0.0
		_mode3d_view.anchor_right  = 0.0
		_mode3d_view.anchor_bottom = 0.0
		if _mode3d_view.has_node("CloseBtn"):
			(_mode3d_view.get_node("CloseBtn") as Control).visible = false
		_mode3d_view.sell_requested.connect(_on_sell_pressed.bind(fl))
		_mode3d_view.wall_sell_requested.connect(_on_wall_sell_pressed.bind(fl))
		_mode3d_view.furniture_moved.connect(func(_f): _on_furniture_action_changed())
	_mode3d_view.offset_left   = LEFT_X
	_mode3d_view.offset_top    = TOP_Y
	_mode3d_view.offset_right  = RIGHT_X
	_mode3d_view.offset_bottom = BOT_Y
	var below_floor: Floor = null
	if fl.floor_id in _floor_below_id:
		below_floor = _floors.get(_floor_below_id[fl.floor_id] as String) as Floor
	# _teardown_mode3d_view() (called when switching to Floor Plan) frees this
	# node entirely — switching back to 3D recreates it from scratch, which
	# would otherwise silently reset read_only to its default (false) and
	# reopen editing/selling the instant you tabbed away and back during
	# post-win "View Apartment".
	_mode3d_view.read_only = _post_win_view
	_mode3d_view.build_from_floor(fl, gm.furniture_data["furniture"], below_floor)
	# The 3D view's rect fully contains TenantCard's corner (both are direct
	# UI children), so appending it here — same CanvasLayer, later sibling —
	# would otherwise draw over the card and hide it completely. Re-assert
	# TenantCard (and, via _position_undo_btn, Undo/Redo) above it every time,
	# regardless of which of this function's several callers triggered the
	# (re)build.
	ui_layer.move_child(tenant_card, ui_layer.get_child_count() - 1)
	# Inventory's declared width (LEFT_X = 170px) is only its anchor offset —
	# it actually grows past that to fit content (item tooltips, Builder-tab
	# shop rows with a price pill + Buy button, ...), which the 3D view's
	# rect (starting at LEFT_X) then overlapped and hid. Same fix as
	# TenantCard above: keep Inventory the topmost sibling so its overflow —
	# and the Buy button on it — stays visible and clickable in 3D mode.
	ui_layer.move_child(inventory, ui_layer.get_child_count() - 1)
	_position_undo_btn()
	_position_minimap()


func _teardown_mode3d_view() -> void:
	if is_instance_valid(_mode3d_view):
		_mode3d_view.queue_free()
	_mode3d_view = null


# TOPDOWN shows the Wall Inspector as a centered modal (with a dismiss-on-tap
# backdrop) rather than a docked panel — VIEW3D handles walls directly in the
# 3D pane instead (drag onto a wall), so this modal only ever appears in
# TOPDOWN mode.
func _position_wall_inspector_modal() -> void:
	if not is_instance_valid(_modal_backdrop):
		_modal_backdrop = ColorRect.new()
		_modal_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
		_modal_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
		_modal_backdrop.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
				wall_inspector.close_btn.pressed.emit())
		ui_layer.add_child(_modal_backdrop)
		ui_layer.move_child(_modal_backdrop, wall_inspector.get_index())
	_modal_backdrop.offset_left   = 0.0
	_modal_backdrop.offset_top    = 0.0
	_modal_backdrop.offset_right  = SCREEN_W
	_modal_backdrop.offset_bottom = BOT_Y
	_modal_backdrop.visible = true

	# Size the modal to the wall's actual aspect ratio instead of a fixed
	# 760x480 box — a fixed box left tall, empty letterboxing on whichever
	# side didn't match the wall's proportions, and dominated the screen even
	# for a small wall, hiding the top-down plan behind it for no reason.
	const MAX_MW := 720.0
	const MAX_MH := 420.0
	const MIN_MW := 380.0
	const MIN_MH := 220.0
	const PAD := 40.0   # room for title bar + panel margins
	var content_w: float = wall_inspector._wall_w() * WallInspector.TILE_SIZE
	var content_h: float = WallInspector.WALL_HEIGHT * WallInspector.TILE_SIZE
	var fit := minf((MAX_MW - PAD) / content_w, (MAX_MH - PAD) / content_h)
	fit = minf(fit, 2.0)   # never blow up a tiny wall to fill the whole box either
	var MW := clampf(content_w * fit + PAD, MIN_MW, MAX_MW)
	var MH := clampf(content_h * fit + PAD, MIN_MH, MAX_MH)
	var center_x := (LEFT_X + RIGHT_X) * 0.5
	wall_inspector.offset_left   = center_x - MW * 0.5
	wall_inspector.offset_bottom = BOT_Y - 20.0
	wall_inspector.offset_right  = center_x + MW * 0.5
	wall_inspector.offset_top    = BOT_Y - 20.0 - MH


func _hide_modal_backdrop() -> void:
	if is_instance_valid(_modal_backdrop):
		_modal_backdrop.visible = false


# Neither mode has a permanent docked Wall Inspector to hint at wall access
# — this small banner fills that gap. Empty text hides it (used whenever a
# wall is already open, or in VIEW3D where the hint text says something else).
func _set_mode_hint(text: String) -> void:
	if text == "":
		if is_instance_valid(_mode_hint_lbl):
			_mode_hint_lbl.visible = false
		return
	if not is_instance_valid(_mode_hint_lbl):
		_mode_hint_lbl = Label.new()
		_mode_hint_lbl.add_theme_font_size_override("font_size", 12)
		_mode_hint_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
		_mode_hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_mode_hint_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui_layer.add_child(_mode_hint_lbl)
	_mode_hint_lbl.text = text
	_mode_hint_lbl.offset_left   = LEFT_X
	_mode_hint_lbl.offset_right  = RIGHT_X
	_mode_hint_lbl.offset_top    = TOP_Y + 14.0
	_mode_hint_lbl.offset_bottom = TOP_Y + 34.0
	_mode_hint_lbl.visible = true
	ui_layer.move_child(_mode_hint_lbl, ui_layer.get_child_count() - 1)


# Right-click removal of a wall-mounted item dropped directly in the 3D view —
# mirrors WallInspector._remove_wall_at (no refund, matching that 2D behavior).
func _on_wall_sell_pressed(edge: String, origin: Vector2i, apt_floor: Floor) -> void:
	apt_floor.remove_wall_item(edge, origin)
	_refresh_functions()


# ── Floor plan zoom (mouse wheel) / pan (middle-drag) ──────────────────────
# The plan is always the full window now — TOPDOWN is the only mode that
# shows it at all (VIEW3D hides it entirely).
func _floor_pane_right_x() -> float:
	return RIGHT_X


func _floor_pane_bottom_y() -> float:
	return BOT_Y


# Any full-screen modal that should freeze zoom/pan everywhere while it's up:
# the "NEW MECHANIC" intro card, the Wall Inspector's modal backdrop (Top-Down
# mode), and the win/fail result screen.
func _blocking_modal_open() -> bool:
	return _intro_modal_open \
		or (is_instance_valid(_modal_backdrop) and _modal_backdrop.visible) \
		or result_screen.visible


func _handle_view_input(event: InputEvent) -> void:
	# The 3D view and the Top-Down modal's Wall Inspector each own independent
	# zoom/camera state (Room3DView._dist, WallInspector._zoom) — never let the
	# floor-plan zoom (_manual_zoom) react to scroll/pan meant for those views.
	if _view_mode == ViewMode.VIEW3D:
		return
	if _blocking_modal_open():
		return
	if event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		var in_bounds := mbe.position.x > LEFT_X and mbe.position.x < _floor_pane_right_x() and mbe.position.y > TOP_Y and mbe.position.y < _floor_pane_bottom_y()
		if mbe.button_index == MOUSE_BUTTON_WHEEL_UP and mbe.pressed and in_bounds:
			_zoom_floor(0.15, mbe.position)
		elif mbe.button_index == MOUSE_BUTTON_WHEEL_DOWN and mbe.pressed and in_bounds:
			_zoom_floor(-0.15, mbe.position)
		elif mbe.button_index == MOUSE_BUTTON_MIDDLE:
			_panning_floor = mbe.pressed and in_bounds
	elif event is InputEventMouseMotion and _panning_floor:
		_manual_pan += (event as InputEventMouseMotion).relative
		_apply_room_transform()


func _zoom_floor(delta: float, cursor_pos: Vector2) -> void:
	var old_total := _base_scale * _manual_zoom
	_manual_zoom = clampf(_manual_zoom + delta, MIN_MANUAL_ZOOM, MAX_MANUAL_ZOOM)
	var new_total := _base_scale * _manual_zoom
	if new_total == old_total:
		return
	# Keep the point under the cursor fixed while zooming
	var focus_world := (cursor_pos - room.position) / old_total
	room.position  = cursor_pos - focus_world * new_total
	room.scale     = Vector2(new_total, new_total)
	_manual_pan    = room.position - _base_position


func _on_wall_edge_clicked(edge: String, span_lo: int, span_hi: int, apt_floor: Floor) -> void:
	for fid in _floors:
		var fl := _floors[fid] as Floor
		fl.set_active_wall_edge("" if fl != apt_floor else edge)
	# Remembered per floor (not globally) so the "W" shortcut reopens the
	# wall that was actually last inspected on whichever floor you're
	# currently looking at, not wherever you happened to click last overall.
	_last_wall_click_by_floor[apt_floor.floor_id] = {
		"edge": edge, "span_lo": span_lo, "span_hi": span_hi,
	}
	# Clicking a wall edge jumps into the 3D view — replaces the old 2D Wall
	# Inspector modal entirely. VIEW3D already handles walls directly (drag
	# items onto them) with no 2D panel at all. There's no scripted camera
	# orbit onto the specific wall (removed — needed constant per-room tuning
	# and free orbiting already covers the same need); players position
	# themselves manually from here.
	if _view_mode != ViewMode.VIEW3D:
		_set_view_mode(ViewMode.VIEW3D)


# Up/W and Down/S shortcuts — step to the floor directly above/below in the
# same order the Minimap tabs show, so the shortcut always matches what
# clicking a tab would do (including dynamically added loft floors).
func _step_floor(direction: int) -> void:
	var order := minimap.get_floor_order()
	var idx := order.find(_current_floor_id)
	if idx == -1:
		return
	var next_idx := idx + direction
	if next_idx < 0 or next_idx >= order.size():
		return
	_switch_floor(order[next_idx] as String)


# Left/A and Right/D shortcuts — step to the previous/next moment tab.
func _step_moment(direction: int) -> void:
	if gm.moments.is_empty():
		return
	var idx := -1
	for i in range(gm.moments.size()):
		if (gm.moments[i] as Dictionary).get("id", "") == _active_moment_id:
			idx = i
			break
	var next_idx: int = clampi((idx if idx != -1 else 0) + direction, 0, gm.moments.size() - 1)
	var next_id := (gm.moments[next_idx] as Dictionary).get("id", "") as String
	if next_id != "":
		_on_moment_selected(next_id)


# "Q" shortcut — reopen (or re-focus, now that wall clicks jump into 3D) the
# last wall inspected on the current floor, without having to re-find and
# re-click the same edge on the plan. Works from either view mode now: there's
# no separate 2D wall state to be "already in" any more.
func _reopen_last_wall() -> void:
	var last := _last_wall_click_by_floor.get(_current_floor_id, {}) as Dictionary
	if last.is_empty():
		_set_mode_hint("No wall inspected on this floor yet")
		return
	var apt_floor := _floors.get(_current_floor_id) as Floor
	if not apt_floor:
		return
	_on_wall_edge_clicked(last["edge"] as String, last["span_lo"] as int, last["span_hi"] as int, apt_floor)


func _on_inspector_visibility_changed() -> void:
	if not wall_inspector.visible:
		for fid in _floors:
			(_floors[fid] as Floor).set_active_wall_edge("")
		_hide_modal_backdrop()
		if _view_mode == ViewMode.TOPDOWN:
			_set_mode_hint("Click a highlighted wall edge on the plan to inspect it or hang items")


func _on_wall_item_placed(furniture_id: String) -> void:
	gm.buy_furniture(furniture_id)
	# The wall placement won — cancel the parallel floor-placement ghost so it
	# doesn't linger following the mouse (and can't be placed a second time for free).
	if is_instance_valid(_pending_floor_ghost):
		_pending_floor_ghost.cancel_placement()
	_pending_floor_ghost = null
	_refresh_functions()


func _on_buy_requested(furniture_id: String) -> void:
	var apt_floor := _floors.get(_current_floor_id) as Floor
	if not apt_floor:
		return
	var fdata := gm.get_furniture_by_id(furniture_id)
	if fdata.is_empty():
		return
	if gm.budget < (fdata.get("buy_price", 0) as int):
		return
	# Every item can go on the floor or on a wall — arm both placements at once.
	# Whichever the player actually clicks into completes the purchase; the other
	# is cancelled automatically.
	var f: Furniture = FurnitureScene.instantiate() as Furniture
	apt_floor.add_child(f)
	f.setup(fdata, apt_floor)
	f.sell_requested.connect(_on_sell_pressed.bind(apt_floor))
	f.fold_toggled.connect(_refresh_functions)
	f.fold_toggled.connect(_on_furniture_action_changed)
	f.placed.connect(func(_n): _on_furniture_action_changed())   # repositioning-drag commits
	if f.rail_axis != "":
		f.placed.connect(func(_n): _refresh_functions())

	if _view_mode == ViewMode.VIEW3D and is_instance_valid(_mode3d_view):
		# 3D-primary mode: the floor ghost (`f`) is armed, but the player can
		# just as easily drop the item on a wall instead — Room3DView decides
		# which happened and fires the matching signal below. There's no 2D
		# floor plan or Wall Inspector on screen to race against here.
		#
		# The three handlers below disconnect each other once one of them
		# fires. GDScript locals declared with `var` and reassigned via
		# `x = func(): ...` do NOT reliably close over each other by live
		# reference when a lambda refers to a sibling var assigned later (or
		# to itself) in the same statement block — a `Dictionary` is used as
		# a shared mutable box instead, since its *contents* are looked up at
		# call time rather than captured at closure-creation time.
		var h := {}
		h["confirmed"] = func(_f: Furniture):
			_mode3d_view.buy_confirmed_wall.disconnect(h["wall_confirmed"])
			_mode3d_view.buy_cancelled.disconnect(h["cancelled"])
			gm.buy_furniture(furniture_id)
			if fdata.get("creates_loft", false):
				_promote_to_loft(f, apt_floor)
			_refresh_functions()
			_on_furniture_action_changed()
		h["wall_confirmed"] = func(_fid: String, _edge: String, _origin: Vector2i):
			_mode3d_view.buy_confirmed.disconnect(h["confirmed"])
			_mode3d_view.buy_cancelled.disconnect(h["cancelled"])
			f.queue_free()   # the floor ghost was never used — it landed on a wall instead
			gm.buy_furniture(furniture_id)
			_refresh_functions()
			_on_furniture_action_changed()
		h["cancelled"] = func(_f: Furniture):
			_mode3d_view.buy_confirmed.disconnect(h["confirmed"])
			_mode3d_view.buy_confirmed_wall.disconnect(h["wall_confirmed"])
			f.queue_free()
			_refresh_functions()
		_mode3d_view.buy_confirmed.connect(h["confirmed"], CONNECT_ONE_SHOT)
		_mode3d_view.buy_confirmed_wall.connect(h["wall_confirmed"], CONNECT_ONE_SHOT)
		_mode3d_view.buy_cancelled.connect(h["cancelled"], CONNECT_ONE_SHOT)
		_mode3d_view.start_buying(f, fdata)
	else:
		f.placement_confirmed.connect(func():
			gm.buy_furniture(furniture_id)
			_pending_floor_ghost = null
			wall_inspector.cancel_selection()
			if fdata.get("creates_loft", false):
				_promote_to_loft(f, apt_floor)
			_refresh_functions()
			_on_furniture_action_changed())
		f.placement_cancelled.connect(func():
			_pending_floor_ghost = null
			_refresh_functions())
		f.begin_placement(apt_floor, get_viewport().get_mouse_position())
		_pending_floor_ghost = f
		if wall_inspector.is_showing_wall():
			wall_inspector.select_item(furniture_id)

	_refresh_functions()


func _on_sell_pressed(furniture: Furniture, apt_floor: Floor) -> void:
	Audio.play("sell")
	gm.sell_furniture(furniture.furniture_id)
	apt_floor.remove_furniture(furniture)
	# This handler also runs for a sale initiated in 3D itself (Room3DView's
	# own sell_requested), where it's already dropped from _furniture_entries —
	# but a 2D-initiated sale never told the (separately cached, persistent)
	# 3D view's render cache, leaving a stale entry pointing at the now-freed
	# node that crashed the next time the 3D view hit-tested near it.
	if is_instance_valid(_mode3d_view):
		_mode3d_view.remove_furniture_entry(furniture)
	_refresh_functions()
	_on_furniture_action_changed()   # push pre-sell state, cache the new post-sell state


func _on_furniture_changed() -> void:
	_refresh_functions()
	_update_floor_locks()
	_update_accessibility()
	# NOTE: deliberately NOT hooking undo-tracking here — this signal also
	# fires during an uncommitted 2D buy ghost-preview (set_floor_drag_ghost),
	# once per mouse-move, which flooded the undo stack with intermediate
	# states and could even crash (a snapshot taken mid-drag over some other
	# not-yet-settled furniture). Undo tracking hooks the precise, one-shot
	# signals instead: placement_confirmed, placed, fold_toggled, plus
	# explicit calls around sell and the 3D buy/move paths.


func _refresh_functions() -> void:
	# Floor items are passed as live Furniture nodes so foldable pieces report
	# their REAL current state (folded/extended), not just what they're capable
	# of. Wall items have no live node, so they stay id-based.
	var all_entries: Array = []
	for fid in _floors:
		var fl := _floors[fid] as Floor
		all_entries += fl.get_all_furniture()
		all_entries += fl.get_all_wall_item_ids()
	var extra_fns: Array = []
	for floor_id in _paint_pieces:
		for type_id in _paint_pieces[floor_id]:
			var piece := _paint_pieces[floor_id][type_id] as PaintedFurniture
			if is_instance_valid(piece) and piece.is_valid():
				for fn in piece.functions:
					if fn not in extra_fns:
						extra_fns.append(fn)
	var free_tiles_by_moment: Dictionary = {}
	for m in gm.moments:
		var mid := (m as Dictionary)["id"] as String
		var total := 0
		for fid in _floors:
			var fl := _floors[fid] as Floor
			# Only real navigable floors — skip ceiling/subfloor/roof layers,
			# which have no real footprint and would otherwise fall back to
			# the full apartment grid size.
			if fl.floor_type in ["floor", "loft"]:
				total += fl.count_free_tiles_for_moment(mid)
		free_tiles_by_moment[mid] = total
	gm.update_functions(all_entries, extra_fns, _active_moment_id, free_tiles_by_moment)
	var apt_floor := _floors.get(_current_floor_id) as Floor
	if apt_floor:
		gm.update_zones(apt_floor.zones)


func _on_budget_changed(new_budget: int) -> void:
	budget_label.text = "Budget: %d€" % new_budget


func _on_functions_updated(fulfilled: Array, required: Array) -> void:
	tenant_card.update_checks(fulfilled, required)
	_update_rent_btn()


func _on_moments_updated(results: Dictionary) -> void:
	tenant_card.update_moments(results)
	_update_rent_btn()


# Celebrate the moment the puzzle becomes solvable: the instant every
# requirement flips green, RENT OUT wakes up with a pulse so the player's eye
# is drawn to the "finish" button without a tutorial pointing at it.
func _update_rent_btn() -> void:
	rent_btn.disabled = not gm.check_win() or not _all_furniture_accessible()
	tenant_card.set_rent_available(not rent_btn.disabled)


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
		_refresh_undo_redo_buttons()
		return
	if not _all_furniture_accessible():
		Audio.play("error")
		result_screen.show_failure("Some furniture is completely blocked.\nLeave at least 1 tile of walking space around it.")
		_refresh_undo_redo_buttons()
		return

	Audio.play("success")

	var stars       := gm.calculate_stars()
	var funds       := gm.get_funds_reward()
	var level_rent  := gm.current_level["tenant"]["monthly_rent"] as int

	GameState.complete_level(_current_level_id, stars, funds, level_rent)
	GameState.save_level_layout(_current_level_id, _snapshot_all_furniture())
	tenant_card.set_rented(true)

	await _play_completion_reveal()

	result_screen.show_success(
		stars,
		funds,
		GameState.portfolio_rent,
		gm.current_level["tenant"]["name"],
		level_rent,
		not gm.get_next_owned_level_id(_current_level_id).is_empty()
	)
	_refresh_undo_redo_buttons()


# The "wow" moment on a successful RENT OUT — a short scripted camera sweep
# through the finished apartment (Room3DView.play_reveal) instead of jumping
# straight to the results screen. Switches into 3D mode if the player was
# still on the Floor Plan so there's always something to actually show; skips
# entirely under Reduce Motion, same as the settings menu's other animations.
func _play_completion_reveal() -> void:
	if GameState.reduce_motion:
		return
	_set_view_mode(ViewMode.VIEW3D)
	if is_instance_valid(_mode3d_view):
		await _mode3d_view.play_reveal()




func _on_moment_selected(moment_id: String) -> void:
	_active_moment_id = moment_id
	tenant_card.highlight_moment(moment_id)
	# Selecting a moment enables the same fold/unfold interaction Test Layout
	# does — the player still has to click each piece themselves to match the
	# moment's needs; nothing is toggled automatically here.
	Furniture.test_mode_active = true
	Furniture.active_moment_id = moment_id
	for fid in _floors:
		var fl := _floors[fid] as Floor
		for f in fl.get_all_furniture():
			var fur := f as Furniture
			if fur.foldable or fur.rail_axis != "":
				# Re-apply THIS moment's own remembered fold state / rail position —
				# a sofa bed unfolded for Night stays unfolded there even if Day has
				# it folded; a wardrobe pulled out on its rail for one moment stays
				# out there even if another moment has it tucked away.
				fur.set_moment_view(moment_id)
			if fur.foldable:
				fur.set_extended_conflict(fl.check_extended_conflict(fur))
			fur.queue_redraw()
	# queue_redraw() above only repaints the 2D Node2D furniture — the 3D
	# diorama is a separate set of MeshInstance3D nodes built once from a
	# snapshot of the floor, so switching moments while looking at the 3D
	# view left it showing the pre-switch fold/rail state until you left
	# and came back. Rebuilding here keeps it in sync immediately.
	if _view_mode == ViewMode.VIEW3D:
		_ensure_mode3d_view()
	_refresh_functions()


func _on_test_toggled(pressed: bool) -> void:
	Furniture.test_mode_active = pressed
	# Click-to-fold works all the time now, not just in Test Layout, so a
	# piece's fold state is real/persistent furnishing state rather than a
	# throwaway preview — toggling this button off no longer forces every
	# foldable piece back closed the way it used to.
	for fid in _floors:
		var fl := _floors[fid] as Floor
		for f in fl.get_all_furniture():
			var fur := f as Furniture
			if fur.foldable:
				fur.set_extended_conflict(fl.check_extended_conflict(fur))
			fur.queue_redraw()
	if _view_mode == ViewMode.VIEW3D:
		_ensure_mode3d_view()
	if not pressed:
		_refresh_functions()


func _has_foldable_furniture() -> bool:
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			if (f as Furniture).foldable:
				return true
	return false


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ke := event as InputEventKey
		# Undo key is remappable (Settings → Accessibility); Redo is always the
		# same key + Shift, plus the fixed Ctrl+Y alias below.
		if ke.pressed and not ke.echo and not _post_win_view and ke.keycode == GameState.undo_keycode and (ke.ctrl_pressed or ke.meta_pressed):
			if ke.shift_pressed:
				_redo_builder_action()
			else:
				_undo_builder_action()
			get_viewport().set_input_as_handled()
			return
		if ke.pressed and not ke.echo and not _post_win_view and ke.keycode == KEY_Y and (ke.ctrl_pressed or ke.meta_pressed):
			_redo_builder_action()
			get_viewport().set_input_as_handled()
			return
		# Quick-access shortcuts — skip while the Results screen is up (its own
		# buttons take precedence) and while a Builder/paint tool is capturing
		# keys for something else (T/W/number keys are rare enough in that
		# context that the tool's own use of them, if any, should win).
		if ke.pressed and not ke.echo and not result_screen.visible \
				and _active_paint_type == "" and _active_builder_tool == "" \
				and not (ke.ctrl_pressed or ke.meta_pressed or ke.alt_pressed):
			if ke.keycode == KEY_T:
				_set_view_mode(ViewMode.VIEW3D if _view_mode == ViewMode.TOPDOWN else ViewMode.TOPDOWN)
				get_viewport().set_input_as_handled()
				return
			if ke.keycode == KEY_Q:
				_reopen_last_wall()
				get_viewport().set_input_as_handled()
				return
			if ke.keycode >= KEY_1 and ke.keycode <= KEY_9:
				var _midx := ke.keycode - KEY_1
				if _midx < gm.moments.size():
					var _mid := (gm.moments[_midx] as Dictionary).get("id", "") as String
					if _mid != "":
						_on_moment_selected(_mid)
						get_viewport().set_input_as_handled()
						return
			if ke.keycode == KEY_UP or ke.keycode == KEY_W:
				_step_floor(1)
				get_viewport().set_input_as_handled()
				return
			if ke.keycode == KEY_DOWN or ke.keycode == KEY_S:
				_step_floor(-1)
				get_viewport().set_input_as_handled()
				return
			if ke.keycode == KEY_LEFT or ke.keycode == KEY_A:
				_step_moment(-1)
				get_viewport().set_input_as_handled()
				return
			if ke.keycode == KEY_RIGHT or ke.keycode == KEY_D:
				_step_moment(1)
				get_viewport().set_input_as_handled()
				return
	if _dragging_divider:
		if event is InputEventMouseMotion:
			_update_split((event as InputEventMouseMotion).position.y)
		elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
				and not (event as InputEventMouseButton).pressed:
			_dragging_divider = false
		return
	if _active_paint_type != "":
		_handle_paint_input(event)
		return
	if _active_builder_tool != "":
		_handle_builder_input(event)
		return
	_handle_view_input(event)


func _on_next_level() -> void:
	Transition.change_scene("res://scenes/CityMap.tscn")


func _on_retry() -> void:
	_load_level(_current_level_id)


# "View Apartment" on the Results screen — just closes the modal and hands
# full camera control back to the player (orbit/zoom/pan freely, same as the
# normal 3D view), like tabbing out to the post-game map in an RTS. Does NOT
# replay the scripted camera sweep — that already played once right after
# RENT OUT; this is "let me look around," not "show me the intro again." A
# small floating button is the only way back, since the Results panel stays
# hidden the whole time so it doesn't block the view.
func _on_watch_again_reveal() -> void:
	result_screen.visible = false
	_post_win_view = true
	Furniture.read_only     = true
	WallInspector.read_only = true
	_set_view_mode(ViewMode.VIEW3D)
	if is_instance_valid(_mode3d_view):
		_mode3d_view.read_only = true
	inventory.visible = false
	_refresh_undo_redo_buttons()
	_show_watch_done_button()


func _show_watch_done_button() -> void:
	if is_instance_valid(_watch_done_btn):
		_watch_done_btn.queue_free()
	_watch_done_btn = Button.new()
	_watch_done_btn.text = "✕ Back to Results"
	_watch_done_btn.add_theme_font_size_override("font_size", 13)
	_watch_done_btn.custom_minimum_size = Vector2(200, 40)
	ui_layer.add_child(_watch_done_btn)
	# Centered on the play area (not the whole window) and sat below the
	# diorama's resting position, rather than tucked in the top-left corner
	# where it competed with the Builder tool panel.
	var center_x := (LEFT_X + RIGHT_X) * 0.5
	_watch_done_btn.offset_left   = center_x - 100.0
	_watch_done_btn.offset_right  = center_x + 100.0
	_watch_done_btn.offset_top    = BOT_Y - 90.0
	_watch_done_btn.offset_bottom = BOT_Y - 50.0
	# Same reasoning as Inventory in _ensure_mode3d_view: the 3D view is a
	# later sibling in this same CanvasLayer, so a freshly added Control has
	# to be moved after it explicitly or the 3D view's opaque background
	# paints over it and swallows its clicks.
	ui_layer.move_child(_watch_done_btn, ui_layer.get_child_count() - 1)
	_watch_done_btn.pressed.connect(func():
		_watch_done_btn.queue_free()
		_watch_done_btn = null
		_post_win_view = false
		if is_instance_valid(_mode3d_view):
			_mode3d_view.read_only = false
		inventory.visible = true
		result_screen.visible = true
		_refresh_undo_redo_buttons()
	)


# "Next Level" on the Results screen — loads the next owned level directly
# instead of detouring through CityMap. get_next_owned_level_id() already
# returned non-empty when the button became visible, but re-check here since
# nothing stops the player sitting on the Results screen indefinitely first.
func _on_advance_level() -> void:
	var next_id := gm.get_next_owned_level_id(_current_level_id)
	if next_id.is_empty():
		Transition.change_scene("res://scenes/CityMap.tscn")
		return
	GameState.pending_level_id = next_id
	GameState.pending_use_saved_layout = false
	Transition.change_scene("res://scenes/Main.tscn")


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
	sb.bg_color     = Color(0.115, 0.100, 0.085, 0.97)
	sb.border_color = Color(0.290, 0.245, 0.190)
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
	if mp.x < LEFT_X or mp.x > _floor_pane_right_x() or mp.y < TOP_Y or mp.y > _floor_pane_bottom_y():
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


# ── Builder tab tools ───────────────────────────────────────────────────────
# Free-form geometry editing during play (walls/columns/erase for now).
# Unlike the paid pre-furnish Demolition Phase (which removes the LEVEL's
# pre-existing walls at a cost), these are the player's own construction —
# free to add and free to undo, same as arranging furniture is free.

func _on_builder_tool_selected(tool_id: String) -> void:
	_cancel_builder_drawing()
	_active_builder_tool = tool_id
	for fid in _floors:
		(_floors[fid] as Floor).input_suppressed = (tool_id != "")
	# Pipe routes/connection points live on every Floor but are normally only
	# rendered on the (player-inaccessible, hidden_floors) subfloor layer —
	# show them directly on the current floor's own plan while a pipe tool
	# is active, since that's the floor the routes are actually being drawn
	# and read against (get_unconnected_needs checks furniture on this same
	# floor, not a separate subfloor node).
	# Keep pipes visible for "erase" too — Erase is the shared removal tool
	# for everything the Builder tab adds, including pipe routes.
	var show_pipes := tool_id == "pipe_water" or tool_id == "pipe_power" or tool_id == "erase"
	var cur_fl := _floors.get(_current_floor_id) as Floor
	if cur_fl:
		var gd := cur_fl.get_node_or_null("GridDraw") as GridDraw
		if gd:
			gd.show_subfloor = show_pipes
			gd.queue_redraw()


func _builder_tile_at(fl: Floor) -> Vector2i:
	var local := fl.to_local(get_viewport().get_mouse_position())
	return Vector2i(floori(local.x / Floor.TILE_SIZE), floori(local.y / Floor.TILE_SIZE))


func _handle_builder_input(event: InputEvent) -> void:
	var fl := _floors.get(_current_floor_id) as Floor
	if not fl:
		return
	if event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		if mbe.button_index != MOUSE_BUTTON_LEFT:
			return
		if mbe.pressed:
			if mbe.position.x <= LEFT_X or mbe.position.x >= _floor_pane_right_x() or mbe.position.y < TOP_Y or mbe.position.y > _floor_pane_bottom_y():
				return
			_builder_press_consumed = true
			var tile := _builder_tile_at(fl)
			match _active_builder_tool:
				"wall", "rail", "reveal":
					_builder_press_tile = tile
					_builder_cur_tile   = tile
					_builder_drawing    = true
					_update_builder_ghost(fl)
				"column":
					var already := false
					for c in fl.columns:
						if (c["x"] as int) == tile.x and (c["y"] as int) == tile.y:
							already = true
							break
					if already or fl.can_place_column(tile.x, tile.y):
						_push_builder_undo(fl)
						fl.toggle_column(tile.x, tile.y)
						Audio.play("place")
						_refresh_functions()
					else:
						Audio.play("error")
				"erase":
					var local := fl.to_local(get_viewport().get_mouse_position())
					_push_builder_undo(fl)
					if fl.erase_near(local, tile):
						Audio.play("demolish")
						_refresh_functions()
					else:
						_builder_undo_stack.pop_back()  # nothing erased — drop the wasted snapshot
				"balcony", "bathroom":
					_builder_drawing  = true
					_builder_cur_tile = tile
					_push_builder_undo(fl)  # one snapshot per stroke, not per tile painted
					_paint_floor_tile(fl, tile, _active_builder_tool)
				"window":
					var local_w := fl.to_local(get_viewport().get_mouse_position())
					var idx_w := fl.find_segment_near(local_w, 1.5)
					if idx_w >= 0:
						_push_builder_undo(fl)
						if fl.toggle_window_on_segment(idx_w):
							Audio.play("place")
							_refresh_functions()
						else:
							_builder_undo_stack.pop_back()
							Audio.play("error")
					else:
						Audio.play("error")
				"door":
					var local_d := fl.to_local(get_viewport().get_mouse_position())
					var idx_d := fl.find_segment_near(local_d, 1.5)
					if idx_d >= 0:
						_push_builder_undo(fl)
						if fl.toggle_door_on_segment(idx_d):
							Audio.play("place")
							_refresh_functions()
						else:
							_builder_undo_stack.pop_back()
							Audio.play("error")
					else:
						Audio.play("error")
				"pipe_water", "pipe_power":
					_builder_drawing    = true
					_builder_pipe_tiles = [tile]
					_update_builder_pipe_ghost(fl)
			# Consume the event so Floor.gd's own _input() (wall-edge-click
			# detection, used by the normal Select mode) doesn't also react
			# to the same press/release and pop open the Wall Inspector.
			get_viewport().set_input_as_handled()
		elif _builder_press_consumed:
			# Only swallow the release that matches a press we actually
			# handled — otherwise a release over UI (e.g. a Builder-tab
			# button click that started elsewhere) gets eaten here too,
			# since _input() runs before Control._gui_input and leaves the
			# button's own click never firing.
			_builder_press_consumed = false
			if _builder_drawing and _active_builder_tool == "wall":
				_commit_builder_wall(fl)
			elif _builder_drawing and _active_builder_tool == "rail":
				_commit_builder_rail(fl)
			elif _builder_drawing and _active_builder_tool == "reveal":
				_commit_builder_reveal(fl)
			elif _builder_drawing and (_active_builder_tool == "pipe_water" or _active_builder_tool == "pipe_power"):
				_commit_builder_pipe(fl)
			_builder_drawing = false
			_clear_builder_ghost()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _builder_drawing:
		var tile := _builder_tile_at(fl)
		match _active_builder_tool:
			"wall", "rail", "reveal":
				# Axis-snap to whichever direction has moved further, same as
				# LevelEditor's wall-drawing preview.
				if absi(tile.x - _builder_press_tile.x) >= absi(tile.y - _builder_press_tile.y):
					tile.y = _builder_press_tile.y
				else:
					tile.x = _builder_press_tile.x
				_builder_cur_tile = tile
				_update_builder_ghost(fl)
			"pipe_water", "pipe_power":
				if _builder_pipe_tiles.is_empty() or tile != _builder_pipe_tiles[-1]:
					_builder_pipe_tiles.append(tile)
					_update_builder_pipe_ghost(fl)
			"balcony", "bathroom":
				if tile != _builder_cur_tile:
					_builder_cur_tile = tile
					_paint_floor_tile(fl, tile, _active_builder_tool)


# ── Builder tab undo ──────────────────────────────────────────────────────
# Snapshot-based rather than per-tool inverse operations: every commit action
# for every tool (wall/column/erase/paint/window/door/rail/reveal/pipe) only
# ever touches these six Floor fields, so capturing all six before a mutation
# and restoring them wholesale on undo covers every tool with one mechanism.
func _push_builder_undo(fl: Floor) -> void:
	_builder_undo_stack.append(_capture_builder_entry(fl))
	if _builder_undo_stack.size() > BUILDER_UNDO_MAX:
		_builder_undo_stack.pop_front()
	_redo_stack.clear()   # a fresh action invalidates whatever was undone before it
	_refresh_undo_redo_buttons()


func _capture_builder_entry(fl: Floor) -> Dictionary:
	return {
		"type": "builder",
		"floor_id": fl.name,
		"data": {
			"segments":         fl.segments.duplicate(true),
			"columns":          fl.columns.duplicate(true),
			"floor_kind":       fl.floor_kind.duplicate(true),
			"rails":            fl.rails.duplicate(true),
			"reveal_zones":     fl.reveal_zones.duplicate(true),
			"pipe_routes":      fl.pipe_routes.duplicate(true),
		},
	}


func _apply_builder_entry(entry: Dictionary) -> void:
	var fl := _floors.get(entry["floor_id"] as String) as Floor
	if not fl:
		return
	var data := entry["data"] as Dictionary
	fl.segments     = (data["segments"] as Array).duplicate(true)
	fl.columns      = (data["columns"] as Array).duplicate(true)
	fl.floor_kind   = (data["floor_kind"] as Dictionary).duplicate(true)
	fl.rails        = (data["rails"] as Array).duplicate(true)
	fl.reveal_zones = (data["reveal_zones"] as Array).duplicate(true)
	fl.pipe_routes  = (data["pipe_routes"] as Array).duplicate(true)
	if fl.has_method("_compute_light_map"):
		fl._compute_light_map()
	if fl.grid_draw:
		fl.grid_draw.queue_redraw()
	_refresh_functions()


func _undo_builder_action() -> void:
	if _builder_undo_stack.is_empty():
		return
	var entry := _builder_undo_stack.pop_back() as Dictionary
	if (entry.get("type", "builder") as String) == "furniture":
		_redo_stack.append({"type": "furniture", "snapshot": _snapshot_all_furniture()})
		_restore_furniture_snapshot(entry["snapshot"] as Dictionary)
		_refresh_undo_redo_buttons()
		return
	var fl := _floors.get(entry["floor_id"] as String) as Floor
	if fl:
		_redo_stack.append(_capture_builder_entry(fl))
	_apply_builder_entry(entry)
	Audio.play("click")
	_refresh_undo_redo_buttons()


func _redo_builder_action() -> void:
	if _redo_stack.is_empty():
		return
	var entry := _redo_stack.pop_back() as Dictionary
	if (entry.get("type", "builder") as String) == "furniture":
		_builder_undo_stack.append({"type": "furniture", "snapshot": _snapshot_all_furniture()})
		_restore_furniture_snapshot(entry["snapshot"] as Dictionary)
		Audio.play("click")
		_refresh_undo_redo_buttons()
		return
	var fl := _floors.get(entry["floor_id"] as String) as Floor
	if fl:
		_builder_undo_stack.append(_capture_builder_entry(fl))
	_apply_builder_entry(entry)
	Audio.play("click")
	_refresh_undo_redo_buttons()


# Also locked out whenever the Results modal is up (or during the post-win
# "View Apartment" free-look) — undoing/redoing a level that's already been
# scored and saved makes no sense, in ANY view mode (floor plan, wall view,
# or 3D), not just whichever one happened to be active when RENT OUT was hit.
func _refresh_undo_redo_buttons() -> void:
	var locked := result_screen.visible or _post_win_view
	if is_instance_valid(_undo_btn):
		_undo_btn.disabled = locked or _builder_undo_stack.is_empty()
	if is_instance_valid(_redo_btn):
		_redo_btn.disabled = locked or _redo_stack.is_empty()


# ── Furniture undo (buy/sell/move/fold) ──────────────────────────────────
# Called once, right after each real commit (never from Wall.gd's own
# furniture_changed — that also fires during an uncommitted buy-ghost preview,
# once per mouse-move, which would flood the stack and can even snapshot a
# not-yet-settled piece). The state cached from the PREVIOUS call is exactly
# "how things were right before this change", so: push that, then re-cache
# the new current state for next time. Hooked from precise one-shot signals
# (placement_confirmed, placed, fold_toggled, furniture_moved) plus explicit
# calls around sell and the 3D buy paths.
func _on_furniture_action_changed() -> void:
	if _restoring_furniture:
		return
	if not _last_furniture_state.is_empty():
		_builder_undo_stack.append({"type": "furniture", "snapshot": _last_furniture_state})
		if _builder_undo_stack.size() > BUILDER_UNDO_MAX:
			_builder_undo_stack.pop_front()
		_redo_stack.clear()
		_refresh_undo_redo_buttons()
	_last_furniture_state = _snapshot_all_furniture()


func _snapshot_all_furniture() -> Dictionary:
	var floors_data := {}
	for fid in _floors:
		var fl := _floors[fid] as Floor
		var furn := []
		for item in fl.get_all_furniture():
			var f := item as Furniture
			furn.append({
				"id": f.furniture_id, "x": f.grid_pos.x, "y": f.grid_pos.y,
				"extended": f.is_extended,
			})
		floors_data[fid] = {
			"furniture":   furn,
			"wall_items": (fl.wall_items as Dictionary).duplicate(true),
		}
	return {"funds": gm.budget, "floors": floors_data}


func _restore_furniture_snapshot(snap: Dictionary) -> void:
	_restoring_furniture = true
	gm.budget = snap["funds"] as int
	gm.budget_changed.emit(gm.budget)
	var floors_data := snap["floors"] as Dictionary
	var touched_current := false
	for fid in floors_data:
		var fl := _floors.get(fid) as Floor
		if not fl:
			continue   # a loft floor removed in between — rare edge case, skipped
		var fd := floors_data[fid] as Dictionary
		# A single undo/redo step only ever changes one floor (one tool action
		# happened on one floor) — tearing down and respawning every OTHER
		# floor's furniture too (destroy + re-instantiate + re-setup each
		# piece) was the actual cost here, multiplied by every floor in the
		# apartment on every single step. Skip any floor whose snapshot
		# already matches its current state.
		if _floor_matches_furniture_snapshot(fl, fd):
			continue
		if fid == _current_floor_id:
			touched_current = true
		for item in fl.get_all_furniture().duplicate():
			# remove_furniture() (not a raw queue_free) so the Floor's own grid
			# bookkeeping is cleaned up too — otherwise later code that iterates
			# placed furniture (zone/light-map recompute, moment checks, ...)
			# can still trip over the stale reference before its deferred free
			# actually runs.
			fl.remove_furniture(item as Furniture)
		fl.wall_items.clear()
		for e in (fd["furniture"] as Array):
			var ed := e as Dictionary
			var f := _restore_spawn_furniture(ed["id"] as String, fl, int(ed["x"]), int(ed["y"]))
			if f and (ed.get("extended", false) as bool) and f.foldable:
				f._apply_fold_state(true)
		var wall_items := fd["wall_items"] as Dictionary
		for edge in wall_items:
			var items := wall_items[edge] as Dictionary
			for origin in items:
				fl.place_wall_item(edge, origin as Vector2i, items[origin] as String)
	_restoring_furniture = false
	_last_furniture_state = _snapshot_all_furniture()
	_refresh_functions()
	if _view_mode == ViewMode.VIEW3D and touched_current:
		_ensure_mode3d_view()
	Audio.play("click")


# True if a floor's live furniture + wall items already equal what the
# snapshot wants — lets _restore_furniture_snapshot skip the (expensive)
# destroy/respawn cycle for every floor an undo/redo step didn't touch.
func _floor_matches_furniture_snapshot(fl: Floor, fd: Dictionary) -> bool:
	var furn := []
	for item in fl.get_all_furniture():
		var f := item as Furniture
		furn.append({"id": f.furniture_id, "x": f.grid_pos.x, "y": f.grid_pos.y, "extended": f.is_extended})
	return furn == (fd["furniture"] as Array) and (fl.wall_items as Dictionary) == (fd["wall_items"] as Dictionary)


# Same as _spawn_furniture but never auto-promotes onto a loft floor — used
# during undo restore, where the snapshot already records each piece on
# whichever floor (base or loft) it actually ended up on, so re-triggering
# the auto-promotion would try to move it a second time.
func _restore_spawn_furniture(furniture_id: String, apt_floor: Floor, gx: int, gy: int) -> Furniture:
	var fdata := gm.get_furniture_by_id(furniture_id)
	if fdata.is_empty():
		return null
	var f: Furniture = FurnitureScene.instantiate() as Furniture
	apt_floor.add_child(f)
	f.setup(fdata, apt_floor)
	apt_floor.place_furniture(f, Vector2i(gx, gy))
	f.sell_requested.connect(_on_sell_pressed.bind(apt_floor))
	f.fold_toggled.connect(_refresh_functions)
	f.fold_toggled.connect(_on_furniture_action_changed)
	f.placed.connect(func(_n): _on_furniture_action_changed())
	if f.rail_axis != "":
		f.placed.connect(func(_n): _refresh_functions())
	return f


func _paint_floor_tile(fl: Floor, tile: Vector2i, kind: String) -> void:
	if tile.x < 0 or tile.y < 0 or tile.x >= fl.grid_w or tile.y >= fl.grid_h:
		return
	fl.paint_floor_kind(tile, kind)
	Audio.play("place")


func _commit_builder_wall(fl: Floor) -> void:
	var ps := _builder_press_tile
	var pe := _builder_cur_tile
	if ps == pe:
		return
	if not fl.can_add_segment(ps.x, ps.y, pe.x, pe.y):
		Audio.play("error")
		return
	_push_builder_undo(fl)
	fl.add_segment(ps.x, ps.y, pe.x, pe.y)
	Audio.play("place")
	_refresh_functions()


func _commit_builder_rail(fl: Floor) -> void:
	var ps := _builder_press_tile
	var pe := _builder_cur_tile
	if ps == pe:
		return
	if not fl.can_add_rail(ps.x, ps.y, pe.x, pe.y):
		Audio.play("error")
		return
	_push_builder_undo(fl)
	fl.add_rail(ps.x, ps.y, pe.x, pe.y)
	Audio.play("place")


func _commit_builder_reveal(fl: Floor) -> void:
	var ps := _builder_press_tile
	var pe := _builder_cur_tile
	if ps == pe:
		return
	if not fl.can_add_reveal_zone(ps.x, ps.y, pe.x, pe.y):
		Audio.play("error")
		return
	_push_builder_undo(fl)
	fl.add_reveal_zone(ps.x, ps.y, pe.x, pe.y)
	Audio.play("place")


func _commit_builder_pipe(fl: Floor) -> void:
	var pipe_type := "water" if _active_builder_tool == "pipe_water" else "power"
	if _builder_pipe_tiles.size() < 2:
		_builder_pipe_tiles = []
		_clear_builder_pipe_ghost()
		return
	_push_builder_undo(fl)
	fl.add_pipe_route(pipe_type, _builder_pipe_tiles.duplicate())
	Audio.play("place")
	_builder_pipe_tiles = []
	_clear_builder_pipe_ghost()


func _update_builder_pipe_ghost(fl: Floor) -> void:
	if not is_instance_valid(_builder_pipe_ghost):
		_builder_pipe_ghost = Line2D.new()
		_builder_pipe_ghost.width = 2.5
		_builder_pipe_ghost.default_color = Color(0.95, 0.65, 0.25, 0.9)
		fl.add_child(_builder_pipe_ghost)
	var pts := PackedVector2Array()
	for t in _builder_pipe_tiles:
		pts.append((Vector2(t) + Vector2(0.5, 0.5)) * Floor.TILE_SIZE)
	_builder_pipe_ghost.points = pts


func _clear_builder_pipe_ghost() -> void:
	if is_instance_valid(_builder_pipe_ghost):
		_builder_pipe_ghost.queue_free()
	_builder_pipe_ghost = null


func _update_builder_ghost(fl: Floor) -> void:
	if not is_instance_valid(_builder_ghost):
		_builder_ghost = Line2D.new()
		_builder_ghost.width = 3.0
		_builder_ghost.default_color = Color(0.95, 0.65, 0.25, 0.9)
		fl.add_child(_builder_ghost)
	_builder_ghost.points = PackedVector2Array([
		Vector2(_builder_press_tile) * Floor.TILE_SIZE,
		Vector2(_builder_cur_tile)   * Floor.TILE_SIZE,
	])


func _clear_builder_ghost() -> void:
	if is_instance_valid(_builder_ghost):
		_builder_ghost.queue_free()
	_builder_ghost = null


func _cancel_builder_drawing() -> void:
	_builder_drawing = false
	_builder_press_consumed = false
	_builder_pipe_tiles = []
	_clear_builder_ghost()
	_clear_builder_pipe_ghost()


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
