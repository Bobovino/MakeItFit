extends Node

# ─────────────────────────────────────────────────────────────────────────────
const TILE_SIZE  := 8
const WIN_LEN    := 15
const DOOR_LEN   := 10
const LEFT_W     := 170.0
const RIGHT_W    := 214.0
const TOP_H      := 36.0
const DEFAULT_GW := 200
const DEFAULT_GH := 150

const _OV_SCRIPT := preload("res://scripts/EditorOverlay.gd")

enum Tool { FLOOR, MEZZANINE, STAIRS, RAIL, PRIMARY_WALL, SECONDARY_WALL, WINDOW, DOOR, WALL_VIEW, COLUMN, ERASE }

# ── Floor geometry ────────────────────────────────────────────────────────────
var _gw: int = DEFAULT_GW
var _gh: int = DEFAULT_GH
var _floor_mask:     Dictionary = {}  # Vector2i -> true (painted floor tiles)
var _mezzanine_mask: Dictionary = {}  # Vector2i -> true (mezzanine/loft tiles)
var _stair_mask:     Dictionary = {}  # Vector2i -> true (stair tiles)
var _segments:       Array      = []  # [{x1,y1,x2,y2,primary,demolished,...}]
var _rails:          Array      = []  # [{x1,y1,x2,y2}] rail tracks
var _cols:           Array      = []  # [{x,y}]

# ── Wall drawing state ────────────────────────────────────────────────────────
var _floor_painting:   bool = false
var _floor_erase:      bool = false
var _floor_brush:      int  = 10  # 1 = tile (10 cm), 10 = cell (1 m = 10×10 tiles)
var _mezz_painting:    bool = false
var _mezz_erase:       bool = false
var _stair_painting:   bool = false
var _stair_erase:      bool = false
var _window_painting:  bool = false
var _window_erase:     bool = false

# ── Metadata ──────────────────────────────────────────────────────────────────
var _lname:  String = "Untitled Apartment"
var _dist:   String = "Mitte"
var _tname:  String = "Alex"
var _tage:   int    = 28
var _tflav:  String = "Needs a proper home."
var _budget: int    = 2000
var _rent:   int    = 300
var _reward: int    = 800
var _cost:   int    = 1500
var _funcs: Dictionary = {
	"sleep": false, "sit": false, "work": false, "cook": false, "storage": false, "dine": false
}

# ── Tool & interaction state ──────────────────────────────────────────────────
var _tool: Tool = Tool.FLOOR
var _tool_btns: Dictionary = {}   # Tool -> Button; for programmatic switching
var _ps: Vector2i = Vector2i(-1, -1)
var _pe: Vector2i = Vector2i(-1, -1)
var _pdrawing: bool = false

# ── Door drag state ───────────────────────────────────────────────────────────
var _door_dragging: bool = false
var _door_seg_idx:  int  = -1
var _door_pos:      int  = 0
var _door_side:     int  = 1   # +1 = south/east, -1 = north/west

# Wall-view side drag state
var _wv_dragging: bool = false
var _wv_seg_idx:  int  = -1
var _wv_side:     int  = 1    # +1 = south/east, -1 = north/west

# Wall-view elevation modal
const WV_TS := 12   # px per tile in elevation view
const WV_H  := 24   # wall height in tiles
var _wv_modal_win:  Window      = null
var _wv_modal_seg:  int         = -1
var _wv_modal_side: int         = 1
var _wv_modal_draw: Control     = null
var _wv_modal_sfid: String      = ""
var _wv_modal_grp:  ButtonGroup = null

# ── Camera pan / zoom ─────────────────────────────────────────────────────────
var _panning: bool    = false
var _pan_last: Vector2 = Vector2.ZERO

# ── Scene nodes ───────────────────────────────────────────────────────────────
var _room:   Node2D   = null
var _camera: Camera2D = null
var _floor:  Floor    = null
var _camera_fitted: bool = false  # true after first fit; prevents reset on every rebuild
var _ov:     Node2D   = null

# ── UI refs ───────────────────────────────────────────────────────────────────
var _sw: SpinBox = null;  var _sh: SpinBox = null
var _en: LineEdit = null; var _ed: LineEdit = null
var _etn: LineEdit = null; var _sage: SpinBox = null; var _ef: LineEdit = null
var _sbud: SpinBox = null; var _srent: SpinBox = null
var _srew: SpinBox = null; var _scost: SpinBox = null
var _fncbs: Dictionary = {}
var _status: Label = null
var _size_lbl: Label = null
var _clear_dlg: ConfirmationDialog = null

# ── Furniture data (loaded once) ──────────────────────────────────────────────
var _furn_catalog: Array = []   # full furniture array from furniture.json

# ── Furniture restrictions + starting inventory ───────────────────────────────
var _allowed_furniture:    Array   = []   # [] = all allowed; otherwise ID whitelist
var _starting_inventory:   Array   = []   # [{id, count}] items that start in the apartment
var _placed_furniture:     Array   = []   # [{id, x, y}] pre-placed positions on the floor

# Furniture placement mode
var _placing_furniture_id:   String   = ""
var _placing_furn_size:      Vector2i = Vector2i.ZERO
var _placing_furn_col:       Color    = Color.WHITE

# Right-panel summary labels
var _cat_filter_lbl:   Label  = null
var _inv_count_lbl:    Label  = null
var _level_summary_lbl: Label = null

# Starting inventory modal (kept alive so it can be hidden/shown during placement)
var _inv_modal_win:  Window = null
var _inv_list_vb:    VBoxContainer = null

# ── Multi-floor editing ───────────────────────────────────────────────────────
# Ordered bottom→top: [subfloor, ground, ..., roof]
# Each entry: {id, label, type, floor_tiles, mezzanine_tiles, stair_tiles, rails, segments, columns}
var _editor_floors: Array         = []
var _active_efl:    int           = 1   # default: ground floor (index 1)
var _fl_list_vb:    VBoxContainer = null
var _hidden_fl_ids: Dictionary    = {}  # floor id -> true; player cannot switch to these

# ── Moments ───────────────────────────────────────────────────────────────────
var _moments:         Array         = []   # [{id, label}]
var _active_moment:   String        = ""   # "" = no moment active
var _moment_funcs:    Dictionary    = {}   # moment_id -> {fn_name: bool}
var _moment_dropdown: OptionButton  = null


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  READY                                                                   ║
# ╚══════════════════════════════════════════════════════════════════════════╝

func _ready() -> void:
	var fj := FileAccess.open("res://data/furniture.json", FileAccess.READ)
	if fj:
		var jp := JSON.new(); jp.parse(fj.get_as_text()); fj.close()
		_furn_catalog = (jp.get_data() as Dictionary).get("furniture", []) as Array
	_init_editor_floors()
	_build_scene()
	# Returning from a test session — restore the level that was being edited
	var gs: Node = get_node("/root/GameState")
	if gs.get("resume_editor") and not (gs.get("custom_level_data") as Dictionary).is_empty():
		gs.set("resume_editor", false)
		_load_from_dict(gs.get("custom_level_data") as Dictionary)
		_set_status("Returned from test — level restored")
	else:
		_rebuild_floor()
		_set_status("Floor Paint: LMB pintasuelos · RMB borra  |  Dibuja paredes encima del suelo")


# ── Scene skeleton ────────────────────────────────────────────────────────────

func _build_scene() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_room = Node2D.new()
	_room.name = "EditorRoom"
	add_child(_room)

	_camera = Camera2D.new()
	_camera.enabled = true
	add_child(_camera)

	var ui := CanvasLayer.new()
	ui.layer = 20
	add_child(ui)

	# Themed root — buttons inherit GameTheme from here
	var troot := Control.new()
	troot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	troot.theme = GameTheme.make()
	troot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(troot)

	_build_topbar(troot)
	_build_left(troot)
	_build_right(troot)


func _build_topbar(ui: Node) -> void:
	var bar := PanelContainer.new()
	var bs := StyleBoxFlat.new()
	bs.bg_color = Color(0.09, 0.11, 0.16)
	bs.border_color = Color(0.22, 0.28, 0.36)
	bs.set_border_width(SIDE_BOTTOM, 1)
	bs.set_content_margin_all(6)
	bar.add_theme_stylebox_override("panel", bs)
	bar.set_anchor(SIDE_RIGHT, 1.0)
	bar.offset_bottom = TOP_H
	ui.add_child(bar)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	bar.add_child(hb)

	var back_btn := Button.new()
	back_btn.text = "← Back"
	back_btn.add_theme_font_size_override("font_size", 11)
	back_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
	back_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/CityMap.tscn"))
	hb.add_child(back_btn)

	var title := Label.new()
	title.text = "LEVEL EDITOR"
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", GameTheme.C_AMBER)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hb.add_child(title)

	var hint := Label.new()
	hint.text = "1 m = 10 tiles  |  RMB = erase"
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", GameTheme.C_MUTED)
	hb.add_child(hint)


func _build_left(ui: Node) -> void:
	var panel := PanelContainer.new()
	var ps := StyleBoxFlat.new()
	ps.bg_color = Color(0.09, 0.11, 0.16)
	ps.border_color = Color(0.18, 0.24, 0.34, 0.70)
	ps.set_border_width(SIDE_RIGHT, 1)
	ps.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", ps)
	panel.set_anchor(SIDE_BOTTOM, 1.0)
	panel.offset_top   = TOP_H
	panel.offset_right = LEFT_W
	ui.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	vb.custom_minimum_size = Vector2(LEFT_W - 24, 0)
	scroll.add_child(vb)

	_sect(vb, "TOOLS")
	var bg := ButtonGroup.new()
	var tool_defs: Array = [
		[Tool.FLOOR,         "Floor Paint",    "LMB paint · RMB erase floor tiles"],
		[Tool.MEZZANINE,     "Mezzanine",      "LMB paint · RMB erase mezzanine/loft tiles"],
		[Tool.STAIRS,        "Stairs",         "LMB paint · RMB erase stair tiles"],
		[Tool.RAIL,          "Rail",           "Drag to draw sliding rail track"],
		[Tool.PRIMARY_WALL,  "Primary Wall",   "Drag axis-snapped — cannot demolish"],
		[Tool.SECONDARY_WALL,"Secondary Wall", "Drag axis-snapped — can demolish"],
		[Tool.WINDOW,        "Window",         "LMB paint · RMB erase window tiles on a wall"],
		[Tool.DOOR,          "Door",           "Click wall · drag to choose opening side · click again to remove"],
		[Tool.WALL_VIEW,     "Wall View",      "Click wall · drag to choose which face is the interior view · RMB to clear"],
		[Tool.COLUMN,        "Column",         "Click inside room"],
		[Tool.ERASE,         "Erase",          "Click any feature or floor tile"],
	]
	for td in tool_defs:
		var t := td[0] as Tool
		var btn := Button.new()
		btn.text         = td[1] as String
		btn.tooltip_text = td[2] as String
		btn.toggle_mode  = true
		btn.button_group = bg
		btn.button_pressed = (t == _tool)
		btn.add_theme_font_size_override("font_size", 10)
		btn.pressed.connect(func():
			_tool = t
			_cancel_wall_drawing()
			if is_instance_valid(_ov):
				_ov.set("wall_primary",   _tool == Tool.PRIMARY_WALL)
				_ov.set("rail_mode",      _tool == Tool.RAIL)
				_ov.set("floor_hover",    Vector2i(-1, -1))
				_ov.set("wall_hover",     Vector2i(-1, -1))
				_ov.set("win_hover_rect", Rect2())
				_ov.set("mezz_hover",     false)
				_ov.set("stair_hover",    false)
				_ov.set("active",         false)
				_ov.queue_redraw())
		_tool_btns[t] = btn
		vb.add_child(btn)

	# ── Brush-size selector (Floor Paint) ────────────────────────────────────
	_sect(vb, "BRUSH SIZE")
	var brush_bg := ButtonGroup.new()
	var brush_row := HBoxContainer.new()
	brush_row.add_theme_constant_override("separation", 3)
	vb.add_child(brush_row)
	for bdef: Array in [[1, "Tile\n10cm"], [10, "Cell\n1m"]]:
		var bsz  := bdef[0] as int
		var blbl := bdef[1] as String
		var bbtn := Button.new()
		bbtn.text          = blbl
		bbtn.toggle_mode   = true
		bbtn.button_group  = brush_bg
		bbtn.button_pressed = (bsz == _floor_brush)
		bbtn.add_theme_font_size_override("font_size", 9)
		bbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bbtn.pressed.connect(func():
			_floor_brush = bsz
			if is_instance_valid(_ov):
				_ov.set("floor_brush", _floor_brush))
		brush_row.add_child(bbtn)

	_sect(vb, "GRID SIZE")

	var rw := HBoxContainer.new()
	rw.add_theme_constant_override("separation", 4)
	vb.add_child(rw)
	var lw := Label.new(); lw.text = "W:"; lw.add_theme_font_size_override("font_size", 10)
	rw.add_child(lw)
	_sw = SpinBox.new()
	_sw.min_value = 20; _sw.max_value = 500; _sw.step = 1; _sw.value = _gw
	_sw.add_theme_font_size_override("font_size", 10)
	_sw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rw.add_child(_sw)

	var rh2 := HBoxContainer.new()
	rh2.add_theme_constant_override("separation", 4)
	vb.add_child(rh2)
	var lh := Label.new(); lh.text = "H:"; lh.add_theme_font_size_override("font_size", 10)
	rh2.add_child(lh)
	_sh = SpinBox.new()
	_sh.min_value = 20; _sh.max_value = 500; _sh.step = 1; _sh.value = _gh
	_sh.add_theme_font_size_override("font_size", 10)
	_sh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rh2.add_child(_sh)

	_size_lbl = Label.new()
	_size_lbl.text = "= %.0fm × %.0fm" % [_gw * 0.1, _gh * 0.1]
	_size_lbl.add_theme_font_size_override("font_size", 9)
	_size_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	vb.add_child(_size_lbl)

	var apply := Button.new()
	apply.text = "Apply Size"
	apply.add_theme_font_size_override("font_size", 10)
	apply.pressed.connect(func():
		# SpinBox doesn't commit typed text until Enter/focus-lost — read LineEdit directly
		_gw = clampi(int(_sw.get_line_edit().text), int(_sw.min_value), int(_sw.max_value))
		_gh = clampi(int(_sh.get_line_edit().text), int(_sh.min_value), int(_sh.max_value))
		_sw.value = _gw; _sh.value = _gh  # sync spinbox display
		_size_lbl.text = "= %.0fm × %.0fm" % [_gw * 0.1, _gh * 0.1]
		_camera_fitted = false  # re-centre on the resized grid
		_rebuild_floor())
	vb.add_child(apply)

	_sect(vb, "ACTIONS")
	var clear_btn := Button.new()
	clear_btn.text = "Clear All"
	clear_btn.add_theme_font_size_override("font_size", 10)
	clear_btn.add_theme_color_override("font_color", Color(0.80, 0.30, 0.20))
	clear_btn.pressed.connect(_confirm_clear_all)
	vb.add_child(clear_btn)


