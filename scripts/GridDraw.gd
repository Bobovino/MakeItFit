extends Node2D
class_name GridDraw

const TILE_SIZE    := 8
# ── Cyanotype blueprint palette ───────────────────────────────────────────────
# Everything reads as a classic architectural blueprint: white/cyan ink on
# deep blue. Room interior is a slightly lighter blue so it reads as "inside".
const BP_PAPER     := Color(0.055, 0.145, 0.255, 1.0)  # deep blueprint blue (outside)
const BP_FLOOR     := Color(0.098, 0.235, 0.380, 1.0)  # room interior (lighter blue)
const BP_INK       := Color(0.86, 0.94, 1.00, 1.0)     # bright white-cyan drafting ink
const BP_INK_SOFT  := Color(0.66, 0.82, 0.96, 1.0)     # secondary lines
const BP_GRID_FINE := Color(0.42, 0.64, 0.86, 0.16)    # 10 cm subcell grid
const BP_GRID_MAJ  := Color(0.56, 0.78, 0.98, 0.38)    # 1 m grid lines

const FLOOR_COLOR  := BP_FLOOR
const WALL_COLOR   := BP_INK
const GRID_MINOR   := BP_GRID_FINE
const GRID_MAJOR   := BP_GRID_MAJ
const DOOR_COLOR   := Color(0.55, 0.82, 0.98, 1.0)   # cyan swing
const WINDOW_COLOR := Color(0.60, 0.86, 1.00, 0.95)  # bright glazing
const EDGE_HOVER   := Color(1.0, 0.88, 0.2, 0.55)
const EDGE_ACTIVE  := Color(1.0, 0.60, 0.0, 1.0)
const WALL_THICK   := 6.0
const EDGE_W       := 10.0   # clickable strip width — must match Wall.gd EDGE_MARGIN
const METER_TILES  := 10

var _hovered_edge:    String = ""
var _active_edge:     String = ""
var _hovered_seg_idx: int   = -1   # new-format hover: nearest segment index
var _gm: GameManager = null
var show_subfloor: bool = false
var show_ceiling:  bool = false
var show_grid:     bool = false


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
		if _hovered_edge != "" or _hovered_seg_idx >= 0:
			_hovered_edge = ""; _hovered_seg_idx = -1
			queue_redraw()
		return
	var mouse := to_local(get_global_mouse_position())
	if parent._use_new_format:
		var sidx := parent.find_segment_near(mouse, 3.0)
		if sidx != _hovered_seg_idx:
			_hovered_seg_idx = sidx
			queue_redraw()
	else:
		var x0 := parent._edge_x0; var y0 := parent._edge_y0
		var x1 := parent._edge_x1; var y1 := parent._edge_y1
		var new_hover := ""
		if mouse.y >= y0 - EDGE_W and mouse.y <= y0 + EDGE_W and mouse.x >= x0 and mouse.x <= x1:
			new_hover = "north"
		elif mouse.y >= y1 - EDGE_W and mouse.y <= y1 + EDGE_W and mouse.x >= x0 and mouse.x <= x1:
			new_hover = "south"
		elif mouse.x >= x0 - EDGE_W and mouse.x <= x0 + EDGE_W and mouse.y > y0 + EDGE_W and mouse.y < y1 - EDGE_W:
			new_hover = "west"
		elif mouse.x >= x1 - EDGE_W and mouse.x <= x1 + EDGE_W and mouse.y > y0 + EDGE_W and mouse.y < y1 - EDGE_W:
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
	# Edge hover / active highlight — drawn on top, using tile-bound coords
	_draw_edge_overlays(parent)


func _draw_old_format(parent: Floor, w: int, h: int, rw: int, rh: int) -> void:
	draw_rect(Rect2(0, 0, rw, rh), FLOOR_COLOR)
	_draw_natural_light(parent)

	if show_grid:
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

	_draw_sloped_ceiling(parent)
	_draw_partitions(parent)
	_draw_columns(parent)
	for wall_def in parent.wall_definitions:
		_draw_wall_feature(wall_def, w, h)


