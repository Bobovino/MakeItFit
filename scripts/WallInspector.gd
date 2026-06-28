extends PanelContainer
class_name WallInspector

signal wall_closed

const TILE_SIZE:   int = 12
const WALL_HEIGHT: int = 24

var _all_furniture: Array  = []
var _wall_furniture: Array = []
var _selected_id: String   = ""

var _edge: String     = ""
var _apt_floor: Floor = null

# Drag shared
var _is_dragging:   bool     = false
var _drag_is_floor: bool     = false
var _drag_pos:      Vector2i = Vector2i.ZERO

# Wall item drag
var _drag_origin: Vector2i = Vector2i.ZERO
var _drag_offset: Vector2i = Vector2i.ZERO

# Floor item drag
var _drag_floor_furniture: Furniture = null
var _drag_floor_wall_x:    int       = 0
var _drag_floor_offset_x:  int       = 0

@onready var title_lbl:  Label         = $VBox/TitleRow/Title
@onready var close_btn:  Button        = $VBox/TitleRow/CloseBtn
@onready var hint_lbl:   Label         = $VBox/HintLabel
@onready var draw_area:  Control       = $VBox/Scroll/DrawArea
@onready var shop_strip: HBoxContainer = $VBox/WallItems


func setup(all_furniture: Array) -> void:
	_all_furniture  = all_furniture
	_wall_furniture = all_furniture.filter(func(f): return f.get("placement") == "wall")
	close_btn.pressed.connect(_on_close)
	draw_area.draw.connect(_draw_elevation)
	draw_area.gui_input.connect(_on_draw_input)
	draw_area.mouse_filter = Control.MOUSE_FILTER_STOP
	_show_placeholder()


func _show_placeholder() -> void:
	hint_lbl.visible   = true
	draw_area.visible  = false
	shop_strip.visible = false
	title_lbl.text     = "Wall Inspector"
	_clear_shop()


func show_wall(apt_floor: Floor, edge: String) -> void:
	if _apt_floor and _apt_floor.furniture_changed.is_connected(_on_floor_changed):
		_apt_floor.furniture_changed.disconnect(_on_floor_changed)

	_apt_floor   = apt_floor
	_edge        = edge
	_selected_id = ""
	_is_dragging = false
	_drag_floor_furniture = null

	_apt_floor.furniture_changed.connect(_on_floor_changed)

	title_lbl.text = "Wall: " + _edge_label(edge)
	draw_area.custom_minimum_size = Vector2(_wall_w() * TILE_SIZE, WALL_HEIGHT * TILE_SIZE)
	hint_lbl.visible   = false
	draw_area.visible  = true
	shop_strip.visible = true
	_build_shop()
	draw_area.queue_redraw()


func _on_floor_changed() -> void:
	draw_area.queue_redraw()


func _on_close() -> void:
	if _apt_floor and _apt_floor.furniture_changed.is_connected(_on_floor_changed):
		_apt_floor.furniture_changed.disconnect(_on_floor_changed)
	_apt_floor            = null
	_edge                 = ""
	_selected_id          = ""
	_is_dragging          = false
	_drag_floor_furniture = null
	_show_placeholder()
	wall_closed.emit()


# ── Shop ──────────────────────────────────────────────────────────────────────

func _clear_shop() -> void:
	for c in shop_strip.get_children():
		c.queue_free()


func _build_shop() -> void:
	_clear_shop()
	var grp := ButtonGroup.new()
	for f in _wall_furniture:
		var btn := Button.new()
		btn.text         = "%s  %d€" % [f["name"], f["buy_price"]]
		btn.toggle_mode  = true
		btn.button_group = grp
		btn.toggled.connect(_on_shop_toggled.bind(f["id"] as String))
		shop_strip.add_child(btn)


func _on_shop_toggled(pressed: bool, fid: String) -> void:
	_selected_id = fid if pressed else ""
	draw_area.queue_redraw()


