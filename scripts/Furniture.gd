extends Node2D
class_name Furniture

signal placed(furniture_node: Node2D)
signal sell_requested(furniture_node: Furniture)
signal fold_toggled

const TILE_SIZE := 8

func _play(sound: String) -> void:
	var am := get_node_or_null("/root/Audio")
	if am:
		am.play(sound)

var furniture_id: String = ""
var grid_w: int = 1
var grid_h: int = 1
var grid_pos: Vector2i = Vector2i.ZERO
var functions: Array = []
var buy_price: int = 0
var sell_price: int = 0
var furniture_name: String = ""
var ghost_radius: int = 0   # interaction/clearance zone in tiles (0 = none)
var foldable: bool = false
var is_extended: bool = false
var extended_add_h: int = 0           # extra tiles in +Y when fully extended
var folded_functions_arr:   Array = []
var extended_functions_arr: Array = []
var _base_grid_h: int = 1             # grid_h when folded

var height_category: String = "medium"  # "low" | "medium" | "tall"
var z_bottom: float = 0.0  # tiles from floor level
var z_top:    float = 12.0 # tiles from floor level
var needs_water: bool = false
var needs_power: bool = false

# Rail: constrains dragging to one axis
var rail_axis: String = ""   # "h" | "v" | "" = free
var _rail_lock: int   = -1   # locked row (h) or column (v) set on drag start

static var test_mode_active: bool = false
var _extended_conflict: bool = false

var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _original_pos: Vector2 = Vector2.ZERO
var _wall_ref: Floor = null
var _color: Color = Color.WHITE
var _accessible: bool = true

# Keep rect reference for mouse-over size lookup; hidden visually.
@onready var rect: ColorRect = $ColorRect
@onready var label: Label = $ColorRect/Label


func setup(data: Dictionary, apt_floor: Floor) -> void:
	furniture_id = data["id"]
	furniture_name = data["name"]
	grid_w = data["size"]["w"]
	grid_h = data["size"]["h"]
	functions = data["functions"].duplicate()
	buy_price = data["buy_price"]
	sell_price = data["sell_price"]
	ghost_radius          = data.get("ghost_radius",      0)        as int
	foldable              = data.get("foldable",          false)    as bool
	extended_add_h        = data.get("extended_add_h",    0)        as int
	folded_functions_arr  = (data.get("folded_functions",   []) as Array).duplicate()
	extended_functions_arr = (data.get("extended_functions", []) as Array).duplicate()
	height_category       = data.get("height_category",   "medium") as String
	z_bottom = data.get("z_bottom", 0.0) as float
	match height_category:
		"low":  z_top = data.get("z_top",  6.0) as float
		"tall": z_top = data.get("z_top", 24.0) as float
		_:      z_top = data.get("z_top", 12.0) as float
	needs_water           = data.get("needs_water",       false)    as bool
	needs_power           = data.get("needs_power",       false)    as bool
	rail_axis             = data.get("rail_axis",         "")       as String
	_base_grid_h          = grid_h
	_wall_ref = apt_floor
	_color = Color("#" + data.get("color", "888888"))

	rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	rect.visible = false  # drawing handled in _draw()

	queue_redraw()


func set_accessible(is_accessible: bool) -> void:
	if _accessible != is_accessible:
		_accessible = is_accessible
		queue_redraw()


func set_extended_conflict(conflict: bool) -> void:
	_extended_conflict = conflict
	queue_redraw()


func toggle_fold() -> bool:
	if not foldable or extended_add_h <= 0 or not _wall_ref:
		return false
	if is_extended:
		# Fold back: shrink footprint
		grid_h = _base_grid_h
		is_extended = false
		functions = folded_functions_arr.duplicate() if not folded_functions_arr.is_empty() else functions
		_wall_ref.place_furniture(self, grid_pos)
	else:
		# Try to extend: check for space in the extra rows
		grid_h = _base_grid_h + extended_add_h
		if not _wall_ref.can_place(self, grid_pos):
			grid_h = _base_grid_h   # restore — no room
			return false
		is_extended = true
		functions = extended_functions_arr.duplicate() if not extended_functions_arr.is_empty() else functions
		_wall_ref.place_furniture(self, grid_pos)
	rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	queue_redraw()
	fold_toggled.emit()
	return true


