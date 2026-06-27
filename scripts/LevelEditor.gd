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

enum Tool { FLOOR, PRIMARY_WALL, SECONDARY_WALL, WINDOW, DOOR, COLUMN, ERASE }

# ── Floor geometry ────────────────────────────────────────────────────────────
var _gw: int = DEFAULT_GW
var _gh: int = DEFAULT_GH
var _floor_mask: Dictionary = {}  # Vector2i -> true (painted floor tiles)
var _segments:   Array      = []  # [{x1,y1,x2,y2,primary,demolished,...}]
var _cols:       Array      = []  # [{x,y}]

# ── Wall drawing state ────────────────────────────────────────────────────────
var _floor_painting:  bool = false
var _floor_erase:     bool = false
var _floor_brush:     int  = 1   # 1 = tile (10 cm), 10 = cell (1 m = 10×10 tiles)

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
	"sleep": false, "sit": false, "work": false, "cook": false, "storage": false
}

# ── Tool & interaction state ──────────────────────────────────────────────────
var _tool: Tool = Tool.FLOOR
var _ps: Vector2i = Vector2i(-1, -1)
var _pe: Vector2i = Vector2i(-1, -1)
var _pdrawing: bool = false

# ── Camera pan / zoom ─────────────────────────────────────────────────────────
var _panning: bool    = false
var _pan_last: Vector2 = Vector2.ZERO

# ── Scene nodes ───────────────────────────────────────────────────────────────
var _room:   Node2D   = null
var _camera: Camera2D = null
var _floor:  Floor    = null
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


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  READY                                                                   ║
# ╚══════════════════════════════════════════════════════════════════════════╝

func _ready() -> void:
	_build_scene()
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
		[Tool.PRIMARY_WALL,  "Primary Wall",   "Drag axis-snapped — cannot demolish"],
		[Tool.SECONDARY_WALL,"Secondary Wall", "Drag axis-snapped — can demolish"],
		[Tool.WINDOW,        "Window",         "Click on any wall segment"],
		[Tool.DOOR,          "Door",           "Click on any wall segment"],
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
		btn.pressed.connect(func(): _tool = t; _cancel_wall_drawing())
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
		_gw = int(_sw.value); _gh = int(_sh.value)
		_size_lbl.text = "= %.0fm × %.0fm" % [_gw * 0.1, _gh * 0.1]
		_rebuild_floor())
	vb.add_child(apply)

	_sect(vb, "ACTIONS")
	var clear_btn := Button.new()
	clear_btn.text = "Clear All"
	clear_btn.add_theme_font_size_override("font_size", 10)
	clear_btn.add_theme_color_override("font_color", Color(0.80, 0.30, 0.20))
	clear_btn.pressed.connect(func():
		_floor_mask.clear(); _segments.clear(); _cols.clear()
		_rebuild_floor()
		_set_status("Canvas cleared"))
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
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	vb.custom_minimum_size = Vector2(RIGHT_W - 24, 0)
	scroll.add_child(vb)

	_sect(vb, "LEVEL")
	_en = _field(vb, "Name",     _lname)
	_ed = _field(vb, "District", _dist)

	_sect(vb, "TENANT")
	_etn  = _field(vb,   "Name",        _tname)
	_sage = _spinbox(vb, "Age",         _tage,   18, 90,    1)
	_ef   = _field(vb,   "Flavor",      _tflav)

	_sect(vb, "ECONOMICS")
	_sbud  = _spinbox(vb, "Budget €",  _budget, 500,   20000, 100)
	_srent = _spinbox(vb, "Rent €/mo", _rent,   50,    3000,  50)
	_srew  = _spinbox(vb, "Reward €",  _reward, 200,   10000, 100)
	_scost = _spinbox(vb, "Cost €",    _cost,   0,     8000,  100)

	_sect(vb, "REQUIRED FUNCTIONS")
	for fn: String in ["sleep", "sit", "work", "cook", "storage"]:
		var cb := CheckBox.new()
		cb.text = fn
		cb.add_theme_font_size_override("font_size", 11)
		cb.add_theme_color_override("font_color", GameTheme.C_TEXT)
		_fncbs[fn] = cb
		vb.add_child(cb)

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

	_floor.setup({
		"id": "editor_preview", "label": "Ground Floor",
		"grid_w": _gw, "grid_h": _gh,
		"floor_tiles": floor_tiles,
		"segments": _segments.duplicate(true),
		"columns":  _cols.duplicate(true)
	})

	_ov = Node2D.new()
	_ov.set_script(_OV_SCRIPT)
	_room.add_child(_ov)
	_ov.set("floor_brush", _floor_brush)

	_fit_camera()


