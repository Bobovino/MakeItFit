extends Node2D
class_name GridDraw

const TILE_SIZE    := 8
const FLOOR_COLOR  := Color(0.93, 0.90, 0.83, 1.0)   # warm drafting-paper cream
const WALL_COLOR   := Color(0.16, 0.13, 0.10, 1.0)   # dark charcoal ink
const GRID_MINOR   := Color(0.55, 0.52, 0.44, 0.22)  # subtle warm grid
const GRID_MAJOR   := Color(0.45, 0.42, 0.34, 0.50)  # metre markers
const DOOR_COLOR   := Color(0.62, 0.40, 0.18, 1.0)   # warm chestnut
const WINDOW_COLOR := Color(0.42, 0.68, 0.88, 0.85)  # sky blue pane
const EDGE_HOVER   := Color(1.0, 0.88, 0.2, 0.55)
const EDGE_ACTIVE  := Color(1.0, 0.60, 0.0, 1.0)
const WALL_THICK   := 6.0
const EDGE_W       := 10.0   # clickable strip width — must match Wall.gd EDGE_MARGIN
const METER_TILES  := 10

var _hovered_edge: String = ""
var _active_edge:  String = ""
var _gm: GameManager = null
var show_subfloor: bool = false
var show_ceiling:  bool = false


func set_active_edge(edge: String) -> void:
	if _active_edge != edge:
		_active_edge = edge
		queue_redraw()


func _ready() -> void:
	_gm = get_tree().get_first_node_in_group("game_manager") as GameManager
	var parent := get_parent() as Floor
	if parent:
		parent.furniture_changed.connect(queue_redraw)


func _process(_delta: float) -> void:
	var parent: Floor = get_parent() as Floor
	if not parent or not parent.visible:
		if _hovered_edge != "":
			_hovered_edge = ""
			queue_redraw()
		return
	var mouse := to_local(get_global_mouse_position())
	var rw := parent.grid_w * TILE_SIZE
	var rh := parent.grid_h * TILE_SIZE
	var new_hover := ""
	# Detect hover within EDGE_W on either side of the wall line
	if mouse.y >= -EDGE_W and mouse.y <= EDGE_W and mouse.x >= 0 and mouse.x <= rw:
		new_hover = "north"
	elif mouse.y >= rh - EDGE_W and mouse.y <= rh + EDGE_W and mouse.x >= 0 and mouse.x <= rw:
		new_hover = "south"
	elif mouse.x >= -EDGE_W and mouse.x <= EDGE_W and mouse.y > EDGE_W and mouse.y < rh - EDGE_W:
		new_hover = "west"
	elif mouse.x >= rw - EDGE_W and mouse.x <= rw + EDGE_W and mouse.y > EDGE_W and mouse.y < rh - EDGE_W:
		new_hover = "east"
	if new_hover != _hovered_edge:
		_hovered_edge = new_hover
		queue_redraw()


func _draw() -> void:
	var parent: Floor = get_parent() as Floor
	if not parent:
		return
	var w  := parent.grid_w
	var h  := parent.grid_h
	var rw := w * TILE_SIZE
	var rh := h * TILE_SIZE

	if parent._use_new_format:
		_draw_new_format(parent, w, h, rw, rh)
	else:
		_draw_old_format(parent, w, h, rw, rh)

	# Common to both formats
	_draw_diagonal_splits(parent)
	_draw_wall_items(parent, rw, rh)
	if show_subfloor:
		_draw_subfloor_layer(parent)
	if show_ceiling:
		_draw_ceiling_layer(parent)