func _deselect_shop() -> void:
	for child in shop_strip.get_children():
		(child as Button).button_pressed = false


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_draw_input(event: InputEvent) -> void:
	if not _apt_floor:
		return

	if event is InputEventMouseButton:
		var mbe  := event as InputEventMouseButton
		var tile := _pixel_to_tile(mbe.position)

		if mbe.button_index == MOUSE_BUTTON_LEFT:
			if mbe.pressed:
				var wall_hit: Variant = _wall_item_at(tile)
				if wall_hit != null:
					_drag_origin  = wall_hit as Vector2i
					_drag_offset  = tile - _drag_origin
					_drag_pos     = _drag_origin
					_is_dragging  = true
					_drag_is_floor = false
					_selected_id  = ""
					_deselect_shop()
				else:
					var floor_hit: Variant = _floor_item_at(tile)
					if floor_hit != null:
						var fhd               := floor_hit as Dictionary
						_drag_floor_furniture  = fhd["furniture"] as Furniture
						_drag_floor_wall_x     = fhd["wall_x"]   as int
						_drag_floor_offset_x   = fhd["offset_x"] as int
						_drag_pos              = Vector2i(_drag_floor_wall_x, 0)
						_is_dragging           = true
						_drag_is_floor         = true
						_selected_id           = ""
						_deselect_shop()
					elif _selected_id != "":
						_try_place(_selected_id, tile)
			else:
				if _is_dragging:
					if _drag_is_floor:
						_drop_floor_drag()
					else:
						_drop_wall_drag()

		elif mbe.button_index == MOUSE_BUTTON_RIGHT and mbe.pressed:
			if _is_dragging:
				_is_dragging          = false
				_drag_floor_furniture = null
				draw_area.queue_redraw()
			else:
				_remove_wall_at(tile)

	elif event is InputEventMouseMotion and _is_dragging:
		var mme := event as InputEventMouseMotion
		var cur := _pixel_to_tile(mme.position)
		if _drag_is_floor:
			_drag_pos.x = cur.x - _drag_floor_offset_x
		else:
			_drag_pos = cur - _drag_offset
		draw_area.queue_redraw()


func _pixel_to_tile(px: Vector2) -> Vector2i:
	return Vector2i(int(px.x / TILE_SIZE), int(px.y / TILE_SIZE))


# ── Placement helpers ─────────────────────────────────────────────────────────

func _wall_item_at(tile: Vector2i) -> Variant:
	var placed := _apt_floor.get_wall_items(_edge)
	for origin in placed:
		var o  := origin as Vector2i
		var pf := _find(placed[origin] as String)
		if pf.is_empty():
			continue
		var pw: int = pf["size"]["w"] as int
		var ph: int = pf.get("wall_h", 1) as int
		if tile.x >= o.x and tile.x < o.x + pw \
		and tile.y >= o.y and tile.y < o.y + ph:
			return o
	return null


func _floor_item_at(tile: Vector2i) -> Variant:
	var rh: int = WALL_HEIGHT * TILE_SIZE
	for entry in _apt_floor.get_adjacent_furniture(_edge):
		var f: Furniture = entry["furniture"]
		var wx: int      = entry["wall_x"] as int
		var fdata        := _find_by_id(f.furniture_id)
		if fdata.is_empty():
			continue
		var item_w: int = (f.grid_w if _edge in ["north", "south"] else f.grid_h)
		var wall_h: int = fdata.get("wall_h", 5) as int
		var py_tile: int = int((rh - wall_h * TILE_SIZE) / float(TILE_SIZE))
		if tile.x >= wx and tile.x < wx + item_w \
		and tile.y >= py_tile and tile.y < py_tile + wall_h:
			return {"furniture": f, "wall_x": wx, "offset_x": tile.x - wx}
	return null


