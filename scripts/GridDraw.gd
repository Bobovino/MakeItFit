extends Node2D
class_name GridDraw

const TILE_SIZE    := 8
# ── Cyanotype blueprint palette ───────────────────────────────────────────────
# Everything reads as a classic architectural blueprint: white/cyan ink on
# deep blue. Room interior is a slightly lighter blue so it reads as "inside".
# The plan is drawn in chalk on the drawing board: the sheet a deeper indigo
# than the board around it, the rooms deeper still, white walls.
const BP_PAPER     := Color("3b3e74")                  # the sheet (GameTheme.INDIGO_DK)
const BP_FLOOR     := Color("2c2f63")                  # room interior, deeper
const BP_INK       := Color(1, 1, 1, 1.0)              # chalk white
const BP_INK_SOFT  := Color("c9cbe6")                  # secondary lines (GameTheme.CHALK_SOFT)
const BP_GRID_FINE := Color(1, 1, 1, 0.05)             # 10 cm subcell grid (quiet)
const BP_GRID_MAJ  := Color(1, 1, 1, 0.14)             # 1 m grid lines (quiet)

# ── The plan itself: a white sheet in black ink ───────────────────────────────
# Drawn as flats are drawn in Spain, solid black walls on white, lying on the
# blueprint drawing board (the screen behind it). The BP_* colours above stay
# for the blueprint previews (the map's cards, the catalogue).
const PLAN_PAPER    := Color("fbfaf6")   # the sheet
const PLAN_FLOOR    := Color("ffffff")   # the rooms
const PLAN_INK      := Color("141414")   # walls, dimensions
const PLAN_INK_SOFT := Color("6b6b6b")   # secondary lines

const FLOOR_COLOR  := PLAN_FLOOR
const WALL_COLOR   := PLAN_INK
const GRID_MINOR   := BP_GRID_FINE
const GRID_MAJOR   := BP_GRID_MAJ
const DOOR_COLOR   := Color("4a4a4a")                # door swing, a fine grey line
const WINDOW_COLOR := Color(0.30, 0.56, 0.80, 0.95)  # glazing, the one blue on the plan
const EDGE_HOVER   := Color(0.85, 0.27, 0.25, 0.55)   # GameTheme.RED
const EDGE_ACTIVE  := Color(0.85, 0.27, 0.25, 1.0)
const WALL_THICK   := 6.0
const EDGE_W       := 10.0   # clickable strip width — must match Wall.gd EDGE_MARGIN
const METER_TILES  := 10
# The sheet past the flat's walls, in screen px (it keeps one size at any
# zoom): a narrow edge top and left, room for the dimensions bottom and
# right. Main._fit_floor leaves room for it.
const SHEET_EDGE := 12.0
const SHEET_DIMS := 48.0

# Shared paper-grain texture — generated once, tiled over every sheet
static var _grain_tex: ImageTexture = null

static func _get_grain() -> ImageTexture:
	if _grain_tex == null:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX
		n.frequency = 0.55
		n.seed = 7
		var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
		for y in range(128):
			for x in range(128):
				var v := clampf(n.get_noise_2d(x, y) * 0.5 + 0.5, 0.0, 1.0)
				img.set_pixel(x, y, Color(1, 1, 1, v))
		_grain_tex = ImageTexture.create_from_image(img)
	return _grain_tex


var _hovered_edge:    String = ""
# Whether hovering a wall on the plan lights it up as something to click.
# Main.gd turns this off: walls are no longer opened from the plan (hanging
# things on walls happens in the 3D view), so a highlight would promise a
# click that does nothing. The level editor leaves it on.
var wall_select_enabled: bool = true
var _active_edge:     String = ""
var _hovered_seg_idx: int   = -1   # new-format hover: nearest segment index
var _gm: GameManager = null
var show_subfloor: bool = false
var show_ceiling:  bool = false
var show_grid:     bool = false
# While a piece that has to stand against a wall is dragged (show_grid on),
# every stretch of wall it can back onto is lit up.
var wall_cue:      bool = false
# GameManager.quiet_status (set by Main): the quiet zone round each thing
# that mustn't be woken and the way from a bed to the toilet.
var quiet_routes:  Array = []
# Set by LevelEditor.gd on its own preview Floor only. Gameplay (Main.gd)
# leaves this false: the sheet there should hug the actual apartment walls
# tightly so players get a clear "this is where the apartment ends, you
# can't place furniture past it" signal. The editor wants the opposite —
# a generous blueprint grid that doesn't shrink down to whatever's been
# drawn so far — so it unions the real bounds with a big default view.
var editor_mode:   bool = false


func set_active_edge(edge: String) -> void:
	if _active_edge != edge:
		_active_edge = edge
		queue_redraw()


func _ready() -> void:
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED   # lets the grain tile
	_gm = get_tree().get_first_node_in_group("game_manager") as GameManager
	var parent := get_parent() as Floor
	if parent:
		parent.furniture_changed.connect(queue_redraw)
	# Daylight on its own layer, over the plan and under the furniture (the
	# Floor's other children).
	# Rooms given to residents: their colour on the floor, under the light.
	_room_layer = Node2D.new()
	_room_layer.draw.connect(_draw_room_layer)
	add_child(_room_layer)
	_light_layer = Node2D.new()
	_light_layer.draw.connect(_draw_light_layer)
	add_child(_light_layer)
	# Each room's name and its residents' faces, over the furniture.
	_room_tags = Node2D.new()
	_room_tags.z_index = 19
	_room_tags.draw.connect(_draw_room_tags)
	if parent:
		parent.add_child.call_deferred(_room_tags)


func _process(_delta: float) -> void:
	var parent: Floor = get_parent() as Floor
	if not parent or not parent.visible or not wall_select_enabled:
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
	if is_instance_valid(_room_layer):
		_room_layer.queue_redraw()
	if is_instance_valid(_room_tags):
		_room_tags.queue_redraw()
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

	_draw_split_levels(parent)
	_draw_sloped_ceiling(parent)
	_draw_partitions(parent)
	_draw_columns(parent)
	for wall_def in parent.wall_definitions:
		_draw_wall_feature(wall_def, w, h)