func _draw_old_format(parent: Floor, w: int, h: int, rw: int, rh: int) -> void:
	draw_rect(Rect2(0, 0, rw, rh), FLOOR_COLOR)
	_draw_natural_light(parent)

	for x in range(w + 1):
		draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, rh), GRID_MINOR, 0.5)
	for y in range(h + 1):
		draw_line(Vector2(0, y * TILE_SIZE), Vector2(rw, y * TILE_SIZE), GRID_MINOR, 0.5)
	for x in range(0, w + 1, METER_TILES):
		draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, rh), GRID_MAJOR, 1.0)
	for y in range(0, h + 1, METER_TILES):
		draw_line(Vector2(0, y * TILE_SIZE), Vector2(rw, y * TILE_SIZE), GRID_MAJOR, 1.0)

	draw_line(Vector2(0,  0),  Vector2(rw, 0),  WALL_COLOR, WALL_THICK)
	draw_line(Vector2(0,  rh), Vector2(rw, rh), WALL_COLOR, WALL_THICK)
	draw_line(Vector2(0,  0),  Vector2(0,  rh), WALL_COLOR, WALL_THICK)
	draw_line(Vector2(rw, 0),  Vector2(rw, rh), WALL_COLOR, WALL_THICK)

	if _hovered_edge != "" and _hovered_edge != _active_edge:
		match _hovered_edge:
			"north": draw_line(Vector2(0, 0),  Vector2(rw, 0),  EDGE_HOVER, WALL_THICK + 2.0)
			"south": draw_line(Vector2(0, rh), Vector2(rw, rh), EDGE_HOVER, WALL_THICK + 2.0)
			"west":  draw_line(Vector2(0, 0),  Vector2(0, rh),  EDGE_HOVER, WALL_THICK + 2.0)
			"east":  draw_line(Vector2(rw, 0), Vector2(rw, rh), EDGE_HOVER, WALL_THICK + 2.0)
	if _active_edge != "":
		var glow_outer := Color(EDGE_ACTIVE.r, EDGE_ACTIVE.g, EDGE_ACTIVE.b, 0.35)
		match _active_edge:
			"north":
				draw_line(Vector2(0, 0),  Vector2(rw, 0),  glow_outer,  WALL_THICK + 8.0)
				draw_line(Vector2(0, 0),  Vector2(rw, 0),  EDGE_ACTIVE, WALL_THICK + 1.0)
			"south":
				draw_line(Vector2(0, rh), Vector2(rw, rh), glow_outer,  WALL_THICK + 8.0)
				draw_line(Vector2(0, rh), Vector2(rw, rh), EDGE_ACTIVE, WALL_THICK + 1.0)
			"west":
				draw_line(Vector2(0, 0),  Vector2(0, rh),  glow_outer,  WALL_THICK + 8.0)
				draw_line(Vector2(0, 0),  Vector2(0, rh),  EDGE_ACTIVE, WALL_THICK + 1.0)
			"east":
				draw_line(Vector2(rw, 0), Vector2(rw, rh), glow_outer,  WALL_THICK + 8.0)
				draw_line(Vector2(rw, 0), Vector2(rw, rh), EDGE_ACTIVE, WALL_THICK + 1.0)

	_draw_sloped_ceiling(parent)
	_draw_partitions(parent)
	_draw_columns(parent)
	for wall_def in parent.wall_definitions:
		_draw_wall_feature(wall_def, w, h)


func _draw_new_format(parent: Floor, w: int, h: int, _rw: int, _rh: int) -> void:
	# Dark drawing-table canvas
	const CANVAS_BG   := Color(0.13, 0.12, 0.11, 1.0)
	# Grid lines — visible on both dark canvas and cream floor tiles
	const FINE_COL    := Color(0.44, 0.41, 0.36, 1.0)  # 10 cm subcell lines
	const MAJOR_COL   := Color(0.64, 0.60, 0.52, 1.0)  # 1 m cell lines (brighter)

	var ww := w * TILE_SIZE
	var hh := h * TILE_SIZE

	# ── Adaptive zoom ─────────────────────────────────────────────────────────
	# Use the canvas transform scale to determine effective px-per-tile,
	# which works regardless of where the Camera2D sits in the scene tree.
	var ct_scale := get_viewport().get_canvas_transform().get_scale().x \
		if get_viewport() else 1.0
	var px_per_tile := ct_scale * float(TILE_SIZE)
	var show_fine   := px_per_tile >= 5.0   # draw 10 cm subcell lines when ≥ 5 px/tile

	# ── 1. Canvas background ──────────────────────────────────────────────────
	draw_rect(Rect2(0, 0, ww, hh), CANVAS_BG)

	# ── 2. Painted floor tiles (cream) ───────────────────────────────────────
	for tile in parent.floor_mask:
		var t := tile as Vector2i
		draw_rect(Rect2(t.x * TILE_SIZE, t.y * TILE_SIZE, TILE_SIZE, TILE_SIZE), FLOOR_COLOR)

	# ── 3. Grid lines ─────────────────────────────────────────────────────────
	# Subcell lines (10 cm) — 1 px wide, drawn when each tile is ≥ 5 screen px
	if show_fine:
		for x in range(w + 1):
			if x % METER_TILES != 0:
				draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, hh), FINE_COL, 1.0)
		for y in range(h + 1):
			if y % METER_TILES != 0:
				draw_line(Vector2(0, y * TILE_SIZE), Vector2(ww, y * TILE_SIZE), FINE_COL, 1.0)
	# Meter lines (1 m) — 2 px wide, always drawn
	for x in range(0, w + 1, METER_TILES):
		draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, hh), MAJOR_COL, 2.0)
	for y in range(0, h + 1, METER_TILES):
		draw_line(Vector2(0, y * TILE_SIZE), Vector2(ww, y * TILE_SIZE), MAJOR_COL, 2.0)

	# ── 4. Natural light hatching (only over painted tiles) ───────────────────
	_draw_natural_light(parent)

	_draw_columns(parent)
	_draw_segments(parent)


