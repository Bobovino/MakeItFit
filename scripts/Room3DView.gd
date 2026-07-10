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
signal buy_confirmed(furniture: Furniture)    # a piece bought via start_buying() was placed on the floor
signal buy_confirmed_wall(furniture_id: String, edge: String, origin: Vector2i)  # ...or on a wall instead
signal buy_cancelled(furniture: Furniture)    # the same, but the purchase was backed out (Esc)
signal wall_sell_requested(edge: String, origin: Vector2i)   # right-click on a wall piece
signal furniture_moved(furniture: Furniture)   # an existing piece was dragged to a new spot and committed

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
var _catalog: Array = []   # furniture data array, kept for wall-item placement/validation math
var _room_w_m: float = 0.0
var _room_d_m: float = 0.0
var _furniture_entries: Array = []   # [{furniture, mesh, pos, size}]
var _dragging_furniture: bool = false
var _drag_target:   Dictionary = {}
var _drag_offset:   Vector2    = Vector2.ZERO   # tile-space grab offset
var _drag_orig_pos: Vector3    = Vector3.ZERO
var _drag_last_tile: Vector2   = Vector2.ZERO   # continuous — 3D drag is no longer grid-snapped

# Wall-mounted items: rendered by _add_wall_item_box, but (unlike floor
# furniture) they have no live Furniture node — Floor just tracks them as
# {origin: fid} strings per edge. Dragging/selling them here has to go
# through Floor.place_wall_item/remove_wall_item directly instead.
const WALL_HEIGHT_TILES := WALL_TILES
var _wall_item_entries: Array = []   # [{edge, origin, fid, mesh, iw, ih}]
var _dragging_wall_item: bool = false
var _drag_wall_target:   Dictionary = {}

# Buying a new item directly in 3D: Main.gd instantiates+setup()s the
# Furniture node (same as it does for the 2D purchase flow) and hands it here
# via start_buying() instead of Furniture.begin_placement(); everything after
# that — ghost follow, snap, commit — reuses the drag machinery above. The
# ghost can land on the floor OR on a wall, decided each frame by whichever
# the cursor ray is actually pointing at.
var _buying_furniture: Furniture = null
var _buying_fdata: Dictionary = {}
var _buying_mesh: MeshInstance3D = null
var _buying_on_wall: bool = false   # last hover: floor ghost or wall ghost?

# Walls between the camera and the room center fade out so the view isn't
# blocked — each entry is {mat: StandardMaterial3D, normal: Vector3, base: Color}.
var _wall_data: Array = []
var _cam_flat_dir: Vector3 = Vector3.ZERO   # XZ camera direction from center, set by _update_wall_visibility

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
				var wall_hit := _pick_wall_item(vp_pos)
				if not wall_hit.is_empty():
					_begin_wall_item_drag(wall_hit, vp_pos)
				else:
					var hit := _pick_furniture(vp_pos)
					if not hit.is_empty():
						_begin_furniture_drag(hit, vp_pos)
					else:
						_dragging = true
			else:
				if _dragging_furniture:
					# Mousedown always starts a "drag" the instant it lands on a
					# furniture piece (see the pressed branch above), so a plain
					# click never reaches the `elif ... _on_item_clicked()` case
					# below — it has to be handled here instead, before falling
					# through to the real drag-finish logic.
					if mb.position.distance_to(_press_pos) < CLICK_MOVE_THRESHOLD:
						_click_furniture_no_drag()
					else:
						_finish_furniture_drag()
				elif _dragging_wall_item:
					_finish_wall_item_drag()
				elif mb.position.distance_to(_press_pos) < CLICK_MOVE_THRESHOLD:
					_on_item_clicked(_to_vp(mb.position))
				_dragging = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _buying_furniture:
				_cancel_buy()
				return
			var vp_pos := _to_vp(mb.position)
			var wall_hit := _pick_wall_item(vp_pos)
			if not wall_hit.is_empty():
				_sell_wall_item(wall_hit)
				return
			var hit := _pick_furniture(vp_pos)
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
		elif _dragging_wall_item:
			_update_wall_item_drag(_to_vp(mm.position))
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
	elif close_btn.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		# close_btn is only shown for the standalone single-item preview
		# (build_single_item) — the persistent room 3D view mode hides it and
		# has no "closed" concept, so this never fires there.
		closed.emit()
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
		var item_size: Vector3 = entry["size"]
		var t := _ray_box_t(from, dir, pos - item_size * 0.5, pos + item_size * 0.5)
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
	var item_size: Vector3 = _drag_target["size"]
	mesh.position.x = (tile.x - _room_bounds.position.x) * TILE_M + item_size.x * 0.5
	mesh.position.z = (tile.y - _room_bounds.position.y) * TILE_M + item_size.z * 0.5
	_drag_target["pos"] = mesh.position