func _draw_new_format(parent: Floor, w: int, h: int, _rw: int, _rh: int) -> void:
	# A white sheet, its grid in faint pencil.
	const CANVAS_BG   := PLAN_PAPER
	const FINE_COL    := Color(0, 0, 0, 0.07)  # 10 cm subcell lines
	const MAJOR_COL   := Color(0, 0, 0, 0.10)  # 1 m cell lines (darker)

	# The level's authored canvas (grid_w x grid_h) is usually much bigger than
	# any one room actually uses — drawing the paper sheet/grid across the
	# whole thing buried the room in a sea of empty gridlines. Clip the
	# background, frame, and gridlines to the room's real bounds plus a small
	# margin instead; everything else in this function still draws in the
	# same absolute tile coordinates, so nothing else needs to move.
	var bounds := _room_bounds_tiles(parent)
	var ww := w * TILE_SIZE
	var hh := h * TILE_SIZE
	# World px per screen px: the sheet's margins are given on screen.
	var k := 1.0 / maxf(get_global_transform_with_canvas().get_scale().x, 0.001)
	var sheet_x := bounds.position.x * TILE_SIZE - SHEET_EDGE * k
	var sheet_y := bounds.position.y * TILE_SIZE - SHEET_EDGE * k
	var sheet_w := bounds.size.x * TILE_SIZE + (SHEET_EDGE + SHEET_DIMS) * k
	var sheet_h := bounds.size.y * TILE_SIZE + (SHEET_EDGE + SHEET_DIMS) * k

	# ── Adaptive zoom ─────────────────────────────────────────────────────────
	# Use the canvas transform scale to determine effective px-per-tile,
	# which works regardless of where the Camera2D sits in the scene tree.
	var ct_scale := get_viewport().get_canvas_transform().get_scale().x \
		if get_viewport() else 1.0
	var px_per_tile := ct_scale * float(TILE_SIZE)
	# Fade the 10cm subcell lines in/out smoothly over a zoom range instead of
	# a hard on/off cutoff — a single threshold made them pop in and out
	# abruptly while zooming, which read as the grid glitching.
	var fine_fade   := clampf((px_per_tile - 3.0) / 4.0, 0.0, 1.0)
	var show_fine   := fine_fade > 0.02

	# ── 1. Canvas background — a paper sheet lying on the desk ───────────────
	# Stacked soft drop shadows first, so the blueprint reads as a physical
	# document resting on the warm desk surface behind it.
	# The sheet stands on a navy edge, like every card of the look.
	draw_rect(Rect2(sheet_x + 4 * k, sheet_y + 5 * k, sheet_w, sheet_h), Color("1b2759"))
	draw_rect(Rect2(sheet_x, sheet_y, sheet_w, sheet_h), CANVAS_BG)
	draw_rect(Rect2(sheet_x, sheet_y, sheet_w, sheet_h), GameTheme.NAVY, false, 1.5 * k)

	# ── 1b. Shadow tiles — parent floor ghost when editing a loft ─────────────
	if not parent.shadow_mask.is_empty():
		const SHADOW_COL := Color(0.82, 0.79, 0.72, 0.38)
		for tile in parent.shadow_mask:
			var t := tile as Vector2i
			draw_rect(Rect2(t.x * TILE_SIZE, t.y * TILE_SIZE, TILE_SIZE, TILE_SIZE), SHADOW_COL)

	# ── 1c. Ghost of the floor stacked below (gameplay) — mirrors Room3DView's
	# _add_ghost_floor: a mezzanine/loft or upper floor shows the floor beneath
	# it (walls + furniture silhouettes) as a faint reference layer so the
	# player doesn't lose their bearings switching floors. Distinct from
	# shadow_mask above (LevelEditor-only, floor tiles only, no walls/furniture).
	if parent.below_floor:
		const BELOW_FLOOR_COL := Color(0.82, 0.79, 0.72, 0.30)
		const BELOW_WALL_COL  := Color(0.55, 0.56, 0.58, 0.55)
		const BELOW_FURN_COL  := Color(0.55, 0.56, 0.58, 0.35)
		var below := parent.below_floor
		for tile in below.floor_mask:
			var t := tile as Vector2i
			draw_rect(Rect2(t.x * TILE_SIZE, t.y * TILE_SIZE, TILE_SIZE, TILE_SIZE), BELOW_FLOOR_COL)
		for seg in below.segments:
			if (seg as Dictionary).get("demolished", false):
				continue
			var x1: int = seg["x1"]; var y1: int = seg["y1"]
			var x2: int = seg["x2"]; var y2: int = seg["y2"]
			draw_line(Vector2(x1 * TILE_SIZE, y1 * TILE_SIZE), Vector2(x2 * TILE_SIZE, y2 * TILE_SIZE), BELOW_WALL_COL, 3.0)
		for item in below.get_all_furniture():
			var f := item as Furniture
			draw_rect(Rect2(f.grid_pos.x * TILE_SIZE, f.grid_pos.y * TILE_SIZE,
				f.grid_w * TILE_SIZE, f.grid_h * TILE_SIZE), BELOW_FURN_COL)

	# ── 2. Painted floor tiles (blueprint blue, or tinted by kind) ───────────
	const BALCONY_COL  := Color("efe7d6")   # outdoor decking, a warm tint
	const BATHROOM_COL := Color("eaf0f4")   # wet-room tiles, a cool tint
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
	# A level with a zone rule always shows its zones, even while the whole
	# room is still one: that single tinted, flagged zone IS the problem the
	# player has to solve. A zone that breaks a rule is red.
	var zone_rules := not parent.zone_status.is_empty()
	if parent.zones.size() > 1 or zone_rules:
		for zi in parent.zones.size():
			var z     := parent.zones[zi] as Dictionary
			var z_fns := z.get("functions", []) as Array
			var z_col := Color(0, 0, 0, 0)
			if   "sleep" in z_fns:                     z_col = Color(0.36, 0.52, 0.82, 0.14)  # blue
			elif "cook"  in z_fns:                     z_col = Color(0.82, 0.42, 0.28, 0.14)  # red
			elif "sit"   in z_fns or "dine" in z_fns:  z_col = Color(0.78, 0.68, 0.28, 0.14)  # amber
			elif "work"  in z_fns:                     z_col = Color(0.32, 0.70, 0.42, 0.14)  # green
			if zone_rules:
				z_col = RuleOverlay.zone_color(zi, zi < parent.zone_status.size() and (parent.zone_status[zi] as Dictionary)["conflict"] as bool)
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
		var _sfill := STAIR_FILL   if _tgt == "loft" else FSTAIR_FILL
		var _snos  := STAIR_NOSING if _tgt == "loft" else FSTAIR_NOSING
		var _sbdr  := STAIR_BORDER if _tgt == "loft" else FSTAIR_BORDER
		var _sarr  := STAIR_ARROW  if _tgt == "loft" else FSTAIR_ARROW
		_draw_flight(_r, _dir, _sfill, _snos, _sbdr, _sarr, false)
		if _tgt == "floor":
			_draw_stair_word(_r, _dir, false, tr("Up"), _sarr)

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

	# ── 2d. Stair openings: the stairwell a flight from the floor below comes up through
	# A hole in this floor, the flight below seen down it: drawn in ink on a
	# grey wash, as the same staircase seen from above.
	const SO_FILL   := Color(0.30, 0.34, 0.46, 0.24)
	const SO_BORDER := Color(0.12, 0.14, 0.24, 1.00)
	const SO_NOSING := Color(0.12, 0.14, 0.24, 0.70)
	const SO_ARROW  := Color(0.12, 0.14, 0.24, 1.00)
	for _op in parent.stair_openings:
		var _opd   := _op as Dictionary
		var _opr   := _opd["rect"] as Rect2i
		var _opdir := _opd.get("direction", "north") as String
		_draw_flight(_opr, _opdir, SO_FILL, SO_NOSING, SO_BORDER, SO_ARROW, true)
		if (_opd.get("target", "loft") as String) == "floor":
			_draw_stair_word(_opr, _opdir, true, tr("Down"), SO_ARROW)

	# ── 2d'. Stair landings (Floor.stair_layout): floor kept clear at the foot
	# of a flight and where one arrives, a dashed outline like a clearance.
	const LANDING_FILL := Color(0.78, 0.58, 0.22, 0.10)
	const LANDING_LINE := Color(0.65, 0.42, 0.10, 0.85)
	# Landings that meet (one arriving where the next flight starts) read as
	# one area: the outline goes round them together.
	var _land := parent.stair_landing_tiles()
	for _t in _land:
		var _v := _t as Vector2i
		var _o := Vector2(_v * TILE_SIZE)
		var _ts := float(TILE_SIZE)
		draw_rect(Rect2(_o, Vector2(_ts, _ts)), LANDING_FILL)
		for _e in [[Vector2i(0, -1), _o, _o + Vector2(_ts, 0)], [Vector2i(0, 1), _o + Vector2(0, _ts), _o + Vector2(_ts, _ts)],
				[Vector2i(-1, 0), _o, _o + Vector2(0, _ts)], [Vector2i(1, 0), _o + Vector2(_ts, 0), _o + Vector2(_ts, _ts)]]:
			if not _land.has(_v + (_e[0] as Vector2i)):
				draw_dashed_line(_e[1], _e[2], LANDING_LINE, 1.5, 3.0)

	# ── 2e. Rail tracks ──────────────────────────────────────────────────────
	# A sliding door's floor guide: one thin line with a stop at each end. The
	# track each piece on a rail runs along (Floor.rail_track), and the
	# floor's own rails that no piece rides.
	for item in parent.get_all_furniture():
		var tr_d := parent.rail_track(item as Furniture)
		if not tr_d.is_empty():
			_draw_rail_track(tr_d["h"] as bool, tr_d["from"] as float, tr_d["to"] as float, tr_d["at"] as float)
	for rail in parent.rails:
		var rd := rail as Dictionary
		if parent.rail_ridden(rd):
			continue
		var x1: int = rd["x1"]; var y1: int = rd["y1"]
		var x2: int = rd["x2"]; var y2: int = rd["y2"]
		var is_h_r := (y1 == y2)
		if is_h_r:
			_draw_rail_track(true, mini(x1, x2), maxi(x1, x2) + 1, y1 + 0.5)
		else:
			_draw_rail_track(false, mini(y1, y2), maxi(y1, y2) + 1, x1 + 0.5)

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
	# Line widths are specified in WORLD units, but a fixed width renders as
	# less than one actual screen pixel once zoomed out far enough — sub-pixel
	# non-antialiased lines rasterize inconsistently frame to frame (some
	# columns/rows a hair brighter than others), which reads as the grid
	# "glitching" or looking irregular while zoomed out. Floor both widths at
	# a minimum on-screen pixel size (accounting for the current zoom via
	# ct_scale) and draw them antialiased so they stay crisp at any zoom.
	var min_px_fine := 1.0 / maxf(ct_scale, 0.001)
	var min_px_maj  := 1.4 / maxf(ct_scale, 0.001)
	var fine_base_a := 1.0 if show_grid else 0.22
	var fine_col := Color(FINE_COL.r, FINE_COL.g, FINE_COL.b, FINE_COL.a * fine_base_a * fine_fade)
	var maj_col  := MAJOR_COL if show_grid else Color(MAJOR_COL.r, MAJOR_COL.g, MAJOR_COL.b, MAJOR_COL.a * 0.6)
	# Only inside the flat: out past its walls the sheet stays clean, for the
	# dimensions.
	var gx0 := bounds.position.x
	var gy0 := bounds.position.y
	var gx1 := bounds.position.x + bounds.size.x
	var gy1 := bounds.position.y + bounds.size.y
	var top_px := float(gy0 * TILE_SIZE)
	var bottom_px := float(gy1 * TILE_SIZE)
	var left_px := float(gx0 * TILE_SIZE)
	var right_px := float(gx1 * TILE_SIZE)
	if show_fine:
		for x in range(gx0, gx1 + 1):
			if x % METER_TILES != 0:
				draw_line(Vector2(x * TILE_SIZE, top_px), Vector2(x * TILE_SIZE, bottom_px), fine_col, min_px_fine, true)
		for y in range(gy0, gy1 + 1):
			if y % METER_TILES != 0:
				draw_line(Vector2(left_px, y * TILE_SIZE), Vector2(right_px, y * TILE_SIZE), fine_col, min_px_fine, true)
	for x in range(gx0 - gx0 % METER_TILES, gx1 + 1, METER_TILES):
		if x >= gx0:
			draw_line(Vector2(x * TILE_SIZE, top_px), Vector2(x * TILE_SIZE, bottom_px), maj_col, min_px_maj, true)
	for y in range(gy0 - gy0 % METER_TILES, gy1 + 1, METER_TILES):
		if y >= gy0:
			draw_line(Vector2(left_px, y * TILE_SIZE), Vector2(right_px, y * TILE_SIZE), maj_col, min_px_maj, true)

	# ── 4. Natural light hatching (only over painted tiles) ───────────────────
	_draw_natural_light(parent)

	_draw_columns(parent)
	_draw_segments(parent)
	if show_grid and wall_cue:
		_draw_wall_cue(parent)
	_draw_quiet_routes()
	GridDraw.draw_loop_seams(self, parent.loop, parent.get_room_bounds(), TILE_SIZE)
	_draw_split_levels(parent)
	_draw_sloped_ceiling(parent)

	# ── 5. Blueprint annotations: dimension lines ─────────────────────────────
	# The corner title block (tenant/area/scale/sheet#) used to draw here too —
	# removed in favor of the TenantCard bar adopting the same blueprint
	# title-block styling instead (see TenantCard.gd), so the same
	# information doesn't appear twice, and it no longer visually collides
	# with the floor-tab stack for multi-floor levels.
	_draw_dimensions(parent, ww, hh)