func _draw_segments(parent: Floor) -> void:
	const PRIMARY_COL   := Color(0.16, 0.13, 0.10, 1.0)
	const SECONDARY_COL := Color(0.40, 0.36, 0.30, 0.85)
	const DEMO_COL      := Color(0.78, 0.40, 0.16, 0.18)
	# Primary wall ≈ 20 cm = 2 tiles = 16 px at 1× zoom
	# Secondary wall ≈ 5 cm = 0.5 tile = 4 px at 1× zoom
	const PRIMARY_W     := float(TILE_SIZE * 2)
	const SECONDARY_W   := float(TILE_SIZE) * 0.5
	const DOOR_LEN      := 10

	for seg in parent.segments:
		var sd      := seg as Dictionary
		var x1: int  = sd["x1"]; var y1: int = sd["y1"]
		var x2: int  = sd["x2"]; var y2: int = sd["y2"]
		var primary := sd.get("primary",    false) as bool
		var dem     := sd.get("demolished", false) as bool
		var has_win := sd.get("has_window", false) as bool
		var has_dor := sd.get("has_door",   false) as bool
		var wp: int  = sd.get("window_pos", 0)     as int
		var wl: int  = sd.get("window_len", 10)    as int
		var dp: int  = sd.get("door_pos",   0)     as int
		var is_h    := (y1 == y2)
		var mn_x    := mini(x1, x2); var mn_y := mini(y1, y2)
		var seg_len := maxi(absi(x2 - x1), absi(y2 - y1))

		var pa := Vector2(x1 * TILE_SIZE, y1 * TILE_SIZE)
		var pb := Vector2(x2 * TILE_SIZE, y2 * TILE_SIZE)

		if dem:
			draw_dashed_line(pa, pb, DEMO_COL, 2.0, 5.0)
			continue

		var col   := PRIMARY_COL   if primary else SECONDARY_COL
		var thick := PRIMARY_W     if primary else SECONDARY_W

		# Build gap ranges (window + door)
		var gaps: Array = []
		if has_win and wp >= 0:
			gaps.append([wp, mini(wp + wl, seg_len)])
		if has_dor and dp >= 0:
			gaps.append([dp, mini(dp + DOOR_LEN, seg_len)])
		gaps.sort_custom(func(a, b): return a[0] < b[0])

		# Draw segment in pieces around gaps
		var pos := 0
		for gap in gaps:
			var gs: int = gap[0]; var ge: int = gap[1]
			if pos < gs:
				var a := _seg_pt(is_h, mn_x, mn_y, x1, y1, pos)
				var b := _seg_pt(is_h, mn_x, mn_y, x1, y1, gs)
				draw_line(a, b, col, thick)
			pos = ge
		if pos < seg_len:
			var a := _seg_pt(is_h, mn_x, mn_y, x1, y1, pos)
			draw_line(a, pb, col, thick)
		elif gaps.is_empty():
			draw_line(pa, pb, col, thick)

		# Hatch marks on primary walls (load-bearing indicator)
		if primary:
			var sv    := pb - pa
			var perp  := Vector2(-sv.normalized().y, sv.normalized().x) * 4.0
			var steps := int(sv.length() / (TILE_SIZE * 2))
			for i in range(steps + 1):
				var t := pa + sv * (float(i) / float(maxi(steps, 1)))
				draw_line(t - perp, t + perp, col, 1.2)

		# Window rendering
		if has_win and wp >= 0:
			if is_h:
				draw_rect(Rect2((mn_x + wp) * TILE_SIZE + 1, y1 * TILE_SIZE - thick * 0.5,
						wl * TILE_SIZE - 2, thick + 1), WINDOW_COLOR)
			else:
				draw_rect(Rect2(x1 * TILE_SIZE - thick * 0.5, (mn_y + wp) * TILE_SIZE + 1,
						thick + 1, wl * TILE_SIZE - 2), WINDOW_COLOR)

		# Door rendering
		if has_dor and dp >= 0:
			var door_px := DOOR_LEN * TILE_SIZE
			var arc_col := Color(DOOR_COLOR.r, DOOR_COLOR.g, DOOR_COLOR.b, 0.40)
			if is_h:
				var dx := (mn_x + dp) * TILE_SIZE
				var dy := y1 * TILE_SIZE
				draw_rect(Rect2(dx + 1, dy - thick * 0.5 - 1, door_px - 2, thick + 3), FLOOR_COLOR)
				draw_line(Vector2(dx, dy), Vector2(dx, dy + door_px), DOOR_COLOR, 1.2)
				draw_arc(Vector2(dx, dy), door_px, 0, PI * 0.5, 20, arc_col, 1.0)
			else:
				var dx := x1 * TILE_SIZE
				var dy := (mn_y + dp) * TILE_SIZE
				draw_rect(Rect2(dx - thick * 0.5 - 1, dy + 1, thick + 3, door_px - 2), FLOOR_COLOR)
				draw_line(Vector2(dx, dy), Vector2(dx + door_px, dy), DOOR_COLOR, 1.2)
				draw_arc(Vector2(dx, dy), door_px, 0, PI * 0.5, 20, arc_col, 1.0)