func _try_place(fid: String, at: Vector2i) -> void:
	var f := _find(fid)
	if f.is_empty():
		return
	var iw: int     = f["size"]["w"] as int
	var ih: int     = f.get("wall_h", 1) as int
	var wall_w: int = _wall_w()
	at.x = clampi(at.x, 0, wall_w - iw)
	at.y = clampi(at.y, 0, WALL_HEIGHT - ih)
	var placed := _apt_floor.get_wall_items(_edge)
	if _wall_fits(at, iw, ih, placed):
		Audio.play("place")
		_apt_floor.place_wall_item(_edge, at, fid)


func _drop_wall_drag() -> void:
	_is_dragging = false
	var placed := _apt_floor.get_wall_items(_edge)
	if not (_drag_origin in placed):
		return
	var fid: String = placed[_drag_origin] as String
	var f := _find(fid)
	if f.is_empty():
		return
	var iw: int     = f["size"]["w"] as int
	var ih: int     = f.get("wall_h", 1) as int
	var wall_w: int = _wall_w()
	var at := Vector2i(
		clampi(_drag_pos.x, 0, wall_w - iw),
		clampi(_drag_pos.y, 0, WALL_HEIGHT - ih)
	)
	_apt_floor.remove_wall_item(_edge, _drag_origin)
	# placed is the same dict reference — origin is already erased
	if _wall_fits(at, iw, ih, placed):
		_apt_floor.place_wall_item(_edge, at, fid)
	else:
		_apt_floor.place_wall_item(_edge, _drag_origin, fid)


func _drop_floor_drag() -> void:
	_is_dragging = false
	var f := _drag_floor_furniture
	_drag_floor_furniture = null
	if not f:
		return
	var item_w: int = (f.grid_w if _edge in ["north", "south"] else f.grid_h)
	var wall_w: int = _wall_w()
	var new_wall_x: int = clampi(_drag_pos.x, 0, wall_w - item_w)
	var new_pos := f.grid_pos
	match _edge:
		"north", "south":
			new_pos.x = new_wall_x
		"west", "east":
			new_pos.y = new_wall_x
	if _apt_floor.can_place(f, new_pos):
		_apt_floor.place_furniture(f, new_pos)


func _wall_fits(at: Vector2i, iw: int, ih: int, placed: Dictionary) -> bool:
	var item_rect := Rect2i(at.x, at.y, iw, ih)

	# Restricted zones: windows and doors block all wall item placement in their columns
	for zone in _get_restricted_zones():
		if (zone as Rect2i).intersects(item_rect):
			return false

	# Floor occlusion: can't place behind adjacent furniture silhouette
	if _floor_occludes(at, iw, ih):
		return false

	# Existing wall items
	for tx in range(iw):
		for ty in range(ih):
			var check := Vector2i(at.x + tx, at.y + ty)
			for origin in placed:
				var o  := origin as Vector2i
				var pf := _find(placed[origin] as String)
				if pf.is_empty():
					continue
				var pw: int = pf["size"]["w"] as int
				var ph: int = pf.get("wall_h", 1) as int
				if check.x >= o.x and check.x < o.x + pw \
				and check.y >= o.y and check.y < o.y + ph:
					return false
	return true


func _get_restricted_zones() -> Array:
	var zones: Array = []
	var wd := _get_wall_def()
	if wd.is_empty():
		return zones
	if wd.get("has_window", false):
		var wx  := wd.get("window_x",   5) as int
		var wlen := wd.get("window_len", 15) as int
		zones.append(Rect2i(wx, 0, wlen, WALL_HEIGHT))
	if wd.get("has_door", false):
		var dx := wd.get("door_x", 0) as int
		zones.append(Rect2i(dx, 0, 10, WALL_HEIGHT))
	return zones