func _draw_new_format(parent: Floor, w: int, h: int, _rw: int, _rh: int) -> void:
	# Deep blueprint-blue canvas
	const CANVAS_BG   := BP_PAPER
	# Grid lines — cyan, visible on both the deep-blue paper and lighter floor
	const FINE_COL    := Color(0.34, 0.54, 0.76, 0.55)  # 10 cm subcell lines
	const MAJOR_COL   := Color(0.52, 0.74, 0.96, 0.75)  # 1 m cell lines (brighter)

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

	# ── 1b. Shadow tiles — parent floor ghost when editing a loft ─────────────
	if not parent.shadow_mask.is_empty():
		const SHADOW_COL := Color(0.82, 0.79, 0.72, 0.38)
		for tile in parent.shadow_mask:
			var t := tile as Vector2i
			draw_rect(Rect2(t.x * TILE_SIZE, t.y * TILE_SIZE, TILE_SIZE, TILE_SIZE), SHADOW_COL)

	# ── 2. Painted floor tiles (blueprint blue, or tinted by kind) ───────────
	const BALCONY_COL  := Color(0.14, 0.34, 0.32, 1.0)   # outdoor decking (teal-blue)
	const BATHROOM_COL := Color(0.16, 0.34, 0.46, 1.0)   # wet-room (brighter cyan-blue)
	for tile in parent.floor_mask:
		var t := tile as Vector2i
		var kind := parent.get_tile_kind(t) if parent.has_method("get_tile_kind") else "normal"
		var col := FLOOR_COLOR
		match kind:
			"balcony":  col = BALCONY_COL
			"bathroom": col = BATHROOM_COL
		draw_rect(Rect2(t.x * TILE_SIZE, t.y * TILE_SIZE, TILE_SIZE, TILE_SIZE), col)

	# ── 2a. Balcony railings — drawn along any edge of a balcony tile that
	# borders a non-floor (exterior/void) tile, marking the building's edge.
	if not parent.floor_kind.is_empty():
		const RAIL_BAR_COL := Color(0.94, 0.96, 0.98, 1.0)
		for tile in parent.floor_kind:
			var t := tile as Vector2i
			if (parent.floor_kind[tile] as String) != "balcony":
				continue
			var px := t.x * TILE_SIZE; var py := t.y * TILE_SIZE
			var neighbors := {
				"north": [Vector2i(t.x, t.y - 1), Vector2(px, py), Vector2(px + TILE_SIZE, py)],
				"south": [Vector2i(t.x, t.y + 1), Vector2(px, py + TILE_SIZE), Vector2(px + TILE_SIZE, py + TILE_SIZE)],
				"west":  [Vector2i(t.x - 1, t.y), Vector2(px, py), Vector2(px, py + TILE_SIZE)],
				"east":  [Vector2i(t.x + 1, t.y), Vector2(px + TILE_SIZE, py), Vector2(px + TILE_SIZE, py + TILE_SIZE)],
			}
			for edge_key in neighbors:
				var edge  := neighbors[edge_key] as Array
				var ntile := edge[0] as Vector2i
				if parent.is_floor_tile(ntile):
					continue
				var p0 := edge[1] as Vector2; var p1 := edge[2] as Vector2
				draw_line(p0, p1, RAIL_BAR_COL, 3.0)
				var tile_center := Vector2(px + TILE_SIZE * 0.5, py + TILE_SIZE * 0.5)
				var edge_mid    := (p0 + p1) * 0.5
				var inward      := (tile_center - edge_mid).normalized()
				var steps := 4
				for i in range(steps + 1):
					var pt := p0.lerp(p1, float(i) / steps)
					draw_line(pt, pt + inward * 5.0, RAIL_BAR_COL, 1.5)

	# ── 2b. Zone overlays — colour-coded by primary function ─────────────────
	if parent.zones.size() > 1:
		for zone in parent.zones:
			var z     := zone as Dictionary
			var z_fns := z.get("functions", []) as Array
			var z_col := Color(0, 0, 0, 0)
			if   "sleep" in z_fns:                     z_col = Color(0.36, 0.52, 0.82, 0.14)  # blue
			elif "cook"  in z_fns:                     z_col = Color(0.82, 0.42, 0.28, 0.14)  # red
			elif "sit"   in z_fns or "dine" in z_fns:  z_col = Color(0.78, 0.68, 0.28, 0.14)  # amber
			elif "work"  in z_fns:                     z_col = Color(0.32, 0.70, 0.42, 0.14)  # green
			if z_col.a > 0:
				for tile in z.get("tiles", {}) as Dictionary:
					var t := tile as Vector2i
					draw_rect(Rect2(t.x * TILE_SIZE, t.y * TILE_SIZE, TILE_SIZE, TILE_SIZE), z_col)

	# ── 2c. Mezzanine tiles (warm amber + diagonal hatch) ────────────────────
	const MEZZ_FILL  := Color(0.85, 0.78, 0.58, 1.0)   # warm parchment above
	const MEZZ_HATCH := Color(0.55, 0.45, 0.20, 0.55)  # dark amber hatch lines
	const MEZZ_EDGE  := Color(0.40, 0.30, 0.10, 0.80)  # south+east shadow edge
	for tile in parent.mezzanine_mask:
		var t  := tile as Vector2i
		var rx := float(t.x * TILE_SIZE)
		var ry := float(t.y * TILE_SIZE)
		var ts := float(TILE_SIZE)
		draw_rect(Rect2(rx, ry, ts, ts), MEZZ_FILL)
		# Diagonal hatch lines every 4 px
		var step := 4.0
		var i := 0.0
		while i < ts * 2:
			var x0 := maxf(rx,          rx + i - ts)
			var y0 := minf(ry + ts,     ry + i)
			var x1 := minf(rx + ts,     rx + i)
			var y1 := maxf(ry,          ry + i - ts)
			if x0 < rx + ts and y0 > ry:
				draw_line(Vector2(x0, y0), Vector2(x1, y1), MEZZ_HATCH, 0.8)
			i += step
		# Bottom and right shadow edge (architectural convention: elevated slab)
		var nb_s := Vector2i(t.x,     t.y + 1)
		var nb_e := Vector2i(t.x + 1, t.y)
		if nb_s not in parent.mezzanine_mask:
			draw_line(Vector2(rx,      ry + ts), Vector2(rx + ts, ry + ts), MEZZ_EDGE, 2.0)
		if nb_e not in parent.mezzanine_mask:
			draw_line(Vector2(rx + ts, ry),      Vector2(rx + ts, ry + ts), MEZZ_EDGE, 2.0)

	# ── 2c. Stairs ─────────────────────────────────────────────────────────────
	const STAIR_FILL   := Color(0.52, 0.60, 0.82, 0.80)
	const STAIR_NOSING := Color(0.24, 0.30, 0.58, 1.00)
	const STAIR_BORDER := Color(0.30, 0.38, 0.65, 0.85)
	const STAIR_ARROW  := Color(0.10, 0.18, 0.50, 1.00)
	const FSTAIR_FILL   := Color(0.78, 0.58, 0.22, 0.80)   # floor stair — amber
	const FSTAIR_NOSING := Color(0.58, 0.38, 0.08, 1.00)
	const FSTAIR_BORDER := Color(0.65, 0.42, 0.10, 0.85)
	const FSTAIR_ARROW  := Color(0.50, 0.28, 0.05, 1.00)
	const STEP_DEPTH   := 2   # tiles per step (20 cm rise/going)

	# Build set of tiles owned by a placed-stair furniture block
	var _sd_tiles: Dictionary = {}
	for _sentry in parent.stairs_data:
		var _sr := (_sentry as Dictionary)["rect"] as Rect2i
		for _sx in range(_sr.size.x):
			for _sy in range(_sr.size.y):
				_sd_tiles[Vector2i(_sr.position.x + _sx, _sr.position.y + _sy)] = true

	# Direction-aware block rendering for furniture-placed stairs
	for _sentry in parent.stairs_data:
		var _ed  := _sentry as Dictionary
		var _r   := _ed["rect"]      as Rect2i
		var _dir := _ed["direction"] as String
		var _tgt := _ed.get("target", "loft") as String
		var _srx := float(_r.position.x * TILE_SIZE)
		var _sry := float(_r.position.y * TILE_SIZE)
		var _srw := float(_r.size.x    * TILE_SIZE)
		var _srh := float(_r.size.y    * TILE_SIZE)
		var _sfill := STAIR_FILL   if _tgt == "loft" else FSTAIR_FILL
		var _snos  := STAIR_NOSING if _tgt == "loft" else FSTAIR_NOSING
		var _sbdr  := STAIR_BORDER if _tgt == "loft" else FSTAIR_BORDER
		var _sarr  := STAIR_ARROW  if _tgt == "loft" else FSTAIR_ARROW
		draw_rect(Rect2(_srx, _sry, _srw, _srh), _sfill)
		# Internal tread-separator nosings perpendicular to travel direction
		match _dir:
			"north", "south":
				for _s in range(1, _r.size.y / STEP_DEPTH):
					var _ny := _sry + float(_s * STEP_DEPTH * TILE_SIZE)
					draw_line(Vector2(_srx, _ny), Vector2(_srx + _srw, _ny), _snos, 1.5)
			"east", "west":
				for _s in range(1, _r.size.x / STEP_DEPTH):
					var _nx := _srx + float(_s * STEP_DEPTH * TILE_SIZE)
					draw_line(Vector2(_nx, _sry), Vector2(_nx, _sry + _srh), _snos, 1.5)
		# Outer border
		draw_rect(Rect2(_srx, _sry, _srw, _srh), _sbdr, false, 2.0)
		# Ascent arrow; floor stairs also get a second inner chevron (↑↑) to signal full floor
		var _scx := _srx + _srw * 0.5
		var _scy := _sry + _srh * 0.5
		var _aw  := float(TILE_SIZE) * 1.5
		match _dir:
			"north":
				var _tip := Vector2(_scx, _sry + float(TILE_SIZE))
				draw_line(Vector2(_scx, _scy), _tip, _sarr, 2.0)
				if _tgt == "floor":
					var _mid := Vector2(_scx, (_sry + float(TILE_SIZE) + _scy) * 0.5)
					draw_line(_mid, Vector2(_mid.x - _aw * 0.4, _mid.y + _aw * 0.9), _sarr, 1.5)
					draw_line(_mid, Vector2(_mid.x + _aw * 0.4, _mid.y + _aw * 0.9), _sarr, 1.5)
				draw_line(_tip, Vector2(_tip.x - _aw * 0.5, _tip.y + _aw), _sarr, 2.0)
				draw_line(_tip, Vector2(_tip.x + _aw * 0.5, _tip.y + _aw), _sarr, 2.0)
			"south":
				var _tip := Vector2(_scx, _sry + _srh - float(TILE_SIZE))
				draw_line(Vector2(_scx, _scy), _tip, _sarr, 2.0)
				if _tgt == "floor":
					var _mid := Vector2(_scx, (_sry + _srh - float(TILE_SIZE) + _scy) * 0.5)
					draw_line(_mid, Vector2(_mid.x - _aw * 0.4, _mid.y - _aw * 0.9), _sarr, 1.5)
					draw_line(_mid, Vector2(_mid.x + _aw * 0.4, _mid.y - _aw * 0.9), _sarr, 1.5)
				draw_line(_tip, Vector2(_tip.x - _aw * 0.5, _tip.y - _aw), _sarr, 2.0)
				draw_line(_tip, Vector2(_tip.x + _aw * 0.5, _tip.y - _aw), _sarr, 2.0)
			"east":
				var _tip := Vector2(_srx + _srw - float(TILE_SIZE), _scy)
				draw_line(Vector2(_scx, _scy), _tip, _sarr, 2.0)
				if _tgt == "floor":
					var _mid := Vector2((_srx + _srw - float(TILE_SIZE) + _scx) * 0.5, _scy)
					draw_line(_mid, Vector2(_mid.x - _aw * 0.9, _mid.y - _aw * 0.4), _sarr, 1.5)
					draw_line(_mid, Vector2(_mid.x - _aw * 0.9, _mid.y + _aw * 0.4), _sarr, 1.5)
				draw_line(_tip, Vector2(_tip.x - _aw, _tip.y - _aw * 0.5), _sarr, 2.0)
				draw_line(_tip, Vector2(_tip.x - _aw, _tip.y + _aw * 0.5), _sarr, 2.0)
			"west":
				var _tip := Vector2(_srx + float(TILE_SIZE), _scy)
				draw_line(Vector2(_scx, _scy), _tip, _sarr, 2.0)
				if _tgt == "floor":
					var _mid := Vector2((_srx + float(TILE_SIZE) + _scx) * 0.5, _scy)
					draw_line(_mid, Vector2(_mid.x + _aw * 0.9, _mid.y - _aw * 0.4), _sarr, 1.5)
					draw_line(_mid, Vector2(_mid.x + _aw * 0.9, _mid.y + _aw * 0.4), _sarr, 1.5)
				draw_line(_tip, Vector2(_tip.x + _aw, _tip.y - _aw * 0.5), _sarr, 2.0)
				draw_line(_tip, Vector2(_tip.x + _aw, _tip.y + _aw * 0.5), _sarr, 2.0)

	# Per-tile fallback for editor-painted stair_mask tiles (no stairs_data block)
	for _stile in parent.stair_mask:
		if _stile in _sd_tiles:
			continue
		var _t   := _stile as Vector2i
		var _trx := float(_t.x * TILE_SIZE)
		var _tpy := float(_t.y * TILE_SIZE)
		var _ts  := float(TILE_SIZE)
		draw_rect(Rect2(_trx, _tpy, _ts, _ts), STAIR_FILL)
		draw_line(Vector2(_trx, _tpy + 0.5), Vector2(_trx + _ts, _tpy + 0.5), STAIR_NOSING, 2.0)
		if Vector2i(_t.x, _t.y + 1) not in parent.stair_mask:
			draw_line(Vector2(_trx, _tpy + _ts), Vector2(_trx + _ts, _tpy + _ts), STAIR_BORDER, 2.0)
		if Vector2i(_t.x - 1, _t.y) not in parent.stair_mask:
			draw_line(Vector2(_trx, _tpy), Vector2(_trx, _tpy + _ts), STAIR_BORDER, 1.5)
		if Vector2i(_t.x + 1, _t.y) not in parent.stair_mask:
			draw_line(Vector2(_trx + _ts, _tpy), Vector2(_trx + _ts, _tpy + _ts), STAIR_BORDER, 1.5)

	# ── 2d. Stair openings (loft floors — same footprint as floor stair, descent arrow) ─
	const SO_FILL   := Color(0.40, 0.50, 0.80, 0.65)
	const SO_BORDER := Color(0.20, 0.30, 0.70, 1.00)
	const SO_NOSING := Color(0.20, 0.30, 0.70, 0.60)
	const SO_ARROW  := Color(0.05, 0.10, 0.50, 1.00)
	for _op in parent.stair_openings:
		var _opd   := _op as Dictionary
		var _opr   := _opd["rect"] as Rect2i
		var _opdir := _opd.get("direction", "north") as String
		var _srx   := float(_opr.position.x * TILE_SIZE)
		var _sry   := float(_opr.position.y * TILE_SIZE)
		var _srw   := float(_opr.size.x    * TILE_SIZE)
		var _srh   := float(_opr.size.y    * TILE_SIZE)
		var _scx   := _srx + _srw * 0.5
		var _scy   := _sry + _srh * 0.5
		var _aw    := float(TILE_SIZE) * 1.5
		# Draw over the stair footprint (same x/y/w/h as the ground-floor stair block)
		draw_rect(Rect2(_srx, _sry, _srw, _srh), SO_FILL)
		match _opdir:
			"north", "south":
				for _s in range(1, _opr.size.y / STEP_DEPTH):
					var _ny := _sry + float(_s * STEP_DEPTH * TILE_SIZE)
					draw_line(Vector2(_srx, _ny), Vector2(_srx + _srw, _ny), SO_NOSING, 1.5)
			"east", "west":
				for _s in range(1, _opr.size.x / STEP_DEPTH):
					var _nx := _srx + float(_s * STEP_DEPTH * TILE_SIZE)
					draw_line(Vector2(_nx, _sry), Vector2(_nx, _sry + _srh), SO_NOSING, 1.5)
		draw_rect(Rect2(_srx, _sry, _srw, _srh), SO_BORDER, false, 2.0)
		# Arrow pointing in DESCENT direction — mirrors ground-floor arrow but opposite end
		# Ground floor: "north"→↑ tip at top | "south"→↓ tip at bottom
		#               "east"→→ tip at right | "west"→← tip at left
		# Loft descent: flip the tip to the opposite end and flip the chevron
		match _opdir:
			"north":  # descent ↓: tip at bottom, chevron opens upward
				var _tip := Vector2(_scx, _sry + _srh - float(TILE_SIZE))
				draw_line(Vector2(_scx, _sry + float(TILE_SIZE)), _tip, SO_ARROW, 2.5)
				draw_line(_tip, Vector2(_tip.x - _aw * 0.5, _tip.y - _aw), SO_ARROW, 2.0)
				draw_line(_tip, Vector2(_tip.x + _aw * 0.5, _tip.y - _aw), SO_ARROW, 2.0)
			"south":  # descent ↑: tip at top, chevron opens downward
				var _tip := Vector2(_scx, _sry + float(TILE_SIZE))
				draw_line(Vector2(_scx, _sry + _srh - float(TILE_SIZE)), _tip, SO_ARROW, 2.5)
				draw_line(_tip, Vector2(_tip.x - _aw * 0.5, _tip.y + _aw), SO_ARROW, 2.0)
				draw_line(_tip, Vector2(_tip.x + _aw * 0.5, _tip.y + _aw), SO_ARROW, 2.0)
			"east":   # descent ←: tip at left, chevron opens rightward
				var _tip := Vector2(_srx + float(TILE_SIZE), _scy)
				draw_line(Vector2(_srx + _srw - float(TILE_SIZE), _scy), _tip, SO_ARROW, 2.5)
				draw_line(_tip, Vector2(_tip.x + _aw, _tip.y - _aw * 0.5), SO_ARROW, 2.0)
				draw_line(_tip, Vector2(_tip.x + _aw, _tip.y + _aw * 0.5), SO_ARROW, 2.0)
			"west":   # descent →: tip at right, chevron opens leftward
				var _tip := Vector2(_srx + _srw - float(TILE_SIZE), _scy)
				draw_line(Vector2(_srx + float(TILE_SIZE), _scy), _tip, SO_ARROW, 2.5)
				draw_line(_tip, Vector2(_tip.x - _aw, _tip.y - _aw * 0.5), SO_ARROW, 2.0)
				draw_line(_tip, Vector2(_tip.x - _aw, _tip.y + _aw * 0.5), SO_ARROW, 2.0)

	# ── 2e. Rail tracks ──────────────────────────────────────────────────────
	const RAIL_COL  := Color(0.22, 0.70, 0.78, 0.90)
	const RAIL_DASH := Color(0.22, 0.70, 0.78, 0.45)
	for rail in parent.rails:
		var rd := rail as Dictionary
		var x1: int = rd["x1"]; var y1: int = rd["y1"]
		var x2: int = rd["x2"]; var y2: int = rd["y2"]
		var is_h_r := (y1 == y2)
		var mn_xr := mini(x1, x2); var mn_yr := mini(y1, y2)
		var mx_xr := maxi(x1, x2); var mx_yr := maxi(y1, y2)
		var px1 := mn_xr * TILE_SIZE; var py1 := mn_yr * TILE_SIZE
		var px2 := (mx_xr + 1) * TILE_SIZE; var py2 := (mx_yr + 1) * TILE_SIZE
		# Filled channel strip
		draw_rect(Rect2(px1, py1, px2 - px1, py2 - py1), Color(0.22, 0.70, 0.78, 0.18))
		# Double rail lines (parallel to axis)
		var margin := 1.5
		if is_h_r:
			var cy := (py1 + py2) * 0.5
			draw_line(Vector2(px1, cy - margin), Vector2(px2, cy - margin), RAIL_COL, 1.0)
			draw_line(Vector2(px1, cy + margin), Vector2(px2, cy + margin), RAIL_COL, 1.0)
			# Dash marks across the rail
			var tx := px1
			while tx < px2:
				draw_line(Vector2(tx, py1 + 1.5), Vector2(tx, py2 - 1.5), RAIL_DASH, 0.8)
				tx += TILE_SIZE
		else:
			var cx := (px1 + px2) * 0.5
			draw_line(Vector2(cx - margin, py1), Vector2(cx - margin, py2), RAIL_COL, 1.0)
			draw_line(Vector2(cx + margin, py1), Vector2(cx + margin, py2), RAIL_COL, 1.0)
			var ty := py1
			while ty < py2:
				draw_line(Vector2(px1 + 1.5, ty), Vector2(px2 - 1.5, ty), RAIL_DASH, 0.8)
				ty += TILE_SIZE

	# ── 2f. Reveal zones — sub-range of a rail where a piece counts as "revealed"
	const REVEAL_COL := Color(0.90, 0.30, 0.62, 0.85)
	for rz in parent.reveal_zones:
		var zd := rz as Dictionary
		var zx1: int = zd["x1"]; var zy1: int = zd["y1"]
		var zx2: int = zd["x2"]; var zy2: int = zd["y2"]
		var zmn_x := mini(zx1, zx2); var zmn_y := mini(zy1, zy2)
		var zmx_x := maxi(zx1, zx2); var zmx_y := maxi(zy1, zy2)
		var qx1 := zmn_x * TILE_SIZE; var qy1 := zmn_y * TILE_SIZE
		var qx2 := (zmx_x + 1) * TILE_SIZE; var qy2 := (zmx_y + 1) * TILE_SIZE
		draw_rect(Rect2(qx1, qy1, qx2 - qx1, qy2 - qy1), Color(0.90, 0.30, 0.62, 0.22))
		draw_rect(Rect2(qx1, qy1, qx2 - qx1, qy2 - qy1), REVEAL_COL, false, 1.2)

	# ── 3. Blueprint grid — always visible (the defining blueprint element).
	# Fine 10 cm lines get brighter while dragging; 1 m lines are always drawn.
	var fine_col := FINE_COL if show_grid else Color(FINE_COL.r, FINE_COL.g, FINE_COL.b, 0.22)
	var maj_col  := MAJOR_COL if show_grid else Color(MAJOR_COL.r, MAJOR_COL.g, MAJOR_COL.b, 0.40)
	if show_fine:
		for x in range(w + 1):
			if x % METER_TILES != 0:
				draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, hh), fine_col, 1.0)
		for y in range(h + 1):
			if y % METER_TILES != 0:
				draw_line(Vector2(0, y * TILE_SIZE), Vector2(ww, y * TILE_SIZE), fine_col, 1.0)
	for x in range(0, w + 1, METER_TILES):
		draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, hh), maj_col, 2.0)
	for y in range(0, h + 1, METER_TILES):
		draw_line(Vector2(0, y * TILE_SIZE), Vector2(ww, y * TILE_SIZE), maj_col, 2.0)

	# ── 3b. Blueprint sheet border — inset double frame (drafting-sheet feel) ─
	const FRAME_COL := Color(0.56, 0.78, 0.98, 0.70)
	var m1 := 4.0
	var m2 := 7.0
	draw_rect(Rect2(m1, m1, ww - m1 * 2, hh - m1 * 2), FRAME_COL, false, 1.5)
	draw_rect(Rect2(m2, m2, ww - m2 * 2, hh - m2 * 2), Color(FRAME_COL.r, FRAME_COL.g, FRAME_COL.b, 0.35), false, 1.0)

	# ── 4. Natural light hatching (only over painted tiles) ───────────────────
	_draw_natural_light(parent)

	_draw_columns(parent)
	_draw_segments(parent)
	_draw_sloped_ceiling(parent)

	# ── 5. Blueprint annotations: dimension lines + corner title block ────────
	_draw_dimensions(parent, ww, hh)
	_draw_title_block(parent, ww, hh)


