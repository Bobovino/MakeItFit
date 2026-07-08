extends Control
class_name Room3DView

# Low-poly 3D room view, built as a diorama from the same data the 2D
# blueprint views use (grid_w/h, wall_h, floor_depth, color). Floor furniture
# here is a first-class interactive surface, not just a "wow moment" reveal:
# it can be picked up, dragged, bought, and sold directly in 3D, going through
# the exact same Floor.can_place/snap_to_wall/place_furniture calls the 2D
# views use — there's only one source of truth (Floor), this is just another
# way to look at and edit it. Wall-mounted items aren't editable here yet.

signal closed
signal sell_requested(furniture: Furniture)   # right-click on a floor piece — Main.gd handles the refund
signal buy_confirmed(furniture: Furniture)    # a piece bought via start_buying() was placed
signal buy_cancelled(furniture: Furniture)    # the same, but the purchase was backed out (Esc)

const TILE_M      := 0.1     # metres per tile (10 cm) — matches the 2D views
const WALL_TILES  := 24      # matches WallInspector.WALL_HEIGHT (2.4 m ceiling)
const WALL_H_M    := WALL_TILES * TILE_M
const WALL_THICK  := 0.1

@onready var container:  SubViewportContainer = $SubViewportContainer
@onready var sub_vp:     SubViewport          = $SubViewportContainer/SubViewport
@onready var cam:        Camera3D             = $SubViewportContainer/SubViewport/World/Cam
@onready var build_root: Node3D               = $SubViewportContainer/SubViewport/World/BuildRoot
@onready var close_btn:  Button               = $CloseBtn

var _yaw:     float   = -45.0
var _pitch:   float   = -32.0
var _dist:    float   = 6.0
var _center:  Vector3 = Vector3.ZERO
var _dragging: bool   = false
var _auto_spin: bool  = false
var _press_pos: Vector2 = Vector2.ZERO
const CLICK_MOVE_THRESHOLD := 6.0

# Floor-furniture dragging: reach back into the live Floor this diorama was
# built from so a drag here actually moves the piece (unlike everything else
# in this file, which is throwaway presentation geometry). Wall-mounted items
# aren't draggable here, just the floor-standing boxes from _add_furniture_box.
var _apt_floor:    Floor  = null
var _room_bounds:  Rect2i = Rect2i()
var _furniture_entries: Array = []   # [{furniture, mesh, pos, size}]
var _dragging_furniture: bool = false
var _drag_target:   Dictionary = {}
var _drag_offset:   Vector2    = Vector2.ZERO   # tile-space grab offset
var _drag_orig_pos: Vector3    = Vector3.ZERO
var _drag_last_tile: Vector2   = Vector2.ZERO   # continuous — 3D drag is no longer grid-snapped

# Buying a new floor item directly in 3D: Main.gd instantiates+setup()s the
# Furniture node (same as it does for the 2D purchase flow) and hands it here
# via start_buying() instead of Furniture.begin_placement(); everything after
# that — ghost follow, snap, commit — reuses the drag machinery above.
var _buying_furniture: Furniture = null
var _buying_mesh: MeshInstance3D = null

# Walls between the camera and the room center fade out so the view isn't
# blocked — each entry is {mat: StandardMaterial3D, normal: Vector3, base: Color}.
var _wall_data: Array = []

# ── Foldable-item demo (single-item preview only) ──────────────────────────
# Click the item to toggle folded/extended; before the first click it loops
# on its own so the player can see the transform without touching anything.
const FOLD_LOOP_SPEED   := 1.1   # radians/sec fed into sin() — ~5.7s per cycle
const FOLD_MANUAL_SPEED := 2.2   # fold_t units/sec once the player takes over
var _foldable:    bool    = false
var _fold_auto:   bool    = true
var _fold_t:      float   = 0.0   # 0 = folded/closed, 1 = extended/open
var _fold_target: float   = 0.0
var _fold_phase:  float   = 0.0
var _fold_mesh:   MeshInstance3D = null
var _fold_closed_size: Vector3 = Vector3.ONE
var _fold_closed_pos:  Vector3 = Vector3.ZERO
var _fold_open_size:   Vector3 = Vector3.ONE
var _fold_open_pos:    Vector3 = Vector3.ZERO


func _ready() -> void:
	close_btn.pressed.connect(func(): closed.emit())
	container.mouse_filter = Control.MOUSE_FILTER_STOP
	container.gui_input.connect(_on_container_input)


