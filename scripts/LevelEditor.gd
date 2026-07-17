extends Node

# ─────────────────────────────────────────────────────────────────────────────
const TILE_SIZE  := 8
const WIN_LEN    := 15
const DOOR_LEN   := 10
const LEFT_W     := 170.0
const RIGHT_W    := 236.0
const TOP_H      := 36.0
const BOTTOM_H   := 160.0
const DEFAULT_GW := 300
const DEFAULT_GH := 300
# Fixed-but-generous canvas: DEFAULT_GW/GH above is already large enough that
# almost no apartment will ever reach its edge, but if one does, grow it in
# chunks rather than hard-capping — keeps editing frictionless without
# needing a true infinite canvas. Growth only ever extends the +x/+y edges
# (tile coords stay valid, nothing already placed needs to move); building
# further up/left than (0,0) isn't supported since that would require
# re-indexing every mask/segment/rail/column already placed.
const GRID_GROW_MARGIN := 6
const GRID_GROW_CHUNK  := 20

const _OV_SCRIPT     := preload("res://scripts/EditorOverlay.gd")
const FurnitureScene := preload("res://scenes/Furniture.tscn")
const Room3DViewScene := preload("res://scenes/Room3DView.tscn")

enum Tool { FLOOR, MEZZANINE, STAIRS, RAIL, REVEAL, PRIMARY_WALL, SECONDARY_WALL, WINDOW, DOOR, WALL_VIEW, COLUMN, ERASE }

# ── Floor geometry ────────────────────────────────────────────────────────────
var _gw: int = DEFAULT_GW
var _gh: int = DEFAULT_GH
var _floor_mask:     Dictionary = {}  # Vector2i -> true (painted floor tiles)
var _mezzanine_mask: Dictionary = {}  # Vector2i -> true (mezzanine/loft tiles)
var _stair_mask:     Dictionary = {}  # Vector2i -> true (stair tiles, auto-filled from _stairs)
var _stairs:         Array      = []  # [{x, y, w, h, direction}] placed staircases
var _segments:       Array      = []  # [{x1,y1,x2,y2,primary,demolished,...}]
var _rails:          Array      = []  # [{x1,y1,x2,y2}] rail tracks
var _reveal_zones:   Array      = []  # [{x1,y1,x2,y2}] reveal-zone markers (sub-range of a rail)
var _cols:           Array      = []  # [{x,y}]

# ── Wall drawing state ────────────────────────────────────────────────────────
var _floor_painting:   bool = false
var _floor_erase:      bool = false
var _floor_brush:      int  = 10  # 1 = tile (10 cm), 10 = cell (1 m = 10×10 tiles)
var _floor_kind_paint:  String = "balcony"  # kind stamped by Floor Paint while painting floor tiles
var _floor_kind:        Dictionary = {}    # Vector2i -> String ("balcony"|"bathroom"); absent = "normal"

# Sloped ceiling (per active floor) — {axis, low_start, high_end, min_h, max_h}
var _sc_enabled:   bool   = false
var _sc_axis:      String = "x"
var _sc_low_start: int    = 0
var _sc_high_end:  int    = 10
var _sc_min_h:     float  = 1.8
var _sc_max_h:     float  = 2.4
var _mezz_painting:    bool = false
var _mezz_erase:       bool = false
var _stair_painting:   bool   = false  # unused — kept to avoid ref errors
var _stair_dir:        String = "north"  # current stamp direction
var _stair_target:     String = "loft"   # "loft" → mezzanine; "floor" → floor above
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
var _block:   int   = 1   # block (category) in city map
var _map_col: int   = 0   # column position in city map grid
var _map_row: int   = 0   # row position in city map grid
var _funcs: Dictionary = {
	"sleep": false, "sit": false, "work": false, "cook": false, "storage": false, "dine": false, "dress": false
}

# ── Tool & interaction state ──────────────────────────────────────────────────
var _tool: Tool = Tool.FLOOR
var _tool_btns: Dictionary = {}   # Tool -> Button; for programmatic switching
var _ps: Vector2i = Vector2i(-1, -1)
var _pe: Vector2i = Vector2i(-1, -1)
var _pdrawing: bool = false

# ── Door drag state ───────────────────────────────────────────────────────────
var _door_dragging: bool = false
var _door_shift_held: bool = false   # shift state at the moment of the click that started/toggled a door
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
var _popup_open: int = 0  # count of open overlay popups; zoom/pan blocked while > 0

# ── Scene nodes ───────────────────────────────────────────────────────────────
var _room:   Node2D   = null
var _camera: Camera2D = null
var _floor:  Floor    = null
var _camera_fitted: bool = false  # true after first fit; prevents reset on every rebuild
var _ov:     Node2D   = null

# ── 3D preview (view-only — the editor's own tools all operate on the 2D
# canvas; this is a "what does this actually look like" check, not a second
# way to edit) ────────────────────────────────────────────────────────────────
var _ui_layer:    CanvasLayer = null
var _view3d_active: bool      = false
var _view3d_node: Control     = null
var _view3d_btn:  Button      = null
var _zoom_label:  Label       = null
var _fit_zoom:    float       = 1.0   # zoom set by the last _fit_camera() call — 100% baseline for the zoom label
var _space_held:  bool        = false # Space+drag pan, same convention as Godot's own 2D editor

# ── UI refs ───────────────────────────────────────────────────────────────────
var _sw: SpinBox = null;  var _sh: SpinBox = null  # unused — grid fixed at 300×300
var _status: Label = null
var _size_lbl: Label = null  # unused — grid fixed at 300×300
var _clear_dlg: ConfirmationDialog = null

# ── Furniture data (loaded once) ──────────────────────────────────────────────
var _furn_catalog: Array = []   # full furniture array from furniture.json

# ── Furniture restrictions + starting inventory ───────────────────────────────
var _allowed_furniture:    Array   = []   # [] = all allowed; otherwise ID whitelist
var _starting_inventory:   Array   = []   # [{id, count}] items that start in the apartment
var _placed_furniture:     Array   = []   # [{id, x, y}] pre-placed positions on the floor
var _furn_preview_nodes:   Array   = []   # Furniture instances shown on the editor canvas

# Furniture placement mode
var _placing_furniture_id:   String   = ""
var _placing_furn_size:      Vector2i = Vector2i.ZERO
var _placing_furn_col:       Color    = Color.WHITE

# Right-panel summary labels
var _cat_filter_lbl:   Label  = null
var _level_summary_lbl: Label = null

# Starting inventory modal (kept alive so it can be hidden/shown during placement)
var _inv_modal_win:  Window = null
var _inv_list_vb:    VBoxContainer = null

# Bottom catalog panel + right-panel placed list
var _editor_furn_vb: VBoxContainer = null
var _placed_vb:      VBoxContainer = null

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
	_rebuild_floor()
	_set_status("Floor Paint: LMB pintasuelos · RMB borra  |  Dibuja paredes encima del suelo")

	# The very first _fit_camera() call above can land before the viewport's
	# layout has fully settled for one frame (anchors resolve immediately, but
	# the window/viewport size itself can still be mid-transition right at
	# startup) — re-fit once more next frame, forced, so the camera reliably
	# lands centred on entry instead of occasionally needing a manual "Fit".
	await get_tree().process_frame
	if is_instance_valid(self) and is_inside_tree():
		_fit_camera(true)


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
	_ui_layer = ui

	# Themed root — buttons inherit GameTheme from here
	var troot := Control.new()
	troot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	troot.theme = GameTheme.make()
	troot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(troot)

	_build_topbar(troot)
	_build_left(troot)
	_build_right(troot)
	_build_bottom(troot)


func _build_topbar(ui: Node) -> void:
	var bar := PanelContainer.new()
	var bs := StyleBoxFlat.new()
	bs.bg_color = Color(0.115, 0.100, 0.085)
	bs.border_color = Color(0.320, 0.270, 0.205)
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
	back_btn.pressed.connect(func(): Transition.change_scene("res://scenes/CityMap.tscn"))
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

	_zoom_label = Label.new()
	_zoom_label.text = "100%"
	_zoom_label.custom_minimum_size = Vector2(40, 0)
	_zoom_label.add_theme_font_size_override("font_size", 10)
	_zoom_label.add_theme_color_override("font_color", GameTheme.C_MUTED)
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hb.add_child(_zoom_label)

	var fit_btn := Button.new()
	fit_btn.text = "Fit"
	fit_btn.tooltip_text = "Reset zoom/pan to fit the whole floor (F)"
	fit_btn.add_theme_font_size_override("font_size", 11)
	fit_btn.pressed.connect(_fit_camera.bind(true))
	hb.add_child(fit_btn)

	# View-only 3D preview of the currently edited floor — all the actual
	# editing tools still only operate on the 2D canvas; this is just a "what
	# does this actually look like" check without leaving the editor.
	_view3d_btn = Button.new()
	_view3d_btn.text = "3D Preview"
	_view3d_btn.toggle_mode = true
	_view3d_btn.add_theme_font_size_override("font_size", 11)
	_view3d_btn.pressed.connect(_toggle_3d_view)
	hb.add_child(_view3d_btn)


