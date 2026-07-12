extends PanelContainer
class_name WallInspector

signal wall_closed
signal wall_item_placed(furniture_id: String)

const TILE_SIZE:   int = 12
const WALL_HEIGHT: int = 24

const MIN_ZOOM := 0.5
const MAX_ZOOM := 3.0
var _zoom: float = 1.0
var _panning: bool = false

var _all_furniture: Array  = []
var _wall_furniture: Array = []
var _selected_id: String   = ""

var _edge: String     = ""
var _apt_floor: Floor = null
var _other_floor: Floor = null  # sibling base/loft floor — shown as read-only context

# Multi-room support: when the clicked cardinal edge is crossed by an interior
# partition wall, Main passes the specific sub-span (absolute tile coords) for
# just the room that was actually clicked. `_span_lo`/`_span_hi` (-1 = no
# split, whole edge) are that span; `_span_offset_local` is where the span's
# own local-0 falls in the FULL edge's local coordinate space (the space
# get_adjacent_furniture()/wall_items storage already use) and `_span_width`
# is the span's width in that same space — every existing _wall_w()-based
# calculation stays untouched, this inspector's whole coordinate frame just
# shifts to start at the span instead of the full edge.
var _span_lo: int = -1
var _span_hi: int = -1
var _span_offset_local: int = 0
var _span_width: int = -1

# Drag shared
var _is_dragging:   bool     = false
var _drag_is_floor: bool     = false
var _drag_pos:      Vector2i = Vector2i.ZERO

# Wall item drag
var _drag_origin: Vector2i = Vector2i.ZERO
var _drag_offset: Vector2i = Vector2i.ZERO
var _drag_fid:     String   = ""

# Floor item drag
var _drag_floor_furniture: Furniture = null
var _drag_floor_wall_x:    int       = 0
var _drag_floor_offset_x:  int       = 0

var _hover_tile: Vector2i = Vector2i(-999, -999)   # live cursor tile, for the shop-selection ghost

@onready var title_lbl:  Label         = $VBox/TitleRow/Title
@onready var close_btn:  Button        = $VBox/TitleRow/CloseBtn
@onready var hint_lbl:   Label         = $VBox/HintLabel
@onready var scroll_area: ScrollContainer = $VBox/Scroll
@onready var draw_area:  Control       = $VBox/Scroll/DrawArea


func setup(all_furniture: Array) -> void:
	_all_furniture  = all_furniture
	_wall_furniture = all_furniture   # any item can now be hung on a wall
	close_btn.pressed.connect(_on_close)
	draw_area.draw.connect(_draw_elevation)
	draw_area.gui_input.connect(_on_draw_input)
	draw_area.mouse_filter = Control.MOUSE_FILTER_STOP
	scroll_area.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll_area.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll_area.resized.connect(_on_scroll_area_resized)
	_show_placeholder()


# Keeps the wall fully visible without scrollbars — re-fit whenever the panel
# is resized (split divider drag, window resize), instead of ever scrolling.
func _on_scroll_area_resized() -> void:
	if _apt_floor:
		refit()


func refit() -> void:
	var content_w := _wall_w() * TILE_SIZE
	var content_h := WALL_HEIGHT * TILE_SIZE
	var avail := scroll_area.size
	if avail.x <= 0 or avail.y <= 0 or content_w <= 0 or content_h <= 0:
		return
	_zoom = clampf(minf(avail.x / content_w, avail.y / content_h), 0.1, MAX_ZOOM)
	draw_area.custom_minimum_size = Vector2(content_w * _zoom, content_h * _zoom)
	draw_area.queue_redraw()


func _show_placeholder() -> void:
	hint_lbl.visible   = true
	draw_area.visible  = false
	title_lbl.text     = "Wall Inspector"


# True only while an actual wall is open for inspection — unlike `visible`,
# which stays true even for the idle placeholder panel.
func is_showing_wall() -> bool:
	return _apt_floor != null


func show_wall(apt_floor: Floor, edge: String, other_floor: Floor = null,
		span_lo: int = -1, span_hi: int = -1) -> void:
	show()
	if _apt_floor and _apt_floor.furniture_changed.is_connected(_on_floor_changed):
		_apt_floor.furniture_changed.disconnect(_on_floor_changed)
	if _other_floor and _other_floor.furniture_changed.is_connected(_on_floor_changed):
		_other_floor.furniture_changed.disconnect(_on_floor_changed)

	_apt_floor   = apt_floor
	_other_floor = other_floor
	_edge        = edge
	_selected_id = ""
	_is_dragging = false
	_drag_floor_furniture = null
	_panning = false

	_span_lo = span_lo
	_span_hi = span_hi
	_span_offset_local = 0
	_span_width = -1
	if span_lo >= 0 and _apt_floor:
		var a := _abs_to_local(span_lo)
		var b := _abs_to_local(span_hi)
		_span_offset_local = mini(a, b)
		_span_width = maxi(a, b) - mini(a, b)

	_apt_floor.furniture_changed.connect(_on_floor_changed)
	if _other_floor:
		_other_floor.furniture_changed.connect(_on_floor_changed)

	title_lbl.text = "Wall: " + _edge_label(edge) + "  (scroll to zoom, middle-drag to pan)"
	hint_lbl.visible  = false
	draw_area.visible = true
	call_deferred("refit")
	draw_area.queue_redraw()


