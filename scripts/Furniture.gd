extends Node2D
class_name Furniture

signal placed(furniture_node: Node2D)
signal sell_requested(furniture_node: Furniture)
signal fold_toggled
signal placement_confirmed
signal placement_cancelled

const TILE_SIZE := 8

# Set once by Main._ready() so a floor-placement ghost knows whether a click is
# actually over the floor pane — otherwise it swallows every left click on
# screen (other panels, buttons) trying to confirm placement at a stale position.
static var is_in_floor_pane: Callable = Callable()

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
var moment_fold_state: Dictionary = {}   # moment_id -> bool; each moment remembers its OWN fold state
static var active_moment_id: String = "" # "" for levels without moments
var _base_grid_h: int = 1             # grid_h when folded

var height_category: String = "medium"  # "low" | "medium" | "tall"
var z_bottom: float = 0.0  # tiles from floor level
var z_top:    float = 12.0 # tiles from floor level
var needs_water:  bool = false
var needs_power:  bool = false
var zone_divider: bool = false   # acts as a soft wall for zone flood-fill
var floor_category: String = "any"   # "any" | "balcony" | "bathroom" — which tile kinds accept this piece
var is_stair:     bool = false
var stair_direction: String = ""   # "north" | "south" | "east" | "west"

# Rail: constrains dragging to one axis within a defined extent
var rail_axis:  String = ""   # "h" | "v" | "" = free
var rail_start: int    = -1   # first valid tile offset along the rail (-1 = unclamped)
var rail_end:   int    = -1   # last valid tile offset along the rail
var _rail_lock: int    = -1   # locked row (h) or column (v) set on drag start

# Rail + moments: a rail piece can be slid into a "reveal zone" (a sub-range
# along its own rail) to grant extra functions while it sits there — e.g. a
# wardrobe pulled out of its hidden dock to fulfill "dress" during one moment,
# then slid back out of the way for another. Like moment_fold_state, each
# moment remembers its OWN position independently.
var reveal_start:     int    = -1   # rail-local coord where the reveal zone begins (-1 = none)
var reveal_end:       int    = -1   # rail-local coord where the reveal zone ends
var reveal_functions: Array  = []   # extra functions granted while inside the reveal zone
var moment_rail_pos:  Dictionary = {}   # moment_id -> Vector2i grid_pos left by the player

static var test_mode_active: bool = false
var _extended_conflict: bool = false

var _dragging: bool = false
var _placement_mode: bool = false   # true while waiting for initial click-to-place
var _drag_offset: Vector2 = Vector2.ZERO
var _original_pos: Vector2 = Vector2.ZERO
var _press_pos: Vector2 = Vector2.ZERO   # viewport-space position at mouse-down, for click-vs-drag detection
const CLICK_MOVE_THRESHOLD := 4.0        # px; below this, a release counts as a click, not a drag
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
	# A foldable piece starts folded (is_extended = false); its live .functions
	# must reflect that from the start, not the full base list, so moment/need
	# checks don't count a state the player hasn't actually set yet.
	if foldable and not folded_functions_arr.is_empty():
		functions = folded_functions_arr.duplicate()
	height_category       = data.get("height_category",   "medium") as String
	z_bottom = data.get("z_bottom", 0.0) as float
	match height_category:
		"low":  z_top = data.get("z_top",  6.0) as float
		"tall": z_top = data.get("z_top", 24.0) as float
		_:      z_top = data.get("z_top", 12.0) as float
	needs_water           = data.get("needs_water",       false)    as bool
	needs_power           = data.get("needs_power",       false)    as bool
	zone_divider          = data.get("zone_divider",      false)    as bool
	floor_category        = data.get("floor_category",    "any")    as String
	rail_axis             = data.get("rail_axis",         "")       as String
	rail_start            = data.get("rail_start",        -1)       as int
	rail_end              = data.get("rail_end",          -1)       as int
	reveal_start          = data.get("reveal_start",      -1)       as int
	reveal_end            = data.get("reveal_end",        -1)       as int
	reveal_functions      = (data.get("reveal_functions", []) as Array).duplicate()
	is_stair              = data.get("is_stair",          false)    as bool
	stair_direction       = data.get("stair_direction",   "")       as String
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
	var want_extended := not (moment_fold_state.get(active_moment_id, false) as bool)
	if not _apply_fold_state(want_extended):
		return false
	moment_fold_state[active_moment_id] = want_extended
	fold_toggled.emit()
	return true