# Is this Floor node a real floor plate (worth annotating) vs a subfloor/
# ceiling/roof overlay layer? Real plates carry wall segments or a floor mask.
func _is_plate(parent: Floor) -> bool:
	return not parent.segments.is_empty() or not parent.floor_mask.is_empty()


# Room bounding box (in tiles): prefer the floor mask, fall back to the extent
# of the wall segments, then to the whole grid.
func _room_bounds_tiles(parent: Floor) -> Rect2i:
	var mnx := 1 << 30; var mny := 1 << 30
	var mxx := -(1 << 30); var mxy := -(1 << 30)
	if not parent.floor_mask.is_empty():
		for tile in parent.floor_mask:
			var t := tile as Vector2i
			mnx = mini(mnx, t.x); mny = mini(mny, t.y)
			mxx = maxi(mxx, t.x); mxy = maxi(mxy, t.y)
		return Rect2i(mnx, mny, mxx - mnx + 1, mxy - mny + 1)
	if not parent.segments.is_empty():
		for seg in parent.segments:
			var sd := seg as Dictionary
			for xy in [[sd["x1"], sd["y1"]], [sd["x2"], sd["y2"]]]:
				mnx = mini(mnx, xy[0] as int); mny = mini(mny, xy[1] as int)
				mxx = maxi(mxx, xy[0] as int); mxy = maxi(mxy, xy[1] as int)
		return Rect2i(mnx, mny, mxx - mnx, mxy - mny)
	return Rect2i(0, 0, parent.grid_w, parent.grid_h)


