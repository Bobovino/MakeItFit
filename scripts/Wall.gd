extends Node2D
class_name Floor

signal furniture_changed
# span_lo/span_hi (absolute tile coords, -1/-1 = no split) identify which
# sub-span of a multi-room floor's edge was actually clicked — see
# get_wall_span(). Every existing connection ignoring the extra args keeps
# working; only Main.gd's handler needs to read them.
signal wall_edge_clicked(edge: String, span_lo: int, span_hi: int)

const TILE_SIZE := 8
const EDGE_MARGIN := 10
const WALL_DEPTH := 8  # tiles within this distance count as "against the wall"
const FLOOR_HEIGHT_TILES := 28  # nominal room height in tiles (≈2.8 m at 10 cm/tile)

var floor_id: String = ""
var floor_label: String = ""
var floor_type: String = "floor"
# Set by Main.gd while a Builder-tab tool (wall/column/erase) is active, so
# this Floor's own click-to-inspect-a-wall _input() doesn't also react to the
# same press/release the builder tool just handled.
var input_suppressed: bool = false
var parent_id: String = ""
var grid_w: int = 8
var grid_h: int = 6
var wall_definitions: Array = []
var partitions: Array = []       # [{x1,y1,x2,y2,load_bearing,demolished}]
var columns: Array = []          # [{x,y}] — permanent structural obstacles
# Ceiling and floor heights: level geometry, not props (see ceiling_height_at()
# and level_at()). A flat ceiling stands at ceiling_h; each ramp in
# ceiling_ramps lowers it over part of the room, the lowest one winning, so
# two ramps make a gable and a ramp with a "rect" makes a dormer:
#   {axis:"x"|"y", low_start, high_end, min_h, max_h, rect?:[x, y, w, h]}
# (tiles along `axis`, absolute; low_start may be past high_end for a ramp
# that falls the other way; metres). Kept per floor and serialised as plain
# data so a ceiling layer of its own can own it later.
const CEILING_H_M := 2.4
var ceiling_h: float = CEILING_H_M
var ceiling_ramps: Array = []
# Split levels inside one floor: a raised platform or a sunken area is a set
# of tiles whose floor stands floor_level[tile] tiles (10 cm each) above (+)
# or below (-) the rest. People only change level over step tiles, and
# nothing can stand on a step or across two levels.
var floor_level: Dictionary = {}   # Vector2i -> int; absent = 0
var step_mask:   Dictionary = {}   # Vector2i -> true
var connection_points: Dictionary = {}  # {water:[{x,y}], power:[{x,y}]}
var pipe_routes: Array = []     # [{type:"water"|"power", tiles:[Vector2i]}]  player-drawn
var duct_routes: Array = []     # reserved for HVAC (ceiling layer)

var floor_mask:     Dictionary = {}   # Vector2i -> true; empty = whole grid is floor
var floor_kind:     Dictionary = {}   # Vector2i -> String ("balcony"|"bathroom"); absent = "normal"
var mezzanine_mask: Dictionary = {}   # Vector2i -> true; mezzanine/loft tiles
# Total furniture weight (Furniture.weight) the mezzanine structure can carry
# before it's considered overloaded — see can_place()'s mezzanine load check.
# Scales with mezzanine area so a bigger loft can carry more, by default.
var mezzanine_max_load: float = 0.0
var stair_mask:     Dictionary = {}   # Vector2i -> true; stair tiles
var shadow_mask:    Dictionary = {}   # Vector2i -> true; parent floor ghost (LevelEditor loft view only)
var below_floor:    Floor      = null # the "floor"-type floor stacked directly below this one, if any (gameplay 2D/3D ghost-below reference — see Main.gd's _floor_below_id)
var rails:          Array      = []   # [{x1,y1,x2,y2}] sliding rail tracks
var reveal_zones:   Array      = []   # [{x1,y1,x2,y2}] sub-range of a rail where a piece counts as "revealed"
var segments:       Array      = []   # new-format walls: [{x1,y1,x2,y2,primary,demolished,...}]
var stairs_data:    Array      = []   # [{rect:Rect2i, direction:String}] one entry per placed stair
var stair_openings: Array      = []   # same format, but stair footprints from parent floor (for loft rendering)
var _use_new_format: bool      = false
var loop: LoopSeams = null      # openings that lead back into this same floor (see LoopSeams.gd); null = none

var _block_reason: String = ""    # why the most recent can_place() call returned false, for UI feedback
var _placed: Dictionary = {}      # Vector2i -> Array[Furniture]  (multi-Z) — rasterized cache,
								   # derived from the continuous positions below, used by
								   # lighting/zones/needs/adjacency (all inherently tile-discrete).
var _placed_continuous: Array = []  # [{furniture:Furniture, pos:Vector2}] — precise overlap source of truth
var floor_z_offset: int = 0       # global Z of this floor's floor level (tiles)
var zones: Array = []             # [{tiles:Dictionary, functions:Array[String]}] — recalculated on furniture change
var wall_items: Dictionary = {}   # "north" -> { Vector2i origin -> fid }
var _light_map: Dictionary = {}   # Vector2i -> float  (0.0 dark … 1.0 full sunlight)
# For a nested/parabox apartment (this Floor is the interior of a "box" prop
# placed inside another, bigger apartment): how much of the outside daylight
# actually reaches this floor's own windows, 1.0 = unobstructed. Set from
# outside (see Main.gd's _update_nested_box_occlusion()) by checking whether
# the parent apartment has tall/medium furniture sitting in front of the box
# in the parent's own grid — a real cross-frame interaction, not just cosmetic.
var external_daylight_factor: float = 1.0

# Live drag previews so the floor plan and Wall Inspector mirror each other
# while a piece is being dragged, not just after it's dropped.
var _wall_drag_ghost:  Dictionary = {}  # {edge:String, origin:Vector2i, fid:String}
var _floor_drag_ghost: Dictionary = {}  # {furniture:Furniture, gx:int, gy:int}

# Cached floor bounds in local px — set in setup(), used by _input() for edge detection
var _edge_x0: float = 0.0
var _edge_y0: float = 0.0
var _edge_x1: float = 0.0
var _edge_y1: float = 0.0
# Drag tracking for wall inspector
var _drag_press_local: Vector2 = Vector2.ZERO
var _drag_active:      bool    = false

@onready var grid_draw: GridDraw = $GridDraw


# ── Spatial index helpers ─────────────────────────────────────────────────────

func _placed_list(tile: Vector2i) -> Array:
	return _placed.get(tile, []) as Array

# Whether anything stands on this tile; a skylight overhead doesn't.
func _placed_any_at(tile: Vector2i) -> bool:
	for f in _placed_list(tile):
		if not (f as Furniture).overhead:
			return true
	return false

func _placed_overlapping_z(tile: Vector2i, z0: float, z1: float, exclude: Furniture = null) -> Furniture:
	for item in _placed_list(tile):
		var f := item as Furniture
		if f == exclude: continue
		if f.z_top > z0 and f.z_bottom < z1:
			return f
	return null

func _placed_add(tile: Vector2i, furniture: Furniture) -> void:
	if not _placed.has(tile):
		_placed[tile] = []
	(_placed[tile] as Array).append(furniture)

func _placed_remove_tile(tile: Vector2i, furniture: Furniture) -> void:
	if not _placed.has(tile): return
	var arr := _placed[tile] as Array
	arr.erase(furniture)
	if arr.is_empty():
		_placed.erase(tile)

# Rasterizes a continuous rect (float origin, integer w/h in tiles) down to
# the set of integer tiles it overlaps at least partially — the bridge that
# lets lighting/zones/needs/adjacency (all inherently tile-discrete systems)
# keep working unchanged while furniture position itself is continuous.
func _rect_tiles(at: Vector2, w: int, h: int) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	var x0 := floori(at.x)
	var y0 := floori(at.y)
	var x1 := floori(at.x + w - 0.001)
	var y1 := floori(at.y + h - 0.001)
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			tiles.append(Vector2i(x, y))
	if loop != null:
		# On a looped floor a piece across a seam stands on both sides of it.
		var seen: Dictionary = {}
		var wrapped: Array[Vector2i] = []
		for t in tiles:
			var wt := loop.wrap_tile(t)
			if not seen.has(wt):
				seen[wt] = true
				wrapped.append(wt)
		return wrapped
	return tiles


# The tile `t` really is on a looped floor (see LoopSeams.wrap_tile); `t`
# itself anywhere else.
func wrap_tile(t: Vector2i) -> Vector2i:
	return loop.wrap_tile(t) if loop != null else t


# A piece's corner moved round the loop to inside the room (a no-op on an
# ordinary floor).
func wrap_point(p: Vector2) -> Vector2:
	return loop.wrap_point(p) if loop != null else p