func _floor_occludes(at: Vector2i, iw: int, ih: int) -> bool:
	var item_rect := Rect2i(at.x, at.y, iw, ih)
	for entry in _apt_floor.get_adjacent_furniture(_edge):
		var f: Furniture    = entry["furniture"]
		var wx: int         = entry["wall_x"] as int
		var fdata           := _find_by_id(f.furniture_id)
		if fdata.is_empty():
			continue
		var item_w: int = (f.grid_w if _edge in ["north", "south"] else f.grid_h)
		var wall_h: int = fdata.get("wall_h", 5) as int
		var py_tile: int = WALL_HEIGHT - wall_h
		var sil := Rect2i(wx, py_tile, item_w, wall_h)
		if sil.intersects(item_rect):
			return true
	return false


func _remove_wall_at(tile: Vector2i) -> void:
	var placed := _apt_floor.get_wall_items(_edge)
	for origin in placed.keys():
		var o  := origin as Vector2i
		var pf := _find(placed[origin] as String)
		if pf.is_empty():
			continue
		var pw: int = pf["size"]["w"] as int
		var ph: int = pf.get("wall_h", 1) as int
		if tile.x >= o.x and tile.x < o.x + pw \
		and tile.y >= o.y and tile.y < o.y + ph:
			_apt_floor.remove_wall_item(_edge, origin)
			return


# ── Rendering ─────────────────────────────────────────────────────────────────