# Converts an ABSOLUTE tile coordinate along this wall's own axis into the
# same "local wall_x" coordinate space get_adjacent_furniture()/wall_items
# storage already use (0 at the FULL edge's own start, not this inspector's
# possibly-narrower span) — the one shared reference frame every span
# calculation below is expressed in.
func _abs_to_local(along_abs: int) -> int:
	if not _apt_floor:
		return along_abs
	var bounds := _apt_floor.get_room_bounds()
	match _edge:
		"north", "south":
			return along_abs - bounds.position.x - 1
		"east":
			return along_abs - bounds.position.y - 1
		"west":
			return bounds.size.y - (along_abs - bounds.position.y)
	return along_abs


# Inverse of _abs_to_local — used to turn a span-local drag/placement back
# into a true absolute tile coordinate for Floor.gd's own APIs (floor-piece
# drag ghosts, sloped-ceiling column lookups) that don't know about spans.
func _local_to_abs(local_x: int) -> int:
	if not _apt_floor:
		return local_x
	var bounds := _apt_floor.get_room_bounds()
	match _edge:
		"north", "south":
			return local_x + bounds.position.x + 1
		"east":
			return local_x + bounds.position.y + 1
		"west":
			return bounds.position.y + bounds.size.y - local_x
	return local_x


# Wall-hung items are stored keyed only by edge, with origins in the FULL
# edge's local space (0 at the whole perimeter wall's start) — untouched by
# spans, so two rooms sharing one cardinal wall can never collide on the same
# origin. This filters that raw dict down to just the items whose footprint
# falls inside THIS span, re-expressed in span-local coordinates (0 at this
# span's own start) so every existing render/hit-test call site below keeps
# working exactly as it did before spans existed.
func _visible_wall_items() -> Dictionary:
	var raw := _apt_floor.get_wall_items(_edge)
	if _span_width < 0:
		return raw
	var out := {}
	for origin in raw:
		var o := origin as Vector2i
		var fid: String = raw[origin] as String
		var fdata := _find(fid)
		var iw: int = (fdata["size"]["w"] as int) if not fdata.is_empty() else 1
		if o.x + iw <= _span_offset_local or o.x >= _span_offset_local + _wall_w():
			continue
		out[Vector2i(o.x - _span_offset_local, o.y)] = fid
	return out


# Called by Main when the player clicks "Buy" on a wall item in the inventory panel.
func select_item(fid: String) -> void:
	if not visible or not _apt_floor:
		return
	_selected_id = fid if _selected_id != fid else ""
	draw_area.queue_redraw()


# Called by Main when the player completes the equivalent floor placement instead,
# so the armed wall-click-to-place doesn't linger waiting for a second click.
func cancel_selection() -> void:
	if _selected_id == "":
		return
	_selected_id = ""
	draw_area.queue_redraw()


func _on_floor_changed() -> void:
	draw_area.queue_redraw()


func _on_close() -> void:
	if _apt_floor:
		_apt_floor.clear_wall_drag_ghost()
		_apt_floor.clear_floor_drag_ghost()
	if _apt_floor and _apt_floor.furniture_changed.is_connected(_on_floor_changed):
		_apt_floor.furniture_changed.disconnect(_on_floor_changed)
	if _other_floor and _other_floor.furniture_changed.is_connected(_on_floor_changed):
		_other_floor.furniture_changed.disconnect(_on_floor_changed)
	_apt_floor            = null
	_other_floor          = null
	_edge                 = ""
	_selected_id          = ""
	_is_dragging          = false
	_drag_floor_furniture = null
	_show_placeholder()
	hide()
	wall_closed.emit()


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_draw_input(event: InputEvent) -> void:
	if not _apt_floor:
		return

	if event is InputEventMouseButton:
		var mbe  := event as InputEventMouseButton

		if mbe.button_index == MOUSE_BUTTON_WHEEL_UP and mbe.pressed:
			_set_zoom(_zoom + 0.2)
			get_viewport().set_input_as_handled()
			return
		if mbe.button_index == MOUSE_BUTTON_WHEEL_DOWN and mbe.pressed:
			_set_zoom(_zoom - 0.2)
			get_viewport().set_input_as_handled()
			return
		if mbe.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mbe.pressed
			get_viewport().set_input_as_handled()
			return

		var tile := _pixel_to_tile(mbe.position)

		if mbe.button_index == MOUSE_BUTTON_LEFT:
			if mbe.pressed:
				var wall_hit: Variant = _wall_item_at(tile)
				if wall_hit != null:
					_drag_origin  = wall_hit as Vector2i
					_drag_offset  = tile - _drag_origin
					_drag_pos     = _drag_origin
					_is_dragging   = true
					_drag_is_floor = false
					_selected_id   = ""
					_drag_fid      = _apt_floor.get_wall_items(_edge).get(_drag_origin, "") as String
					_apt_floor.set_wall_drag_ghost(_edge, _drag_pos, _drag_fid)
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
						_push_floor_drag_ghost()
					elif _selected_id != "":
						_try_place(_selected_id, tile)
			else:
				if _is_dragging:
					if _drag_is_floor:
						_drop_floor_drag()
					else:
						_drop_wall_drag()
				_apt_floor.clear_wall_drag_ghost()
				_apt_floor.clear_floor_drag_ghost()

		elif mbe.button_index == MOUSE_BUTTON_RIGHT and mbe.pressed:
			if _is_dragging:
				_is_dragging          = false
				_drag_floor_furniture = null
				_apt_floor.clear_wall_drag_ghost()
				_apt_floor.clear_floor_drag_ghost()
				draw_area.queue_redraw()
			else:
				_remove_wall_at(tile)

	elif event is InputEventMouseMotion and _panning:
		var mme := event as InputEventMouseMotion
		scroll_area.scroll_horizontal -= int(mme.relative.x)
		scroll_area.scroll_vertical   -= int(mme.relative.y)

	elif event is InputEventMouseMotion and _is_dragging:
		var mme := event as InputEventMouseMotion
		var cur := _pixel_to_tile(mme.position)
		if _drag_is_floor:
			_drag_pos.x = cur.x - _drag_floor_offset_x
			_push_floor_drag_ghost()
		else:
			_drag_pos = cur - _drag_offset
			_apt_floor.set_wall_drag_ghost(_edge, _drag_pos, _drag_fid)
		draw_area.queue_redraw()

	elif event is InputEventMouseMotion:
		_hover_tile = _pixel_to_tile((event as InputEventMouseMotion).position)
		if _selected_id != "":
			draw_area.queue_redraw()