func _seg_pt(is_h: bool, mn_x: int, mn_y: int, x1: int, y1: int, pos: int) -> Vector2:
	if is_h:
		return Vector2((mn_x + pos) * TILE_SIZE, y1 * TILE_SIZE)
	else:
		return Vector2(x1 * TILE_SIZE, (mn_y + pos) * TILE_SIZE)


func _draw_diagonal_splits(parent: Floor) -> void:
	# When a wall item's floor shadow overlaps a floor furniture tile,
	# render the floor furniture color in the lower-left triangle and
	# the wall item color in the upper-right triangle of that tile.
	if not _gm:
		return

	# Build a map of wall-item shadow tiles → color for each edge
	var wall_shadow: Dictionary = {}  # Vector2i → Color
	for edge in parent.wall_items:
		var items: Dictionary = parent.wall_items[edge] as Dictionary
		for origin in items:
			var o      := origin as Vector2i
			var fid    : String = items[origin] as String
			var fdata  := _gm.get_furniture_by_id(fid)
			if fdata.is_empty():
				continue
			var iw:    int = fdata["size"]["w"] as int
			var depth: int = fdata.get("floor_depth", 1) as int
			var col        := Color("#" + (fdata.get("color", "aaaaaa") as String))
			col.a = 0.85
			for ix in range(iw):
				for iy in range(depth):
					var tile: Vector2i
					match edge:
						"north": tile = Vector2i(o.x + ix, iy)
						"south": tile = Vector2i(o.x + ix, parent.grid_h - 1 - iy)
						"west":  tile = Vector2i(iy, o.x + ix)
						"east":  tile = Vector2i(parent.grid_w - 1 - iy, o.x + ix)
					wall_shadow[tile] = col

	# Check each floor furniture tile for overlap with wall shadow
	for tile in parent._get_placed_tiles():
		if not (tile in wall_shadow):
			continue
		var t         := tile as Vector2i
		var floor_col := parent._get_tile_color(t)
		var wall_col  := wall_shadow[t] as Color
		var px: int   = t.x * TILE_SIZE
		var py: int   = t.y * TILE_SIZE
		var ts: int   = TILE_SIZE
		# Upper-right triangle → wall item color
		draw_colored_polygon(PackedVector2Array([
			Vector2(px,      py),
			Vector2(px + ts, py),
			Vector2(px + ts, py + ts)
		]), wall_col)
		# Lower-left triangle → floor furniture color
		draw_colored_polygon(PackedVector2Array([
			Vector2(px,      py),
			Vector2(px + ts, py + ts),
			Vector2(px,      py + ts)
		]), floor_col)