# A footprint as the rects it covers: itself, or on a looped floor one part
# per side of each seam it crosses.
func footprint_rects(r: Rect2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if loop == null:
		out.append(r)
		return out
	for part in loop.split_rect(r):
		out.append(part["rect"] as Rect2)
	return out


static func _rects_meet(a: Array[Rect2], b: Array[Rect2]) -> bool:
	for ra in a:
		for rb in b:
			if ra.intersects(rb):
				return true
	return false


func _get_all_placed_unique() -> Array:
	var seen: Array = []
	for tile in _placed:
		for item in _placed[tile] as Array:
			if item not in seen:
				seen.append(item)
	return seen

func _register_stair(furniture: Furniture, at: Vector2i) -> void:
	var r := Rect2i(at.x, at.y, furniture.grid_w, furniture.grid_h)
	stairs_data.append({"rect": r, "direction": furniture.stair_direction, "furniture": furniture})
	for x in range(r.size.x):
		for y in range(r.size.y):
			stair_mask[Vector2i(r.position.x + x, r.position.y + y)] = true

func _unregister_stair(furniture: Furniture) -> void:
	var kept: Array = []
	for entry in stairs_data:
		var e := entry as Dictionary
		if e.get("furniture") == furniture:
			var r := e["rect"] as Rect2i
			for x in range(r.size.x):
				for y in range(r.size.y):
					stair_mask.erase(Vector2i(r.position.x + x, r.position.y + y))
		else:
			kept.append(entry)
	stairs_data = kept

# ─────────────────────────────────────────────────────────────────────────────

# ── Ceiling and floor heights ──────────────────────────────────────────────

func has_sloped_ceiling() -> bool:
	return not ceiling_ramps.is_empty()


func has_split_levels() -> bool:
	return not floor_level.is_empty() or not step_mask.is_empty()


# How high one ramp's ceiling is at `p` (tiles, absolute), or INF where the
# ramp doesn't reach: outside its rect, or outside its own low..high run (a
# separate room on a multi-room floor keeps its full height).
static func ramp_height_at(r: Dictionary, p: Vector2) -> float:
	if r.has("rect"):
		var rc := r["rect"] as Array
		if p.x < (rc[0] as float) or p.y < (rc[1] as float) 				or p.x > (rc[0] as float) + (rc[2] as float) or p.y > (rc[1] as float) + (rc[3] as float):
			return INF
	var low := r.get("low_start", 0) as float
	var high := r.get("high_end", 0) as float
	var c := p.x if (r.get("axis", "x") as String) == "x" else p.y
	if high == low or c < minf(low, high) or c > maxf(low, high):
		return INF
	var min_h := r.get("min_h", 1.8) as float
	return min_h + (c - low) / (high - low) * ((r.get("max_h", CEILING_H_M) as float) - min_h)


# Ceiling height in metres above the floor's base level at `p` (tiles,
# absolute; a tile's own coordinate stands for that tile).
func ceiling_height_at(p: Vector2) -> float:
	var best := INF
	for r in ceiling_ramps:
		best = minf(best, ramp_height_at(r as Dictionary, p))
	return best if best < INF else ceiling_h


# How far this tile's floor stands above (+) or below (-) the base, in tiles.
func level_at(tile: Vector2i) -> int:
	return floor_level.get(tile, 0) as int


func level_m_at(tile: Vector2i) -> float:
	return level_at(tile) * 0.1


func is_step(tile: Vector2i) -> bool:
	return step_mask.has(tile)


# The level a piece with its corner at `at` stands on (its first tile's).
func level_under(at: Vector2, w: int, h: int) -> int:
	if floor_level.is_empty():
		return 0
	var tiles := _rect_tiles(at, w, h)
	return level_at(tiles[0]) if not tiles.is_empty() else 0


# The clear height over a tile, from its own floor to the ceiling, in metres.
func headroom_at(tile: Vector2i) -> float:
	return ceiling_height_at(Vector2(tile)) - level_m_at(tile)


# Whether a person can stand on the size x size patch at `top_left`: steps
# go with either level, but everything else under them is one level.
func patch_level_ok(top_left: Vector2i, size: int) -> bool:
	if floor_level.is_empty():
		return true
	var lvl := 0
	var found := false
	for dy in size:
		for dx in size:
			var t := Vector2i(top_left.x + dx, top_left.y + dy)
			if step_mask.has(t):
				continue
			var l := level_at(t)
			if not found:
				lvl = l
				found = true
			elif l != lvl:
				return false
	return true


# Connected stretches of one level, steps left out:
# [{level, center: Vector2 (tiles), size, tiles: Array[Vector2i]}].
func level_regions() -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	var bounds := get_room_bounds()
	for x in range(bounds.position.x, bounds.end.x):
		for y in range(bounds.position.y, bounds.end.y):
			var t0 := Vector2i(x, y)
			if seen.has(t0) or not is_floor_tile(t0) or is_step(t0):
				continue
			var lvl := level_at(t0)
			var queue: Array[Vector2i] = [t0]
			seen[t0] = true
			var sum := Vector2.ZERO
			var head := 0
			while head < queue.size():
				var t := queue[head]
				head += 1
				sum += Vector2(t) + Vector2(0.5, 0.5)
				for n in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var o: Vector2i = t + n
					if not seen.has(o) and is_floor_tile(o) and not is_step(o) and level_at(o) == lvl:
						seen[o] = true
						queue.append(o)
			out.append({"level": lvl, "center": sum / queue.size(), "size": queue.size(), "tiles": queue})
	return out


func get_tile_kind(tile: Vector2i) -> String:
	return floor_kind.get(tile, "normal") as String


# Balcony tiles only accept balcony-category furniture (and vice versa —
# balcony furniture only belongs on a balcony). Bathroom tiles accept
# anything, but bathroom-category furniture is confined to bathroom tiles.
#
# Both "belongs on" rules only apply on a floor that actually HAS that kind
# of flooring. A toilet is confined to the bathroom if there is a bathroom;
# on a floor with no bathroom tiles at all it may go anywhere. Without this,
# a piece that needs flooring the floor doesn't have can be placed nowhere —
# not even back where it already stands — and most levels shipped with a
# toilet and a sink in exactly that state: frozen in place.
func _floor_category_ok(furn_category: String, tile_kind: String) -> bool:
	if tile_kind == "balcony":
		return furn_category == "balcony"
	if furn_category == "balcony":
		return not has_floor_kind("balcony")
	if furn_category == "bathroom" and tile_kind != "bathroom":
		return not has_floor_kind("bathroom")
	return true


# Whether any tile of this floor is painted with the given kind.
func has_floor_kind(kind: String) -> bool:
	return floor_kind.values().has(kind)


# The pieces whose footprint the flooring rule rejects where they stand —
# used by the level editor to warn before saving a level that would trap
# them. Each entry is a furniture id.
func floor_category_problem(furn_category: String, at: Vector2i, w: int, h: int) -> String:
	if furn_category == "":
		return ""
	for dx in range(w):
		for dy in range(h):
			if not _floor_category_ok(furn_category, get_tile_kind(Vector2i(at.x + dx, at.y + dy))):
				return tr("needs %s flooring") % Loc.floor_kind_name(furn_category)
	return ""


func is_floor_tile(tile: Vector2i) -> bool:
	if not _use_new_format:
		return tile.x >= 0 and tile.x < grid_w and tile.y >= 0 and tile.y < grid_h
	if not floor_mask.is_empty():
		return tile in floor_mask
	# No painted floor mask: fall back to the room's real interior extent
	# (derived from wall segments), NOT the raw apartment grid_w/grid_h —
	# that grid is often a much larger sandbox default, and treating it all
	# as floor lets furniture be placed in the "void" outside any walls.
	if not segments.is_empty():
		var b := get_room_bounds()
		return tile.x >= b.position.x and tile.x < b.position.x + b.size.x \
			and tile.y >= b.position.y and tile.y < b.position.y + b.size.y
	return tile.x >= 0 and tile.x < grid_w and tile.y >= 0 and tile.y < grid_h


# Real playable extent of this floor, derived from wall segments — the walls
# are the source of truth for the room's footprint; floor tiles are pruned to
# fit inside them (see _prune_floor_mask_to_walls), not the other way around.
#
# Remembered while the walls stay the same: is_floor_tile() asks for it on
# every call, and light, zones, access and the plan's drawing ask that of
# every tile, so working it out from every segment each time was most of a
# level's loading and of each redraw of the plan. The walls are edited in
# many places, so the check is their hash (cheap, done natively) rather than
# a flag each edit would have to remember to set.
var _bounds_key := 0
var _bounds_cache := Rect2i()

func get_room_bounds() -> Rect2i:
	if not segments.is_empty():
		var key := segments.hash()
		if key == _bounds_key:
			return _bounds_cache
		var minx := INF; var miny := INF; var maxx := -INF; var maxy := -INF
		for s in segments:
			var sd := s as Dictionary
			minx = min(minx, min(sd["x1"] as int, sd["x2"] as int))
			maxx = max(maxx, max(sd["x1"] as int, sd["x2"] as int))
			miny = min(miny, min(sd["y1"] as int, sd["y2"] as int))
			maxy = max(maxy, max(sd["y1"] as int, sd["y2"] as int))
		_bounds_key = key
		_bounds_cache = Rect2i(int(minx), int(miny), int(maxx - minx), int(maxy - miny))
		return _bounds_cache
	if not floor_mask.is_empty():
		var minx := INF; var miny := INF; var maxx := -INF; var maxy := -INF
		for t in floor_mask:
			var tv := t as Vector2i
			minx = min(minx, tv.x); maxx = max(maxx, tv.x)
			miny = min(miny, tv.y); maxy = max(maxy, tv.y)
		return Rect2i(int(minx), int(miny), int(maxx - minx) + 1, int(maxy - miny) + 1)
	return Rect2i(0, 0, grid_w, grid_h)


# ── Multi-room wall splitting ────────────────────────────────────────────────
# A nominal cardinal edge (e.g. "south") can be crossed by an interior
# (non-primary) partition wall on a multi-room floor — the partition's own
# endpoint touches the perimeter edge's line at some coordinate. Without this,
# the Wall Inspector treated the WHOLE perimeter edge as one wall regardless
# of interior partitions, showing one room's furniture mixed with another's.
#
# Returns [lo, hi) in ABSOLUTE tile coordinates for the specific sub-span of
# `edge` that contains `coord` (the clicked tile's coordinate along the wall's
# own axis). A floor with no interior wall crossing this edge returns the
# whole edge unchanged, so every single-room level behaves exactly as before.
func get_wall_span(edge: String, coord: int) -> Vector2i:
	var bounds := get_room_bounds()
	var fixed_coord: int
	var full_lo: int; var full_hi: int
	match edge:
		"north":
			fixed_coord = bounds.position.y
			full_lo = bounds.position.x; full_hi = bounds.position.x + bounds.size.x
		"south":
			fixed_coord = bounds.position.y + bounds.size.y
			full_lo = bounds.position.x; full_hi = bounds.position.x + bounds.size.x
		"west":
			fixed_coord = bounds.position.x
			full_lo = bounds.position.y; full_hi = bounds.position.y + bounds.size.y
		"east":
			fixed_coord = bounds.position.x + bounds.size.x
			full_lo = bounds.position.y; full_hi = bounds.position.y + bounds.size.y
		_:
			return Vector2i(-1, -1)
	var splits: Array = []
	for s in segments:
		var sd := s as Dictionary
		if sd.get("primary", false) or sd.get("demolished", false):
			continue   # only interior (non-primary) walls can split a perimeter edge
		var x1: int = sd["x1"]; var y1: int = sd["y1"]
		var x2: int = sd["x2"]; var y2: int = sd["y2"]
		if edge in ["north", "south"] and x1 == x2:
			var ylo := mini(y1, y2); var yhi := maxi(y1, y2)
			if fixed_coord == ylo or fixed_coord == yhi:
				if x1 > full_lo and x1 < full_hi:
					splits.append(x1)
		elif edge in ["east", "west"] and y1 == y2:
			var xlo := mini(x1, x2); var xhi := maxi(x1, x2)
			if fixed_coord == xlo or fixed_coord == xhi:
				if y1 > full_lo and y1 < full_hi:
					splits.append(y1)
	if splits.is_empty():
		return Vector2i(-1, -1)
	splits.sort()
	var lo := full_lo
	var hi := full_hi
	for sp in splits:
		if coord < sp:
			hi = sp
			break
		lo = sp
	return Vector2i(lo, hi)


# Returns the actual perimeter segment for `edge` that contains `coord` — the
# source of truth for that specific wall's window/door flags in the new
# segments format (replaces the legacy `wall_definitions` lookup, which is
# always empty once a floor uses segments).
func get_wall_segment(edge: String, coord: int) -> Dictionary:
	var bounds := get_room_bounds()
	var fixed_coord: int
	match edge:
		"north": fixed_coord = bounds.position.y
		"south": fixed_coord = bounds.position.y + bounds.size.y
		"west":  fixed_coord = bounds.position.x
		"east":  fixed_coord = bounds.position.x + bounds.size.x
		_: return {}
	for s in segments:
		var sd := s as Dictionary
		if sd.get("demolished", false):
			continue
		var x1: int = sd["x1"]; var y1: int = sd["y1"]
		var x2: int = sd["x2"]; var y2: int = sd["y2"]
		if edge in ["north", "south"]:
			if y1 != y2 or y1 != fixed_coord:
				continue
			if coord >= mini(x1, x2) and coord <= maxi(x1, x2):
				return sd
		else:
			if x1 != x2 or x1 != fixed_coord:
				continue
			if coord >= mini(y1, y2) and coord <= maxi(y1, y2):
				return sd
	return {}


# Wall segments are the source of truth for the main room's footprint. A
# painted floor tile that falls outside the polygon they enclose is dropped
# UNLESS it carries a floor_kind tag (balcony, bathroom nook, etc.) — those are
# deliberate exterior/alcove extensions with no walls of their own. Untagged
# stray tiles left over from an earlier wall edit are what silently inflated
# get_room_bounds() and, from there, every wall/3D-view calculation that
# relies on it — get_room_bounds() itself now reads segments directly, but a
# stray tile can still cause bogus placement/occlusion elsewhere, so drop it.
func _prune_floor_mask_to_walls() -> void:
	if floor_mask.is_empty() or segments.is_empty():
		return
	var poly := _wall_polygon()
	if poly.size() < 3:
		return
	var pruned: Dictionary = {}
	for t in floor_mask:
		var tv := t as Vector2i
		if floor_kind.has(tv) or Geometry2D.is_point_in_polygon(Vector2(tv.x + 0.5, tv.y + 0.5), poly):
			pruned[tv] = true
	floor_mask = pruned


# Builds the closed outer polygon by chasing shared endpoints across
# `segments` regardless of array order or each segment's own start/end
# direction — segments are commonly drawn as independent perimeter drags
# (top, then bottom, then left, then right) rather than one continuous
# chain, so this must not assume segments[i].end == segments[i+1].start.
# Walks from segment 0's start point, at each step finding any not-yet-used
# segment sharing the current point and hopping to its other endpoint,
# until back at the start (or no match is found, e.g. an open/incomplete
# wall run) — either way, whatever's been traced so far is returned.
func _wall_polygon() -> PackedVector2Array:
	if segments.is_empty():
		return PackedVector2Array()
	var pts: Array = []
	for s in segments:
		var sd := s as Dictionary
		pts.append([
			Vector2(sd["x1"] as int, sd["y1"] as int),
			Vector2(sd["x2"] as int, sd["y2"] as int)
		])
	var used: Dictionary = {}
	var start: Vector2 = pts[0][0]
	var cur: Vector2 = start
	var poly := PackedVector2Array()
	poly.append(cur)
	while true:
		var found := -1
		var found_end := Vector2.ZERO
		for i in range(pts.size()):
			if used.has(i):
				continue
			var a: Vector2 = pts[i][0]
			var b: Vector2 = pts[i][1]
			if a.distance_to(cur) < 0.01:
				found = i; found_end = b; break
			elif b.distance_to(cur) < 0.01:
				found = i; found_end = a; break
		if found == -1:
			break
		used[found] = true
		cur = found_end
		poly.append(cur)
		if cur.distance_to(start) < 0.01:
			break
	return poly


func get_light(tile: Vector2i) -> float:
	return _light_map.get(tile, 0.0)


func set_external_daylight_factor(factor: float) -> void:
	factor = clampf(factor, 0.0, 1.0)
	if is_equal_approx(factor, external_daylight_factor):
		return
	external_daylight_factor = factor
	_compute_light_map()
	if grid_draw:
		grid_draw.queue_redraw()


# Daylight, in squares: each window shines a straight beam into the room,
# as wide as the window and BEAM_DEPTH tiles deep (full for the first half,
# BEAM_FAR after). A tall piece stops the beam (it is lit; what stands
# behind it is in its shadow), a medium one lets MEDIUM_PASS through, a low
# one or a screen (reeded glass, a curtain) none of its own. A skylight lights
# the tiles under it. Straight on purpose: a wardrobe's shadow is exactly
# as wide as the wardrobe, so the player can see where light will fall.
const BEAM_DEPTH := 30
const BEAM_FAR := 0.65
const MEDIUM_PASS := 0.5

func _compute_light_map() -> void:
	_light_map = _cast_light(null, Vector2.ZERO)


# The light as it would be with `moving` standing at `at` instead of where
# it is (or isn't): the plan shows the shadow follow a piece being dragged.
func light_map_with(moving: Furniture, at: Vector2) -> Dictionary:
	return _cast_light(moving, at)


func _cast_light(moving: Furniture, at: Vector2) -> Dictionary:
	var out: Dictionary = {}
	var blocked := _partition_tile_set(true)
	var moving_tiles: Dictionary = {}
	if moving != null:
		for t in _rect_tiles(at, moving.grid_w, moving.grid_h):
			moving_tiles[wrap_tile(t)] = true
	var pieces_on := func(t: Vector2i) -> Array:
		var on: Array = _placed_list(t).filter(func(p): return p != moving and not (p as Furniture).overhead)
		if moving_tiles.has(t) and not moving.overhead:
			on.append(moving)
		return on

	# Where each beam starts (the first tile inside, by the window) and
	# which way it goes.
	var beams: Array = []
	if _use_new_format:
		for seg in segments:
			var sd := seg as Dictionary
			if sd.get("demolished", false) or not sd.get("has_window", false):
				continue
			var x1: int = sd["x1"]; var y1: int = sd["y1"]
			var x2: int = sd["x2"]; var y2: int = sd["y2"]
			var wp: int = sd.get("window_pos", 0)  as int
			var wl: int = sd.get("window_len", 10) as int
			var is_horiz := (y1 == y2)
			var mn_x := mini(x1, x2); var mn_y := mini(y1, y2)
			for i in range(wl):
				var wall_tile := Vector2i(mn_x + wp + i, y1) if is_horiz else Vector2i(x1, mn_y + wp + i)
				for dir in ([Vector2i(0, 1), Vector2i(0, -1)] if is_horiz else [Vector2i(1, 0), Vector2i(-1, 0)]):
					var first: Vector2i = wall_tile + dir
					if is_floor_tile(first) and not blocked.has(first):
						beams.append([first, dir])
	else:
		for wd in wall_definitions:
			if not wd.get("has_window", false):
				continue
			var wx: int = wd.get("window_x", 0)
			var wl: int = wd.get("window_len", 0)
			for i in range(wl):
				match wd["edge"] as String:
					"north": beams.append([Vector2i(wx + i, 0), Vector2i(0, 1)])
					"south": beams.append([Vector2i(wx + i, grid_h - 1), Vector2i(0, -1)])
					"west":  beams.append([Vector2i(0, wx + i), Vector2i(1, 0)])
					"east":  beams.append([Vector2i(grid_w - 1, wx + i), Vector2i(-1, 0)])

	for beam in beams:
		var start: Vector2i = beam[0]
		var dir: Vector2i = beam[1]
		var strength := external_daylight_factor
		var dimmed_by: Dictionary = {}
		for step in BEAM_DEPTH:
			var t := wrap_tile(start + dir * step)   # daylight goes round a loop too
			if not is_floor_tile(t) or blocked.has(t):
				break
			var stop := false
			for p in pieces_on.call(t):
				var f := p as Furniture
				if f.blocks_light():
					stop = true
				elif not f.screen and f.height_category == "medium" and not dimmed_by.has(f):
					dimmed_by[f] = true
					strength *= MEDIUM_PASS
			var lit := strength * (1.0 if step < BEAM_DEPTH / 2 else BEAM_FAR)
			if lit > (out.get(t, 0.0) as float):
				out[t] = lit
			if stop:
				break

	# Skylights light their own footprint straight from above: whatever stands
	# under one is lit, and nothing on the floor can shade it.
	for item in _get_all_placed_unique():
		var sky := item as Furniture
		if not sky.overhead:
			continue
		for tile in _rect_tiles(sky.grid_pos, sky.grid_w, sky.grid_h):
			if is_floor_tile(tile) and tile not in blocked:
				out[tile] = maxf(out.get(tile, 0.0) as float, external_daylight_factor)
	return out


func set_active_wall_edge(edge: String) -> void:
	if grid_draw:
		grid_draw.set_active_edge(edge)


func setup(floor_data: Dictionary) -> void:
	floor_id    = floor_data["id"]
	floor_label = floor_data["label"]
	floor_type  = floor_data.get("type", "floor") as String
	parent_id   = floor_data.get("parent_id", "") as String
	grid_w      = floor_data["grid_w"]
	grid_h      = floor_data["grid_h"]
	ceiling_h = floor_data.get("ceiling_h", CEILING_H_M) as float
	ceiling_ramps = []
	for r in floor_data.get("ceiling_ramps", []) as Array:
		ceiling_ramps.append((r as Dictionary).duplicate(true))
	# Older levels carry one ramp as "sloped_ceiling".
	var legacy_slope := floor_data.get("sloped_ceiling", {}) as Dictionary
	if ceiling_ramps.is_empty() and not legacy_slope.is_empty():
		ceiling_ramps.append(legacy_slope.duplicate(true))
	floor_level.clear()
	for t in floor_data.get("floor_levels", []) as Array:
		if (t[2] as int) != 0:
			floor_level[Vector2i(t[0] as int, t[1] as int)] = t[2] as int
	step_mask.clear()
	for t in floor_data.get("step_tiles", []) as Array:
		step_mask[Vector2i(t[0] as int, t[1] as int)] = true
	connection_points = floor_data.get("connection_points", {})
	columns           = floor_data.get("columns", [])
	pipe_routes       = []

	_use_new_format = floor_data.has("segments")
	if _use_new_format:
		floor_mask.clear()
		for t in floor_data.get("floor_tiles", []):
			floor_mask[Vector2i(t[0] as int, t[1] as int)] = true
		floor_kind.clear()
		for t in floor_data.get("floor_kinds", []):
			floor_kind[Vector2i(t[0] as int, t[1] as int)] = t[2] as String
		mezzanine_mask.clear()
		for t in floor_data.get("mezzanine_tiles", []):
			mezzanine_mask[Vector2i(t[0] as int, t[1] as int)] = true
		# 6.0 weight units per tile of mezzanine structure is an arbitrary but
		# workable default (roughly "a couple of medium pieces per tile" given
		# Furniture.weight's own footprint-area default) — authored floors can
		# override it explicitly via "mezzanine_max_load" for a sturdier/flimsier loft.
		mezzanine_max_load = floor_data.get("mezzanine_max_load", mezzanine_mask.size() * 6.0) as float
		stair_mask.clear()
		stairs_data.clear()
		# New format: structured stairs array with rect + direction
		var _raw_stairs := floor_data.get("stairs", []) as Array
		if not _raw_stairs.is_empty():
			for _se in _raw_stairs:
				var _sd := _se as Dictionary
				var _r  := Rect2i(_sd["x"] as int, _sd["y"] as int,
					_sd["w"] as int, _sd["h"] as int)
				var _dir := _sd.get("direction", "north") as String
				var _tgt := _sd.get("target", "loft") as String
				stairs_data.append({"rect": _r, "direction": _dir, "target": _tgt})
				for _x in range(_r.size.x):
					for _y in range(_r.size.y):
						stair_mask[Vector2i(_r.position.x + _x, _r.position.y + _y)] = true
		else:
			# Legacy: plain stair_tiles list (no direction info)
			for t in floor_data.get("stair_tiles", []):
				stair_mask[Vector2i(t[0] as int, t[1] as int)] = true
		# Stair openings from parent floor (used by loft floors to show where stairs come up)
		stair_openings.clear()
		for _so in floor_data.get("stair_openings", []) as Array:
			var _sod := _so as Dictionary
			var _sor := Rect2i(_sod["x"] as int, _sod["y"] as int,
				_sod["w"] as int, _sod["h"] as int)
			stair_openings.append({"rect": _sor, "direction": _sod.get("direction", "north") as String, "target": _sod.get("target", "loft") as String})
		rails = (floor_data.get("rails", []) as Array).duplicate(true)
		reveal_zones = (floor_data.get("reveal_zones", []) as Array).duplicate(true)
		segments = []
		for s in floor_data.get("segments", []):
			var cs: Dictionary = (s as Dictionary).duplicate()
			if not cs.has("demolished"):
				cs["demolished"] = false
			segments.append(cs)
		wall_definitions = []
		partitions       = []
		_prune_floor_mask_to_walls()
		loop = LoopSeams.from_data(floor_data.get("loop"), get_room_bounds())
	else:
		loop             = null
		floor_mask       = {}
		segments         = []
		wall_definitions = floor_data.get("walls", [])
		partitions       = []
		for p in floor_data.get("partitions", []):
			var cp: Dictionary = (p as Dictionary).duplicate()
			cp["demolished"] = false
			partitions.append(cp)

	# Cache edge-detection bounds in local pixel space (tiles may not start at origin)
	if _use_new_format and not floor_mask.is_empty():
		var _mx0 := 999999; var _my0 := 999999
		var _mx1 := -999999; var _my1 := -999999
		for _t in floor_mask:
			var _tx: int = (_t as Vector2i).x; var _ty: int = (_t as Vector2i).y
			if _tx < _mx0: _mx0 = _tx
			if _ty < _my0: _my0 = _ty
			if _tx > _mx1: _mx1 = _tx
			if _ty > _my1: _my1 = _ty
		_edge_x0 = float(_mx0 * TILE_SIZE)
		_edge_y0 = float(_my0 * TILE_SIZE)
		_edge_x1 = float((_mx1 + 1) * TILE_SIZE)
		_edge_y1 = float((_my1 + 1) * TILE_SIZE)
	else:
		_edge_x0 = 0.0; _edge_y0 = 0.0
		_edge_x1 = float(grid_w * TILE_SIZE); _edge_y1 = float(grid_h * TILE_SIZE)

	if grid_draw:
		_compute_light_map()
		grid_draw.queue_redraw()


# The tiles walls stand on. A wall segment marked "translucent" (reeded or
# frosted glass, as in the Never Too Small flats) is a wall in every way but
# one: nothing can be put through it and nothing can be seen through it, but
# daylight passes. `for_light` leaves those segments out, so the light map
# flows straight through them.
# The tiles of the wall line a window takes up. _partition_tile_set() leaves
# them open (light and lines of sight go through a window), but nothing can
# be put in one or walk through one: a stool used to fit in the window gap.
func _window_tile_set() -> Dictionary:
	var out: Dictionary = {}
	if not _use_new_format:
		return out
	for p in segments:
		if p.get("demolished", false) or not (p.get("has_window", false) as bool):
			continue
		var x1: int = p["x1"]; var y1: int = p["y1"]
		var x2: int = p["x2"]; var y2: int = p["y2"]
		var wp := p.get("window_pos", -1) as int
		var wl := p.get("window_len", 0) as int
		if wp < 0:
			continue
		for i in range(wp, wp + wl):
			out[Vector2i(x1, mini(y1, y2) + i) if x1 == x2 else Vector2i(mini(x1, x2) + i, y1)] = true
	return out


func _partition_tile_set(for_light: bool = false) -> Dictionary:
	var blocked: Dictionary = {}

	var source: Array = segments if _use_new_format else partitions
	for p in source:
		if p.get("demolished", false):
			continue
		if for_light and (p.get("translucent", false) as bool):
			continue
		var x1: int = p["x1"]; var y1: int = p["y1"]
		var x2: int = p["x2"]; var y2: int = p["y2"]
		var has_win  := p.get("has_window", false) as bool
		var wp       := p.get("window_pos", -1)   as int
		var wl       := p.get("window_len", 0)    as int
		var has_door := p.get("has_door",   false) as bool
		var dp       := p.get("door_pos",   -1)   as int
		var DOOR_LEN := 10
		if x1 == x2:
			for y in range(mini(y1, y2), maxi(y1, y2) + 1):
				var rel := y - mini(y1, y2)
				var in_w := has_win  and wp >= 0 and rel >= wp and rel < wp + wl
				var in_d := has_door and dp >= 0 and rel >= dp and rel < dp + DOOR_LEN
				if not in_w and not in_d:
					blocked[Vector2i(x1, y)] = true
		else:
			for x in range(mini(x1, x2), maxi(x1, x2) + 1):
				var rel := x - mini(x1, x2)
				var in_w := has_win  and wp >= 0 and rel >= wp and rel < wp + wl
				var in_d := has_door and dp >= 0 and rel >= dp and rel < dp + DOOR_LEN
				if not in_w and not in_d:
					blocked[Vector2i(x, y1)] = true

	for col in columns:
		blocked[Vector2i(col["x"] as int, col["y"] as int)] = true
	return blocked


func demolish_partition(idx: int) -> void:
	if idx < 0 or idx >= partitions.size():
		return
	if partitions[idx].get("load_bearing", false):
		return
	partitions[idx]["demolished"] = true
	if grid_draw:
		_compute_light_map()
		grid_draw.queue_redraw()


func demolish_segment(idx: int) -> void:
	if idx < 0 or idx >= segments.size():
		return
	if (segments[idx] as Dictionary).get("primary", false):
		return  # primary walls are permanent
	segments[idx]["demolished"] = true
	if grid_draw:
		_compute_light_map()
		grid_draw.queue_redraw()


# ── Player-authored building (Builder tab) ──────────────────────────────────
# Walls added in gameplay are always non-"primary" (demolishable) — permanent
# structural walls stay level-author-only, authored via LevelEditor.gd.

func can_add_segment(x1: int, y1: int, x2: int, y2: int) -> bool:
	if x1 != x2 and y1 != y2:
		return false  # must be axis-aligned, same as every other segment
	if x1 == x2:
		for y in range(mini(y1, y2), maxi(y1, y2) + 1):
			if _placed_any_at(Vector2i(x1, y)):
				return false
	else:
		for x in range(mini(x1, x2), maxi(x1, x2) + 1):
			if _placed_any_at(Vector2i(x, y1)):
				return false
	return true


func add_segment(x1: int, y1: int, x2: int, y2: int, translucent: bool = false) -> void:
	var seg := {"x1": x1, "y1": y1, "x2": x2, "y2": y2, "primary": false, "demolished": false}
	if translucent:
		seg["translucent"] = true
	segments.append(seg)
	if grid_draw:
		_compute_light_map()
		grid_draw.queue_redraw()


func can_place_column(x: int, y: int) -> bool:
	return not _placed_any_at(Vector2i(x, y))


# Click-again-to-remove, mirroring LevelEditor._toggle_column.
func toggle_column(x: int, y: int) -> void:
	for i in range(columns.size()):
		var c := columns[i] as Dictionary
		if (c["x"] as int) == x and (c["y"] as int) == y:
			columns.remove_at(i)
			if grid_draw:
				_compute_light_map()
				grid_draw.queue_redraw()
			return
	if not can_place_column(x, y):
		return
	columns.append({"x": x, "y": y})
	if grid_draw:
		_compute_light_map()
		grid_draw.queue_redraw()


# General Builder-tab erase: tries a nearby wall segment first (only ones the
# player could have added or that are otherwise demolishable), then a column
# at the given tile, then a painted floor-kind tag, then a reveal zone, then a
# rail track, then a pipe route. Reveal zones are checked before rails
# deliberately — a reveal zone is a narrow sub-range nested inside a rail, so
# a click aimed at one is also near the rail it sits on; checking rails first
# would let an Erase click meant to remove a small reveal zone take out the
# whole rail instead. Returns true if something was actually removed.
func erase_near(local_pos: Vector2, tile: Vector2i) -> bool:
	var idx := find_segment_near(local_pos, 1.5)
	if idx >= 0:
		var sd := segments[idx] as Dictionary
		if not sd.get("primary", false) and not sd.get("demolished", false):
			demolish_segment(idx)
			return true
	for i in range(columns.size()):
		var c := columns[i] as Dictionary
		if (c["x"] as int) == tile.x and (c["y"] as int) == tile.y:
			columns.remove_at(i)
			if grid_draw:
				_compute_light_map()
				grid_draw.queue_redraw()
			return true
	if floor_kind.has(tile):
		floor_kind.erase(tile)
		if grid_draw:
			grid_draw.queue_redraw()
		return true
	if erase_reveal_zone_near(local_pos):
		return true
	if erase_rail_near(local_pos):
		return true
	var pipe_type := pipe_route_type_near(local_pos, 1.5)
	if pipe_type != "":
		clear_pipe_route(pipe_type)
		return true
	return false


# Stamps a tile with a floor kind ("balcony"/"bathroom"), or clears the tag
# when kind is "normal" — mirrors LevelEditor's Floor Paint tool.
func paint_floor_kind(tile: Vector2i, kind: String) -> void:
	if kind == "normal":
		if floor_kind.has(tile):
			floor_kind.erase(tile)
		else:
			return
	else:
		if floor_kind.get(tile, "normal") == kind:
			return
		floor_kind[tile] = kind
	if grid_draw:
		grid_draw.queue_redraw()


# Click-again-to-remove, mirroring toggle_column. A segment can carry a
# window or a door but not both (mirrors LevelEditor's single-feature-per-
# segment model); the shared window/door tools reject the segment (returns
# false) if the other feature is already present so a stray click can't
# silently overwrite it.
func toggle_window_on_segment(idx: int) -> bool:
	if idx < 0 or idx >= segments.size():
		return false
	var sd := segments[idx] as Dictionary
	if sd.get("demolished", false):
		return false
	if sd.get("has_window", false):
		sd.erase("has_window"); sd.erase("window_pos"); sd.erase("window_len")
	else:
		if sd.get("has_door", false):
			return false
		var seg_len: int = maxi(absi((sd["x2"] as int) - (sd["x1"] as int)), absi((sd["y2"] as int) - (sd["y1"] as int)))
		var wl: int = mini(10, seg_len)
		sd["has_window"] = true
		sd["window_pos"] = maxi(0, (seg_len - wl) / 2)
		sd["window_len"] = wl
	if grid_draw:
		_compute_light_map()
		grid_draw.queue_redraw()
	return true


func toggle_door_on_segment(idx: int) -> bool:
	if idx < 0 or idx >= segments.size():
		return false
	var sd := segments[idx] as Dictionary
	if sd.get("demolished", false):
		return false
	if sd.get("has_door", false):
		sd.erase("has_door"); sd.erase("door_pos")
	else:
		if sd.get("has_window", false):
			return false
		var seg_len: int = maxi(absi((sd["x2"] as int) - (sd["x1"] as int)), absi((sd["y2"] as int) - (sd["y1"] as int)))
		var dl := mini(10, seg_len)
		sd["has_door"] = true
		sd["door_pos"] = maxi(0, (seg_len - dl) / 2)
	if grid_draw:
		grid_draw.queue_redraw()
	return true


func find_segment_near(fl_pos: Vector2, snap_tiles: float = 1.5) -> int:
	var snap := float(TILE_SIZE) * snap_tiles
	var best_d := snap
	var best_i := -1
	for i in range(segments.size()):
		var sd := segments[i] as Dictionary
		if sd.get("demolished", false):
			continue
		var pa := Vector2(sd["x1"] as int * TILE_SIZE, sd["y1"] as int * TILE_SIZE)
		var pb := Vector2(sd["x2"] as int * TILE_SIZE, sd["y2"] as int * TILE_SIZE)
		var seg := pb - pa
		var seg_len := seg.length()
		if seg_len < 1.0:
			continue
		var t   := clampf((fl_pos - pa).dot(seg) / (seg_len * seg_len), 0.0, 1.0)
		var d   := fl_pos.distance_to(pa + seg * t)
		if d < best_d:
			best_d = d; best_i = i
	return best_i


# Rails are axis-aligned sliding-furniture tracks — same {x1,y1,x2,y2} shape
# as a wall segment but stored separately since they never block movement or
# placement, only constrain how a piece dropped onto one can later slide.
func can_add_rail(x1: int, y1: int, x2: int, y2: int) -> bool:
	return x1 == x2 or y1 == y2  # must be axis-aligned; may cross furniture/floor freely


func add_rail(x1: int, y1: int, x2: int, y2: int) -> void:
	rails.append({"x1": x1, "y1": y1, "x2": x2, "y2": y2})
	if grid_draw:
		grid_draw.queue_redraw()


func find_rail_near(fl_pos: Vector2, snap_tiles: float = 1.5) -> int:
	var snap := float(TILE_SIZE) * snap_tiles
	var best_d := snap
	var best_i := -1
	for i in range(rails.size()):
		var rd := rails[i] as Dictionary
		var pa := Vector2(rd["x1"] as int * TILE_SIZE, rd["y1"] as int * TILE_SIZE)
		var pb := Vector2(rd["x2"] as int * TILE_SIZE, rd["y2"] as int * TILE_SIZE)
		var seg := pb - pa
		var seg_len := seg.length()
		if seg_len < 1.0:
			continue
		var t := clampf((fl_pos - pa).dot(seg) / (seg_len * seg_len), 0.0, 1.0)
		var d := fl_pos.distance_to(pa + seg * t)
		if d < best_d:
			best_d = d; best_i = i
	return best_i


func erase_rail_near(local_pos: Vector2) -> bool:
	var idx := find_rail_near(local_pos, 1.5)
	if idx < 0:
		return false
	rails.remove_at(idx)
	if grid_draw:
		grid_draw.queue_redraw()
	return true


# Reveal zones are a sub-range of a rail — same {x1,y1,x2,y2} shape again —
# marking where a rail piece counts as "revealed" for a moment. Independent
# of the rail tool since a rail can have zero, one, or several reveal zones.
func can_add_reveal_zone(x1: int, y1: int, x2: int, y2: int) -> bool:
	return x1 == x2 or y1 == y2


func add_reveal_zone(x1: int, y1: int, x2: int, y2: int) -> void:
	reveal_zones.append({"x1": x1, "y1": y1, "x2": x2, "y2": y2})
	if grid_draw:
		grid_draw.queue_redraw()


func find_reveal_zone_near(fl_pos: Vector2, snap_tiles: float = 1.5) -> int:
	var snap := float(TILE_SIZE) * snap_tiles
	var best_d := snap
	var best_i := -1
	for i in range(reveal_zones.size()):
		var rd := reveal_zones[i] as Dictionary
		var pa := Vector2(rd["x1"] as int * TILE_SIZE, rd["y1"] as int * TILE_SIZE)
		var pb := Vector2(rd["x2"] as int * TILE_SIZE, rd["y2"] as int * TILE_SIZE)
		var seg := pb - pa
		var seg_len := seg.length()
		if seg_len < 1.0:
			continue
		var t := clampf((fl_pos - pa).dot(seg) / (seg_len * seg_len), 0.0, 1.0)
		var d := fl_pos.distance_to(pa + seg * t)
		if d < best_d:
			best_d = d; best_i = i
	return best_i


func erase_reveal_zone_near(local_pos: Vector2) -> bool:
	var idx := find_reveal_zone_near(local_pos, 1.5)
	if idx < 0:
		return false
	reveal_zones.remove_at(idx)
	if grid_draw:
		grid_draw.queue_redraw()
	return true


func _near_edge(local: Vector2, x0: float, y0: float, x1: float, y1: float) -> String:
	if local.y < y0 + EDGE_MARGIN and local.x > x0 and local.x < x1: return "north"
	if local.y > y1 - EDGE_MARGIN and local.x > x0 and local.x < x1: return "south"
	if local.x < x0 + EDGE_MARGIN and local.y > y0 and local.y < y1: return "west"
	if local.x > x1 - EDGE_MARGIN and local.y > y0 and local.y < y1: return "east"
	return ""


func _input(event: InputEvent) -> void:
	if not visible or input_suppressed:
		return
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var local := to_local(get_global_mouse_position())
	if event.pressed:
		# New-format: press must start near an actual segment line
		# Old-format: press must start near a bounding-box edge
		var near := false
		if _use_new_format:
			near = find_segment_near(local, 3.0) >= 0
		else:
			near = _near_edge(local, _edge_x0, _edge_y0, _edge_x1, _edge_y1) != ""
		if near:
			_drag_press_local = local
			_drag_active      = true
		return
	# ── Button released ────────────────────────────────────────────────────────
	if not _drag_active:
		return
	_drag_active = false
	# Edge is determined by drag direction — same logic for both formats
	var drag := local - _drag_press_local
	var edge  := ""
	if drag.length() > EDGE_MARGIN:
		# Long drag: direction of the drag selects which face to inspect
		if abs(drag.x) >= abs(drag.y):
			edge = "east" if drag.x > 0.0 else "west"
		else:
			edge = "south" if drag.y > 0.0 else "north"
	elif not _use_new_format:
		# Short click on old format: proximity to bounding-box edge
		edge = _near_edge(local, _edge_x0, _edge_y0, _edge_x1, _edge_y1)
	else:
		# Short click on new format: position relative to floor centre picks face
		var cx := (_edge_x0 + _edge_x1) * 0.5
		var cy := (_edge_y0 + _edge_y1) * 0.5
		var dx := local.x - cx;  var dy := local.y - cy
		if abs(dx) >= abs(dy):
			edge = "east" if dx > 0.0 else "west"
		else:
			edge = "south" if dy > 0.0 else "north"
	if edge == "":
		return
	# Which sub-span of this edge was actually clicked (multi-room floors only
	# — see get_wall_span; a floor with no interior wall crossing this edge
	# just gets the whole edge back, unchanged from before spans existed).
	var click_coord := int((local.x if edge in ["north", "south"] else local.y) / float(TILE_SIZE))
	var span := get_wall_span(edge, click_coord)
	# Emit signal — do NOT set_input_as_handled so editor painting still gets the event
	wall_edge_clicked.emit(edge, span.x, span.y)


const WALL_SNAP := 1.0   # tiles — placing within this distance of a wall snaps flush against it

# Nudges a placement position flush against any wall it's within WALL_SNAP
# tiles of, so "close to the wall" in the top-down actually means "touching"
# everywhere that reads adjacency (Wall Inspector mirror, occlusion, etc.),
# not just visually close at the floor plan's small scale.
func snap_to_wall(furniture: Furniture, at: Vector2) -> Vector2:
	var bounds := get_room_bounds()
	# A piece standing across a seam of a looped floor is not near a wall
	# there: leave it where it was put.
	if loop != null:
		at = wrap_point(at)
		if loop.split_rect(Rect2(at, Vector2(furniture.grid_w, furniture.grid_h))).size() > 1:
			return at
	var snap_pos := at
	# bounds.position itself is the wall's own tile (blocked by
	# _partition_tile_set), so touching the west/north wall means sitting one
	# tile in from it — genuinely so now, not a hack: the wall occupies the
	# continuous interval [bounds.position, bounds.position+1), so a flush
	# furniture edge really does sit at exactly bounds.position + 1.0. The far
	# side needs no such offset: subtracting the furniture's size from
	# bounds.position + bounds.size already lands one tile short of that
	# wall's own blocked tile.
	if at.x - bounds.position.x <= WALL_SNAP:
		snap_pos.x = bounds.position.x + 1.0
	elif (bounds.position.x + bounds.size.x) - (at.x + furniture.grid_w) <= WALL_SNAP:
		snap_pos.x = bounds.position.x + bounds.size.x - furniture.grid_w
	if at.y - bounds.position.y <= WALL_SNAP:
		snap_pos.y = bounds.position.y + 1.0
	elif (bounds.position.y + bounds.size.y) - (at.y + furniture.grid_h) <= WALL_SNAP:
		snap_pos.y = bounds.position.y + bounds.size.y - furniture.grid_h
	if furniture.wall_flush_required and snap_pos == at and not on_a_rail(furniture, at) and not backs_onto_wall(furniture, at):
		# A piece that has to stand against a wall (a fold-down bed, the
		# balcony window, a folding stair) and was put down away from every
		# wall goes to the nearest wall it fits against, instead of being
		# refused for not touching one.
		var nearest := _nearest_wall_spot(furniture, at, bounds)
		if nearest != at:
			return nearest
	if snap_pos == at or can_place(furniture, snap_pos):
		return snap_pos
	# Full snap blocked (e.g. corner obstruction) — try each axis independently
	var x_only := Vector2(snap_pos.x, at.y)
	if x_only != at and can_place(furniture, x_only):
		return x_only
	var y_only := Vector2(at.x, snap_pos.y)
	if y_only != at and can_place(furniture, y_only):
		return y_only
	return at


const LANDING_SLACK := 4   # tiles, past half the piece's own size, landing_spot() looks around

# Where a piece put down at `at` (already snap_to_wall()ed) actually lands:
# `at` itself if it can stand there, otherwise the nearest spot around it
# where it can — half through a wall, over another piece, its back off the
# wall: it lands next to that instead of jumping back. Vector2.INF when
# nothing near enough fits; get_block_reason() then says why `at` didn't.
# `across_moments`: the piece is being moved, and a red non-rail one (one
# place for every moment) also has to clear every other moment's layout.
func landing_spot(furniture: Furniture, at: Vector2, across_moments := false) -> Vector2:
	var fits := func(p: Vector2) -> bool:
		if not can_place(furniture, p):
			return false
		if across_moments and furniture.mobility_tier == "red" and furniture.rail_axis == "" \
				and Furniture.test_mode_active and Furniture.all_moment_ids.size() > 1:
			return can_place_across_moments(furniture, p, Furniture.all_moment_ids, Furniture.active_moment_id)
		return true
	if fits.call(at):
		return at
	var why := _block_reason
	var reach := ceili(maxf(furniture.grid_w, furniture.grid_h) * 0.5) + LANDING_SLACK
	var offsets: Array[Vector2i] = []
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			if dx != 0 or dy != 0:
				offsets.append(Vector2i(dx, dy))
	offsets.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.length_squared() < b.length_squared())
	for o in offsets:
		var spot := at + Vector2(o)
		if fits.call(spot):
			# Close to a wall: flush against it, as any drop there would be.
			var flush := snap_to_wall(furniture, spot)
			return flush if flush != spot and fits.call(flush) else spot
	_block_reason = why
	return Vector2.INF


