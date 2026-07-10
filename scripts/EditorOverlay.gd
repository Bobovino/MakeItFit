extends Node2D

const TS := 8

var p_start:     Vector2i = Vector2i(-1, -1)
var p_end:       Vector2i = Vector2i(-1, -1)
var active:      bool     = false
var floor_hover: Vector2i = Vector2i(-1, -1)
var mezz_hover:  bool     = false  # true = floor_hover is a mezzanine tile
var floor_brush: int      = 1     # 1 = tile, 10 = meter cell
var wall_hover:   Vector2i = Vector2i(-1, -1)
var wall_primary: bool    = false  # true = primary (2 tiles), false = secondary (1 tile)
var win_hover_rect: Rect2 = Rect2()
var rail_mode:   bool = false  # true = preview is a rail (teal) not a wall (orange)
var reveal_mode: bool = false  # true = preview is a reveal zone (rose) marker
var stair_hover:        bool    = false    # legacy (unused)
var stair_hover_rect:   Rect2i = Rect2i() # full footprint of stair being previewed
var stair_hover_dir:    String = "north"  # direction for preview arrow
var stair_hover_target: String = "loft"   # "loft" (blue) or "floor" (amber)

# Door drag preview
var door_drag_active: bool    = false
var door_drag_hinge:  Vector2 = Vector2.ZERO
var door_drag_is_h:   bool    = true
var door_drag_side:   int     = 1      # +1 south/east, -1 north/west
var door_drag_len:    float   = 80.0   # door length in pixels

# Wall-view side drag preview
var wv_drag_active: bool    = false
var wv_drag_hinge:  Vector2 = Vector2.ZERO
var wv_drag_is_h:   bool    = true
var wv_drag_side:   int     = 1       # +1 south/east, -1 north/west
var wv_drag_thick:  int     = 1       # wall thickness in tiles

# Pre-placed furniture overlay
var placed_furniture: Array = []  # [{x,y,w,h,col}]

# Furniture placement preview
var placing_active: bool    = false
var placing_x:      int     = 0
var placing_y:      int     = 0
var placing_w:      int     = 5
var placing_h:      int     = 5
var placing_col:    Color   = Color.WHITE