func _build_left(ui: Node) -> void:
	var panel := PanelContainer.new()
	var ps := StyleBoxFlat.new()
	ps.bg_color = Color(0.115, 0.100, 0.085)
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
		[Tool.STAIRS,        "Stairs",         "LMB stamp · RMB remove · R rotate · T loft/floor"],
		[Tool.RAIL,          "Rail",           "Drag to draw sliding rail track"],
		[Tool.REVEAL,        "Reveal Zone",    "Drag over a rail to mark where a piece counts as revealed"],
		[Tool.PRIMARY_WALL,  "Primary Wall",   "Drag axis-snapped — cannot demolish"],
		[Tool.SECONDARY_WALL,"Secondary Wall", "Drag axis-snapped — can demolish"],
		[Tool.WINDOW,        "Window",         "LMB paint · RMB erase window tiles on a wall"],
		[Tool.DOOR,          "Door",           "Click wall · drag to choose side · Shift+drag/click for sliding · click again to remove"],
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
				_ov.set("reveal_mode",    _tool == Tool.REVEAL)
				_ov.set("floor_hover",    Vector2i(-1, -1))
				_ov.set("wall_hover",     Vector2i(-1, -1))
				_ov.set("win_hover_rect", Rect2())
				_ov.set("mezz_hover",     false)
				_ov.set("stair_hover",      false)
				_ov.set("stair_hover_rect", Rect2i())
				_ov.set("active",           false)
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

	# ── Floor kind selector (Floor Paint) — balcony / bathroom only. Normal
	# interior floor is never hand-painted — it's auto-filled the moment its
	# walls close a loop (see _autofill_enclosed_floor). Floor Paint exists
	# only for the cases that AREN'T wall-enclosed and so can't be inferred
	# that way: balconies/terraces (open-air, past the building envelope)
	# and tagging a bathroom's wet-room floor kind.
	_sect(vb, "FLOOR KIND")
	var kind_bg := ButtonGroup.new()
	for kdef: Array in [["balcony", "Balcony/Terrace"], ["bathroom", "Bathroom"]]:
		var kid  := kdef[0] as String
		var klbl := kdef[1] as String
		var kbtn := Button.new()
		kbtn.text          = klbl
		kbtn.toggle_mode   = true
		kbtn.button_group  = kind_bg
		kbtn.button_pressed = (kid == _floor_kind_paint)
		kbtn.add_theme_font_size_override("font_size", 9)
		kbtn.pressed.connect(func(): _floor_kind_paint = kid)
		vb.add_child(kbtn)

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
	ps.bg_color = Color(0.115, 0.100, 0.085)
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
	mgmt_btn.clip_text = true
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
	det_btn.clip_text = true
	det_btn.add_theme_font_size_override("font_size", 10)
	det_btn.pressed.connect(_open_level_details_modal)
	vb.add_child(det_btn)
	var sc_btn := Button.new()
	sc_btn.text = "Sloped Ceiling…"
	sc_btn.clip_text = true
	sc_btn.add_theme_font_size_override("font_size", 10)
	sc_btn.pressed.connect(_open_sloped_ceiling_modal)
	vb.add_child(sc_btn)

	# ── Furniture (compact buttons → open modals) ─────────────────────────────
	_sect(vb, "FURNITURE")
	var cat_btn := Button.new()
	cat_btn.text = "Catalog Filter…"
	cat_btn.clip_text = true
	cat_btn.add_theme_font_size_override("font_size", 10)
	cat_btn.pressed.connect(_open_catalog_filter_modal)
	vb.add_child(cat_btn)
	_cat_filter_lbl = Label.new()
	_cat_filter_lbl.add_theme_font_size_override("font_size", 9)
	_cat_filter_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	vb.add_child(_cat_filter_lbl)
	_update_cat_filter_lbl()

	_sect(vb, "PLACED")
	_placed_vb = VBoxContainer.new()
	_placed_vb.add_theme_constant_override("separation", 2)
	vb.add_child(_placed_vb)
	_fill_placed_list()

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

	# ── MAP POSITION ──
	_sect(vb, "MAP POSITION")
	var sblk  := _spinbox(vb, "Block",   _block,   1,  5, 1)
	var scol  := _spinbox(vb, "Col",     _map_col, 0,  4, 1)
	var srow  := _spinbox(vb, "Row",     _map_row, 0, 99, 1)
	sblk.value_changed.connect(func(v: float): _block   = int(v))
	scol.value_changed.connect(func(v: float): _map_col = int(v))
	srow.value_changed.connect(func(v: float): _map_row = int(v))

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
	for fn: String in ["sleep", "sit", "work", "cook", "storage", "dine", "dress"]:
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


func _open_sloped_ceiling_modal() -> void:
	var win := Window.new()
	win.title = "Sloped Ceiling"
	win.size  = Vector2i(300, 320)
	win.wrap_controls = true
	add_child(win)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.custom_minimum_size = Vector2(280, 0)
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	win.add_child(vb)

	var hint := Label.new()
	hint.text = "Ceiling height ramps linearly from Min (at Low Start) to Max (at High End), along the chosen axis. Tall furniture is blocked wherever the ceiling drops below 2.0m."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.add_theme_font_size_override("font_size", 9)
	hint.add_theme_color_override("font_color", GameTheme.C_MUTED)
	vb.add_child(hint)

	var en_cb := CheckBox.new()
	en_cb.text = "Enabled"
	en_cb.button_pressed = _sc_enabled
	en_cb.add_theme_font_size_override("font_size", 11)
	vb.add_child(en_cb)

	var axis_row := HBoxContainer.new()
	axis_row.add_theme_constant_override("separation", 4)
	vb.add_child(axis_row)
	var axis_bg := ButtonGroup.new()
	for adef: Array in [["x", "Slopes along X"], ["y", "Slopes along Y"]]:
		var aid  := adef[0] as String
		var albl := adef[1] as String
		var abtn := Button.new()
		abtn.text = albl
		abtn.toggle_mode  = true
		abtn.button_group = axis_bg
		abtn.button_pressed = (aid == _sc_axis)
		abtn.add_theme_font_size_override("font_size", 9)
		abtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		abtn.pressed.connect(func(): _sc_axis = aid)
		axis_row.add_child(abtn)

	var s_low  := _spinbox(vb, "Low Start (tile)",  _sc_low_start, 0, 300, 1)
	var s_high := _spinbox(vb, "High End (tile)",   _sc_high_end,  0, 300, 1)
	s_low.value_changed.connect(func(v: float):  _sc_low_start = int(v))
	s_high.value_changed.connect(func(v: float): _sc_high_end  = int(v))

	var s_min := _float_spinbox(vb, "Min Height (m)", _sc_min_h, 1.0, 3.0, 0.1)
	var s_max := _float_spinbox(vb, "Max Height (m)", _sc_max_h, 1.0, 3.0, 0.1)
	s_min.value_changed.connect(func(v: float): _sc_min_h = v)
	s_max.value_changed.connect(func(v: float): _sc_max_h = v)

	en_cb.toggled.connect(func(on: bool):
		_sc_enabled = on
		if is_instance_valid(_floor):
			_floor.sloped_ceiling = _current_sloped_ceiling_dict()
			_floor.grid_draw.queue_redraw())

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_font_size_override("font_size", 11)
	close_btn.pressed.connect(func():
		if is_instance_valid(_floor):
			_floor.sloped_ceiling = _current_sloped_ceiling_dict()
			_floor.grid_draw.queue_redraw()
		win.queue_free())
	vb.add_child(close_btn)

	win.close_requested.connect(close_btn.pressed.emit)
	win.popup_centered()


func _current_sloped_ceiling_dict() -> Dictionary:
	if not _sc_enabled:
		return {}
	return {
		"axis": _sc_axis, "low_start": _sc_low_start, "high_end": _sc_high_end,
		"min_h": _sc_min_h, "max_h": _sc_max_h
	}


func _float_spinbox(p: Control, label: String, val: float, mn: float, mx: float, step: float) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	p.add_child(row)
	var lbl := Label.new()
	lbl.text = label + ":"
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.custom_minimum_size = Vector2(90, 0)
	row.add_child(lbl)
	var sb := SpinBox.new()
	sb.min_value = mn; sb.max_value = mx; sb.step = step; sb.value = val
	sb.add_theme_font_size_override("font_size", 10)
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sb)
	return sb


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
	const FNS := ["sleep", "sit", "work", "cook", "storage", "dine", "dress"]
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
		"floor_tiles": [], "floor_kinds": [], "mezzanine_tiles": [], "stair_tiles": [],
		"stairs": [], "rails": [], "reveal_zones": [], "segments": [], "columns": [],
		"sloped_ceiling": {}
	}

func _make_floor_trio(fid: String, lbl: String) -> Array:
	var sub  := _make_efloor(fid + "_sub",  lbl + " Subfloor", "floor_sub")
	sub["parent_id"] = fid
	var fl   := _make_efloor(fid, lbl, "floor")
	var ceiling_fl := _make_efloor(fid + "_ceil", lbl + " Ceiling",  "ceiling")
	ceiling_fl["parent_id"] = fid
	return [sub, fl, ceiling_fl]

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
	var fk: Array = []
	for t in _floor_kind:     fk.append([(t as Vector2i).x, (t as Vector2i).y, _floor_kind[t]])
	var mt: Array = []
	for t in _mezzanine_mask: mt.append([(t as Vector2i).x, (t as Vector2i).y])
	var st: Array = []
	for t in _stair_mask:     st.append([(t as Vector2i).x, (t as Vector2i).y])
	fd["floor_tiles"]     = ft
	fd["floor_kinds"]     = fk
	fd["mezzanine_tiles"] = mt
	fd["sloped_ceiling"]  = _current_sloped_ceiling_dict()
	fd["stair_tiles"]     = st   # auto-derived for backward compat; source of truth is "stairs"
	fd["stairs"]          = _stairs.duplicate(true)
	fd["rails"]           = _rails.duplicate(true)
	fd["reveal_zones"]    = _reveal_zones.duplicate(true)
	fd["segments"]        = _segments.duplicate(true)
	fd["columns"]         = _cols.duplicate(true)