# The spot against a wall closest to `at` where `furniture` can go: each of
# the four walls is tried, nearest first, sliding along it from `at` if the
# spot right opposite is taken. `at` itself when none has room.
func _nearest_wall_spot(furniture: Furniture, at: Vector2, bounds: Rect2) -> Vector2:
	var west := bounds.position.x + 1.0
	var north := bounds.position.y + 1.0
	var east := bounds.position.x + bounds.size.x - furniture.grid_w
	var south := bounds.position.y + bounds.size.y - furniture.grid_h
	var walls := [
		[absf(at.x - west), Vector2(west, at.y), Vector2.DOWN],
		[absf(east - at.x), Vector2(east, at.y), Vector2.DOWN],
		[absf(at.y - north), Vector2(at.x, north), Vector2.RIGHT],
		[absf(south - at.y), Vector2(at.x, south), Vector2.RIGHT],
	]
	walls.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var span := int(maxf(bounds.size.x, bounds.size.y))
	for wall in walls:
		var base: Vector2 = wall[1]
		var along: Vector2 = wall[2]
		for step in span:
			for dir in ([0] if step == 0 else [step, -step]):
				var spot: Vector2 = base + along * float(dir)
				if can_place(furniture, spot):
					return spot
	return at


func can_place(furniture: Furniture, at: Vector2) -> bool:
	_block_reason = ""
	at = wrap_point(at)
	# Looped floor: a piece longer than the loop meets its own tail.
	if loop != null and LoopSeams.parts_overlap(loop.split_rect(Rect2(at, Vector2(furniture.grid_w, furniture.grid_h)))):
		_block_reason = tr("Longer than the loop: it runs into itself")
		return false
	var blocked := _partition_tile_set()
	blocked.merge(_window_tile_set())
	for tile in _rect_tiles(at, furniture.grid_w, furniture.grid_h):
		if not is_floor_tile(tile):
			_block_reason = tr("Outside the room")
			return false
		# Nested/parabox boxes are a structural container, not furniture with
		# a real usage tied to floor type — a balcony or bathroom is exactly
		# as valid a spot for one as any other room, so it's exempt from the
		# balcony/bathroom flooring restriction below.
		if not furniture.is_nested_box and not _floor_category_ok(furniture.floor_category, get_tile_kind(tile)):
			_block_reason = tr("Needs %s flooring") % Loc.floor_kind_name(furniture.floor_category)
			return false
		if tile in blocked:
			_block_reason = tr("Blocked by a wall")
			return false

	# (A piece on a rail is meant to slide out into the room: exempt.)
	if furniture.wall_flush_required and not on_a_rail(furniture, at) and not backs_onto_wall(furniture, at):
		_block_reason = tr("Its back has to be against a wall")
		return false

	# Weight & structural support (see Furniture.gd's weight/is_surface/
	# requires_surface fields). Two independent checks:
	#  - a piece landing on mezzanine tiles must not push the loft's total
	#    carried weight past what it can structurally support;
	#  - stacking: ANY piece whose footprint lands fully on top of a furniture
	#    piece flagged is_surface counts as being stacked there (not gated
	#    behind requires_surface any more — a heavy item stacked on a flimsy
	#    surface should be rejected regardless of whether the item itself was
	#    specifically authored as "needs a surface"). requires_surface stays
	#    as a stronger, separate constraint: THAT item can never sit on bare
	#    floor at all, surface or no.
	var target_tiles := _rect_tiles(at, furniture.grid_w, furniture.grid_h)
	var on_mezzanine := false
	for tile in target_tiles:
		if mezzanine_mask.get(tile, false):
			on_mezzanine = true
			break
	# Under a loft there is LOFT_HEADROOM of height: a chest freezer or a
	# desk fits, a fridge or a wardrobe doesn't (they used to go anywhere).
	if on_mezzanine and not furniture.walkable and stack_lift(furniture, at) + furniture.body_h > LOFT_HEADROOM:
		_block_reason = tr("Too tall to go under the loft")
		return false
	if on_mezzanine and mezzanine_max_load > 0.0:
		var projected_load := _mezzanine_load(furniture) + furniture.weight
		if projected_load > mezzanine_max_load:
			_block_reason = tr("Too heavy for this loft (%.0f / %.0f)") % [projected_load, mezzanine_max_load]
			return false

	# Inside a box that stands on a table: a new piece is weight on that table
	# too, shrunk (see Main._apply_carry_limit()). Moving what is already in
	# here weighs nothing more.
	if Floor.carry_limit >= 0.0 and Floor.carried_weight.is_valid() and not is_registered(furniture):
		if (Floor.carried_weight.call() as float) + furniture._base_weight > Floor.carry_limit:
			_block_reason = tr("Too heavy: what this box stands on would break (%s)") % Floor.carry_support_name
			return false

	var stacked_on := _surface_support_at(target_tiles, furniture)
	if furniture.requires_surface and stacked_on == null:
		_block_reason = tr("Needs a table or shelf underneath")
		return false
	if stacked_on != null:
		var spare: float = stacked_on.max_support_weight - _surface_load(stacked_on, furniture)
		if furniture.weight > spare:
			_block_reason = tr("Too heavy for %s — it would break (%.0f / %.0f)") % [
				stacked_on.furniture_name, furniture.weight, stacked_on.max_support_weight]
			return false

	# Furniture-vs-furniture overlap: precise continuous rects + Z-range test,
	# not tile-quantized — two pieces can sit flush at a fractional boundary
	# without a false collision from tile rounding.
	var new_rect := Rect2(at, Vector2(furniture.grid_w, furniture.grid_h))
	var new_parts := footprint_rects(new_rect)
	# Whatever rests on this piece travels with it (move_with_riders()), so it
	# is never in its own way; the riders' own landing spots are checked there.
	var carried := riders_of(furniture) if furniture.is_surface else []
	# The surface it would stand on, and whatever that one stands on in turn.
	var under: Array = []
	var below := stacked_on
	while below != null and below not in under:
		under.append(below)
		below = support_under(below)
	for entry in _placed_continuous:
		var f: Furniture = entry["furniture"]
		if f in carried:
			continue
		# stacked_on is deliberately excluded here — a piece legitimately
		# stacked on top of its support (already weight-checked above) sits at
		# the SAME tiles as that support with the SAME z_bottom==0 (there's no
		# real Z offset tracked for a stacked item, see Furniture.gd's z_top/
		# z_bottom comments), so without this exemption it would always fail
		# the ordinary overlap check right after passing the weight check.
		if f == furniture or f in under:
			continue
		if furniture.z_top <= f.z_bottom or furniture.z_bottom >= f.z_top:
			continue   # different Z layers (e.g. loft above, ground below) never collide
		var other_rect := Rect2(entry["pos"] as Vector2, Vector2(f.grid_w, f.grid_h))
		if _rects_meet(new_parts, footprint_rects(other_rect)):
			_block_reason = tr("Overlaps %s") % f.furniture_name
			return false

	# Split levels: a piece stands on one level, and never on the steps.
	if has_split_levels():
		var lvl := level_at(target_tiles[0])
		for tile in target_tiles:
			if step_mask.has(tile):
				_block_reason = tr("Keep the steps clear")
				return false
			if level_at(tile) != lvl:
				_block_reason = tr("Can't stand across a step")
				return false

	# Ceiling: the floor it stands on, whatever it stands on and the piece
	# itself all have to fit under the ceiling over every tile it covers.
	# (A skylight is set into the ceiling itself, whatever its height.)
	var need_tiles := stack_lift(furniture, at) + furniture.body_h
	for tile in (target_tiles if not furniture.overhead else []):
		if (need_tiles + level_at(tile)) * 0.1 > ceiling_height_at(Vector2(tile)) + 0.001:
			_block_reason = tr("Ceiling too low here")
			return false

	# Ghost zone: can't place inside another furniture's interaction clearance
	# — except the piece THIS one is legitimately stacked on top of (already
	# weight-checked above); its own clearance ring is about keeping OTHER
	# furniture from blocking access to it, not about what sits on its surface.
	for entry in _placed_continuous:
		var f: Furniture = entry["furniture"]
		if f == furniture or f in under or f.ghost_radius <= 0 or f in carried:
			continue
		# Clearance is floor space around a piece: a loft bed up at 1.4 m is
		# not in a desk's way, and the desk is not in its.
		if furniture.z_top <= f.z_bottom or furniture.z_bottom >= f.z_top:
			continue
		var fpos: Vector2 = entry["pos"]
		var ghost := Rect2(
			fpos - Vector2(f.ghost_radius, f.ghost_radius),
			Vector2(f.grid_w + f.ghost_radius * 2, f.grid_h + f.ghost_radius * 2)
		)
		if _rects_meet(new_parts, footprint_rects(ghost)):
			_block_reason = tr("Needs clearance around %s") % f.furniture_name
			return false

	# A swing door needs the quarter circle it opens through (a rug can lie
	# there; nothing else can stand there).
	if not furniture.walkable:
		for swing in door_swings():
			for part in new_parts:
				if _rect_hits_swing(part, swing as Dictionary):
					_block_reason = tr("In the way of the door")
					return false

	# Every other moment of the day: the piece is there too (unless it has a
	# spot of its own in that moment), and so is everything else as it stands
	# then, unfolded beds and all, each with its clearance.
	var clash := _moment_clash(furniture, at, under, carried)
	if clash != "":
		_block_reason = clash
		return false

	return true