func _draw_elevation() -> void:
	if not _apt_floor:
		return
	var wall_w: int = _wall_w()
	var rw := wall_w * TILE_SIZE
	var rh := WALL_HEIGHT * TILE_SIZE

	# Wall surface + grid — blueprint palette to match floor plan
	draw_area.draw_rect(Rect2(0, 0, rw, rh), Color(0.93, 0.90, 0.83))
	for x in range(wall_w + 1):
		draw_area.draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, rh),
			Color(0.55, 0.52, 0.44, 0.22), 0.5)
	for y in range(WALL_HEIGHT + 1):
		draw_area.draw_line(Vector2(0, y * TILE_SIZE), Vector2(rw, y * TILE_SIZE),
			Color(0.55, 0.52, 0.44, 0.22), 0.5)
	for x in range(0, wall_w + 1, 10):
		draw_area.draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, rh),
			Color(0.45, 0.42, 0.34, 0.50), 1.0)
	for y in range(0, WALL_HEIGHT + 1, 10):
		draw_area.draw_line(Vector2(0, y * TILE_SIZE), Vector2(rw, y * TILE_SIZE),
			Color(0.45, 0.42, 0.34, 0.50), 1.0)
	draw_area.draw_line(Vector2(0, rh), Vector2(rw, rh), Color(0.16, 0.13, 0.10), 4.0)
	draw_area.draw_line(Vector2(0, 0),  Vector2(rw, 0),  Color(0.16, 0.13, 0.10), 2.0)

	_draw_openings(rw, rh)

	# ── Restricted zones overlay (windows / doors) ────────────────────────────
	for zone in _get_restricted_zones():
		var z  := zone as Rect2i
		var zr := Rect2(z.position.x * TILE_SIZE, z.position.y * TILE_SIZE,
						z.size.x * TILE_SIZE, z.size.y * TILE_SIZE)
		draw_area.draw_rect(zr, Color(1.0, 0.30, 0.20, 0.07))
		draw_area.draw_rect(zr, Color(1.0, 0.30, 0.20, 0.30), false, 1.0)

	# ── Floor-adjacent pieces ─────────────────────────────────────────────────
	for entry in _apt_floor.get_adjacent_furniture(_edge):
		var f: Furniture = entry["furniture"]
		var wx: int      = entry["wall_x"] as int
		var fdata        := _find_by_id(f.furniture_id)
		if fdata.is_empty():
			continue
		var item_w: int = (f.grid_w if _edge in ["north", "south"] else f.grid_h)
		var wall_h: int = fdata.get("wall_h", 5) as int
		var col         := Color("#" + (fdata.get("color", "888888") as String))
		var is_dragged  := _is_dragging and _drag_is_floor and _drag_floor_furniture == f
		if is_dragged:
			col.a = 0.28
		var px := wx * TILE_SIZE
		var pw := item_w * TILE_SIZE
		var ph := wall_h * TILE_SIZE
		var py := rh - ph
		draw_area.draw_rect(Rect2(px + 1, py, pw - 2, ph), col)
		draw_area.draw_rect(Rect2(px + 1, py, pw - 2, ph), Color(0, 0, 0, 0.30), false, 1.0)
		if not is_dragged:
			_draw_label(px + 3, py + 10, float(pw - 6), f.furniture_name)

	# ── Mezzanine slab ───────────────────────────────────────────────────────
	# Show mezzanine tiles adjacent to this wall as an amber platform slab.
	# Mezzanine floor sits at 14 tiles from floor bottom (≈ 2.1 m headroom below).
	const MEZZ_LEVEL := 10   # tiles from top of elevation view
	var mezz_y   := MEZZ_LEVEL * TILE_SIZE
	var mezz_col := Color(0.82, 0.70, 0.35, 0.90)
	var mezz_fg  := Color(0.50, 0.38, 0.10, 0.90)
	# Determine which wall-axis coords have adjacent mezzanine tiles
	var wall_coords: Array = []
	for tile in _apt_floor.mezzanine_mask:
		var t := tile as Vector2i
		var wc := -1
		match _edge:
			"north": if t.y == 0:            wc = t.x
			"south": if t.y == _apt_floor.grid_h - 1: wc = t.x
			"west":  if t.x == 0:            wc = t.y
			"east":  if t.x == _apt_floor.grid_w - 1: wc = t.y
		if wc >= 0:
			wall_coords.append(wc)
	# Draw slab for each contiguous run of mezzanine tiles along this wall
	if not wall_coords.is_empty():
		wall_coords.sort()
		var run_s := wall_coords[0] as int
		var run_e := run_s + 1
		for i in range(1, wall_coords.size()):
			var wc := wall_coords[i] as int
			if wc == run_e:
				run_e += 1
			else:
				var sx := run_s * TILE_SIZE; var sw := (run_e - run_s) * TILE_SIZE
				draw_area.draw_rect(Rect2(sx, mezz_y, sw, 3), mezz_col)
				draw_area.draw_rect(Rect2(sx, 0, sw, mezz_y), Color(0.85, 0.78, 0.55, 0.10))
				draw_area.draw_line(Vector2(sx, mezz_y), Vector2(sx + sw, mezz_y), mezz_fg, 2.0)
				draw_area.draw_string(ThemeDB.fallback_font, Vector2(sx + 2, mezz_y - 3),
					"MEZZ", HORIZONTAL_ALIGNMENT_LEFT, sw - 4, 7, mezz_fg)
				run_s = wc; run_e = wc + 1
		var sx := run_s * TILE_SIZE; var sw := (run_e - run_s) * TILE_SIZE
		draw_area.draw_rect(Rect2(sx, mezz_y, sw, 3), mezz_col)
		draw_area.draw_rect(Rect2(sx, 0, sw, mezz_y), Color(0.85, 0.78, 0.55, 0.10))
		draw_area.draw_line(Vector2(sx, mezz_y), Vector2(sx + sw, mezz_y), mezz_fg, 2.0)
		draw_area.draw_string(ThemeDB.fallback_font, Vector2(sx + 2, mezz_y - 3),
			"MEZZ", HORIZONTAL_ALIGNMENT_LEFT, sw - 4, 7, mezz_fg)

	# ── Hung wall items ───────────────────────────────────────────────────────
	var placed := _apt_floor.get_wall_items(_edge)
	for origin in placed:
		var o   := origin as Vector2i
		if not _drag_is_floor and _is_dragging and o == _drag_origin:
			continue   # shown as ghost
		var fid   : String = placed[origin] as String
		var fdata  := _find(fid)
		if fdata.is_empty():
			continue
		var iw: int = fdata["size"]["w"] as int
		var ih: int = fdata.get("wall_h", 3) as int
		var col     := Color("#" + (fdata.get("color", "aaaaaa") as String))
		var px := o.x * TILE_SIZE
		var py := o.y * TILE_SIZE
		var pw := iw * TILE_SIZE
		var ph := ih * TILE_SIZE
		draw_area.draw_rect(Rect2(px + 1, py + 1, pw - 2, ph - 2), col)
		draw_area.draw_rect(Rect2(px + 1, py + 1, pw - 2, ph - 2), Color(0, 0, 0, 0.45), false, 1.0)
		_draw_label(px + 3, py + 11, float(pw - 6), fdata["name"] as String)
		var depth_px: int = (fdata.get("floor_depth", 1) as int) * TILE_SIZE
		draw_area.draw_rect(Rect2(px + 1, rh - depth_px, pw - 2, depth_px),
			Color(col.r, col.g, col.b, 0.18))

	# ── Wall item drag ghost ──────────────────────────────────────────────────
	if _is_dragging and not _drag_is_floor and (_drag_origin in placed):
		var fid   : String = placed[_drag_origin] as String
		var fdata  := _find(fid)
		if not fdata.is_empty():
			var iw: int      = fdata["size"]["w"] as int
			var ih: int      = fdata.get("wall_h", 1) as int
			var wall_w2: int = _wall_w()
			var at := Vector2i(
				clampi(_drag_pos.x, 0, wall_w2 - iw),
				clampi(_drag_pos.y, 0, WALL_HEIGHT - ih)
			)
			var col := Color("#" + (fdata.get("color", "888888") as String))
			col.a = 0.60
			draw_area.draw_rect(Rect2(at.x * TILE_SIZE + 1, at.y * TILE_SIZE + 1,
				iw * TILE_SIZE - 2, ih * TILE_SIZE - 2), col)
			draw_area.draw_rect(Rect2(at.x * TILE_SIZE + 1, at.y * TILE_SIZE + 1,
				iw * TILE_SIZE - 2, ih * TILE_SIZE - 2), Color.WHITE, false, 1.5)

	# ── Floor item drag ghost ─────────────────────────────────────────────────
	if _is_dragging and _drag_is_floor and _drag_floor_furniture:
		var f      := _drag_floor_furniture
		var fdata  := _find_by_id(f.furniture_id)
		if not fdata.is_empty():
			var item_w: int  = (f.grid_w if _edge in ["north", "south"] else f.grid_h)
			var wall_h: int  = fdata.get("wall_h", 5) as int
			var wall_w2: int = _wall_w()
			var ghost_x: int = clampi(_drag_pos.x, 0, wall_w2 - item_w)
			var col          := Color("#" + (fdata.get("color", "888888") as String))
			col.a = 0.55
			var px := ghost_x * TILE_SIZE
			var pw := item_w * TILE_SIZE
			var ph := wall_h * TILE_SIZE
			var py := rh - ph
			draw_area.draw_rect(Rect2(px + 1, py, pw - 2, ph), col)
			draw_area.draw_rect(Rect2(px + 1, py, pw - 2, ph), Color.WHITE, false, 1.5)

	# ── Shop selection ghost ──────────────────────────────────────────────────
	if _selected_id != "":
		var fdata := _find(_selected_id)
		if not fdata.is_empty():
			var iw: int = (fdata["size"]["w"] as int) * TILE_SIZE
			var ih: int = (fdata.get("wall_h", 1) as int) * TILE_SIZE
			var ghost   := Color("#" + (fdata.get("color", "888888") as String))
			ghost.a = 0.35
			draw_area.draw_rect(Rect2(2, 2, iw - 4, ih - 4), ghost)
			_draw_label(4, 13, float(iw - 6), "click wall to place")