func _floor_below_efl(idx: int) -> Dictionary:
	for i in range(idx - 1, -1, -1):
		if (_editor_floors[i] as Dictionary).get("type", "floor") == "floor":
			return _editor_floors[i] as Dictionary
	return {}

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
		fd["floor_kinds"] = []
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

	_floor_kind.clear()
	for t in fd.get("floor_kinds", []):
		_floor_kind[Vector2i(t[0] as int, t[1] as int)] = t[2] as String

	var _scd := fd.get("sloped_ceiling", {}) as Dictionary
	_sc_enabled   = not _scd.is_empty()
	_sc_axis      = _scd.get("axis", "x") as String
	_sc_low_start = _scd.get("low_start", 0) as int
	_sc_high_end  = _scd.get("high_end", 10) as int
	_sc_min_h     = _scd.get("min_h", 1.8) as float
	_sc_max_h     = _scd.get("max_h", 2.4) as float

	_mezzanine_mask.clear()
	for t in fd.get("mezzanine_tiles", []):
		_mezzanine_mask[Vector2i(t[0] as int, t[1] as int)] = true
	# Load stairs array (new format); fall back to stair_tiles for old levels
	_stairs = (fd.get("stairs", []) as Array).duplicate(true)
	_stair_mask.clear()
	if not _stairs.is_empty():
		_rebuild_stair_mask()  # derive stair_mask from _stairs
	else:
		for t in fd.get("stair_tiles", []):
			_stair_mask[Vector2i(t[0] as int, t[1] as int)] = true
	_rails        = (fd.get("rails",        []) as Array).duplicate(true)
	_reveal_zones = (fd.get("reveal_zones", []) as Array).duplicate(true)
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
		btn.tooltip_text = btn.text
		btn.clip_text = true   # long labels ("Ground Floor Subfloor") truncate with an
							   # ellipsis instead of overflowing past the row into the
							   # neighboring rename/delete/visibility buttons — this
							   # narrow right panel doesn't have room to spare.
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
	btn.clip_text = true
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
	_maybe_grow_grid()
	_autofill_enclosed_floor()
	if is_instance_valid(_floor):
		_floor.queue_free()
	if is_instance_valid(_ov):
		_ov.queue_free()
	_floor = null; _ov = null

	var scene := load("res://scenes/Wall.tscn") as PackedScene
	_floor = scene.instantiate() as Floor
	_floor.set_process_input(false)
	_room.add_child(_floor)
	# Editor wants a generous blueprint grid that never shrinks down to just
	# whatever's been drawn so far — gameplay (Main.gd) leaves this false so
	# the sheet still hugs the actual apartment walls tightly there.
	if _floor.has_node("GridDraw"):
		(_floor.get_node("GridDraw") as GridDraw).editor_mode = true

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

	var reveal_arr: Array = []
	for rz in _reveal_zones:
		reveal_arr.append((rz as Dictionary).duplicate())

	var floor_kinds: Array = []
	for t in _floor_kind:
		floor_kinds.append([(t as Vector2i).x, (t as Vector2i).y, _floor_kind[t]])

	# Build stair_openings for the editor preview:
	#   loft floors → parent's loft-targeted stairs
	#   floor type above another floor → that floor's floor-targeted stairs
	var _preview_so: Array = []
	var _afed  := _editor_floors[_active_efl] as Dictionary
	var _aftype := _afed.get("type", "") as String
	if _aftype == "loft":
		var _pstairs := _parent_efloor(_afed).get("stairs", []) as Array
		_preview_so = _pstairs.filter(func(s) -> bool:
			return (s as Dictionary).get("target", "loft") != "floor")
	elif _aftype == "floor":
		var _bfd := _floor_below_efl(_active_efl)
		if not _bfd.is_empty():
			var _bstairs := _bfd.get("stairs", []) as Array
			_preview_so = _bstairs.filter(func(s) -> bool:
				return (s as Dictionary).get("target", "loft") == "floor")

	_floor.setup({
		"id": "editor_preview", "label": "Ground Floor",
		"grid_w": _gw, "grid_h": _gh,
		"floor_tiles":     floor_tiles,
		"floor_kinds":     floor_kinds,
		"sloped_ceiling":  _current_sloped_ceiling_dict(),
		"mezzanine_tiles": mezz_tiles,
		"stair_tiles":     stair_tiles,
		"stairs":          _stairs.duplicate(true),
		"rails":           rail_arr,
		"reveal_zones":    reveal_arr,
		"stair_openings":  _preview_so,
		"segments": _segments.duplicate(true),
		"columns":  _cols.duplicate(true)
	})
	_floor.grid_draw.show_grid = true

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

	# If the 3D preview is open while a floor rebuild happens (e.g. switching
	# floor tabs), refresh it against the freshly-rebuilt _floor instead of
	# silently going stale — _rebuild_floor() replaces _floor with a new node
	# every time (see "_floor = null" above), so the preview's reference to
	# the old one would otherwise dangle.
	if _view3d_active:
		_show_3d_preview()


# Fixed-but-generous canvas that grows in chunks if content gets near its edge —
# see the GRID_GROW_* comment above. Scans every placeable on the floor
# currently being edited (other floors are checked when THEY become active,
# since _gw/_gh is shared apartment-wide and _rebuild_floor() runs on every
# floor switch too).
func _maybe_grow_grid() -> void:
	var max_x := 0
	var max_y := 0
	for t in _floor_mask:
		max_x = maxi(max_x, (t as Vector2i).x); max_y = maxi(max_y, (t as Vector2i).y)
	for t in _mezzanine_mask:
		max_x = maxi(max_x, (t as Vector2i).x); max_y = maxi(max_y, (t as Vector2i).y)
	for t in _stair_mask:
		max_x = maxi(max_x, (t as Vector2i).x); max_y = maxi(max_y, (t as Vector2i).y)
	for seg in _segments:
		var sd := seg as Dictionary
		max_x = maxi(max_x, maxi(sd["x1"] as int, sd["x2"] as int))
		max_y = maxi(max_y, maxi(sd["y1"] as int, sd["y2"] as int))
	for r in _rails:
		var rd := r as Dictionary
		max_x = maxi(max_x, maxi(rd["x1"] as int, rd["x2"] as int))
		max_y = maxi(max_y, maxi(rd["y1"] as int, rd["y2"] as int))
	for rz in _reveal_zones:
		var zd := rz as Dictionary
		max_x = maxi(max_x, maxi(zd["x1"] as int, zd["x2"] as int))
		max_y = maxi(max_y, maxi(zd["y1"] as int, zd["y2"] as int))
	for c in _cols:
		var cd := c as Dictionary
		max_x = maxi(max_x, cd["x"] as int)
		max_y = maxi(max_y, cd["y"] as int)

	var grew := false
	while max_x + GRID_GROW_MARGIN >= _gw:
		_gw += GRID_GROW_CHUNK
		grew = true
	while max_y + GRID_GROW_MARGIN >= _gh:
		_gh += GRID_GROW_CHUNK
		grew = true
	if grew:
		_set_status("Apartment grid grew to %d × %d tiles" % [_gw, _gh])


# Drawing a rectangular room's four walls used to leave the interior
# unpainted until Floor Paint was also run tile-by-tile — this floods every
# wall-enclosed pocket the moment its walls close a loop and adds those
# tiles to _floor_mask automatically. Only ever ADDS tiles, never removes:
# a manually-painted balcony/irregular extension outside the walled
# rectangle stays untouched even if walls are edited afterwards.
func _autofill_enclosed_floor() -> void:
	if _segments.is_empty():
		return

	var bounds := _content_bounds_tiles()   # already padded with a margin beyond the walls
	var blocked: Dictionary = {}
	for seg in _segments:
		var sd := seg as Dictionary
		if sd.get("demolished", false):
			continue
		var x1: int = sd["x1"]; var y1: int = sd["y1"]
		var x2: int = sd["x2"]; var y2: int = sd["y2"]
		if y1 == y2:
			for x in range(mini(x1, x2), maxi(x1, x2) + 1):
				blocked[Vector2i(x, y1)] = true
		elif x1 == x2:
			for y in range(mini(y1, y2), maxi(y1, y2) + 1):
				blocked[Vector2i(x1, y)] = true

	# Flood-fill inward from the padded bounding box's border — anything the
	# fill reaches is "outside"; whatever's left over (not blocked, not
	# reached) is enclosed by walls on every side.
	var bx0 := bounds.position.x; var by0 := bounds.position.y
	var bx1 := bounds.position.x + bounds.size.x - 1
	var by1 := bounds.position.y + bounds.size.y - 1
	var outside: Dictionary = {}
	var stack: Array = []
	for x in range(bx0, bx1 + 1):
		stack.append(Vector2i(x, by0)); stack.append(Vector2i(x, by1))
	for y in range(by0, by1 + 1):
		stack.append(Vector2i(bx0, y)); stack.append(Vector2i(bx1, y))

	while not stack.is_empty():
		var t: Vector2i = stack.pop_back()
		if t.x < bx0 or t.x > bx1 or t.y < by0 or t.y > by1:
			continue
		if outside.has(t) or blocked.has(t):
			continue
		outside[t] = true
		stack.append(Vector2i(t.x + 1, t.y)); stack.append(Vector2i(t.x - 1, t.y))
		stack.append(Vector2i(t.x, t.y + 1)); stack.append(Vector2i(t.x, t.y - 1))

	var added := 0
	for x in range(bx0, bx1 + 1):
		for y in range(by0, by1 + 1):
			var t := Vector2i(x, y)
			if blocked.has(t) or outside.has(t):
				continue
			if not _floor_mask.has(t):
				_floor_mask[t] = true
				added += 1
	if added > 0:
		_set_status("Auto-filled %d enclosed floor tile(s)" % added)


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  3D PREVIEW (view-only)                                                  ║
# ╚══════════════════════════════════════════════════════════════════════════╝