# The quarter circle each swing door of this floor opens through, in tiles:
# [{hinge: Vector2, dir: Vector2 (the quadrant, ±1 per axis), r: float}],
# matching how GridDraw draws its arc. Sliding doors don't swing.
func door_swings() -> Array:
	var out: Array = []
	if not _use_new_format:
		return out
	for seg in segments:
		var sd := seg as Dictionary
		if sd.get("demolished", false) or not (sd.get("has_door", false) as bool) \
				or (sd.get("door_type", "swing") as String) == "sliding":
			continue
		var x1: int = sd["x1"]; var y1: int = sd["y1"]
		var x2: int = sd["x2"]; var y2: int = sd["y2"]
		var dp := sd.get("door_pos", 0) as int
		var side := 1.0 if (sd.get("door_side", 1) as int) > 0 else -1.0
		if y1 == y2:
			out.append({"hinge": Vector2(mini(x1, x2) + dp, y1), "dir": Vector2(1.0, side), "r": float(DOOR_SWING_LEN)})
		else:
			out.append({"hinge": Vector2(x1, mini(y1, y2) + dp), "dir": Vector2(side, 1.0), "r": float(DOOR_SWING_LEN)})
	return out

const DOOR_SWING_LEN := 10   # tiles, the door's width (see _partition_tile_set)