func _draw_wall_items(parent: Floor, rw: int, rh: int) -> void:
	if not _gm:
		return
	for edge in parent.wall_items:
		var items: Dictionary = parent.wall_items[edge] as Dictionary
		for origin in items:
			var o     := origin as Vector2i
			var fid   : String = items[origin] as String
			var fdata  := _gm.get_furniture_by_id(fid)
			if fdata.is_empty():
				continue
			var iw: int    = fdata["size"]["w"] as int
			var depth: int = fdata.get("floor_depth", 1) as int
			var col        := Color("#" + (fdata.get("color", "aaaaaa") as String))
			col.a = 0.85
			match edge:
				"north":
					draw_rect(Rect2(o.x * TILE_SIZE, 0, iw * TILE_SIZE, depth * TILE_SIZE), col)
					draw_rect(Rect2(o.x * TILE_SIZE, 0, iw * TILE_SIZE, depth * TILE_SIZE),
						Color(0, 0, 0, 0.40), false, 1.0)
				"south":
					var ry := rh - depth * TILE_SIZE
					draw_rect(Rect2(o.x * TILE_SIZE, ry, iw * TILE_SIZE, depth * TILE_SIZE), col)
					draw_rect(Rect2(o.x * TILE_SIZE, ry, iw * TILE_SIZE, depth * TILE_SIZE),
						Color(0, 0, 0, 0.40), false, 1.0)
				"west":
					draw_rect(Rect2(0, o.x * TILE_SIZE, depth * TILE_SIZE, iw * TILE_SIZE), col)
					draw_rect(Rect2(0, o.x * TILE_SIZE, depth * TILE_SIZE, iw * TILE_SIZE),
						Color(0, 0, 0, 0.40), false, 1.0)
				"east":
					var rx := rw - depth * TILE_SIZE
					draw_rect(Rect2(rx, o.x * TILE_SIZE, depth * TILE_SIZE, iw * TILE_SIZE), col)
					draw_rect(Rect2(rx, o.x * TILE_SIZE, depth * TILE_SIZE, iw * TILE_SIZE),
						Color(0, 0, 0, 0.40), false, 1.0)