func _process(delta: float) -> void:
	if _auto_spin and not _dragging:
		_yaw += delta * 18.0
		_update_camera()
	if _foldable:
		if _fold_auto:
			_fold_phase += delta * FOLD_LOOP_SPEED
			_fold_t = (sin(_fold_phase) + 1.0) * 0.5
		else:
			_fold_t = move_toward(_fold_t, _fold_target, delta * FOLD_MANUAL_SPEED)
		_update_fold_visual()


func _on_container_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press_pos = mb.position
				if _buying_furniture:
					_confirm_buy(_to_vp(mb.position))
					return
				var vp_pos := _to_vp(mb.position)
				var hit := _pick_furniture(vp_pos)
				if not hit.is_empty():
					_begin_furniture_drag(hit, vp_pos)
				else:
					_dragging = true
			else:
				if _dragging_furniture:
					_finish_furniture_drag()
				elif mb.position.distance_to(_press_pos) < CLICK_MOVE_THRESHOLD:
					_on_item_clicked()
				_dragging = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _buying_furniture:
				_cancel_buy()
				return
			var hit := _pick_furniture(_to_vp(mb.position))
			if not hit.is_empty():
				_sell_furniture(hit)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(1.5, _dist - 0.5)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(30.0, _dist + 0.5)
			_update_camera()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _buying_furniture:
			_update_buy_ghost(_to_vp(mm.position))
		elif _dragging_furniture:
			_update_furniture_drag(_to_vp(mm.position))
		elif _dragging:
			_yaw   -= mm.relative.x * 0.4
			_pitch  = clampf(_pitch - mm.relative.y * 0.4, -80.0, -5.0)
			_update_camera()


# gui_input only reliably delivers mouse/touch events here (the container
# doesn't hold keyboard focus), so Esc-to-cancel a purchase is handled through
# the normal _input() channel instead, same as Furniture.gd's 2D equivalent.
func _input(event: InputEvent) -> void:
	if _buying_furniture and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel_buy()
		get_viewport().set_input_as_handled()


# Picking / dragging helpers

func _to_vp(pos: Vector2) -> Vector2:
	var csize := container.size
	if csize.x <= 0.0 or csize.y <= 0.0:
		return pos
	return pos * (Vector2(sub_vp.size) / csize)


func _ground_hit(vp_pos: Vector2) -> Vector3:
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	if absf(dir.y) < 0.0001:
		return from
	var t := -from.y / dir.y
	return from + dir * t


func _room_local_to_tile(local: Vector3) -> Vector2:
	return Vector2(local.x / TILE_M + _room_bounds.position.x,
		local.z / TILE_M + _room_bounds.position.y)


func _ray_box_t(from: Vector3, dir: Vector3, box_min: Vector3, box_max: Vector3) -> float:
	var tmin := -INF
	var tmax := INF
	for axis in range(3):
		var o: float = from[axis]
		var d: float = dir[axis]
		var mn: float = box_min[axis]
		var mx: float = box_max[axis]
		if absf(d) < 1e-6:
			if o < mn or o > mx:
				return INF
			continue
		var t1 := (mn - o) / d
		var t2 := (mx - o) / d
		if t1 > t2:
			var tmp := t1; t1 = t2; t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return INF
	if tmax < 0.0:
		return INF
	return tmin if tmin >= 0.0 else tmax


func _pick_furniture(vp_pos: Vector2) -> Dictionary:
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	var best_t := INF
	var best: Dictionary = {}
	for entry in _furniture_entries:
		var pos: Vector3 = entry["pos"]
		var size: Vector3 = entry["size"]
		var t := _ray_box_t(from, dir, pos - size * 0.5, pos + size * 0.5)
		if t < best_t:
			best_t = t
			best = entry
	return best


func _begin_furniture_drag(hit: Dictionary, vp_pos: Vector2) -> void:
	_drag_target        = hit
	_dragging_furniture = true
	_drag_orig_pos       = hit["pos"]
	var f: Furniture     = hit["furniture"]
	var tile             := _room_local_to_tile(_ground_hit(vp_pos))
	_drag_offset         = Vector2(f.grid_pos.x, f.grid_pos.y) - tile
	_drag_last_tile      = f.grid_pos