func _toggle_3d_view() -> void:
	_view3d_active = not _view3d_active
	if _view3d_active:
		_room.visible   = false
		_camera.enabled = false
		_show_3d_preview()
	else:
		_hide_3d_preview()
		_room.visible   = true
		_camera.enabled = true


func _show_3d_preview() -> void:
	if not is_instance_valid(_floor):
		return
	if not is_instance_valid(_view3d_node):
		_view3d_node = Room3DViewScene.instantiate()
		_ui_layer.add_child(_view3d_node)
		# Anchored like the editor's own left/right tool panels (see
		# _build_left/_build_right) rather than Main.gd's fixed-1280×720
		# convention — the editor sizes its panels off the actual viewport,
		# not a hardcoded design resolution.
		_view3d_node.anchor_left   = 0.0
		_view3d_node.anchor_top    = 0.0
		_view3d_node.anchor_right  = 1.0
		_view3d_node.anchor_bottom = 1.0
		if _view3d_node.has_node("CloseBtn"):
			(_view3d_node.get_node("CloseBtn") as Control).visible = false
		# The editor's own tools (Floor Paint, Stairs, walls, ...) are the only
		# way to actually edit anything here — this preview exists to answer
		# "what does this look like," not to double as a second editing
		# surface with its own drag/sell logic to keep in sync with the 2D
		# authoring data.
		_view3d_node.read_only = true
	_view3d_node.offset_left   = LEFT_W
	_view3d_node.offset_top    = TOP_H
	_view3d_node.offset_right  = -RIGHT_W
	_view3d_node.offset_bottom = -BOTTOM_H
	_ui_layer.move_child(_view3d_node, _ui_layer.get_child_count() - 1)
	_view3d_node.build_from_floor(_floor, _furn_catalog, null)


func _hide_3d_preview() -> void:
	if is_instance_valid(_view3d_node):
		_view3d_node.queue_free()
	_view3d_node = null


func _fit_camera(force: bool = false) -> void:
	if not is_instance_valid(_camera) or (_camera_fitted and not force):
		return
	_camera_fitted = true

	var vp  := get_viewport().get_visible_rect().size
	var aw  := vp.x - LEFT_W - RIGHT_W - 20.0
	var ah  := vp.y - TOP_H - 16.0
	var scx := LEFT_W + aw * 0.5
	var scy := TOP_H  + ah * 0.5

	# Fit to the floor's actual content (walls/floor/stairs/...), not the
	# whole fixed-but-generous _gw x _gh canvas (up to 300+ tiles) — fitting
	# to the raw canvas zoomed out so far that a normal-sized room looked
	# tiny and its 10cm subcell gridlines dropped below GridDraw's
	# visibility threshold, which read as "the subtiles are just missing".
	var bounds := _content_bounds_tiles()
	var content_w := maxi(bounds.size.x, 1) * TILE_SIZE
	var content_h := maxi(bounds.size.y, 1) * TILE_SIZE
	var fit_z: float = clampf(minf(aw / content_w, ah / content_h) * 0.92, ZOOM_MIN, ZOOM_MAX)
	_fit_zoom = fit_z
	_camera.zoom = Vector2(fit_z, fit_z)

	# Centre the camera on the middle of the actual content, not the whole
	# canvas. Folded directly into camera.position (offset left at its default
	# zero) rather than using Camera2D.offset — _do_zoom's proven-correct
	# zoom-toward-cursor math already assumes offset is zero and derives
	# world_point_at(screen_point) = camera.position + (screen_point - vp/2) / zoom,
	# so reusing that exact relationship here (solved for camera.position
	# instead of the world point) keeps both in agreement instead of guessing
	# Camera2D.offset's own scaling convention, which is what produced a
	# content-shifted-off-centre bug the first time this was attempted.
	var content_center := Vector2(
		(bounds.position.x + bounds.size.x * 0.5) * TILE_SIZE,
		(bounds.position.y + bounds.size.y * 0.5) * TILE_SIZE
	)
	_camera.offset = Vector2.ZERO
	_camera.position = content_center - Vector2(scx - vp.x * 0.5, scy - vp.y * 0.5) / fit_z
	_update_zoom_label()


# The editor's default view is simply the whole fixed-but-generous editing
# canvas (_gw x _gh) — not a small box fitted/unioned around whatever's been
# drawn so far. _maybe_grow_grid() already guarantees _gw/_gh always covers
# every painted tile/wall/etc with margin to spare, so "the whole canvas"
# already includes all real content by construction; there's no separate
# content-bounds calculation left to keep in sync with GridDraw's own sheet
# bounds (see GridDraw.editor_mode), which is what kept causing the sheet
# and the camera's fit to visibly disagree/detach from each other.
#
# Exception: a completely empty floor uses a smaller centred default instead
# of the literal whole canvas — fitting all 300 tiles on screen zoomed out so
# far that the 10cm subcell gridlines faded below GridDraw's visibility
# threshold, which read as "there's no detail grid at all" the moment you
# open a fresh level. EMPTY_VIEW_TILES is comfortably bigger than a single
# room while still keeping subtiles clearly visible at 100%.
const EMPTY_VIEW_TILES := 60