func _draw_wall_feature(wall_def: Dictionary, w: int, h: int) -> void:
	var edge: String = wall_def.get("edge", "")
	var rw := w * TILE_SIZE
	var rh := h * TILE_SIZE

	if wall_def.get("has_door", false):
		var dx: int = wall_def.get("door_x", 0) as int
		var gap := TILE_SIZE * 10   # door = 1 m wide
		var arc_col := Color(DOOR_COLOR.r, DOOR_COLOR.g, DOOR_COLOR.b, 0.40)
		match edge:
			"north":
				draw_rect(Rect2(dx * TILE_SIZE + 1, -1, gap - 2, WALL_THICK + 2), FLOOR_COLOR)
				draw_line(Vector2(dx * TILE_SIZE, 0), Vector2(dx * TILE_SIZE, gap), DOOR_COLOR, 1.2)
				draw_arc(Vector2(dx * TILE_SIZE, 0), gap, 0, PI * 0.5, 20, arc_col, 1.0)
			"south":
				draw_rect(Rect2(dx * TILE_SIZE + 1, rh - 1, gap - 2, WALL_THICK + 2), FLOOR_COLOR)
				draw_line(Vector2(dx * TILE_SIZE, rh), Vector2(dx * TILE_SIZE, rh - gap), DOOR_COLOR, 1.2)
				draw_arc(Vector2(dx * TILE_SIZE, rh), gap, -PI * 0.5, 0, 20, arc_col, 1.0)
			"west":
				draw_rect(Rect2(-1, dx * TILE_SIZE + 1, WALL_THICK + 2, gap - 2), FLOOR_COLOR)
				draw_line(Vector2(0, dx * TILE_SIZE), Vector2(gap, dx * TILE_SIZE), DOOR_COLOR, 1.2)
				draw_arc(Vector2(0, dx * TILE_SIZE), gap, 0, PI * 0.5, 20, arc_col, 1.0)
			"east":
				draw_rect(Rect2(rw - 1, dx * TILE_SIZE + 1, WALL_THICK + 2, gap - 2), FLOOR_COLOR)
				draw_line(Vector2(rw, dx * TILE_SIZE), Vector2(rw - gap, dx * TILE_SIZE), DOOR_COLOR, 1.2)
				draw_arc(Vector2(rw, dx * TILE_SIZE), gap, PI * 0.5, PI, 20, arc_col, 1.0)

	if wall_def.get("has_window", false):
		var wx: int = wall_def.get("window_x", 0) as int
		var wl: int = wall_def.get("window_len", 15) as int
		match edge:
			"north": draw_rect(Rect2(wx * TILE_SIZE + 1, -1, wl * TILE_SIZE - 2, WALL_THICK + 2), WINDOW_COLOR)
			"south": draw_rect(Rect2(wx * TILE_SIZE + 1, rh - 1, wl * TILE_SIZE - 2, WALL_THICK + 2), WINDOW_COLOR)
			"west":  draw_rect(Rect2(-1, wx * TILE_SIZE + 1, WALL_THICK + 2, wl * TILE_SIZE - 2), WINDOW_COLOR)
			"east":  draw_rect(Rect2(rw - 1, wx * TILE_SIZE + 1, WALL_THICK + 2, wl * TILE_SIZE - 2), WINDOW_COLOR)


func _draw_sloped_ceiling(parent: Floor) -> void:
	# sloped_ceiling: {axis, low_start, high_end, min_h, max_h}
	# axis: "x" → slope runs left→right, "y" → top→bottom
	# Draws height contour lines as thin dashed blue-grey lines at each step change
	var sc: Dictionary = parent.sloped_ceiling
	if sc.is_empty():
		return

	var axis: String  = sc.get("axis", "x") as String
	var low_s: int    = sc.get("low_start", 0) as int   # tile coord where low ceiling starts
	var high_e: int   = sc.get("high_end",  0) as int   # tile coord where it reaches full height
	var min_h: float  = sc.get("min_h", 1.8) as float   # metres at low end
	var max_h: float  = sc.get("max_h", 2.4) as float   # metres at high end

	const CONTOUR_STEP := 0.2   # draw a line every 20cm height change
	const CONTOUR_COL  := Color(0.42, 0.52, 0.68, 0.55)

	var rw := parent.grid_w * TILE_SIZE
	var rh := parent.grid_h * TILE_SIZE
	var span := high_e - low_s
	if span <= 0:
		return

	var steps := int((max_h - min_h) / CONTOUR_STEP)
	for si in range(1, steps + 1):
		var h_at := min_h + si * CONTOUR_STEP
		var frac := (h_at - min_h) / (max_h - min_h)
		var tile_pos := low_s + int(frac * span)
		var px := tile_pos * TILE_SIZE
		if axis == "x":
			draw_dashed_line(Vector2(px, 0), Vector2(px, rh), CONTOUR_COL, 0.8, 5.0)
			if si % 2 == 0:
				draw_string(ThemeDB.fallback_font, Vector2(px + 2, 10), "%.1fm" % h_at,
					HORIZONTAL_ALIGNMENT_LEFT, 32, 6, CONTOUR_COL)
		else:
			draw_dashed_line(Vector2(0, px), Vector2(rw, px), CONTOUR_COL, 0.8, 5.0)
			if si % 2 == 0:
				draw_string(ThemeDB.fallback_font, Vector2(2, px - 2), "%.1fm" % h_at,
					HORIZONTAL_ALIGNMENT_LEFT, 32, 6, CONTOUR_COL)

	# Low-ceiling blocked zone overlay (min_h < 2.0 m blocks tall furniture)
	if min_h < 2.0:
		var frac_2m := (2.0 - min_h) / (max_h - min_h)
		var px_2m := int((low_s + frac_2m * span) * TILE_SIZE)
		if axis == "x":
			draw_rect(Rect2(0, 0, px_2m, rh), Color(0.25, 0.30, 0.50, 0.07))
		else:
			draw_rect(Rect2(0, 0, rw, px_2m), Color(0.25, 0.30, 0.50, 0.07))