func _draw() -> void:
	var w := grid_w * TILE_SIZE
	var h := grid_h * TILE_SIZE
	var ink := Color(0.16, 0.13, 0.10, 0.85)

	# Base fill + crisp outline
	draw_rect(Rect2(0, 0, w, h), _color)
	draw_rect(Rect2(0, 0, w, h), ink, false, 1.5)

	# Architectural symbol
	_draw_symbol(w, h, ink)

	# Name label
	draw_string(ThemeDB.fallback_font, Vector2(3, 9), furniture_name,
		HORIZONTAL_ALIGNMENT_LEFT, w - 6, 7,
		Color(ink.r, ink.g, ink.b, 0.90))

	# Ghost interaction zone — dashed amber outline shown while dragging
	if _dragging and ghost_radius > 0:
		var gr  := ghost_radius * TILE_SIZE
		var gc  := Color(0.95, 0.78, 0.22, 0.60)
		var pts := [Vector2(-gr, -gr), Vector2(w + gr, -gr),
					Vector2(w + gr, h + gr), Vector2(-gr, h + gr), Vector2(-gr, -gr)]
		for i in range(pts.size() - 1):
			draw_dashed_line(pts[i], pts[i + 1], gc, 1.2, 4.0)
		draw_rect(Rect2(-gr, -gr, w + gr * 2, h + gr * 2), Color(0.95, 0.78, 0.22, 0.04))

	# Foldable states
	if foldable and extended_add_h > 0:
		var ext_h := extended_add_h * TILE_SIZE
		if is_extended:
			# Show fold boundary line so user knows the base footprint
			var base_y := float(_base_grid_h * TILE_SIZE)
			draw_dashed_line(Vector2(0, base_y), Vector2(w, base_y),
				Color(ink.r, ink.g, ink.b, 0.50), 1.0, 4.0)
			# Double-click hint
			draw_string(ThemeDB.fallback_font, Vector2(3, base_y + 8),
				"▲ FOLD", HORIZONTAL_ALIGNMENT_LEFT, w - 6, 6,
				Color(ink.r, ink.g, ink.b, 0.55))
		elif test_mode_active:
			# Dashed preview of extended zone (not currently extended)
			var ec    := Color(0.88, 0.10, 0.10, 0.45) if _extended_conflict else Color(_color.r, _color.g, _color.b, 0.32)
			var ec_bd := Color(0.88, 0.10, 0.10, 0.85) if _extended_conflict else Color(_color.r * 0.8, _color.g * 0.8, _color.b * 0.8, 0.70)
			draw_rect(Rect2(0, h, w, ext_h), ec)
			draw_dashed_line(Vector2(0, h),         Vector2(w, h),         ec_bd, 1.5, 5.0)
			draw_dashed_line(Vector2(0, h),         Vector2(0, h + ext_h), ec_bd, 1.0, 4.0)
			draw_dashed_line(Vector2(w, h),         Vector2(w, h + ext_h), ec_bd, 1.0, 4.0)
			draw_dashed_line(Vector2(0, h + ext_h), Vector2(w, h + ext_h), ec_bd, 1.5, 5.0)
			draw_string(ThemeDB.fallback_font, Vector2(3, h + 9),
				"▼ CLICK TO UNFOLD", HORIZONTAL_ALIGNMENT_LEFT, w - 6, 6,
				Color(ec_bd.r, ec_bd.g, ec_bd.b, 0.70))

	# Rail axis indicators (small arrows at edges)
	if rail_axis == "h":
		var mid_y := h * 0.5
		var rc := Color(0.55, 0.55, 0.65, 0.85)
		draw_line(Vector2(-7, mid_y), Vector2(-2, mid_y), rc, 1.2)
		draw_line(Vector2(-7, mid_y), Vector2(-4, mid_y - 3), rc, 1.2)
		draw_line(Vector2(-7, mid_y), Vector2(-4, mid_y + 3), rc, 1.2)
		draw_line(Vector2(w + 7, mid_y), Vector2(w + 2, mid_y), rc, 1.2)
		draw_line(Vector2(w + 7, mid_y), Vector2(w + 4, mid_y - 3), rc, 1.2)
		draw_line(Vector2(w + 7, mid_y), Vector2(w + 4, mid_y + 3), rc, 1.2)
		if _dragging and _wall_ref:
			var lx := float(grid_pos.x * TILE_SIZE)
			var rx := float((_wall_ref.grid_w - grid_pos.x - grid_w) * TILE_SIZE)
			if lx > 0:
				draw_dashed_line(Vector2(-lx, mid_y), Vector2(0, mid_y), Color(rc.r, rc.g, rc.b, 0.50), 1.0, 4.0)
			if rx > 0:
				draw_dashed_line(Vector2(w, mid_y), Vector2(w + rx, mid_y), Color(rc.r, rc.g, rc.b, 0.50), 1.0, 4.0)
	elif rail_axis == "v":
		var mid_x := w * 0.5
		var rc := Color(0.55, 0.55, 0.65, 0.85)
		draw_line(Vector2(mid_x, -7), Vector2(mid_x, -2), rc, 1.2)
		draw_line(Vector2(mid_x, -7), Vector2(mid_x - 3, -4), rc, 1.2)
		draw_line(Vector2(mid_x, -7), Vector2(mid_x + 3, -4), rc, 1.2)
		draw_line(Vector2(mid_x, h + 7), Vector2(mid_x, h + 2), rc, 1.2)
		draw_line(Vector2(mid_x, h + 7), Vector2(mid_x - 3, h + 4), rc, 1.2)
		draw_line(Vector2(mid_x, h + 7), Vector2(mid_x + 3, h + 4), rc, 1.2)
		if _dragging and _wall_ref:
			var ty := float(grid_pos.y * TILE_SIZE)
			var by := float((_wall_ref.grid_h - grid_pos.y - grid_h) * TILE_SIZE)
			if ty > 0:
				draw_dashed_line(Vector2(mid_x, -ty), Vector2(mid_x, 0), Color(rc.r, rc.g, rc.b, 0.50), 1.0, 4.0)
			if by > 0:
				draw_dashed_line(Vector2(mid_x, h), Vector2(mid_x, h + by), Color(rc.r, rc.g, rc.b, 0.50), 1.0, 4.0)

	# Blocked overlay with X
	if not _accessible:
		draw_rect(Rect2(0, 0, w, h), Color(0.88, 0.08, 0.08, 0.32))
		draw_line(Vector2(3, 3),     Vector2(w - 3, h - 3), Color(0.85, 0.05, 0.05, 0.80), 2.0)
		draw_line(Vector2(w - 3, 3), Vector2(3,     h - 3), Color(0.85, 0.05, 0.05, 0.80), 2.0)

	# Architectural dimension cotes while dragging
	if _dragging and _wall_ref:
		_draw_cotes(float(w), float(h))