# Converts the wall-local drag position of a floor-adjacent piece back into
# absolute grid coordinates so the floor plan can mirror the live drag.
func _push_floor_drag_ghost() -> void:
	var f := _drag_floor_furniture
	if not f:
		return
	var bounds := _apt_floor.get_room_bounds()
	var gx := f.grid_pos.x
	var gy := f.grid_pos.y
	# When this inspector is showing a sub-span (multi-room floor), _drag_pos
	# is span-local — anchor the conversion back to absolute coords on the
	# span's own bounds instead of the whole edge's, same as everywhere else.
	var lo_x := _span_lo if _span_lo >= 0 else bounds.position.x
	var lo_y := _span_lo if _span_lo >= 0 else bounds.position.y
	var hi_y := _span_hi if _span_hi >= 0 else bounds.position.y + bounds.size.y
	match _edge:
		"north", "south":
			gx = _drag_pos.x + lo_x
		"west":
			gy = hi_y - _drag_pos.x - f.grid_h
		"east":
			gy = _drag_pos.x + lo_y
	_apt_floor.set_floor_drag_ghost(f, gx, gy)


func _pixel_to_tile(px: Vector2) -> Vector2i:
	var unzoomed := px / _zoom
	return Vector2i(int(unzoomed.x / TILE_SIZE), int(unzoomed.y / TILE_SIZE))


func _set_zoom(new_zoom: float) -> void:
	var clamped := clampf(new_zoom, MIN_ZOOM, MAX_ZOOM)
	if clamped == _zoom:
		return
	_zoom = clamped
	draw_area.custom_minimum_size = Vector2(_wall_w() * TILE_SIZE * _zoom, WALL_HEIGHT * TILE_SIZE * _zoom)
	draw_area.queue_redraw()


# ── Placement helpers ─────────────────────────────────────────────────────────

func _wall_item_at(tile: Vector2i) -> Variant:
	var placed := _visible_wall_items()
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
	for entry in _apt_floor.get_adjacent_furniture(_edge, Vector2i(_span_lo, _span_hi)):
		var f: Furniture = entry["furniture"]
		var wx: int      = (entry["wall_x"] as int) - _span_offset_local
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


# Floor-standing furniture (beds, desks, wardrobes...) leans flush against the
# floor when hung on a wall — only true wall-mounted decor (shelves, paintings)
# can be hung at an arbitrary height.
func _pinned_wall_y(fdata: Dictionary, ih: int) -> int:
	if fdata.get("placement", "") == "floor":
		return WALL_HEIGHT - ih
	return -1   # not pinned — caller keeps the clicked/dragged y


func _try_place(fid: String, at: Vector2i) -> void:
	var f := _find(fid)
	if f.is_empty():
		return
	var iw: int     = f["size"]["w"] as int
	var ih: int     = f.get("wall_h", 1) as int
	var wall_w: int = _wall_w()
	at.x = clampi(at.x, 0, wall_w - iw)
	# Magnetize to the side walls — clicking near an end should mean "in that
	# corner", not "a few tiles short of it".
	if at.x <= Floor.WALL_SNAP:
		at.x = 0
	elif wall_w - iw - at.x <= Floor.WALL_SNAP:
		at.x = wall_w - iw
	var pinned_y := _pinned_wall_y(f, ih)
	at.y = pinned_y if pinned_y >= 0 else clampi(at.y, 0, WALL_HEIGHT - ih)
	var placed := _visible_wall_items()
	if _wall_fits(at, iw, ih, placed):
		Audio.play("place")
		_apt_floor.place_wall_item(_edge, Vector2i(at.x + _span_offset_local, at.y), fid)
		_selected_id = ""
		wall_item_placed.emit(fid)


func _drop_wall_drag() -> void:
	_is_dragging = false
	var placed := _visible_wall_items()
	if not (_drag_origin in placed):
		return
	var fid: String = placed[_drag_origin] as String
	var f := _find(fid)
	if f.is_empty():
		return
	var iw: int     = f["size"]["w"] as int
	var ih: int     = f.get("wall_h", 1) as int
	var wall_w: int = _wall_w()
	var pinned_y := _pinned_wall_y(f, ih)
	var at := Vector2i(
		clampi(_drag_pos.x, 0, wall_w - iw),
		pinned_y if pinned_y >= 0 else clampi(_drag_pos.y, 0, WALL_HEIGHT - ih)
	)
	var orig_full := Vector2i(_drag_origin.x + _span_offset_local, _drag_origin.y)
	_apt_floor.remove_wall_item(_edge, orig_full)
	placed.erase(_drag_origin)   # local copy, not a live reference — keep it in sync with the removal above
	if _wall_fits(at, iw, ih, placed):
		_apt_floor.place_wall_item(_edge, Vector2i(at.x + _span_offset_local, at.y), fid)
	else:
		_apt_floor.place_wall_item(_edge, orig_full, fid)