func _update_furniture_drag(vp_pos: Vector2) -> void:
	# Continuous — no rounding to a tile grid. 3D is the source of truth now,
	# so the piece follows the cursor at whatever fractional position it's at;
	# snap_to_wall() below (on release) is the only thing that pulls it flush.
	var tile := _room_local_to_tile(_ground_hit(vp_pos)) + _drag_offset
	_drag_last_tile = tile
	var mesh: MeshInstance3D = _drag_target["mesh"]
	var size: Vector3 = _drag_target["size"]
	mesh.position.x = (tile.x - _room_bounds.position.x) * TILE_M + size.x * 0.5
	mesh.position.z = (tile.y - _room_bounds.position.y) * TILE_M + size.z * 0.5
	_drag_target["pos"] = mesh.position


# Mirrors Furniture.begin_placement(): Main.gd creates and setup()s the
# Furniture node for a purchase (deducting budget only once it's actually
# placed, same as the 2D flow), then hands it here instead of calling
# begin_placement() so the ghost follows the 3D ground-raycast instead of a
# 2D mouse position.
func start_buying(furniture: Furniture, fdata: Dictionary) -> void:
	_buying_furniture = furniture
	var height_m := maxf((fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
	var col := Color("#" + (fdata.get("color", "888888") as String))
	col.a = 0.55
	var size := Vector3(furniture.grid_w * TILE_M, height_m, furniture.grid_h * TILE_M)
	_buying_mesh = _box(size, Vector3(size.x * 0.5, size.y * 0.5, size.z * 0.5), col)


func _update_buy_ghost(vp_pos: Vector2) -> void:
	var tile := _room_local_to_tile(_ground_hit(vp_pos))
	var size: Vector3 = (_buying_mesh.mesh as BoxMesh).size
	_buying_mesh.position.x = (tile.x - _room_bounds.position.x) * TILE_M + size.x * 0.5
	_buying_mesh.position.z = (tile.y - _room_bounds.position.y) * TILE_M + size.z * 0.5


func _confirm_buy(vp_pos: Vector2) -> void:
	if not _apt_floor:
		return
	var tile := _room_local_to_tile(_ground_hit(vp_pos))
	var snapped := _apt_floor.snap_to_wall(_buying_furniture, tile)
	if not _apt_floor.can_place(_buying_furniture, snapped):
		return
	_apt_floor.place_furniture(_buying_furniture, snapped)
	var f := _buying_furniture
	var size: Vector3 = (_buying_mesh.mesh as BoxMesh).size
	var mat := _buying_mesh.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color.a = 1.0   # drop the semi-transparent "ghost" look now that it's placed
	_furniture_entries.append({"furniture": f, "mesh": _buying_mesh, "pos": _buying_mesh.position, "size": size})
	_buying_furniture = null
	_buying_mesh = null
	buy_confirmed.emit(f)


func _cancel_buy() -> void:
	var f := _buying_furniture
	if is_instance_valid(_buying_mesh):
		_buying_mesh.queue_free()
	_buying_furniture = null
	_buying_mesh = null
	buy_cancelled.emit(f)


func _sell_furniture(hit: Dictionary) -> void:
	var f: Furniture = hit["furniture"]
	var mesh: MeshInstance3D = hit["mesh"]
	for i in range(_furniture_entries.size() - 1, -1, -1):
		if _furniture_entries[i]["furniture"] == f:
			_furniture_entries.remove_at(i)
	if is_instance_valid(mesh):
		mesh.queue_free()
	sell_requested.emit(f)   # Main.gd handles the refund + apt_floor.remove_furniture


func _finish_furniture_drag() -> void:
	_dragging_furniture = false
	var f: Furniture = _drag_target["furniture"]
	var mesh: MeshInstance3D = _drag_target["mesh"]
	var size: Vector3 = _drag_target["size"]
	var snapped := _apt_floor.snap_to_wall(f, _drag_last_tile) if _apt_floor else _drag_last_tile
	if _apt_floor and _apt_floor.can_place(f, snapped):
		_apt_floor.place_furniture(f, snapped)
		mesh.position.x = (snapped.x - _room_bounds.position.x) * TILE_M + size.x * 0.5
		mesh.position.z = (snapped.y - _room_bounds.position.y) * TILE_M + size.z * 0.5
	else:
		mesh.position = _drag_orig_pos
	_drag_target["pos"] = mesh.position
	_drag_target = {}


# A real click (not a camera-drag) on the preview toggles a foldable item
# between its folded and extended shape; harmless no-op for anything else.
func _on_item_clicked() -> void:
	if not _foldable:
		return
	_fold_auto   = false
	_fold_target = 0.0 if _fold_target > 0.5 else 1.0


func _update_fold_visual() -> void:
	if not is_instance_valid(_fold_mesh):
		return
	var mesh := _fold_mesh.mesh as BoxMesh
	mesh.size          = _fold_closed_size.lerp(_fold_open_size, _fold_t)
	_fold_mesh.position = _fold_closed_pos.lerp(_fold_open_pos, _fold_t)


func _update_camera() -> void:
	var ry := deg_to_rad(_yaw)
	var rp := deg_to_rad(_pitch)
	var offset := Vector3(cos(rp) * sin(ry), -sin(rp), cos(rp) * cos(ry)) * _dist
	cam.position = _center + offset
	cam.look_at(_center, Vector3.UP)
	_update_wall_visibility(offset)


# Fades out whichever wall(s) sit between the camera and the room so the
# interior is never blocked — a "dollhouse cutaway" rather than a sealed box.
func _update_wall_visibility(cam_offset: Vector3) -> void:
	var flat := Vector3(cam_offset.x, 0.0, cam_offset.z)
	if flat.length() < 0.001:
		return
	flat = flat.normalized()
	for wd in _wall_data:
		var normal: Vector3 = wd["normal"]
		var mat: StandardMaterial3D = wd["mat"]
		var base: Color = wd["base"]
		# Positive dot = camera is on the outside of this wall, looking in —
		# that's the wall we need to hide.
		var facing := clampf(normal.dot(flat), 0.0, 1.0)
		var alpha := lerpf(1.0, 0.08, facing)
		mat.albedo_color = Color(base.r, base.g, base.b, alpha)


# `catalog` is the furniture data array (gm.furniture_data["furniture"]).
func build_from_floor(apt_floor: Floor, catalog: Array) -> void:
	_auto_spin = false
	_foldable  = false
	_fold_mesh = null
	for c in build_root.get_children():
		c.queue_free()
	_wall_data.clear()
	_furniture_entries.clear()
	_dragging_furniture = false
	_drag_target = {}

	_apt_floor = apt_floor
	var bounds := apt_floor.get_room_bounds()
	_room_bounds = bounds
	var w := bounds.size.x * TILE_M
	var d := bounds.size.y * TILE_M

	_center = Vector3(w * 0.5, WALL_H_M * 0.35, d * 0.5)
	_dist   = maxf(w, d) * 1.4 + 2.0

	_add_floor(w, d)
	_add_walls(w, d, apt_floor.sloped_ceiling, bounds)
	_add_balcony_extras(bounds)
	_update_camera()   # also applies initial wall-fade now that _wall_data exists

	for item in apt_floor.get_all_furniture():
		_add_furniture_box(item as Furniture, bounds, catalog)

	for edge in apt_floor.wall_items:
		var items: Dictionary = apt_floor.wall_items[edge] as Dictionary
		for origin in items:
			_add_wall_item_box(edge, origin as Vector2i, items[origin] as String, w, d, catalog)


# Product-shot mode: a single item on a small floor pad, slowly auto-rotating,
# with no walls. `fdata` is one entry from the furniture catalog (a Dictionary
# with size/wall_h/color etc, the same shape build_from_floor reads).
func build_single_item(fdata: Dictionary) -> void:
	_auto_spin = true
	_yaw   = -30.0
	_pitch = -22.0
	_foldable  = fdata.get("foldable", false) as bool
	_fold_mesh = null
	for c in build_root.get_children():
		c.queue_free()
	_wall_data.clear()

	var iw: int = (fdata.get("size", {}) as Dictionary).get("w", 5) as int
	var ih: int = (fdata.get("size", {}) as Dictionary).get("h", 5) as int
	var height_m := maxf((fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
	var fw := iw * TILE_M
	var fd := ih * TILE_M
	var col := Color("#" + (fdata.get("color", "888888") as String))

	if _foldable:
		# `extended_add_h` (tiles) is the same field the 2D game uses to grow a
		# foldable item's footprint when deployed — reuse it here so the demo
		# matches the item's real folded/extended sizes.
		const OPEN_THICK := 0.15   # generic "lying flat" thickness — no per-item field for this
		var add_h: int = fdata.get("extended_add_h", 6) as int
		var closed_depth := fd
		var open_depth   := (ih + add_h) * TILE_M

		var pad := maxf(fw, maxf(open_depth, height_m)) * 1.7
		_center = Vector3(0.0, height_m * 0.35, open_depth * 0.25)
		_dist   = maxf(fw, maxf(open_depth, height_m)) * 2.4 + 1.0

		_box(Vector3(pad, 0.05, pad), Vector3(0.0, -0.025, 0.0), Color(0.93, 0.90, 0.83))

		# Backdrop "wall" for context — the panel folds up flush against it.
		var wall_z := -pad * 0.2
		_box(Vector3(fw * 1.3, height_m * 1.15, 0.05), Vector3(0.0, height_m * 0.575, wall_z), Color(0.86, 0.83, 0.76))

		_fold_closed_size = Vector3(fw, height_m, closed_depth)
		_fold_closed_pos  = Vector3(0.0, height_m * 0.5, wall_z + closed_depth * 0.5 + 0.03)
		_fold_open_size   = Vector3(fw, OPEN_THICK, open_depth)
		_fold_open_pos    = Vector3(0.0, OPEN_THICK * 0.5, wall_z + open_depth * 0.5 + 0.05)

		_fold_t      = 0.0
		_fold_target = 0.0
		_fold_auto   = true
		_fold_phase  = 0.0
		_fold_mesh = _box(_fold_closed_size, _fold_closed_pos, col)
	else:
		var pad := maxf(fw, fd) * 1.6
		_center = Vector3(0.0, height_m * 0.4, 0.0)
		_dist   = maxf(fw, maxf(fd, height_m)) * 2.2 + 1.0
		_box(Vector3(pad, 0.05, pad), Vector3(0.0, -0.025, 0.0), Color(0.93, 0.90, 0.83))
		_box(Vector3(fw, height_m, fd), Vector3(0.0, height_m * 0.5, 0.0), col)

	_update_camera()


func _find_furniture_data(catalog: Array, fid: String) -> Dictionary:
	for f in catalog:
		if (f as Dictionary).get("id", "") == fid:
			return f as Dictionary
	return {}


func _box(box_size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = box_size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	build_root.add_child(mi)
	return mi


func _add_floor(w: float, d: float) -> void:
	_box(Vector3(w, 0.05, d), Vector3(w * 0.5, -0.025, d * 0.5), Color(0.93, 0.90, 0.83))


const RAIL_H_M     := 0.9
const RAIL_THICK_M := 0.03

# Balconies/bathroom nooks are floor_kind-tagged tiles that sit OUTSIDE the
# wall-bounds rectangle _add_floor already covers (see Wall.gd's
# _prune_floor_mask_to_walls) — without this they'd be invisible in 3D even
# though they're walkable. Each one also gets a railing along any edge that
# borders a non-floor (exterior) tile, mirroring GridDraw's 2D balcony rail.
func _add_balcony_extras(bounds: Rect2i) -> void:
	if not _apt_floor or _apt_floor.floor_kind.is_empty():
		return
	var floor_col := Color(0.93, 0.90, 0.83)
	var rail_col  := Color(0.9, 0.92, 0.95)
	for tile in _apt_floor.floor_kind:
		var t := tile as Vector2i
		var local_x := (t.x - bounds.position.x) * TILE_M
		var local_z := (t.y - bounds.position.y) * TILE_M
		if not bounds.has_point(t):
			_box(Vector3(TILE_M, 0.05, TILE_M),
				Vector3(local_x + TILE_M * 0.5, -0.025, local_z + TILE_M * 0.5), floor_col)
		if (_apt_floor.floor_kind[tile] as String) != "balcony":
			continue
		var edges := [
			[Vector2i(t.x, t.y - 1), Vector3(local_x + TILE_M * 0.5, 0.0, local_z), true],
			[Vector2i(t.x, t.y + 1), Vector3(local_x + TILE_M * 0.5, 0.0, local_z + TILE_M), true],
			[Vector2i(t.x - 1, t.y), Vector3(local_x, 0.0, local_z + TILE_M * 0.5), false],
			[Vector2i(t.x + 1, t.y), Vector3(local_x + TILE_M, 0.0, local_z + TILE_M * 0.5), false],
		]
		for e in edges:
			var ntile: Vector2i = e[0]
			var center: Vector3 = e[1]
			var horizontal: bool = e[2]
			if _apt_floor.is_floor_tile(ntile):
				continue
			var size := Vector3(TILE_M, RAIL_H_M, RAIL_THICK_M) if horizontal \
				else Vector3(RAIL_THICK_M, RAIL_H_M, TILE_M)
			_box(size, center + Vector3(0.0, RAIL_H_M * 0.5, 0.0), rail_col)


# Ceiling height (metres) at a given absolute world tile coordinate along the
# slope axis — same formula GridDraw/WallInspector use for the 2D contour.
func _sloped_height_m(sc: Dictionary, coord_tile: float) -> float:
	var low_s  := sc.get("low_start", 0) as float
	var high_e := sc.get("high_end", 0) as float
	var min_h  := sc.get("min_h", 1.8) as float
	var max_h  := sc.get("max_h", 2.4) as float
	var span := high_e - low_s
	if span <= 0.0:
		return max_h
	var frac := clampf((coord_tile - low_s) / span, 0.0, 1.0)
	return min_h + frac * (max_h - min_h)


# A wall as a "wedge" prism: rectangular cross-section whose top edge rises
# linearly from h0 (local x=0) to h1 (local x=length) — degenerates to a
# plain box when h0 == h1, so it doubles as the flat-ceiling case too.
func _wedge_mesh(length: float, thick: float, h0: float, h1: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a0 := Vector3(0.0, 0.0, 0.0)
	var b0 := Vector3(0.0, h0, 0.0)
	var c0 := Vector3(length, h1, 0.0)
	var d0 := Vector3(length, 0.0, 0.0)
	var a1 := Vector3(0.0, 0.0, thick)
	var b1 := Vector3(0.0, h0, thick)
	var c1 := Vector3(length, h1, thick)
	var d1 := Vector3(length, 0.0, thick)
	# Winding isn't hardened per-face (materials render double-sided instead),
	# so these just need to be planar quads, not a specific orientation.
	var faces := [
		[a0, d0, d1, a1],   # bottom
		[b0, b1, c1, c0],   # slanted top
		[a0, b0, c0, d0],   # front (z=0)
		[d1, c1, b1, a1],   # back (z=thick)
		[a1, b1, b0, a0],   # left end (x=0)
		[d0, c0, c1, d1],   # right end (x=length)
	]
	for quad in faces:
		var p0: Vector3 = quad[0]
		var p1: Vector3 = quad[1]
		var p2: Vector3 = quad[2]
		var p3: Vector3 = quad[3]
		var n := (p1 - p0).cross(p2 - p0).normalized()
		st.set_normal(n); st.add_vertex(p0)
		st.set_normal(n); st.add_vertex(p1)
		st.set_normal(n); st.add_vertex(p2)
		st.set_normal(n); st.add_vertex(p0)
		st.set_normal(n); st.add_vertex(p2)
		st.set_normal(n); st.add_vertex(p3)
	return st.commit()


func _add_sloped_wall(length: float, thick: float, h0: float, h1: float,
		pos: Vector3, rot_y_deg: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _wedge_mesh(length, thick, h0, h1)
	mi.position = pos
	mi.rotation.y = deg_to_rad(rot_y_deg)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	build_root.add_child(mi)
	return mi


# `sc` is Floor.sloped_ceiling ({} if the room has a flat ceiling). Walls
# running along the slope axis get a slanted top edge; the other two get a
# constant height matching the ceiling at their fixed position — mirrors the
# 2D GridDraw/WallInspector cut logic exactly, just in 3D.
func _add_walls(w: float, d: float, sc: Dictionary, bounds: Rect2i) -> void:
	var col := Color(0.86, 0.83, 0.76)
	var has_slope := not sc.is_empty()
	var axis: String = sc.get("axis", "x") as String

	var slope_ns := has_slope and axis == "x"   # north/south run along world X
	var slope_we := has_slope and axis == "y"   # west/east run along world Y (our Z)

	var h_n0 := WALL_H_M; var h_n1 := WALL_H_M
	var h_s0 := WALL_H_M; var h_s1 := WALL_H_M
	if slope_ns:
		h_n0 = _sloped_height_m(sc, bounds.position.x)
		h_n1 = _sloped_height_m(sc, bounds.position.x + bounds.size.x)
		h_s0 = h_n0; h_s1 = h_n1
	elif has_slope:
		h_n0 = _sloped_height_m(sc, bounds.position.y)
		h_n1 = h_n0
		h_s0 = _sloped_height_m(sc, bounds.position.y + bounds.size.y)
		h_s1 = h_s0

	var h_w0 := WALL_H_M; var h_w1 := WALL_H_M
	var h_e0 := WALL_H_M; var h_e1 := WALL_H_M
	if slope_we:
		h_w0 = _sloped_height_m(sc, bounds.position.y)
		h_w1 = _sloped_height_m(sc, bounds.position.y + bounds.size.y)
		h_e0 = h_w0; h_e1 = h_w1
	elif has_slope:
		h_w0 = _sloped_height_m(sc, bounds.position.x)
		h_w1 = h_w0
		h_e0 = _sloped_height_m(sc, bounds.position.x + bounds.size.x)
		h_e1 = h_e0

	var mi_n := _add_sloped_wall(w, WALL_THICK, h_n0, h_n1, Vector3(0.0, 0.0, 0.0), 0.0, col)
	_wall_data.append({"mat": mi_n.material_override, "normal": Vector3(0, 0, -1), "base": col})

	var mi_s := _add_sloped_wall(w, WALL_THICK, h_s0, h_s1, Vector3(0.0, 0.0, d - WALL_THICK), 0.0, col)
	_wall_data.append({"mat": mi_s.material_override, "normal": Vector3(0, 0, 1), "base": col})

	var mi_w := _add_sloped_wall(d, WALL_THICK, h_w0, h_w1, Vector3(WALL_THICK, 0.0, 0.0), -90.0, col)
	_wall_data.append({"mat": mi_w.material_override, "normal": Vector3(-1, 0, 0), "base": col})

	var mi_e := _add_sloped_wall(d, WALL_THICK, h_e0, h_e1, Vector3(w, 0.0, 0.0), -90.0, col)
	_wall_data.append({"mat": mi_e.material_override, "normal": Vector3(1, 0, 0), "base": col})


func _add_furniture_box(f: Furniture, bounds: Rect2i, catalog: Array) -> void:
	var fdata := _find_furniture_data(catalog, f.furniture_id)
	var height_m := maxf((fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
	var fw := f.grid_w * TILE_M
	var fd := f.grid_h * TILE_M
	var local_x := (f.grid_pos.x - bounds.position.x) * TILE_M + fw * 0.5
	var local_z := (f.grid_pos.y - bounds.position.y) * TILE_M + fd * 0.5
	var col := Color("#" + (fdata.get("color", "888888") as String))
	var size := Vector3(fw, height_m, fd)
	var pos  := Vector3(local_x, height_m * 0.5, local_z)
	var mi   := _box(size, pos, col)
	_furniture_entries.append({"furniture": f, "mesh": mi, "pos": pos, "size": size})


# `origin` is wall-local: origin.x along the wall, origin.y from the TOP of
# the wall (0 = ceiling, WALL_TILES = floor) — matches WallInspector.
func _add_wall_item_box(edge: String, origin: Vector2i, fid: String,
		w: float, d: float, catalog: Array) -> void:
	var fdata := _find_furniture_data(catalog, fid)
	if fdata.is_empty():
		return
	var iw: int    = (fdata.get("size", {}) as Dictionary).get("w", 5) as int
	var ih: int    = fdata.get("wall_h", 5) as int
	var depth: int = fdata.get("floor_depth", 1) as int
	var iw_m    := iw * TILE_M
	var ih_m    := ih * TILE_M
	var depth_m := maxf(depth * TILE_M, 0.05)
	var top_from_floor_m := WALL_H_M - origin.y * TILE_M
	var center_y := top_from_floor_m - ih_m * 0.5
	var along    := origin.x * TILE_M + iw_m * 0.5
	var col := Color("#" + (fdata.get("color", "888888") as String))

	match edge:
		"north": _box(Vector3(iw_m, ih_m, depth_m), Vector3(along, center_y, depth_m * 0.5), col)
		"south": _box(Vector3(iw_m, ih_m, depth_m), Vector3(along, center_y, d - depth_m * 0.5), col)
		"west":  _box(Vector3(depth_m, ih_m, iw_m), Vector3(depth_m * 0.5, center_y, along), col)
		"east":  _box(Vector3(depth_m, ih_m, iw_m), Vector3(w - depth_m * 0.5, center_y, along), col)
