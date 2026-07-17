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
var sloped_ceiling: Dictionary = {}   # {axis, low_start, high_end, min_h, max_h}
var connection_points: Dictionary = {}  # {water:[{x,y}], power:[{x,y}]}
var pipe_routes: Array = []     # [{type:"water"|"power", tiles:[Vector2i]}]  player-drawn
var duct_routes: Array = []     # reserved for HVAC (ceiling layer)

var floor_mask:     Dictionary = {}   # Vector2i -> true; empty = whole grid is floor
var floor_kind:     Dictionary = {}   # Vector2i -> String ("balcony"|"bathroom"); absent = "normal"
var mezzanine_mask: Dictionary = {}   # Vector2i -> true; mezzanine/loft tiles
var stair_mask:     Dictionary = {}   # Vector2i -> true; stair tiles
var shadow_mask:    Dictionary = {}   # Vector2i -> true; parent floor ghost (LevelEditor loft view only)
var below_floor:    Floor      = null # the "floor"-type floor stacked directly below this one, if any (gameplay 2D/3D ghost-below reference — see Main.gd's _floor_below_id)
var rails:          Array      = []   # [{x1,y1,x2,y2}] sliding rail tracks
var reveal_zones:   Array      = []   # [{x1,y1,x2,y2}] sub-range of a rail where a piece counts as "revealed"
var segments:       Array      = []   # new-format walls: [{x1,y1,x2,y2,primary,demolished,...}]
var stairs_data:    Array      = []   # [{rect:Rect2i, direction:String}] one entry per placed stair
var stair_openings: Array      = []   # same format, but stair footprints from parent floor (for loft rendering)
var _use_new_format: bool      = false

var _block_reason: String = ""    # why the most recent can_place() call returned false, for UI feedback
var _placed: Dictionary = {}      # Vector2i -> Array[Furniture]  (multi-Z) — rasterized cache,
								   # derived from the continuous positions below, used by
								   # lighting/zones/needs/adjacency (all inherently tile-discrete).
var _placed_continuous: Array = []  # [{furniture:Furniture, pos:Vector2}] — precise overlap source of truth
var floor_z_offset: int = 0       # global Z of this floor's floor level (tiles)
var zones: Array = []             # [{tiles:Dictionary, functions:Array[String]}] — recalculated on furniture change
var wall_items: Dictionary = {}   # "north" -> { Vector2i origin -> fid }
var _light_map: Dictionary = {}   # Vector2i -> float  (0.0 dark … 1.0 full sunlight)

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

func _placed_any_at(tile: Vector2i) -> bool:
	return not _placed_list(tile).is_empty()

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
	return tiles


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

func get_tile_kind(tile: Vector2i) -> String:
	return floor_kind.get(tile, "normal") as String


# Balcony tiles only accept balcony-category furniture (and vice versa —
# balcony furniture only belongs on a balcony). Bathroom tiles accept
# anything, but bathroom-category furniture is confined to bathroom tiles.
func _floor_category_ok(furn_category: String, tile_kind: String) -> bool:
	if tile_kind == "balcony":
		return furn_category == "balcony"
	if furn_category == "balcony":
		return false
	if furn_category == "bathroom" and tile_kind != "bathroom":
		return false
	return true


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
func get_room_bounds() -> Rect2i:
	if not segments.is_empty():
		var minx := INF; var miny := INF; var maxx := -INF; var maxy := -INF
		for s in segments:
			var sd := s as Dictionary
			minx = min(minx, min(sd["x1"] as int, sd["x2"] as int))
			maxx = max(maxx, max(sd["x1"] as int, sd["x2"] as int))
			miny = min(miny, min(sd["y1"] as int, sd["y2"] as int))
			maxy = max(maxy, max(sd["y1"] as int, sd["y2"] as int))
		return Rect2i(int(minx), int(miny), int(maxx - minx), int(maxy - miny))
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