func _draw_dimensions(parent: Floor, ww: int, hh: int) -> void:
	if not _is_plate(parent):
		return
	const DIM_COL := Color(0.62, 0.82, 0.98, 0.85)
	var b := _room_bounds_tiles(parent)
	var font := ThemeDB.fallback_font
	var left   := float(b.position.x * TILE_SIZE)
	var right  := float((b.position.x + b.size.x) * TILE_SIZE)
	var top    := float(b.position.y * TILE_SIZE)
	var bottom := float((b.position.y + b.size.y) * TILE_SIZE)
	var w_m := b.size.x / float(METER_TILES)
	var h_m := b.size.y / float(METER_TILES)

	# Horizontal dim: prefer the side (above/below the room) with more free space
	var gap_above := top
	var gap_below := hh - bottom
	var dy := bottom + 6.0 if gap_below >= gap_above else top - 6.0
	if maxf(gap_above, gap_below) >= 6.0:
		draw_line(Vector2(left, dy), Vector2(right, dy), DIM_COL, 1.0)
		draw_line(Vector2(left, dy - 2), Vector2(left, dy + 2), DIM_COL, 1.0)
		draw_line(Vector2(right, dy - 2), Vector2(right, dy + 2), DIM_COL, 1.0)
		var wtxt := "%.1f m" % w_m
		var wsz := font.get_string_size(wtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 7)
		draw_string(font, Vector2((left + right) * 0.5 - wsz.x * 0.5, dy - 2), wtxt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 7, DIM_COL)

	# Vertical dim: prefer the side (left/right of the room) with more space
	var gap_left  := left
	var gap_right := ww - right
	var dx := right + 6.0 if gap_right >= gap_left else left - 6.0
	if maxf(gap_left, gap_right) >= 6.0:
		draw_line(Vector2(dx, top), Vector2(dx, bottom), DIM_COL, 1.0)
		draw_line(Vector2(dx - 2, top), Vector2(dx + 2, top), DIM_COL, 1.0)
		draw_line(Vector2(dx - 2, bottom), Vector2(dx + 2, bottom), DIM_COL, 1.0)
		var htxt := "%.1f m" % h_m
		draw_string(font, Vector2(dx + 2, (top + bottom) * 0.5 + 3), htxt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 7, DIM_COL)