func _drop_floor_drag() -> void:
	_is_dragging = false
	var f := _drag_floor_furniture
	_drag_floor_furniture = null
	if not f:
		return
	var item_w: int = (f.grid_w if _edge in ["north", "south"] else f.grid_h)
	var wall_w: int = _wall_w()
	var new_wall_x: int = clampi(_drag_pos.x, 0, wall_w - item_w)
	# Magnetize to the side walls too, same tolerance as Wall.snap_to_wall —
	# otherwise a drag that ends a tile or two short of the corner looks fine
	# here (this view always pins to the floor) but shows a gap in that other
	# wall's own view.
	if new_wall_x <= Floor.WALL_SNAP:
		new_wall_x = 0
	elif wall_w - item_w - new_wall_x <= Floor.WALL_SNAP:
		new_wall_x = wall_w - item_w
	var bounds := _apt_floor.get_room_bounds()

	# Dragging a piece within THIS wall's view means "against this wall" —
	# pin the perpendicular distance flush too, not just the along-wall slide.
	# bounds.position itself is the wall's own tile (blocked), so touching the
	# west/north wall means sitting one tile in from it — that's the pinned
	# perpendicular distance below, always.
	#
	# _wall_w() is one tile narrower than the raw bounds span for the same
	# reason (see its own comment), so new_wall_x's two extremes line up with
	# the two ends of the wall as drawn. For "north"/"south"/"east" the
	# along-wall coordinate is built by adding new_wall_x directly onto
	# bounds.position, so shrinking the range by 1 shifts BOTH extremes one
	# tile short of their true target — each needs its own +1. "west" is
	# built from bounds.size instead, which already absorbs the shrink
	# correctly at both ends, so it needs no per-extreme patching.
	# A sub-span's along-wall coordinate anchors on the span's own absolute
	# bounds instead of the whole edge's, same as everywhere else this
	# inspector converts a span-local coordinate back to an absolute one.
	var lo_x := _span_lo if _span_lo >= 0 else bounds.position.x
	var lo_y := _span_lo if _span_lo >= 0 else bounds.position.y
	var hi_y := _span_hi if _span_hi >= 0 else bounds.position.y + bounds.size.y

	var flush := f.grid_pos
	match _edge:
		"north":
			flush.x = new_wall_x + lo_x
			if new_wall_x == 0 or new_wall_x == wall_w - item_w:
				flush.x += 1
			flush.y = bounds.position.y + 1
		"south":
			flush.x = new_wall_x + lo_x
			if new_wall_x == 0 or new_wall_x == wall_w - item_w:
				flush.x += 1
			flush.y = bounds.position.y + bounds.size.y - f.grid_h
		"west":
			flush.y = hi_y - new_wall_x - item_w
			flush.x = bounds.position.x + 1
		"east":
			flush.y = new_wall_x + lo_y
			if new_wall_x == 0 or new_wall_x == wall_w - item_w:
				flush.y += 1
			flush.x = bounds.position.x + bounds.size.x - f.grid_w

	if _apt_floor.can_place(f, flush):
		_apt_floor.place_furniture(f, flush)
		return

	# Flush pin blocked (e.g. another piece in the way) — fall back to sliding
	# along the wall only, keeping whatever perpendicular gap it already had.
	var slide := f.grid_pos
	match _edge:
		"north", "south":
			slide.x = new_wall_x + lo_x
		"west", "east":
			slide.y = flush.y
	if _apt_floor.can_place(f, slide):
		_apt_floor.place_furniture(f, slide)


func _wall_fits(at: Vector2i, iw: int, ih: int, placed: Dictionary) -> bool:
	var item_rect := Rect2i(at.x, at.y, iw, ih)

	# Restricted zones: windows and doors block all wall item placement in their columns
	for zone in _get_restricted_zones():
		if (zone as Rect2i).intersects(item_rect):
			return false

	# Sloped ceiling: reject if the item's top edge pokes into the cut zone
	if _apt_floor and not _apt_floor.sloped_ceiling.is_empty():
		for tx in range(iw):
			if at.y < _ceiling_cut_tiles(at.x + tx):
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
	for entry in _apt_floor.get_adjacent_furniture(_edge, Vector2i(_span_lo, _span_hi)):
		var f: Furniture    = entry["furniture"]
		var wx: int         = (entry["wall_x"] as int) - _span_offset_local
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
	var placed := _visible_wall_items()
	for origin in placed.keys():
		var o  := origin as Vector2i
		var pf := _find(placed[origin] as String)
		if pf.is_empty():
			continue
		var pw: int = pf["size"]["w"] as int
		var ph: int = pf.get("wall_h", 1) as int
		if tile.x >= o.x and tile.x < o.x + pw \
		and tile.y >= o.y and tile.y < o.y + ph:
			_apt_floor.remove_wall_item(_edge, Vector2i(o.x + _span_offset_local, o.y))
			return


# ── Rendering ─────────────────────────────────────────────────────────────────