func _build_right(ui: Node) -> void:
	var panel := PanelContainer.new()
	var ps := StyleBoxFlat.new()
	ps.bg_color = Color(0.09, 0.11, 0.16)
	ps.border_color = Color(0.18, 0.24, 0.34, 0.70)
	ps.set_border_width(SIDE_LEFT, 1)
	ps.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", ps)
	panel.set_anchor(SIDE_LEFT, 1.0)
	panel.set_anchor(SIDE_RIGHT, 1.0)
	panel.set_anchor(SIDE_BOTTOM, 1.0)
	panel.offset_top  = TOP_H
	panel.offset_left = -RIGHT_W
	ui.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	_sect(vb, "FLOORS")
	_fl_list_vb = VBoxContainer.new()
	_fl_list_vb.add_theme_constant_override("separation", 2)
	vb.add_child(_fl_list_vb)
	_refresh_fl_switcher()

	# ── Moments (time-based configurations) ─────────────────────────────────
	_sect(vb, "MOMENT")
	_moment_dropdown = OptionButton.new()
	_moment_dropdown.add_theme_font_size_override("font_size", 10)
	_moment_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_moment_dropdown.item_selected.connect(_on_moment_selected)
	vb.add_child(_moment_dropdown)
	var mgmt_btn := Button.new()
	mgmt_btn.text  = "Manage Moments…"
	mgmt_btn.add_theme_font_size_override("font_size", 10)
	mgmt_btn.pressed.connect(_open_moments_modal)
	vb.add_child(mgmt_btn)
	_rebuild_moment_dropdown()

	_sect(vb, "LEVEL")
	_level_summary_lbl = Label.new()
	_level_summary_lbl.add_theme_font_size_override("font_size", 10)
	_level_summary_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	_level_summary_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_level_summary_lbl)
	_refresh_level_summary()
	var det_btn := Button.new()
	det_btn.text = "Level Details…"
	det_btn.add_theme_font_size_override("font_size", 10)
	det_btn.pressed.connect(_open_level_details_modal)
	vb.add_child(det_btn)

	# ── Furniture (compact buttons → open modals) ─────────────────────────────
	_sect(vb, "FURNITURE")
	var cat_btn := Button.new()
	cat_btn.text = "Catalog Filter…"
	cat_btn.add_theme_font_size_override("font_size", 10)
	cat_btn.pressed.connect(_open_catalog_filter_modal)
	vb.add_child(cat_btn)
	_cat_filter_lbl = Label.new()
	_cat_filter_lbl.add_theme_font_size_override("font_size", 9)
	_cat_filter_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	vb.add_child(_cat_filter_lbl)
	_update_cat_filter_lbl()

	var inv_btn := Button.new()
	inv_btn.text = "Starting Furniture…"
	inv_btn.add_theme_font_size_override("font_size", 10)
	inv_btn.pressed.connect(_open_starting_inv_modal)
	vb.add_child(inv_btn)
	_inv_count_lbl = Label.new()
	_inv_count_lbl.add_theme_font_size_override("font_size", 9)
	_inv_count_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	vb.add_child(_inv_count_lbl)
	_update_inv_count_lbl()

	_sect(vb, "ACTIONS")
	_actbtn(vb, "▶  Test Level",  Color(0.28, 0.80, 0.52), _test_level)
	_actbtn(vb, "💾  Save Level", GameTheme.C_AMBER,        _save_level)
	_actbtn(vb, "📂  Load Level", GameTheme.C_MUTED,        _load_dialog)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 9)
	_status.add_theme_color_override("font_color", Color(0.42, 0.76, 0.52))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_status)


# ── UI helpers ────────────────────────────────────────────────────────────────

func _refresh_level_summary() -> void:
	if not is_instance_valid(_level_summary_lbl): return
	var fn_list: Array[String] = []
	for fn: String in _funcs:
		if _funcs[fn]: fn_list.append(fn)
	var fn_str := ", ".join(fn_list) if not fn_list.is_empty() else "none"
	_level_summary_lbl.text = "%s · %s\n%s · %d y/o\n%d€ budget · %d€/mo\nNeeds: %s" % [
		_lname if not _lname.is_empty() else "Untitled",
		_dist  if not _dist.is_empty()  else "—",
		_tname if not _tname.is_empty() else "—",
		_tage, _budget, _rent, fn_str
	]


func _open_level_details_modal() -> void:
	_collect_meta()
	var win := Window.new()
	win.title = "Level Details"
	win.size  = Vector2i(320, 540)
	win.wrap_controls = true
	add_child(win)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	win.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.custom_minimum_size = Vector2(300, 0)
	scroll.add_child(vb)

	# ── LEVEL ──
	_sect(vb, "LEVEL")
	var en  := _field(vb, "Name",     _lname)
	var ed  := _field(vb, "District", _dist)
	en.text_changed.connect(func(t: String): _lname = t; _refresh_level_summary())
	ed.text_changed.connect(func(t: String): _dist  = t; _refresh_level_summary())

	# ── TENANT ──
	_sect(vb, "TENANT")
	var etn  := _field(vb,   "Name",   _tname)
	var sage := _spinbox(vb, "Age",    _tage,   18, 90,   1)
	var ef   := _field(vb,   "Flavor", _tflav)
	etn.text_changed.connect(func(t: String): _tname = t; _refresh_level_summary())
	sage.value_changed.connect(func(v: float): _tage = int(v); _refresh_level_summary())
	ef.text_changed.connect(func(t: String): _tflav = t)

	# ── ECONOMICS ──
	_sect(vb, "ECONOMICS")
	var sbud  := _spinbox(vb, "Budget €",  _budget, 500,  20000, 100)
	var srent := _spinbox(vb, "Rent €/mo", _rent,    50,   3000,  50)
	var srew  := _spinbox(vb, "Reward €",  _reward,  200, 10000, 100)
	var scost := _spinbox(vb, "Cost €",    _cost,      0,   8000, 100)
	sbud.value_changed.connect(func(v: float): _budget  = int(v); _refresh_level_summary())
	srent.value_changed.connect(func(v: float): _rent   = int(v); _refresh_level_summary())
	srew.value_changed.connect(func(v: float):  _reward = int(v))
	scost.value_changed.connect(func(v: float): _cost   = int(v))

	# ── REQUIRED FUNCTIONS ──
	_sect(vb, "REQUIRED FUNCTIONS")
	for fn: String in ["sleep", "sit", "work", "cook", "storage", "dine"]:
		var cb := CheckBox.new()
		cb.text = fn
		cb.button_pressed = _funcs.get(fn, false) as bool
		cb.add_theme_font_size_override("font_size", 11)
		cb.add_theme_color_override("font_color", GameTheme.C_TEXT)
		cb.toggled.connect(func(on: bool): _funcs[fn] = on; _refresh_level_summary())
		vb.add_child(cb)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_font_size_override("font_size", 11)
	close_btn.pressed.connect(win.queue_free)
	vb.add_child(close_btn)

	win.close_requested.connect(win.queue_free)
	win.popup_centered()


# ── Moment management ─────────────────────────────────────────────────────────

func _rebuild_moment_dropdown() -> void:
	if not is_instance_valid(_moment_dropdown): return
	_moment_dropdown.clear()
	_moment_dropdown.add_item("— No moment —", 0)
	for i in range(_moments.size()):
		_moment_dropdown.add_item((_moments[i] as Dictionary)["label"] as String, i + 1)
	var sel := 0
	for i in range(_moments.size()):
		if (_moments[i] as Dictionary)["id"] == _active_moment:
			sel = i + 1; break
	_moment_dropdown.selected = sel


func _on_moment_selected(idx: int) -> void:
	if idx == 0:
		_active_moment = ""
	elif idx - 1 < _moments.size():
		_active_moment = (_moments[idx - 1] as Dictionary)["id"] as String