# Re-applies whatever fold state THIS moment remembers (independent from
# whatever other moments are currently set to) — called when the player
# switches which moment they're viewing.
func set_moment_view(moment_id: String) -> void:
	if foldable and not folded_functions_arr.is_empty():
		var want_extended: bool = moment_fold_state.get(moment_id, false) as bool
		if want_extended != is_extended:
			if not _apply_fold_state(want_extended):
				_apply_fold_state(false)  # doesn't fit here anymore — fall back to folded
	# Rail furniture: snap back to wherever the player left it FOR this moment
	# (defaults to its current/spawn position the first time a moment is seen).
	if rail_axis != "" and moment_rail_pos.has(moment_id):
		var target: Vector2i = moment_rail_pos[moment_id]
		if target != grid_pos and _wall_ref:
			_wall_ref.place_furniture(self, target)
			position = Vector2(target.x * TILE_SIZE, target.y * TILE_SIZE)
			queue_redraw()


# True when `pos` (a grid position along this piece's own rail) sits inside
# its reveal zone — e.g. an armario pulled out of its hidden dock.
func _is_revealed_at(pos: Vector2i) -> bool:
	if rail_axis == "" or reveal_start < 0 or reveal_end < 0:
		return false
	var coord := pos.x if rail_axis == "h" else pos.y
	return coord >= reveal_start and coord <= reveal_end


# Functions this piece contributes for a given moment, based on that moment's
# OWN stored fold state / rail position — independent of whichever moment is
# on screen right now.
func functions_for_moment(moment_id: String) -> Array:
	if foldable and not folded_functions_arr.is_empty():
		var extended: bool = moment_fold_state.get(moment_id, false) as bool
		return extended_functions_arr if extended else folded_functions_arr
	if rail_axis != "" and not reveal_functions.is_empty():
		var pos: Vector2i = moment_rail_pos.get(moment_id, grid_pos) as Vector2i
		if _is_revealed_at(pos):
			var out := functions.duplicate()
			for fn in reveal_functions:
				if fn not in out:
					out.append(fn)
			return out
	return functions


