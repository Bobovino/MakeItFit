extends Node2D
class_name Floor

signal furniture_changed
signal wall_edge_clicked(edge: String)

const TILE_SIZE := 8
const EDGE_MARGIN := 10
const WALL_DEPTH := 8  # tiles within this distance count as "against the wall"
const FLOOR_HEIGHT_TILES := 28  # nominal room height in tiles (≈2.8 m at 10 cm/tile)

var floor_id: String = ""
var floor_label: String = ""
var floor_type: String = "floor"
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
var mezzanine_mask: Dictionary = {}   # Vector2i -> true; mezzanine/loft tiles
var stair_mask:     Dictionary = {}   # Vector2i -> true; stair tiles
var shadow_mask:    Dictionary = {}   # Vector2i -> true; parent floor ghost (loft view only)
var rails:          Array      = []   # [{x1,y1,x2,y2}] sliding rail tracks
var reveal_zones:   Array      = []   # [{x1,y1,x2,y2}] sub-range of a rail where a piece counts as "revealed"
var segments:       Array      = []   # new-format walls: [{x1,y1,x2,y2,primary,demolished,...}]
var stairs_data:    Array      = []   # [{rect:Rect2i, direction:String}] one entry per placed stair
var stair_openings: Array      = []   # same format, but stair footprints from parent floor (for loft rendering)
var _use_new_format: bool      = false

var _placed: Dictionary = {}      # Vector2i -> Array[Furniture]  (multi-Z)
var floor_z_offset: int = 0       # global Z of this floor's floor level (tiles)
var zones: Array = []             # [{tiles:Dictionary, functions:Array[String]}] — recalculated on furniture change
var wall_items: Dictionary = {}   # "north" -> { Vector2i origin -> fid }
var _light_map: Dictionary = {}   # Vector2i -> float  (0.0 dark … 1.0 full sunlight)

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


# Real playable extent of this floor, derived from wall segments (or floor tiles)
# rather than the apartment-level grid_w/grid_h, which can be a much larger
# sandbox default unrelated to this room's actual footprint.
func get_room_bounds() -> Rect2i:
	if not floor_mask.is_empty():
		var minx := INF; var miny := INF; var maxx := -INF; var maxy := -INF
		for t in floor_mask:
			var tv := t as Vector2i
			minx = min(minx, tv.x); maxx = max(maxx, tv.x)
			miny = min(miny, tv.y); maxy = max(maxy, tv.y)
		return Rect2i(int(minx), int(miny), int(maxx - minx) + 1, int(maxy - miny) + 1)
	if not segments.is_empty():
		var minx := INF; var miny := INF; var maxx := -INF; var maxy := -INF
		for s in segments:
			var sd := s as Dictionary
			minx = min(minx, min(sd["x1"] as int, sd["x2"] as int))
			maxx = max(maxx, max(sd["x1"] as int, sd["x2"] as int))
			miny = min(miny, min(sd["y1"] as int, sd["y2"] as int))
			maxy = max(maxy, max(sd["y1"] as int, sd["y2"] as int))
		return Rect2i(int(minx), int(miny), int(maxx - minx), int(maxy - miny))
	return Rect2i(0, 0, grid_w, grid_h)


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
		var len := seg.length()
		if len < 1.0:
			continue
		var t   := clampf((fl_pos - pa).dot(seg) / (len * len), 0.0, 1.0)
		var d   := fl_pos.distance_to(pa + seg * t)
		if d < best_d:
			best_d = d; best_i = i
	return best_i


func _near_edge(local: Vector2, x0: float, y0: float, x1: float, y1: float) -> String:
	if local.y < y0 + EDGE_MARGIN and local.x > x0 and local.x < x1: return "north"
	if local.y > y1 - EDGE_MARGIN and local.x > x0 and local.x < x1: return "south"
	if local.x < x0 + EDGE_MARGIN and local.y > y0 and local.y < y1: return "west"
	if local.x > x1 - EDGE_MARGIN and local.y > y0 and local.y < y1: return "east"
	return ""


func _input(event: InputEvent) -> void:
	if not visible:
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
	# Emit signal — do NOT set_input_as_handled so editor painting still gets the event
	wall_edge_clicked.emit(edge)