func _draw_elevation() -> void:
	if not _apt_floor:
		return
	var wall_w: int = _wall_w()
	var rw := wall_w * TILE_SIZE
	var rh := WALL_HEIGHT * TILE_SIZE

	# All draw calls below use raw (unzoomed) tile-pixel coordinates; this
	# transform scales the whole render to match draw_area's zoomed size.
	draw_area.draw_set_transform(Vector2.ZERO, 0.0, Vector2(_zoom, _zoom))

	# Wall surface + grid — same cyanotype blueprint palette as the floor plan.
	# The fine 10 cm grid only earns its keep once each tile is a few pixels
	# wide on screen — at the fitted zoom of a wide wall it just muddies into
	# near-invisible noise (same adaptive threshold GridDraw's 2D plan uses),
	# so skip it below that point instead of drawing lines nobody can read.
	draw_area.draw_rect(Rect2(0, 0, rw, rh), GridDraw.BP_FLOOR)
	var px_per_tile := TILE_SIZE * _zoom
	if px_per_tile >= 5.0:
		for x in range(wall_w + 1):
			draw_area.draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, rh),
				GridDraw.BP_GRID_FINE, 0.5)
		for y in range(WALL_HEIGHT + 1):
			draw_area.draw_line(Vector2(0, y * TILE_SIZE), Vector2(rw, y * TILE_SIZE),
				GridDraw.BP_GRID_FINE, 0.5)
	for x in range(0, wall_w + 1, 10):
		draw_area.draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, rh),
			GridDraw.BP_GRID_MAJ, 1.0)
	for y in range(0, WALL_HEIGHT + 1, 10):
		draw_area.draw_line(Vector2(0, y * TILE_SIZE), Vector2(rw, y * TILE_SIZE),
			GridDraw.BP_GRID_MAJ, 1.0)
	draw_area.draw_line(Vector2(0, rh), Vector2(rw, rh), GridDraw.BP_INK, 4.0)
	draw_area.draw_line(Vector2(0, 0),  Vector2(rw, 0),  GridDraw.BP_INK, 2.0)

	# ── Sloped ceiling cut — grey out the unusable space above the real roofline
	if not _apt_floor.sloped_ceiling.is_empty():
		var roof_pts: PackedVector2Array = []
		for col in range(wall_w + 1):
			var cut_y := clampf(rh - _ceiling_height_m(col) * 10.0 * TILE_SIZE, 0.0, rh)
			roof_pts.append(Vector2(col * TILE_SIZE, cut_y))
		var blocked := roof_pts.duplicate()
		blocked.append(Vector2(rw, 0))
		blocked.append(Vector2(0, 0))
		draw_area.draw_colored_polygon(blocked, Color(0.02, 0.05, 0.11, 0.65))
		for i in range(roof_pts.size() - 1):
			draw_area.draw_line(roof_pts[i], roof_pts[i + 1], Color(0.80, 0.30, 0.18, 0.95), 2.0)

	_draw_openings(rw, rh)

	# ── Restricted zones overlay (windows / doors) ────────────────────────────
	for zone in _get_restricted_zones():
		var z  := zone as Rect2i
		var zr := Rect2(z.position.x * TILE_SIZE, z.position.y * TILE_SIZE,
						z.size.x * TILE_SIZE, z.size.y * TILE_SIZE)
		draw_area.draw_rect(zr, Color(1.0, 0.30, 0.20, 0.07))
		draw_area.draw_rect(zr, Color(1.0, 0.30, 0.20, 0.30), false, 1.0)

	# ── Mezzanine baseline — the loft's own "floor" height within this wall ────
	# Sits at 14 tiles from the real floor (≈1.4 m headroom below).
	const MEZZ_LEVEL := 10   # tiles from top of elevation view
	var mezz_y := MEZZ_LEVEL * TILE_SIZE

	# ── Floor-adjacent pieces (this floor, interactive) ───────────────────────
	for entry in _apt_floor.get_adjacent_furniture(_edge, Vector2i(_span_lo, _span_hi)):
		_draw_floor_piece(entry["furniture"], (entry["wall_x"] as float) - _span_offset_local, rh,
			_is_dragging and _drag_is_floor and _drag_floor_furniture == entry["furniture"])

	# ── Sibling floor pieces (base ↔ loft, read-only context) ─────────────────
	if _other_floor:
		var other_baseline := mezz_y if _other_floor.floor_type == "loft" else rh
		for entry in _other_floor.get_adjacent_furniture(_edge, Vector2i(_span_lo, _span_hi)):
			_draw_floor_piece(entry["furniture"], (entry["wall_x"] as float) - _span_offset_local,
				other_baseline, false, true)

	# ── Mezzanine slab ───────────────────────────────────────────────────────
	# Show mezzanine tiles adjacent to this wall as an amber platform slab.
	var mezz_col := Color(0.82, 0.70, 0.35, 0.90)
	var mezz_fg  := Color(0.50, 0.38, 0.10, 0.90)
	# Determine which wall-axis coords have adjacent mezzanine tiles
	var bounds := _apt_floor.get_room_bounds()
	var wall_coords_set: Dictionary = {}
	for tile in _apt_floor.mezzanine_mask:
		var t := tile as Vector2i
		var wc := -1
		match _edge:
			"north": if t.y < bounds.position.y + Floor.WALL_DEPTH:                          wc = t.x
			"south": if t.y >= bounds.position.y + bounds.size.y - Floor.WALL_DEPTH:           wc = t.x
			"west":  if t.x < bounds.position.x + Floor.WALL_DEPTH:                           wc = t.y
			"east":  if t.x >= bounds.position.x + bounds.size.x - Floor.WALL_DEPTH:           wc = t.y
		if wc >= 0 and _span_lo >= 0 and (wc < _span_lo or wc >= _span_hi):
			wc = -1   # outside this room's own span of the shared edge
		if wc >= 0:
			wc = _abs_to_local(wc) - _span_offset_local
			wall_coords_set[wc] = true
	var wall_coords: Array = wall_coords_set.keys()
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
		var last_sx := run_s * TILE_SIZE; var last_sw := (run_e - run_s) * TILE_SIZE
		draw_area.draw_rect(Rect2(last_sx, mezz_y, last_sw, 3), mezz_col)
		draw_area.draw_rect(Rect2(last_sx, 0, last_sw, mezz_y), Color(0.85, 0.78, 0.55, 0.10))
		draw_area.draw_line(Vector2(last_sx, mezz_y), Vector2(last_sx + last_sw, mezz_y), mezz_fg, 2.0)
		draw_area.draw_string(ThemeDB.fallback_font, Vector2(last_sx + 2, mezz_y - 3),
			"MEZZ", HORIZONTAL_ALIGNMENT_LEFT, last_sw - 4, 7, mezz_fg)

	# ── Hung wall items ───────────────────────────────────────────────────────
	var placed := _visible_wall_items()
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
		var col     := Color("#" + (fdata.get("color", "888888") as String))
		col.a = 0.55
		var px := o.x * TILE_SIZE
		var py := o.y * TILE_SIZE
		var pw := iw * TILE_SIZE
		var ph := ih * TILE_SIZE
		draw_area.draw_rect(Rect2(px, py, pw, ph), col)
		draw_area.draw_rect(Rect2(px, py, pw, ph), GridDraw.BP_INK, false, 1.5)
		_draw_label(px + 3, py + 11, float(pw - 6), fdata["name"] as String)
		var depth_px: int = (fdata.get("floor_depth", 1) as int) * TILE_SIZE
		draw_area.draw_rect(Rect2(px, rh - depth_px, pw, depth_px),
			Color(col.r, col.g, col.b, 0.25))

	# ── Wall item drag ghost ──────────────────────────────────────────────────
	if _is_dragging and not _drag_is_floor and (_drag_origin in placed):
		var fid   : String = placed[_drag_origin] as String
		var fdata  := _find(fid)
		if not fdata.is_empty():
			var iw: int      = fdata["size"]["w"] as int
			var ih: int      = fdata.get("wall_h", 1) as int
			var wall_w2: int = _wall_w()
			var pinned_y2 := _pinned_wall_y(fdata, ih)
			var at := Vector2i(
				clampi(_drag_pos.x, 0, wall_w2 - iw),
				pinned_y2 if pinned_y2 >= 0 else clampi(_drag_pos.y, 0, WALL_HEIGHT - ih)
			)
			var col := Color("#" + (fdata.get("color", "888888") as String))
			col.a = 0.60
			draw_area.draw_rect(Rect2(at.x * TILE_SIZE, at.y * TILE_SIZE,
				iw * TILE_SIZE, ih * TILE_SIZE), col)
			draw_area.draw_rect(Rect2(at.x * TILE_SIZE, at.y * TILE_SIZE,
				iw * TILE_SIZE, ih * TILE_SIZE), Color.WHITE, false, 1.5)

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
			draw_area.draw_rect(Rect2(px, py, pw, ph), col)
			draw_area.draw_rect(Rect2(px, py, pw, ph), Color.WHITE, false, 1.5)

	# ── Shop selection ghost — follows the cursor so you can see the item before
	# committing, flush against the floor for floor-standing furniture ─────────
	if _selected_id != "" and not _is_dragging:
		var fdata := _find(_selected_id)
		if not fdata.is_empty():
			var iw_t: int   = fdata["size"]["w"] as int
			var ih_t: int   = fdata.get("wall_h", 1) as int
			var wall_w3: int = _wall_w()
			var pinned_y3 := _pinned_wall_y(fdata, ih_t)
			var hover_x := clampi(_hover_tile.x, 0, wall_w3 - iw_t)
			if hover_x <= Floor.WALL_SNAP:
				hover_x = 0
			elif wall_w3 - iw_t - hover_x <= Floor.WALL_SNAP:
				hover_x = wall_w3 - iw_t
			var at := Vector2i(
				hover_x,
				pinned_y3 if pinned_y3 >= 0 else clampi(_hover_tile.y, 0, WALL_HEIGHT - ih_t)
			)
			var px := at.x * TILE_SIZE
			var py := at.y * TILE_SIZE
			var iw := iw_t * TILE_SIZE
			var ih := ih_t * TILE_SIZE
			var ghost := Color("#" + (fdata.get("color", "888888") as String))
			ghost.a = 0.45
			draw_area.draw_rect(Rect2(px, py, iw, ih), ghost)
			draw_area.draw_rect(Rect2(px, py, iw, ih), Color.WHITE, false, 1.5)
			_draw_label(px + 3, py + 12, float(iw - 6), fdata["name"] as String)


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
		draw_area.draw_rect(Rect2(wx, wy, wlen, wh), GridDraw.WINDOW_COLOR)
		draw_area.draw_rect(Rect2(wx - 2, wy + wh, wlen + 4, 3), GridDraw.BP_INK)
		draw_area.draw_rect(Rect2(wx, wy, wlen, wh), GridDraw.BP_INK, false, 3.0)
		draw_area.draw_line(Vector2(wx + wlen * 0.5, wy), Vector2(wx + wlen * 0.5, wy + wh),
			GridDraw.BP_INK, 2.0)
		draw_area.draw_line(Vector2(wx, wy + wh * 0.5), Vector2(wx + wlen, wy + wh * 0.5),
			GridDraw.BP_INK, 2.0)

	if wd.get("has_door", false):
		var dx: int = (wd.get("door_x", 0) as int) * TILE_SIZE
		var dw: int = 10 * TILE_SIZE
		var dh: int = 21 * TILE_SIZE
		var dy: int = rh - dh
		draw_area.draw_rect(Rect2(dx, dy, dw, dh), Color(0.03, 0.07, 0.13))
		draw_area.draw_rect(Rect2(dx + 3, dy + 3, dw - 6, dh - 3), Color(0.20, 0.42, 0.58))
		draw_area.draw_rect(Rect2(dx, dy, dw, dh), GridDraw.BP_INK, false, 3.0)
		draw_area.draw_rect(Rect2(dx + 7, dy + 8, dw - 14, dh / 2.0 - 12),
			Color(0, 0, 0, 0.15), false, 1.0)
		draw_area.draw_rect(Rect2(dx + 7, dy + dh / 2.0 + 4, dw - 14, dh / 2.0 - 16),
			Color(0, 0, 0, 0.15), false, 1.0)
		draw_area.draw_circle(Vector2(dx + dw - 8, dy + dh * 0.55), 3.0,
			Color(0.85, 0.72, 0.20))