func _apply_fold_state(want_extended: bool) -> bool:
	if want_extended:
		# Try to extend: check for space in the extra rows
		grid_h = _base_grid_h + extended_add_h
		if not _wall_ref.can_place(self, grid_pos):
			grid_h = _base_grid_h   # restore — no room
			return false
		is_extended = true
		functions = extended_functions_arr.duplicate() if not extended_functions_arr.is_empty() else functions
		_wall_ref.place_furniture(self, grid_pos)
	else:
		# Fold back: shrink footprint
		grid_h = _base_grid_h
		is_extended = false
		functions = folded_functions_arr.duplicate() if not folded_functions_arr.is_empty() else functions
		_wall_ref.place_furniture(self, grid_pos)
	rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	queue_redraw()
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
			var left_b := 0                        if rail_start < 0 else rail_start
			var right_b := _wall_ref.grid_w - grid_w if rail_end   < 0 else rail_end
			var lx := float((grid_pos.x - left_b)  * TILE_SIZE)
			var rx := float((right_b - grid_pos.x)  * TILE_SIZE)
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
			var top_b := 0                         if rail_start < 0 else rail_start
			var bot_b := _wall_ref.grid_h - grid_h  if rail_end   < 0 else rail_end
			var ty := float((grid_pos.y - top_b) * TILE_SIZE)
			var by := float((bot_b - grid_pos.y)  * TILE_SIZE)
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

		"toilet":
			# Tank rectangle at top, oval bowl below, flush dot
			var tk_h := h * 0.36
			draw_rect(Rect2(3, 3, w - 6, tk_h), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(3, 3, w - 6, tk_h), s, false, lw)
			draw_circle(Vector2(w * 0.5, 3 + tk_h * 0.5), 2.0, Color(s.r, s.g, s.b, 0.35))
			var bwl_y := 3 + tk_h + 2
			var bwl_h := h - bwl_y - 3
			var bwl_r := minf((w - 8) * 0.5, bwl_h * 0.5)
			var bwl_c := Vector2(w * 0.5, bwl_y + bwl_h * 0.5)
			draw_arc(bwl_c, bwl_r, 0, TAU, 16, s, lw)
			draw_arc(bwl_c, bwl_r * 0.45, 0, TAU, 12, Color(s.r, s.g, s.b, 0.22), lw)

		"sink":
			# Basin rect with drain dot and cross faucet
			var bsx := 4.0; var bsy := 3.0
			var bsw := w - 8.0; var bsh := h - 6.0
			draw_rect(Rect2(bsx, bsy, bsw, bsh), Color(s.r, s.g, s.b, 0.14))
			draw_rect(Rect2(bsx, bsy, bsw, bsh), s, false, lw)
			draw_circle(Vector2(w * 0.5, bsy + bsh * 0.62), 1.5, Color(s.r, s.g, s.b, 0.40))
			var fc := Vector2(w * 0.5, bsy + 4)
			draw_circle(fc, 2.0, s)
			draw_line(fc + Vector2(-5, 0), fc + Vector2(5, 0), s, lw)
			draw_line(fc + Vector2(0, -3), fc + Vector2(0, 4), s, lw)

		"shower":
			# Square stall, corner drain, showerhead arc, rain grid
			draw_rect(Rect2(3, 3, w - 6, h - 6), Color(s.r, s.g, s.b, 0.10))
			draw_rect(Rect2(3, 3, w - 6, h - 6), s, false, lw)
			draw_circle(Vector2(7, h - 7), 2.0, Color(s.r, s.g, s.b, 0.40))
			draw_arc(Vector2(w - 6, 6), (w - 12) * 0.45, PI * 0.5, PI, 10, s, lw)
			draw_circle(Vector2(w - 6, 6), 2.5, Color(s.r, s.g, s.b, 0.30))
			for ri in range(3):
				for ci in range(3):
					draw_circle(Vector2(w * 0.28 + float(ci) * w * 0.14,
							h * 0.40 + float(ri) * h * 0.14), 1.0, Color(s.r, s.g, s.b, 0.28))

		"towel_rack":
			# Horizontal bar with end brackets and towel fold
			var my := h * 0.5
			draw_line(Vector2(5, my), Vector2(w - 5, my), s, lw * 1.5)
			draw_line(Vector2(5,   my - 2), Vector2(5,   my + 2), s, lw)
			draw_line(Vector2(w-5, my - 2), Vector2(w-5, my + 2), s, lw)
			draw_line(Vector2(w * 0.5, my - 2), Vector2(w * 0.5, my + 2),
					  Color(s.r, s.g, s.b, 0.28), lw)

		"murphy_bed":
			# Wall-mounted fold-down bed: wall rail at top, pillow band, folded panel with pivot
			draw_rect(Rect2(2, 2, w - 4, 4), s, false, lw)                             # wall-mount rail
			var mph := minf(h * 0.30, 18.0)
			draw_rect(Rect2(3, 7, w - 6, mph), Color(s.r, s.g, s.b, 0.18))             # pillow fill
			draw_line(Vector2(3, 7 + mph), Vector2(w - 3, 7 + mph), s, lw)              # pillow divider
			draw_line(Vector2(w * 0.5, 7 + mph), Vector2(w * 0.5, h - 4), s, lw)       # centre spine
			draw_line(Vector2(4, h - 4),  Vector2(w - 4, h - 4),  s, lw)               # foot rail
			draw_circle(Vector2(4.0, 6.0),  2.0, s)                                      # hinge L
			draw_circle(Vector2(w - 4.0, 6.0), 2.0, s)                                   # hinge R

		"bathtub":
			# Oval tub inside rectangle; faucet dot at one end
			var bw := w - 8.0; var bh := h - 8.0
			var bx := 4.0; var by := 4.0
			draw_rect(Rect2(bx, by, bw, bh), Color(s.r, s.g, s.b, 0.14))
			draw_rect(Rect2(bx, by, bw, bh), s, false, lw)
			# Inner oval
			draw_arc(Vector2(w * 0.5, h * 0.5), bw * 0.38, 0, TAU, 18, Color(s.r, s.g, s.b, 0.30), lw)
			# Faucet dot at head end
			draw_circle(Vector2(w * 0.5, by + 4.0), 2.0, s)

		"tv":
			# Screen with thin bezel and stand legs
			var sw := w - 6.0; var sh := h * 0.72
			var sx := 3.0;     var sy := 3.0
			draw_rect(Rect2(sx, sy, sw, sh), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(sx, sy, sw, sh), s, false, lw)
			# Screen glare diagonal
			draw_line(Vector2(sx + 4, sy + 3), Vector2(sx + sw * 0.35, sy + sh * 0.40),
					  Color(s.r, s.g, s.b, 0.25), lw)
			# Stand base
			var stx := w * 0.5
			draw_line(Vector2(stx, sy + sh), Vector2(stx, h - 3), s, lw)
			draw_line(Vector2(stx - 6, h - 3), Vector2(stx + 6, h - 3), s, lw)

		"wall_shelf":
			# Three horizontal shelves with end brackets
			var n := 3
			for si in range(n):
				var sy2 := 3.0 + float(si) * (h - 6.0) / float(n) + (h - 6.0) / float(n) * 0.5
				draw_line(Vector2(3, sy2), Vector2(w - 3, sy2), s, lw)
				draw_line(Vector2(3, sy2), Vector2(3, sy2 - 3), s, lw * 0.7)       # bracket L
				draw_line(Vector2(w - 3, sy2), Vector2(w - 3, sy2 - 3), s, lw * 0.7) # bracket R

		"mirror":
			# Oval reflection surface with cross glare
			var mr := minf(w - 8.0, h - 8.0) * 0.5
			var mc := Vector2(w * 0.5, h * 0.5)
			draw_circle(mc, mr, Color(s.r, s.g, s.b, 0.12))
			draw_arc(mc, mr, 0, TAU, 20, s, lw)
			draw_arc(mc, mr, 0, TAU, 20, s, lw)
			# Glare lines
			draw_line(mc + Vector2(-mr * 0.5, -mr * 0.5),
					  mc + Vector2(-mr * 0.22, -mr * 0.22), Color(s.r, s.g, s.b, 0.35), lw)

		"stair_n", "stair_s", "stair_e", "stair_w":
			var n_treads := maxi(3, int(maxf(w, h) / 8))
			if furniture_id in ["stair_n", "stair_s"]:
				# Treads horizontal, stepping upward (N = head at top)
				var tread_h := float(h - 4) / float(n_treads)
				var dir_flip := 1.0 if furniture_id == "stair_n" else -1.0
				for ti in range(n_treads):
					var ti_eff := ti if dir_flip > 0 else (n_treads - 1 - ti)
					var ty := 2.0 + ti_eff * tread_h
					var tx_end := 2.0 + float(ti + 1) / float(n_treads) * (w - 4)
					draw_line(Vector2(2, ty), Vector2(tx_end, ty), s, lw)
					draw_line(Vector2(tx_end, ty), Vector2(tx_end, ty + tread_h), s, lw)
				draw_line(Vector2(2, 2), Vector2(2, h - 2), s, lw)
			else:
				# Treads vertical, stepping rightward (E = head at right)
				var tread_w := float(w - 4) / float(n_treads)
				var dir_flip := 1.0 if furniture_id == "stair_e" else -1.0
				for ti in range(n_treads):
					var ti_eff := ti if dir_flip > 0 else (n_treads - 1 - ti)
					var tx := 2.0 + ti_eff * tread_w
					var ty_end := 2.0 + float(ti + 1) / float(n_treads) * (h - 4)
					draw_line(Vector2(tx, 2), Vector2(tx, ty_end), s, lw)
					draw_line(Vector2(tx, ty_end), Vector2(tx + tread_w, ty_end), s, lw)
				draw_line(Vector2(2, 2), Vector2(w - 2, 2), s, lw)

		"loft_bed":
			# Two-level: lower living area + upper sleep platform (ladder on side)
			draw_line(Vector2(3, h * 0.5), Vector2(w - 3, h * 0.5), s, lw)
			var ph := minf(h * 0.20, 14.0)
			draw_rect(Rect2(3, 3, w - 6, ph), Color(s.r, s.g, s.b, 0.18))
			draw_line(Vector2(3, 3 + ph), Vector2(w - 3, 3 + ph), s, lw)
			draw_line(Vector2(w * 0.5, 3 + ph), Vector2(w * 0.5, h * 0.5 - 2), s, lw)
			draw_line(Vector2(w - 5, 3 + ph), Vector2(w - 5, h * 0.5), s, lw)
			for ri in range(3):
				var ry := 3.0 + ph + float(ri + 1) * (h * 0.5 - 3.0 - ph) / 4.0
				draw_line(Vector2(w - 8, ry), Vector2(w - 2, ry), s, lw * 0.7)

		"wall_plant", "painting":
			# Simple rect outline for wall deco
			draw_rect(Rect2(2, 2, w - 4, h - 4), Color(s.r, s.g, s.b, 0.20))

		# ── Rugs / mats ──────────────────────────────────────────────────────
		"rug", "bedroom_rug", "bath_mat":
			# Outer border + inner parallel stripes
			draw_rect(Rect2(3, 3, w - 6, h - 6), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(3, 3, w - 6, h - 6), s, false, lw)
			var n_stripes := maxi(2, int((h - 10) / 5))
			for si in range(1, n_stripes):
				var sy := 6.0 + float(si) * float(h - 12) / float(n_stripes)
				draw_line(Vector2(6, sy), Vector2(w - 6, sy), Color(s.r, s.g, s.b, 0.30), lw * 0.7)
			# Corner tassels
			for cx in [4.0, w - 4.0]:
				for cy in [4.0, h - 4.0]:
					draw_circle(Vector2(cx, cy), 1.5, Color(s.r, s.g, s.b, 0.50))

		# ── Lamps ─────────────────────────────────────────────────────────────
		"floor_lamp", "desk_lamp":
			var cx2 := w * 0.5
			var stem_top := h * 0.20
			var shade_r := minf(w * 0.38, h * 0.20)
			# Stem
			draw_line(Vector2(cx2, h - 3), Vector2(cx2, stem_top + shade_r), s, lw)
			# Base
			draw_line(Vector2(cx2 - 4, h - 3), Vector2(cx2 + 4, h - 3), s, lw)
			# Shade (arc + bottom line)
			draw_arc(Vector2(cx2, stem_top + shade_r), shade_r, PI, TAU, 14, s, lw)
			draw_line(Vector2(cx2 - shade_r, stem_top + shade_r),
					  Vector2(cx2 + shade_r, stem_top + shade_r), s, lw)
			# Glow fill
			draw_circle(Vector2(cx2, stem_top + shade_r * 0.6), shade_r * 0.5,
					Color(s.r, s.g, s.b, 0.12))

		# ── Fridge ────────────────────────────────────────────────────────────
		"fridge":
			# Freezer compartment at top (~30%), fridge body below
			var divider_y := h * 0.30
			draw_line(Vector2(3, divider_y), Vector2(w - 3, divider_y), s, lw)
			# Door handle on right side
			var hx := w - 5.0
			draw_line(Vector2(hx, divider_y + 3), Vector2(hx, h * 0.75), s, lw * 1.5)

		# ── Drawers furniture (dresser, filing cabinet, nightstand, tv_stand) ─
		"dresser", "filing_cabinet", "nightstand", "tv_stand", "bathroom_cabinet":
			var n_drawers := maxi(2, int(h / 10))
			var drawer_h := float(h - 4) / float(n_drawers)
			for di in range(n_drawers):
				var dy := 2.0 + di * drawer_h
				draw_line(Vector2(3, dy + drawer_h), Vector2(w - 3, dy + drawer_h), s, lw * 0.8)
				# Drawer handle
				var mid_x := w * 0.5
				draw_line(Vector2(mid_x - 3, dy + drawer_h * 0.55),
						  Vector2(mid_x + 3, dy + drawer_h * 0.55), s, lw * 1.2)

		# ── Clothes rack ──────────────────────────────────────────────────────
		"clothes_rack":
			# Horizontal bar across top third
			var bar_y := h * 0.30
			draw_line(Vector2(3, bar_y), Vector2(w - 3, bar_y), s, lw * 1.5)
			# Vertical supports at ends
			draw_line(Vector2(3, bar_y), Vector2(3, h - 3), s, lw)
			draw_line(Vector2(w - 3, bar_y), Vector2(w - 3, h - 3), s, lw)
			# Hangers (triangle arcs)
			var n_hangers := maxi(2, int((w - 8) / 8))
			for hi2 in range(n_hangers):
				var hx2 := 6.0 + hi2 * float(w - 12) / float(n_hangers - 1) if n_hangers > 1 else w * 0.5
				draw_arc(Vector2(hx2, bar_y), 3.5, PI * 0.1, PI * 0.9, 8,
						Color(s.r, s.g, s.b, 0.55), lw * 0.8)
				draw_line(Vector2(hx2, bar_y + 3.5), Vector2(hx2 - 3, bar_y + 9), s, lw * 0.7)
				draw_line(Vector2(hx2, bar_y + 3.5), Vector2(hx2 + 3, bar_y + 9), s, lw * 0.7)

		# ── Planter box ───────────────────────────────────────────────────────
		"planter_box":
			# Soil fill + plant stems + dots
			draw_rect(Rect2(3, h * 0.5, w - 6, h * 0.45), Color(s.r, s.g, s.b, 0.20))
			var n_plants := maxi(2, int((w - 6) / 10))
			for pi2 in range(n_plants):
				var px := 5.0 + pi2 * float(w - 10) / float(n_plants - 1) if n_plants > 1 else w * 0.5
				var py_soil := h * 0.5
				draw_line(Vector2(px, py_soil), Vector2(px, py_soil - h * 0.30), s, lw)
				draw_circle(Vector2(px, py_soil - h * 0.30), 2.5, Color(s.r, s.g, s.b, 0.30))

		# ── Sun lounger ───────────────────────────────────────────────────────
		"sun_lounger":
			# Reclined rectangle with head rest bump
			var hr_w := w * 0.18
			draw_rect(Rect2(3, h * 0.20, hr_w, h * 0.60), Color(s.r, s.g, s.b, 0.25))
			draw_rect(Rect2(3 + hr_w, h * 0.30, w - hr_w - 6, h * 0.40),
					Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(3, h * 0.20, hr_w, h * 0.60), s, false, lw)
			draw_rect(Rect2(3 + hr_w, h * 0.30, w - hr_w - 6, h * 0.40), s, false, lw)
			# Leg lines
			for lx in [6.0, w - 6.0]:
				draw_line(Vector2(lx, h * 0.70), Vector2(lx, h - 3), s, lw * 0.7)

		# ── Laundry basket ────────────────────────────────────────────────────
		"laundry_basket":
			# Tapered body + oval opening at top
			var bx := w * 0.10; var by := h * 0.25
			draw_rect(Rect2(bx, by, w - bx * 2, h - by - 3), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(bx, by, w - bx * 2, h - by - 3), s, false, lw)
			var ell_pts: PackedVector2Array = PackedVector2Array()
			for _ai in range(13):
				var ang := _ai * TAU / 12.0
				ell_pts.append(Vector2(w * 0.5 + (w - bx * 2) * 0.45 * cos(ang), (by + 3) + 3.5 * sin(ang)))
			ell_pts.append(ell_pts[0])
			draw_polyline(ell_pts, Color(s.r, s.g, s.b, 0.55), lw)
			# Weave lines
			var n_weave := 3
			for wi in range(1, n_weave + 1):
				var wy := by + float(wi) * (h - by - 3) / float(n_weave + 1)
				draw_line(Vector2(bx + 2, wy), Vector2(w - bx - 2, wy),
						Color(s.r, s.g, s.b, 0.25), lw * 0.7)

		# ── Whiteboard ────────────────────────────────────────────────────────
		"whiteboard":
			draw_rect(Rect2(2, 2, w - 4, h - 4), Color(s.r, s.g, s.b, 0.15))
			# Writing lines
			for li in range(2):
				var ly := 4.0 + float(li) * (h - 8) / 2.0 + (h - 8) / 4.0
				draw_line(Vector2(5, ly), Vector2(w - 5, ly), Color(s.r, s.g, s.b, 0.35), lw * 0.7)

		# ── Kitchen island / outdoor table / side table ───────────────────────
		"kitchen_island", "outdoor_table", "side_table":
			# Surface with a thin inset and seam lines
			draw_rect(Rect2(3, 3, w - 6, h - 6), Color(s.r, s.g, s.b, 0.15))
			# Centre seam
			if w > h:
				draw_line(Vector2(w * 0.5, 5), Vector2(w * 0.5, h - 5), s, lw * 0.5)
			else:
				draw_line(Vector2(5, h * 0.5), Vector2(w - 5, h * 0.5), s, lw * 0.5)

		# ── Seats (office chair, outdoor chair, bar stool) ────────────────────
		"office_chair", "outdoor_chair", "bar_stool":
			var cr := minf(w, h) * 0.38
			var cc := Vector2(w * 0.5, h * 0.55)
			draw_circle(cc, cr, Color(s.r, s.g, s.b, 0.20))
			draw_arc(cc, cr, 0, TAU, 16, s, lw)
			# Back
			draw_arc(Vector2(w * 0.5, h * 0.18), w * 0.30, PI * 0.1, PI * 0.9, 10, s, lw)

		# ── Floor mirror ──────────────────────────────────────────────────────
		"floor_mirror":
			var mr2 := minf(w - 6.0, h * 0.60) * 0.5
			var mc2 := Vector2(w * 0.5, h * 0.40)
			draw_rect(Rect2(mc2.x - mr2, mc2.y - mr2 * 1.4, mr2 * 2, mr2 * 2.8),
					Color(s.r, s.g, s.b, 0.12))
			draw_rect(Rect2(mc2.x - mr2, mc2.y - mr2 * 1.4, mr2 * 2, mr2 * 2.8),
					s, false, lw)
			# Glare line
			draw_line(mc2 + Vector2(-mr2 * 0.3, -mr2 * 0.5),
					  mc2 + Vector2(-mr2 * 0.1, -mr2 * 0.2),
					  Color(s.r, s.g, s.b, 0.35), lw)
			# Stand base
			draw_line(Vector2(w * 0.5 - 4, h - 3), Vector2(w * 0.5 + 4, h - 3), s, lw)
			draw_line(Vector2(w * 0.5, mc2.y + mr2 * 1.4), Vector2(w * 0.5, h - 3), s, lw * 0.8)

		# ── Towel set (wall) / kitchen rack (wall) ────────────────────────────
		"towel_set":
			# Folded towel stacks
			var n_towels := maxi(1, int((w - 4) / 8))
			for ti2 in range(n_towels):
				var tx2 := 3.0 + ti2 * float(w - 6) / float(n_towels)
				var tw2 := float(w - 6) / float(n_towels) - 2
				draw_rect(Rect2(tx2, 2, tw2, h - 4), Color(s.r, s.g, s.b, 0.22))
				draw_line(Vector2(tx2, h * 0.5), Vector2(tx2 + tw2, h * 0.5),
						Color(s.r, s.g, s.b, 0.35), lw * 0.7)

		"kitchen_rack":
			# Horizontal rod with hanging hooks
			var ry2 := h * 0.35
			draw_line(Vector2(3, ry2), Vector2(w - 3, ry2), s, lw * 1.5)
			var n_hooks := maxi(2, int((w - 6) / 7))
			for hi3 in range(n_hooks):
				var hx3 := 5.0 + hi3 * float(w - 10) / float(n_hooks - 1) if n_hooks > 1 else w * 0.5
				draw_line(Vector2(hx3, ry2), Vector2(hx3, ry2 + (h - ry2) * 0.6), s, lw * 0.8)
				draw_arc(Vector2(hx3, ry2 + (h - ry2) * 0.6), 2.0,
						PI * 0.5, PI * 1.5, 6, Color(s.r, s.g, s.b, 0.55), lw * 0.8)


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