func _fit_camera() -> void:
	if not is_instance_valid(_camera):
		return
	var vp  := get_viewport().get_visible_rect().size
	var aw  := vp.x - LEFT_W - RIGHT_W - 20.0
	var ah  := vp.y - TOP_H - 16.0
	var scx := LEFT_W + aw * 0.5
	var scy := TOP_H  + ah * 0.5

	# 9 px/tile → each canvas-pixel = 1 tile = 10 cm subcell, visible area ≈ 70 m²
	# (876 / 9 ≈ 97 tiles wide = 9.7 m; 668 / 9 ≈ 74 tiles tall = 7.4 m → ~72 m²)
	const INIT_PX_PER_TILE := 9.0
	var z := INIT_PX_PER_TILE / float(TILE_SIZE)
	_camera.zoom = Vector2(z, z)

	# Place the view so the top-left corner of the canvas sits at the top-left of the screen
	var half_view_w := (aw * 0.5) / INIT_PX_PER_TILE * float(TILE_SIZE)
	var half_view_h := (ah * 0.5) / INIT_PX_PER_TILE * float(TILE_SIZE)
	_camera.position = Vector2(half_view_w, half_view_h)
	_camera.offset = Vector2(
		(vp.x * 0.5 - scx) / z,
		(vp.y * 0.5 - scy) / z
	)


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  INPUT                                                                   ║
# ╚══════════════════════════════════════════════════════════════════════════╝

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not (event as InputEventKey).pressed:
		return
	var ke := event as InputEventKey
	# Ctrl+R → reload scene with latest saved scripts (debug hot-reload)
	if ke.keycode == KEY_R and ke.ctrl_pressed and not ke.shift_pressed and not ke.alt_pressed:
		get_viewport().set_input_as_handled()
		get_tree().reload_current_scene()


func _input(event: InputEvent) -> void:
	if not event is InputEventMouse:
		return

	# ── Camera controls (work everywhere, not only in canvas) ────────────────
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			_pan_last = mb.position
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_do_zoom(true);  get_viewport().set_input_as_handled(); return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_do_zoom(false); get_viewport().set_input_as_handled(); return
	elif event is InputEventMouseMotion and _panning:
		var delta := (event as InputEventMouseMotion).relative
		if is_instance_valid(_camera):
			_camera.position -= delta / _camera.zoom.x
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
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_lmb_down(fl, tile)
			else:
				_lmb_up()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				if _tool == Tool.FLOOR:
					_floor_painting = true; _floor_erase = true
					_paint_floor_tile(tile, true)
				else:
					_erase_at(fl, tile)
			else:
				_floor_painting = false
	elif event is InputEventMouseMotion:
		if _floor_painting:
			_paint_floor_tile(tile, _floor_erase)
		elif _pdrawing:
			_preview_wall(tile)
		if is_instance_valid(_ov):
			_ov.set("floor_hover", tile if _tool == Tool.FLOOR else Vector2i(-1, -1))
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
		Tool.PRIMARY_WALL, Tool.SECONDARY_WALL:
			_ps = tile; _pe = tile; _pdrawing = true
			if is_instance_valid(_ov):
				_ov.set("p_start", _ps)
				_ov.set("p_end",   _pe)
				_ov.set("active",  true)
				_ov.queue_redraw()
		Tool.WINDOW:
			var hit := _detect_segment_at(fl)
			if not hit.is_empty():
				_toggle_window(hit["idx"] as int, hit["pos"] as int)
			else:
				_set_status("Click on a wall segment to add a window")
		Tool.DOOR:
			var hit := _detect_segment_at(fl)
			if not hit.is_empty():
				_toggle_door(hit["idx"] as int, hit["pos"] as int)
			else:
				_set_status("Click on a wall segment to add a door")
		Tool.COLUMN:
			_toggle_column(tile)
		Tool.ERASE:
			_erase_at(fl, tile)


func _lmb_up() -> void:
	if _floor_painting:
		_floor_painting = false
		_rebuild_floor()
		return
	if not _pdrawing:
		return
	_pdrawing = false
	if is_instance_valid(_ov):
		_ov.set("active", false)
		_ov.queue_redraw()
	if _ps.x >= 0 and _ps != _pe and (_ps.x == _pe.x or _ps.y == _pe.y):
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
	var t := tile
	if abs(t.x - _ps.x) >= abs(t.y - _ps.y):
		t.y = _ps.y
	else:
		t.x = _ps.x
	_pe = t
	if is_instance_valid(_ov):
		_ov.set("p_end", _pe)
		_ov.queue_redraw()


func _cancel_wall_drawing() -> void:
	_floor_painting = false
	if not _pdrawing:
		return
	_pdrawing = false
	_ps = Vector2i(-1, -1)
	if is_instance_valid(_ov):
		_ov.set("active", false)
		_ov.queue_redraw()


func _paint_floor_tile(tile: Vector2i, erase: bool) -> void:
	# Snap to brush-size grid origin (1 = single tile, 10 = full 1m cell)
	var ox := (tile.x / _floor_brush) * _floor_brush
	var oy := (tile.y / _floor_brush) * _floor_brush
	var changed := false
	for dy in range(_floor_brush):
		for dx in range(_floor_brush):
			var t := Vector2i(ox + dx, oy + dy)
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