func _get_wall_def() -> Dictionary:
	if not _apt_floor:
		return {}
	# New (segments) format: wall_definitions is always empty (has_window/
	# has_door live on the segment itself instead), so the legacy lookup below
	# silently found nothing and no level built with the Builder tab ever
	# rendered its window/door in this elevation view. Look the segment up
	# directly and translate its fields into the same shape the legacy dict
	# used, so every draw call below stays unchanged.
	if not _apt_floor.segments.is_empty():
		var seg := _apt_floor.get_wall_segment(_edge, _local_to_abs(int(_wall_w() / 2)))
		if seg.is_empty():
			return {}
		var seg_start: int = mini(seg["x1"] as int, seg["x2"] as int) if _edge in ["north", "south"] \
			else mini(seg["y1"] as int, seg["y2"] as int)
		var out := {}
		if seg.get("has_window", false):
			var w_lo := seg_start + (seg.get("window_pos", 0) as int)
			var w_hi := w_lo + (seg.get("window_len", 15) as int)
			var a := _abs_to_local(w_lo) - _span_offset_local
			var b := _abs_to_local(w_hi) - _span_offset_local
			out["has_window"]  = true
			out["window_x"]    = mini(a, b)
			out["window_len"]  = absi(b - a)
		if seg.get("has_door", false):
			const DOOR_LEN := 10   # matches Wall.gd's own _partition_tile_set constant
			var d_lo := seg_start + (seg.get("door_pos", 0) as int)
			var d_hi := d_lo + DOOR_LEN
			var a := _abs_to_local(d_lo) - _span_offset_local
			var b := _abs_to_local(d_hi) - _span_offset_local
			out["has_door"] = true
			out["door_x"]   = mini(a, b)
		return out
	for wd in _apt_floor.wall_definitions:
		if wd.get("edge", "") == _edge:
			return wd
	return {}