func _open_moments_modal() -> void:
	var win := Window.new()
	win.title = "Moments"
	win.size  = Vector2i(380, 480)
	win.wrap_controls = true
	add_child(win)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	win.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.custom_minimum_size = Vector2(350, 0)
	scroll.add_child(vb)

	var hint := Label.new()
	hint.text = "Moments let you define named time-of-day states for this level (e.g. Day, Night, Sport). Each moment can require different tenant needs and furniture configurations."
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", GameTheme.C_MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(hint)

	_rebuild_moments_list(vb, win)

	var add_btn := Button.new()
	add_btn.text = "+ Add Moment"
	add_btn.add_theme_font_size_override("font_size", 11)
	add_btn.pressed.connect(func():
		_add_moment()
		win.queue_free()
		_open_moments_modal())
	vb.add_child(add_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_font_size_override("font_size", 11)
	close_btn.pressed.connect(win.queue_free)
	vb.add_child(close_btn)

	win.close_requested.connect(win.queue_free)
	win.popup_centered()


func _rebuild_moments_list(vb: VBoxContainer, win: Window) -> void:
	const FNS := ["sleep", "sit", "work", "cook", "storage", "dine"]
	for i in range(_moments.size()):
		var m   := _moments[i] as Dictionary
		var mid := m["id"] as String

		var sep := HSeparator.new()
		vb.add_child(sep)

		# Label row
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		vb.add_child(row)

		var ef := LineEdit.new()
		ef.text = m["label"] as String
		ef.placeholder_text = "Moment name"
		ef.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ef.add_theme_font_size_override("font_size", 11)
		var ci := i
		ef.text_changed.connect(func(t: String):
			_moments[ci]["label"] = t
			_moments[ci]["id"]    = t.to_lower().replace(" ", "_")
			_rebuild_moment_dropdown())
		row.add_child(ef)

		var del_btn := Button.new()
		del_btn.text = "×"
		del_btn.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
		del_btn.pressed.connect(func():
			_delete_moment(ci)
			win.queue_free()
			_open_moments_modal())
		row.add_child(del_btn)

		# Per-moment required functions
		var fn_lbl := Label.new()
		fn_lbl.text = "Needs in this moment:"
		fn_lbl.add_theme_font_size_override("font_size", 9)
		fn_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
		vb.add_child(fn_lbl)

		var fn_hb := HBoxContainer.new()
		fn_hb.add_theme_constant_override("separation", 2)
		vb.add_child(fn_hb)

		if not _moment_funcs.has(mid):
			_moment_funcs[mid] = {}
		var mf := _moment_funcs[mid] as Dictionary

		for fn: String in FNS:
			var cb := CheckBox.new()
			cb.text = fn
			cb.button_pressed = mf.get(fn, false) as bool
			cb.add_theme_font_size_override("font_size", 9)
			var fn_copy := fn
			var mid_copy := mid
			cb.toggled.connect(func(on: bool):
				(_moment_funcs[mid_copy] as Dictionary)[fn_copy] = on)
			fn_hb.add_child(cb)


func _add_moment() -> void:
	var defaults := ["Day", "Night", "Home Office", "Sport", "Morning", "Dinner"]
	var lbl: String = defaults[mini(_moments.size(), defaults.size() - 1)]
	var mid := lbl.to_lower().replace(" ", "_")
	# Avoid duplicate ids
	var existing_ids: Array = []
	for m in _moments: existing_ids.append((m as Dictionary)["id"])
	var suffix := 2
	var base_mid := mid
	while mid in existing_ids:
		mid = base_mid + str(suffix); suffix += 1
	_moments.append({"id": mid, "label": lbl})
	_moment_funcs[mid] = {}
	_rebuild_moment_dropdown()


func _delete_moment(idx: int) -> void:
	if idx < 0 or idx >= _moments.size(): return
	var mid := (_moments[idx] as Dictionary)["id"] as String
	_moments.remove_at(idx)
	_moment_funcs.erase(mid)
	if _active_moment == mid:
		_active_moment = ""
	_rebuild_moment_dropdown()


# ── Floor management ──────────────────────────────────────────────────────────

func _make_efloor(id: String, label: String, ftype: String) -> Dictionary:
	return {
		"id": id, "label": label, "type": ftype,
		"floor_tiles": [], "mezzanine_tiles": [], "stair_tiles": [],
		"rails": [], "segments": [], "columns": []
	}

func _make_floor_trio(fid: String, lbl: String) -> Array:
	var sub  := _make_efloor(fid + "_sub",  lbl + " Subfloor", "floor_sub")
	sub["parent_id"] = fid
	var fl   := _make_efloor(fid, lbl, "floor")
	var ceil := _make_efloor(fid + "_ceil", lbl + " Ceiling",  "ceiling")
	ceil["parent_id"] = fid
	return [sub, fl, ceil]

func _init_editor_floors() -> void:
	var trio := _make_floor_trio("fl_0", "Ground Floor")
	_editor_floors = [
		_make_efloor("subfloor", "Building Subfloor", "subfloor"),
	] + trio + [
		_make_efloor("roof", "Roof / Techo", "roof"),
	]
	_active_efl = 2   # Ground Floor is at index 2
	_hidden_fl_ids.clear()
	# Default: only floor and loft layers are visible to the player
	for _efd in _editor_floors:
		var _ft := (_efd as Dictionary).get("type", "") as String
		var _fi := (_efd as Dictionary).get("id", "") as String
		if _ft not in ["floor", "loft"]:
			_hidden_fl_ids[_fi] = true

func _snapshot_to_efloor(fd: Dictionary) -> void:
	var ft: Array = []
	for t in _floor_mask:     ft.append([(t as Vector2i).x, (t as Vector2i).y])
	var mt: Array = []
	for t in _mezzanine_mask: mt.append([(t as Vector2i).x, (t as Vector2i).y])
	var st: Array = []
	for t in _stair_mask:     st.append([(t as Vector2i).x, (t as Vector2i).y])
	fd["floor_tiles"]     = ft
	fd["mezzanine_tiles"] = mt
	fd["stair_tiles"]     = st
	fd["rails"]           = _rails.duplicate(true)
	fd["segments"]        = _segments.duplicate(true)
	fd["columns"]         = _cols.duplicate(true)

func _parent_efloor(fd: Dictionary) -> Dictionary:
	var pid := fd.get("parent_id", "") as String
	if pid.is_empty(): return {}
	for efd in _editor_floors:
		if (efd as Dictionary).get("id", "") == pid: return efd as Dictionary
	return {}

func _save_active_efloor() -> void:
	if _active_efl < 0 or _active_efl >= _editor_floors.size(): return
	var fd    := _editor_floors[_active_efl] as Dictionary
	var ftype := fd.get("type", "floor") as String
	_snapshot_to_efloor(fd)
	# Derived floor types don't own their floor_tiles — clear them so save is clean
	if ftype in ["loft", "floor_sub", "ceiling"]:
		fd["floor_tiles"] = []
	_editor_floors[_active_efl] = fd

func _load_active_efloor() -> void:
	if _active_efl < 0 or _active_efl >= _editor_floors.size(): return
	var fd    := _editor_floors[_active_efl] as Dictionary
	var ftype := fd.get("type", "floor") as String
	var parent := _parent_efloor(fd)

	_floor_mask.clear()
	match ftype:
		"loft":
			# Outline = parent floor's mezzanine tiles
			for t in parent.get("mezzanine_tiles", []):
				_floor_mask[Vector2i(t[0] as int, t[1] as int)] = true
		"floor_sub", "ceiling":
			# Outline = parent floor's floor tiles
			for t in parent.get("floor_tiles", []):
				_floor_mask[Vector2i(t[0] as int, t[1] as int)] = true
		_:
			for t in fd.get("floor_tiles", []):
				_floor_mask[Vector2i(t[0] as int, t[1] as int)] = true

	_mezzanine_mask.clear()
	for t in fd.get("mezzanine_tiles", []):
		_mezzanine_mask[Vector2i(t[0] as int, t[1] as int)] = true
	_stair_mask.clear()
	for t in fd.get("stair_tiles", []):
		_stair_mask[Vector2i(t[0] as int, t[1] as int)] = true
	_rails    = (fd.get("rails",    []) as Array).duplicate(true)
	_segments = (fd.get("segments", []) as Array).duplicate(true)
	_cols     = (fd.get("columns",  []) as Array).duplicate(true)

func _switch_efloor(idx: int) -> void:
	if idx == _active_efl or idx < 0 or idx >= _editor_floors.size(): return
	_save_active_efloor()
	_active_efl = idx
	_load_active_efloor()
	_rebuild_floor()
	_refresh_fl_switcher()
	_set_status("Editing: " + (_editor_floors[idx] as Dictionary).get("label", "") as String)

func _count_efloors_of_type(ftype: String) -> int:
	var n := 0
	for fd in _editor_floors:
		if (fd as Dictionary).get("type", "") == ftype: n += 1
	return n

func _find_roof_idx() -> int:
	for i in range(_editor_floors.size() - 1, -1, -1):
		if (_editor_floors[i] as Dictionary).get("type", "") == "roof": return i
	return _editor_floors.size() - 1

func _add_efloor() -> void:
	var n      := _count_efloors_of_type("floor")
	var labels: Array[String] = ["Ground Floor", "Second Floor", "Third Floor", "Fourth Floor",
				   "Fifth Floor",  "Sixth Floor",  "Seventh Floor"]
	var lbl    := labels[mini(n, labels.size() - 1)]
	var fid    := "fl_%d" % n
	var trio   := _make_floor_trio(fid, lbl)
	var ri     := _find_roof_idx()
	_save_active_efloor()
	# Insert trio bottom→top before the roof: [sub, floor, ceiling]
	for entry in trio:
		_editor_floors.insert(ri, entry)
		ri += 1
	# Active = the main floor (middle of trio)
	_active_efl = ri - 2
	# Sub and ceiling default to hidden (floor is visible, loft will be visible when auto-added)
	_hidden_fl_ids[fid + "_sub"]  = true
	_hidden_fl_ids[fid + "_ceil"] = true
	# Auto-copy floor tiles from the nearest floor below as a starting reference
	for _k in range(_active_efl - 1, -1, -1):
		var _kfd := _editor_floors[_k] as Dictionary
		if _kfd.get("type", "") == "floor":
			var _new_fl := _editor_floors[_active_efl] as Dictionary
			_new_fl["floor_tiles"] = (_kfd.get("floor_tiles", []) as Array).duplicate(true)
			_editor_floors[_active_efl] = _new_fl
			break
	_load_active_efloor()
	_rebuild_floor()
	_refresh_fl_switcher()
	_set_status("Floor added: " + lbl + " (floor tiles copied from below as reference)")

func _delete_efloor(idx: int) -> void:
	if _count_efloors_of_type("floor") <= 1: return
	var fd    := _editor_floors[idx] as Dictionary
	var ftype := fd.get("type", "") as String
	if ftype != "floor": return
	var fid   := fd.get("id", "") as String
	# Remove floor + all entries that have this floor as parent (sub, ceiling, loft)
	var to_del: Array[int] = []
	for i in range(_editor_floors.size()):
		var efd := _editor_floors[i] as Dictionary
		if efd.get("id", "") == fid or efd.get("parent_id", "") == fid:
			to_del.append(i)
	to_del.reverse()
	for i in to_del: _editor_floors.remove_at(i)
	_active_efl = clampi(_active_efl, 0, _editor_floors.size() - 1)
	_load_active_efloor()
	_rebuild_floor()
	_refresh_fl_switcher()

func _rename_efloor_dialog(idx: int) -> void:
	var fd  := _editor_floors[idx] as Dictionary
	var win := Window.new()
	win.title = "Rename Floor"
	win.size  = Vector2i(280, 120)
	win.wrap_controls = true
	add_child(win)
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.add_theme_constant_override("separation", 8)
	win.add_child(vb)
	var le := LineEdit.new()
	le.text = fd.get("label", "") as String
	le.select_all_on_focus = true
	vb.add_child(le)
	var ok := Button.new(); ok.text = "OK"
	ok.pressed.connect(func():
		var new_lbl := le.text.strip_edges()
		if not new_lbl.is_empty():
			fd["label"] = new_lbl
			_editor_floors[idx] = fd
			_refresh_fl_switcher()
		win.queue_free())
	le.text_submitted.connect(func(_t: String): ok.pressed.emit())
	vb.add_child(ok)
	win.close_requested.connect(func(): win.queue_free())
	win.popup_centered()
	le.call_deferred("grab_focus")

func _auto_add_loft() -> void:
	var cur := _editor_floors[_active_efl] as Dictionary
	if cur.get("type", "") != "floor": return
	var cur_id  := cur.get("id", "") as String
	var loft_id := cur_id + "_loft"
	for fd in _editor_floors:
		if (fd as Dictionary).get("id", "") == loft_id: return
	var lbl     := (cur.get("label", "Floor") as String) + " Loft"
	var loft_fd := _make_efloor(loft_id, lbl, "loft")
	loft_fd["parent_id"] = cur_id
	_save_active_efloor()
	# Insert after the floor but before its ceiling (which has parent_id == cur_id and type=="ceiling")
	var insert_at := _active_efl + 1
	for _j in range(_active_efl + 1, _editor_floors.size()):
		var _efd := _editor_floors[_j] as Dictionary
		if _efd.get("type", "") == "ceiling" and _efd.get("parent_id", "") == cur_id:
			insert_at = _j; break
	_editor_floors.insert(insert_at, loft_fd)
	_refresh_fl_switcher()

func _refresh_fl_switcher() -> void:
	if not is_instance_valid(_fl_list_vb): return
	for ch in _fl_list_vb.get_children(): ch.queue_free()
	# Display top→bottom: highest index (roof) first
	for i in range(_editor_floors.size() - 1, -1, -1):
		var fd    := _editor_floors[i] as Dictionary
		var ftype := fd.get("type", "floor") as String
		var is_active := (i == _active_efl)
		var ci := i

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)

		# Indent derived/sub layers
		var indented := ftype in ["loft", "floor_sub", "ceiling"]
		if indented:
			var ind := Control.new()
			ind.custom_minimum_size = Vector2i(10, 0)
			row.add_child(ind)

		var btn := Button.new()
		btn.text = fd.get("label", "Floor") as String
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 10)
		var col := Color(0.20, 0.75, 0.95) if is_active else GameTheme.C_TEXT
		# Dim the sub-layers slightly so main floors stand out
		if ftype in ["floor_sub", "ceiling", "loft"] and not is_active:
			col = GameTheme.C_MUTED
		btn.add_theme_color_override("font_color", col)
		btn.pressed.connect(func(): _switch_efloor(ci))
		row.add_child(btn)

		# Rename allowed on all non-fixed layers
		if ftype not in ["subfloor", "roof"]:
			var ren := Button.new()
			ren.text = "✎"; ren.flat = true
			ren.custom_minimum_size = Vector2i(20, 0)
			ren.add_theme_font_size_override("font_size", 9)
			ren.pressed.connect(func(): _rename_efloor_dialog(ci))
			row.add_child(ren)

		# Delete only on main floor entries (removes paired sub/ceiling/lofts too)
		if ftype == "floor" and _count_efloors_of_type("floor") > 1:
			var del := Button.new()
			del.text = "×"; del.flat = true
			del.custom_minimum_size = Vector2i(20, 0)
			del.add_theme_font_size_override("font_size", 9)
			del.pressed.connect(func(): _delete_efloor(ci))
			row.add_child(del)

		# Visibility toggle — ● player can see this layer, ○ hidden from player
		var fid    := fd.get("id", "") as String
		var vis    := not _hidden_fl_ids.has(fid)
		var vis_btn := Button.new()
		vis_btn.text = "●" if vis else "○"
		vis_btn.flat = true
		vis_btn.custom_minimum_size = Vector2i(18, 0)
		vis_btn.add_theme_font_size_override("font_size", 8)
		var vis_col := Color(0.38, 0.78, 0.48) if vis else Color(0.42, 0.42, 0.42)
		vis_btn.add_theme_color_override("font_color", vis_col)
		vis_btn.tooltip_text = "Player can see this layer" if vis else "Hidden from player"
		vis_btn.pressed.connect(func():
			if _hidden_fl_ids.has(fid): _hidden_fl_ids.erase(fid)
			else: _hidden_fl_ids[fid] = true
			_refresh_fl_switcher())
		row.add_child(vis_btn)

		_fl_list_vb.add_child(row)

		if ftype == "roof":
			var add_btn := Button.new()
			add_btn.text = "＋ Add Floor"
			add_btn.add_theme_font_size_override("font_size", 9)
			add_btn.pressed.connect(_add_efloor)
			_fl_list_vb.add_child(add_btn)


func _sect(p: Control, t: String) -> void:
	var sep := HSeparator.new(); p.add_child(sep)
	var lbl := Label.new()
	lbl.text = t
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.add_theme_color_override("font_color", Color(0.36, 0.50, 0.66, 0.90))
	p.add_child(lbl)


func _field(p: Control, label: String, val: String) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	p.add_child(row)
	var lbl := Label.new()
	lbl.text = label + ":"
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.custom_minimum_size = Vector2(54, 0)
	row.add_child(lbl)
	var le := LineEdit.new()
	le.text = val
	le.add_theme_font_size_override("font_size", 10)
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(le)
	return le


func _spinbox(p: Control, label: String, val: int, mn: int, mx: int, step: int) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	p.add_child(row)
	var lbl := Label.new()
	lbl.text = label + ":"
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.custom_minimum_size = Vector2(64, 0)
	row.add_child(lbl)
	var sb := SpinBox.new()
	sb.min_value = mn; sb.max_value = mx; sb.step = step; sb.value = val
	sb.add_theme_font_size_override("font_size", 10)
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sb)
	return sb


func _actbtn(p: Control, label: String, col: Color, cb: Callable) -> void:
	var btn := Button.new()
	btn.text = label
	btn.add_theme_font_size_override("font_size", 11)
	btn.add_theme_color_override("font_color", col)
	btn.pressed.connect(cb)
	p.add_child(btn)


func _set_status(msg: String) -> void:
	if _status:
		_status.text = msg


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  FLOOR REBUILD                                                           ║
# ╚══════════════════════════════════════════════════════════════════════════╝