func _content_bounds_tiles() -> Rect2i:
	var empty := _floor_mask.is_empty() and _mezzanine_mask.is_empty() and _stair_mask.is_empty() \
		and _segments.is_empty() and _rails.is_empty() and _reveal_zones.is_empty() and _cols.is_empty()
	if empty:
		return Rect2i(_gw / 2 - EMPTY_VIEW_TILES / 2, _gh / 2 - EMPTY_VIEW_TILES / 2, EMPTY_VIEW_TILES, EMPTY_VIEW_TILES)
	return Rect2i(0, 0, _gw, _gh)


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
	# R (no modifier) → rotate stair direction when STAIRS tool is active
	if ke.keycode == KEY_R and not ke.ctrl_pressed and not ke.shift_pressed and not ke.alt_pressed:
		if _tool == Tool.STAIRS:
			const _DIRS := ["north", "east", "south", "west"]
			_stair_dir = _DIRS[(_DIRS.find(_stair_dir) + 1) % _DIRS.size()]
			if is_instance_valid(_ov):
				_ov.set("stair_hover_dir", _stair_dir)
				_ov.queue_redraw()
			_set_status("Stair direction: " + _stair_dir)
			get_viewport().set_input_as_handled()
	# T (no modifier) → toggle stair target (loft ↔ floor) when STAIRS tool is active
	if ke.keycode == KEY_T and not ke.ctrl_pressed and not ke.shift_pressed and not ke.alt_pressed:
		if _tool == Tool.STAIRS:
			_stair_target = "floor" if _stair_target == "loft" else "loft"
			if is_instance_valid(_ov):
				_ov.set("stair_hover_target", _stair_target)
				_ov.queue_redraw()
			_set_status("Stair target: " + _stair_target)
			get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	# The 3D preview is a separate Room3DView control layered on top that
	# handles its own camera orbit/zoom/pan via its own gui_input — none of
	# this 2D-canvas input handling (including camera zoom/pan below) should
	# run underneath it, or scrolling over the 3D view ends up silently
	# zooming the hidden 2D camera instead of the 3D one.
	if _view3d_active:
		return
	if not (event is InputEventMouse or event is InputEventKey):
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
					var place_sp := (event as InputEventMouse).position
					if not _is_ui(place_sp):
						var place_fl := _to_floor(place_sp)
						var tx := int(place_fl.x / TILE_SIZE)
						var ty := int(place_fl.y / TILE_SIZE)
						var _pfsize := (_furn_data_by_id(_placing_furniture_id).get("size", {}) as Dictionary)
						var _pfw: int = _pfsize.get("w", 1) as int
						var _pfh: int = _pfsize.get("h", 1) as int
						var _on_floor := true
						if is_instance_valid(_floor):
							for _dx in range(_pfw):
								for _dy in range(_pfh):
									if not _floor.is_floor_tile(Vector2i(tx + _dx, ty + _dy)):
										_on_floor = false
						if not _on_floor:
							_set_status("Can't place here — no floor under this footprint")
							get_viewport().set_input_as_handled()
							return
						_placed_furniture.append({"id": _placing_furniture_id, "x": tx, "y": ty})
						# If placed over a drawn rail, mark it as rail-constrained
						var _ri := _detect_rail_under(tx, ty, _pfw, _pfh)
						if not _ri.is_empty():
							var _last := _placed_furniture[_placed_furniture.size() - 1] as Dictionary
							_last["rail_axis"]  = _ri["axis"]
							_last["rail_start"] = _ri["start"]
							_last["rail_end"]   = _ri["end"]
							# If also dropped over a reveal zone on the same axis, this piece
							# grants "dress" while parked inside that zone (per moment).
							var _rev := _detect_reveal_under(tx, ty, _pfw, _pfh)
							if not _rev.is_empty() and _rev["axis"] == _ri["axis"]:
								_last["reveal_start"]     = _rev["start"]
								_last["reveal_end"]       = _rev["end"]
								_last["reveal_functions"] = ["dress"]
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
						_fill_placed_list()
						get_viewport().set_input_as_handled()
		elif event is InputEventMouseMotion:
			var move_sp := (event as InputEventMouse).position
			var move_fl := _to_floor(move_sp)
			var tx := int(move_fl.x / TILE_SIZE)
			var ty := int(move_fl.y / TILE_SIZE)
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
			if _popup_open > 0:
				return  # let the popup's ScrollContainer handle the scroll
			var vp_size := get_viewport().get_visible_rect().size
			var mx := mb.position.x
			var over_panel := mx < LEFT_W or mx > vp_size.x - RIGHT_W or mb.position.y < TOP_H or mb.position.y > vp_size.y - BOTTOM_H
			if not over_panel:
				_do_zoom(mb.button_index == MOUSE_BUTTON_WHEEL_UP, mb.position)
				get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and _space_held:
			# Space+drag pans too (in addition to middle-drag) — middle-mouse-only
			# panning is uncomfortable/unavailable on a lot of trackpads, and
			# Space+drag is the same convention Godot's own 2D editor uses.
			_panning = mb.pressed
			_pan_last = mb.position
			get_viewport().set_input_as_handled()
			return
	elif event is InputEventMouseMotion and _panning:
		var delta := (event as InputEventMouseMotion).relative
		if is_instance_valid(_camera):
			_camera.position -= delta / _camera.zoom.x
		get_viewport().set_input_as_handled()
		return
	elif event is InputEventKey:
		var ke := event as InputEventKey
		if ke.keycode == KEY_SPACE:
			_space_held = ke.pressed
			if not ke.pressed:
				_panning = false
			return
		if ke.pressed and not ke.echo and ke.keycode == KEY_F and not (ke.ctrl_pressed or ke.shift_pressed or ke.alt_pressed):
			_fit_camera(true)
			get_viewport().set_input_as_handled()
			return

	# Every branch below this point is mouse-only canvas/tool logic (starting
	# with the unconditional `(event as InputEventMouse).position` cast further
	# down) — any key event that wasn't Space/F above (e.g. Print Screen, Tab,
	# arrow keys, ...) must not fall through, since InputEventKey as
	# InputEventMouse is null and `.position` on that crashes with "Invalid
	# access to property or key 'position' on a base object of type 'Nil'".
	if event is InputEventKey:
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
	if _popup_open > 0:
		return  # let overlay popups handle their own clicks / drags

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
			_door_shift_held = mb.shift_pressed
			_lmb_down(fl, tile)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if _tool == Tool.FLOOR:
				_floor_painting = true; _floor_erase = true
				_paint_floor_tile(tile, true)
			elif _tool == Tool.MEZZANINE:
				_mezz_painting = true; _mezz_erase = true
				_paint_mezz_tile(tile, true)
			elif _tool == Tool.STAIRS:
				_remove_stair_at(tile)
			elif _tool == Tool.WINDOW:
				var hit := _detect_segment_at(fl)
				if not hit.is_empty():
					_window_painting = true; _window_erase = true
					_paint_window_tile(hit["idx"] as int, hit["pos"] as int, true)
			elif _tool == Tool.RAIL:
				_erase_rail_at(tile)
			elif _tool == Tool.REVEAL:
				_erase_reveal_at(tile)
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
		elif _window_painting:
			var hit := _detect_segment_at(fl)
			if not hit.is_empty():
				_paint_window_tile(hit["idx"] as int, hit["pos"] as int, _window_erase)
		elif _pdrawing:
			_preview_wall(tile)
		if is_instance_valid(_ov):
			var is_wall := _tool == Tool.PRIMARY_WALL or _tool == Tool.SECONDARY_WALL
			var is_rail := _tool == Tool.RAIL
			var is_reveal := _tool == Tool.REVEAL
			var snapped_tile := _snap_tile(tile)
			var is_floor_like := _tool == Tool.FLOOR or _tool == Tool.MEZZANINE
			_ov.set("floor_hover",  tile if is_floor_like else Vector2i(-1, -1))
			_ov.set("mezz_hover",   _tool == Tool.MEZZANINE)
			_ov.set("stair_hover",  _tool == Tool.STAIRS)
			if _tool == Tool.STAIRS:
				var _sr := _stair_rect_at(tile)
				_ov.set("stair_hover_rect",   _sr)
				_ov.set("stair_hover_dir",    _stair_dir)
				_ov.set("stair_hover_target", _stair_target)
			_ov.set("wall_hover",   snapped_tile if ((is_wall or is_rail or is_reveal) and not _pdrawing) else Vector2i(-1, -1))
			_ov.set("wall_primary", _tool == Tool.PRIMARY_WALL)
			_ov.set("rail_mode",    is_rail)
			_ov.set("reveal_mode",  is_reveal)
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


# Continuous exponential zoom (each notch scales by a fixed ratio, like
# Godot's own 2D editor / Figma / Blender) instead of the old ±1 screen-pixel
# step — that scheme only had ~24 usable increments total across its whole
# 1..32px/tile range and felt like it wasn't responding to most scroll input.
const ZOOM_STEP := 1.12
const ZOOM_MIN  := 0.25   # ~2px/tile — below this, tiles/walls/furniture icons become illegible anyway
const ZOOM_MAX  := 6.0    # ~48px/tile — fine detail work (rails, doors)