func _draw_title_block(parent: Floor, ww: int, hh: int) -> void:
	if _gm == null or _gm.current_level.is_empty():
		return
	if not _is_plate(parent):
		return  # skip on overlay-only layers
	var lvl: Dictionary = _gm.current_level
	var font := ThemeDB.fallback_font
	var b := _room_bounds_tiles(parent)
	var area_m2 := b.size.x * b.size.y / float(METER_TILES * METER_TILES)
	var tenant := (lvl.get("tenant", {}) as Dictionary).get("name", "—") as String
	var title := (lvl.get("name", "APARTMENT") as String).to_upper()

	# Block geometry — bottom-right corner, inside the sheet frame
	var bw := 116.0
	var bh := 40.0
	var pad := 8.0
	var bx := ww - bw - pad
	var by := hh - bh - pad

	const BG   := Color(0.055, 0.145, 0.255, 0.92)
	const LINE := Color(0.62, 0.82, 0.98, 0.85)
	const INK  := Color(0.86, 0.94, 1.00, 1.0)
	const MUT  := Color(0.60, 0.76, 0.94, 0.80)
	draw_rect(Rect2(bx, by, bw, bh), BG)
	draw_rect(Rect2(bx, by, bw, bh), LINE, false, 1.2)
	# Title bar
	draw_rect(Rect2(bx, by, bw, 12), Color(0.10, 0.24, 0.40, 0.90))
	draw_line(Vector2(bx, by + 12), Vector2(bx + bw, by + 12), LINE, 1.0)
	draw_string(font, Vector2(bx + 4, by + 9), title, HORIZONTAL_ALIGNMENT_LEFT, bw - 8, 7, INK)
	# Rows
	draw_string(font, Vector2(bx + 4, by + 22), "TENANT", HORIZONTAL_ALIGNMENT_LEFT, 60, 6, MUT)
	draw_string(font, Vector2(bx + 44, by + 22), tenant, HORIZONTAL_ALIGNMENT_LEFT, bw - 48, 7, INK)
	draw_string(font, Vector2(bx + 4, by + 31), "AREA", HORIZONTAL_ALIGNMENT_LEFT, 40, 6, MUT)
	draw_string(font, Vector2(bx + 44, by + 31), "%.1f m2" % area_m2, HORIZONTAL_ALIGNMENT_LEFT, 50, 7, INK)
	# Scale marker, bottom divider
	draw_line(Vector2(bx, by + 34), Vector2(bx + bw, by + 34), Color(LINE.r, LINE.g, LINE.b, 0.4), 0.7)
	draw_string(font, Vector2(bx + 4, by + 39), "SCALE 1:50", HORIZONTAL_ALIGNMENT_LEFT, bw - 8, 6, MUT)


func _draw_edge_overlays(parent: Floor) -> void:
	if parent._use_new_format:
		# New format: highlight the exact segment the mouse is near
		if _hovered_seg_idx < 0:
			return
		var sd := parent.segments[_hovered_seg_idx] as Dictionary
		if sd.get("demolished", false):
			return
		var seg_x1: int = sd["x1"]; var seg_y1: int = sd["y1"]
		var seg_x2: int = sd["x2"]; var seg_y2: int = sd["y2"]
		# A primary (perimeter) segment can be cut by an interior wall meeting
		# it partway along — clip the highlight to just the sub-span under the
		# mouse so a multi-room floor doesn't read as "one giant wall".
		if sd.get("primary", false):
			var bounds := parent.get_room_bounds()
			var edge := ""
			if seg_y1 == seg_y2:
				if seg_y1 == bounds.position.y: edge = "north"
				elif seg_y1 == bounds.position.y + bounds.size.y: edge = "south"
			elif seg_x1 == seg_x2:
				if seg_x1 == bounds.position.x: edge = "west"
				elif seg_x1 == bounds.position.x + bounds.size.x: edge = "east"
			if edge != "":
				var mouse := get_local_mouse_position()
				var coord := int((mouse.x if edge in ["north", "south"] else mouse.y) / float(TILE_SIZE))
				var span := parent.get_wall_span(edge, coord)
				if span.x >= 0:
					if edge in ["north", "south"]:
						seg_x1 = span.x; seg_x2 = span.y
					else:
						seg_y1 = span.x; seg_y2 = span.y
		var p0 := Vector2(float(seg_x1 * TILE_SIZE), float(seg_y1 * TILE_SIZE))
		var p1 := Vector2(float(seg_x2 * TILE_SIZE), float(seg_y2 * TILE_SIZE))
		var seg_glow := Color(EDGE_HOVER.r, EDGE_HOVER.g, EDGE_HOVER.b, 0.25)
		draw_line(p0, p1, seg_glow, WALL_THICK + 8.0)
		draw_line(p0, p1, EDGE_HOVER, WALL_THICK + 2.0)
		return
	# Old format: bounding-box edge lines
	if _hovered_edge == "" and _active_edge == "":
		return
	var x0 := parent._edge_x0; var y0 := parent._edge_y0
	var x1 := parent._edge_x1; var y1 := parent._edge_y1
	var glow := Color(EDGE_ACTIVE.r, EDGE_ACTIVE.g, EDGE_ACTIVE.b, 0.35)
	for _pass in range(2):
		var is_hover := _pass == 0
		var edge := _hovered_edge if is_hover else _active_edge
		if edge == "" or (is_hover and edge == _active_edge):
			continue
		var col   := EDGE_HOVER if is_hover else EDGE_ACTIVE
		var thick := WALL_THICK + (2.0 if is_hover else 1.0)
		var p0 := Vector2.ZERO; var p1 := Vector2.ZERO
		match edge:
			"north": p0 = Vector2(x0, y0); p1 = Vector2(x1, y0)
			"south": p0 = Vector2(x0, y1); p1 = Vector2(x1, y1)
			"west":  p0 = Vector2(x0, y0); p1 = Vector2(x0, y1)
			"east":  p0 = Vector2(x1, y0); p1 = Vector2(x1, y1)
		if not is_hover:
			draw_line(p0, p1, glow, WALL_THICK + 8.0)
		draw_line(p0, p1, col, thick)