func _draw_openings(_rw: int, rh: int) -> void:
	var wd := _get_wall_def()
	if wd.is_empty():
		return

	if wd.get("has_window", false):
		var wx: int   = (wd.get("window_x",   5) as int) * TILE_SIZE
		var wlen: int = (wd.get("window_len", 15) as int) * TILE_SIZE
		var sill: int = 8  * TILE_SIZE
		var wh: int   = 12 * TILE_SIZE
		var wy: int   = rh - sill - wh
		draw_area.draw_rect(Rect2(wx, wy, wlen, wh), Color(0.55, 0.80, 0.95))
		draw_area.draw_rect(Rect2(wx - 2, wy + wh, wlen + 4, 3), Color(0.85, 0.80, 0.72))
		draw_area.draw_rect(Rect2(wx, wy, wlen, wh), Color(0.92, 0.90, 0.85), false, 3.0)
		draw_area.draw_line(Vector2(wx + wlen * 0.5, wy), Vector2(wx + wlen * 0.5, wy + wh),
			Color(0.92, 0.90, 0.85), 2.0)
		draw_area.draw_line(Vector2(wx, wy + wh * 0.5), Vector2(wx + wlen, wy + wh * 0.5),
			Color(0.92, 0.90, 0.85), 2.0)

	if wd.get("has_door", false):
		var dx: int = (wd.get("door_x", 0) as int) * TILE_SIZE
		var dw: int = 10 * TILE_SIZE
		var dh: int = 21 * TILE_SIZE
		var dy: int = rh - dh
		draw_area.draw_rect(Rect2(dx, dy, dw, dh), Color(0.12, 0.08, 0.05))
		draw_area.draw_rect(Rect2(dx + 3, dy + 3, dw - 6, dh - 3), Color(0.62, 0.43, 0.22))
		draw_area.draw_rect(Rect2(dx, dy, dw, dh), Color(0.35, 0.22, 0.10), false, 3.0)
		draw_area.draw_rect(Rect2(dx + 7, dy + 8, dw - 14, dh / 2.0 - 12),
			Color(0, 0, 0, 0.15), false, 1.0)
		draw_area.draw_rect(Rect2(dx + 7, dy + dh / 2.0 + 4, dw - 14, dh / 2.0 - 16),
			Color(0, 0, 0, 0.15), false, 1.0)
		draw_area.draw_circle(Vector2(dx + dw - 8, dy + dh * 0.55), 3.0,
			Color(0.85, 0.72, 0.20))