# Looped flats (LoopSeams): each opening that leads back into the flat is a
# gap in the wall, tinted in its pair's colour, with arrows pointing out
# through it and the pair's letter outside, the same letter at both ends.
# Static so the level preview cards (BlueprintPreview) draw them the same
# way; `ts` is pixels per tile on `ci`.
const SEAM_COLORS := [Color(0.42, 0.82, 1.0), Color(1.0, 0.72, 0.30), Color(0.78, 0.58, 1.0), Color(0.46, 0.94, 0.62)]

static func seam_color(pair: int) -> Color:
	return SEAM_COLORS[pair % SEAM_COLORS.size()]


static func draw_loop_seams(ci: CanvasItem, loop: LoopSeams, b: Rect2i, ts: float, with_labels := true) -> void:
	if loop == null:
		return
	var font := ThemeDB.fallback_font
	for o in loop.openings():
		var side := o["side"] as String
		var f0 := float(o["from"] as int) * ts
		var f1 := float(o["to"] as int) * ts
		var col := seam_color(o["pair"] as int)
		var r: Rect2
		var out_dir: Vector2
		match side:
			"west":
				r = Rect2(b.position.x * ts, f0, ts, f1 - f0); out_dir = Vector2.LEFT
			"east":
				r = Rect2(b.end.x * ts, f0, ts, f1 - f0); out_dir = Vector2.RIGHT
			"north":
				r = Rect2(f0, b.position.y * ts, f1 - f0, ts); out_dir = Vector2.UP
			_:
				r = Rect2(f0, b.end.y * ts, f1 - f0, ts); out_dir = Vector2.DOWN
		# The wall is open here.
		ci.draw_rect(r, BP_FLOOR)
		ci.draw_rect(r, Color(col.r, col.g, col.b, 0.35))
		var along := Vector2(out_dir.y, -out_dir.x).abs()
		var inner := r.get_center() - out_dir * r.size.dot(out_dir.abs()) * 0.5
		var outer := r.get_center() + out_dir * r.size.dot(out_dir.abs()) * 0.5
		var half := along * r.size.dot(along) * 0.5
		ci.draw_dashed_line(inner - half, inner + half, col, maxf(1.0, ts * 0.2), ts * 0.6)
		ci.draw_line(outer - half, outer + half, col, maxf(1.5, ts * 0.3))
		# Arrows out through the opening, about one a metre.
		var n := maxi(1, int(round(r.size.dot(along) / (ts * 10.0))))
		var arrow := ts * 0.9
		for i in n:
			var c := r.get_center() - half + along * r.size.dot(along) * (i + 0.5) / n
			ci.draw_line(c - out_dir * arrow * 0.5 - along * arrow * 0.6, c + out_dir * arrow * 0.5, col, maxf(1.0, ts * 0.22), true)
			ci.draw_line(c - out_dir * arrow * 0.5 + along * arrow * 0.6, c + out_dir * arrow * 0.5, col, maxf(1.0, ts * 0.22), true)
		if with_labels:
			var tag := String.chr(65 + (o["pair"] as int))
			# A quarter of the way along, clear of the dimension text that
			# sits at a wall's middle.
			var at := outer - half * 0.5 + out_dir * ts * 1.6
			ci.draw_circle(at, ts * 1.1, col)
			var fs := maxi(8, int(ts * 1.4))
			var sz := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			ci.draw_string(font, at + Vector2(-sz.x * 0.5, sz.y * 0.32), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.06, 0.08, 0.20))