func _draw_partitions(parent: Floor) -> void:
	const LB_COL   := Color(0.16, 0.13, 0.10, 0.95)   # load-bearing: same ink as outer wall
	const DEMO_COL := Color(0.40, 0.36, 0.30, 0.80)   # demolishable: softer warm grey
	const DEMO_H   := Color(0.78, 0.40, 0.16, 0.18)   # demolished: faint amber ghost

	for p in parent.partitions:
		var x1: int = p["x1"]; var y1: int = p["y1"]
		var x2: int = p["x2"]; var y2: int = p["y2"]
		var lb: bool   = p.get("load_bearing", false)
		var dem: bool  = p.get("demolished",   false)

		var pa := Vector2(x1 * TILE_SIZE, y1 * TILE_SIZE)
		var pb := Vector2(x2 * TILE_SIZE, y2 * TILE_SIZE)

		if dem:
			draw_dashed_line(pa, pb, DEMO_H, 2.0, 5.0)
			continue

		if lb:
			# Thick solid line + cross-hatch fill
			draw_line(pa, pb, LB_COL, WALL_THICK)
			# Hatch marks perpendicular to wall, every 2 tiles
			var seg := pb - pa
			var perp := Vector2(-seg.normalized().y, seg.normalized().x) * 4.0
			var steps := int(seg.length() / (TILE_SIZE * 2))
			for i in range(steps + 1):
				var t   := pa + seg * (float(i) / float(max(steps, 1)))
				draw_line(t - perp, t + perp, LB_COL, 1.2)
		else:
			draw_line(pa, pb, DEMO_COL, 2.5)
			draw_dashed_line(pa, pb, Color(1.0, 0.55, 0.20, 0.50), 1.0, 6.0)


func _draw_columns(parent: Floor) -> void:
	const COL_COL  := Color(0.16, 0.13, 0.10, 1.0)
	const COL_H    := Color(0.30, 0.26, 0.22, 0.40)
	for col in parent.columns:
		var cx: int = col["x"] as int
		var cy: int = col["y"] as int
		var r := Rect2(cx * TILE_SIZE, cy * TILE_SIZE, TILE_SIZE, TILE_SIZE)
		draw_rect(r, COL_COL)
		draw_rect(r, COL_H, false, 1.5)
		draw_line(r.position + Vector2(2, 2), r.end - Vector2(2, 2), Color(1, 1, 1, 0.12), 1.0)
		draw_line(r.position + Vector2(r.size.x - 2, 2), r.position + Vector2(2, r.size.y - 2), Color(1, 1, 1, 0.12), 1.0)


func _draw_subfloor_layer(parent: Floor) -> void:
	const WATER_COL := Color(0.22, 0.58, 0.88, 0.75)
	const POWER_COL := Color(0.95, 0.80, 0.15, 0.75)
	const SRC_W     := Color(0.22, 0.58, 0.88, 1.0)
	const SRC_P     := Color(0.95, 0.80, 0.15, 1.0)

	# Connection points (source nodes)
	for pt in parent.connection_points.get("water", []):
		var cx: int = pt["x"] as int; var cy: int = pt["y"] as int
		draw_circle(Vector2((cx + 0.5) * TILE_SIZE, (cy + 0.5) * TILE_SIZE), 4.5, SRC_W)
		draw_arc(Vector2((cx + 0.5) * TILE_SIZE, (cy + 0.5) * TILE_SIZE), 4.5, 0, TAU, 12, Color(1,1,1,0.6), 1.5)
	for pt in parent.connection_points.get("power", []):
		var cx: int = pt["x"] as int; var cy: int = pt["y"] as int
		var cx_px := (cx + 0.5) * TILE_SIZE; var cy_px := (cy + 0.5) * TILE_SIZE
		draw_rect(Rect2(cx_px - 4, cy_px - 4, 8, 8), SRC_P)
		draw_line(Vector2(cx_px, cy_px - 3), Vector2(cx_px, cy_px + 3), Color(0.2,0.2,0.2), 1.5)

	# Pipe routes
	for route in parent.pipe_routes:
		var col := WATER_COL if route["type"] == "water" else POWER_COL
		var tiles: Array = route["tiles"]
		for i in range(tiles.size() - 1):
			var a := tiles[i] as Vector2i
			var b := tiles[i + 1] as Vector2i
			var pa := Vector2((a.x + 0.5) * TILE_SIZE, (a.y + 0.5) * TILE_SIZE)
			var pb := Vector2((b.x + 0.5) * TILE_SIZE, (b.y + 0.5) * TILE_SIZE)
			draw_line(pa, pb, col, 2.5)
			draw_circle(pa, 2.0, col)
		if tiles.size() > 0:
			var last := tiles[-1] as Vector2i
			draw_circle(Vector2((last.x + 0.5) * TILE_SIZE, (last.y + 0.5) * TILE_SIZE), 2.0, col)