func _rebuild_floor() -> void:
	if is_instance_valid(_floor):
		_floor.queue_free()
	if is_instance_valid(_ov):
		_ov.queue_free()
	_floor = null; _ov = null

	var scene := load("res://scenes/Wall.tscn") as PackedScene
	_floor = scene.instantiate() as Floor
	_floor.set_process_input(false)
	_room.add_child(_floor)

	var floor_tiles: Array = []
	for tile in _floor_mask:
		var t := tile as Vector2i
		floor_tiles.append([t.x, t.y])

	var mezz_tiles: Array = []
	for tile in _mezzanine_mask:
		var t := tile as Vector2i
		mezz_tiles.append([t.x, t.y])

	var stair_tiles: Array = []
	for tile in _stair_mask:
		var t := tile as Vector2i
		stair_tiles.append([t.x, t.y])

	var rail_arr: Array = []
	for r in _rails:
		rail_arr.append((r as Dictionary).duplicate())

	_floor.setup({
		"id": "editor_preview", "label": "Ground Floor",
		"grid_w": _gw, "grid_h": _gh,
		"floor_tiles":     floor_tiles,
		"mezzanine_tiles": mezz_tiles,
		"stair_tiles":     stair_tiles,
		"rails":           rail_arr,
		"segments": _segments.duplicate(true),
		"columns":  _cols.duplicate(true)
	})

	# Shadow: parent floor tiles shown ghosted when on derived layers
	var _cur_efd  := _editor_floors[_active_efl] as Dictionary
	var _cur_type := _cur_efd.get("type", "") as String
	var _shadow_src: Dictionary = {}
	match _cur_type:
		"loft":
			# Show parent floor's full area as context (loft only covers part of it)
			_shadow_src = _parent_efloor(_cur_efd)
		"subfloor":
			# Show ground floor for layout reference
			for _efd in _editor_floors:
				if (_efd as Dictionary).get("type", "") == "floor":
					_shadow_src = _efd as Dictionary; break
		"floor":
			# Show the floor directly below this one as a faint reference
			# (ground floor has nothing below, so shadow stays empty)
			for _j in range(_active_efl - 1, -1, -1):
				if (_editor_floors[_j] as Dictionary).get("type", "") == "floor":
					_shadow_src = _editor_floors[_j] as Dictionary; break
		# floor_sub and ceiling use parent floor tiles as their actual floor
		# (derived in _load_active_efloor) — no extra shadow needed
	for _st in _shadow_src.get("floor_tiles", []):
		_floor.shadow_mask[Vector2i(_st[0] as int, _st[1] as int)] = true

	_ov = Node2D.new()
	_ov.set_script(_OV_SCRIPT)
	_room.add_child(_ov)
	_ov.set("floor_brush",  _floor_brush)
	_ov.set("wall_primary", _tool == Tool.PRIMARY_WALL)
	_update_placed_furniture_overlay()

	_fit_camera()


func _fit_camera() -> void:
	if not is_instance_valid(_camera) or _camera_fitted:
		return
	_camera_fitted = true

	var vp  := get_viewport().get_visible_rect().size
	var aw  := vp.x - LEFT_W - RIGHT_W - 20.0
	var ah  := vp.y - TOP_H - 16.0
	var scx := LEFT_W + aw * 0.5
	var scy := TOP_H  + ah * 0.5

	const INIT_PX_PER_TILE := 9.0
	var z := INIT_PX_PER_TILE / float(TILE_SIZE)
	_camera.zoom = Vector2(z, z)

	# Centre the camera on the middle of the grid.
	# The offset accounts for left/right/top panel asymmetry so the canvas
	# midpoint (scx, scy) maps exactly to the grid centre in world space.
	_camera.position = Vector2(_gw * TILE_SIZE * 0.5, _gh * TILE_SIZE * 0.5)
	_camera.offset = Vector2(
		(scx - vp.x * 0.5) / z,
		(scy - vp.y * 0.5) / z
	)


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  INPUT                                                                   ║
# ╚══════════════════════════════════════════════════════════════════════════╝

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not (event as InputEventKey).pressed:
		return
	var ke := event as InputEventKey
	if ke.keycode == KEY_ESCAPE:
		if not _placing_furniture_id.is_empty():
			_cancel_placement()
		else:
			_tool = Tool.WALL_VIEW
			_cancel_wall_drawing()
			if _tool_btns.has(Tool.WALL_VIEW):
				(_tool_btns[Tool.WALL_VIEW] as Button).set_pressed_no_signal(true)
			if is_instance_valid(_ov):
				_ov.set("wall_primary", false)
				_ov.set("rail_mode",    false)
				_ov.set("floor_hover",  Vector2i(-1, -1))
				_ov.set("wall_hover",   Vector2i(-1, -1))
				_ov.set("active",       false)
				_ov.queue_redraw()
		get_viewport().set_input_as_handled()
		return
	# Ctrl+R → reload scene with latest saved scripts (debug hot-reload)
	if ke.keycode == KEY_R and ke.ctrl_pressed and not ke.shift_pressed and not ke.alt_pressed:
		get_viewport().set_input_as_handled()
		get_tree().reload_current_scene()


func _input(event: InputEvent) -> void:
	if not event is InputEventMouse:
		return

	# ── Furniture placement mode ─────────────────────────────────────────────
	if not _placing_furniture_id.is_empty():
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.pressed:
				if mb.button_index == MOUSE_BUTTON_RIGHT:
					_cancel_placement()
					get_viewport().set_input_as_handled()
				elif mb.button_index == MOUSE_BUTTON_LEFT:
					var sp := (event as InputEventMouse).position
					if not _is_ui(sp):
						var fl := _to_floor(sp)
						var tx := int(fl.x / TILE_SIZE)
						var ty := int(fl.y / TILE_SIZE)
						_placed_furniture.append({"id": _placing_furniture_id, "x": tx, "y": ty})
						# Loft-creating furniture → paint footprint as mezzanine and auto-add loft floor
						var _pfdata := _furn_data_by_id(_placing_furniture_id)
						if _pfdata.get("creates_loft", false) as bool:
							var _pw: int = (_pfdata["size"] as Dictionary)["w"] as int
							var _ph: int = (_pfdata["size"] as Dictionary)["h"] as int
							for _dy in range(_ph):
								for _dx in range(_pw):
									var _mt := Vector2i(tx + _dx, ty + _dy)
									_mezzanine_mask[_mt] = true
									if is_instance_valid(_floor):
										_floor.mezzanine_mask[_mt] = true
							if is_instance_valid(_floor):
								_floor.grid_draw.queue_redraw()
							_auto_add_loft()
						_cancel_placement()
						_update_placed_furniture_overlay()
						_fill_inv_modal_rows()
						_update_inv_count_lbl()
						get_viewport().set_input_as_handled()
		elif event is InputEventMouseMotion:
			var sp := (event as InputEventMouse).position
			var fl := _to_floor(sp)
			var tx := int(fl.x / TILE_SIZE)
			var ty := int(fl.y / TILE_SIZE)
			if is_instance_valid(_ov):
				_ov.set("placing_x", tx)
				_ov.set("placing_y", ty)
				_ov.queue_redraw()
		return

	# ── Camera controls (work everywhere, not only in canvas) ────────────────
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			_pan_last = mb.position
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var vp_size := get_viewport().get_visible_rect().size
			var mx := mb.position.x
			var over_panel := mx < LEFT_W or mx > vp_size.x - RIGHT_W or mb.position.y < TOP_H
			if not over_panel:
				_do_zoom(mb.button_index == MOUSE_BUTTON_WHEEL_UP)
				get_viewport().set_input_as_handled()
			return
	elif event is InputEventMouseMotion and _panning:
		var delta := (event as InputEventMouseMotion).relative
		if is_instance_valid(_camera):
			_camera.position -= delta / _camera.zoom.x
		get_viewport().set_input_as_handled()
		return

	# ── Button releases: clean up active paint/draw state even if over UI ───
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			var has_active := _floor_painting or _mezz_painting or _stair_painting or _window_painting or _pdrawing or _door_dragging or _wv_dragging
			if has_active:
				if mb.button_index == MOUSE_BUTTON_LEFT:
					_lmb_up()
				elif mb.button_index == MOUSE_BUTTON_RIGHT:
					_rmb_up()
				get_viewport().set_input_as_handled()
				return

	# ── Tool handling (canvas area only) ─────────────────────────────────────
	var sp := (event as InputEventMouse).position
	if _is_ui(sp):
		_cancel_wall_drawing()
		return

	get_viewport().set_input_as_handled()

	var fl   := _to_floor(sp)
	var tile := Vector2i(int(fl.x / TILE_SIZE), int(fl.y / TILE_SIZE))

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return  # releases already handled before _is_ui check
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_lmb_down(fl, tile)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if _tool == Tool.FLOOR:
				_floor_painting = true; _floor_erase = true
				_paint_floor_tile(tile, true)
			elif _tool == Tool.MEZZANINE:
				_mezz_painting = true; _mezz_erase = true
				_paint_mezz_tile(tile, true)
			elif _tool == Tool.STAIRS:
				_stair_painting = true; _stair_erase = true
				_paint_stair_tile(tile, true)
			elif _tool == Tool.WINDOW:
				var hit := _detect_segment_at(fl)
				if not hit.is_empty():
					_window_painting = true; _window_erase = true
					_paint_window_tile(hit["idx"] as int, hit["pos"] as int, true)
			elif _tool == Tool.RAIL:
				_erase_rail_at(tile)
			elif _tool == Tool.WALL_VIEW:
				var hit := _detect_segment_at(fl)
				if not hit.is_empty():
					var sidx        := hit["idx"] as int
					var cursor_side := _compute_door_side(sidx, fl)
					var sd          := _segments[sidx] as Dictionary
					var sides       := (sd.get("view_sides", {}) as Dictionary).duplicate()
					if sides.has(str(cursor_side)):
						sides.erase(str(cursor_side))
						if sides.is_empty(): sd.erase("view_sides")
						else:                sd["view_sides"] = sides
						_segments[sidx] = sd
						_rebuild_floor()
						_set_status("Wall view face cleared")
			else:
				_erase_at(fl, tile)
	elif event is InputEventMouseMotion:
		if _floor_painting:
			_paint_floor_tile(tile, _floor_erase)
		elif _mezz_painting:
			_paint_mezz_tile(tile, _mezz_erase)
		elif _stair_painting:
			_paint_stair_tile(tile, _stair_erase)
		elif _window_painting:
			var hit := _detect_segment_at(fl)
			if not hit.is_empty():
				_paint_window_tile(hit["idx"] as int, hit["pos"] as int, _window_erase)
		elif _pdrawing:
			_preview_wall(tile)
		if is_instance_valid(_ov):
			var is_wall := _tool == Tool.PRIMARY_WALL or _tool == Tool.SECONDARY_WALL
			var is_rail := _tool == Tool.RAIL
			var snapped := _snap_tile(tile)
			var is_floor_like := _tool == Tool.FLOOR or _tool == Tool.MEZZANINE or _tool == Tool.STAIRS
			_ov.set("floor_hover",  tile if is_floor_like else Vector2i(-1, -1))
			_ov.set("mezz_hover",   _tool == Tool.MEZZANINE)
			_ov.set("stair_hover",  _tool == Tool.STAIRS)
			_ov.set("wall_hover",   snapped if ((is_wall or is_rail) and not _pdrawing) else Vector2i(-1, -1))
			_ov.set("wall_primary", _tool == Tool.PRIMARY_WALL)
			_ov.set("rail_mode",    is_rail)
			var win_hr := Rect2()
			if _tool == Tool.WINDOW and not _window_painting:
				var hit := _detect_segment_at(fl)
				if not hit.is_empty():
					win_hr = _segment_tile_rect(hit["idx"] as int, hit["pos"] as int)
			_ov.set("win_hover_rect", win_hr)
			# Door drag: update side from cursor position
			if _door_dragging and _door_seg_idx >= 0:
				_door_side = _compute_door_side(_door_seg_idx, fl)
				_update_door_preview()
			if _wv_dragging and _wv_seg_idx >= 0:
				_wv_side = _compute_door_side(_wv_seg_idx, fl)
				_update_wall_view_preview()
			_ov.queue_redraw()


func _do_zoom(zoom_in: bool) -> void:
	if not is_instance_valid(_camera):
		return
	var old_px := roundi(_camera.zoom.x * TILE_SIZE)
	var new_px  := clampi(old_px + (1 if zoom_in else -1), 1, 32)
	if new_px == old_px:
		return
	var new_z := float(new_px) / float(TILE_SIZE)
	# Zoom toward canvas centre so the floor stays visible
	var vp  := get_viewport().get_visible_rect().size
	var aw  := vp.x - LEFT_W - RIGHT_W - 20.0
	var ah  := vp.y - TOP_H - 16.0
	var ctr := Vector2(LEFT_W + aw * 0.5, TOP_H + ah * 0.5)
	var old_z := _camera.zoom.x
	var world_ctr := _camera.position + (ctr - vp * 0.5) / old_z
	_camera.position = world_ctr - (ctr - vp * 0.5) / new_z
	_camera.zoom     = Vector2(new_z, new_z)
	_set_status("Zoom %d px/tile  (%.0fcm visible width)" % [
		new_px, vp.x / new_z * 0.1])


func _is_ui(sp: Vector2) -> bool:
	var sz := get_viewport().get_visible_rect().size
	return sp.x < LEFT_W or sp.x > sz.x - RIGHT_W or sp.y < TOP_H