func _compute_light_map() -> void:
	_light_map.clear()
	var blocked := _partition_tile_set()
	var queue: Array[Vector2i] = []

	if _use_new_format:
		# Seed from windows on segments
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
				for side in [-1, 0]:
					var tile: Vector2i
					if is_horiz:
						tile = Vector2i(mn_x + wp + i, y1 + side)
					else:
						tile = Vector2i(x1 + side, mn_y + wp + i)
					if is_floor_tile(tile) and tile not in _light_map:
						_light_map[tile] = 1.0
						queue.append(tile)
	else:
		# Seed every window tile at full intensity (old format)
		for wd in wall_definitions:
			if not wd.get("has_window", false):
				continue
			var edge: String = wd["edge"]
			var wx: int = wd.get("window_x", 0)
			var wl: int = wd.get("window_len", 0)
			for i in range(wl):
				var tile: Vector2i
				match edge:
					"north": tile = Vector2i(wx + i, 0)
					"south": tile = Vector2i(wx + i, grid_h - 1)
					"west":  tile = Vector2i(0, wx + i)
					"east":  tile = Vector2i(grid_w - 1, wx + i)
				if not (tile in _light_map):
					_light_map[tile] = 1.0
					queue.append(tile)

	# BFS — propagate maximum intensity, skip already-higher tiles
	var head := 0
	while head < queue.size():
		var tile: Vector2i = queue[head]
		head += 1
		var intensity: float = _light_map[tile]
		if intensity < 0.04:
			continue
		for dir: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next: Vector2i = tile + dir
			if not is_floor_tile(next):
				continue
			if next in blocked:
				continue
			var decay := 0.05
			var _lm := _placed_list(next)
			if not _lm.is_empty():
				var f := _lm[0] as Furniture
				match f.height_category:
					"tall":   continue
					"medium": decay += 0.28
					"low":    decay += 0.05
			var next_i: float = intensity - decay
			if next_i <= 0.0:
				continue
			if next_i <= (_light_map.get(next, 0.0) as float):
				continue
			_light_map[next] = next_i
			queue.append(next)


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
	sloped_ceiling    = floor_data.get("sloped_ceiling", {})
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
	else:
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


func _partition_tile_set() -> Dictionary:
	var blocked: Dictionary = {}

	var source: Array = segments if _use_new_format else partitions
	for p in source:
		if p.get("demolished", false):
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


func add_segment(x1: int, y1: int, x2: int, y2: int) -> void:
	segments.append({"x1": x1, "y1": y1, "x2": x2, "y2": y2, "primary": false, "demolished": false})
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


func can_place(furniture: Furniture, at: Vector2) -> bool:
	_block_reason = ""
	var blocked := _partition_tile_set()
	for tile in _rect_tiles(at, furniture.grid_w, furniture.grid_h):
		if not is_floor_tile(tile):
			_block_reason = "Outside the room"
			return false
		if not _floor_category_ok(furniture.floor_category, get_tile_kind(tile)):
			_block_reason = "Needs %s flooring" % furniture.floor_category
			return false
		if tile in blocked:
			_block_reason = "Blocked by a wall"
			return false

	# Furniture-vs-furniture overlap: precise continuous rects + Z-range test,
	# not tile-quantized — two pieces can sit flush at a fractional boundary
	# without a false collision from tile rounding.
	var new_rect := Rect2(at, Vector2(furniture.grid_w, furniture.grid_h))
	for entry in _placed_continuous:
		var f: Furniture = entry["furniture"]
		if f == furniture:
			continue
		if furniture.z_top <= f.z_bottom or furniture.z_bottom >= f.z_top:
			continue   # different Z layers (e.g. loft above, ground below) never collide
		var other_rect := Rect2(entry["pos"] as Vector2, Vector2(f.grid_w, f.grid_h))
		if new_rect.intersects(other_rect):
			_block_reason = "Overlaps " + f.furniture_name
			return false

	# Sloped ceiling: any furniture taller than the local ceiling height is blocked
	if not sloped_ceiling.is_empty():
		var sc       := sloped_ceiling
		var axis     := sc.get("axis", "x") as String
		var low_s    := sc.get("low_start", 0) as int
		var high_e   := sc.get("high_end",  0) as int
		var min_h    := sc.get("min_h", 1.8) as float
		var max_h    := sc.get("max_h", 2.4) as float
		var span     := float(high_e - low_s)
		var furn_h_m := furniture.z_top / 10.0   # 10 tiles per meter (see FLOOR_HEIGHT_TILES)
		if span > 0:
			for tile in _rect_tiles(at, furniture.grid_w, furniture.grid_h):
				var coord := tile.x if axis == "x" else tile.y
				# Outside the slope's own [low_start, high_end] run — e.g. a
				# separate room on a multi-room floor that just happens to
				# share this floor's sloped_ceiling record — isn't part of
				# the raked ceiling at all, so it must read as full height,
				# not get clamped to the slope's lowest point.
				var ceil_h := max_h
				if coord >= low_s and coord <= high_e:
					var frac := (coord - low_s) / span
					ceil_h = min_h + frac * (max_h - min_h)
				if ceil_h < furn_h_m:
					_block_reason = "Ceiling too low here"
					return false

	# Ghost zone: can't place inside another furniture's interaction clearance
	for entry in _placed_continuous:
		var f: Furniture = entry["furniture"]
		if f == furniture or f.ghost_radius <= 0:
			continue
		var fpos: Vector2 = entry["pos"]
		var ghost := Rect2(
			fpos - Vector2(f.ghost_radius, f.ghost_radius),
			Vector2(f.grid_w + f.ghost_radius * 2, f.grid_h + f.ghost_radius * 2)
		)
		if ghost.intersects(new_rect):
			_block_reason = "Needs clearance around " + f.furniture_name
			return false

	return true