func _do_zoom(zoom_in: bool, at_screen_pos = null) -> void:
	if not is_instance_valid(_camera):
		return
	var old_z := _camera.zoom.x
	var new_z: float = clampf(old_z * (ZOOM_STEP if zoom_in else 1.0 / ZOOM_STEP), ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(new_z, old_z):
		return
	# Zoom toward the cursor position when given (mouse wheel), else canvas centre (Fit/keys)
	var vp  := get_viewport().get_visible_rect().size
	var ctr: Vector2
	if at_screen_pos != null:
		ctr = at_screen_pos as Vector2
	else:
		var aw := vp.x - LEFT_W - RIGHT_W - 20.0
		var ah := vp.y - TOP_H - 16.0
		ctr = Vector2(LEFT_W + aw * 0.5, TOP_H + ah * 0.5)
	var world_ctr := _camera.position + (ctr - vp * 0.5) / old_z
	_camera.position = world_ctr - (ctr - vp * 0.5) / new_z
	_camera.zoom     = Vector2(new_z, new_z)
	_update_zoom_label()

func _update_zoom_label() -> void:
	if not is_instance_valid(_camera) or not is_instance_valid(_zoom_label):
		return
	# 100% = the initial fit-to-grid zoom set by _fit_camera(), not raw px/tile,
	# so the number means "relative to your starting view" like other editors.
	var pct := roundi(_camera.zoom.x / maxf(_fit_zoom, 0.0001) * 100.0)
	_zoom_label.text = "%d%%" % pct


func _is_ui(sp: Vector2) -> bool:
	var sz := get_viewport().get_visible_rect().size
	return sp.x < LEFT_W or sp.x > sz.x - RIGHT_W or sp.y < TOP_H or sp.y > sz.y - BOTTOM_H


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
			_place_stair(tile)
		Tool.PRIMARY_WALL, Tool.SECONDARY_WALL, Tool.RAIL, Tool.REVEAL:
			_ps = _snap_tile(tile); _pe = _ps; _pdrawing = true
			if is_instance_valid(_ov):
				_ov.set("p_start", _ps)
				_ov.set("rail_mode", _tool == Tool.RAIL)
				_ov.set("reveal_mode", _tool == Tool.REVEAL)
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
					if _door_shift_held:
						var was_sliding := (sd.get("door_type", "swing") as String) == "sliding"
						sd["door_type"] = "swing" if was_sliding else "sliding"
						_segments[sidx] = sd
						_rebuild_floor()
						_set_status("Door set to %s" % ("swing" if was_sliding else "sliding"))
					else:
						sd.erase("has_door"); sd.erase("door_pos"); sd.erase("door_side"); sd.erase("door_type")
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
			sd["door_type"] = "sliding" if _door_shift_held else "swing"
			_segments[_door_seg_idx] = sd
			_rebuild_floor()
			if sd["door_type"] == "sliding":
				_set_status("Sliding door added")
			else:
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
		elif _tool == Tool.REVEAL:
			_reveal_zones.append({"x1": _ps.x, "y1": _ps.y, "x2": _pe.x, "y2": _pe.y})
			_rebuild_floor()
			_set_status("Reveal zone added (%d tiles) — drop a rail piece over it" % maxi(absi(_pe.x - _ps.x), absi(_pe.y - _ps.y)))
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
					_floor_kind.erase(t)
					if is_instance_valid(_floor):
						_floor.floor_mask.erase(t)
						_floor.floor_kind.erase(t)
					changed = true
			else:
				if t not in _floor_mask:
					_floor_mask[t] = true
					changed = true
				if _floor_kind.get(t) != _floor_kind_paint:
					_floor_kind[t] = _floor_kind_paint
					changed = true
				if is_instance_valid(_floor):
					_floor.floor_mask[t] = true
					_floor.floor_kind[t] = _floor_kind_paint
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


const STAIR_STEP_DEPTH := 2   # tiles per step (20 cm)
const STAIR_STEPS      := 9   # steps to reach loft (18-tile height / 2 tiles per step)
const STAIR_WIDTH      := 8   # tiles wide (80 cm minimum)

func _stair_rect_at(tile: Vector2i) -> Rect2i:
	var w: int; var h: int
	match _stair_dir:
		"north", "south": w = STAIR_WIDTH;                    h = STAIR_STEPS * STAIR_STEP_DEPTH
		_:                 w = STAIR_STEPS * STAIR_STEP_DEPTH; h = STAIR_WIDTH

	# Default: centered on cursor
	var cx := tile.x - w / 2
	var cy := tile.y - h / 2

	# Loft stairs snap to mezzanine edge; floor stairs are placed freely.
	if _stair_target != "loft":
		return Rect2i(cx, cy, w, h)

	# Snap loft end to the nearest mezzanine boundary in the ascent direction.
	# Search up to (run + 4) tiles away from cursor so close-but-not-exact hovers snap.
	var search := h + 4
	match _stair_dir:
		"north":
			# Loft end is the top edge (cy). Scan upward for mezzanine.
			for dy in range(0, search):
				if _mezzanine_mask.has(Vector2i(tile.x, tile.y - dy)):
					# Walk to find the southernmost row of this mezzanine blob
					var my := tile.y - dy
					while _mezzanine_mask.has(Vector2i(tile.x, my + 1)):
						my += 1
					cy = my + 1   # stair top sits just south of mezzanine
					break
		"south":
			# Loft end is the bottom edge (cy + h). Scan downward.
			for dy in range(0, search):
				if _mezzanine_mask.has(Vector2i(tile.x, tile.y + dy)):
					var my := tile.y + dy
					while my > 0 and _mezzanine_mask.has(Vector2i(tile.x, my - 1)):
						my -= 1
					cy = my - h   # stair bottom sits just north of mezzanine
					break
		"east":
			# Loft end is the right edge (cx + w). Scan rightward.
			search = w + 4
			for dx in range(0, search):
				if _mezzanine_mask.has(Vector2i(tile.x + dx, tile.y)):
					var mx := tile.x + dx
					while mx > 0 and _mezzanine_mask.has(Vector2i(mx - 1, tile.y)):
						mx -= 1
					cx = mx - w
					break
		"west":
			# Loft end is the left edge (cx). Scan leftward.
			search = w + 4
			for dx in range(0, search):
				if _mezzanine_mask.has(Vector2i(tile.x - dx, tile.y)):
					var mx := tile.x - dx
					while _mezzanine_mask.has(Vector2i(mx + 1, tile.y)):
						mx += 1
					cx = mx + 1
					break

	return Rect2i(cx, cy, w, h)

func _place_stair(tile: Vector2i) -> void:
	if _active_floor_type() != "floor":
		_set_status("Stairs can only be placed on floor layers")
		return
	var r := _stair_rect_at(tile)
	var entry := {"x": r.position.x, "y": r.position.y,
		"w": r.size.x, "h": r.size.y, "direction": _stair_dir, "target": _stair_target}
	_stairs.append(entry)
	_rebuild_stair_mask()
	_set_status("Staircase placed (%s → %s)" % [_stair_dir, _stair_target])

func _remove_stair_at(tile: Vector2i) -> void:
	var before := _stairs.size()
	_stairs = _stairs.filter(func(e) -> bool:
		var r := Rect2i((e as Dictionary)["x"] as int, (e as Dictionary)["y"] as int,
			(e as Dictionary)["w"] as int, (e as Dictionary)["h"] as int)
		return not r.has_point(tile))
	if _stairs.size() < before:
		_rebuild_stair_mask()
		_set_status("Staircase removed")

func _rebuild_stair_mask() -> void:
	_stair_mask.clear()
	for e in _stairs:
		var ed := e as Dictionary
		var r  := Rect2i(ed["x"] as int, ed["y"] as int, ed["w"] as int, ed["h"] as int)
		for x in range(r.size.x):
			for y in range(r.size.y):
				_stair_mask[Vector2i(r.position.x + x, r.position.y + y)] = true
	if is_instance_valid(_floor):
		_floor.stair_mask = _stair_mask.duplicate()
		_floor.stairs_data.clear()
		for e in _stairs:
			var ed  := e as Dictionary
			var r   := Rect2i(ed["x"] as int, ed["y"] as int, ed["w"] as int, ed["h"] as int)
			var dir := ed["direction"] as String
			var tgt := ed.get("target", "loft") as String
			_floor.stairs_data.append({"rect": r, "direction": dir, "target": tgt})
		_floor.grid_draw.queue_redraw()

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
		else "%d item(s) allowed" % _allowed_furniture.size()


func _update_inv_count_lbl() -> void:
	_fill_placed_list()


# ── Bottom furniture catalog panel ───────────────────────────────────────────

func _build_bottom(ui: Node) -> void:
	var panel := PanelContainer.new()
	var ps := StyleBoxFlat.new()
	ps.bg_color    = Color(0.115, 0.100, 0.085)
	ps.border_color = Color(0.18, 0.24, 0.34, 0.70)
	ps.set_border_width(SIDE_TOP, 1)
	ps.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", ps)
	panel.set_anchor(SIDE_RIGHT,  1.0)
	panel.set_anchor(SIDE_TOP,    1.0)
	panel.set_anchor(SIDE_BOTTOM, 1.0)
	panel.offset_left   = LEFT_W
	panel.offset_right  = -RIGHT_W
	panel.offset_top    = -BOTTOM_H
	ui.add_child(panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(outer)

	var hdr := Label.new()
	hdr.text = "FLOOR ITEMS"
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	outer.add_child(hdr)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	_editor_furn_vb = VBoxContainer.new()
	_editor_furn_vb.add_theme_constant_override("separation", 3)
	_editor_furn_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_editor_furn_vb)

	_refresh_editor_furn_panel()


func _refresh_editor_furn_panel() -> void:
	if not is_instance_valid(_editor_furn_vb):
		return
	for c in _editor_furn_vb.get_children():
		c.queue_free()

	var catalog: Array = _furn_catalog
	if not _allowed_furniture.is_empty():
		catalog = catalog.filter(
			func(f: Dictionary) -> bool: return f["id"] as String in _allowed_furniture)

	for fraw in catalog:
		var fdata := fraw as Dictionary
		var fid    := fdata["id"] as String
		var fw: int = (fdata.get("size", {}) as Dictionary).get("w", 5) as int
		var fh: int = (fdata.get("size", {}) as Dictionary).get("h", 5) as int
		var fcolor := Color("#" + fdata.get("color", "888888") as String)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_editor_furn_vb.add_child(row)

		var swatch := ColorRect.new()
		swatch.color = fcolor
		swatch.custom_minimum_size = Vector2(8, 0)
		swatch.size_flags_vertical = Control.SIZE_EXPAND_FILL
		row.add_child(swatch)

		var name_lbl := Label.new()
		name_lbl.text = fdata["name"] as String
		name_lbl.custom_minimum_size.x = 108
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(name_lbl)

		var funcs := fdata.get("functions", []) as Array
		var func_lbl := Label.new()
		func_lbl.text = ", ".join(funcs) if not funcs.is_empty() else "decor"
		func_lbl.custom_minimum_size.x = 100
		func_lbl.add_theme_font_size_override("font_size", 10)
		func_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
		row.add_child(func_lbl)

		var place_btn := Button.new()
		place_btn.text = "Free"
		place_btn.add_theme_font_size_override("font_size", 11)
		place_btn.pressed.connect(func(): _start_placement(fid, fw, fh, fcolor))
		row.add_child(place_btn)


func _fill_placed_list() -> void:
	if not is_instance_valid(_placed_vb):
		return
	for c in _placed_vb.get_children():
		c.queue_free()

	if _placed_furniture.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "—"
		empty_lbl.add_theme_font_size_override("font_size", 9)
		empty_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
		_placed_vb.add_child(empty_lbl)
		return

	for pi in range(_placed_furniture.size()):
		var pf     := _placed_furniture[pi] as Dictionary
		var pfid   := pf["id"] as String
		var pfdata := _furn_data_by_id(pfid)
		var pfname := pfdata.get("name", pfid) as String
		var prow := HBoxContainer.new()
		prow.add_theme_constant_override("separation", 2)
		_placed_vb.add_child(prow)
		var plbl := Label.new()
		plbl.text = pfname
		plbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		plbl.add_theme_font_size_override("font_size", 9)
		prow.add_child(plbl)
		var pci := pi
		var del_btn := Button.new()
		del_btn.text = "×"
		del_btn.add_theme_font_size_override("font_size", 9)
		del_btn.add_theme_color_override("font_color", Color(0.80, 0.30, 0.20))
		del_btn.pressed.connect(func():
			_placed_furniture.remove_at(pci)
			_update_placed_furniture_overlay()
			_fill_placed_list())
		prow.add_child(del_btn)


# ── Catalog filter modal ──────────────────────────────────────────────────────

func _open_catalog_filter_modal() -> void:
	var win := Window.new()
	win.title = "Catalog Filter"
	win.size = Vector2i(300, 520)
	win.wrap_controls = true
	win.close_requested.connect(func():
		_update_cat_filter_lbl()
		_refresh_editor_furn_panel()
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
		# _allowed_furniture is a WHITELIST (matches Main.gd's shop filter): empty
		# means "no restriction", so every item shows checked until the player
		# unchecks the first one, at which point it becomes an explicit whitelist.
		cb.button_pressed = _allowed_furniture.is_empty() or fid in _allowed_furniture
		cb.add_theme_font_size_override("font_size", 10)
		cb.toggled.connect(func(on: bool):
			if on:
				if fid not in _allowed_furniture and not _allowed_furniture.is_empty():
					_allowed_furniture.append(fid)
			else:
				if _allowed_furniture.is_empty():
					# First uncheck: convert "allow all" into an explicit
					# whitelist of every other catalog item.
					for other in _furn_catalog:
						var oid := (other as Dictionary)["id"] as String
						if oid != fid:
							_allowed_furniture.append(oid)
				else:
					_allowed_furniture.erase(fid)
			_update_cat_filter_lbl())
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
	# Remove old preview nodes
	for pn in _furn_preview_nodes:
		if is_instance_valid(pn):
			pn.queue_free()
	_furn_preview_nodes.clear()

	if not is_instance_valid(_room):
		return

	for pf in _placed_furniture:
		var pfd   := pf as Dictionary
		var fid   := pfd["id"] as String
		var fdata := _furn_data_by_id(fid)
		if fdata.is_empty():
			continue
		var gx: int = pfd["x"] as int
		var gy: int = pfd["y"] as int
		# Merge per-instance rail overrides into catalog data for the preview node
		var merged := fdata.duplicate()
		for key in ["rail_axis", "rail_start", "rail_end"]:
			if pfd.has(key):
				merged[key] = pfd[key]

		var f: Furniture = FurnitureScene.instantiate() as Furniture
		_room.add_child(f)
		f.setup(merged, null)
		f.position = Vector2(gx * TILE_SIZE, gy * TILE_SIZE)
		# Disable all processing so preview nodes don't react to input
		f.process_mode = Node.PROCESS_MODE_DISABLED
		_furn_preview_nodes.append(f)
		# Also register onto the ephemeral _floor's own furniture tracking —
		# these preview nodes are otherwise purely 2D-visual children of _room
		# and invisible to Floor.get_all_furniture(), which is what the 3D
		# preview (_show_3d_preview -> Room3DView.build_from_floor) reads to
		# know what furniture exists on this floor.
		if is_instance_valid(_floor):
			_floor.place_furniture(f, Vector2(gx, gy))

	# Clear overlay rects (real nodes used instead)
	if is_instance_valid(_ov):
		_ov.set("placed_furniture", [])
		_ov.queue_redraw()


func _confirm_clear_all() -> void:
	if not is_instance_valid(_clear_dlg):
		_clear_dlg = ConfirmationDialog.new()
		_clear_dlg.title = "Clear All"
		_clear_dlg.dialog_text = "This will erase all floor tiles, walls, doors, windows and rails.\nCannot be undone. Continue?"
		_clear_dlg.get_ok_button().text = "Clear"
		_clear_dlg.confirmed.connect(func():
			_floor_mask.clear(); _floor_kind.clear(); _mezzanine_mask.clear(); _stair_mask.clear()
			_segments.clear(); _rails.clear(); _reveal_zones.clear(); _cols.clear()
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


func _detect_rail_under(tx: int, ty: int, fw: int, fh: int) -> Dictionary:
	for r in _rails:
		var x1: int = r["x1"]; var y1: int = r["y1"]
		var x2: int = r["x2"]; var y2: int = r["y2"]
		var mn_x := mini(x1, x2); var mx_x := maxi(x1, x2)
		var mn_y := mini(y1, y2); var mx_y := maxi(y1, y2)
		var is_h := (y1 == y2)
		if is_h:
			# Horizontal rail at row y1 — furniture must contain that row
			if ty <= y1 and y1 < ty + fh and tx < mx_x and tx + fw > mn_x:
				var start := mn_x
				var end   := mx_x - fw
				if end >= start:
					return {"axis": "h", "start": start, "end": end}
		else:
			# Vertical rail at col x1 — furniture must contain that column
			if tx <= x1 and x1 < tx + fw and ty < mx_y and ty + fh > mn_y:
				var start := mn_y
				var end   := mx_y - fh
				if end >= start:
					return {"axis": "v", "start": start, "end": end}
	return {}


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


# Reveal zone: a sub-range of a rail — a rail piece dropped so it overlaps this
# zone counts as "revealed" (gains reveal_functions) for whichever moment it's
# left there. Same detection shape as a rail, just a separate marker list.
func _detect_reveal_under(tx: int, ty: int, fw: int, fh: int) -> Dictionary:
	for rz in _reveal_zones:
		var x1: int = rz["x1"]; var y1: int = rz["y1"]
		var x2: int = rz["x2"]; var y2: int = rz["y2"]
		var mn_x := mini(x1, x2); var mx_x := maxi(x1, x2)
		var mn_y := mini(y1, y2); var mx_y := maxi(y1, y2)
		var is_h := (y1 == y2)
		# Only requires being on the SAME rail line (row for "h", column for "v") —
		# not positional overlap — since a piece is deliberately placed OUTSIDE
		# the reveal zone (its hidden dock) when first dropped on the rail.
		if is_h:
			if ty <= y1 and y1 < ty + fh:
				var start := mn_x
				var end   := mx_x - fw
				if end >= start:
					return {"axis": "h", "start": start, "end": end}
		else:
			if tx <= x1 and x1 < tx + fw:
				var start := mn_y
				var end   := mx_y - fh
				if end >= start:
					return {"axis": "v", "start": start, "end": end}
	return {}


func _erase_reveal_at(tile: Vector2i) -> void:
	for i in range(_reveal_zones.size()):
		var rz := _reveal_zones[i] as Dictionary
		var x1: int = rz["x1"]; var y1: int = rz["y1"]
		var x2: int = rz["x2"]; var y2: int = rz["y2"]
		var mn_x := mini(x1, x2); var mx_x := maxi(x1, x2)
		var mn_y := mini(y1, y2); var mx_y := maxi(y1, y2)
		if tile.x >= mn_x and tile.x <= mx_x and tile.y >= mn_y and tile.y <= mx_y:
			_reveal_zones.remove_at(i)
			_rebuild_floor()
			_set_status("Reveal zone erased")
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


# Fixed-but-generous editing canvas (DEFAULT_GW/GH, possibly grown further by
# _maybe_grow_grid) vs. what actually gets saved: gameplay should start on a
# grid sized to the real apartment, not the whole editing canvas, so this
# scans every floor's actual content and returns the tile furthest from the
# origin across all of them (apartment-wide grid_w/h is shared by all floors).
func _compute_content_bounds() -> Vector2i:
	_save_active_efloor()
	var max_x := 0
	var max_y := 0
	for fd in _editor_floors:
		var d := fd as Dictionary
		for t in (d.get("floor_tiles", []) as Array):
			max_x = maxi(max_x, t[0] as int); max_y = maxi(max_y, t[1] as int)
		for t in (d.get("mezzanine_tiles", []) as Array):
			max_x = maxi(max_x, t[0] as int); max_y = maxi(max_y, t[1] as int)
		for t in (d.get("stair_tiles", []) as Array):
			max_x = maxi(max_x, t[0] as int); max_y = maxi(max_y, t[1] as int)
		for seg in (d.get("segments", []) as Array):
			var sd := seg as Dictionary
			max_x = maxi(max_x, maxi(sd["x1"] as int, sd["x2"] as int))
			max_y = maxi(max_y, maxi(sd["y1"] as int, sd["y2"] as int))
		for r in (d.get("rails", []) as Array):
			var rd := r as Dictionary
			max_x = maxi(max_x, maxi(rd["x1"] as int, rd["x2"] as int))
			max_y = maxi(max_y, maxi(rd["y1"] as int, rd["y2"] as int))
		for rz in (d.get("reveal_zones", []) as Array):
			var zd := rz as Dictionary
			max_x = maxi(max_x, maxi(zd["x1"] as int, zd["x2"] as int))
			max_y = maxi(max_y, maxi(zd["y1"] as int, zd["y2"] as int))
		for c in (d.get("columns", []) as Array):
			var cd := c as Dictionary
			max_x = maxi(max_x, cd["x"] as int)
			max_y = maxi(max_y, cd["y"] as int)
	for pf in _placed_furniture:
		var pfd := pf as Dictionary
		max_x = maxi(max_x, pfd.get("x", 0) as int)
		max_y = maxi(max_y, pfd.get("y", 0) as int)
	return Vector2i(max_x, max_y)


const SAVE_CROP_MARGIN := 4
const MIN_SAVED_GRID   := 20

func _build_dict() -> Dictionary:
	_collect_meta()
	var req: Array = []
	for fn: String in _funcs:
		if _funcs[fn]:
			req.append(fn)
	var lvl_id := _lname.to_lower().replace(" ", "_")
	var bounds := _compute_content_bounds()
	var saved_gw := maxi(bounds.x + SAVE_CROP_MARGIN, MIN_SAVED_GRID)
	var saved_gh := maxi(bounds.y + SAVE_CROP_MARGIN, MIN_SAVED_GRID)
	return {
		"id": lvl_id, "name": _lname, "district": _dist,
		"acquisition_cost": _cost,
		"map_col": _map_col, "map_row": _map_row, "min_stars": 0, "block": _block,
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
			"grid_w": saved_gw, "grid_h": saved_gh,
			"active_floor": _active_efl,
			"hidden_floors": _hidden_fl_ids.keys(),
			"floors": (func() -> Array:
				_save_active_efloor()
				return _editor_floors.duplicate(true)).call()
		}
	}


func _save_level() -> void:
	if _lname.strip_edges().is_empty() or _lname == "Untitled Apartment":
		_prompt_level_name(func(new_name: String):
			_lname = new_name
			_save_level())
		return

	var d := _build_dict()
	var lvl_id := d["id"] as String

	# Read the current levels.json
	var lf := FileAccess.open("res://data/levels.json", FileAccess.READ)
	if not lf:
		_set_status("Save failed — cannot open levels.json")
		return
	var lj := JSON.new()
	if lj.parse(lf.get_as_text()) != OK:
		lf.close()
		_set_status("Save failed — levels.json parse error")
		return
	lf.close()
	var root := lj.get_data() as Dictionary
	var levels := root.get("levels", []) as Array

	# Update existing entry or append
	var found := false
	for i in range(levels.size()):
		if (levels[i] as Dictionary).get("id", "") == lvl_id:
			levels[i] = d
			found = true
			break
	if not found:
		# Auto-assign the next free grid slot (sequential, 5 cols wide)
		var used: Dictionary = {}
		for lv in levels:
			var k := "%d,%d" % [(lv as Dictionary).get("map_col", 0), (lv as Dictionary).get("map_row", 0)]
			used[k] = true
		var placed := false
		for r in range(100):
			if placed: break
			for c in range(5):
				var k := "%d,%d" % [c, r]
				if not used.has(k):
					d["map_col"] = c
					d["map_row"] = r
					_map_col = c
					_map_row = r
					placed = true
					break
		levels.append(d)
	root["levels"] = levels

	var wf := FileAccess.open("res://data/levels.json", FileAccess.WRITE)
	if not wf:
		_set_status("Save failed — cannot write levels.json")
		return
	wf.store_string(JSON.stringify(root, "\t"))
	wf.close()
	_set_status("Saved \"%s\" → levels.json (block %d, col %d, row %d)" % [_lname, _block, _map_col, _map_row])


func _prompt_level_name(on_confirm: Callable) -> void:
	_popup_open += 1
	var cl := CanvasLayer.new()
	cl.layer = 30
	cl.tree_exited.connect(func(): _popup_open -= 1)
	add_child(cl)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	cl.add_child(bg)

	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color     = Color(0.115, 0.100, 0.085)
	cs.border_color = Color(0.24, 0.34, 0.48)
	cs.set_border_width_all(1)
	cs.set_content_margin_all(20)
	card.add_theme_stylebox_override("panel", cs)
	card.set_anchor(SIDE_LEFT,   0.5); card.set_anchor(SIDE_RIGHT,  0.5)
	card.set_anchor(SIDE_TOP,    0.5); card.set_anchor(SIDE_BOTTOM, 0.5)
	card.offset_left = -170; card.offset_right  = 170
	card.offset_top  =  -70; card.offset_bottom =  70
	cl.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	card.add_child(vb)

	var ttl := Label.new()
	ttl.text = "Level Name"
	ttl.add_theme_font_size_override("font_size", 13)
	ttl.add_theme_color_override("font_color", GameTheme.C_AMBER)
	vb.add_child(ttl)

	var line := LineEdit.new()
	line.placeholder_text = "e.g. Calle Mayor 4B"
	line.custom_minimum_size = Vector2(300, 0)
	line.add_theme_font_size_override("font_size", 12)
	vb.add_child(line)
	line.grab_focus()

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	vb.add_child(hb)

	var ok := Button.new()
	ok.text = "Save"
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok.add_theme_font_size_override("font_size", 11)
	hb.add_child(ok)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.add_theme_font_size_override("font_size", 11)
	cancel.add_theme_color_override("font_color", GameTheme.C_MUTED)
	hb.add_child(cancel)

	var _do_confirm := func():
		var entered_name := line.text.strip_edges()
		if entered_name.is_empty():
			return
		cl.queue_free()
		on_confirm.call(entered_name)

	ok.pressed.connect(_do_confirm)
	line.text_submitted.connect(func(_t: String): _do_confirm.call())
	cancel.pressed.connect(cl.queue_free)


func _load_dialog() -> void:
	var items: Array = []
	var lf := FileAccess.open("res://data/levels.json", FileAccess.READ)
	if lf:
		var lj := JSON.new()
		if lj.parse(lf.get_as_text()) == OK:
			for lvl in (lj.get_data() as Dictionary).get("levels", []) as Array:
				var lvld := lvl as Dictionary
				var lbl  := lvld.get("name", lvld.get("id", "?")) as String
				items.append({"label": lbl, "data": lvld})
		lf.close()
	if items.is_empty():
		_set_status("No levels found — save a level first")
		return
	_show_load_popup(items)


func _show_load_popup(_items: Array) -> void:
	_popup_open += 1
	var cl := CanvasLayer.new()
	cl.layer = 30
	cl.tree_exited.connect(func(): _popup_open -= 1)
	add_child(cl)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	cl.add_child(bg)

	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color = Color(0.115, 0.100, 0.085)
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
	scroll.custom_minimum_size = Vector2(340, 260)
	vb.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)

	_build_load_rows(list, cl)


	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.add_theme_font_size_override("font_size", 11)
	cancel.add_theme_color_override("font_color", GameTheme.C_MUTED)
	cancel.pressed.connect(cl.queue_free)
	vb.add_child(cancel)

	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			cl.queue_free())