# Is this Floor node a real floor plate (worth annotating) vs a subfloor/
# ceiling/roof overlay layer? Real plates carry wall segments or a floor mask.
func _is_plate(parent: Floor) -> bool:
	return not parent.segments.is_empty() or not parent.floor_mask.is_empty()


# Room bounding box (in tiles): the union of floor mask + wall segments (not
# either/or) — a room is usually walled in one full stroke but floor-painted
# tile by tile, so preferring floor_mask alone made the drafting sheet shrink
# to a near-nothing patch the instant a room had walls but only one or two
# painted floor tiles.
#
# Gameplay (editor_mode == false) hugs the actual apartment tightly — this is
# what makes "you can't place furniture past the walls" visually legible, so
# it must NOT be padded out with a big generous default.
#
# The Level Editor's own preview Floor sets editor_mode = true, and instead
# always shows the WHOLE fixed-but-generous grid_w x grid_h canvas — this is
# the actual drawn paper/gridlines you pan around in, independent of where
# the camera happens to start framed. It must NOT shrink to a small default
# when the floor is empty (that's a separate concern, handled purely by
# LevelEditor's own _content_bounds_tiles() for the camera's initial
# framing) — conflating the two meant panning an empty floor hit a dead
# void just past a small patch instead of a continuous 300x300m grid.
const MIN_SHEET_TILES := 10

func _room_bounds_tiles(parent: Floor) -> Rect2i:
	if editor_mode:
		return Rect2i(0, 0, parent.grid_w, parent.grid_h)

	var mnx := 1 << 30; var mny := 1 << 30
	var mxx := -(1 << 30); var mxy := -(1 << 30)
	var any := false
	for tile in parent.floor_mask:
		var t := tile as Vector2i
		mnx = mini(mnx, t.x); mny = mini(mny, t.y)
		mxx = maxi(mxx, t.x); mxy = maxi(mxy, t.y)
		any = true
	for seg in parent.segments:
		var sd := seg as Dictionary
		for xy in [[sd["x1"], sd["y1"]], [sd["x2"], sd["y2"]]]:
			mnx = mini(mnx, xy[0] as int); mny = mini(mny, xy[1] as int)
			mxx = maxi(mxx, xy[0] as int); mxy = maxi(mxy, xy[1] as int)
			any = true

	if not any:
		return Rect2i(0, 0, parent.grid_w, parent.grid_h)
	var w := mxx - mnx + 1
	var h := mxy - mny + 1
	if w < MIN_SHEET_TILES:
		mnx -= (MIN_SHEET_TILES - w) / 2
		w = MIN_SHEET_TILES
	if h < MIN_SHEET_TILES:
		mny -= (MIN_SHEET_TILES - h) / 2
		h = MIN_SHEET_TILES
	return Rect2i(mnx, mny, w, h)