func _draw_segments(parent: Floor) -> void:
	# Contrasts against both the cream floor AND the dark canvas background —
	# a near-black ink (previously ~equal to CANVAS_BG) made walls vanish
	# whenever there was no stray floor tile just outside them for contrast.
	const PRIMARY_COL   := Color(0.90, 0.96, 1.00, 1.0)   # bold white blueprint wall
	const SECONDARY_COL := Color(0.62, 0.80, 0.96, 0.90)  # lighter interior partition
	const DEMO_COL      := Color(0.95, 0.55, 0.35, 0.55)  # orange demolition guide
	# Thickness in TILES — walls render as filled tile cells, not lines.
	# Kept at the minimum (1 tile = 10 cm) for both primary and secondary walls
	# so there's no centering/offset math to get wrong — the fill starts
	# exactly at the segment line, matching the (always-centered) hover line
	# closely enough that no gap is visible, regardless of which side a wall
	# faces.
	const PRIMARY_T   := 1
	const SECONDARY_T := 1
	const DOOR_LEN    := 10

	for seg in parent.segments:
		var sd      := seg as Dictionary
		var x1: int  = sd["x1"]; var y1: int = sd["y1"]
		var x2: int  = sd["x2"]; var y2: int = sd["y2"]
		var primary := sd.get("primary",    false) as bool
		var dem     := sd.get("demolished", false) as bool
		var has_dor := sd.get("has_door",   false) as bool
		var dp: int  = sd.get("door_pos",   0)     as int
		var is_h    := (y1 == y2)
		var mn_x    := mini(x1, x2)
		var mn_y    := mini(y1, y2)
		var seg_len := maxi(absi(x2 - x1), absi(y2 - y1))

		var col    := PRIMARY_COL if primary else SECONDARY_COL
		var thick  := PRIMARY_T   if primary else SECONDARY_T      # tiles
		var coff   := 0   # fill starts exactly at the segment line (thickness is 1 tile either way)

		# Demolished → dashed guide line only
		if dem:
			var pa := Vector2(x1 * TILE_SIZE, y1 * TILE_SIZE)
			var pb := Vector2(x2 * TILE_SIZE, y2 * TILE_SIZE)
			draw_dashed_line(pa, pb, DEMO_COL, 2.0, 5.0)
			continue

		# Collect window tile positions: new format (window_tiles array) or old format
		var win_tiles: Array = []
		if sd.has("window_tiles"):
			win_tiles = (sd["window_tiles"] as Array).duplicate()
		elif sd.get("has_window", false) as bool:
			var wp: int = sd.get("window_pos", 0) as int
			var wl: int = sd.get("window_len", 10) as int
			for ti in range(wp, mini(wp + wl, seg_len)):
				win_tiles.append(ti)

		# Merge contiguous window tile runs into gap ranges
		var win_gaps: Array = []
		if not win_tiles.is_empty():
			win_tiles.sort()
			var gs := win_tiles[0] as int; var ge := gs + 1
			for ti in range(1, win_tiles.size()):
				var tp := win_tiles[ti] as int
				if tp == ge:
					ge += 1
				else:
					win_gaps.append([gs, ge])
					gs = tp; ge = tp + 1
			win_gaps.append([gs, ge])

		# Combined gap list (windows + door) sorted by start position
		var gaps: Array = []
		for wg in win_gaps:
			gaps.append([wg[0], wg[1], "window"])
		if has_dor and dp >= 0:
			gaps.append([dp, mini(dp + DOOR_LEN, seg_len), "door"])
		gaps.sort_custom(func(a, b): return a[0] < b[0])

		# Draw wall rect sections (skipping all gaps)
		var pos := 0
		for gap in gaps:
			var gs: int = gap[0]; var ge: int = gap[1]
			if pos < gs:
				draw_rect(_wall_rect(is_h, mn_x, mn_y, x1, y1, pos, gs, coff, thick), col)
			pos = ge
		if pos < seg_len:
			draw_rect(_wall_rect(is_h, mn_x, mn_y, x1, y1, pos, seg_len, coff, thick), col)

		# Diagonal hatch marks inside primary walls (load-bearing indicator)
		if primary:
			var tp := thick * TILE_SIZE
			var step := TILE_SIZE * 3
			if is_h:
				var wy := y1 * TILE_SIZE + coff * TILE_SIZE
				var x  := mn_x * TILE_SIZE
				while x < (mn_x + seg_len) * TILE_SIZE:
					draw_line(Vector2(x, wy), Vector2(x + tp, wy + tp), col, 0.8)
					x += step
			else:
				var wx := x1 * TILE_SIZE + coff * TILE_SIZE
				var y  := mn_y * TILE_SIZE
				while y < (mn_y + seg_len) * TILE_SIZE:
					draw_line(Vector2(wx, y), Vector2(wx + tp, y + tp), col, 0.8)
					y += step

		# Draw gap fills
		for gap in gaps:
			var gs: int = gap[0]; var ge: int = gap[1]
			var gtype: String = gap[2] if gap.size() > 2 else "window"
			if gtype == "window":
				draw_rect(_wall_rect(is_h, mn_x, mn_y, x1, y1, gs, ge, coff, thick), WINDOW_COLOR)
			elif gtype == "door":
				var dtype: String = sd.get("door_type", "swing") as String
				var dr := _wall_rect(is_h, mn_x, mn_y, x1, y1, gs, ge, coff, thick)
				draw_rect(dr, FLOOR_COLOR)
				if dtype == "sliding":
					_draw_sliding_door(dr, is_h)
				else:
					var ds: int  = sd.get("door_side", 1) as int  # +1 south/east, -1 north/west
					var door_px  := DOOR_LEN * TILE_SIZE
					var arc_col  := Color(DOOR_COLOR.r, DOOR_COLOR.g, DOOR_COLOR.b, 0.40)
					if is_h:
						var hinge := Vector2(dr.position.x, y1 * TILE_SIZE)
						if ds > 0:   # opens south
							draw_line(hinge, Vector2(hinge.x, hinge.y + door_px), DOOR_COLOR, 1.2)
							draw_arc(hinge, door_px, 0.0, PI * 0.5, 20, arc_col, 1.0)
						else:        # opens north
							draw_line(hinge, Vector2(hinge.x, hinge.y - door_px), DOOR_COLOR, 1.2)
							draw_arc(hinge, door_px, -PI * 0.5, 0.0, 20, arc_col, 1.0)
					else:
						var hinge := Vector2(x1 * TILE_SIZE, dr.position.y)
						if ds > 0:   # opens east
							draw_line(hinge, Vector2(hinge.x + door_px, hinge.y), DOOR_COLOR, 1.2)
							draw_arc(hinge, door_px, 0.0, PI * 0.5, 20, arc_col, 1.0)
						else:        # opens west
							draw_line(hinge, Vector2(hinge.x - door_px, hinge.y), DOOR_COLOR, 1.2)
							draw_arc(hinge, door_px, PI * 0.5, PI, 20, arc_col, 1.0)

		# Wall-view side indicators — teal arrow per active face (new view_sides dict)
		var vs_dict := sd.get("view_sides", {}) as Dictionary
		# Migrate old single view_side format for display
		if vs_dict.is_empty() and sd.has("view_side"):
			var old_vs := sd.get("view_side", 0) as int
			if old_vs != 0: vs_dict = {str(old_vs): {}}
		if not vs_dict.is_empty():
			const WV_COL  := Color(0.25, 0.82, 0.88, 0.95)
			const TICK_PX := 10
			var mid := seg_len / 2.0
			for sk in vs_dict:
				var vs := (sk as String).to_int()
				if is_h:
					var mx := (mn_x + mid) * TILE_SIZE
					if vs > 0:  # south face
						var fy := float((y1 + thick) * TILE_SIZE)
						draw_line(Vector2(mx, fy), Vector2(mx, fy + TICK_PX), WV_COL, 2.5)
						draw_line(Vector2(mx, fy + TICK_PX), Vector2(mx - 4, fy + TICK_PX - 5), WV_COL, 2.0)
						draw_line(Vector2(mx, fy + TICK_PX), Vector2(mx + 4, fy + TICK_PX - 5), WV_COL, 2.0)
					else:       # north face
						var fy := float(y1 * TILE_SIZE)
						draw_line(Vector2(mx, fy), Vector2(mx, fy - TICK_PX), WV_COL, 2.5)
						draw_line(Vector2(mx, fy - TICK_PX), Vector2(mx - 4, fy - TICK_PX + 5), WV_COL, 2.0)
						draw_line(Vector2(mx, fy - TICK_PX), Vector2(mx + 4, fy - TICK_PX + 5), WV_COL, 2.0)
				else:
					var my := (mn_y + mid) * TILE_SIZE
					if vs > 0:  # east face
						var fx := float((x1 + thick) * TILE_SIZE)
						draw_line(Vector2(fx, my), Vector2(fx + TICK_PX, my), WV_COL, 2.5)
						draw_line(Vector2(fx + TICK_PX, my), Vector2(fx + TICK_PX - 5, my - 4), WV_COL, 2.0)
						draw_line(Vector2(fx + TICK_PX, my), Vector2(fx + TICK_PX - 5, my + 4), WV_COL, 2.0)
					else:       # west face
						var fx := float(x1 * TILE_SIZE)
						draw_line(Vector2(fx, my), Vector2(fx - TICK_PX, my), WV_COL, 2.5)
						draw_line(Vector2(fx - TICK_PX, my), Vector2(fx - TICK_PX + 5, my - 4), WV_COL, 2.0)
						draw_line(Vector2(fx - TICK_PX, my), Vector2(fx - TICK_PX + 5, my + 4), WV_COL, 2.0)