func _to_floor(sp: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * sp


func _lmb_down(fl: Vector2, tile: Vector2i) -> void:
	match _tool:
		Tool.FLOOR:
			_floor_painting = true; _floor_erase = false
			_paint_floor_tile(tile, false)
		Tool.MEZZANINE:
			_mezz_painting = true; _mezz_erase = false
			_paint_mezz_tile(tile, false)
		Tool.STAIRS:
			_stair_painting = true; _stair_erase = false
			_paint_stair_tile(tile, false)
		Tool.PRIMARY_WALL, Tool.SECONDARY_WALL, Tool.RAIL:
			_ps = _snap_tile(tile); _pe = _ps; _pdrawing = true
			if is_instance_valid(_ov):
				_ov.set("p_start", _ps)
				_ov.set("rail_mode", _tool == Tool.RAIL)
				_ov.set("p_end",   _pe)
				_ov.set("active",  true)
				_ov.queue_redraw()
		Tool.WINDOW:
			var hit := _detect_segment_at(fl)
			if not hit.is_empty():
				_window_painting = true; _window_erase = false
				_paint_window_tile(hit["idx"] as int, hit["pos"] as int, false)
			else:
				_set_status("LMB paint · RMB erase window tiles on a wall")
		Tool.DOOR:
			var hit := _detect_segment_at(fl)
			if not hit.is_empty():
				var sidx := hit["idx"] as int
				var sd   := _segments[sidx] as Dictionary
				if sd.get("has_door", false):
					sd.erase("has_door"); sd.erase("door_pos"); sd.erase("door_side")
					_segments[sidx] = sd
					_rebuild_floor()
					_set_status("Door removed")
				else:
					_door_seg_idx  = sidx
					_door_pos      = hit["pos"] as int
					_door_side     = _compute_door_side(sidx, fl)
					_door_dragging = true
					_update_door_preview()
					_set_status("Drag to choose door opening direction")
			else:
				_set_status("Click on a wall segment to add a door")
		Tool.WALL_VIEW:
			var hit := _detect_segment_at(fl)
			if not hit.is_empty():
				var sidx := hit["idx"] as int
				_wv_seg_idx  = sidx
				_wv_side     = _compute_door_side(sidx, fl)
				_wv_dragging = true
				_update_wall_view_preview()
				_set_status("Drag to choose which face · release to open")
			else:
				_set_status("Click on a wall segment to open its wall view")
		Tool.COLUMN:
			_toggle_column(_snap_tile(tile))
		Tool.ERASE:
			_erase_at(fl, tile)


func _rmb_up() -> void:
	var needs_rebuild := _floor_painting or _mezz_painting or _stair_painting or _window_painting
	_floor_painting  = false
	_mezz_painting   = false
	_stair_painting  = false
	_window_painting = false
	if needs_rebuild:
		_rebuild_floor()


func _lmb_up() -> void:
	if _floor_painting:
		_floor_painting = false
		_rebuild_floor()
		return
	if _mezz_painting:
		_mezz_painting = false
		_rebuild_floor()
		return
	if _stair_painting:
		_stair_painting = false
		_rebuild_floor()
		return
	if _window_painting:
		_window_painting = false
		_rebuild_floor()
		return
	if _door_dragging:
		_door_dragging = false
		if _door_seg_idx >= 0:
			var sd := _segments[_door_seg_idx] as Dictionary
			sd["has_door"]  = true
			sd["door_pos"]  = maxi(0, _door_pos - DOOR_LEN / 2)
			sd["door_side"] = _door_side
			_segments[_door_seg_idx] = sd
			_rebuild_floor()
			_set_status("Door added (opens %s)" % ("south/east" if _door_side > 0 else "north/west"))
		_door_seg_idx = -1
		if is_instance_valid(_ov):
			_ov.set("door_drag_active", false)
			_ov.queue_redraw()
		return
	if _wv_dragging:
		_wv_dragging = false
		var commit_idx  := _wv_seg_idx
		var commit_side := _wv_side
		_wv_seg_idx = -1
		if commit_idx >= 0:
			var sd       := _segments[commit_idx] as Dictionary
			# Migrate old single-side format if needed
			if sd.has("view_side") and not sd.has("view_sides"):
				var old_s := sd.get("view_side", 1) as int
				sd["view_sides"] = {str(old_s): sd.get("wall_items", {}) as Dictionary}
				sd.erase("view_side"); sd.erase("wall_items")
			var sides    := (sd.get("view_sides", {}) as Dictionary).duplicate(true)
			var side_key := str(commit_side)
			if not sides.has(side_key):
				var stash_key := "wv_items_" + side_key
				var stashed   := (sd.get(stash_key, {}) as Dictionary).duplicate()
				if not stashed.is_empty(): sd.erase(stash_key)
				sides[side_key] = stashed
				sd["view_sides"] = sides
				_segments[commit_idx] = sd
				_rebuild_floor()
				_set_status("Wall view → %s face" % ("south/east" if commit_side > 0 else "north/west"))
			else:
				_set_status("Opening %s face" % ("south/east" if commit_side > 0 else "north/west"))
			_open_wall_view_modal(commit_idx, commit_side)
			if is_instance_valid(_ov):
				_ov.set("wv_drag_active", false)
				_ov.queue_redraw()
			return
		if is_instance_valid(_ov):
			_ov.set("wv_drag_active", false)
			_ov.queue_redraw()
		return
	if not _pdrawing:
		return
	_pdrawing = false
	if is_instance_valid(_ov):
		_ov.set("active", false)
		_ov.queue_redraw()
	if _ps.x >= 0 and _ps != _pe and (_ps.x == _pe.x or _ps.y == _pe.y):
		if _tool == Tool.RAIL:
			_rails.append({"x1": _ps.x, "y1": _ps.y, "x2": _pe.x, "y2": _pe.y})
			_rebuild_floor()
			_set_status("Rail added (%d tiles)" % maxi(absi(_pe.x - _ps.x), absi(_pe.y - _ps.y)))
		else:
			var primary := (_tool == Tool.PRIMARY_WALL)
			_segments.append({
				"x1": _ps.x, "y1": _ps.y, "x2": _pe.x, "y2": _pe.y,
				"primary": primary, "demolished": false
			})
			_rebuild_floor()
			var kind := "Primary" if primary else "Secondary"
			_set_status(kind + " wall added (%d tiles)" % maxi(absi(_pe.x - _ps.x), absi(_pe.y - _ps.y)))
	_ps = Vector2i(-1, -1)


func _preview_wall(tile: Vector2i) -> void:
	var t := _snap_tile(tile)
	if abs(t.x - _ps.x) >= abs(t.y - _ps.y):
		t.y = _ps.y
	else:
		t.x = _ps.x
	_pe = t
	if is_instance_valid(_ov):
		_ov.set("p_end", _pe)
		_ov.queue_redraw()


func _cancel_wall_drawing() -> void:
	_floor_painting  = false
	_mezz_painting   = false
	_stair_painting  = false
	_window_painting = false
	if _door_dragging:
		_door_dragging = false
		_door_seg_idx  = -1
		if is_instance_valid(_ov):
			_ov.set("door_drag_active", false)
			_ov.queue_redraw()
	if _wv_dragging:
		_wv_dragging = false
		_wv_seg_idx  = -1
		if is_instance_valid(_ov):
			_ov.set("wv_drag_active", false)
			_ov.queue_redraw()
	if not _pdrawing:
		return
	_pdrawing = false
	_ps = Vector2i(-1, -1)
	if is_instance_valid(_ov):
		_ov.set("active", false)
		_ov.queue_redraw()


func _snap_tile(tile: Vector2i) -> Vector2i:
	# Walls and columns always snap to 1-tile precision regardless of floor brush size
	return tile


func _active_floor_type() -> String:
	if _active_efl < 0 or _active_efl >= _editor_floors.size(): return "floor"
	return (_editor_floors[_active_efl] as Dictionary).get("type", "floor") as String

func _paint_floor_tile(tile: Vector2i, erase: bool) -> void:
	# Floor outline is derived for these types — painting does nothing meaningful
	var ft := _active_floor_type()
	if ft in ["loft", "floor_sub", "ceiling"]:
		_set_status("Floor boundary is set by the parent floor on this layer")
		return
	var half := _floor_brush / 2
	var changed := false
	for dy in range(_floor_brush):
		for dx in range(_floor_brush):
			var t := Vector2i(tile.x + dx - half, tile.y + dy - half)
			if t.x < 0 or t.x >= _gw or t.y < 0 or t.y >= _gh:
				continue
			if erase:
				if t in _floor_mask:
					_floor_mask.erase(t)
					if is_instance_valid(_floor):
						_floor.floor_mask.erase(t)
					changed = true
			else:
				if t not in _floor_mask:
					_floor_mask[t] = true
					if is_instance_valid(_floor):
						_floor.floor_mask[t] = true
					changed = true
	if changed and is_instance_valid(_floor):
		_floor.grid_draw.queue_redraw()


func _paint_mezz_tile(tile: Vector2i, erase: bool) -> void:
	if _active_floor_type() != "floor":
		_set_status("Mezzanines can only be painted on floor layers")
		return
	var half := _floor_brush / 2
	var changed := false
	for dy in range(_floor_brush):
		for dx in range(_floor_brush):
			var t := Vector2i(tile.x + dx - half, tile.y + dy - half)
			if t.x < 0 or t.x >= _gw or t.y < 0 or t.y >= _gh:
				continue
			if erase:
				if t in _mezzanine_mask:
					_mezzanine_mask.erase(t)
					if is_instance_valid(_floor):
						_floor.mezzanine_mask.erase(t)
					changed = true
			else:
				if t not in _mezzanine_mask:
					_mezzanine_mask[t] = true
					if is_instance_valid(_floor):
						_floor.mezzanine_mask[t] = true
					changed = true
	if changed:
		if is_instance_valid(_floor):
			_floor.grid_draw.queue_redraw()
		if not _mezzanine_mask.is_empty():
			_auto_add_loft()


func _paint_stair_tile(tile: Vector2i, erase: bool) -> void:
	if _active_floor_type() != "floor":
		_set_status("Stairs can only be placed on floor layers")
		return
	var half := _floor_brush / 2
	var changed := false
	for dy in range(_floor_brush):
		for dx in range(_floor_brush):
			var t := Vector2i(tile.x + dx - half, tile.y + dy - half)
			if t.x < 0 or t.x >= _gw or t.y < 0 or t.y >= _gh:
				continue
			if erase:
				if t in _stair_mask:
					_stair_mask.erase(t)
					if is_instance_valid(_floor):
						_floor.stair_mask.erase(t)
					changed = true
			else:
				if t not in _stair_mask:
					_stair_mask[t] = true
					if is_instance_valid(_floor):
						_floor.stair_mask[t] = true
					changed = true
	if changed and is_instance_valid(_floor):
		_floor.grid_draw.queue_redraw()


func _detect_segment_at(fl: Vector2) -> Dictionary:
	var best_d := INF
	var best_i := -1
	var best_p := 0
	for i in range(_segments.size()):
		var sd := _segments[i] as Dictionary
		if sd.get("demolished", false):
			continue
		var x1: int = sd["x1"]; var y1: int = sd["y1"]
		var x2: int = sd["x2"]; var y2: int = sd["y2"]
		var primary := sd.get("primary", false) as bool
		var thick   := 2 if primary else 1   # tiles
		var is_h    := (y1 == y2)
		var mn_x    := mini(x1, x2);  var mx_x := maxi(x1, x2)
		var mn_y    := mini(y1, y2);  var mx_y := maxi(y1, y2)

		# Build the wall rect exactly as GridDraw renders it (coff = 0)
		var wr: Rect2
		if is_h:
			wr = Rect2(mn_x * TILE_SIZE, y1 * TILE_SIZE,
					   (mx_x - mn_x) * TILE_SIZE, thick * TILE_SIZE)
		else:
			wr = Rect2(x1 * TILE_SIZE, mn_y * TILE_SIZE,
					   thick * TILE_SIZE, (mx_y - mn_y) * TILE_SIZE)

		# Expand by 1 tile as margin so clicks just outside also register
		var margin := float(TILE_SIZE)
		var wr_exp := wr.grow(margin)
		if not wr_exp.has_point(fl):
			continue

		# Project click onto segment axis to get position along wall (in tiles)
		var along: float
		var d: float
		if is_h:
			along = clampf(fl.x - mn_x * TILE_SIZE, 0.0, (mx_x - mn_x) * TILE_SIZE)
			d     = absf(fl.y - (y1 * TILE_SIZE + thick * TILE_SIZE * 0.5))
		else:
			along = clampf(fl.y - mn_y * TILE_SIZE, 0.0, (mx_y - mn_y) * TILE_SIZE)
			d     = absf(fl.x - (x1 * TILE_SIZE + thick * TILE_SIZE * 0.5))

		if d < best_d:
			best_d = d
			best_i = i
			best_p = int(along / TILE_SIZE)
	if best_i < 0:
		return {}
	return {"idx": best_i, "pos": best_p}


func _paint_window_tile(seg_idx: int, pos: int, erase: bool) -> void:
	var sd := _segments[seg_idx] as Dictionary
	var tiles: Array = sd.get("window_tiles", []) as Array
	if not sd.has("window_tiles"):
		# Migrate old format if present
		if sd.get("has_window", false) as bool:
			var wp: int = sd.get("window_pos", 0) as int
			var wl: int = sd.get("window_len", 10) as int
			for ti in range(wp, wp + wl):
				tiles.append(ti)
			sd.erase("has_window"); sd.erase("window_pos"); sd.erase("window_len")
	if erase:
		tiles.erase(pos)
	else:
		if pos not in tiles:
			tiles.append(pos)
	sd["window_tiles"] = tiles
	_segments[seg_idx] = sd
	# Live preview — sync to floor node without full rebuild
	if is_instance_valid(_floor) and seg_idx < _floor.segments.size():
		_floor.segments[seg_idx] = sd.duplicate(true)
		_floor.grid_draw.queue_redraw()


func _segment_tile_rect(seg_idx: int, pos: int) -> Rect2:
	var sd := _segments[seg_idx] as Dictionary
	var x1: int = sd["x1"]; var y1: int = sd["y1"]
	var x2: int = sd["x2"]; var y2: int = sd["y2"]
	var thick := 2 if bool(sd.get("primary", false)) else 1
	var is_h  := (y1 == y2)
	var mn_x  := mini(x1, x2); var mn_y := mini(y1, y2)
	if is_h:
		return Rect2((mn_x + pos) * TILE_SIZE, y1 * TILE_SIZE,
					 TILE_SIZE, thick * TILE_SIZE)
	else:
		return Rect2(x1 * TILE_SIZE, (mn_y + pos) * TILE_SIZE,
					 thick * TILE_SIZE, TILE_SIZE)


func _update_cat_filter_lbl() -> void:
	if not is_instance_valid(_cat_filter_lbl):
		return
	_cat_filter_lbl.text = "No restrictions" if _allowed_furniture.is_empty() \
		else "%d item(s) restricted" % _allowed_furniture.size()


func _update_inv_count_lbl() -> void:
	if not is_instance_valid(_inv_count_lbl):
		return
	var total := 0
	for e in _starting_inventory:
		total += (e as Dictionary)["count"] as int
	total += _placed_furniture.size()
	_inv_count_lbl.text = "Empty" if total == 0 else "%d item(s)" % total


# ── Catalog filter modal ──────────────────────────────────────────────────────

func _open_catalog_filter_modal() -> void:
	var win := Window.new()
	win.title = "Catalog Filter"
	win.size = Vector2i(300, 520)
	win.wrap_controls = true
	win.close_requested.connect(func():
		_update_cat_filter_lbl()
		win.queue_free())
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	win.add_child(panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(outer)
	var hint := Label.new()
	hint.text = "Uncheck items to hide them from the shop.\nAll checked = no restrictions."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.add_theme_font_size_override("font_size", 10)
	outer.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)
	var local_checks: Dictionary = {}
	var allow_all := Button.new()
	allow_all.text = "Allow All"
	allow_all.add_theme_font_size_override("font_size", 10)
	allow_all.pressed.connect(func():
		_allowed_furniture.clear()
		for cid in local_checks:
			(local_checks[cid] as CheckButton).button_pressed = true)
	vb.add_child(allow_all)
	for f in _furn_catalog:
		var fid   := f["id"] as String
		var fname := f["name"] as String
		var cb := CheckButton.new()
		cb.text = fname
		cb.button_pressed = fid not in _allowed_furniture
		cb.add_theme_font_size_override("font_size", 10)
		cb.toggled.connect(func(on: bool):
			if on:
				_allowed_furniture.erase(fid)
			else:
				if fid not in _allowed_furniture:
					_allowed_furniture.append(fid))
		vb.add_child(cb)
		local_checks[fid] = cb
	add_child(win)
	win.popup_centered()


# ── Starting furniture modal ──────────────────────────────────────────────────

func _open_starting_inv_modal() -> void:
	if is_instance_valid(_inv_modal_win):
		_fill_inv_modal_rows()
		_inv_modal_win.show()
		return
	_inv_modal_win = Window.new()
	_inv_modal_win.title = "Starting Furniture"
	_inv_modal_win.size = Vector2i(360, 500)
	_inv_modal_win.wrap_controls = true
	_inv_modal_win.close_requested.connect(func():
		_cancel_placement()
		_inv_modal_win.hide()
		_update_inv_count_lbl())
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_inv_modal_win.add_child(panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(outer)
	var hint := Label.new()
	hint.text = "Add furniture pre-placed in the apartment.\n\"Place\" → click the floor to set its position.\nItems without position stay in the player's inventory."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.add_theme_font_size_override("font_size", 10)
	outer.add_child(hint)
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 4)
	outer.add_child(add_row)
	var opt := OptionButton.new()
	opt.add_theme_font_size_override("font_size", 10)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for f in _furn_catalog:
		opt.add_item(f["name"] as String)
	add_row.add_child(opt)
	var add_btn := Button.new()
	add_btn.text = "Add"
	add_btn.add_theme_font_size_override("font_size", 10)
	add_btn.pressed.connect(func():
		var idx := opt.selected
		if idx < 0 or idx >= _furn_catalog.size():
			return
		var fid := (_furn_catalog[idx] as Dictionary)["id"] as String
		for entry in _starting_inventory:
			if (entry as Dictionary)["id"] == fid:
				(entry as Dictionary)["count"] = (entry as Dictionary)["count"] as int + 1
				_fill_inv_modal_rows()
				return
		_starting_inventory.append({"id": fid, "count": 1})
		_fill_inv_modal_rows())
	add_row.add_child(add_btn)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	_inv_list_vb = VBoxContainer.new()
	_inv_list_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inv_list_vb.add_theme_constant_override("separation", 4)
	scroll.add_child(_inv_list_vb)
	_fill_inv_modal_rows()
	add_child(_inv_modal_win)
	_inv_modal_win.popup_centered()


func _fill_inv_modal_rows() -> void:
	if not is_instance_valid(_inv_list_vb):
		return
	for c in _inv_list_vb.get_children():
		c.queue_free()

	# ── Inventory items (unpositioned) ────────────────────────────────────
	if not _starting_inventory.is_empty():
		var hdr := Label.new()
		hdr.text = "IN INVENTORY"
		hdr.add_theme_font_size_override("font_size", 9)
		hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
		_inv_list_vb.add_child(hdr)
	for i in range(_starting_inventory.size()):
		var entry := _starting_inventory[i] as Dictionary
		var fid   := entry["id"] as String
		var cnt   := entry["count"] as int
		var fdata := _furn_data_by_id(fid)
		var fname := fdata.get("name", fid) as String
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_inv_list_vb.add_child(row)
		var lbl := Label.new()
		lbl.text = fname
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 10)
		row.add_child(lbl)
		var minus := Button.new(); minus.text = "−"; minus.add_theme_font_size_override("font_size", 10)
		var ci := i
		minus.pressed.connect(func():
			var e := _starting_inventory[ci] as Dictionary
			e["count"] = (e["count"] as int) - 1
			if (e["count"] as int) <= 0:
				_starting_inventory.remove_at(ci)
			_fill_inv_modal_rows())
		row.add_child(minus)
		var cnt_lbl := Label.new()
		cnt_lbl.text = "×%d" % cnt
		cnt_lbl.add_theme_font_size_override("font_size", 10)
		cnt_lbl.custom_minimum_size.x = 20
		row.add_child(cnt_lbl)
		var plus := Button.new(); plus.text = "+"; plus.add_theme_font_size_override("font_size", 10)
		plus.pressed.connect(func():
			(_starting_inventory[ci] as Dictionary)["count"] = (_starting_inventory[ci] as Dictionary)["count"] as int + 1
			_fill_inv_modal_rows())
		row.add_child(plus)
		var place_btn := Button.new()
		place_btn.text = "Place"
		place_btn.add_theme_font_size_override("font_size", 10)
		place_btn.add_theme_color_override("font_color", Color(0.40, 0.82, 0.54))
		place_btn.pressed.connect(func():
			var fw: int = (fdata.get("size", {}) as Dictionary).get("w", 5) as int
			var fh: int = (fdata.get("size", {}) as Dictionary).get("h", 5) as int
			_start_placement(fid, fw, fh, Color("#" + fdata.get("color", "888888") as String)))
		row.add_child(place_btn)

	# ── Pre-placed furniture ────────────────────────────────────────────────
	if not _placed_furniture.is_empty():
		var sep := HSeparator.new()
		_inv_list_vb.add_child(sep)
		var hdr2 := Label.new()
		hdr2.text = "PLACED IN APARTMENT"
		hdr2.add_theme_font_size_override("font_size", 9)
		hdr2.add_theme_color_override("font_color", GameTheme.C_MUTED)
		_inv_list_vb.add_child(hdr2)
	for pi in range(_placed_furniture.size()):
		var pf     := _placed_furniture[pi] as Dictionary
		var pfid   := pf["id"] as String
		var pfdata := _furn_data_by_id(pfid)
		var pfname := pfdata.get("name", pfid) as String
		var prow := HBoxContainer.new()
		prow.add_theme_constant_override("separation", 4)
		_inv_list_vb.add_child(prow)
		var plbl := Label.new()
		plbl.text = pfname + " (%d,%d)" % [pf["x"] as int, pf["y"] as int]
		plbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		plbl.add_theme_font_size_override("font_size", 10)
		prow.add_child(plbl)
		var pci := pi
		var del_btn := Button.new()
		del_btn.text = "×"
		del_btn.add_theme_font_size_override("font_size", 10)
		del_btn.add_theme_color_override("font_color", Color(0.80, 0.30, 0.20))
		del_btn.pressed.connect(func():
			_placed_furniture.remove_at(pci)
			_update_placed_furniture_overlay()
			_fill_inv_modal_rows())
		prow.add_child(del_btn)

		# Per-moment extended states (foldable furniture only, when moments exist)
		if not _moments.is_empty() and pfdata.get("foldable", false) as bool:
			if not pf.has("moment_states"):
				pf["moment_states"] = {}
			var ms_hb := HBoxContainer.new()
			ms_hb.add_theme_constant_override("separation", 8)
			_inv_list_vb.add_child(ms_hb)
			var ms_lbl := Label.new()
			ms_lbl.text = "    ↳"
			ms_lbl.add_theme_font_size_override("font_size", 9)
			ms_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
			ms_hb.add_child(ms_lbl)
			for m in _moments:
				var mid  := (m as Dictionary)["id"]    as String
				var mlbl := (m as Dictionary)["label"] as String
				var ms   := pf["moment_states"] as Dictionary
				if not ms.has(mid): ms[mid] = {}
				var cb := CheckBox.new()
				cb.text           = mlbl + " extended"
				cb.button_pressed = (ms[mid] as Dictionary).get("extended", false) as bool
				cb.add_theme_font_size_override("font_size", 9)
				var mid_copy := mid
				var pf_ref   := pf
				cb.toggled.connect(func(on: bool):
					var msd := (pf_ref as Dictionary).get("moment_states", {}) as Dictionary
					if not msd.has(mid_copy): msd[mid_copy] = {}
					(msd[mid_copy] as Dictionary)["extended"] = on)
				ms_hb.add_child(cb)