func _draw() -> void:
	const COL_FILL   := Color(0.62, 0.42, 0.18, 0.30)
	const COL_BORDER := Color(0.62, 0.42, 0.18, 0.90)
	const RAIL_FILL  := Color(0.20, 0.65, 0.70, 0.30)
	const RAIL_BDR   := Color(0.25, 0.80, 0.85, 0.90)
	const REVEAL_FILL := Color(0.80, 0.25, 0.55, 0.30)
	const REVEAL_BDR  := Color(0.95, 0.35, 0.68, 0.90)

	# Floor-paint / mezzanine / stairs hover highlight — brush centred on cursor
	# Offset uses integer division (floor_brush/2) to match _paint_*_tile() exactly
	if floor_hover.x >= 0:
		var sz     := float(floor_brush * TS)
		var half_px := float((floor_brush / 2) * TS)
		var px := float(floor_hover.x * TS) - half_px
		var py := float(floor_hover.y * TS) - half_px
		if mezz_hover:
			draw_rect(Rect2(px, py, sz, sz), Color(0.72, 0.60, 0.20, 0.35))
			draw_rect(Rect2(px, py, sz, sz), Color(0.80, 0.65, 0.22, 0.90), false, 1.0)
		elif stair_hover:
			# stair_hover_rect overrides the floor_hover brush square
			pass  # handled below
		else:
			draw_rect(Rect2(px, py, sz, sz), Color(0.40, 0.72, 0.52, 0.30))
			draw_rect(Rect2(px, py, sz, sz), Color(0.40, 0.82, 0.54, 0.90), false, 1.0)

	# Stair stamp hover preview — shows the full staircase footprint + direction arrow
	if stair_hover and stair_hover_rect.size.x > 0 and stair_hover_rect.size.y > 0:
		var _SF := Color(0.52, 0.60, 0.82, 0.35) if stair_hover_target == "loft" else Color(0.78, 0.58, 0.22, 0.35)
		var _SB := Color(0.30, 0.50, 0.90, 0.90) if stair_hover_target == "loft" else Color(0.85, 0.55, 0.10, 0.90)
		var _SN := Color(0.30, 0.40, 0.75, 0.65) if stair_hover_target == "loft" else Color(0.60, 0.38, 0.08, 0.65)
		var _SA := Color(0.10, 0.20, 0.60, 0.90) if stair_hover_target == "loft" else Color(0.50, 0.28, 0.05, 0.90)
		const _SD  := 2   # step depth in tiles
		var _sx  := float(stair_hover_rect.position.x * TS)
		var _sy  := float(stair_hover_rect.position.y * TS)
		var _sw  := float(stair_hover_rect.size.x * TS)
		var _sh  := float(stair_hover_rect.size.y * TS)
		draw_rect(Rect2(_sx, _sy, _sw, _sh), _SF)
		draw_rect(Rect2(_sx, _sy, _sw, _sh), _SB, false, 1.5)
		match stair_hover_dir:
			"north", "south":
				for _ss in range(1, stair_hover_rect.size.y / _SD):
					var _ny := _sy + float(_ss * _SD * TS)
					draw_line(Vector2(_sx, _ny), Vector2(_sx + _sw, _ny), _SN, 1.0)
			"east", "west":
				for _ss in range(1, stair_hover_rect.size.x / _SD):
					var _nx := _sx + float(_ss * _SD * TS)
					draw_line(Vector2(_nx, _sy), Vector2(_nx, _sy + _sh), _SN, 1.0)
		var _scx := _sx + _sw * 0.5
		var _scy := _sy + _sh * 0.5
		var _aw  := float(TS) * 1.5
		match stair_hover_dir:
			"north":
				var _tip := Vector2(_scx, _sy + float(TS))
				draw_line(Vector2(_scx, _scy), _tip, _SA, 2.0)
				draw_line(_tip, Vector2(_tip.x - _aw * 0.5, _tip.y + _aw), _SA, 2.0)
				draw_line(_tip, Vector2(_tip.x + _aw * 0.5, _tip.y + _aw), _SA, 2.0)
			"south":
				var _tip := Vector2(_scx, _sy + _sh - float(TS))
				draw_line(Vector2(_scx, _scy), _tip, _SA, 2.0)
				draw_line(_tip, Vector2(_tip.x - _aw * 0.5, _tip.y - _aw), _SA, 2.0)
				draw_line(_tip, Vector2(_tip.x + _aw * 0.5, _tip.y - _aw), _SA, 2.0)
			"east":
				var _tip := Vector2(_sx + _sw - float(TS), _scy)
				draw_line(Vector2(_scx, _scy), _tip, _SA, 2.0)
				draw_line(_tip, Vector2(_tip.x - _aw, _tip.y - _aw * 0.5), _SA, 2.0)
				draw_line(_tip, Vector2(_tip.x - _aw, _tip.y + _aw * 0.5), _SA, 2.0)
			"west":
				var _tip := Vector2(_sx + float(TS), _scy)
				draw_line(Vector2(_scx, _scy), _tip, _SA, 2.0)
				draw_line(_tip, Vector2(_tip.x + _aw, _tip.y - _aw * 0.5), _SA, 2.0)
				draw_line(_tip, Vector2(_tip.x + _aw, _tip.y + _aw * 0.5), _SA, 2.0)

	# Pre-placed furniture rectangles (always visible)
	for pf in placed_furniture:
		var fd := pf as Dictionary
		var rx := float((fd["x"] as int) * TS)
		var ry := float((fd["y"] as int) * TS)
		var rw := float((fd["w"] as int) * TS)
		var rh := float((fd["h"] as int) * TS)
		var fc := fd["col"] as Color
		draw_rect(Rect2(rx, ry, rw, rh), Color(fc.r, fc.g, fc.b, 0.30))
		draw_rect(Rect2(rx, ry, rw, rh), Color(fc.r, fc.g, fc.b, 0.85), false, 1.0)

	# Furniture placement preview at cursor (always visible)
	if placing_active:
		var rx := float(placing_x * TS)
		var ry := float(placing_y * TS)
		var rw := float(placing_w * TS)
		var rh := float(placing_h * TS)
		draw_rect(Rect2(rx, ry, rw, rh), Color(placing_col.r, placing_col.g, placing_col.b, 0.40))
		draw_rect(Rect2(rx, ry, rw, rh), placing_col, false, 1.5)

	var thick := 2 if wall_primary else 1  # tiles

	var fill_col   := REVEAL_FILL if reveal_mode else (RAIL_FILL if rail_mode else COL_FILL)
	var border_col := REVEAL_BDR  if reveal_mode else (RAIL_BDR  if rail_mode else COL_BORDER)
	var rail_thick := 1 if (rail_mode or reveal_mode) else thick  # rails/reveal zones are always 1 tile thin

	# Wall/rail hover rect — shows where segment would start before LMB pressed
	if not active and wall_hover.x >= 0:
		var hover_r := Rect2(wall_hover.x * TS, wall_hover.y * TS, TS * rail_thick, TS * rail_thick)
		draw_rect(hover_r, fill_col)
		draw_rect(hover_r, border_col, false, 1.0)
		return

	# Wall/rail segment preview rect while dragging
	if not active or p_start.x < 0:
		return

	var is_h := (p_start.y == p_end.y)
	var mn_x  := mini(p_start.x, p_end.x)
	var mn_y  := mini(p_start.y, p_end.y)
	var mx_x  := maxi(p_start.x, p_end.x)
	var mx_y  := maxi(p_start.y, p_end.y)

	var r: Rect2
	if is_h:
		r = Rect2(mn_x * TS, p_start.y * TS,
				  (mx_x - mn_x) * TS, rail_thick * TS)
	else:
		r = Rect2(p_start.x * TS, mn_y * TS,
				  rail_thick * TS, (mx_y - mn_y) * TS)

	if r.size.x > 0 and r.size.y > 0:
		draw_rect(r, fill_col)
		draw_rect(r, border_col, false, 1.5)
		if rail_mode or reveal_mode:
			# Dashed centre line to distinguish rail/reveal zone from wall
			var dash_col := REVEAL_BDR if reveal_mode else RAIL_BDR
			var step := 4
			if is_h:
				var cy := r.position.y + r.size.y * 0.5
				var x := r.position.x
				while x < r.end.x - 2:
					draw_line(Vector2(x, cy), Vector2(minf(x + step, r.end.x), cy),
							  dash_col, 1.0)
					x += step * 2
			else:
				var cx := r.position.x + r.size.x * 0.5
				var y := r.position.y
				while y < r.end.y - 2:
					draw_line(Vector2(cx, y), Vector2(cx, minf(y + step, r.end.y)),
							  dash_col, 1.0)
					y += step * 2

	# Window hover tile
	if win_hover_rect.size.x > 0:
		draw_rect(win_hover_rect, Color(0.28, 0.55, 0.85, 0.40))
		draw_rect(win_hover_rect, Color(0.45, 0.72, 1.00, 0.90), false, 1.5)

	# Door drag preview — arc showing which side the door will open toward
	if door_drag_active:
		var dh  := door_drag_hinge
		var drl := door_drag_len
		var dtip: Vector2
		var da0: float; var da1: float
		if door_drag_is_h:
			if door_drag_side > 0:  # opens south
				dtip = Vector2(dh.x, dh.y + drl)
				da0 = 0.0; da1 = PI * 0.5
			else:                   # opens north
				dtip = Vector2(dh.x, dh.y - drl)
				da0 = -PI * 0.5; da1 = 0.0
		else:
			if door_drag_side > 0:  # opens east
				dtip = Vector2(dh.x + drl, dh.y)
				da0 = 0.0; da1 = PI * 0.5
			else:                   # opens west
				dtip = Vector2(dh.x - drl, dh.y)
				da0 = PI * 0.5; da1 = PI
		draw_line(dh, dtip, Color(0.85, 0.60, 0.20, 0.90), 1.5)
		draw_arc(dh, drl, da0, da1, 24, Color(0.85, 0.60, 0.20, 0.30), 1.0)

	# Wall-view side drag preview — perpendicular arrow from the chosen face
	if wv_drag_active:
		const WV_COL := Color(0.25, 0.82, 0.88, 0.92)
		const WV_LEN := 20.0
		var half_t := wv_drag_thick * TS * 0.5
		var base2: Vector2; var tip2: Vector2
		if wv_drag_is_h:
			if wv_drag_side > 0:   # south face
				base2 = Vector2(wv_drag_hinge.x, wv_drag_hinge.y + half_t)
				tip2  = Vector2(wv_drag_hinge.x, wv_drag_hinge.y + half_t + WV_LEN)
			else:                  # north face
				base2 = Vector2(wv_drag_hinge.x, wv_drag_hinge.y - half_t)
				tip2  = Vector2(wv_drag_hinge.x, wv_drag_hinge.y - half_t - WV_LEN)
		else:
			if wv_drag_side > 0:   # east face
				base2 = Vector2(wv_drag_hinge.x + half_t, wv_drag_hinge.y)
				tip2  = Vector2(wv_drag_hinge.x + half_t + WV_LEN, wv_drag_hinge.y)
			else:                  # west face
				base2 = Vector2(wv_drag_hinge.x - half_t, wv_drag_hinge.y)
				tip2  = Vector2(wv_drag_hinge.x - half_t - WV_LEN, wv_drag_hinge.y)
		draw_line(base2, tip2, WV_COL, 2.0)
		var dir := (tip2 - base2).normalized()
		var perp := Vector2(-dir.y, dir.x)
		draw_line(tip2, tip2 - dir * 6.0 + perp * 4.5, WV_COL, 2.0)
		draw_line(tip2, tip2 - dir * 6.0 - perp * 4.5, WV_COL, 2.0)