func _rect_hits_swing(rect: Rect2, swing: Dictionary) -> bool:
	var h: Vector2 = swing["hinge"]
	var d: Vector2 = swing["dir"]
	var r: float = swing["r"]
	var quad := Rect2(h, d * r).abs()
	var part := rect.intersection(quad)
	if part.size.x <= 0.0 or part.size.y <= 0.0:
		return false
	var nearest := Vector2(clampf(h.x, part.position.x, part.end.x), clampf(h.y, part.position.y, part.end.y))
	return nearest.distance_to(h) < r - 0.01


# Why `furniture` at `at` can't stay there in some other moment, or "".
# Pieces it would stand on (`under`) or carry along (`carried`) don't count,
# as in can_place(). The moment on screen while testing moments is
# can_place()'s own; without moments there is nothing to check.
func _moment_clash(furniture: Furniture, at: Vector2, under: Array, carried: Array) -> String:
	if Furniture.all_moment_ids.size() < 2:
		return ""
	for mid in Furniture.all_moment_ids:
		var m := mid as String
		if Furniture.test_mode_active and m == Furniture.active_moment_id:
			continue
		if furniture.has_own_moment_position() and furniture.moment_positions.has(m):
			continue   # it stands somewhere of its own then
		var h := furniture.grid_h
		if furniture.foldable and furniture.extended_add_h > 0:
			h = (furniture._base_grid_h + furniture.extended_add_h) if (furniture.moment_fold_state.get(m, false) as bool) else furniture._base_grid_h
		var rect := footprint_rects(Rect2(at, Vector2(furniture.grid_w, h)))
		var label: String = Furniture.moment_labels.get(m, m)
		for f in get_all_furniture():
			var other := f as Furniture
			if other == furniture or other in under or other in carried:
				continue
			var r := other.get_moment_rect(m)
			if _rects_meet(rect, footprint_rects(r)) and not (furniture.z_top <= other.z_bottom or furniture.z_bottom >= other.z_top):
				return tr("Would overlap %s during \"%s\"") % [other.furniture_name, label]
			var apart := furniture.z_top <= other.z_bottom or furniture.z_bottom >= other.z_top
			if other.ghost_radius > 0 and not apart and _rects_meet(rect, footprint_rects(r.grow(float(other.ghost_radius)))):
				return tr("Needs clearance around %s during \"%s\"") % [other.furniture_name, label]
	return ""


# Where the other pieces stand in moments other than the one on screen, when
# that differs from now (an unfolded bed at night, a piece moved for the
# evening), with their clearance: [{rect: Rect2 tiles, label: moment name}].
func other_moment_zones(exclude: Furniture) -> Array:
	var out: Array = []
	if Furniture.all_moment_ids.size() < 2:
		return out
	for f in get_all_furniture():
		var other := f as Furniture
		if other == exclude:
			continue
		var now := Rect2(other.grid_pos, Vector2(other.grid_w, other.grid_h))
		for mid in Furniture.all_moment_ids:
			var m := mid as String
			var r := other.get_moment_rect(m)
			if r == now:
				continue
			out.append({"rect": r.grow(float(other.ghost_radius)), "label": Furniture.moment_labels.get(m, m)})
	return out


# Extra check for a red-tier, non-rail piece — it shares ONE position across
# every Moment (see Furniture.has_own_moment_position()), so moving it isn't
# just a local edit: the new spot has to be free in every OTHER Moment too,
# not just whichever one is on screen right now (can_place() alone only ever
# validates against the live/current layout). `active_moment_id` is skipped
# since can_place() already covers it.
func can_place_across_moments(furniture: Furniture, at: Vector2, all_moments: Array, active_moment_id: String) -> bool:
	var new_rect := Rect2(at, Vector2(furniture.grid_w, furniture.grid_h))
	for mid in all_moments:
		var mid_s := mid as String
		if mid_s == active_moment_id:
			continue
		for f in get_all_furniture():
			var other := f as Furniture
			if other == furniture:
				continue
			if furniture.z_top <= other.z_bottom or furniture.z_bottom >= other.z_top:
				continue
			if new_rect.intersects(other.get_moment_rect(mid_s)):
				var mid_label: String = Furniture.moment_labels.get(mid_s, mid_s)
				_block_reason = tr("Would overlap %s during \"%s\"") % [other.furniture_name, mid_label]
				return false
	return true


# The reason the most recent can_place() call returned false ("" if it
# returned true, or if nothing has called it yet) — read right after
# can_place() by whatever's showing the player feedback.
func get_block_reason() -> String:
	return _block_reason


func place_furniture(furniture: Furniture, at: Vector2) -> void:
	_remove_from_grid(furniture)
	at = wrap_point(at)
	for tile in _rect_tiles(at, furniture.grid_w, furniture.grid_h):
		_placed_add(tile, furniture)
	_placed_continuous.append({"furniture": furniture, "pos": at})
	furniture.grid_pos = at
	furniture.position = at * TILE_SIZE
	# Stair furniture: register block in stairs_data + populate stair_mask
	if furniture.is_stair:
		_register_stair(furniture, Vector2i(floori(at.x), floori(at.y)))
	_layout_changed()


func remove_furniture(furniture: Furniture) -> void:
	_remove_from_grid(furniture)
	if _floor_drag_ghost.get("furniture") == furniture:
		clear_floor_drag_ghost()
	furniture.queue_free()
	_layout_changed()


# Light and zones are recomputed from scratch whenever a piece is put down or
# taken away, about a tenth of a second each time on a full floor. A level
# being put together piece by piece (loaded, restored after a box trip or an
# undo) wraps that in begin_batch()/end_batch() so it happens once, for the
# finished layout, with the same result.
var _batch_depth := 0
var _batch_dirty := false


func begin_batch() -> void:
	_batch_depth += 1


func end_batch() -> void:
	_batch_depth = maxi(0, _batch_depth - 1)
	if _batch_depth == 0 and _batch_dirty:
		_batch_dirty = false
		_layout_changed()


func _layout_changed() -> void:
	if _batch_depth > 0:
		_batch_dirty = true
		return
	_update_stack_order()
	_update_strain()
	_compute_light_map()
	_recalculate_zones()
	furniture_changed.emit()


func _recalculate_zones() -> void:
	zones = []
	if not _use_new_format:
		return

	# All walkable floor tiles (floor_mask empty = whole grid)
	var all_floor: Dictionary = {}
	if loop != null:
		# A looped floor's rooms are what its walls (and the seams) make of
		# it: a wall keeps two rooms apart until a seam joins them round the
		# back. (An ordinary floor floods its whole grid, below.)
		var walls := _partition_tile_set()
		var b := get_room_bounds()
		for x in range(b.position.x, b.end.x + 1):
			for y in range(b.position.y, b.end.y + 1):
				var t := Vector2i(x, y)
				if is_floor_tile(t) and not walls.has(t):
					all_floor[t] = true
	elif floor_mask.is_empty():
		for x in range(grid_w):
			for y in range(grid_h):
				all_floor[Vector2i(x, y)] = true
	else:
		all_floor = floor_mask

	# Tiles occupied by zone-divider furniture are walls for zone purposes
	var divider_tiles: Dictionary = {}
	for item in _get_all_placed_unique():
		var f := item as Furniture
		if not f.divides_zone():
			continue
		for t in _rect_tiles(f.grid_pos, f.grid_w, f.grid_h):
			divider_tiles[t] = true

	# BFS flood-fill to find connected components
	var visited: Dictionary = {}
	for tile in all_floor:
		var t: Vector2i = tile
		if t in visited or t in divider_tiles:
			continue
		var zone_tiles: Dictionary = {}
		var queue: Array[Vector2i] = [t]
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_front()
			if cur in visited or cur in divider_tiles or cur not in all_floor:
				continue
			visited[cur] = true
			zone_tiles[cur] = true
			for step in [Vector2i(cur.x - 1, cur.y), Vector2i(cur.x + 1, cur.y),
					   Vector2i(cur.x, cur.y - 1), Vector2i(cur.x, cur.y + 1)]:
				var nb := wrap_tile(step)   # through a seam, to the other side
				if nb not in visited and nb not in divider_tiles and nb in all_floor:
					queue.append(nb)

		# Gather functions from non-divider furniture whose footprint touches this zone
		var zone_fns: Array[String] = []
		var zone_fids: Array[String] = []
		for item in _get_all_placed_unique():
			var f := item as Furniture
			if f.divides_zone():
				continue
			for ft in _rect_tiles(f.grid_pos, f.grid_w, f.grid_h):
				if ft in zone_tiles:
					for fn in f.functions:
						if fn not in zone_fns:
							zone_fns.append(fn as String)
					if f.furniture_id not in zone_fids:
						zone_fids.append(f.furniture_id)
					break
		zones.append({"tiles": zone_tiles, "functions": zone_fns, "furniture_ids": zone_fids})
	grid_draw.queue_redraw()


# Whether this piece is actually on the floor's books (placed), as opposed to
# a purchase ghost that is only a child node so far.
func is_registered(furniture: Furniture) -> bool:
	for entry in _placed_continuous:
		if entry["furniture"] == furniture:
			return true
	return false


# Takes a piece off the floor's books without freeing it. Safe to call for a
# piece that was never placed.
func forget_furniture(furniture: Furniture) -> void:
	_remove_from_grid(furniture)


func _remove_from_grid(furniture: Furniture) -> void:
	for tile in _placed.keys():
		_placed_remove_tile(tile, furniture)
	for i in range(_placed_continuous.size() - 1, -1, -1):
		if _placed_continuous[i]["furniture"] == furniture:
			_placed_continuous.remove_at(i)
	if furniture.is_stair:
		_unregister_stair(furniture)


func find_free_spot(w: int, h: int) -> Vector2i:
	for y in range(grid_h - h + 1):
		for x in range(grid_w - w + 1):
			var clear := true
			for dy in range(h):
				for dx in range(w):
					if _placed_any_at(Vector2i(x + dx, y + dy)):
						clear = false
						break
				if not clear:
					break
			if clear:
				return Vector2i(x, y)
	return Vector2i.ZERO


func place_wall_item(edge: String, origin: Vector2i, fid: String) -> void:
	if not (edge in wall_items):
		wall_items[edge] = {}
	wall_items[edge][origin] = fid
	furniture_changed.emit()


func remove_wall_item(edge: String, origin: Vector2i) -> void:
	if edge in wall_items:
		wall_items[edge].erase(origin)
	furniture_changed.emit()


func set_wall_drag_ghost(edge: String, origin: Vector2i, fid: String) -> void:
	_wall_drag_ghost = {"edge": edge, "origin": origin, "fid": fid}
	furniture_changed.emit()


func clear_wall_drag_ghost() -> void:
	if _wall_drag_ghost.is_empty():
		return
	_wall_drag_ghost = {}
	furniture_changed.emit()


func set_floor_drag_ghost(furniture: Furniture, gx: float, gy: float) -> void:
	var moved: bool = _floor_drag_ghost.get("furniture") != furniture 		or _floor_drag_ghost.get("gx") != gx or _floor_drag_ghost.get("gy") != gy
	_floor_drag_ghost = {"furniture": furniture, "gx": gx, "gy": gy}
	if moved:
		_update_strain()   # only when it is over another tile: this runs on every mouse move
	furniture_changed.emit()


func clear_floor_drag_ghost() -> void:
	if _floor_drag_ghost.is_empty():
		return
	_floor_drag_ghost = {}
	_update_strain()
	furniture_changed.emit()


# ── Strain: how loaded a surface is ─────────────────────────────────────────
# Shown on the furniture itself rather than as a number: past STRAIN_FROM of
# what it holds a surface starts to show it (bowing in 3D, see Room3DView;
# its long edges pulled in on the plan, see Furniture._draw_strain), and a
# piece being carried over it counts as already there, so the player sees a
# table give before putting something too heavy on it.
const STRAIN_FROM := 0.6
const LOFT_HEADROOM := 14.0   # tiles under a loft's platform (see WallInspector: it sits at 1.4 m)

# Set by Main: told about the piece being carried (and its corner), or null
# when nothing is any more, so boxes can preview their shade and noise.
static var carry_preview: Callable

# What share of what `support` can hold rests on it. `carried` (being dragged
# or bought, its corner at `carried_at`) counts on the surface it is over and
# no longer on the one it was lifted off. Above 1 it would break.
func strain_of(support: Furniture, carried: Furniture = null, carried_at: Variant = null) -> float:
	if support.max_support_weight <= 0.0:
		return 0.0
	var load := _surface_load(support, carried)
	if carried != null and carried_at != null and support_under(carried, carried_at) == support:
		load += carried.weight
	return load / support.max_support_weight


# Where `carried` couldn't go, worked out once when it is picked up, so the
# plan and the 3D view can show it while it is carried instead of only
# saying so after a drop (the same rules as can_place()):
#   clearance:   [Rect2] other pieces' clearance zones, in tiles
#   bad_floor:   [Vector2i] tiles whose flooring it can't stand on
#   low_ceiling: [Vector2i] tiles where the sloped ceiling is too low for it
#   loft:        {} or {tiles: [Vector2i], load, max, weight}: the loft's load
var _hints_for: Furniture = null

func carry_hints(carried: Furniture) -> Dictionary:
	var out := {"clearance": [], "bad_floor": [], "low_ceiling": [], "loft": {},
		"doors": [] if carried.walkable else door_swings(), "moments": other_moment_zones(carried)}
	for f in get_all_furniture():
		var fur := f as Furniture
		if fur == carried or fur.ghost_radius <= 0:
			continue
		out["clearance"].append(Rect2(fur.grid_pos, Vector2(fur.grid_w, fur.grid_h)).grow(float(fur.ghost_radius)))
	var b := get_room_bounds()
	var check_floor := not carried.is_nested_box and (carried.floor_category != "any" or has_floor_kind("balcony"))
	var height_m := carried.body_h * 0.1
	for x in range(b.position.x, b.end.x):
		for y in range(b.position.y, b.end.y):
			var t := Vector2i(x, y)
			if not is_floor_tile(t):
				continue
			if check_floor and not _floor_category_ok(carried.floor_category, get_tile_kind(t)):
				out["bad_floor"].append(t)
			elif step_mask.has(t):
				out["bad_floor"].append(t)   # nothing stands on the steps
			if headroom_at(t) + 0.001 < height_m:
				out["low_ceiling"].append(t)
	if not carried.walkable and carried.body_h > LOFT_HEADROOM:
		for t in mezzanine_mask:
			out["low_ceiling"].append(t)   # too tall to go under the loft
	if not mezzanine_mask.is_empty() and mezzanine_max_load > 0.0:
		out["loft"] = {"tiles": mezzanine_mask.keys(), "load": _mezzanine_load(carried),
			"max": mezzanine_max_load, "weight": carried.weight}
	return out