# The flat's outer width and depth as an architect's dimension lines on the
# sheet, clear of the walls: extension lines out from the wall faces, the
# dimension line between them with a slash at each end, and the measure
# written over its middle.
const DIM_OFF := 26.0    # from the wall face to the dimension line, screen px
const DIM_FONT := 13     # screen px: the dimensions keep one size on screen at any zoom

func _draw_dimensions(parent: Floor, _ww: int, _hh: int) -> void:
	if not _is_plate(parent):
		return
	const DIM_COL := Color(0.08, 0.08, 0.08, 0.85)
	const EXT_COL := Color(0.08, 0.08, 0.08, 0.40)
	var b := _room_bounds_tiles(parent)
	var font := GameTheme.font("mono")
	# World px per screen px: offsets and lettering are given on screen.
	var k := 1.0 / maxf(get_global_transform_with_canvas().get_scale().x, 0.001)
	var off := DIM_OFF * k
	var left   := float(b.position.x * TILE_SIZE)
	var right  := float((b.position.x + b.size.x) * TILE_SIZE)
	var top    := float(b.position.y * TILE_SIZE)
	var bottom := float((b.position.y + b.size.y) * TILE_SIZE)
	# Under the flat: its width.
	var px := k   # one screen pixel
	var tick := 4.0 * k
	# Under the flat: its width.
	var dy := bottom + off
	draw_line(Vector2(left, bottom + tick), Vector2(left, dy + tick), EXT_COL, px, true)
	draw_line(Vector2(right, bottom + tick), Vector2(right, dy + tick), EXT_COL, px, true)
	draw_line(Vector2(left, dy), Vector2(right, dy), DIM_COL, px, true)
	for x in [left, right]:
		draw_line(Vector2(x - tick, dy + tick), Vector2(x + tick, dy - tick), DIM_COL, 1.6 * px, true)
	var wtxt := "%.2f m" % (b.size.x / float(METER_TILES))
	var wsz := font.get_string_size(wtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, DIM_FONT)
	draw_set_transform(Vector2((left + right) * 0.5 - wsz.x * 0.5 * k, dy - 4.0 * k), 0.0, Vector2(k, k))
	draw_string(font, Vector2.ZERO, wtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, DIM_FONT, DIM_COL)
	# To its right: its depth, written along the line.
	var dx := right + off
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	draw_line(Vector2(right + tick, top), Vector2(dx + tick, top), EXT_COL, px, true)
	draw_line(Vector2(right + tick, bottom), Vector2(dx + tick, bottom), EXT_COL, px, true)
	draw_line(Vector2(dx, top), Vector2(dx, bottom), DIM_COL, px, true)
	for y in [top, bottom]:
		draw_line(Vector2(dx - tick, y + tick), Vector2(dx + tick, y - tick), DIM_COL, 1.6 * px, true)
	var htxt := "%.2f m" % (b.size.y / float(METER_TILES))
	var hsz := font.get_string_size(htxt, HORIZONTAL_ALIGNMENT_LEFT, -1, DIM_FONT)
	draw_set_transform(Vector2(dx - 4.0 * k, (top + bottom) * 0.5 + hsz.x * 0.5 * k), -PI * 0.5, Vector2(k, k))
	draw_string(font, Vector2.ZERO, htxt, HORIZONTAL_ALIGNMENT_LEFT, -1, DIM_FONT, DIM_COL)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


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
	const PRIMARY_COL   := PLAN_INK                       # solid black wall
	const SECONDARY_COL := Color("333333")                # interior partition, a touch lighter
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
		# A glass wall: pale and see-through on the plan, so it reads as
		# "light comes through here" next to the solid walls.
		if sd.get("translucent", false) as bool:
			col = Color(0.55, 0.95, 0.90, 0.45)
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
			const WV_COL  := Color(0.20, 0.50, 0.62, 0.95)
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
	const TRACK_COL := Color(0.25, 0.25, 0.25, 0.90)
	const PANEL_COL := Color(0.25, 0.25, 0.25, 0.35)
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
	# Contour lines every 20 cm of ceiling height, drawn along the tile edges
	# where the ceiling crosses one, so any mix of ramps (a gable, a dormer)
	# reads the same way. Where it is under 2 m the floor is tinted.
	if not parent.has_sloped_ceiling():
		return
	const CONTOUR_STEP := 0.2
	const CONTOUR_COL  := Color(0.50, 0.66, 0.95, 0.85)   # reads on the paper plan and the blueprint
	var bounds := parent.get_room_bounds()
	var band := func(t: Vector2i) -> int:
		return floori(parent.ceiling_height_at(Vector2(t)) / CONTOUR_STEP + 0.0001)
	var labelled: Dictionary = {}
	for x in range(bounds.position.x, bounds.end.x):
		for y in range(bounds.position.y, bounds.end.y):
			var t := Vector2i(x, y)
			if not parent.is_floor_tile(t):
				continue
			var h := parent.ceiling_height_at(Vector2(t))
			if h < 2.0:
				draw_rect(Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE), Color(0.50, 0.62, 0.95, 0.10))
			var b: int = band.call(t)
			for n in [Vector2i(1, 0), Vector2i(0, 1)]:
				var o: Vector2i = t + n
				if not parent.is_floor_tile(o) or band.call(o) == b:
					continue
				var a := Vector2((x + n.x) * TILE_SIZE, (y + n.y) * TILE_SIZE)
				var e := a + (Vector2(0, TILE_SIZE) if n.x == 1 else Vector2(TILE_SIZE, 0))
				draw_line(a, e, CONTOUR_COL, 1.0)
				var hb := maxi(b, band.call(o))
				if hb % 2 == 0 and not labelled.has(hb):
					labelled[hb] = true
					draw_string(ThemeDB.fallback_font, a + Vector2(2, 12), "%.1fm" % (hb * CONTOUR_STEP),
						HORIZONTAL_ALIGNMENT_LEFT, 32, 9, CONTOUR_COL)

	var room_x0 := bounds.position.x * TILE_SIZE
	var room_y0 := bounds.position.y * TILE_SIZE
	var room_x1 := bounds.end.x * TILE_SIZE
	var room_y1 := bounds.end.y * TILE_SIZE
	if parent.ceiling_ramps.size() == 1:
		var sc := parent.ceiling_ramps[0] as Dictionary
		var low_s := sc.get("low_start", 0) as int
		var high_e := sc.get("high_end", 0) as int
		_draw_slope_info(sc.get("axis", "x") as String, low_s, high_e, sc.get("min_h", 1.8) as float,
			sc.get("max_h", 2.4) as float, absi(high_e - low_s), room_x0, room_y0, room_x1, room_y1)
	else:
		var lo := INF
		var hi := -INF
		for x in range(bounds.position.x, bounds.end.x):
			for y in range(bounds.position.y, bounds.end.y):
				if parent.is_floor_tile(Vector2i(x, y)):
					var h := parent.ceiling_height_at(Vector2(x, y))
					lo = minf(lo, h)
					hi = maxf(hi, h)
		draw_rect(Rect2(room_x0, room_y0 - 16, room_x1 - room_x0, 15), Color(0.93, 0.93, 0.90, 0.85))
		draw_string(ThemeDB.fallback_font, Vector2(room_x0 + 4, room_y0 - 5),
			tr("Sloped ceiling: %.2fm to %.2fm") % [lo, hi], HORIZONTAL_ALIGNMENT_LEFT, room_x1 - room_x0 - 8, 11,
			Color(0.15, 0.15, 0.18, 1.0))