# Mirrors Furniture.begin_placement(): Main.gd creates and setup()s the
# Furniture node for a purchase (deducting budget only once it's actually
# placed, same as the 2D flow), then hands it here instead of calling
# begin_placement() so the ghost follows the cursor in 3D instead of a 2D
# mouse position. The ghost can land on the floor or on a wall — whichever
# the cursor ray is actually pointing at each frame (see _scene_hit).
func start_buying(furniture: Furniture, fdata: Dictionary) -> void:
	# Pressing Buy again before confirming/cancelling the previous ghost used
	# to just overwrite _buying_mesh, leaking the old ghost (and its pending
	# Furniture node) on screen forever. Cancel it first — this also emits
	# buy_cancelled so Main.gd's pending Furniture node gets freed too.
	if _buying_furniture:
		_cancel_buy()
	_buying_furniture = furniture
	_buying_fdata     = fdata
	_buying_on_wall   = false
	var height_m := maxf((fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
	var col := Color("#" + (fdata.get("color", "888888") as String))
	col.a = 0.55
	var box_size := Vector3(furniture.grid_w * TILE_M, height_m, furniture.grid_h * TILE_M)
	_buying_mesh = _box(box_size, Vector3(box_size.x * 0.5, box_size.y * 0.5, box_size.z * 0.5), col)
	_apply_item_model(_buying_mesh, fdata.get("model", "") as String, box_size, fdata.get("hide_nodes", []) as Array)


func _update_buy_ghost(vp_pos: Vector2) -> void:
	var hit := _scene_hit(vp_pos)
	if hit.is_empty():
		return
	var iw: int = _buying_furniture.grid_w
	var box := _buying_mesh.mesh as BoxMesh
	if hit["mode"] == "wall":
		_buying_on_wall = true
		var edge: String = hit["edge"]
		var wall_h: int = _buying_fdata.get("wall_h", 8) as int
		var depth: int  = _buying_fdata.get("floor_depth", 1) as int
		var origin := _wall_origin_from_hit(edge, hit["along_m"], hit["height_m"], iw, wall_h, _buying_fdata)
		var xf := _wall_item_mesh_transform(edge, origin, iw, wall_h, depth)
		box.size = xf["size"]
		_buying_mesh.position = xf["pos"]
		_buying_mesh.set_meta("wall_edge", edge)
		_buying_mesh.set_meta("wall_origin", origin)
		_refit_item_model(_buying_mesh, box.size)
	else:
		_buying_on_wall = false
		# Centre the item's footprint on the cursor (matching the wall path's
		# "along_m - iw*0.5" convention below) rather than gluing its corner
		# to the raw ground-hit tile — otherwise the ghost visibly sits off
		# to one side of the cursor, worse the bigger the item is.
		var cursor_tile := _room_local_to_tile(hit["pos"] as Vector3)
		var tile := cursor_tile - Vector2(iw, _buying_furniture.grid_h) * 0.5
		var height_m := maxf((_buying_fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
		box.size = Vector3(iw * TILE_M, height_m, _buying_furniture.grid_h * TILE_M)
		_buying_mesh.position.x = (tile.x - _room_bounds.position.x) * TILE_M + box.size.x * 0.5
		_buying_mesh.position.y = box.size.y * 0.5
		_buying_mesh.position.z = (tile.y - _room_bounds.position.y) * TILE_M + box.size.z * 0.5
		_refit_item_model(_buying_mesh, box.size)


func _confirm_buy(vp_pos: Vector2) -> void:
	if _buying_on_wall:
		var edge: String = _buying_mesh.get_meta("wall_edge", "")
		var origin: Vector2i = _buying_mesh.get_meta("wall_origin", Vector2i.ZERO)
		var iw: int = _buying_furniture.grid_w
		var ih: int = _buying_fdata.get("wall_h", 8) as int
		if edge == "" or not _can_place_wall_item(edge, origin, iw, ih, Vector2i(-999999, -999999)):
			return
		var fid := _buying_furniture.furniture_id
		if _apt_floor:
			_apt_floor.place_wall_item(edge, origin, fid)
		var depth: int = _buying_fdata.get("floor_depth", 1) as int
		var xf := _wall_item_mesh_transform(edge, origin, iw, ih, depth)
		var wall_ghost_mat := _buying_mesh.material_override as StandardMaterial3D
		if wall_ghost_mat:
			wall_ghost_mat.albedo_color.a = 1.0
		(_buying_mesh.mesh as BoxMesh).size = xf["size"]
		_buying_mesh.position = xf["pos"]
		_apply_item_model(_buying_mesh, _buying_fdata.get("model", "") as String, xf["size"], _buying_fdata.get("hide_nodes", []) as Array)
		_wall_item_entries.append({"edge": edge, "origin": origin, "fid": fid, "mesh": _buying_mesh, "size": xf["size"]})
		_buying_furniture = null
		_buying_fdata     = {}
		_buying_mesh      = null
		buy_confirmed_wall.emit(fid, edge, origin)
		return

	if not _apt_floor:
		return
	var cursor_tile := _room_local_to_tile(_ground_hit(vp_pos))
	var tile := cursor_tile - Vector2(_buying_furniture.grid_w, _buying_furniture.grid_h) * 0.5
	var snap_pos := _apt_floor.snap_to_wall(_buying_furniture, tile)
	if not _apt_floor.can_place(_buying_furniture, snap_pos):
		return
	_apt_floor.place_furniture(_buying_furniture, snap_pos)
	var f := _buying_furniture
	var item_size: Vector3 = (_buying_mesh.mesh as BoxMesh).size
	var ghost_mat := _buying_mesh.material_override as StandardMaterial3D
	if ghost_mat:
		ghost_mat.albedo_color.a = 1.0   # drop the semi-transparent "ghost" look now that it's placed
	_apply_item_model(_buying_mesh, _buying_fdata.get("model", "") as String, item_size, _buying_fdata.get("hide_nodes", []) as Array)
	_furniture_entries.append({"furniture": f, "mesh": _buying_mesh, "pos": _buying_mesh.position, "size": item_size})
	_buying_furniture = null
	_buying_fdata     = {}
	_buying_mesh      = null
	buy_confirmed.emit(f)


func _cancel_buy() -> void:
	var f := _buying_furniture
	if is_instance_valid(_buying_mesh):
		_buying_mesh.queue_free()
	_buying_furniture = null
	_buying_fdata     = {}
	_buying_mesh      = null
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


# ── Wall-mounted items ──────────────────────────────────────────────────────
# Unlike floor furniture, a wall item has no live Furniture node — Floor just
# tracks {origin: furniture_id} strings per edge (see Wall.gd's wall_items).
# Dragging/selling them here goes through Floor.place_wall_item/
# remove_wall_item directly instead of a Furniture node's own API.

func _pick_wall_item(vp_pos: Vector2) -> Dictionary:
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	var best_t := INF
	var best: Dictionary = {}
	for entry in _wall_item_entries:
		var mesh: MeshInstance3D = entry["mesh"]
		var pos: Vector3 = mesh.position
		var item_size: Vector3 = entry["size"]
		var t := _ray_box_t(from, dir, pos - item_size * 0.5, pos + item_size * 0.5)
		if t < best_t:
			best_t = t
			best = entry
	return best


func _begin_wall_item_drag(hit: Dictionary, vp_pos: Vector2) -> void:
	_drag_wall_target   = hit.duplicate()
	_dragging_wall_item = true
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	var wh := _wall_plane_hit(hit["edge"], from, dir)
	var origin: Vector2i = hit["origin"]
	_drag_wall_target["offset_along_m"] = origin.x * TILE_M - (wh.get("along_m", 0.0) as float)
	_drag_wall_target["offset_ceil_m"]  = origin.y * TILE_M - (WALL_H_M - (wh.get("height_m", WALL_H_M) as float))
	_drag_wall_target["preview_origin"] = origin


func _update_wall_item_drag(vp_pos: Vector2) -> void:
	var edge: String = _drag_wall_target["edge"]
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	var wh := _wall_plane_hit(edge, from, dir)
	if wh.is_empty():
		return
	var fid: String = _drag_wall_target["fid"]
	var fdata := _find_furniture_data(_catalog, fid)
	var iw: int = (fdata.get("size", {}) as Dictionary).get("w", 1) as int
	var ih: int = fdata.get("wall_h", 1) as int
	var along_m: float = (wh["along_m"] as float) + (_drag_wall_target["offset_along_m"] as float)
	var from_ceil_m: float = (WALL_H_M - (wh["height_m"] as float)) + (_drag_wall_target["offset_ceil_m"] as float)
	var wall_w := _wall_usable_width(edge)
	var x := clampi(int(round(along_m / TILE_M)), 0, wall_w - iw)
	var pinned: bool = (fdata.get("placement", "") as String) == "floor"
	var y := (WALL_HEIGHT_TILES - ih) if pinned else clampi(int(round(from_ceil_m / TILE_M)), 0, WALL_HEIGHT_TILES - ih)
	var origin := Vector2i(x, y)
	_drag_wall_target["preview_origin"] = origin
	var depth: int = fdata.get("floor_depth", 1) as int
	var xf := _wall_item_mesh_transform(edge, origin, iw, ih, depth)
	var mesh: MeshInstance3D = _drag_wall_target["mesh"]
	mesh.position = xf["pos"]


func _finish_wall_item_drag() -> void:
	_dragging_wall_item = false
	var edge: String = _drag_wall_target["edge"]
	var old_origin: Vector2i = _drag_wall_target["origin"]
	var new_origin: Vector2i = _drag_wall_target.get("preview_origin", old_origin)
	var fid: String = _drag_wall_target["fid"]
	var fdata := _find_furniture_data(_catalog, fid)
	var iw: int = (fdata.get("size", {}) as Dictionary).get("w", 1) as int
	var ih: int = fdata.get("wall_h", 1) as int
	var depth: int = fdata.get("floor_depth", 1) as int
	var mesh: MeshInstance3D = _drag_wall_target["mesh"]
	var final_origin := old_origin
	if new_origin != old_origin and _apt_floor:
		_apt_floor.remove_wall_item(edge, old_origin)
		if _can_place_wall_item(edge, new_origin, iw, ih, new_origin):
			_apt_floor.place_wall_item(edge, new_origin, fid)
			final_origin = new_origin
		else:
			_apt_floor.place_wall_item(edge, old_origin, fid)
	var xf := _wall_item_mesh_transform(edge, final_origin, iw, ih, depth)
	mesh.position = xf["pos"]
	for i in range(_wall_item_entries.size() - 1, -1, -1):
		if _wall_item_entries[i]["mesh"] == mesh:
			_wall_item_entries[i]["origin"] = final_origin
			_wall_item_entries[i]["size"]   = xf["size"]
	_drag_wall_target = {}


func _sell_wall_item(hit: Dictionary) -> void:
	var edge: String = hit["edge"]
	var origin: Vector2i = hit["origin"]
	var mesh: MeshInstance3D = hit["mesh"]
	for i in range(_wall_item_entries.size() - 1, -1, -1):
		if _wall_item_entries[i]["mesh"] == mesh:
			_wall_item_entries.remove_at(i)
	if is_instance_valid(mesh):
		mesh.queue_free()
	wall_sell_requested.emit(edge, origin)   # Main.gd handles apt_floor.remove_wall_item


# Ray-plane intersection against a single wall's (infinite) plane — used for
# dragging an existing wall item, where the edge is already fixed and mustn't
# flip to a different wall mid-drag just because the cursor strayed past the
# room's corner.
func _wall_plane_hit(edge: String, from: Vector3, dir: Vector3) -> Dictionary:
	var axis := "z" if edge in ["north", "south"] else "x"
	var coord := 0.0
	match edge:
		"south": coord = _room_d_m
		"east":  coord = _room_w_m
	var o: float = (from.z if axis == "z" else from.x)
	var d: float = (dir.z if axis == "z" else dir.x)
	if absf(d) < 1e-6:
		return {}
	var t := (coord - o) / d
	if t < 0.0:
		return {}
	var hit := from + dir * t
	var along: float = (hit.x if axis == "z" else hit.z)
	return {"along_m": along, "height_m": hit.y}


# Ray test against the wall planes at once — used for the buy ghost, where we
# don't know which wall (if any) the cursor is over yet. The two "near" walls
# (the ones _update_wall_visibility fades out so the dollhouse cutaway doesn't
# block the view) are excluded: a ray toward the middle of the floor passes
# straight through that invisible near plane on its way from the camera, which
# would otherwise register as a (wrong) wall hit before ever reaching the
# floor and make it impossible to drop anything in the middle of the room.
func _wall_hit_test(from: Vector3, dir: Vector3) -> Dictionary:
	var normals := {
		"north": Vector3(0, 0, -1), "south": Vector3(0, 0, 1),
		"west":  Vector3(-1, 0, 0), "east":  Vector3(1, 0, 0),
	}
	var planes := [
		{"edge": "north", "axis": "z", "coord": 0.0,       "len": _room_w_m},
		{"edge": "south", "axis": "z", "coord": _room_d_m, "len": _room_w_m},
		{"edge": "west",  "axis": "x", "coord": 0.0,       "len": _room_d_m},
		{"edge": "east",  "axis": "x", "coord": _room_w_m, "len": _room_d_m},
	]
	var best_t := INF
	var best: Dictionary = {}
	for p in planes:
		var edge: String = p["edge"]
		if (normals[edge] as Vector3).dot(_cam_flat_dir) > 0.0:
			continue   # near/faded wall — not a valid drop target
		var axis: String = p["axis"]
		var o: float = (from.z if axis == "z" else from.x)
		var d: float = (dir.z if axis == "z" else dir.x)
		if absf(d) < 1e-6:
			continue
		var t := ((p["coord"] as float) - o) / d
		if t < 0.0 or t >= best_t:
			continue
		var hit := from + dir * t
		if hit.y < 0.0 or hit.y > WALL_H_M:
			continue
		var along: float = (hit.x if axis == "z" else hit.z)
		if along < 0.0 or along > (p["len"] as float):
			continue
		best_t = t
		best = {"edge": edge, "along_m": along, "height_m": hit.y, "t": t}
	return best


# Combines the ground-plane hit with the four wall-plane hits and returns
# whichever the cursor ray actually reaches first — that's "what the cursor
# is pointing at" for buy-ghost purposes.
func _scene_hit(vp_pos: Vector2) -> Dictionary:
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	var ground_t := INF
	if absf(dir.y) > 0.0001:
		var t := -from.y / dir.y
		if t >= 0.0:
			ground_t = t
	var wall := _wall_hit_test(from, dir)
	if not wall.is_empty() and (wall["t"] as float) < ground_t:
		wall["mode"] = "wall"
		return wall
	if ground_t < INF:
		return {"mode": "floor", "pos": from + dir * ground_t}
	return {}


func _wall_usable_width(edge: String) -> int:
	if not _apt_floor:
		return 8
	# -1: see Wall.WALL_SNAP / get_adjacent_furniture's comment — the raw
	# bounds span reaches corner-tile to corner-tile, but a wall item can
	# never actually reach either corner tile.
	var raw := _room_bounds.size.x if edge in ["north", "south"] else _room_bounds.size.y
	return raw - 1


func _wall_restricted_zones(edge: String) -> Array:
	var zones: Array = []
	if not _apt_floor:
		return zones
	for wd in _apt_floor.wall_definitions:
		var d := wd as Dictionary
		if d.get("edge", "") != edge:
			continue
		if d.get("has_window", false):
			zones.append(Rect2i(d.get("window_x", 5) as int, 0, d.get("window_len", 15) as int, WALL_HEIGHT_TILES))
		if d.get("has_door", false):
			zones.append(Rect2i(d.get("door_x", 0) as int, 0, 10, WALL_HEIGHT_TILES))
	return zones


# Ceiling height (metres) at a given column of this wall's elevation —
# mirrors WallInspector._ceiling_height_m exactly, just fed from Room3DView's
# own state instead of a 2D panel's.
func _wall_ceiling_height_m(edge: String, col: int) -> float:
	if not _apt_floor or _apt_floor.sloped_ceiling.is_empty():
		return WALL_H_M
	var sc: Dictionary = _apt_floor.sloped_ceiling
	var axis: String  = sc.get("axis", "x") as String
	var low_s: int    = sc.get("low_start", 0) as int
	var high_e: int   = sc.get("high_end", 0) as int
	var min_h: float  = sc.get("min_h", 1.8) as float
	var max_h: float  = sc.get("max_h", 2.4) as float
	var span := high_e - low_s
	if span <= 0:
		return max_h
	var bounds := _room_bounds
	var progressive := (axis == "x" and edge in ["north", "south"]) \
		or (axis == "y" and edge in ["east", "west"])
	var coord: int
	if progressive:
		coord = (bounds.position.x if edge in ["north", "south"] else bounds.position.y) + col
	else:
		match edge:
			"north": coord = bounds.position.y
			"south": coord = bounds.position.y + bounds.size.y - 1
			"west":  coord = bounds.position.x
			"east":  coord = bounds.position.x + bounds.size.x - 1
			_:       coord = low_s
	var frac := clampf(float(coord - low_s) / float(span), 0.0, 1.0)
	return min_h + frac * (max_h - min_h)


func _wall_ceiling_cut_tiles(edge: String, col: int) -> int:
	if not _apt_floor or _apt_floor.sloped_ceiling.is_empty():
		return 0
	var avail_tiles := int(round(_wall_ceiling_height_m(edge, col) * 10.0))
	return clampi(WALL_HEIGHT_TILES - avail_tiles, 0, WALL_HEIGHT_TILES)


func _wall_floor_occludes(edge: String, at: Vector2i, iw: int, ih: int) -> bool:
	if not _apt_floor:
		return false
	var item_rect := Rect2i(at.x, at.y, iw, ih)
	for entry in _apt_floor.get_adjacent_furniture(edge):
		var f: Furniture = entry["furniture"]
		var wx: int = entry["wall_x"] as int
		var fdata := _find_furniture_data(_catalog, f.furniture_id)
		if fdata.is_empty():
			continue
		var item_w: int = (f.grid_w if edge in ["north", "south"] else f.grid_h)
		var wall_h: int = fdata.get("wall_h", 5) as int
		var py_tile: int = WALL_HEIGHT_TILES - wall_h
		var sil := Rect2i(wx, py_tile, item_w, wall_h)
		if sil.intersects(item_rect):
			return true
	return false


# Mirrors WallInspector._wall_fits — restricted zones, sloped-ceiling cut,
# floor-silhouette occlusion, and overlap with other wall items on this edge.
# `ignore_origin` lets a drag-in-progress check against its own new spot
# without also comparing itself (used when the caller hasn't removed the old
# entry yet).
func _can_place_wall_item(edge: String, at: Vector2i, iw: int, ih: int, ignore_origin: Vector2i) -> bool:
	var item_rect := Rect2i(at.x, at.y, iw, ih)
	for zone in _wall_restricted_zones(edge):
		if (zone as Rect2i).intersects(item_rect):
			return false
	if _apt_floor and not _apt_floor.sloped_ceiling.is_empty():
		for tx in range(iw):
			if at.y < _wall_ceiling_cut_tiles(edge, at.x + tx):
				return false
	if _wall_floor_occludes(edge, at, iw, ih):
		return false
	var wall_w := _wall_usable_width(edge)
	if at.x < 0 or at.x + iw > wall_w or at.y < 0 or at.y + ih > WALL_HEIGHT_TILES:
		return false
	if not _apt_floor:
		return true
	var placed := _apt_floor.get_wall_items(edge)
	for tx in range(iw):
		for ty in range(ih):
			var check := Vector2i(at.x + tx, at.y + ty)
			for origin in placed:
				var o := origin as Vector2i
				if o == ignore_origin:
					continue
				var pf := _find_furniture_data(_catalog, placed[origin] as String)
				if pf.is_empty():
					continue
				var pw: int = (pf.get("size", {}) as Dictionary).get("w", 1) as int
				var ph: int = pf.get("wall_h", 1) as int
				if check.x >= o.x and check.x < o.x + pw and check.y >= o.y and check.y < o.y + ph:
					return false
	return true


# Converts a raw ray-hit on a wall plane into a wall-local origin tile,
# clamped/magnetized the same way WallInspector._try_place snaps a click —
# `iw`/`ih` are the item's footprint (ih = wall_h, its mounted height).
func _wall_origin_from_hit(edge: String, along_m: float, height_m: float, iw: int, ih: int, fdata: Dictionary) -> Vector2i:
	var wall_w := _wall_usable_width(edge)
	var x := clampi(int(round(along_m / TILE_M - iw * 0.5)), 0, wall_w - iw)
	if x <= int(Floor.WALL_SNAP):
		x = 0
	elif wall_w - iw - x <= int(Floor.WALL_SNAP):
		x = wall_w - iw
	var pinned: bool = (fdata.get("placement", "") as String) == "floor"
	var y: int
	if pinned:
		y = WALL_HEIGHT_TILES - ih
	else:
		var from_ceiling_m := WALL_H_M - height_m
		y = clampi(int(round(from_ceiling_m / TILE_M - ih * 0.5)), 0, WALL_HEIGHT_TILES - ih)
	return Vector2i(x, y)


# Mirrors _add_wall_item_box's placement math so the buy ghost, drag preview,
# and the final placed mesh all agree on where a wall item sits.
func _wall_item_mesh_transform(edge: String, origin: Vector2i, iw: int, ih: int, depth: int) -> Dictionary:
	var iw_m    := iw * TILE_M
	var ih_m    := ih * TILE_M
	var depth_m := maxf(depth * TILE_M, 0.05)
	var top_from_floor_m := WALL_H_M - origin.y * TILE_M
	var center_y := top_from_floor_m - ih_m * 0.5
	var along    := origin.x * TILE_M + iw_m * 0.5
	var sz: Vector3
	var pos: Vector3
	match edge:
		"north":
			sz  = Vector3(iw_m, ih_m, depth_m)
			pos = Vector3(along, center_y, depth_m * 0.5)
		"south":
			sz  = Vector3(iw_m, ih_m, depth_m)
			pos = Vector3(along, center_y, _room_d_m - depth_m * 0.5)
		"west":
			sz  = Vector3(depth_m, ih_m, iw_m)
			pos = Vector3(depth_m * 0.5, center_y, along)
		_:   # "east"
			sz  = Vector3(depth_m, ih_m, iw_m)
			pos = Vector3(_room_w_m - depth_m * 0.5, center_y, along)
	return {"size": sz, "pos": pos}


func _finish_furniture_drag() -> void:
	_dragging_furniture = false
	var f: Furniture = _drag_target["furniture"]
	var mesh: MeshInstance3D = _drag_target["mesh"]
	var item_size: Vector3 = _drag_target["size"]
	var snap_pos := _apt_floor.snap_to_wall(f, _drag_last_tile) if _apt_floor else _drag_last_tile
	if _apt_floor and _apt_floor.can_place(f, snap_pos):
		_apt_floor.place_furniture(f, snap_pos)
		mesh.position.x = (snap_pos.x - _room_bounds.position.x) * TILE_M + item_size.x * 0.5
		mesh.position.z = (snap_pos.y - _room_bounds.position.y) * TILE_M + item_size.z * 0.5
		furniture_moved.emit(f)
	else:
		mesh.position = _drag_orig_pos
	_drag_target["pos"] = mesh.position
	_drag_target = {}


# A real click (not a camera-drag) on the preview toggles a foldable item
# between its folded and extended shape. For non-foldable items in the
# standalone single-item preview (build_single_item — close_btn.visible is
# only true there, never in the persistent room 3D view mode) there's
# nothing to toggle, so the same "click on empty space" instead acts as a
# click-outside-the-modal dismiss, since this view has no separate
# backdrop/frame to click outside of.
func _on_item_clicked(_vp_pos: Vector2 = Vector2.ZERO) -> void:
	if not _foldable:
		if close_btn.visible:
			closed.emit()
		return
	_fold_auto   = false
	_fold_target = 0.0 if _fold_target > 0.5 else 1.0


# A plain click (no real drag) that landed on a placed foldable furniture
# piece — mousedown already armed a drag the instant it hit the piece (see
# _on_container_input), so this is where a "click" actually gets recognized
# for furniture, matching the 2D top-down view's click-to-fold interaction.
func _click_furniture_no_drag() -> void:
	var entry := _drag_target
	_drag_target = {}
	_dragging_furniture = false
	if entry.is_empty():
		return
	var f: Furniture = entry["furniture"]
	if Furniture.test_mode_active and f.foldable and f.toggle_fold():
		_resize_furniture_entry(entry)


# Re-derives box size/position from a placed Furniture's current grid_w/h
# (which toggle_fold() just changed) using the exact same anchoring formula
# _add_furniture_box used at placement time, then refits its model.
func _resize_furniture_entry(entry: Dictionary) -> void:
	var f: Furniture = entry["furniture"]
	var mesh: MeshInstance3D = entry["mesh"]
	var fdata := _find_furniture_data(_catalog, f.furniture_id)
	var height_m := maxf((fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
	var fw := f.grid_w * TILE_M
	var fd := f.grid_h * TILE_M
	var box_size := Vector3(fw, height_m, fd)
	var pos := Vector3(
		(f.grid_pos.x - _room_bounds.position.x) * TILE_M + fw * 0.5,
		height_m * 0.5,
		(f.grid_pos.y - _room_bounds.position.y) * TILE_M + fd * 0.5)
	(mesh.mesh as BoxMesh).size = box_size
	mesh.position = pos
	# A piece with a distinct "model_extended" (e.g. a sofa bed that should
	# actually become a bed, not just a stretched sofa) needs the whole model
	# swapped for the new fold state, not just rescaled — _refit_item_model
	# alone would keep showing the folded model at the extended size.
	_apply_item_model(mesh, _active_model_path(fdata, f.is_extended), box_size, fdata.get("hide_nodes", []) as Array)
	entry["size"] = box_size
	entry["pos"]  = pos


# Picks which .glb represents a piece for its current fold state — most
# foldable items just rescale their one model between sizes, but a piece can
# opt into a second, distinct model for its extended state via "model_extended"
# (e.g. a sofa bed that should become an actual bed shape, not a bigger sofa).
func _active_model_path(fdata: Dictionary, is_extended: bool) -> String:
	if is_extended:
		var ext := fdata.get("model_extended", "") as String
		if not ext.is_empty():
			return ext
	return fdata.get("model", "") as String


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
	_cam_flat_dir = flat
	for wd in _wall_data:
		var normal: Vector3 = wd["normal"]
		var wall_mat: StandardMaterial3D = wd["mat"]
		var base: Color = wd["base"]
		# Positive dot = camera is on the outside of this wall, looking in —
		# that's the wall we need to hide.
		var facing := clampf(normal.dot(flat), 0.0, 1.0)
		var alpha := lerpf(1.0, 0.08, facing)
		wall_mat.albedo_color = Color(base.r, base.g, base.b, alpha)


# `catalog` is the furniture data array (gm.furniture_data["furniture"]).
func build_from_floor(apt_floor: Floor, catalog: Array) -> void:
	_auto_spin = false
	_foldable  = false
	_fold_mesh = null
	for c in build_root.get_children():
		c.queue_free()
	_wall_data.clear()
	_furniture_entries.clear()
	_wall_item_entries.clear()
	_dragging_furniture = false
	_dragging_wall_item = false
	_drag_target = {}
	_drag_wall_target = {}

	_apt_floor = apt_floor
	_catalog   = catalog
	var bounds := apt_floor.get_room_bounds()
	_room_bounds = bounds
	var w := bounds.size.x * TILE_M
	var d := bounds.size.y * TILE_M
	_room_w_m = w
	_room_d_m = d

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
			_add_wall_item_box(edge, origin as Vector2i, items[origin] as String, catalog)


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
		var item_size := Vector3(fw, height_m, fd)
		var item_mi := _box(item_size, Vector3(0.0, height_m * 0.5, 0.0), col)
		_apply_item_model(item_mi, fdata.get("model", "") as String, item_size, fdata.get("hide_nodes", []) as Array)

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


# Swaps a placeholder box's own surface for a real model (Kenney Furniture
# Kit, CC0 — see assets/models/furniture/LICENSE.txt), scaled uniformly so it
# never exceeds the box on any axis and grounded/centered inside it. `mi`
# keeps its existing transform/size as the pick/drag/fold anchor the rest of
# this script already relies on — only its own mesh surface is removed, the
# model renders as a child instead. No-op (box stays visible) if the item has
# no "model" entry or the file can't be loaded.
func _apply_item_model(mi: MeshInstance3D, model_path: String, box_size: Vector3, hide_nodes: Array = []) -> void:
	# Clear a previously-applied model (re-fit case, e.g. re-running this on
	# an already-modeled drag ghost) before possibly adding a fresh one.
	if mi.has_meta("model_inst"):
		var old_inst: Node = mi.get_meta("model_inst")
		if old_inst and is_instance_valid(old_inst):
			old_inst.queue_free()
		mi.set_meta("model_inst", null)

	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		return
	var packed := load(model_path) as PackedScene
	if not packed:
		return
	var inst := packed.instantiate() as Node3D
	if not inst:
		return
	var native := _node_aabb(inst)
	if native.size.x <= 0.0001 or native.size.y <= 0.0001 or native.size.z <= 0.0001:
		inst.queue_free()
		return
	# Keep the placeholder box as the mesh (some callers keep resizing it every
	# frame while dragging) but make it invisible — the model renders instead.
	var mat := mi.material_override as StandardMaterial3D
	if mat:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.0
	mi.add_child(inst)
	# Some shared models cover more than one item (e.g. the bunk-bed model
	# doubles as the Loft Bed) — a piece can list child node names to hide so
	# it reads as a distinct silhouette without needing its own separate file.
	for node_name in hide_nodes:
		var n := inst.find_child(node_name as String, true, false)
		if n is Node3D:
			(n as Node3D).visible = false
	mi.set_meta("model_inst", inst)
	mi.set_meta("model_native", native)
	_refit_item_model(mi, box_size)


# Cheap per-frame rescale of an already-instantiated model (used while a drag
# ghost is resizing, e.g. swapping between floor and wall placement) — avoids
# reloading/reinstantiating the whole .glb every frame.
func _refit_item_model(mi: MeshInstance3D, box_size: Vector3) -> void:
	if not mi.has_meta("model_inst"):
		return
	var inst: Node3D = mi.get_meta("model_inst")
	if not inst or not is_instance_valid(inst):
		return
	var native: AABB = mi.get_meta("model_native")
	var fit_scale := minf(minf(box_size.x / native.size.x, box_size.y / native.size.y), box_size.z / native.size.z)
	inst.scale = Vector3.ONE * fit_scale
	inst.position = Vector3(
		-(native.position.x + native.size.x * 0.5) * fit_scale,
		-box_size.y * 0.5 - native.position.y * fit_scale,
		-(native.position.z + native.size.z * 0.5) * fit_scale)


func _node_aabb(node: Node3D) -> AABB:
	var result := AABB()
	var first := true
	# Most Kenney models put their mesh directly on the root node passed in
	# here, with no children at all — must be checked explicitly, since the
	# loop below only walks node.get_children().
	if node is MeshInstance3D:
		var own_mesh: Mesh = (node as MeshInstance3D).mesh
		if own_mesh:
			result = node.transform * own_mesh.get_aabb()
			first = false
	for child in node.get_children():
		if child is MeshInstance3D:
			var mesh: Mesh = (child as MeshInstance3D).mesh
			if mesh:
				var aabb: AABB = (child as MeshInstance3D).transform * mesh.get_aabb()
				result = aabb if first else result.merge(aabb)
				first = false
		if child is Node3D:
			var sub := _node_aabb(child as Node3D)
			if sub.size != Vector3.ZERO:
				sub = (child as Node3D).transform * sub
				result = sub if first else result.merge(sub)
				first = false
	return result


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
			var rail_size := Vector3(TILE_M, RAIL_H_M, RAIL_THICK_M) if horizontal \
				else Vector3(RAIL_THICK_M, RAIL_H_M, TILE_M)
			_box(rail_size, center + Vector3(0.0, RAIL_H_M * 0.5, 0.0), rail_col)


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
	var box_size := Vector3(fw, height_m, fd)
	var pos  := Vector3(local_x, height_m * 0.5, local_z)
	var mi   := _box(box_size, pos, col)
	_apply_item_model(mi, _active_model_path(fdata, f.is_extended), box_size, fdata.get("hide_nodes", []) as Array)
	_furniture_entries.append({"furniture": f, "mesh": mi, "pos": pos, "size": box_size})


# `origin` is wall-local: origin.x along the wall, origin.y from the TOP of
# the wall (0 = ceiling, WALL_TILES = floor) — matches WallInspector.
func _add_wall_item_box(edge: String, origin: Vector2i, fid: String, catalog: Array) -> void:
	var fdata := _find_furniture_data(catalog, fid)
	if fdata.is_empty():
		return
	var iw: int    = (fdata.get("size", {}) as Dictionary).get("w", 5) as int
	var ih: int    = fdata.get("wall_h", 5) as int
	var depth: int = fdata.get("floor_depth", 1) as int
	var col := Color("#" + (fdata.get("color", "888888") as String))
	var xf := _wall_item_mesh_transform(edge, origin, iw, ih, depth)
	var mi := _box(xf["size"], xf["pos"], col)
	_apply_item_model(mi, fdata.get("model", "") as String, xf["size"], fdata.get("hide_nodes", []) as Array)
	_wall_item_entries.append({"edge": edge, "origin": origin, "fid": fid, "mesh": mi, "size": xf["size"]})