# Sliding door: no swing arc (nothing to collide with) — drawn as a recessed
# track with a single leaf, matching the rail-furniture visual language.
func _draw_sliding_door(dr: Rect2, is_h: bool) -> void:
	const TRACK_COL := Color(0.30, 0.68, 0.72, 0.90)
	const PANEL_COL := Color(0.30, 0.68, 0.72, 0.45)
	if is_h:
		var cy := dr.position.y + dr.size.y * 0.5
		draw_line(Vector2(dr.position.x, cy - 1.5), Vector2(dr.end.x, cy - 1.5), TRACK_COL, 1.0)
		draw_line(Vector2(dr.position.x, cy + 1.5), Vector2(dr.end.x, cy + 1.5), TRACK_COL, 1.0)
		draw_rect(Rect2(dr.position.x, dr.position.y, dr.size.x * 0.55, dr.size.y), PANEL_COL)
	else:
		var cx := dr.position.x + dr.size.x * 0.5
		draw_line(Vector2(cx - 1.5, dr.position.y), Vector2(cx - 1.5, dr.end.y), TRACK_COL, 1.0)
		draw_line(Vector2(cx + 1.5, dr.position.y), Vector2(cx + 1.5, dr.end.y), TRACK_COL, 1.0)
		draw_rect(Rect2(dr.position.x, dr.position.y, dr.size.x, dr.size.y * 0.55), PANEL_COL)


# Returns the pixel Rect2 for a wall section [from_t .. to_t] along the segment.
# coff = cross-axis tile offset from the edge; thick = cross-axis tiles.
func _wall_rect(is_h: bool, mn_x: int, mn_y: int, x1: int, y1: int,
				from_t: int, to_t: int, coff: int, thick: int) -> Rect2:
	var len_px  := (to_t - from_t) * TILE_SIZE
	var thick_px := thick * TILE_SIZE
	if is_h:
		return Rect2(
			(mn_x + from_t) * TILE_SIZE,
			y1 * TILE_SIZE + coff * TILE_SIZE,
			len_px, thick_px)
	else:
		return Rect2(
			x1 * TILE_SIZE + coff * TILE_SIZE,
			(mn_y + from_t) * TILE_SIZE,
			thick_px, len_px)


func _draw_diagonal_splits(parent: Floor) -> void:
	# When a wall item's floor shadow overlaps a floor furniture tile,
	# render the floor furniture color in the lower-left triangle and
	# the wall item color in the upper-right triangle of that tile.
	if not _gm:
		return

	var bounds := parent.get_room_bounds()

	# Build a map of wall-item shadow tiles → color for each edge
	var wall_shadow: Dictionary = {}  # Vector2i → Color
	for edge in parent.wall_items:
		var items: Dictionary = parent.wall_items[edge] as Dictionary
		for origin in items:
			var o      := origin as Vector2i   # local to the wall — 0 at the wall's start
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
						"north": tile = Vector2i(bounds.position.x + o.x + ix, bounds.position.y + iy)
						"south": tile = Vector2i(bounds.position.x + o.x + ix, bounds.position.y + bounds.size.y - 1 - iy)
						"west":  tile = Vector2i(bounds.position.x + iy, bounds.position.y + o.x + ix)
						"east":  tile = Vector2i(bounds.position.x + bounds.size.x - 1 - iy, bounds.position.y + o.x + ix)
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


func _draw_wall_items(parent: Floor, _rw: int, _rh: int) -> void:
	if not _gm:
		return
	var bounds := parent.get_room_bounds()
	var ghost      := parent._wall_drag_ghost
	var ghost_edge := ghost.get("edge", "") as String
	var ghost_origin: Vector2i = ghost.get("origin", Vector2i(-999999, -999999)) as Vector2i
	for edge in parent.wall_items:
		var items: Dictionary = parent.wall_items[edge] as Dictionary
		for origin in items:
			var o := origin as Vector2i   # local to the wall — 0 at the wall's start
			if edge == ghost_edge and o == ghost_origin:
				continue   # being dragged right now — drawn as a ghost below instead
			_draw_one_wall_item(bounds, edge, o, items[origin] as String, 0.85)
	if not ghost.is_empty():
		_draw_one_wall_item(bounds, ghost_edge, ghost_origin, ghost.get("fid", "") as String, 0.5)