func _draw_symbol(w: int, h: int, ink: Color) -> void:
	var s  := Color(ink.r, ink.g, ink.b, 0.48)
	var lw := 1.0

	match furniture_id:
		"normal_bed", "high_bed":
			# Pillow band across the top, centre body line
			var ph := minf(h * 0.28, 18.0)
			draw_rect(Rect2(3, 3, w - 6, ph - 3), Color(s.r, s.g, s.b, 0.18))
			draw_line(Vector2(3, ph),         Vector2(w - 3, ph), s, lw)
			draw_line(Vector2(w * 0.5, ph + 3), Vector2(w * 0.5, h - 3), s, lw)

		"sofa", "sofa_bed":
			# Thick backrest bar at top, cushion outlines below
			draw_rect(Rect2(3, 3, w - 6, h * 0.26), Color(s.r, s.g, s.b, 0.22))
			draw_rect(Rect2(3, 3, w - 6, h * 0.26), s, false, lw)
			var seat_y := h * 0.30
			var cw     := (w - 6) / 3.0
			for i in range(3):
				draw_rect(Rect2(3 + i * cw, seat_y, cw, h - seat_y - 3), Color(s.r, s.g, s.b, 0.10))
				draw_rect(Rect2(3 + i * cw, seat_y, cw, h - seat_y - 3), s, false, lw)
			if furniture_id == "sofa_bed":
				draw_dashed_line(Vector2(4, h * 0.55), Vector2(w - 4, h * 0.55), s, lw)

		"desk":
			# Desk surface implied by outline; chair seat + arc backrest below
			var ch   := h * 0.28
			var cy   := h - ch - 3.0
			var csz  := minf(w * 0.40, 24.0)
			var cx   := (w - csz) * 0.5
			draw_rect(Rect2(cx, cy, csz, ch), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(cx, cy, csz, ch), s, false, lw)
			# backrest arc
			draw_arc(Vector2(cx + csz * 0.5, cy), csz * 0.5, PI, TAU, 12, s, lw)

		"kitchen":
			# Four hob circles
			var rr := minf(w * 0.10, h * 0.16)
			var pts := [Vector2(w * 0.27, h * 0.35), Vector2(w * 0.73, h * 0.35),
						Vector2(w * 0.27, h * 0.72), Vector2(w * 0.73, h * 0.72)]
			for pt in pts:
				draw_circle(pt, rr * 0.45, Color(s.r, s.g, s.b, 0.15))
				draw_arc(pt, rr, 0, TAU, 14, s, lw)
			# Sink outline (top-right quadrant)
			draw_rect(Rect2(w * 0.55, h * 0.08, w * 0.38, h * 0.22), s, false, lw)

		"wardrobe":
			# Two door panels with handles
			draw_line(Vector2(w * 0.5, 4), Vector2(w * 0.5, h - 4), s, lw)
			draw_circle(Vector2(w * 0.5 - 4, h * 0.50), 1.8, s)
			draw_circle(Vector2(w * 0.5 + 4, h * 0.50), 1.8, s)

		"ottoman":
			# Cushion cross
			draw_line(Vector2(4, h * 0.50), Vector2(w - 4, h * 0.50), s, lw)
			draw_line(Vector2(w * 0.50, 4), Vector2(w * 0.50, h - 4), s, lw)

		"wall_cabinet":
			draw_line(Vector2(w * 0.5, 3), Vector2(w * 0.5, h - 3), s, lw)

		"storage_bed":
			var ph := minf(h * 0.28, 18.0)
			draw_rect(Rect2(3, 3, w - 6, ph - 3), Color(s.r, s.g, s.b, 0.18))
			draw_line(Vector2(3, ph),           Vector2(w - 3, ph), s, lw)
			draw_line(Vector2(w * 0.5, ph + 3), Vector2(w * 0.5, h - 3), s, lw)
			# Storage drawers at bottom
			var drawer_y := h * 0.72
			draw_rect(Rect2(4, drawer_y, w - 8, h - drawer_y - 3), Color(s.r, s.g, s.b, 0.12))
			draw_line(Vector2(w * 0.5, drawer_y), Vector2(w * 0.5, h - 3), s, lw * 0.7)
			draw_circle(Vector2(w * 0.5 - 6, (drawer_y + h) * 0.5), 1.5, s)
			draw_circle(Vector2(w * 0.5 + 6, (drawer_y + h) * 0.5), 1.5, s)

		"bunk_bed":
			# Lower bunk
			var ph := h * 0.28
			draw_rect(Rect2(3, 3, w - 6, ph - 3), Color(s.r, s.g, s.b, 0.18))
			draw_line(Vector2(3, ph), Vector2(w - 3, ph), s, lw)
			# Upper bunk divider
			draw_line(Vector2(3, h * 0.5), Vector2(w - 3, h * 0.5), s, lw)
			var ph2 := h * 0.5 + h * 0.14
			draw_rect(Rect2(3, h * 0.5 + 3, w - 6, ph2 - h * 0.5 - 3), Color(s.r, s.g, s.b, 0.14))
			draw_line(Vector2(3, ph2), Vector2(w - 3, ph2), s, lw)
			# Ladder
			draw_line(Vector2(w - 5, ph), Vector2(w - 5, h * 0.5), s, lw)
			for i in range(3):
				var ry := ph + float(i + 1) * (h * 0.5 - ph) / 4.0
				draw_line(Vector2(w - 8, ry), Vector2(w - 2, ry), s, lw * 0.7)

		"futon":
			# Like a sofa but simpler / flatter
			draw_rect(Rect2(3, 3, w - 6, h * 0.20), Color(s.r, s.g, s.b, 0.20))
			draw_rect(Rect2(3, 3, w - 6, h * 0.20), s, false, lw)
			draw_rect(Rect2(3, h * 0.24, w - 6, h - h * 0.24 - 3), Color(s.r, s.g, s.b, 0.10))
			draw_dashed_line(Vector2(4, h * 0.50), Vector2(w - 4, h * 0.50), s, lw)

		"puff":
			# Circle inside square
			var cx := w * 0.5; var cy := h * 0.5
			var r := minf(w, h) * 0.38
			draw_circle(Vector2(cx, cy), r, Color(s.r, s.g, s.b, 0.18))
			draw_arc(Vector2(cx, cy), r, 0, TAU, 16, s, lw)
			draw_circle(Vector2(cx, cy), r * 0.25, s)

		"stool":
			# Simple cross + circle
			var cx := w * 0.5; var cy := h * 0.5
			draw_circle(Vector2(cx, cy), minf(w, h) * 0.35, Color(s.r, s.g, s.b, 0.18))
			draw_arc(Vector2(cx, cy), minf(w, h) * 0.35, 0, TAU, 12, s, lw)

		"lounge_chair":
			draw_rect(Rect2(3, 3, w - 6, h * 0.28), Color(s.r, s.g, s.b, 0.22))
			draw_rect(Rect2(3, 3, w - 6, h * 0.28), s, false, lw)
			draw_rect(Rect2(3, h * 0.32, w - 6, h - h * 0.32 - 3), Color(s.r, s.g, s.b, 0.10))
			draw_rect(Rect2(3, h * 0.32, w - 6, h - h * 0.32 - 3), s, false, lw)

		"barcelona_chair":
			# Iconic cross-leg symbol
			draw_rect(Rect2(3, 3, w - 6, h * 0.32), Color(s.r, s.g, s.b, 0.22))
			draw_rect(Rect2(3, 3, w - 6, h * 0.32), s, false, lw)
			draw_line(Vector2(3, h * 0.35), Vector2(w * 0.5, h - 3), s, lw)
			draw_line(Vector2(w - 3, h * 0.35), Vector2(w * 0.5, h - 3), s, lw)

		"small_desk":
			var ch := h * 0.32
			var cy := h - ch - 3.0
			var csz := minf(w * 0.45, 20.0)
			var cx := (w - csz) * 0.5
			draw_rect(Rect2(cx, cy, csz, ch), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(cx, cy, csz, ch), s, false, lw)
			draw_arc(Vector2(cx + csz * 0.5, cy), csz * 0.5, PI, TAU, 10, s, lw)

		"murphy_desk":
			# Fold symbol — dashed desk surface + hinge arrow
			draw_dashed_line(Vector2(2, h * 0.5), Vector2(w - 2, h * 0.5), s, lw, 3.0)
			draw_line(Vector2(2, 2), Vector2(2, h - 2), s, lw)
			draw_line(Vector2(2, h * 0.5), Vector2(w * 0.35, h * 0.85), s, lw * 0.7)

		"dining_table":
			# Table rectangle with chairs on sides
			var mx := w * 0.5; var my := h * 0.5
			var tw := w * 0.55; var th := h * 0.50
			draw_rect(Rect2(mx - tw * 0.5, my - th * 0.5, tw, th), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(mx - tw * 0.5, my - th * 0.5, tw, th), s, false, lw)
			# Chairs (small rects top and bottom)
			for ci in range(2):
				var cx2 := mx + (ci - 0.5) * tw * 0.7
				draw_rect(Rect2(cx2 - 4, my - th * 0.5 - 5, 8, 4), s, false, lw * 0.7)
				draw_rect(Rect2(cx2 - 4, my + th * 0.5 + 1, 8, 4), s, false, lw * 0.7)

		"coffee_table":
			draw_rect(Rect2(4, 4, w - 8, h - 8), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(4, 4, w - 8, h - 8), s, false, lw)

		"bookshelf":
			# Vertical shelves with books
			var num_shelves := 3
			for si in range(num_shelves):
				var shelf_y := 3.0 + float(si) * (h - 6.0) / float(num_shelves)
				draw_line(Vector2(3, shelf_y), Vector2(w - 3, shelf_y), s, lw)
			# Book spines
			var book_w := (w - 6) / 5.0
			for bi in range(5):
				draw_line(Vector2(3 + bi * book_w + book_w * 0.5, 3),
						  Vector2(3 + bi * book_w + book_w * 0.5, h - 3), Color(s.r, s.g, s.b, 0.35), lw * 0.6)

		"pantry":
			# Tall cabinet with handle
			draw_line(Vector2(w * 0.5, 3), Vector2(w * 0.5, h - 3), s, lw)
			draw_circle(Vector2(w * 0.5 - 3, h * 0.5), 1.5, s)
			draw_circle(Vector2(w * 0.5 + 3, h * 0.5), 1.5, s)
			draw_line(Vector2(3, h * 0.33), Vector2(w - 3, h * 0.33), Color(s.r, s.g, s.b, 0.40), lw * 0.6)
			draw_line(Vector2(3, h * 0.66), Vector2(w - 3, h * 0.66), Color(s.r, s.g, s.b, 0.40), lw * 0.6)

		"kitchen_small":
			# 2 hobs instead of 4
			var rr := minf(w * 0.14, h * 0.20)
			for pt in [Vector2(w * 0.30, h * 0.50), Vector2(w * 0.70, h * 0.50)]:
				draw_circle(pt, rr * 0.45, Color(s.r, s.g, s.b, 0.15))
				draw_arc(pt, rr, 0, TAU, 12, s, lw)
			draw_rect(Rect2(w * 0.20, h * 0.08, w * 0.60, h * 0.22), s, false, lw)

		"wall_hanger":
			# Row of hook pegs
			var n_pegs := maxi(2, int(w / 8))
			var spacing := float(w - 4) / float(n_pegs - 1)
			for pi in range(n_pegs):
				var px := 2.0 + pi * spacing
				draw_line(Vector2(px, 1), Vector2(px, h - 1), s, lw)
				draw_arc(Vector2(px, h - 1), 2.0, 0, PI, 8, s, lw)

		"stairs":
			# Stair treads — horizontal lines stepping diagonally
			var n_treads := maxi(3, int(h / 8))
			var tread_h  := float(h - 4) / float(n_treads)
			for ti in range(n_treads):
				var ty := 2.0 + ti * tread_h
				var tx_end := 2.0 + float(ti + 1) / float(n_treads) * (w - 4)
				draw_line(Vector2(2, ty), Vector2(tx_end, ty), s, lw)
				draw_line(Vector2(tx_end, ty), Vector2(tx_end, ty + tread_h), s, lw)
			draw_line(Vector2(2, 2), Vector2(2, h - 2), s, lw)
			draw_line(Vector2(w - 2, 2), Vector2(w - 2, h - 2), s, lw * 0.5)

		"plant":
			# Circle with stem
			draw_circle(Vector2(w * 0.5, h * 0.40), minf(w, h) * 0.32, Color(s.r, s.g, s.b, 0.25))
			draw_arc(Vector2(w * 0.5, h * 0.40), minf(w, h) * 0.32, 0, TAU, 14, s, lw)
			draw_line(Vector2(w * 0.5, h * 0.72), Vector2(w * 0.5, h - 2), s, lw)

		"wall_plant", "painting":
			# Simple rect outline for wall deco
			draw_rect(Rect2(2, 2, w - 4, h - 4), Color(s.r, s.g, s.b, 0.20))