func _build_load_rows(list: VBoxContainer, cl: CanvasLayer) -> void:
	for ch in list.get_children():
		ch.queue_free()
	var items: Array = []
	var lf := FileAccess.open("res://data/levels.json", FileAccess.READ)
	if lf:
		var lj := JSON.new()
		if lj.parse(lf.get_as_text()) == OK:
			for lvl in (lj.get_data() as Dictionary).get("levels", []) as Array:
				var ld := lvl as Dictionary
				items.append({"label": ld.get("name", ld.get("id", "?")) as String, "data": ld})
		lf.close()
	for item: Dictionary in items:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		list.add_child(row)
		var load_btn := Button.new()
		load_btn.text = item["label"] as String
		load_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		load_btn.add_theme_font_size_override("font_size", 11)
		load_btn.pressed.connect(func():
			_load_from_dict(item["data"] as Dictionary)
			cl.queue_free())
		row.add_child(load_btn)
		var del_btn := Button.new()
		del_btn.text = "×"
		del_btn.add_theme_font_size_override("font_size", 13)
		del_btn.add_theme_color_override("font_color", Color(0.85, 0.30, 0.25, 1.0))
		del_btn.custom_minimum_size = Vector2(28, 0)
		del_btn.pressed.connect(func():
			_delete_level((item["data"] as Dictionary).get("id", "") as String)
			_build_load_rows(list, cl))
		row.add_child(del_btn)