func _draw_one_wall_item(bounds: Rect2i, edge: String, o: Vector2i, fid: String, alpha: float) -> void:
	var fdata := _gm.get_furniture_by_id(fid)
	if fdata.is_empty():
		return
	var iw: int    = fdata["size"]["w"] as int
	var depth: int = fdata.get("floor_depth", 1) as int
	var col        := Color("#" + (fdata.get("color", "aaaaaa") as String))
	col.a = alpha
	var rect: Rect2
	match edge:
		"north":
			rect = Rect2((bounds.position.x + o.x) * TILE_SIZE, bounds.position.y * TILE_SIZE,
				iw * TILE_SIZE, depth * TILE_SIZE)
		"south":
			rect = Rect2((bounds.position.x + o.x) * TILE_SIZE,
				(bounds.position.y + bounds.size.y) * TILE_SIZE - depth * TILE_SIZE,
				iw * TILE_SIZE, depth * TILE_SIZE)
		"west":
			rect = Rect2(bounds.position.x * TILE_SIZE,
				(bounds.position.y + bounds.size.y - o.x - iw) * TILE_SIZE,
				depth * TILE_SIZE, iw * TILE_SIZE)
		"east":
			rect = Rect2((bounds.position.x + bounds.size.x) * TILE_SIZE - depth * TILE_SIZE,
				(bounds.position.y + o.x) * TILE_SIZE, depth * TILE_SIZE, iw * TILE_SIZE)
		_:
			return
	draw_rect(rect, col)
	draw_rect(rect, Color(0, 0, 0, 0.40), false, 1.0)


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

	var bounds := parent.get_room_bounds()
	var room_x0 := bounds.position.x * TILE_SIZE
	var room_y0 := bounds.position.y * TILE_SIZE
	var room_x1 := (bounds.position.x + bounds.size.x) * TILE_SIZE
	var room_y1 := (bounds.position.y + bounds.size.y) * TILE_SIZE
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
			draw_dashed_line(Vector2(px, room_y0), Vector2(px, room_y1), CONTOUR_COL, 0.8, 5.0)
			if si % 2 == 0:
				draw_string(ThemeDB.fallback_font, Vector2(px + 2, room_y0 + 12), "%.1fm" % h_at,
					HORIZONTAL_ALIGNMENT_LEFT, 32, 9, CONTOUR_COL)
		else:
			draw_dashed_line(Vector2(room_x0, px), Vector2(room_x1, px), CONTOUR_COL, 0.8, 5.0)
			if si % 2 == 0:
				draw_string(ThemeDB.fallback_font, Vector2(room_x0 + 2, px - 2), "%.1fm" % h_at,
					HORIZONTAL_ALIGNMENT_LEFT, 32, 9, CONTOUR_COL)

	# Low-ceiling blocked zone overlay (min_h < 2.0 m blocks tall furniture)
	if min_h < 2.0:
		var frac_2m := (2.0 - min_h) / (max_h - min_h)
		var px_2m := int((low_s + frac_2m * span) * TILE_SIZE)
		if axis == "x":
			draw_rect(Rect2(room_x0, room_y0, px_2m - room_x0, room_y1 - room_y0), Color(0.25, 0.30, 0.50, 0.07))
		else:
			draw_rect(Rect2(room_x0, room_y0, room_x1 - room_x0, px_2m - room_y0), Color(0.25, 0.30, 0.50, 0.07))

	_draw_slope_info(axis, low_s, high_e, min_h, max_h, span, room_x0, room_y0, room_x1, room_y1)


func _draw_slope_info(axis: String, low_s: int, high_e: int, min_h: float,
		max_h: float, span: int, room_x0: int, room_y0: int, room_x1: int, room_y1: int) -> void:
	const START_COL := Color(0.30, 0.42, 0.62, 0.9)
	const END_COL   := Color(0.62, 0.30, 0.30, 0.9)
	const INFO_COL  := Color(0.15, 0.15, 0.18, 1.0)
	const INFO_BG    := Color(0.93, 0.93, 0.90, 0.85)

	var span_m := float(span) / METER_TILES
	var angle_deg := rad_to_deg(atan2(max_h - min_h, span_m)) if span_m > 0.0 else 0.0

	var px_start := low_s * TILE_SIZE
	var px_end   := high_e * TILE_SIZE

	var label := "%.1f° slope  |  %.2fm → %.2fm over %.1fm  (tiles %d–%d)" % \
		[angle_deg, min_h, max_h, span_m, low_s, high_e]

	if axis == "x":
		draw_line(Vector2(px_start, room_y0), Vector2(px_start, room_y1), START_COL, 2.0)
		draw_string(ThemeDB.fallback_font, Vector2(px_start + 4, room_y1 - 6),
			"%.2fm" % min_h, HORIZONTAL_ALIGNMENT_LEFT, 90, 12, START_COL)
		draw_line(Vector2(px_end, room_y0), Vector2(px_end, room_y1), END_COL, 2.0)
		draw_string(ThemeDB.fallback_font, Vector2(px_end - 46, room_y1 - 6),
			"%.2fm" % max_h, HORIZONTAL_ALIGNMENT_RIGHT, 90, 12, END_COL)
		draw_rect(Rect2(room_x0, room_y0 - 16, room_x1 - room_x0, 15), INFO_BG)
		draw_string(ThemeDB.fallback_font, Vector2(room_x0 + 4, room_y0 - 5),
			label, HORIZONTAL_ALIGNMENT_LEFT, room_x1 - room_x0 - 8, 11, INFO_COL)
	else:
		draw_line(Vector2(room_x0, px_start), Vector2(room_x1, px_start), START_COL, 2.0)
		draw_string(ThemeDB.fallback_font, Vector2(room_x0 + 4, px_start - 4),
			"%.2fm" % min_h, HORIZONTAL_ALIGNMENT_LEFT, 90, 12, START_COL)
		draw_line(Vector2(room_x0, px_end), Vector2(room_x1, px_end), END_COL, 2.0)
		draw_string(ThemeDB.fallback_font, Vector2(room_x0 + 4, px_end + 14),
			"%.2fm" % max_h, HORIZONTAL_ALIGNMENT_LEFT, 90, 12, END_COL)
		draw_rect(Rect2(room_x1 + 2, room_y0, 160, 15), INFO_BG)
		draw_string(ThemeDB.fallback_font, Vector2(room_x1 + 6, room_y0 + 11),
			label, HORIZONTAL_ALIGNMENT_LEFT, 154, 11, INFO_COL)


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
	# Structural column: filled white square with an X (standard blueprint symbol)
	const COL_COL  := Color(0.86, 0.94, 1.00, 1.0)
	const COL_H    := Color(0.30, 0.50, 0.72, 0.90)
	for col in parent.columns:
		var cx: int = col["x"] as int
		var cy: int = col["y"] as int
		var r := Rect2(cx * TILE_SIZE, cy * TILE_SIZE, TILE_SIZE, TILE_SIZE)
		draw_rect(r, COL_COL)
		draw_rect(r, COL_H, false, 1.5)
		draw_line(r.position + Vector2(2, 2), r.end - Vector2(2, 2), Color(0.10, 0.24, 0.40, 0.55), 1.0)
		draw_line(r.position + Vector2(r.size.x - 2, 2), r.position + Vector2(2, r.size.y - 2), Color(0.10, 0.24, 0.40, 0.55), 1.0)


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
			var col := Color(0.02, 0.06, 0.13, t * MAX_ALPHA)

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