func _draw_cotes(fW: float, fH: float) -> void:
	var gx := int(position.x / TILE_SIZE)
	var gy := int(position.y / TILE_SIZE)

	var d_n := gy
	var d_s := _wall_ref.grid_h - gy - grid_h
	var d_w := gx
	var d_e := _wall_ref.grid_w - gx - grid_w

	const COL  := Color(0.18, 0.58, 0.90, 0.82)
	const FS   := 7
	const TICK := 4.0
	const OFF  := 8.0
	var font := ThemeDB.fallback_font

	# ── Own-size cotes (just outside the furniture edges) ──────────────────
	# Width — horizontal line above
	draw_line(Vector2(0, -OFF), Vector2(fW, -OFF), COL, 0.7)
	draw_line(Vector2(0,  -OFF - TICK), Vector2(0,  -OFF + TICK), COL, 1.0)
	draw_line(Vector2(fW, -OFF - TICK), Vector2(fW, -OFF + TICK), COL, 1.0)
	draw_string(font, Vector2(fW * 0.5 - 9, -OFF - 2),
		"%.1fm" % (float(grid_w) * 0.1),
		HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)

	# Height — vertical line left
	draw_line(Vector2(-OFF, 0), Vector2(-OFF, fH), COL, 0.7)
	draw_line(Vector2(-OFF - TICK, 0),  Vector2(-OFF + TICK, 0),  COL, 1.0)
	draw_line(Vector2(-OFF - TICK, fH), Vector2(-OFF + TICK, fH), COL, 1.0)
	draw_string(font, Vector2(-OFF - 16, fH * 0.5 + 3),
		"%.1fm" % (float(grid_h) * 0.1),
		HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)

	# ── Distance-to-wall cotes ─────────────────────────────────────────────
	if d_n > 0:
		var px := float(d_n * TILE_SIZE)
		var mx := fW * 0.5
		draw_line(Vector2(mx, 0), Vector2(mx, -px), COL, 0.55)
		draw_line(Vector2(mx - TICK, 0),   Vector2(mx + TICK, 0),   COL, 0.8)
		draw_line(Vector2(mx - TICK, -px), Vector2(mx + TICK, -px), COL, 0.8)
		draw_string(font, Vector2(mx + 3, -px * 0.5 + 3),
			"%.1fm" % (d_n * 0.1), HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)

	if d_s > 0:
		var px := float(d_s * TILE_SIZE)
		var mx := fW * 0.5
		draw_line(Vector2(mx, fH), Vector2(mx, fH + px), COL, 0.55)
		draw_line(Vector2(mx - TICK, fH),      Vector2(mx + TICK, fH),      COL, 0.8)
		draw_line(Vector2(mx - TICK, fH + px), Vector2(mx + TICK, fH + px), COL, 0.8)
		draw_string(font, Vector2(mx + 3, fH + px * 0.5 + 3),
			"%.1fm" % (d_s * 0.1), HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)

	if d_w > 0:
		var px := float(d_w * TILE_SIZE)
		var my := fH * 0.5
		draw_line(Vector2(0, my), Vector2(-px, my), COL, 0.55)
		draw_line(Vector2(0,   my - TICK), Vector2(0,   my + TICK), COL, 0.8)
		draw_line(Vector2(-px, my - TICK), Vector2(-px, my + TICK), COL, 0.8)
		draw_string(font, Vector2(-px * 0.5 - 10, my - 2),
			"%.1fm" % (d_w * 0.1), HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)

	if d_e > 0:
		var px := float(d_e * TILE_SIZE)
		var my := fH * 0.5
		draw_line(Vector2(fW, my), Vector2(fW + px, my), COL, 0.55)
		draw_line(Vector2(fW,      my - TICK), Vector2(fW,      my + TICK), COL, 0.8)
		draw_line(Vector2(fW + px, my - TICK), Vector2(fW + px, my + TICK), COL, 0.8)
		draw_string(font, Vector2(fW + px * 0.5 - 8, my - 2),
			"%.1fm" % (d_e * 0.1), HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)