func _delete_level(lvl_id: String) -> void:
	if lvl_id.is_empty():
		return
	var lf := FileAccess.open("res://data/levels.json", FileAccess.READ)
	if not lf:
		return
	var lj := JSON.new()
	if lj.parse(lf.get_as_text()) != OK:
		lf.close(); return
	lf.close()
	var root := lj.get_data() as Dictionary
	var levels := root.get("levels", []) as Array
	for i in range(levels.size()):
		if (levels[i] as Dictionary).get("id", "") == lvl_id:
			levels.remove_at(i)
			break
	# Repack grid positions so there are no gaps after deletion
	for i in range(levels.size()):
		(levels[i] as Dictionary)["map_col"] = i % 5
		(levels[i] as Dictionary)["map_row"] = i / 5
	root["levels"] = levels
	var wf := FileAccess.open("res://data/levels.json", FileAccess.WRITE)
	if wf:
		wf.store_string(JSON.stringify(root, "\t"))
		wf.close()
	_set_status("Deleted \"%s\"" % lvl_id)


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
	_budget   = d.get("starting_budget",  2000) as int
	_rent     = ten.get("monthly_rent",    300) as int
	_reward   = d.get("funds_base_reward", 800) as int
	_cost     = d.get("acquisition_cost", 1500) as int
	_block    = d.get("block",    1) as int
	_map_col  = d.get("map_col", 0) as int
	_map_row  = d.get("map_row", 0) as int
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
	_refresh_editor_furn_panel()

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
		for fn: String in ["sleep", "sit", "work", "cook", "storage", "dine", "dress"]:
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
	gs.call("own_level", "_custom")
	Transition.change_scene("res://scenes/Main.tscn")