# The reason the most recent can_place() call returned false ("" if it
# returned true, or if nothing has called it yet) — read right after
# can_place() by whatever's showing the player feedback.
func get_block_reason() -> String:
	return _block_reason


func place_furniture(furniture: Furniture, at: Vector2) -> void:
	_remove_from_grid(furniture)
	for tile in _rect_tiles(at, furniture.grid_w, furniture.grid_h):
		_placed_add(tile, furniture)
	_placed_continuous.append({"furniture": furniture, "pos": at})
	furniture.grid_pos = at
	furniture.position = at * TILE_SIZE
	# Stair furniture: register block in stairs_data + populate stair_mask
	if furniture.is_stair:
		_register_stair(furniture, Vector2i(floori(at.x), floori(at.y)))
	_compute_light_map()
	_recalculate_zones()
	furniture_changed.emit()


func remove_furniture(furniture: Furniture) -> void:
	_remove_from_grid(furniture)
	if _floor_drag_ghost.get("furniture") == furniture:
		clear_floor_drag_ghost()
	furniture.queue_free()
	_compute_light_map()
	_recalculate_zones()
	furniture_changed.emit()


func _recalculate_zones() -> void:
	zones = []
	if not _use_new_format:
		return

	# All walkable floor tiles (floor_mask empty = whole grid)
	var all_floor: Dictionary = {}
	if floor_mask.is_empty():
		for x in range(grid_w):
			for y in range(grid_h):
				all_floor[Vector2i(x, y)] = true
	else:
		all_floor = floor_mask

	# Tiles occupied by zone-divider furniture are walls for zone purposes
	var divider_tiles: Dictionary = {}
	for item in _get_all_placed_unique():
		var f := item as Furniture
		if not f.zone_divider:
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
			for nb in [Vector2i(cur.x - 1, cur.y), Vector2i(cur.x + 1, cur.y),
					   Vector2i(cur.x, cur.y - 1), Vector2i(cur.x, cur.y + 1)]:
				if nb not in visited and nb not in divider_tiles and nb in all_floor:
					queue.append(nb)

		# Gather functions from non-divider furniture whose footprint touches this zone
		var zone_fns: Array[String] = []
		var zone_fids: Array[String] = []
		for item in _get_all_placed_unique():
			var f := item as Furniture
			if f.zone_divider:
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
	_floor_drag_ghost = {"furniture": furniture, "gx": gx, "gy": gy}
	furniture_changed.emit()


func clear_floor_drag_ghost() -> void:
	if _floor_drag_ghost.is_empty():
		return
	_floor_drag_ghost = {}
	furniture_changed.emit()


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
		for t in f.get_occupied_tiles_for_moment(moment_id):
			occupied[t] = true

	var free := 0
	for t in floor_tiles_set:
		if t in blocked:
			continue
		if not occupied.has(t):
			free += 1
	return free


func get_inaccessible_furniture() -> Array:
	var result: Array = []
	for f in get_all_furniture():
		if not _has_adjacent_free(f):
			result.append(f)
	return result


func _has_adjacent_free(f: Furniture) -> bool:
	var x0 := floori(f.grid_pos.x)
	var y0 := floori(f.grid_pos.y)
	var x1 := x0 + f.grid_w
	var y1 := y0 + f.grid_h
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