# Raised platforms and sunken areas: each level tinted (lighter up, darker
# down) with a firm line where two levels meet, its height written in the
# middle, and the steps drawn as treads.
func _draw_split_levels(parent: Floor) -> void:
	if not parent.has_split_levels():
		return
	const EDGE_COL := Color(0.22, 0.20, 0.18, 0.85)
	const TREAD_COL := Color(0.22, 0.20, 0.18, 0.45)
	var bounds := parent.get_room_bounds()
	for x in range(bounds.position.x, bounds.end.x):
		for y in range(bounds.position.y, bounds.end.y):
			var t := Vector2i(x, y)
			if not parent.is_floor_tile(t):
				continue
			var r := Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
			var l := parent.level_at(t)
			if parent.is_step(t):
				draw_rect(r, Color(0.96, 0.92, 0.84, 0.55))
				var horizontal := parent.level_at(t + Vector2i(0, 1)) != parent.level_at(t + Vector2i(0, -1))
				if horizontal:
					draw_line(r.position + Vector2(0, TILE_SIZE * 0.5), r.position + Vector2(TILE_SIZE, TILE_SIZE * 0.5), TREAD_COL, 1.0)
				else:
					draw_line(r.position + Vector2(TILE_SIZE * 0.5, 0), r.position + Vector2(TILE_SIZE * 0.5, TILE_SIZE), TREAD_COL, 1.0)
			elif l > 0:
				draw_rect(r, Color(1.0, 0.97, 0.88, clampf(0.10 + l * 0.01, 0.12, 0.35)))
			elif l < 0:
				draw_rect(r, Color(0.0, 0.0, 0.05, clampf(0.10 - l * 0.02, 0.12, 0.35)))
			for n in [Vector2i(1, 0), Vector2i(0, 1)]:
				var o: Vector2i = t + n
				if not parent.is_floor_tile(o) or parent.is_step(o) or parent.is_step(t) or parent.level_at(o) == l:
					continue
				var a := Vector2((x + n.x) * TILE_SIZE, (y + n.y) * TILE_SIZE)
				var e := a + (Vector2(0, TILE_SIZE) if n.x == 1 else Vector2(TILE_SIZE, 0))
				draw_line(a, e, EDGE_COL, 2.0)
	# The height each flight of steps leads to, written on the steps (nothing
	# stands there, so it is never hidden under a piece).
	var seen: Dictionary = {}
	for t0 in parent.step_mask:
		if seen.has(t0):
			continue
		var queue: Array = [t0]
		seen[t0] = true
		var head := 0
		var lead := 0
		var sum := Vector2.ZERO
		while head < queue.size():
			var t: Vector2i = queue[head]
			head += 1
			sum += Vector2(t) + Vector2(0.5, 0.5)
			for n in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var o: Vector2i = t + n
				if parent.step_mask.has(o):
					if not seen.has(o):
						seen[o] = true
						queue.append(o)
				elif parent.is_floor_tile(o) and absi(parent.level_at(o)) > absi(lead):
					lead = parent.level_at(o)
		if lead == 0:
			continue
		var c := sum / queue.size() * TILE_SIZE
		draw_string(ThemeDB.fallback_font, c + Vector2(-24, 4), "%+d cm" % (lead * 10),
			HORIZONTAL_ALIGNMENT_CENTER, 48, 10, EDGE_COL)


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

	var label := tr("%.1f° slope  |  %.2fm → %.2fm over %.1fm  (tiles %d–%d)") % \
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
	# Structural column: a solid square in the walls' black, crossed (the plan's symbol)
	const COL_COL  := Color(0.20, 0.20, 0.20, 1.0)
	const COL_H    := Color(0.08, 0.08, 0.08, 1.0)
	for col in parent.columns:
		var cx: int = col["x"] as int
		var cy: int = col["y"] as int
		var r := Rect2(cx * TILE_SIZE, cy * TILE_SIZE, TILE_SIZE, TILE_SIZE)
		draw_rect(r, COL_COL)
		draw_rect(r, COL_H, false, 1.5)
		draw_line(r.position + Vector2(2, 2), r.end - Vector2(2, 2), Color(1, 1, 1, 0.45), 1.0)
		draw_line(r.position + Vector2(r.size.x - 2, 2), r.position + Vector2(2, r.size.y - 2), Color(1, 1, 1, 0.45), 1.0)


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


# Quiet routes: a dashed ring round the sleeping birds (the distance to keep)
# and the night-time way from a bed to the toilet as a line of footsteps,
# calm when it keeps clear, red when it wakes them.
const QUIET_RING := Color(0.25, 0.35, 0.75, 0.85)
const QUIET_OK := Color(0.12, 0.58, 0.32, 0.95)
const QUIET_BAD := Color(1.0, 0.42, 0.38, 0.95)

func _draw_quiet_routes() -> void:
	var ts := float(TILE_SIZE)
	for q in quiet_routes:
		var st := q as Dictionary
		var radius := st.get("radius", 10.0) as float
		for z in st.get("zone", []) as Array:
			var r := z as Rect2
			var c := r.get_center() * ts
			var rr := (radius + maxf(r.size.x, r.size.y) * 0.5) * ts
			var segs := 48
			for i in segs:
				if i % 2 == 1:
					continue
				var a0 := TAU * i / segs
				var a1 := TAU * (i + 1) / segs
				draw_line(c + Vector2(cos(a0), sin(a0)) * rr, c + Vector2(cos(a1), sin(a1)) * rr, QUIET_RING, 1.4, true)
			var font := ThemeDB.fallback_font
			draw_string(font, c + Vector2(r.size.x * ts * 0.5 + 2.0, -r.size.y * ts * 0.5), "z z z", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, QUIET_RING)
		var path := st.get("path", []) as Array
		var col := QUIET_OK if (st.get("ok", true) as bool) else QUIET_BAD
		var zones := st.get("zone", []) as Array
		for i in range(0, path.size(), 2):
			var p := (path[i] as Vector2)
			# Red only where it comes too close; the rest of the way stays calm.
			var near := false
			for z in zones:
				if Floor._rect_gap(Rect2(p - Vector2.ONE * 2.0, Vector2.ONE * 4.0), z as Rect2) < radius:
					near = true
			var ok_route := st.get("ok", true) as bool
			draw_circle(p * ts, 1.6, col if ok_route else (QUIET_BAD if near else QUIET_RING))