# Footprint this piece would have for a given moment's OWN stored fold state,
# without touching its real current grid_h/position. Used for free-space
# checks (e.g. "sport" needs enough open floor) that must account for a
# foldable piece being unfolded in one moment but folded in another.
func get_occupied_tiles_for_moment(moment_id: String) -> Array:
	var h := grid_h
	if foldable and extended_add_h > 0:
		var extended: bool = moment_fold_state.get(moment_id, false) as bool
		h = (_base_grid_h + extended_add_h) if extended else _base_grid_h
	var pos: Vector2i = grid_pos
	if rail_axis != "" and moment_rail_pos.has(moment_id):
		pos = moment_rail_pos[moment_id]
	var tiles: Array = []
	for x in range(grid_w):
		for y in range(h):
			tiles.append(Vector2i(pos.x + x, pos.y + y))
	return tiles


func _input(event: InputEvent) -> void:
	# ── Placement mode: furniture follows cursor until click or Esc ───────────
	if _placement_mode:
		if get_viewport().is_input_handled():
			return
		if event is InputEventMouseMotion:
			_drag(event.position)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if Furniture.is_in_floor_pane.is_valid() and not Furniture.is_in_floor_pane.call(event.position):
				return   # click landed on another panel (e.g. Wall Inspector) — let it through
			var sx := int(position.x / TILE_SIZE)
			var sy := int(position.y / TILE_SIZE)
			var snap_pos := _wall_ref.snap_to_wall(self, Vector2i(sx, sy)) if _wall_ref else Vector2i(sx, sy)
			if not (_wall_ref and _wall_ref.can_place(self, snap_pos)):
				_play("error")
				get_viewport().set_input_as_handled()
				return
			_placement_mode = false
			_dragging = false
			_wall_ref.place_furniture(self, snap_pos)
			_wall_ref.grid_draw.show_grid = false
			_wall_ref.grid_draw.queue_redraw()
			placement_confirmed.emit()
			queue_redraw()
			get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			cancel_placement()
			get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R and _is_mouse_over():
			_rotate()
			get_viewport().set_input_as_handled()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _is_mouse_over():
				_press_pos = event.position
				_start_drag(event.position)
			elif _dragging and not event.pressed:
				var release_pos: Vector2 = (event as InputEventMouseButton).position
				var was_click: bool = release_pos.distance_to(_press_pos) < CLICK_MOVE_THRESHOLD
				if was_click and Furniture.test_mode_active and foldable:
					_dragging = false
					z_index = 0
					if _wall_ref:
						_wall_ref.grid_draw.show_grid = false
						_wall_ref.grid_draw.queue_redraw()
					position = _original_pos
					queue_redraw()
					toggle_fold()
				else:
					_end_drag(event.position)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if _is_mouse_over():
				sell_requested.emit(self)
				get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion and _dragging:
		_drag(event.position)