func _furn_data_by_id(fid: String) -> Dictionary:
	for f in _furn_catalog:
		if (f as Dictionary)["id"] == fid:
			return f as Dictionary
	return {}


func _start_placement(fid: String, fw: int, fh: int, col: Color) -> void:
	_placing_furniture_id = fid
	_placing_furn_size    = Vector2i(fw, fh)
	_placing_furn_col     = col
	if is_instance_valid(_inv_modal_win):
		_inv_modal_win.hide()
	if is_instance_valid(_ov):
		_ov.set("placing_active", true)
		_ov.set("placing_w", fw)
		_ov.set("placing_h", fh)
		_ov.set("placing_col", col)
		_ov.queue_redraw()
	_set_status("Click floor to place — RMB / Esc to cancel")


func _cancel_placement() -> void:
	if _placing_furniture_id.is_empty():
		return
	_placing_furniture_id = ""
	_placing_furn_size    = Vector2i.ZERO
	if is_instance_valid(_ov):
		_ov.set("placing_active", false)
		_ov.queue_redraw()
	_set_status("Placement cancelled")


func _update_placed_furniture_overlay() -> void:
	if not is_instance_valid(_ov):
		return
	var display: Array = []
	for pf in _placed_furniture:
		var fid   := (pf as Dictionary)["id"] as String
		var fdata := _furn_data_by_id(fid)
		var fw: int = (fdata.get("size", {}) as Dictionary).get("w", 5) as int
		var fh: int = (fdata.get("size", {}) as Dictionary).get("h", 5) as int
		display.append({
			"x": (pf as Dictionary)["x"] as int,
			"y": (pf as Dictionary)["y"] as int,
			"w": fw, "h": fh,
			"col": Color("#" + fdata.get("color", "888888") as String)
		})
	_ov.set("placed_furniture", display)
	_ov.queue_redraw()


func _confirm_clear_all() -> void:
	if not is_instance_valid(_clear_dlg):
		_clear_dlg = ConfirmationDialog.new()
		_clear_dlg.title = "Clear All"
		_clear_dlg.dialog_text = "This will erase all floor tiles, walls, doors, windows and rails.\nCannot be undone. Continue?"
		_clear_dlg.get_ok_button().text = "Clear"
		_clear_dlg.confirmed.connect(func():
			_floor_mask.clear(); _mezzanine_mask.clear(); _stair_mask.clear()
			_segments.clear(); _rails.clear(); _cols.clear()
			_rebuild_floor()
			_set_status("Canvas cleared"))
		add_child(_clear_dlg)
	_clear_dlg.popup_centered()


# Returns +1 (south/east) or -1 (north/west) based on cursor position vs wall.
func _compute_door_side(seg_idx: int, fl: Vector2) -> int:
	var sd   := _segments[seg_idx] as Dictionary
	var is_h := (sd["y1"] as int) == (sd["y2"] as int)
	if is_h:
		return -1 if fl.y < (sd["y1"] as int) * TILE_SIZE else 1
	else:
		return -1 if fl.x < (sd["x1"] as int) * TILE_SIZE else 1


# Push door drag preview data to the overlay.
func _update_door_preview() -> void:
	if not is_instance_valid(_ov) or _door_seg_idx < 0:
		return
	var sd    := _segments[_door_seg_idx] as Dictionary
	var is_h  := (sd["y1"] as int) == (sd["y2"] as int)
	var mn_x  := mini(sd["x1"] as int, sd["x2"] as int)
	var mn_y  := mini(sd["y1"] as int, sd["y2"] as int)
	var dp    := maxi(0, _door_pos - DOOR_LEN / 2)
	var hinge := Vector2(
		((mn_x + dp) * TILE_SIZE) if is_h else (sd["x1"] as int) * TILE_SIZE,
		(sd["y1"] as int) * TILE_SIZE if is_h else (mn_y + dp) * TILE_SIZE
	)
	_ov.set("door_drag_active", true)
	_ov.set("door_drag_hinge",  hinge)
	_ov.set("door_drag_is_h",   is_h)
	_ov.set("door_drag_side",   _door_side)
	_ov.set("door_drag_len",    float(DOOR_LEN * TILE_SIZE))