func set_grid_pos(gx: int, gy: int) -> void:
	grid_pos = Vector2i(gx, gy)
	position = Vector2(gx * TILE_SIZE, gy * TILE_SIZE)


func get_occupied_tiles() -> Array:
	var tiles: Array = []
	for x in range(grid_w):
		for y in range(grid_h):
			tiles.append(Vector2i(grid_pos.x + x, grid_pos.y + y))
	return tiles


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R and _is_mouse_over():
			_rotate()
			get_viewport().set_input_as_handled()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _is_mouse_over():
				if Furniture.test_mode_active and foldable:
					toggle_fold()
					get_viewport().set_input_as_handled()
					return
				_start_drag(event.position)
			elif _dragging and not event.pressed:
				_end_drag(event.position)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if _is_mouse_over():
				sell_requested.emit(self)
				get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion and _dragging:
		_drag(event.position)


func _is_mouse_over() -> bool:
	var mouse := get_global_mouse_position()
	var sz := Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	return Rect2(global_position, sz).has_point(mouse)


func _start_drag(mouse_pos: Vector2) -> void:
	_dragging = true
	_drag_offset = global_position - mouse_pos
	_original_pos = position
	z_index = 10
	# Lock rail axis on drag start
	if rail_axis == "h":
		_rail_lock = grid_pos.y
	elif rail_axis == "v":
		_rail_lock = grid_pos.x
	queue_redraw()