func can_place(furniture: Furniture, at: Vector2i) -> bool:
	var blocked := _partition_tile_set()
	for x in range(furniture.grid_w):
		for y in range(furniture.grid_h):
			var tile := Vector2i(at.x + x, at.y + y)
			if not is_floor_tile(tile):
				return false
			if _placed_overlapping_z(tile, furniture.z_bottom, furniture.z_top, furniture) != null:
				return false
			if tile in blocked:
				return false

	# Sloped ceiling: tall furniture blocked in low zones
	if furniture.height_category == "tall" and not sloped_ceiling.is_empty():
		var sc     := sloped_ceiling
		var axis   := sc.get("axis", "x") as String
		var low_s  := sc.get("low_start", 0) as int
		var high_e := sc.get("high_end",  0) as int
		var min_h  := sc.get("min_h", 1.8) as float
		var max_h  := sc.get("max_h", 2.4) as float
		var span   := float(high_e - low_s)
		if span > 0:
			for x in range(furniture.grid_w):
				for y in range(furniture.grid_h):
					var tile := Vector2i(at.x + x, at.y + y)
					var coord := tile.x if axis == "x" else tile.y
					var frac  := clampf(float(coord - low_s) / span, 0.0, 1.0)
					var ceil_h := min_h + frac * (max_h - min_h)
					if ceil_h < 2.0:
						return false

	# Ghost zone: can't place inside another furniture's interaction clearance
	var new_rect := Rect2i(at.x, at.y, furniture.grid_w, furniture.grid_h)
	for item in _get_all_placed_unique():
		var f := item as Furniture
		if f == furniture or f.ghost_radius <= 0:
			continue
		var ghost := Rect2i(
			f.grid_pos.x - f.ghost_radius,
			f.grid_pos.y - f.ghost_radius,
			f.grid_w + f.ghost_radius * 2,
			f.grid_h + f.ghost_radius * 2
		)
		if ghost.intersects(new_rect):
			return false

	return true


func place_furniture(furniture: Furniture, at: Vector2i) -> void:
	_remove_from_grid(furniture)
	for x in range(furniture.grid_w):
		for y in range(furniture.grid_h):
			_placed_add(Vector2i(at.x + x, at.y + y), furniture)
	furniture.grid_pos = at
	furniture.position = Vector2(at.x * TILE_SIZE, at.y * TILE_SIZE)
	# Stair furniture: register block in stairs_data + populate stair_mask
	if furniture.is_stair:
		_register_stair(furniture, at)
	_compute_light_map()
	_recalculate_zones()
	furniture_changed.emit()


func remove_furniture(furniture: Furniture) -> void:
	_remove_from_grid(furniture)
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
		for dx in range(f.grid_w):
			for dy in range(f.grid_h):
				divider_tiles[Vector2i(f.grid_pos.x + dx, f.grid_pos.y + dy)] = true

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
			var found := false
			for dx in range(f.grid_w):
				if found: break
				for dy in range(f.grid_h):
					if Vector2i(f.grid_pos.x + dx, f.grid_pos.y + dy) in zone_tiles:
						for fn in f.functions:
							if fn not in zone_fns:
								zone_fns.append(fn as String)
						if f.furniture_id not in zone_fids:
							zone_fids.append(f.furniture_id)
						found = true
						break
		zones.append({"tiles": zone_tiles, "functions": zone_fns, "furniture_ids": zone_fids})
	grid_draw.queue_redraw()


func _remove_from_grid(furniture: Furniture) -> void:
	for tile in _placed.keys():
		_placed_remove_tile(tile, furniture)
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


func get_adjacent_furniture(edge: String) -> Array:
	# Returns [{furniture, wall_x}] for pieces whose footprint touches this wall edge
	var result: Array = []
	var bounds := get_room_bounds()
	for item in _get_all_placed_unique():
		var f := item as Furniture
		var adjacent := false
		var wall_x := 0
		match edge:
			"north":
				if f.grid_pos.y < WALL_DEPTH:
					adjacent = true
					wall_x = f.grid_pos.x
			"south":
				if f.grid_pos.y + f.grid_h > bounds.position.y + bounds.size.y - WALL_DEPTH:
					adjacent = true
					wall_x = f.grid_pos.x
			"west":
				if f.grid_pos.x < WALL_DEPTH:
					adjacent = true
					wall_x = f.grid_pos.y
			"east":
				if f.grid_pos.x + f.grid_w > bounds.position.x + bounds.size.x - WALL_DEPTH:
					adjacent = true
					wall_x = f.grid_pos.y
		if adjacent:
			result.append({"furniture": f, "wall_x": wall_x})
	return result


func check_extended_conflict(furniture: Furniture) -> bool:
	if not furniture.foldable or furniture.extended_add_h <= 0:
		return false
	var start_y := furniture.grid_pos.y + furniture.grid_h
	var end_y   := start_y + furniture.extended_add_h
	for y in range(start_y, end_y):
		for x in range(furniture.grid_w):
			var tile := Vector2i(furniture.grid_pos.x + x, y)
			if tile.y >= grid_h or tile.x < 0 or tile.x >= grid_w:
				return true
			if _placed_overlapping_z(tile, furniture.z_bottom, furniture.z_top, furniture) != null:
				return true
	return false


func add_pipe_route(type: String, tiles: Array) -> void:
	# Remove existing route of same type first
	pipe_routes = pipe_routes.filter(func(r): return r["type"] != type)
	pipe_routes.append({"type": type, "tiles": tiles})


func clear_pipe_route(type: String) -> void:
	pipe_routes = pipe_routes.filter(func(r): return r["type"] != type)


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
				if Rect2i(fur.grid_pos, Vector2i(fur.grid_w, fur.grid_h)).has_point(t):
					connected = true
					break
			if not connected:
				missing["water"].append(fur.furniture_id)
		if fur.needs_power:
			var connected := false
			for t in routed_power:
				if Rect2i(fur.grid_pos, Vector2i(fur.grid_w, fur.grid_h)).has_point(t):
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
	var x0 := f.grid_pos.x
	var y0 := f.grid_pos.y
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