func _update_wall_view_preview() -> void:
	if not is_instance_valid(_ov) or _wv_seg_idx < 0:
		return
	var sd      := _segments[_wv_seg_idx] as Dictionary
	var is_h    := (sd["y1"] as int) == (sd["y2"] as int)
	var mn_x    := mini(sd["x1"] as int, sd["x2"] as int)
	var mn_y    := mini(sd["y1"] as int, sd["y2"] as int)
	var seg_len := maxi(absi((sd["x2"] as int) - (sd["x1"] as int)),
						absi((sd["y2"] as int) - (sd["y1"] as int)))
	var thick   := 2 if (sd.get("primary", false) as bool) else 1
	var hinge: Vector2
	if is_h:
		hinge = Vector2((mn_x + seg_len / 2.0) * TILE_SIZE,
						(sd["y1"] as int) * TILE_SIZE + thick * TILE_SIZE * 0.5)
	else:
		hinge = Vector2((sd["x1"] as int) * TILE_SIZE + thick * TILE_SIZE * 0.5,
						(mn_y + seg_len / 2.0) * TILE_SIZE)
	_ov.set("wv_drag_active", true)
	_ov.set("wv_drag_hinge",  hinge)
	_ov.set("wv_drag_is_h",   is_h)
	_ov.set("wv_drag_side",   _wv_side)
	_ov.set("wv_drag_thick",  thick)


# ── Wall-view elevation modal ─────────────────────────────────────────────────

func _open_wall_view_modal(seg_idx: int, side: int) -> void:
	if is_instance_valid(_wv_modal_win):
		if _wv_modal_seg == seg_idx and _wv_modal_side == side:
			_wv_modal_win.show(); return
		_wv_modal_win.queue_free()

	_wv_modal_seg  = seg_idx
	_wv_modal_side = side
	_wv_modal_sfid = ""

	var sd   := _segments[seg_idx] as Dictionary
	var is_h := (sd["y1"] as int) == (sd["y2"] as int)
	var vs   := side
	var seg_len := maxi(absi((sd["x2"] as int) - (sd["x1"] as int)),
						absi((sd["y2"] as int) - (sd["y1"] as int)))
	var side_lbl: String
	if   is_h and vs > 0:  side_lbl = "south"
	elif is_h:              side_lbl = "north"
	elif vs > 0:            side_lbl = "east"
	else:                   side_lbl = "west"

	_wv_modal_win = Window.new()
	_wv_modal_win.title = "Wall View — %s face (%d tiles wide)" % [side_lbl, seg_len]
	var win_w := mini(seg_len * WV_TS + 40, 1100)
	_wv_modal_win.size = Vector2i(win_w, WV_H * WV_TS + 120)
	_wv_modal_win.wrap_controls = true
	_wv_modal_win.close_requested.connect(func():
		# Stash wall items so they survive the arrow removal
		if _wv_modal_seg >= 0 and _wv_modal_seg < _segments.size():
			var _csd   := _segments[_wv_modal_seg] as Dictionary
			var _csides := (_csd.get("view_sides", {}) as Dictionary).duplicate(true)
			var _csk   := str(_wv_modal_side)
			if _csides.has(_csk):
				_csd["wv_items_" + _csk] = _csides[_csk]
				_csides.erase(_csk)
				if _csides.is_empty(): _csd.erase("view_sides")
				else:                  _csd["view_sides"] = _csides
				_segments[_wv_modal_seg] = _csd
				_rebuild_floor()
		_wv_modal_sfid = ""
		_wv_modal_win.hide())

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wv_modal_win.add_child(panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(outer)

	# Shop strip — wall-placement furniture
	var shop_hdr := Label.new()
	shop_hdr.text = "WALL ITEMS  (LMB place · RMB remove)"
	shop_hdr.add_theme_font_size_override("font_size", 9)
	shop_hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	outer.add_child(shop_hdr)
	var shop := HBoxContainer.new()
	shop.add_theme_constant_override("separation", 4)
	outer.add_child(shop)
	_wv_modal_grp = ButtonGroup.new()
	for f in _furn_catalog:
		var fd := f as Dictionary
		if fd.get("placement", "floor") != "wall":
			continue
		var fid := fd["id"] as String
		var btn := Button.new()
		btn.text = fd["name"] as String
		btn.toggle_mode = true; btn.button_group = _wv_modal_grp
		btn.add_theme_font_size_override("font_size", 10)
		btn.toggled.connect(func(on: bool): _wv_modal_sfid = fid if on else "")
		shop.add_child(btn)

	# Scrollable draw area
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	_wv_modal_draw = Control.new()
	_wv_modal_draw.custom_minimum_size = Vector2(seg_len * WV_TS, WV_H * WV_TS)
	_wv_modal_draw.mouse_filter = Control.MOUSE_FILTER_STOP
	_wv_modal_draw.draw.connect(func(): _draw_wv_elevation())
	_wv_modal_draw.gui_input.connect(func(ev: InputEvent): _on_wv_draw_input(ev))
	scroll.add_child(_wv_modal_draw)

	add_child(_wv_modal_win)
	_wv_modal_win.popup_centered()


func _draw_wv_elevation() -> void:
	if not is_instance_valid(_wv_modal_draw) or _wv_modal_seg < 0:
		return
	var draw := _wv_modal_draw
	var sd := _segments[_wv_modal_seg] as Dictionary
	var seg_len := maxi(absi((sd["x2"] as int) - (sd["x1"] as int)),
						absi((sd["y2"] as int) - (sd["y1"] as int)))
	var rw := seg_len * WV_TS
	var rh := WV_H * WV_TS

	draw.draw_rect(Rect2(0, 0, rw, rh), Color(0.93, 0.90, 0.83))
	for x in range(seg_len + 1):
		draw.draw_line(Vector2(x * WV_TS, 0), Vector2(x * WV_TS, rh),
			Color(0.55, 0.52, 0.44, 0.22), 0.5)
	for y in range(WV_H + 1):
		draw.draw_line(Vector2(0, y * WV_TS), Vector2(rw, y * WV_TS),
			Color(0.55, 0.52, 0.44, 0.22), 0.5)
	for x in range(0, seg_len + 1, 10):
		draw.draw_line(Vector2(x * WV_TS, 0), Vector2(x * WV_TS, rh),
			Color(0.45, 0.42, 0.34, 0.50), 1.0)
	for y in range(0, WV_H + 1, 10):
		draw.draw_line(Vector2(0, y * WV_TS), Vector2(rw, y * WV_TS),
			Color(0.45, 0.42, 0.34, 0.50), 1.0)
	draw.draw_line(Vector2(0, rh), Vector2(rw, rh), Color(0.16, 0.13, 0.10), 4.0)
	draw.draw_line(Vector2(0, 0),  Vector2(rw, 0),  Color(0.16, 0.13, 0.10), 2.0)

	# Windows
	var win_tiles: Array = _wv_collect_win_tiles(sd, seg_len)
	var win_runs: Array = _wv_tile_runs(win_tiles)
	for run in win_runs:
		var ws: int = run[0]; var we: int = run[1]
		var sill := 8 * WV_TS; var wh_px := 12 * WV_TS
		var wy := rh - sill - wh_px
		var wx := ws * WV_TS; var wlen := (we - ws) * WV_TS
		draw.draw_rect(Rect2(wx, wy, wlen, wh_px), Color(0.55, 0.80, 0.95))
		draw.draw_rect(Rect2(wx - 2, wy + wh_px, wlen + 4, 3), Color(0.85, 0.80, 0.72))
		draw.draw_rect(Rect2(wx, wy, wlen, wh_px), Color(0.92, 0.90, 0.85), false, 3.0)
		draw.draw_line(Vector2(wx + wlen * 0.5, wy), Vector2(wx + wlen * 0.5, wy + wh_px),
			Color(0.92, 0.90, 0.85), 2.0)
		draw.draw_line(Vector2(wx, wy + wh_px * 0.5), Vector2(wx + wlen, wy + wh_px * 0.5),
			Color(0.92, 0.90, 0.85), 2.0)
		# Restricted zone overlay
		draw.draw_rect(Rect2(wx, 0, wlen, rh), Color(1, 0.30, 0.20, 0.07))
		draw.draw_rect(Rect2(wx, 0, wlen, rh), Color(1, 0.30, 0.20, 0.28), false, 1.0)

	# Door
	if sd.get("has_door", false) as bool:
		var dp: int = sd.get("door_pos", 0) as int
		var dw := 10 * WV_TS; var dh_px := 21 * WV_TS
		var dy := rh - dh_px
		draw.draw_rect(Rect2(dp * WV_TS, dy, dw, dh_px), Color(0.12, 0.08, 0.05))
		draw.draw_rect(Rect2(dp * WV_TS + 3, dy + 3, dw - 6, dh_px - 3), Color(0.62, 0.43, 0.22))
		draw.draw_rect(Rect2(dp * WV_TS, dy, dw, dh_px), Color(0.35, 0.22, 0.10), false, 3.0)
		draw.draw_rect(Rect2(dp * WV_TS, 0, dw, rh), Color(1, 0.30, 0.20, 0.07))
		draw.draw_rect(Rect2(dp * WV_TS, 0, dw, rh), Color(1, 0.30, 0.20, 0.28), false, 1.0)

	# Wall items (side-specific)
	var _sides_dict := sd.get("view_sides", {}) as Dictionary
	var wall_items: Dictionary = (_sides_dict.get(str(_wv_modal_side), {}) as Dictionary)
	for key in wall_items:
		var parts := (key as String).split(",")
		var ox := parts[0].to_int(); var oy := parts[1].to_int()
		var fid := wall_items[key] as String
		var fdata := _furn_data_by_id(fid)
		if fdata.is_empty(): continue
		var iw: int = fdata["size"]["w"] as int
		var ih: int = fdata.get("wall_h", 3) as int
		var col := Color("#" + (fdata.get("color", "888888") as String))
		draw.draw_rect(Rect2(ox*WV_TS+1, oy*WV_TS+1, iw*WV_TS-2, ih*WV_TS-2), col)
		draw.draw_rect(Rect2(ox*WV_TS+1, oy*WV_TS+1, iw*WV_TS-2, ih*WV_TS-2),
			Color(0, 0, 0, 0.45), false, 1.0)
		draw.draw_string(ThemeDB.fallback_font,
			Vector2(ox*WV_TS+3, oy*WV_TS+11), fdata["name"] as String,
			HORIZONTAL_ALIGNMENT_LEFT, iw*WV_TS-6, 9, Color(0.16, 0.13, 0.10, 0.90))


func _on_wv_draw_input(event: InputEvent) -> void:
	if _wv_modal_seg < 0 or not is_instance_valid(_wv_modal_draw):
		return
	if not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed:
		return
	var mb  := event as InputEventMouseButton
	var sd  := _segments[_wv_modal_seg] as Dictionary
	var seg_len := maxi(absi((sd["x2"] as int) - (sd["x1"] as int)),
						absi((sd["y2"] as int) - (sd["y1"] as int)))
	var tile      := Vector2i(int(mb.position.x / WV_TS), int(mb.position.y / WV_TS))
	var side_key  := str(_wv_modal_side)
	var sides_d   := (sd.get("view_sides", {}) as Dictionary).duplicate(true)
	var wall_items: Dictionary = (sides_d.get(side_key, {}) as Dictionary).duplicate()

	if mb.button_index == MOUSE_BUTTON_RIGHT:
		var to_del := ""
		for key in wall_items:
			var parts := (key as String).split(",")
			var ox := parts[0].to_int(); var oy := parts[1].to_int()
			var fid := wall_items[key] as String
			var fd  := _furn_data_by_id(fid)
			if fd.is_empty(): continue
			var iw: int = fd["size"]["w"] as int
			var ih: int = fd.get("wall_h", 3) as int
			if tile.x >= ox and tile.x < ox + iw and tile.y >= oy and tile.y < oy + ih:
				to_del = key; break
		if not to_del.is_empty():
			wall_items.erase(to_del)
			sides_d[side_key] = wall_items
			sd["view_sides"] = sides_d
			_segments[_wv_modal_seg] = sd
			_wv_modal_draw.queue_redraw()

	elif mb.button_index == MOUSE_BUTTON_LEFT and not _wv_modal_sfid.is_empty():
		var fdata := _furn_data_by_id(_wv_modal_sfid)
		if fdata.is_empty(): return
		var iw: int = fdata["size"]["w"] as int
		var ih: int = fdata.get("wall_h", 3) as int
		var at := Vector2i(
			clampi(tile.x, 0, seg_len - iw),
			clampi(tile.y, 0, WV_H - ih))
		if _wv_item_fits(at, iw, ih, wall_items, sd):
			wall_items["%d,%d" % [at.x, at.y]] = _wv_modal_sfid
			sides_d[side_key] = wall_items
			sd["view_sides"] = sides_d
			_segments[_wv_modal_seg] = sd
			_wv_modal_draw.queue_redraw()


func _wv_item_fits(at: Vector2i, iw: int, ih: int, wall_items: Dictionary, sd: Dictionary) -> bool:
	var item_rect := Rect2i(at.x, at.y, iw, ih)
	var seg_len := maxi(absi((sd["x2"] as int) - (sd["x1"] as int)),
						absi((sd["y2"] as int) - (sd["y1"] as int)))
	# Restricted zones
	var win_tiles := _wv_collect_win_tiles(sd, seg_len)
	for run in _wv_tile_runs(win_tiles):
		if Rect2i(run[0], 0, run[1] - run[0], WV_H).intersects(item_rect):
			return false
	if sd.get("has_door", false) as bool:
		var dp: int = sd.get("door_pos", 0) as int
		if Rect2i(dp, 0, 10, WV_H).intersects(item_rect):
			return false
	# Existing items
	for key in wall_items:
		var parts := (key as String).split(",")
		var ox := parts[0].to_int(); var oy := parts[1].to_int()
		var fd  := _furn_data_by_id(wall_items[key] as String)
		if fd.is_empty(): continue
		var ew: int = fd["size"]["w"] as int
		var eh: int = fd.get("wall_h", 3) as int
		if Rect2i(ox, oy, ew, eh).intersects(item_rect):
			return false
	return true


func _wv_collect_win_tiles(sd: Dictionary, seg_len: int) -> Array:
	var tiles: Array = sd.get("window_tiles", []) as Array
	if tiles.is_empty() and (sd.get("has_window", false) as bool):
		var wp: int = sd.get("window_pos", 0) as int
		var wl: int = sd.get("window_len", 10) as int
		for ti in range(wp, mini(wp + wl, seg_len)):
			tiles.append(ti)
	return tiles


func _wv_tile_runs(tiles: Array) -> Array:
	if tiles.is_empty():
		return []
	var sorted := tiles.duplicate(); (sorted as Array).sort()
	var runs: Array = []
	var ws := sorted[0] as int; var we := ws + 1
	for i in range(1, sorted.size()):
		var tp := sorted[i] as int
		if tp == we: we += 1
		else: runs.append([ws, we]); ws = tp; we = tp + 1
	runs.append([ws, we])
	return runs


func _toggle_door(seg_idx: int, pos: int) -> void:
	var sd := _segments[seg_idx] as Dictionary
	if sd.get("has_door", false):
		sd.erase("has_door"); sd.erase("door_pos"); sd.erase("door_side")
		_set_status("Door removed")
	else:
		sd["has_door"]  = true
		sd["door_pos"]  = maxi(0, pos - DOOR_LEN / 2)
		sd["door_side"] = 1
		_set_status("Door added")
	_segments[seg_idx] = sd
	_rebuild_floor()


# ── Wall feature helpers ──────────────────────────────────────────────────────

func _toggle_column(tile: Vector2i) -> void:
	if tile.x < 0 or tile.x >= _gw or tile.y < 0 or tile.y >= _gh:
		return
	for i in range(_cols.size()):
		var c := _cols[i] as Dictionary
		if c["x"] == tile.x and c["y"] == tile.y:
			_cols.remove_at(i)
			_rebuild_floor()
			_set_status("Column removed")
			return
	_cols.append({"x": tile.x, "y": tile.y})
	_rebuild_floor()
	_set_status("Column at (%d, %d)" % [tile.x, tile.y])


func _erase_rail_at(tile: Vector2i) -> void:
	for i in range(_rails.size()):
		var r := _rails[i] as Dictionary
		var x1: int = r["x1"]; var y1: int = r["y1"]
		var x2: int = r["x2"]; var y2: int = r["y2"]
		var mn_x := mini(x1, x2); var mx_x := maxi(x1, x2)
		var mn_y := mini(y1, y2); var mx_y := maxi(y1, y2)
		if tile.x >= mn_x and tile.x <= mx_x and tile.y >= mn_y and tile.y <= mx_y:
			_rails.remove_at(i)
			_rebuild_floor()
			_set_status("Rail erased")
			return


func _erase_at(fl: Vector2, tile: Vector2i) -> void:
	# Nearest segment first
	var hit := _detect_segment_at(fl)
	if not hit.is_empty():
		_segments.remove_at(hit["idx"] as int)
		_rebuild_floor()
		_set_status("Wall segment erased")
		return
	# Column
	for i in range(_cols.size()):
		var c := _cols[i] as Dictionary
		if c["x"] == tile.x and c["y"] == tile.y:
			_cols.remove_at(i)
			_rebuild_floor()
			_set_status("Column erased")
			return
	# Floor tile
	if tile in _floor_mask:
		_paint_floor_tile(tile, true)
		_set_status("Floor tile erased")


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  SAVE / LOAD / TEST                                                      ║
# ╚══════════════════════════════════════════════════════════════════════════╝

func _collect_meta() -> void:
	# All backing vars (_lname, _dist, etc.) are kept live via signal callbacks
	# in _open_level_details_modal — nothing to read from inline widgets here.
	pass


func _build_dict() -> Dictionary:
	_collect_meta()
	var req: Array = []
	for fn: String in _funcs:
		if _funcs[fn]:
			req.append(fn)
	var lvl_id := "custom_" + _lname.to_lower().replace(" ", "_")
	return {
		"id": lvl_id, "name": _lname, "district": _dist,
		"is_custom": true, "acquisition_cost": _cost,
		"map_col": 0, "map_row": 0, "min_stars": 0, "block": 1,
		"funds_base_reward": _reward, "starting_budget": _budget,
		"tenant": {
			"name": _tname, "age": _tage, "flavor": _tflav,
			"required_functions": req, "monthly_rent": _rent
		},
		"allowed_furniture":   _allowed_furniture.duplicate(),
		"starting_inventory":  _starting_inventory.duplicate(true),
		"starting_furniture":  _placed_furniture.duplicate(true),
		"moments": (func() -> Array:
			var out: Array = []
			for m in _moments:
				var mid  := (m as Dictionary)["id"]    as String
				var mf   := (_moment_funcs.get(mid, {}) as Dictionary)
				var needs: Array = []
				for fn in mf:
					if mf[fn]: needs.append(fn)
				var entry := (m as Dictionary).duplicate()
				entry["needs"] = needs
				out.append(entry)
			return out).call(),
		"apartment": {
			"grid_w": _gw, "grid_h": _gh,
			"active_floor": _active_efl,
			"hidden_floors": _hidden_fl_ids.keys(),
			"floors": (func() -> Array:
				_save_active_efloor()
				return _editor_floors.duplicate(true)).call()
		}
	}


func _save_level() -> void:
	var d    := _build_dict()
	var jstr := JSON.stringify(d, "\t")
	DirAccess.make_dir_recursive_absolute("user://custom_levels")
	var fname := (d["id"] as String) + ".json"
	var path  := "user://custom_levels/" + fname
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(jstr)
		f.close()
		_set_status("Saved → " + fname)
	else:
		_set_status("Save failed (err %d)" % FileAccess.get_open_error())


func _load_dialog() -> void:
	var dir := DirAccess.open("user://custom_levels")
	if not dir:
		_set_status("No saved levels found")
		return
	var files: Array = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	if files.is_empty():
		_set_status("No saved levels found")
		return
	_show_load_popup(files)


func _show_load_popup(files: Array) -> void:
	var cl := CanvasLayer.new()
	cl.layer = 30
	add_child(cl)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	cl.add_child(bg)

	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color = Color(0.09, 0.12, 0.17)
	cs.border_color = Color(0.24, 0.34, 0.48)
	cs.set_border_width_all(1)
	cs.set_content_margin_all(16)
	card.add_theme_stylebox_override("panel", cs)
	card.set_anchor(SIDE_LEFT, 0.5); card.set_anchor(SIDE_RIGHT, 0.5)
	card.set_anchor(SIDE_TOP, 0.5);  card.set_anchor(SIDE_BOTTOM, 0.5)
	card.offset_left = -200; card.offset_right = 200
	card.offset_top  = -180; card.offset_bottom = 180
	cl.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	card.add_child(vb)

	var ttl := Label.new()
	ttl.text = "Load Level"
	ttl.add_theme_font_size_override("font_size", 14)
	ttl.add_theme_color_override("font_color", GameTheme.C_AMBER)
	vb.add_child(ttl)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 240)
	vb.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)

	for fn: String in files:
		var btn := Button.new()
		btn.text = fn.replace(".json", "").replace("custom_", "")
		btn.add_theme_font_size_override("font_size", 11)
		btn.pressed.connect(func():
			_load_file("user://custom_levels/" + fn)
			cl.queue_free())
		list.add_child(btn)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.add_theme_font_size_override("font_size", 11)
	cancel.add_theme_color_override("font_color", GameTheme.C_MUTED)
	cancel.pressed.connect(cl.queue_free)
	vb.add_child(cancel)

	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			cl.queue_free())