func _drag(mouse_pos: Vector2) -> void:
	if not _wall_ref:
		return
	var target := mouse_pos + _drag_offset - _wall_ref.global_position
	var snapped_x := int(target.x / TILE_SIZE)
	var snapped_y := int(target.y / TILE_SIZE)
	if rail_axis == "h" and _rail_lock >= 0:
		snapped_y = _rail_lock
		snapped_x = clampi(snapped_x, 0, _wall_ref.grid_w - grid_w)
	elif rail_axis == "v" and _rail_lock >= 0:
		snapped_x = _rail_lock
		snapped_y = clampi(snapped_y, 0, _wall_ref.grid_h - grid_h)
	else:
		snapped_x = clampi(snapped_x, 0, _wall_ref.grid_w - grid_w)
		snapped_y = clampi(snapped_y, 0, _wall_ref.grid_h - grid_h)
	position = Vector2(snapped_x * TILE_SIZE, snapped_y * TILE_SIZE)
	queue_redraw()


func _rotate() -> void:
	_play("rotate")
	var new_w := grid_h
	var new_h := grid_w
	if _wall_ref:
		var cx := clampi(grid_pos.x, 0, _wall_ref.grid_w - new_w)
		var cy := clampi(grid_pos.y, 0, _wall_ref.grid_h - new_h)
		grid_w = new_w
		grid_h = new_h
		rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
		_wall_ref.place_furniture(self, Vector2i(cx, cy))
	else:
		grid_w = new_w
		grid_h = new_h
		rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	queue_redraw()


func _end_drag(_mouse_pos: Vector2) -> void:
	_dragging = false
	z_index = 0
	queue_redraw()
	var snapped_x := int(position.x / TILE_SIZE)
	var snapped_y := int(position.y / TILE_SIZE)

	if _wall_ref and _wall_ref.can_place(self, Vector2i(snapped_x, snapped_y)):
		_wall_ref.place_furniture(self, Vector2i(snapped_x, snapped_y))
		_play("place")
		placed.emit(self)
	else:
		_play("error")
		position = _original_pos