func _is_mouse_over() -> bool:
	var local_mouse := get_local_mouse_position()
	var sz := Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	return Rect2(Vector2.ZERO, sz).has_point(local_mouse)


func _start_drag(mouse_pos: Vector2) -> void:
	_dragging = true
	_drag_offset = position - _wall_ref.to_local(mouse_pos)
	_original_pos = position
	z_index = 10
	if _wall_ref:
		_wall_ref.grid_draw.show_grid = true
		_wall_ref.grid_draw.queue_redraw()
	# Lock rail axis on drag start
	if rail_axis == "h":
		_rail_lock = grid_pos.y
	elif rail_axis == "v":
		_rail_lock = grid_pos.x
	queue_redraw()


func _drag(mouse_pos: Vector2) -> void:
	if not _wall_ref:
		return
	var target := _wall_ref.to_local(mouse_pos) + _drag_offset
	var snapped_x := int(target.x / TILE_SIZE)
	var snapped_y := int(target.y / TILE_SIZE)
	if rail_axis == "h" and _rail_lock >= 0:
		snapped_y = _rail_lock
		var mn_x := 0                        if rail_start < 0 else rail_start
		var mx_x := _wall_ref.grid_w - grid_w if rail_end   < 0 else rail_end
		snapped_x = clampi(snapped_x, mn_x, mx_x)
	elif rail_axis == "v" and _rail_lock >= 0:
		snapped_x = _rail_lock
		var mn_y := 0                        if rail_start < 0 else rail_start
		var mx_y := _wall_ref.grid_h - grid_h if rail_end   < 0 else rail_end
		snapped_y = clampi(snapped_y, mn_y, mx_y)
	else:
		snapped_x = clampi(snapped_x, 0, _wall_ref.grid_w - grid_w)
		snapped_y = clampi(snapped_y, 0, _wall_ref.grid_h - grid_h)
	position = Vector2(snapped_x * TILE_SIZE, snapped_y * TILE_SIZE)
	_wall_ref.set_floor_drag_ghost(self, snapped_x, snapped_y)
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
	if _wall_ref:
		_wall_ref.grid_draw.show_grid = false
		_wall_ref.grid_draw.queue_redraw()
		_wall_ref.clear_floor_drag_ghost()
	queue_redraw()
	var snapped_x := int(position.x / TILE_SIZE)
	var snapped_y := int(position.y / TILE_SIZE)
	var snap_pos := _wall_ref.snap_to_wall(self, Vector2i(snapped_x, snapped_y)) if _wall_ref else Vector2i(snapped_x, snapped_y)

	if _wall_ref and _wall_ref.can_place(self, snap_pos):
		_wall_ref.place_furniture(self, snap_pos)
		if rail_axis != "" and Furniture.test_mode_active:
			moment_rail_pos[Furniture.active_moment_id] = grid_pos
		_play("place")
		placed.emit(self)
	else:
		_play("error")
		position = _original_pos


func cancel_placement() -> void:
	if not _placement_mode:
		return
	_placement_mode = false
	_dragging = false
	if _wall_ref:
		_wall_ref.grid_draw.show_grid = false
		_wall_ref.grid_draw.queue_redraw()
	placement_cancelled.emit()
	queue_free()


func begin_placement(floor: Floor, mouse_pos: Vector2) -> void:
	_wall_ref       = floor
	_placement_mode = true
	_dragging       = true
	_drag_offset    = -Vector2(grid_w, grid_h) * TILE_SIZE * 0.5
	z_index         = 10
	if _wall_ref:
		_wall_ref.grid_draw.show_grid = true
		_wall_ref.grid_draw.queue_redraw()
	_drag(mouse_pos)
	queue_redraw()