func _load_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		_set_status("Cannot open: " + path.get_file())
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		f.close(); _set_status("JSON parse error"); return
	f.close()
	_load_from_dict(json.get_data() as Dictionary)


func _load_from_dict(d: Dictionary) -> void:
	var apt := d.get("apartment", {}) as Dictionary
	var saved_floors: Array = apt.get("floors", []) as Array
	_camera_fitted = false

	# Detect format: new multi-floor has "type" on floor entries
	var is_multi := not saved_floors.is_empty() and (saved_floors[0] as Dictionary).has("type")
	if is_multi:
		_editor_floors = saved_floors.duplicate(true)
		_gw = apt.get("grid_w", DEFAULT_GW) as int
		_gh = apt.get("grid_h", DEFAULT_GH) as int
		# Migrate old saves that have "floor" entries but no paired floor_sub/ceiling
		var _has_paired := false
		for _efd in _editor_floors:
			if (_efd as Dictionary).get("type", "") in ["floor_sub", "ceiling"]:
				_has_paired = true; break
		if not _has_paired:
			# Insert sub+ceiling pairs around each "floor" entry
			var _fi := 0
			while _fi < _editor_floors.size():
				var _efd := _editor_floors[_fi] as Dictionary
				if _efd.get("type", "") == "floor":
					var _fid := _efd.get("id", "") as String
					var _lbl := _efd.get("label", "Floor") as String
					# Insert ceiling above (after the floor / any loft)
					var _ceil_at := _fi + 1
					while _ceil_at < _editor_floors.size():
						var _nfd := _editor_floors[_ceil_at] as Dictionary
						if _nfd.get("type", "") not in ["loft"]: break
						_ceil_at += 1
					var _ceil := _make_efloor(_fid + "_ceil", _lbl + " Ceiling", "ceiling")
					_ceil["parent_id"] = _fid
					_editor_floors.insert(_ceil_at, _ceil)
					# Insert subfloor below (before the floor)
					var _sub := _make_efloor(_fid + "_sub", _lbl + " Subfloor", "floor_sub")
					_sub["parent_id"] = _fid
					_editor_floors.insert(_fi, _sub)
					_fi += 3   # skip past sub, floor, ceiling
				else:
					_fi += 1
		_active_efl = clampi(apt.get("active_floor", 2) as int, 0, _editor_floors.size() - 1)
	else:
		# Old single-floor format — migrate into ground floor slot
		_init_editor_floors()
		var fl0: Dictionary = saved_floors[0] as Dictionary if not saved_floors.is_empty() else {}
		_gw = fl0.get("grid_w", DEFAULT_GW) as int
		_gh = fl0.get("grid_h", DEFAULT_GH) as int
		# Find the first "floor" type entry (index may shift as structure evolves)
		var ground_idx := -1
		for _mi in range(_editor_floors.size()):
			if (_editor_floors[_mi] as Dictionary).get("type", "") == "floor":
				ground_idx = _mi; break
		if ground_idx >= 0:
			var ground := _editor_floors[ground_idx] as Dictionary
			ground["floor_tiles"]     = fl0.get("floor_tiles", [])
			ground["mezzanine_tiles"] = fl0.get("mezzanine_tiles", [])
			ground["stair_tiles"]     = fl0.get("stair_tiles", [])
			ground["rails"]           = fl0.get("rails", [])
			ground["segments"]        = fl0.get("segments", [])
			ground["columns"]         = fl0.get("columns", [])
			_editor_floors[ground_idx] = ground
			_active_efl = ground_idx

	# Load player-visibility mask
	_hidden_fl_ids.clear()
	for _hid in apt.get("hidden_floors", []):
		_hidden_fl_ids[_hid as String] = true

	_load_active_efloor()
	# Ensure demolished key on segments
	for seg in _segments:
		if not (seg as Dictionary).has("demolished"):
			(seg as Dictionary)["demolished"] = false

	_lname  = d.get("name",     "") as String
	_dist   = d.get("district", "") as String
	var ten: Dictionary = d.get("tenant", {}) as Dictionary
	_tname  = ten.get("name",   "")   as String
	_tage   = ten.get("age",    28)   as int
	_tflav  = ten.get("flavor", "")   as String
	_budget = d.get("starting_budget",  2000) as int
	_rent   = ten.get("monthly_rent",    300) as int
	_reward = d.get("funds_base_reward", 800) as int
	_cost   = d.get("acquisition_cost", 1500) as int
	var req: Array = ten.get("required_functions", []) as Array
	for fn: String in _funcs:
		_funcs[fn] = (fn in req)

	# Inline widgets are now modal-only — update summary label instead
	_refresh_level_summary()
	if _sw:       _sw.value       = _gw
	if _sh:       _sh.value       = _gh
	if _size_lbl: _size_lbl.text  = "= %.0fm × %.0fm" % [_gw * 0.1, _gh * 0.1]

	# Catalog filter — modal rebuilt on open, so just restore the data
	_allowed_furniture = (d.get("allowed_furniture", []) as Array).duplicate()
	_update_cat_filter_lbl()

	# Starting furniture
	_starting_inventory = (d.get("starting_inventory", []) as Array).duplicate(true)
	_placed_furniture   = (d.get("starting_furniture", []) as Array).duplicate(true)
	_update_inv_count_lbl()

	# Moments — strip embedded needs back into _moment_funcs for the editor UI
	_moments = []
	_moment_funcs = {}
	for m in (d.get("moments", []) as Array):
		var md  := (m as Dictionary).duplicate()
		var mid := md["id"] as String
		var needs := md.get("needs", []) as Array
		md.erase("needs")
		_moments.append(md)
		var mf: Dictionary = {}
		for fn: String in ["sleep", "sit", "work", "cook", "storage", "dine"]:
			mf[fn] = fn in needs
		_moment_funcs[mid] = mf
	_active_moment = ""
	_rebuild_moment_dropdown()

	_refresh_fl_switcher()
	_rebuild_floor()
	_set_status("Loaded: " + _lname)


func _test_level() -> void:
	if _gw < 10 or _gh < 10:
		_set_status("Grid too small"); return
	var d := _build_dict()
	var gs: Node = get_node("/root/GameState")
	gs.set("custom_level_data", d)
	gs.set("pending_level_id",  "_custom")
	gs.set("testing_from_editor", true)
	gs.call("own_level", "_custom")
	get_tree().change_scene_to_file("res://scenes/Main.tscn")