func _draw_ceiling_layer(parent: Floor) -> void:
	const LIGHT_COL := Color(0.95, 0.90, 0.60, 0.15)
	const LIGHT_BD  := Color(0.95, 0.90, 0.60, 0.60)
	const HVAC_COL  := Color(0.60, 0.75, 0.85, 0.70)

	for lm in parent.connection_points.get("lights", []):
		var cx: int = lm["x"] as int; var cy: int = lm["y"] as int
		var r: float = lm.get("radius", 8) as float
		var center := Vector2((cx + 0.5) * TILE_SIZE, (cy + 0.5) * TILE_SIZE)
		draw_circle(center, r * TILE_SIZE, LIGHT_COL)
		draw_arc(center, r * TILE_SIZE, 0, TAU, 24, LIGHT_BD, 1.0)
		draw_circle(center, 3.0, LIGHT_BD)

	for hv in parent.connection_points.get("hvac", []):
		var vx: int = hv["x"] as int; var vy: int = hv["y"] as int
		var vr := Rect2(vx * TILE_SIZE - 3, vy * TILE_SIZE - 3, TILE_SIZE + 6, TILE_SIZE + 6)
		draw_rect(vr, HVAC_COL)
		draw_rect(vr, Color(0.40, 0.55, 0.70, 0.90), false, 1.0)
		# Duct lines in cardinal directions
		draw_line(Vector2((vx + 0.5) * TILE_SIZE, vy * TILE_SIZE - 3),
				  Vector2((vx + 0.5) * TILE_SIZE, 0), HVAC_COL, 2.5)


func _draw_natural_light(parent: Floor) -> void:
	# Architectural hatching (45° NW→SE lines) for tiles that receive less natural light.
	# Intensity is computed by BFS flood-fill from window tiles in Floor._compute_light_map().
	# Tall furniture and walls fully block propagation; medium furniture attenuates.
	if parent._light_map.is_empty():
		return  # no windows yet — skip hatching entirely

	const LIT_MIN  := 0.50   # above this the tile is considered fully lit
	const MAX_ALPHA := 0.34  # maximum ink density of the hatching
	const HATCH_SP  := 3     # pixel spacing between hatch lines

	for gy in range(parent.grid_h):
		for gx in range(parent.grid_w):
			var tile := Vector2i(gx, gy)
			if not parent.is_floor_tile(tile):
				continue
			var intensity: float = parent.get_light(tile)
			if intensity >= LIT_MIN:
				continue

			# Remap: 0 at LIT_MIN → 1 at full dark
			var t := 1.0 - (intensity / LIT_MIN)
			var col := Color(0.10, 0.08, 0.05, t * MAX_ALPHA)

			var px := float(gx * TILE_SIZE)
			var py := float(gy * TILE_SIZE)
			var ts := float(TILE_SIZE)

			# 45° hatching: lines satisfying  y − x = k, clipped to the tile rect.
			# For each offset k the line runs from xs=(max(px, py−k)) to xe=(min(px+ts, py+ts−k)).
			var k := -int(ts)
			while k < int(ts) * 2:
				var fk  := float(k)
				var xs  := maxf(px, py - fk)
				var xe  := minf(px + ts, py + ts - fk)
				if xs < xe:
					draw_line(Vector2(xs, xs + fk), Vector2(xe, xe + fk), col, 0.7)
				k += HATCH_SP