# Hands every surface its current strain, counting the piece being dragged
# or bought on the plan (the drag ghost) where it is now.
func _update_strain() -> void:
	var carried: Furniture = null
	var at: Variant = null
	var ghost: Variant = _floor_drag_ghost.get("furniture")
	if is_instance_valid(ghost) and ((ghost as Furniture)._dragging or (ghost as Furniture)._placement_mode):
		carried = ghost as Furniture
		at = Vector2(_floor_drag_ghost["gx"] as float, _floor_drag_ghost["gy"] as float)
	for f in get_all_furniture():
		var fur := f as Furniture
		if fur.is_surface and fur != carried:
			fur.set_strain(strain_of(fur, carried, at))
	if Floor.carry_preview.is_valid():
		Floor.carry_preview.call(carried, at)
	if carried != _hints_for:
		_hints_for = carried
		if _rule_overlay == null and carried != null:
			_rule_overlay = RuleOverlay.new()
			_rule_overlay.z_index = 20
			add_child(_rule_overlay)
		if _rule_overlay != null:
			_rule_overlay.set_carry_hints(carry_hints(carried) if carried != null else {})


func get_wall_items(edge: String) -> Dictionary:
	if not (edge in wall_items):
		wall_items[edge] = {}
	return wall_items[edge]   # returns a live reference


func get_all_furniture_ids() -> Array:
	var ids: Array = []
	for f in _get_all_placed_unique():
		ids.append((f as Furniture).furniture_id)
	return ids


func get_all_wall_item_ids() -> Array:
	var ids: Array = []
	for edge in wall_items:
		var items: Dictionary = wall_items[edge]
		for origin in items:
			var fid: String = items[origin] as String
			if fid not in ids:
				ids.append(fid)
	return ids


func get_adjacent_furniture(edge: String, span: Vector2i = Vector2i(-1, -1)) -> Array:
	# Returns [{furniture, wall_x}] for pieces whose footprint touches this wall
	# edge. `wall_x` is LOCAL to the wall (0 at the wall's start), matching the
	# coordinate space WallInspector draws in.
	#
	# `span` (absolute tile coords, from get_wall_span) restricts results to
	# one sub-span of a multi-room floor's edge — e.g. a partition wall splits
	# the south perimeter edge into a bedroom half and a kitchen half; without
	# this, inspecting either half showed BOTH rooms' furniture mixed together,
	# since a piece's proximity to the wall's straight line was checked without
	# any awareness of which room it's actually in. Filtering by the piece's
	# own along-the-wall coordinate (not wall_x, which stays in the full
	# edge's coordinate space so existing wall-item storage is untouched)
	# keeps this a pure read-time filter, not a data-model change.
	var result: Array = []
	var bounds := get_room_bounds()
	var ghost_raw: Object = _floor_drag_ghost.get("furniture")
	var ghost_f: Furniture = (ghost_raw as Furniture) if is_instance_valid(ghost_raw) else null
	for item in _get_all_placed_unique():
		var f := item as Furniture
		var gx := f.grid_pos.x
		var gy := f.grid_pos.y
		if f == ghost_f:
			gx = _floor_drag_ghost["gx"] as float
			gy = _floor_drag_ghost["gy"] as float
		var adjacent := false
		var wall_x := 0.0
		var along := 0.0
		var along_w := 0.0
		match edge:
			"north":
				if gy < bounds.position.y + WALL_DEPTH:
					adjacent = true
					# -1: bounds.position.x is the west wall's own (blocked) tile,
					# so the first tile a floor piece can actually occupy is one
					# in from it. Without this offset, a piece truly flush
					# against the west wall reports wall_x = 1, not 0, and the
					# Wall Inspector draws it a tile short of that wall's face.
					wall_x = gx - bounds.position.x - 1
					along = gx; along_w = f.grid_w
			"south":
				if gy + f.grid_h > bounds.position.y + bounds.size.y - WALL_DEPTH:
					adjacent = true
					wall_x = gx - bounds.position.x - 1
					along = gx; along_w = f.grid_w
			"west":
				if gx < bounds.position.x + WALL_DEPTH:
					adjacent = true
					# Flipped vs. east: facing west, north is on your right, so
					# wall_x (left-to-right in the elevation view) runs south→north.
					# No -1 needed here: this formula already lands on 0 for a
					# south-flush piece and (bounds.size.y - 1 - f.grid_h) for a
					# north-flush one, matching the corrected range below.
					wall_x = bounds.size.y - (gy - bounds.position.y) - f.grid_h
					along = gy; along_w = f.grid_h
			"east":
				if gx + f.grid_w > bounds.position.x + bounds.size.x - WALL_DEPTH:
					adjacent = true
					wall_x = gy - bounds.position.y - 1
					along = gy; along_w = f.grid_h
		if adjacent and span.x >= 0 and (along + along_w <= span.x or along >= span.y):
			adjacent = false
		if adjacent:
			result.append({"furniture": f, "wall_x": wall_x})
	return result


func check_extended_conflict(furniture: Furniture) -> bool:
	if not furniture.foldable or furniture.extended_add_h <= 0:
		return false
	var start_y := floori(furniture.grid_pos.y) + furniture.grid_h
	var end_y   := start_y + furniture.extended_add_h
	for y in range(start_y, end_y):
		for x in range(furniture.grid_w):
			var tile := Vector2i(floori(furniture.grid_pos.x) + x, y)
			if tile.y >= grid_h or tile.x < 0 or tile.x >= grid_w:
				return true
			if _placed_overlapping_z(tile, furniture.z_bottom, furniture.z_top, furniture) != null:
				return true
	return false


func add_pipe_route(type: String, tiles: Array) -> void:
	# Remove existing route of same type first — one continuous route per type.
	pipe_routes = pipe_routes.filter(func(r): return r["type"] != type)
	pipe_routes.append({"type": type, "tiles": tiles})
	if grid_draw:
		grid_draw.queue_redraw()


func clear_pipe_route(type: String) -> void:
	pipe_routes = pipe_routes.filter(func(r): return r["type"] != type)
	if grid_draw:
		grid_draw.queue_redraw()


# Builder-tab erase hit-test: which route type (if any) passes near this
# point. Distance-to-polyline (not exact tile membership) since a freeform
# drawn path only records the tiles actually visited during the drag — a
# click between two recorded points would otherwise never register a hit.
func pipe_route_type_near(local_pos: Vector2, snap_tiles: float = 1.5) -> String:
	var snap := float(TILE_SIZE) * snap_tiles
	var best_d := snap
	var best_type := ""
	for route in pipe_routes:
		var tiles: Array = route["tiles"]
		for i in range(tiles.size() - 1):
			var pa := (Vector2(tiles[i] as Vector2i) + Vector2(0.5, 0.5)) * TILE_SIZE
			var pb := (Vector2(tiles[i + 1] as Vector2i) + Vector2(0.5, 0.5)) * TILE_SIZE
			var seg := pb - pa
			var seg_len := seg.length()
			if seg_len < 1.0:
				continue
			var t := clampf((local_pos - pa).dot(seg) / (seg_len * seg_len), 0.0, 1.0)
			var d := local_pos.distance_to(pa + seg * t)
			if d < best_d:
				best_d = d; best_type = route["type"] as String
	return best_type


func get_unconnected_needs(furniture_list: Array) -> Dictionary:
	# Returns {water:[fid,...], power:[fid,...]} for furniture not reached by routes
	var routed_water: Array = []
	var routed_power: Array = []
	for route in pipe_routes:
		for t in route["tiles"]:
			if route["type"] == "water":
				routed_water.append(t)
			else:
				routed_power.append(t)

	var placed_set := get_all_furniture()
	var missing := {"water": [], "power": []}
	for f in furniture_list:
		var fur := f as Furniture
		if fur not in placed_set:
			continue
		if fur.needs_water:
			var connected := false
			for t in routed_water:
				if Rect2i(Vector2i(floori(fur.grid_pos.x), floori(fur.grid_pos.y)), Vector2i(fur.grid_w, fur.grid_h)).has_point(t):
					connected = true
					break
			if not connected:
				missing["water"].append(fur.furniture_id)
		if fur.needs_power:
			var connected := false
			for t in routed_power:
				if Rect2i(Vector2i(floori(fur.grid_pos.x), floori(fur.grid_pos.y)), Vector2i(fur.grid_w, fur.grid_h)).has_point(t):
					connected = true
					break
			if not connected:
				missing["power"].append(fur.furniture_id)
	return missing


func _get_placed_tiles() -> Array:
	return _placed.keys()


func _get_tile_color(tile: Vector2i) -> Color:
	var fc := _placed_list(tile)
	if not fc.is_empty():
		return (fc[0] as Furniture)._color
	return Color.WHITE


func get_all_furniture() -> Array:
	return _get_all_placed_unique()


# Straight-line-of-sight test between two tiles, e.g. "can this bed see the
# sunrise through that window" or "can someone standing at the front door see
# into the bedroom" (the overprotective-parent case). Walks a Bresenham line
# tile-by-tile; a wall or a "tall" piece of furniture fully blocks the line
# (same height rule _compute_light_map() uses for light), "medium"/"low"
# furniture doesn't block a sightline (you can see over/around it even if it
# dims ambient light) — sightline blocking is specifically about eye-level
# obstruction, not the softer light-falloff model.
func has_sightline(from: Vector2i, to: Vector2i) -> bool:
	return sightline_block(from, to) == null


# The first tile that cuts the line of sight from `from` to `to` (a wall or a
# tall piece of furniture), or null when the line is clear.
func sightline_block(from: Vector2i, to: Vector2i) -> Variant:
	var blocked := _partition_tile_set()
	if loop == null:
		return _line_block(_line_tiles(from, to), blocked)
	# On a looped floor the eye can also see `to` the long way round, out
	# through a seam and back in: the line is clear if any way round is. The
	# block reported is the one on the direct line.
	var direct: Variant = null
	for img in loop.images_of(to):
		var hit: Variant = _line_block(_line_tiles(from, img), blocked)
		if hit == null:
			return null
		if img == to:
			direct = hit
	return direct


# The way round a looped floor that the eye sees `to` by, when it is not the
# straight line: [[a, b], ...] stretches in tiles, one per side of each seam
# it goes through. Empty when the straight line is clear, or nothing is.
func sightline_route(from: Vector2i, to: Vector2i) -> Array:
	if loop == null:
		return []
	var blocked := _partition_tile_set()
	if _line_block(_line_tiles(from, to), blocked) == null:
		return []
	for img in loop.images_of(to):
		if img == to:
			continue
		var line := _line_tiles(from, img)
		if _line_block(line, blocked) != null:
			continue
		var out: Array = []
		var start := Vector2(from)
		var prev := from
		var prev_shift := Vector2i.ZERO
		for raw in line:
			var shift := loop.wrap_tile(raw) - raw
			if shift != prev_shift:
				# Out through the seam: this stretch ends at the wall, the
				# next one starts at the opening opposite.
				var cross := (Vector2(prev) + Vector2(raw)) * 0.5
				out.append([start, cross + Vector2(prev_shift)])
				start = cross + Vector2(shift)
				prev_shift = shift
			prev = raw
		out.append([start, Vector2(to)])
		return out
	return []