# The walls a wall-bound piece can be put against (Floor.backs_onto_wall):
# every wall tile but doorways, in a soft glow over the wall.
const WALL_CUE_COL := Color(0.12, 0.50, 0.85, 0.50)

func _draw_wall_cue(parent: Floor) -> void:
	var ts := float(TILE_SIZE)
	for t in parent._wall_contact_tiles():
		var v := t as Vector2i
		draw_rect(Rect2(v.x * ts - 1.0, v.y * ts - 1.0, ts + 2.0, ts + 2.0), WALL_CUE_COL)


var _light_layer: Node2D = null
var _room_layer: Node2D = null
var _room_tags: Node2D = null

# ── Rooms (Floor.rooms) ──────────────────────────────────────────────────────
const ROOM_TINT := 0.16        # a resident's colour over the room given to them
const ROOM_FAULT_COL := Color(0.86, 0.22, 0.18)   # a room a room rule is broken in
const ROOM_FACE_PX := 30.0     # on screen, whatever the zoom
const ROOM_NAME_PX := 13
const ROOM_KINDS := ["kitchen", "bathroom", "bedroom", "living"]   # Floor.room_kind()
# i18n-const
const ROOM_NAMES := ["Kitchen", "Bathroom", "Bedroom", "Living room"]

func _draw_room_layer() -> void:
	var parent := get_parent() as Floor
	if parent == null or not parent.visible:
		return
	var ts := float(TILE_SIZE)
	for room in parent.rooms:
		var tiles := room["tiles"] as Dictionary
		var owners := parent.owners_of_room(room)
		if not owners.is_empty():
			var col := (parent.resident_looks.get(owners[0], {}) as Dictionary).get("color", GameTheme.NAVY) as Color
			var fill := Color(col, ROOM_TINT)
			for t in tiles:
				var v := t as Vector2i
				_room_layer.draw_rect(Rect2(v.x * ts, v.y * ts, ts, ts), fill)
		# A room a room rule is broken in: a red wash and a red edge round it.
		if parent.room_faults.has(room.get("index", -1)):
			for t in tiles:
				var v := t as Vector2i
				var r := Rect2(v.x * ts, v.y * ts, ts, ts)
				_room_layer.draw_rect(r, Color(ROOM_FAULT_COL, 0.10))
				for side in [[Vector2i(-1, 0), r.position, Vector2(r.position.x, r.end.y)],
						[Vector2i(1, 0), Vector2(r.end.x, r.position.y), r.end],
						[Vector2i(0, -1), r.position, Vector2(r.end.x, r.position.y)],
						[Vector2i(0, 1), Vector2(r.position.x, r.end.y), r.end]]:
					if not tiles.has(v + (side[0] as Vector2i)):
						_room_layer.draw_line(side[1], side[2], ROOM_FAULT_COL, 2.0)


# On a clear bit of each room's floor, at a steady size on screen: what the
# room is (from what is in it) and, under that, the faces of whoever it was
# given to.
func _draw_room_tags() -> void:
	var parent := get_parent() as Floor
	if parent == null or not parent.visible or editor_mode:
		return
	var scale := _room_tags.get_global_transform_with_canvas().get_scale().x
	var k := 1.0 / maxf(scale, 0.01)
	var font := GameTheme.font("mono_bold")
	var ts := float(TILE_SIZE)
	for room in parent.rooms:
		var owners := parent.owners_of_room(room)
		var kind := parent.room_kind(room)
		if owners.is_empty() and kind == "":
			continue
		# At a clear spot of the room (Floor.room_label_spot), so a piece
		# put where the name was moves it aside rather than hiding it.
		var text := tr(ROOM_NAMES[ROOM_KINDS.find(kind)] as String).to_upper() if kind != "" else ""
		var fs := roundi(ROOM_NAME_PX * k)
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x if text != "" else 0.0
		var faces_w := owners.size() * (ROOM_FACE_PX + 4.0) * k
		var block := Vector2(maxf(tw, faces_w), (ROOM_NAME_PX + 6.0 if text != "" else 0.0) * k + (ROOM_FACE_PX * k if not owners.is_empty() else 0.0))
		var spot := parent.room_label_spot(room, block / ts + Vector2(2, 2)) * ts
		var c := Vector2(spot.x, spot.y - block.y * 0.5)
		var y := c.y + (ROOM_NAME_PX * k if text != "" else 0.0)
		if text != "":
			var at := Vector2(c.x - tw * 0.5, y)
			_room_tags.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, roundi(4 * k), Color(PLAN_PAPER, 0.9))
			_room_tags.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, PLAN_INK_SOFT)
			y += 6.0 * k
		var side := ROOM_FACE_PX * k
		var gap := 4.0 * k
		var x := c.x - (owners.size() * side + (owners.size() - 1) * gap) * 0.5
		for rid in owners:
			var look := parent.resident_looks.get(rid, {}) as Dictionary
			var col := look.get("color", GameTheme.NAVY) as Color
			var r := Rect2(x, y, side, side)
			_room_tags.draw_rect(r.grow(2.0 * k), col.darkened(0.3))
			_room_tags.draw_rect(r, col.lightened(0.15))
			_room_tags.draw_texture_rect(MiiPortrait.face(look.get("body", "adult") as String,
				look.get("feminine", false) as bool), r, false)
			x += side + gap

# One rail track, in tiles: along the axis (`horizontal` or not) from `from`
# to `to`, its line across at `at`. A fine dashed line, the way a plan marks
# what runs overhead or under, with a short stop across each end.
const RAIL_TRACK_COL := Color(0.30, 0.33, 0.40, 0.95)