func _draw_floor_piece(f: Furniture, wx: float, floor_baseline_px: float, is_dragged: bool, is_context: bool = false) -> void:
	var fdata := _find_by_id(f.furniture_id)
	if fdata.is_empty():
		return
	var item_w: int = (f.grid_w if _edge in ["north", "south"] else f.grid_h)
	var col := Color("#" + (fdata.get("color", "888888") as String))
	col.a = 0.55
	var outline_a := 1.0
	if is_dragged:
		outline_a = 0.35
	elif is_context:
		outline_a = 0.75
	var px := wx * TILE_SIZE
	var pw := item_w * TILE_SIZE

	if fdata.get("creates_loft", false):
		# Elevated bed on legs: legs always reach the real floor, regardless of
		# which floor tab (base or loft) this is drawn from.
		_draw_loft_bed(f, px, pw, col, is_dragged)
		return

	var wall_h: int = fdata.get("wall_h", 5) as int
	var ph := wall_h * TILE_SIZE
	var py := floor_baseline_px - ph
	draw_area.draw_rect(Rect2(px, py, pw, ph), col)
	draw_area.draw_rect(Rect2(px, py, pw, ph),
		Color(GridDraw.BP_INK.r, GridDraw.BP_INK.g, GridDraw.BP_INK.b, outline_a), false, 1.5)
	if not is_dragged:
		_draw_label(px + 3, py + 10, float(pw - 6), f.furniture_name)