# The tiles of a straight line from `a` to `b` (Bresenham), unwrapped.
func _line_tiles(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var x0 := a.x; var y0 := a.y
	var dx := absi(b.x - x0); var sx := 1 if x0 < b.x else -1
	var dy := -absi(b.y - y0); var sy := 1 if y0 < b.y else -1
	var err := dx + dy
	while true:
		out.append(Vector2i(x0, y0))
		if x0 == b.x and y0 == b.y:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy; x0 += sx
		if e2 <= dx:
			err += dx; y0 += sy
	return out


# The first tile of `line` (ends left out) that cuts it: a wall, a tall
# piece, or — round a loop — the outside, past a wall with no opening.
func _line_block(line: Array[Vector2i], blocked: Dictionary) -> Variant:
	for i in range(1, line.size() - 1):
		var tile := line[i]
		if loop != null:
			tile = loop.wrap_tile(tile)
			if not is_floor_tile(tile):
				return tile
		if tile in blocked:
			return tile
		for f in _placed_list(tile):
			if (f as Furniture).blocks_sight():
				return tile
	return null


# Shows the level's lines of sight on this floor's plan (see RuleOverlay).
var _rule_overlay: RuleOverlay = null

var zone_status: Array = []   # GameManager.zone_status(): one {conflict, label} per zone, or empty

func set_zone_status(status: Array) -> void:
	zone_status = status
	if grid_draw:
		grid_draw.queue_redraw()
	if _rule_overlay == null and not status.is_empty():
		_rule_overlay = RuleOverlay.new()
		_rule_overlay.z_index = 20
		add_child(_rule_overlay)
	if _rule_overlay != null:
		_rule_overlay.set_zones(zones, status)


# Yellow-tier pieces away from where they started (Main._show_moved_from_home()):
# their old spot, a line back to it and what it costs.
func set_home_marks(marks: Array) -> void:
	if _rule_overlay == null:
		if marks.is_empty():
			return
		_rule_overlay = RuleOverlay.new()
		_rule_overlay.z_index = 20
		add_child(_rule_overlay)
	_rule_overlay.set_home_marks(marks)


# The flat's outside walls that pass rules into boxes, and which wall each box
# takes them from (see Main._show_outside_walls()).
func set_outside_walls(walls: Array, links: Array) -> void:
	if _rule_overlay == null:
		if walls.is_empty():
			return
		_rule_overlay = RuleOverlay.new()
		_rule_overlay.z_index = 20
		add_child(_rule_overlay)
	_rule_overlay.set_outside(walls, links, get_room_bounds())


func set_sight_lines(status: Array) -> void:
	if _rule_overlay == null:
		if status.is_empty():
			return
		_rule_overlay = RuleOverlay.new()
		_rule_overlay.z_index = 20   # above furniture, including a piece being dragged
		add_child(_rule_overlay)
	_rule_overlay.set_lines(status)


# Total weight already resting on this floor's mezzanine tiles, excluding
# `exclude` itself (the piece being moved/re-checked shouldn't count against
# its own new placement).
func _mezzanine_load(exclude: Furniture = null) -> float:
	var counted: Dictionary = {}   # avoid double-counting a piece spanning multiple mezzanine tiles
	var total := 0.0
	for tile in mezzanine_mask:
		for f in _placed_list(tile):
			var fur := f as Furniture
			if fur == exclude or counted.has(fur):
				continue
			counted[fur] = true
			total += fur.weight
	return total


# Finds a furniture piece flagged is_surface whose footprint fully covers
# `tiles` (so a stacked item can't half-hang off the edge of its support), or
# null if none does — null means "bare floor", not "no support needed". When
# surfaces are themselves stacked (a nightstand on a kitchen island), the
# highest one is the one actually underneath.
#
# Two surfaces with the same footprint (two storage-wall modules of one size,
# stacked) could each be "on" the other. Where `exclude` is placed now
# (`as_placed`), it only rests on such a twin put down before it — without
# that, each one's height was the top of the other and the lookup never ended.
func _surface_support_at(tiles: Array, exclude: Furniture = null, as_placed := false) -> Furniture:
	if exclude != null and exclude.overhead:
		return null   # a skylight is up in the ceiling, never resting on a table
	var best: Furniture = null
	var best_top := -1.0
	var own_index := _placed_index(exclude) if as_placed and exclude != null else -1
	for f in get_all_furniture():
		var fur := f as Furniture
		if fur == exclude or not fur.is_surface:
			continue
		var covers_all := true
		for tile in tiles:
			if not _placed_list(tile).has(fur):
				covers_all = false
				break
		if covers_all and own_index >= 0 and _placed_index(fur) > own_index 				and Vector2i(fur.grid_w, fur.grid_h) == Vector2i(exclude.grid_w, exclude.grid_h):
			continue   # its twin, put down after it: that one is on top
		if covers_all:
			var top := stack_lift(fur) + fur.body_h
			if top > best_top:
				best = fur
				best_top = top
	return best


# The surface `f` rests on (at `at`, or where it is now), or null on bare floor.
func support_under(f: Furniture, at: Variant = null) -> Furniture:
	var pos: Vector2 = f.grid_pos if at == null else at as Vector2
	return _surface_support_at(_rect_tiles(pos, f.grid_w, f.grid_h), f, at == null and is_registered(f))


# Where `f` is in the order pieces were put down here, or -1.
func _placed_index(f: Furniture) -> int:
	for i in _placed_continuous.size():
		if _placed_continuous[i]["furniture"] == f:
			return i
	return -1


# How high above the floor `f` stands, in tiles (the same units as the
# catalogue's wall_h): the top of whatever it is stacked on, 0 on the floor.
func stack_lift(f: Furniture, at: Variant = null, _depth: int = 0) -> float:
	if _depth > 6:
		return 0.0   # a support loop can't happen physically; never recurse forever on bad data
	var sup := support_under(f, at)
	if sup == null:
		return 0.0
	return stack_lift(sup, null, _depth + 1) + sup.body_h


# Whether `f` rests on `support`, directly or on something that does.
func rests_on(f: Furniture, support: Furniture) -> bool:
	var cur := f
	for i in 6:
		cur = support_under(cur)
		if cur == null:
			return false
		if cur == support:
			return true
	return false


# Everything resting on `support`, directly or higher up the stack, lowest
# first (the order they have to be put back down in when it moves).
func riders_of(support: Furniture) -> Array:
	var out: Array = []
	if not support.is_surface or not is_registered(support):
		return out
	var seen: Dictionary = {}
	for tile in _rect_tiles(support.grid_pos, support.grid_w, support.grid_h):
		for f in _placed_list(tile):
			var fur := f as Furniture
			if fur == support or seen.has(fur):
				continue
			seen[fur] = true
			if rests_on(fur, support):
				out.append(fur)
	out.sort_custom(func(a, b): return stack_lift(a) < stack_lift(b))
	return out


# Moves `support` to `at` and carries everything on it along, keeping each
# piece where it was on the surface. All or nothing: if any rider can't go
# where it would land, everything stays where it was and false comes back
# (with that rider's block reason). A piece with nothing on it just moves.
func move_with_riders(support: Furniture, at: Vector2) -> bool:
	var riders := riders_of(support)
	if riders.is_empty():
		place_furniture(support, at)
		return true
	var delta := at - support.grid_pos
	var old_support_pos := support.grid_pos
	var old_pos: Dictionary = {}
	begin_batch()
	for r in riders:
		old_pos[r] = (r as Furniture).grid_pos
		_remove_from_grid(r as Furniture)
	place_furniture(support, at)
	var ok := true
	var reason := ""
	for r in riders:
		var rf := r as Furniture
		var dest: Vector2 = old_pos[rf] + delta
		if not can_place(rf, dest):
			ok = false
			reason = "%s: %s" % [rf.furniture_name, _block_reason]
			break
		place_furniture(rf, dest)
	if not ok:
		for r in riders:
			_remove_from_grid(r as Furniture)
		place_furniture(support, old_support_pos)
		for r in riders:
			place_furniture(r as Furniture, old_pos[r])
		_block_reason = reason
	elif Furniture.test_mode_active:
		for r in riders:
			(r as Furniture).record_moment_move(old_pos[r], Input.is_key_pressed(KEY_SHIFT))
	end_batch()
	return ok


# After `support` was turned a quarter (Furniture._rotate(): one rot_step,
# counter-clockwise on the plan) from `old_pos`, `old_w` tiles wide: turns
# `riders` (riders_of() taken before the turn) with it, each keeping its spot
# on the surface as the surface turns under it. Everything stays inside the
# turned footprint, so nothing is left hanging off the edge.
func turn_riders(support: Furniture, riders: Array, old_pos: Vector2, old_w: int) -> void:
	if riders.is_empty():
		return
	begin_batch()
	var offsets: Dictionary = {}
	for r in riders:
		offsets[r] = (r as Furniture).grid_pos - old_pos
		_remove_from_grid(r as Furniture)
	for r in riders:
		var rf := r as Furniture
		var off: Vector2 = offsets[rf]
		var rw := rf.grid_w
		rf.set_rot_steps(rf.rot_steps + 1)   # not registered right now, so this only turns it
		place_furniture(rf, support.grid_pos + Vector2(off.y, old_w - off.x - rw))
		rf.record_moment_move(old_pos + off)
	end_batch()


# Combined weight of everything already resting on `support` (any piece
# stacked there, not just requires_surface-flagged ones — see can_place()'s
# generalized stacking check, and whatever rests on those in turn), excluding
# `exclude`. What `support` itself stands on is not load on it.
func _surface_load(support: Furniture, exclude: Furniture = null) -> float:
	var counted: Dictionary = {}
	var total := 0.0
	for tile in _rect_tiles(support.grid_pos, support.grid_w, support.grid_h):
		for f in _placed_list(tile):
			var fur := f as Furniture
			if fur == support or fur == exclude or counted.has(fur):
				continue
			counted[fur] = true
			if rests_on(fur, support):
				total += fur.weight
	return total


# Draw order in the plan: a piece on a table is drawn over it (and over
# whatever that table stands on), whatever order they were put down in.
func _update_stack_order() -> void:
	for f in get_all_furniture():
		var fur := f as Furniture
		var depth := 0
		var cur := fur
		while depth < 6:
			cur = support_under(cur)
			if cur == null:
				break
			depth += 1
		fur.stack_z = depth
		if not fur._dragging:
			fur.z_index = depth


# Open floor tiles for a given moment — total walkable tiles minus whatever
# every piece of furniture occupies UNDER THAT MOMENT's own fold state (a
# sofa bed unfolded for Night blocks more floor than it does folded for Day).
func count_free_tiles_for_moment(moment_id: String) -> int:
	var floor_tiles_set: Dictionary
	if not floor_mask.is_empty():
		floor_tiles_set = floor_mask.duplicate()
	else:
		floor_tiles_set = {}
		var b := get_room_bounds()
		for x in range(b.position.x, b.position.x + b.size.x):
			for y in range(b.position.y, b.position.y + b.size.y):
				floor_tiles_set[Vector2i(x, y)] = true

	var blocked := _partition_tile_set()
	var occupied: Dictionary = {}
	for item in get_all_furniture():
		var f := item as Furniture
		if f.overhead:
			continue   # a skylight takes no floor
		for t in f.get_occupied_tiles_for_moment(moment_id):
			occupied[t] = true

	var free := 0
	for t in floor_tiles_set:
		if t in blocked:
			continue
		if not occupied.has(t):
			free += 1
	return free


# Same idea as count_free_tiles_for_moment, but only counts free tiles that
# also receive real daylight (light map > threshold) — used for space_needs
# like "ventilation"/"light" that specifically require open floor NEAR a
# window, as opposed to "sport" which just needs open floor anywhere.
func count_free_window_tiles_for_moment(moment_id: String, light_threshold: float = 0.15) -> int:
	var floor_tiles_set: Dictionary
	if not floor_mask.is_empty():
		floor_tiles_set = floor_mask.duplicate()
	else:
		floor_tiles_set = {}
		var b := get_room_bounds()
		for x in range(b.position.x, b.position.x + b.size.x):
			for y in range(b.position.y, b.position.y + b.size.y):
				floor_tiles_set[Vector2i(x, y)] = true

	var blocked := _partition_tile_set()
	var occupied: Dictionary = {}
	for item in get_all_furniture():
		var f := item as Furniture
		if f.overhead:
			continue   # a skylight takes no floor
		for t in f.get_occupied_tiles_for_moment(moment_id):
			occupied[t] = true

	var free := 0
	for t in floor_tiles_set:
		if t in blocked or occupied.has(t):
			continue
		if get_light(t) >= light_threshold:
			free += 1
	return free


# Straight-line tile distance from `tile` to the nearest wall/room boundary
# (an approximation of "how exposed is this spot to the street outside" —
# used for external-zone restrictions like noise/smell/bird setbacks, see
# GameManager.check_external_restrictions()). Cheap orthogonal-scan distance
# rather than a true geodesic BFS — good enough for "is this near an edge".
func min_distance_to_wall(tile: Vector2i) -> int:
	var blocked := _partition_tile_set()
	var best := 999
	for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var d := 0
		var t := tile
		# Round a loop a seam is not a wall: keep going through it, as far
		# as once round (a row with no wall at all is never near one).
		var cap := 999 if loop == null else grid_w + grid_h
		while is_floor_tile(t) and t not in blocked and d < cap:
			d += 1
			t = wrap_tile(t + dir)
		best = mini(best, d - 1)
	return maxi(best, 0)


func get_inaccessible_furniture() -> Array:
	if Floor.pathing_enabled:
		return get_unreachable_furniture()
	var result: Array = []
	for f in get_all_furniture():
		if (f as Furniture).overhead:
			continue   # nobody needs to reach a skylight
		if not _has_adjacent_free(_ground_piece(f)):
			result.append(f)
	return result


# What a piece is reached through: the furniture at the bottom of its stack
# (a lamp or a box on a table is as reachable as the table), itself if it
# stands on the floor.
func _ground_piece(f: Furniture) -> Furniture:
	var cur := f
	for i in 6:
		var sup := support_under(cur)
		if sup == null:
			break
		cur = sup
	return cur


# ── Pathing (experimental — only in force while Floor.pathing_enabled) ──────
# Can the tenant walk from the front door to every piece of furniture?
#
#   1. Walkable map: a person needs a WALK_WIDTH x WALK_WIDTH patch of clear
#      floor to stand on. Starting from the patches at the entrance door, the
#      flood fill moves one tile at a time through every such patch it can
#      reach. The floor under those patches is the "reached" floor.
#   2. Reachability: a piece is reachable when the side it is used from
#      (Furniture.front) has reached floor right next to it.
#
# With the flag on, get_inaccessible_furniture() answers with this instead of
# the older "one free tile beside it" rule, so the game's blocked-piece
# marker, the win condition and the level validator all follow it.
static var pathing_enabled := false

# Set by Main while the player is inside a box that stands on a table or
# shelf: how much (in this apartment's own, unshrunk weight) everything in it
# may add up to before that table outside would break, what weighs in here
# now, and the table's name. carry_limit < 0: no such limit.
static var carry_limit := -1.0
static var carried_weight: Callable
static var carry_support_name := ""
const WALK_WIDTH := 4            # tiles (40 cm): the narrowest gap a person fits through
const HEAD_HEIGHT := 18.0        # tiles: anything starting above this is walked under

var _path_signature := -1
var _path_reached: Dictionary = {}   # Vector2i -> true


# Whether a placed piece stands in the way of someone walking.
func blocks_walking(f: Furniture) -> bool:
	return not f.walkable and not f.requires_surface and f.z_bottom < HEAD_HEIGHT


# The floor tiles a person can stand on having walked in from the door.
# Cached until the layout changes.
func get_reachable_floor() -> Dictionary:
	var parts: Array = [segments.size(), columns.size(), floor_mask.size(), hash(floor_level), hash(step_mask)]
	for s in segments:
		parts.append((s as Dictionary).get("demolished", false))
		parts.append((s as Dictionary).get("door_pos", -1))
	for entry in _placed_continuous:
		var pf: Furniture = entry["furniture"]
		parts.append_array([pf.get_instance_id(), entry["pos"], pf.grid_w, pf.grid_h])
	var signature := hash(parts)
	if signature != _path_signature:
		_path_signature = signature
		_path_reached = _compute_reachable_floor()
	return _path_reached


func _compute_reachable_floor() -> Dictionary:
	# Work area: the room, plus any painted floor that sticks out of it
	# (balconies), plus a tile of margin.
	var b := get_room_bounds()
	var x0 := b.position.x; var y0 := b.position.y
	var x1 := b.position.x + b.size.x; var y1 := b.position.y + b.size.y
	for t in floor_mask:
		var tv := t as Vector2i
		x0 = mini(x0, tv.x); y0 = mini(y0, tv.y); x1 = maxi(x1, tv.x + 1); y1 = maxi(y1, tv.y + 1)
	x0 -= 1; y0 -= 1; x1 += 1; y1 += 1
	var w := x1 - x0
	var h := y1 - y0
	if w < WALK_WIDTH or h < WALK_WIDTH:
		return {}

	# 1 = something is in the way (no floor, a wall, a piece of furniture).
	var solid := PackedByteArray()
	solid.resize(w * h)
	var walls := _partition_tile_set()
	walls.merge(_window_tile_set())   # nobody walks through a window
	for y in h:
		for x in w:
			var t := Vector2i(x0 + x, y0 + y)
			solid[y * w + x] = 1 if (not is_floor_tile(t) or walls.has(t)) else 0
	for entry in _placed_continuous:
		var f: Furniture = entry["furniture"]
		if not blocks_walking(f):
			continue
		for t in _rect_tiles(entry["pos"], f.grid_w, f.grid_h):
			var lx := t.x - x0
			var ly := t.y - y0
			if lx >= 0 and ly >= 0 and lx < w and ly < h:
				solid[ly * w + lx] = 1

	# Summed-area table, so "is this whole patch clear" is four lookups.
	var sw := w + 1
	var sums := PackedInt32Array()
	sums.resize(sw * (h + 1))
	for y in h:
		var run := 0
		for x in w:
			run += solid[y * w + x]
			sums[(y + 1) * sw + x + 1] = sums[y * sw + x + 1] + run
	var aw := w - WALK_WIDTH + 1     # a patch is named by its top-left tile
	var ah := h - WALK_WIDTH + 1
	var clear := PackedByteArray()
	clear.resize(aw * ah)
	for y in ah:
		for x in aw:
			var total := sums[(y + WALK_WIDTH) * sw + x + WALK_WIDTH] - sums[y * sw + x + WALK_WIDTH] \
				- sums[(y + WALK_WIDTH) * sw + x] + sums[y * sw + x]
			clear[y * aw + x] = 1 if total == 0 else 0
	# Split levels: a patch straddling two levels is a ledge, not floor. Two
	# levels meet only through a band of steps at least WALK_WIDTH - 1 deep,
	# so one patch can stand half on each side of it.
	if not floor_level.is_empty():
		for y in ah:
			for x in aw:
				if clear[y * aw + x] == 1 and not patch_level_ok(Vector2i(x0 + x, y0 + y), WALK_WIDTH):
					clear[y * aw + x] = 0

	# Start at the entrance: every clear patch that touches a door in an
	# outer wall.
	var seeds: Array[int] = []
	for s in segments:
		var sd := s as Dictionary
		if sd.get("demolished", false) or not (sd.get("has_door", false) as bool):
			continue
		var sx1 := sd["x1"] as int; var sy1 := sd["y1"] as int
		var sx2 := sd["x2"] as int; var sy2 := sd["y2"] as int
		var outer := (sx1 == sx2 and (sx1 == b.position.x or sx1 == b.position.x + b.size.x)) \
			or (sy1 == sy2 and (sy1 == b.position.y or sy1 == b.position.y + b.size.y))
		if not outer:
			continue
		var dp := sd.get("door_pos", 0) as int
		for i in range(dp, dp + 10):   # 10 = door length, as in _partition_tile_set
			var door := Vector2i(sx1, mini(sy1, sy2) + i) if sx1 == sx2 else Vector2i(mini(sx1, sx2) + i, sy1)
			for ay in range(door.y - y0 - WALK_WIDTH, door.y - y0 + 2):
				for ax in range(door.x - x0 - WALK_WIDTH, door.x - x0 + 2):
					if ax >= 0 and ay >= 0 and ax < aw and ay < ah and clear[ay * aw + ax] == 1:
						seeds.append(ay * aw + ax)

	# Looped floor: a patch against one opening of a seam steps through to
	# the patch against the other.
	var links: Dictionary = {}
	if loop != null:
		var by_tile := loop.patch_links(WALK_WIDTH)
		for a in by_tile:
			var av := a as Vector2i - Vector2i(x0, y0)
			if av.x < 0 or av.y < 0 or av.x >= aw or av.y >= ah:
				continue
			var to: Array[int] = []
			for other in by_tile[a] as Array:
				var bv := other as Vector2i - Vector2i(x0, y0)
				if bv.x >= 0 and bv.y >= 0 and bv.x < aw and bv.y < ah:
					to.append(bv.y * aw + bv.x)
			links[av.y * aw + av.x] = to

	var seen := PackedByteArray()
	seen.resize(aw * ah)
	var reached_patches: Array[int] = []
	if not seeds.is_empty():
		reached_patches = _flood_patches(seeds, clear, seen, aw, ah, links)
	else:
		# No entrance on this floor (an upper storey, a box interior, a test
		# room): take the largest connected stretch of walkable floor.
		for i in aw * ah:
			if clear[i] == 1 and seen[i] == 0:
				var comp := _flood_patches([i] as Array[int], clear, seen, aw, ah, links)
				if comp.size() > reached_patches.size():
					reached_patches = comp

	var reached: Dictionary = {}
	for i in reached_patches:
		var px := x0 + i % aw
		var py := y0 + i / aw
		for dy in WALK_WIDTH:
			for dx in WALK_WIDTH:
				reached[Vector2i(px + dx, py + dy)] = true
	return reached


func _flood_patches(seeds: Array[int], clear: PackedByteArray, seen: PackedByteArray, aw: int, ah: int,
		links: Dictionary = {}) -> Array[int]:
	var out: Array[int] = []
	var queue: Array[int] = []
	for s in seeds:
		if seen[s] == 0:
			seen[s] = 1
			queue.append(s)
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		out.append(i)
		var x := i % aw
		var y := i / aw
		if x > 0 and clear[i - 1] == 1 and seen[i - 1] == 0:
			seen[i - 1] = 1; queue.append(i - 1)
		if x < aw - 1 and clear[i + 1] == 1 and seen[i + 1] == 0:
			seen[i + 1] = 1; queue.append(i + 1)
		if y > 0 and clear[i - aw] == 1 and seen[i - aw] == 0:
			seen[i - aw] = 1; queue.append(i - aw)
		if y < ah - 1 and clear[i + aw] == 1 and seen[i + aw] == 0:
			seen[i + aw] = 1; queue.append(i + aw)
		var linked: Array = links.get(i, [])
		for j in linked:
			if clear[j] == 1 and seen[j] == 0:
				seen[j] = 1; queue.append(j)
	return out


# The sides a piece is used from, as indices 0 north (top of the plan),
# 1 east, 2 south, 3 west — for the way it is turned right now.
# ── Against a wall ───────────────────────────────────────────────────────────
# Pieces that stand against a wall in any real flat (wardrobes, kitchens,
# toilets, a fridge: wall_flush_required) have to have their back to one:
# the side opposite the one they are used from (front), or for a piece used
# from any side, any side. Every wall counts, inside walls too, window or
# not; a doorway doesn't. Half the back touching is enough.

var _contact_key := 0
var _contact_tiles: Dictionary = {}

func _wall_contact_tiles() -> Dictionary:
	var key := segments.hash() if _use_new_format else partitions.hash()
	if key == _contact_key and not _contact_tiles.is_empty():
		return _contact_tiles
	var out: Dictionary = {}
	for p in (segments if _use_new_format else partitions):
		if p.get("demolished", false):
			continue
		var x1: int = p["x1"]; var y1: int = p["y1"]
		var x2: int = p["x2"]; var y2: int = p["y2"]
		var has_door := p.get("has_door", false) as bool
		var dp := p.get("door_pos", -1) as int
		var vertical := x1 == x2
		var lo := mini(y1, y2) if vertical else mini(x1, x2)
		var hi := maxi(y1, y2) if vertical else maxi(x1, x2)
		for c in range(lo, hi + 1):
			if has_door and dp >= 0 and c - lo >= dp and c - lo < dp + 10:
				continue
			out[Vector2i(x1, c) if vertical else Vector2i(c, y1)] = true
	_contact_key = key
	_contact_tiles = out
	return out


# Mounted on a rail: given its own run along one (rail_start..rail_end, as
# a level authors it) or standing over one of the floor's rail tracks. Most
# storage can be put on a rail (rail_axis comes with it), which alone
# doesn't count.
func on_a_rail(f: Furniture, at: Vector2) -> bool:
	if f.rail_axis == "":
		return false
	if f.rail_start >= 0:
		return true
	return not rails.is_empty() and find_rail_near((at + Vector2(f.grid_w, f.grid_h) * 0.5) * TILE_SIZE, maxf(f.grid_w, f.grid_h) * 0.5) >= 0


func backs_onto_wall(f: Furniture, at: Vector2) -> bool:
	var walls := _wall_contact_tiles()
	var x0 := roundi(at.x)
	var y0 := roundi(at.y)
	for front in _front_sides(f):
		var side := (front + 2) % 4 if f.front != "any" else front
		# Flush, or up to WALL_SNAP away (the gap snapping already allows).
		for gap in range(int(WALL_SNAP) + 1):
			var row: Array[Vector2i] = []
			match side:
				0: for x in range(x0, x0 + f.grid_w): row.append(Vector2i(x, y0 - 1 - gap))
				2: for x in range(x0, x0 + f.grid_w): row.append(Vector2i(x, y0 + f.grid_h + gap))
				1: for y in range(y0, y0 + f.grid_h): row.append(Vector2i(x0 + f.grid_w + gap, y))
				3: for y in range(y0, y0 + f.grid_h): row.append(Vector2i(x0 - 1 - gap, y))
			var touching := 0
			for t in row:
				if walls.has(wrap_tile(t)):
					touching += 1
			if touching * 2 >= row.size():
				return true
	return false


# ── Quiet routes ─────────────────────────────────────────────────────────────
# From every bed (a piece giving `from_function`) to a piece in `to` there
# has to be a way a person can walk that never comes within `radius` tiles
# of the `avoid` piece (birds asleep in their cage). Walked as the tenants
# walk: a WALK_WIDTH square over floor reachable from the door.
# {ok, path: [Vector2 tile centres], zone: [Rect2] the quiet areas, radius}:
# path is the way taken when there is one, else the plain shortest way, so
# the plan can show where it would wake them.
func quiet_route(q: Dictionary) -> Dictionary:
	var avoid_id := q.get("avoid", "") as String
	var radius := float(q.get("radius", 10))
	var from_fn := q.get("from_function", "sleep") as String
	var to_ids := q.get("to", []) as Array
	var zones: Array = []
	var sources: Array = []
	var targets: Array = []
	for item in get_all_furniture():
		var f := item as Furniture
		if f.furniture_id == avoid_id:
			zones.append(Rect2(f.grid_pos, Vector2(f.grid_w, f.grid_h)))
		elif f.furniture_id in to_ids:
			targets.append(f)
		elif from_fn in f.functions:
			sources.append(f)
	var out := {"ok": true, "path": [], "zone": zones, "radius": radius}
	if zones.is_empty() or sources.is_empty() or targets.is_empty():
		return out

	var b := get_room_bounds()
	var w := b.size.x
	var h := b.size.y
	var n := WALK_WIDTH
	# Where a person can stand: walked in from the door when the walking
	# rule is on; otherwise any floor clear of walls and furniture in the way
	# (as the tenants walk then), or a flat whose rooms the strict rule
	# doesn't reach (the beach house's bathroom) could never pass.
	var reached := get_reachable_floor() if Floor.pathing_enabled else {}
	var walls := {}
	var in_way := {}
	if not Floor.pathing_enabled:
		walls = _partition_tile_set()
		walls.merge(_window_tile_set())
		for entry in _placed_continuous:
			var pf: Furniture = entry["furniture"]
			if blocks_walking(pf):
				for t in _rect_tiles(entry["pos"], pf.grid_w, pf.grid_h):
					in_way[t] = true
	# Patches (n x n squares, by their top-left tile) a person can stand on.
	var sums := PackedInt32Array()
	sums.resize((w + 1) * (h + 1))
	for y in h:
		for x in w:
			var t := Vector2i(b.position.x + x, b.position.y + y)
			var ok_t := reached.has(t) if Floor.pathing_enabled 				else (is_floor_tile(t) and not walls.has(t) and not in_way.has(t))
			sums[(y + 1) * (w + 1) + x + 1] = (1 if ok_t else 0) + sums[y * (w + 1) + x + 1] 				+ sums[(y + 1) * (w + 1) + x] - sums[y * (w + 1) + x]
	var open := PackedByteArray()    # 1 = a person fits here
	var quiet := PackedByteArray()   # 1 = ...and it is far enough from every zone
	open.resize(w * h)
	quiet.resize(w * h)
	for y in h:
		for x in w:
			if x + n > w or y + n > h:
				continue
			var cnt := sums[(y + n) * (w + 1) + x + n] - sums[y * (w + 1) + x + n] - sums[(y + n) * (w + 1) + x] + sums[y * (w + 1) + x]
			if cnt != n * n:
				continue
			open[y * w + x] = 1
			var patch := Rect2(Vector2(b.position.x + x, b.position.y + y), Vector2(n, n))
			var far := true
			for z in zones:
				if _rect_gap(patch, z as Rect2) < radius:
					far = false
					break
			quiet[y * w + x] = 1 if far else 0

	var patches_beside := func(f: Furniture) -> Array:
		var res: Array = []
		var x0 := floori(f.grid_pos.x) - b.position.x
		var y0 := floori(f.grid_pos.y) - b.position.y
		for side in _front_sides(f):
			match side:
				0: for x in range(x0 - n + 1, x0 + f.grid_w): res.append(Vector2i(x, y0 - n))
				2: for x in range(x0 - n + 1, x0 + f.grid_w): res.append(Vector2i(x, y0 + f.grid_h))
				1: for y in range(y0 - n + 1, y0 + f.grid_h): res.append(Vector2i(x0 + f.grid_w, y))
				3: for y in range(y0 - n + 1, y0 + f.grid_h): res.append(Vector2i(x0 - n, y))
		return res.filter(func(p: Vector2i) -> bool: return p.x >= 0 and p.y >= 0 and p.x < w and p.y < h)

	# Walk out from every toilet-side patch at once; a bed is fine if a patch
	# beside it is reached. Done on the quiet patches, then (for the picture,
	# when that fails) on all of them.
	var walk := func(grid: PackedByteArray) -> Dictionary:
		var came := {}
		var queue: Array[Vector2i] = []
		for t in targets:
			for p in patches_beside.call(t):
				if grid[p.y * w + p.x] == 1 and not came.has(p):
					came[p] = p
					queue.append(p)
		var head := 0
		while head < queue.size():
			var c: Vector2i = queue[head]
			head += 1
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nb: Vector2i = c + d
				if nb.x < 0 or nb.y < 0 or nb.x >= w or nb.y >= h or came.has(nb) or grid[nb.y * w + nb.x] != 1:
					continue
				came[nb] = c
				queue.append(nb)
		return came
	var to_path := func(came: Dictionary, from: Vector2i) -> Array:
		var pts: Array = []
		var c := from
		while true:
			pts.append(Vector2(b.position) + Vector2(c) + Vector2(n, n) * 0.5)
			var nxt: Vector2i = came[c]
			if nxt == c:
				break
			c = nxt
		return pts
	var quiet_came: Dictionary = walk.call(quiet)
	var open_came: Dictionary = {}
	for bed in sources:
		var start := Vector2i(-1, -1)
		for p in patches_beside.call(bed):
			if quiet_came.has(p):
				start = p
				break
		if start.x >= 0:
			if (out["path"] as Array).is_empty():
				out["path"] = to_path.call(quiet_came, start)
			continue
		# No quiet way from this bed: show the way it would take.
		out["ok"] = false
		if open_came.is_empty():
			open_came = walk.call(open)
		for p in patches_beside.call(bed):
			if open_came.has(p):
				out["path"] = to_path.call(open_came, p)
				break
		break
	return out


# The gap between two rectangles, in tiles (0 when they touch or overlap).
static func _rect_gap(a: Rect2, c: Rect2) -> float:
	var dx := maxf(0.0, maxf(a.position.x - c.end.x, c.position.x - a.end.x))
	var dy := maxf(0.0, maxf(a.position.y - c.end.y, c.position.y - a.end.y))
	return sqrt(dx * dx + dy * dy)


func _front_sides(f: Furniture) -> Array[int]:
	match f.front:
		"long":
			if f.grid_w > f.grid_h: return [0, 2]
			if f.grid_h > f.grid_w: return [1, 3]
		"short":
			if f.grid_w > f.grid_h: return [1, 3]
			if f.grid_h > f.grid_w: return [0, 2]
		"n", "e", "s", "w":
			# Authored for the piece as it stands unrotated; each quarter
			# turn moves it one side clockwise.
			return [(["n", "e", "s", "w"].find(f.front) + f.rot_steps) % 4]
	return [0, 1, 2, 3]


# True when the tenant can walk up to the side this piece is used from.
func is_reachable(f: Furniture) -> bool:
	var ground := _ground_piece(f)
	if ground != f:
		return is_reachable(ground)
	if not blocks_walking(f) or f.is_stair:
		return true
	var reached := get_reachable_floor()
	var fx := floori(f.grid_pos.x)
	var fy := floori(f.grid_pos.y)
	# On split levels the tenant has to stand on the piece's own level (or
	# its steps): a bed on a platform isn't used from the floor below it.
	var lvl := level_under(f.grid_pos, f.grid_w, f.grid_h)
	var ok := func(t: Vector2i) -> bool:
		return reached.has(t) and (floor_level.is_empty() or step_mask.has(t) or level_at(t) == lvl)
	for side in _front_sides(f):
		match side:
			0:
				for x in range(fx, fx + f.grid_w):
					if ok.call(wrap_tile(Vector2i(x, fy - 1))): return true
			2:
				for x in range(fx, fx + f.grid_w):
					if ok.call(wrap_tile(Vector2i(x, fy + f.grid_h))): return true
			1:
				for y in range(fy, fy + f.grid_h):
					if ok.call(wrap_tile(Vector2i(fx + f.grid_w, y))): return true
			3:
				for y in range(fy, fy + f.grid_h):
					if ok.call(wrap_tile(Vector2i(fx - 1, y))): return true
	return false


func get_unreachable_furniture() -> Array:
	var result: Array = []
	for f in get_all_furniture():
		if not is_reachable(f as Furniture):
			result.append(f)
	return result


func _has_adjacent_free(f: Furniture) -> bool:
	var x0 := floori(f.grid_pos.x)
	var y0 := floori(f.grid_pos.y)
	var x1 := x0 + f.grid_w
	var y1 := y0 + f.grid_h
	if loop != null:
		# Round a loop the free tile can be across a seam.
		var b := get_room_bounds()
		var walls := _partition_tile_set()
		var around: Array[Vector2i] = []
		for x in range(x0, x1):
			around.append_array([Vector2i(x, y0 - 1), Vector2i(x, y1)])
		for y in range(y0, y1):
			around.append_array([Vector2i(x0 - 1, y), Vector2i(x1, y)])
		for t in around:
			var w := loop.wrap_tile(t)
			if is_floor_tile(w) and not walls.has(w) and b.has_point(w) and not _placed_any_at(w):
				return true
		return false
	for x in range(x0, x1):
		if y0 > 0 and not _placed_any_at(Vector2i(x, y0 - 1)):
			return true
		if y1 < grid_h and not _placed_any_at(Vector2i(x, y1)):
			return true
	for y in range(y0, y1):
		if x0 > 0 and not _placed_any_at(Vector2i(x0 - 1, y)):
			return true
		if x1 < grid_w and not _placed_any_at(Vector2i(x1, y)):
			return true
	return false