func _draw_rail_track(horizontal: bool, from: float, to: float, at: float) -> void:
	var t := float(TILE_SIZE)
	var stop := t * 0.5
	var a := Vector2(from * t, at * t) if horizontal else Vector2(at * t, from * t)
	var b := Vector2(to * t, at * t) if horizontal else Vector2(at * t, to * t)
	draw_dashed_line(a, b, RAIL_TRACK_COL, 1.0, 4.0, true, true)
	var across := Vector2(0, stop) if horizontal else Vector2(stop, 0)
	for p in [a, b]:
		draw_line(p - across, p + across, RAIL_TRACK_COL, 1.0, true)


func _draw_natural_light(_parent: Floor) -> void:
	if is_instance_valid(_light_layer):
		_light_layer.queue_redraw()


# The squares light reaches (Floor._cast_light: the sun by day, lamps by
# night), brighter where more
# light is: the beams from the windows and the shadows furniture throws in
# them read at a glance. While a piece is dragged its shadow moves with it
# (Floor.light_map_with).
func _draw_light_layer() -> void:
	var parent := get_parent() as Floor
	if parent == null or not parent.visible:
		return
	var light: Dictionary = parent._light_map
	var ghost: Dictionary = parent._floor_drag_ghost
	if not ghost.is_empty() and is_instance_valid(ghost.get("furniture")):
		light = parent.light_map_with(ghost["furniture"] as Furniture, Vector2(ghost["gx"] as float, ghost["gy"] as float))
	var ts := float(TILE_SIZE)
	var night := Floor.is_night_moment(Furniture.active_moment_id)
	var col := LAMP_COL if night else LIGHT_COL
	var well := parent.stair_layout()["solid"] as Dictionary
	for t in light:
		var v := t as Vector2i
		if well.has(v):
			continue   # stairs and stairwells: drawn on their own, the light only muddled them
		var k := LIGHT_STRENGTH * clampf(light[t] as float, 0.0, 1.0)
		_light_layer.draw_rect(Rect2(v.x * ts, v.y * ts, ts, ts), Color(col, k))


# A flight as an architect's plan draws it. The plan is a cut through the
# storey at about a metre, so a flight going up from this floor is cut at
# STAIR_CUT of its run: its treads solid up to a break line, dashed beyond
# (above the cut). Seen from the floor above, down its stairwell, it is the
# other way round: the part beyond the break solid, the rest dashed. The
# walking line down the middle always points up the flight — a small circle
# at the first step, an arrowhead at the last — on both floors.
const STAIR_CUT := 0.6

func _draw_flight(r: Rect2i, dir: String, fill: Color, nosing: Color, border: Color, ink: Color, from_below: bool) -> void:
	var px := Rect2(Vector2(r.position * TILE_SIZE), Vector2(r.size * TILE_SIZE))
	var run := r.size.y if dir in ["north", "south"] else r.size.x
	var steps := maxi(run / 2, 1)   # 20 cm treads
	# A point of the flight: u across it (0..1), v along it (0 = foot, 1 = top).
	var at := func(u: float, v: float) -> Vector2:
		match dir:
			"north": return Vector2(px.position.x + u * px.size.x, px.end.y - v * px.size.y)
			"south": return Vector2(px.position.x + u * px.size.x, px.position.y + v * px.size.y)
			"east":  return Vector2(px.position.x + v * px.size.x, px.position.y + u * px.size.y)
		return Vector2(px.end.x - v * px.size.x, px.position.y + u * px.size.y)
	draw_rect(px, fill)
	var shown := func(v: float) -> bool:   # solid on this floor's plan
		return (v >= STAIR_CUT) if from_below else (v <= STAIR_CUT)
	for i in range(1, steps):
		var v := float(i) / steps
		if shown.call(v):
			draw_line(at.call(0.0, v), at.call(1.0, v), nosing, 1.5)
		else:
			draw_dashed_line(at.call(0.0, v), at.call(1.0, v), Color(nosing, nosing.a * 0.7), 1.0, 3.0)
	draw_rect(px, border, false, 2.0)
	# The break line: a slanted cut with a small zigzag in the middle.
	var d := 0.07
	var pts := [at.call(-0.05, STAIR_CUT - d), at.call(0.42, STAIR_CUT - d * 0.1), at.call(0.48, STAIR_CUT + d * 0.6),
		at.call(0.54, STAIR_CUT - d * 0.6), at.call(0.60, STAIR_CUT + d * 0.1), at.call(1.05, STAIR_CUT + d)]
	for i in pts.size() - 1:
		draw_line(pts[i], pts[i + 1], ink, 1.5, true)
	# The walking line.
	var foot: Vector2 = at.call(0.5, 0.5 / steps)
	var top: Vector2 = at.call(0.5, 1.0 - 0.25 / steps)
	var cut: Vector2 = at.call(0.5, STAIR_CUT)
	if from_below:
		draw_dashed_line(foot, cut, Color(ink, 0.6), 1.0, 3.0)
		draw_line(cut, top, ink, 1.5, true)
	else:
		draw_circle(foot, 2.6, ink)
		draw_line(foot, cut, ink, 1.5, true)
		draw_dashed_line(cut, top, Color(ink, 0.6), 1.0, 3.0)
	var back := (cut - top).normalized() * 6.0
	var side := Vector2(-back.y, back.x) * 0.55
	draw_colored_polygon(PackedVector2Array([top, top + back + side, top + back - side]), ink)


# "Up" at the foot of a flight, "Down" at the top of the stairwell one comes
# up through: where each is walked onto, as on an architect's plan.
func _draw_stair_word(r: Rect2i, dir: String, top: bool, word: String, col: Color) -> void:
	var font := ThemeDB.fallback_font
	var fs := maxi(8, int(TILE_SIZE * 1.3))
	var sz := font.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var px := Rect2(Vector2(r.position * TILE_SIZE), Vector2(r.size * TILE_SIZE))
	# On the walking line, clear of its circle and its arrowhead: a quarter
	# of the way up for "Up", most of the way for "Down".
	var v := 0.8 if top else 0.3
	var c := px.get_center()
	match dir:
		"north": c.y = px.end.y - v * px.size.y
		"south": c.y = px.position.y + v * px.size.y
		"east":  c.x = px.position.x + v * px.size.x
		_:       c.x = px.end.x - v * px.size.x
	var at := c + Vector2(-sz.x * 0.5, sz.y * 0.3)
	draw_string_outline(font, at, word, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(1, 0.98, 0.92, 0.85))
	draw_string(font, at, word, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


# Sunlight: a warm yellow wash over the white plan, strong enough to show
# against the paper.
const LIGHT_COL := Color(0.98, 0.80, 0.25)
const LIGHT_STRENGTH := 0.45   # its opacity at full light
const LAMP_COL := Color(1.0, 0.62, 0.22)   # lamplight at night, warmer