func _draw_loft_bed(f: Furniture, px: float, pw: float, col: Color, is_dragged: bool) -> void:
	const LEG_TOP    := 14   # tiles from floor — matches z_bottom clearance below
	const PLATFORM_H := 6    # tiles — mattress + frame + guard rail, drawn as one block
	# Remaining (WALL_HEIGHT - LEG_TOP - PLATFORM_H) = 4 tiles (~40 cm) of clear
	# headroom is left between the platform and the ceiling, intentionally blank.
	var rh      := WALL_HEIGHT * TILE_SIZE
	var leg_top_px  := rh - LEG_TOP * TILE_SIZE
	var plat_top_px := leg_top_px - PLATFORM_H * TILE_SIZE
	var leg_w   := minf(TILE_SIZE, pw * 0.18)
	var outline := Color(GridDraw.BP_INK.r, GridDraw.BP_INK.g, GridDraw.BP_INK.b, 0.75)

	# Bunk beds (litera) keep a fixed lower mattress under the elevated top
	# bunk, unlike a true loft bed which leaves that space open to furnish —
	# draw it first so the corner-post legs still read on top of it.
	if f.furniture_id == "bunk_bed":
		const LOWER_H := 7   # tiles — lower mattress + frame
		var lower_top_px := rh - LOWER_H * TILE_SIZE
		draw_area.draw_rect(Rect2(px, lower_top_px, pw, LOWER_H * TILE_SIZE), col)
		draw_area.draw_rect(Rect2(px, lower_top_px, pw, LOWER_H * TILE_SIZE), outline, false, 1.0)

	# Legs
	draw_area.draw_rect(Rect2(px + 1,               leg_top_px, leg_w, rh - leg_top_px), col)
	draw_area.draw_rect(Rect2(px + pw - leg_w - 1,   leg_top_px, leg_w, rh - leg_top_px), col)
	draw_area.draw_rect(Rect2(px + 1,               leg_top_px, leg_w, rh - leg_top_px), outline, false, 1.0)
	draw_area.draw_rect(Rect2(px + pw - leg_w - 1,   leg_top_px, leg_w, rh - leg_top_px), outline, false, 1.0)
	# Bracing crossbar near the base of the legs
	var brace_y := rh - 3 * TILE_SIZE
	draw_area.draw_line(Vector2(px + 1 + leg_w * 0.5, brace_y),
		Vector2(px + pw - leg_w * 0.5 - 1, brace_y), outline, 1.5)
	# Ladder rungs up the left leg
	for i in range(3):
		var ry := rh - TILE_SIZE * (3 + i * 3)
		draw_area.draw_line(Vector2(px + 1, ry), Vector2(px + 1 + leg_w * 1.6, ry), outline, 1.2)

	# Platform (mattress + frame)
	draw_area.draw_rect(Rect2(px, plat_top_px, pw, PLATFORM_H * TILE_SIZE), col)
	draw_area.draw_rect(Rect2(px, plat_top_px, pw, PLATFORM_H * TILE_SIZE), outline, false, 1.0)
	# Guard-rail line along the top edge
	draw_area.draw_line(Vector2(px + 2, plat_top_px + 2), Vector2(px + pw - 2, plat_top_px + 2),
		outline, 1.5)

	if not is_dragged:
		_draw_label(px + 3, plat_top_px + 10, float(pw - 6), f.furniture_name)


func _draw_label(x: float, y: float, max_w: float, text: String) -> void:
	draw_area.draw_string(ThemeDB.fallback_font, Vector2(x, y), text,
		HORIZONTAL_ALIGNMENT_LEFT, int(max_w), 9, GridDraw.BP_INK)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _wall_w() -> int:
	if not _apt_floor:
		return 8
	if _span_width >= 0:
		return _span_width
	var bounds := _apt_floor.get_room_bounds()
	# -1: bounds.size spans corner-tile to corner-tile (e.g. west wall's own
	# tile to east wall's own tile), but a floor piece can never actually
	# reach either corner tile — those are blocked, same as bounds.position
	# itself (see get_adjacent_furniture / snap_to_wall). The elevation
	# view's usable width is one tile narrower than the raw bounds span.
	var raw := bounds.size.x if _edge in ["north", "south"] else bounds.size.y
	return raw - 1


# ── Sloped ceiling → wall cut ──────────────────────────────────────────────
# Ceiling height (metres) at a given column of THIS wall's elevation view.
# `col` is local to the wall (0 at its start). Walls running along the slope
# axis (north/south for axis "x", east/west for axis "y") get a height that
# varies per column; the other two walls sit at one fixed coordinate along
# the slope axis, so they get a single constant height across their span.
func _ceiling_height_m(col: int) -> float:
	if not _apt_floor:
		return float(WALL_HEIGHT) / 10.0
	var sc: Dictionary = _apt_floor.sloped_ceiling
	if sc.is_empty():
		return float(WALL_HEIGHT) / 10.0
	var axis: String  = sc.get("axis", "x") as String
	var low_s: int    = sc.get("low_start", 0) as int
	var high_e: int   = sc.get("high_end", 0) as int
	var min_h: float  = sc.get("min_h", 1.8) as float
	var max_h: float  = sc.get("max_h", 2.4) as float
	var span := high_e - low_s
	if span <= 0:
		return max_h
	var bounds := _apt_floor.get_room_bounds()
	var progressive := (axis == "x" and _edge in ["north", "south"]) \
		or (axis == "y" and _edge in ["east", "west"])
	var coord: int
	if progressive:
		# _local_to_abs already accounts for a sub-span's own offset, so a
		# split multi-room floor reads the slope at the true absolute
		# position instead of the whole edge's.
		coord = _local_to_abs(col)
	else:
		match _edge:
			"north": coord = bounds.position.y
			"south": coord = bounds.position.y + bounds.size.y - 1
			"west":  coord = bounds.position.x
			"east":  coord = bounds.position.x + bounds.size.x - 1
			_:       coord = low_s
	# Outside the slope's own [low_start, high_end] run, this wall (or this
	# column of it) isn't under the raked ceiling at all — e.g. a separate
	# room on a multi-room floor that just shares the sloped_ceiling record —
	# so it reads as full height instead of being clamped to the slope's
	# lowest point.
	if coord < low_s or coord > high_e:
		return max_h
	var frac := float(coord - low_s) / float(span)
	return min_h + frac * (max_h - min_h)


# Number of tile-rows blocked at the TOP of this wall's elevation (closest to
# the real ceiling) because the sloped ceiling is lower than the full
# WALL_HEIGHT (2.4 m) at this column.
func _ceiling_cut_tiles(col: int) -> int:
	if not _apt_floor or _apt_floor.sloped_ceiling.is_empty():
		return 0
	var avail_tiles := int(round(_ceiling_height_m(col) * 10.0))
	return clampi(WALL_HEIGHT - avail_tiles, 0, WALL_HEIGHT)


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
	if not _apt_floor.segments.is_empty():
		var seg := _apt_floor.get_wall_segment(edge, _local_to_abs(int(_wall_w() / 2)))
		return not seg.is_empty() and (seg.get(feature, false) as bool)
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