func _detect_segment_at(fl: Vector2) -> Dictionary:
	const SNAP := float(TILE_SIZE) * 2.0
	var best_d := SNAP
	var best_i := -1
	var best_p := 0
	for i in range(_segments.size()):
		var sd := _segments[i] as Dictionary
		if sd.get("demolished", false):
			continue
		var pa := Vector2(sd["x1"] as int * TILE_SIZE, sd["y1"] as int * TILE_SIZE)
		var pb := Vector2(sd["x2"] as int * TILE_SIZE, sd["y2"] as int * TILE_SIZE)
		var seg := pb - pa
		var seg_len := seg.length()
		if seg_len < 1.0:
			continue
		var t  := clampf((fl - pa).dot(seg) / (seg_len * seg_len), 0.0, 1.0)
		var d  := fl.distance_to(pa + seg * t)
		if d < best_d:
			best_d = d; best_i = i
			best_p = int(t * seg_len / TILE_SIZE)
	if best_i < 0:
		return {}
	return {"idx": best_i, "pos": best_p}


func _toggle_window(seg_idx: int, pos: int) -> void:
	var sd := _segments[seg_idx] as Dictionary
	if sd.get("has_window", false):
		sd.erase("has_window"); sd.erase("window_pos"); sd.erase("window_len")
		_set_status("Window removed")
	else:
		sd["has_window"]  = true
		sd["window_pos"]  = maxi(0, pos - WIN_LEN / 2)
		sd["window_len"]  = WIN_LEN
		_set_status("Window added  (pos %d, len %d)" % [sd["window_pos"], WIN_LEN])
	_segments[seg_idx] = sd
	_rebuild_floor()


func _toggle_door(seg_idx: int, pos: int) -> void:
	var sd := _segments[seg_idx] as Dictionary
	if sd.get("has_door", false):
		sd.erase("has_door"); sd.erase("door_pos")
		_set_status("Door removed")
	else:
		sd["has_door"]  = true
		sd["door_pos"]  = maxi(0, pos - DOOR_LEN / 2)
		_set_status("Door added  (pos %d)" % sd["door_pos"])
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
	if _en:   _lname  = _en.text
	if _ed:   _dist   = _ed.text
	if _etn:  _tname  = _etn.text
	if _sage: _tage   = int(_sage.value)
	if _ef:   _tflav  = _ef.text
	if _sbud: _budget = int(_sbud.value)
	if _srent: _rent  = int(_srent.value)
	if _srew:  _reward = int(_srew.value)
	if _scost: _cost  = int(_scost.value)
	for fn: String in _fncbs:
		_funcs[fn] = (_fncbs[fn] as CheckBox).button_pressed


func _build_dict() -> Dictionary:
	_collect_meta()
	var req: Array = []
	for fn: String in _funcs:
		if _funcs[fn]:
			req.append(fn)
	var lvl_id     := "custom_" + _lname.to_lower().replace(" ", "_")
	var floor_tiles: Array = []
	for tile in _floor_mask:
		var t := tile as Vector2i
		floor_tiles.append([t.x, t.y])
	return {
		"id": lvl_id, "name": _lname, "district": _dist,
		"is_custom": true, "acquisition_cost": _cost,
		"map_col": 0, "map_row": 0, "min_stars": 0, "block": 1,
		"funds_base_reward": _reward, "starting_budget": _budget,
		"tenant": {
			"name": _tname, "age": _tage, "flavor": _tflav,
			"required_functions": req, "monthly_rent": _rent
		},
		"apartment": {"floors": [{
			"id": "ground", "label": "Ground Floor",
			"grid_w": _gw, "grid_h": _gh,
			"floor_tiles": floor_tiles,
			"segments": _segments.duplicate(true),
			"columns":  _cols.duplicate(true)
		}]}
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
	var d   := json.get_data() as Dictionary
	var floors: Array  = d.get("apartment", {}).get("floors", []) as Array
	var fl0: Dictionary = floors[0] as Dictionary if not floors.is_empty() else {}

	_gw   = fl0.get("grid_w", DEFAULT_GW) as int
	_gh   = fl0.get("grid_h", DEFAULT_GH) as int
	_cols = (fl0.get("columns", []) as Array).duplicate(true)

	# New-format data
	_floor_mask.clear()
	for t in fl0.get("floor_tiles", []):
		_floor_mask[Vector2i(t[0] as int, t[1] as int)] = true
	_segments = (fl0.get("segments", []) as Array).duplicate(true)
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

	if _en:    _en.text     = _lname
	if _ed:    _ed.text     = _dist
	if _etn:   _etn.text    = _tname
	if _sage:  _sage.value  = _tage
	if _ef:    _ef.text     = _tflav
	if _sbud:  _sbud.value  = _budget
	if _srent: _srent.value = _rent
	if _srew:  _srew.value  = _reward
	if _scost: _scost.value = _cost
	for fn: String in _fncbs:
		(_fncbs[fn] as CheckBox).button_pressed = _funcs[fn]
	if _sw:       _sw.value       = _gw
	if _sh:       _sh.value       = _gh
	if _size_lbl: _size_lbl.text  = "= %.0fm × %.0fm" % [_gw * 0.1, _gh * 0.1]
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
	get_tree().change_scene_to_file("res://scenes/Main.tscn")