func _get_wall_def() -> Dictionary:
	if not _apt_floor:
		return {}
	for wd in _apt_floor.wall_definitions:
		if wd.get("edge", "") == _edge:
			return wd
	return {}


func _draw_label(x: float, y: float, max_w: float, text: String) -> void:
	draw_area.draw_string(ThemeDB.fallback_font, Vector2(x, y), text,
		HORIZONTAL_ALIGNMENT_LEFT, int(max_w), 9, Color(0.16, 0.13, 0.10, 0.90))


# ── Helpers ───────────────────────────────────────────────────────────────────

func _wall_w() -> int:
	if not _apt_floor:
		return 8
	return _apt_floor.grid_w if _edge in ["north", "south"] else _apt_floor.grid_h


func _edge_label(edge: String) -> String:
	match edge:
		"north": return "North" + (" (windows)" if _has_feature(edge, "has_window") else "")
		"south": return "South" + (" (entrance)" if _has_feature(edge, "has_door") else "")
		"east":  return "East"
		"west":  return "West"
	return edge


func _has_feature(edge: String, feature: String) -> bool:
	if not _apt_floor:
		return false
	for wd in _apt_floor.wall_definitions:
		if wd.get("edge", "") == edge and wd.get(feature, false):
			return true
	return false


func _find(fid: String) -> Dictionary:
	for f in _wall_furniture:
		if f["id"] == fid:
			return f
	return {}


func _find_by_id(fid: String) -> Dictionary:
	for f in _all_furniture:
		if f["id"] == fid:
			return f
	return {}
