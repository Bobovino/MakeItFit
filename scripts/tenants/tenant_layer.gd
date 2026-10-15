extends Node
class_name TenantLayer

# The household living in the apartment on screen. Purely cosmetic: it reads
# the floor and what the checker last computed, and never writes to either,
# so it can't change whether a level is solved (tests/run_tests.gd checks
# that). Its randomness has its own generator and touches nothing else.
#
#   - The residents of the level's TenantApplication stand on the floor, a
#     token each in the plan and a figure each in the 3D view. Levels without
#     an application have nobody, and so does the inside of a box seen from
#     the apartment around it: only the level on screen is lived in.
#   - While a piece is held (dragged, or being bought), they step out of
#     sight. After every placement each one hops to a random free spot they
#     could walk to; with none, to the level's anchor tile.
#   - When a placement breaks a requirement that was met just before it, the
#     resident who asked for it gets annoyed: a speech bubble with that
#     requirement's icon and, when the checker knows what is in the way, an
#     ink line from that piece to them. One reaction at a time; a new
#     placement replaces it.

const REACTION_TIME := 2.8
const PATCH := Floor.WALK_WIDTH            # a resident stands on a PATCH x PATCH patch of floor
const HOP_TIME := 0.5                       # the hop to a new spot, before anyone reacts

var main: Node                              # Main (no class_name)
var gm: GameManager
var card: TenantCard

var _app: TenantApplication
var _floor: Floor
var _view3d: Room3DView
var _rng := RandomNumberGenerator.new()
var _tiles: Dictionary = {}                 # resident id -> Vector2 (top-left tile of their patch)
var _tokens: Dictionary = {}                # resident id -> TenantToken2D
var _pawns: Dictionary = {}                 # resident id -> TenantPawn3D
var _pawn_root: Node3D
var _status: Dictionary = {}                # requirement id -> met, as of the last placement
var _layout: Dictionary = {}                # furniture instance id -> where/how it stood
var _placing := false
var _started_frame := -1
var _reaction_gen := 0
var _link2d: Line2D
var _link3d: Node3D
var _seen_bounds := Rect2i()
var _commit_pending := false


func _ready() -> void:
	_rng.randomize()


# (Re)populates the floor on screen: on level load, a floor switch, entering
# or leaving a box. `app` null clears everyone.
func start(app: TenantApplication, apt_floor: Floor, view3d: Room3DView) -> void:
	stop()
	_app = app
	_floor = apt_floor
	if _app == null or _floor == null or _app.residents.is_empty():
		return
	_started_frame = Engine.get_process_frames()
	for r in _app.residents:
		var token := TenantToken2D.new()
		token.setup(r, _tint(r))
		_floor.add_child(token)
		_tokens[r.id] = token
	attach_3d(view3d)
	_snapshot()
	_scatter(true)


func stop() -> void:
	_clear_reaction()
	for t in _tokens.values():
		if is_instance_valid(t):
			(t as Node).queue_free()
	_tokens.clear()
	_tiles.clear()
	attach_3d(null)
	_app = null
	_floor = null


# The 3D view is built and freed as the player switches views.
func attach_3d(view3d: Room3DView) -> void:
	for p in _pawns.values():
		if is_instance_valid(p):
			(p as Node).queue_free()
	_pawns.clear()
	if is_instance_valid(_pawn_root):
		_pawn_root.queue_free()
	_pawn_root = null
	_view3d = view3d
	if _view3d == null or _app == null:
		return
	_pawn_root = Node3D.new()
	_pawn_root.name = "Tenants"
	_view3d.build_root.get_parent().add_child(_pawn_root)
	for r in _app.residents:
		var pawn := TenantPawn3D.new()
		pawn.setup(r, _tint(r), _view3d.cam)
		_pawn_root.add_child(pawn)
		_pawns[r.id] = pawn
	_place_pawns(false)


# After a placement. Runs at the end of the frame, once the checker has
# caught up, and only once however many commit signals the frame fired (one
# drop can fire several; so does selling a few pieces at once).
func request_commit() -> void:
	if not _commit_pending:
		_commit_pending = true
		commit.call_deferred()


func commit() -> void:
	_commit_pending = false
	if _app == null or Engine.get_process_frames() == _started_frame:
		return
	var moved := _changed_piece()
	var before := _status
	_status = Requirements.status(gm)
	_clear_reaction()
	_scatter(true)
	var req := _pick_violation(before, _status)
	if req == "":
		return
	_reaction_gen += 1
	var gen := _reaction_gen
	var cause := _cause_of(req, moved)
	await get_tree().create_timer(HOP_TIME).timeout
	if gen != _reaction_gen or _app == null or _placing:
		return
	_react(req, cause)


# Undo/redo, a moment switch: the layout changed but nobody placed anything.
func resync() -> void:
	if _app == null:
		return
	_clear_reaction()
	_snapshot()
	_scatter(true)


func _process(_delta: float) -> void:
	if _app == null:
		return
	var placing: bool = main.is_placing_furniture()
	if placing != _placing:
		_placing = placing
		if placing:
			_clear_reaction()
		for t in _tokens.values():
			(t as TenantToken2D).set_present(not placing)
		for p in _pawns.values():
			(p as TenantPawn3D).set_present(not placing)
	if is_instance_valid(_view3d) and _view3d._room_bounds != _seen_bounds:
		_place_pawns(false)


# ── where everyone stands ────────────────────────────────────────────────────

func _scatter(animate: bool) -> void:
	var spots := _free_spots()
	_shuffle(spots)
	var taken: Array = []
	for r in _app.residents:
		var spot := Vector2(-1, -1)
		for s in spots:
			var v := s as Vector2
			if taken.all(func(o): return absf((o as Vector2).x - v.x) >= PATCH or absf((o as Vector2).y - v.y) >= PATCH):
				spot = v
				break
		if spot.x < 0:
			spot = _anchor() + Vector2(taken.size() % 2, taken.size() / 2) * PATCH
		taken.append(spot)
		_tiles[r.id] = spot
		(_tokens[r.id] as TenantToken2D).place(spot, animate)
	_place_pawns(animate)


# Patches of floor a resident could stand on: walked to from the door when
# the floor has one, else simply free (an upper floor reached by stairs).
func _free_spots() -> Array:
	var reached := _floor.get_reachable_floor()
	var ok: Callable = func(t: Vector2i) -> bool: return reached.has(t)
	if reached.is_empty():
		ok = func(t: Vector2i) -> bool: return _tile_free(t)
	var out: Array = []
	var b := _floor.get_room_bounds()
	# Every other tile is plenty of choice, at a quarter of the work (this runs
	# after every placement, on phones too).
	for y in range(b.position.y, b.end.y - PATCH + 1, 2):
		for x in range(b.position.x, b.end.x - PATCH + 1, 2):
			var fits := true
			for dy in PATCH:
				for dx in PATCH:
					if not ok.call(Vector2i(x + dx, y + dy)):
						fits = false
						break
				if not fits:
					break
			if fits:
				out.append(Vector2(x, y))
	return out


func _tile_free(t: Vector2i) -> bool:
	if not _floor.is_floor_tile(t):
		return false
	for f in _floor._placed_list(t):
		if _floor.blocks_walking(f as Furniture):
			return false
	return true


func _anchor() -> Vector2:
	if _app.anchor_tile.x >= 0:
		return Vector2(_app.anchor_tile)
	var b := _floor.get_room_bounds()
	return Vector2(b.get_center()) - Vector2(PATCH, PATCH) * 0.5


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp = a[i]
		a[i] = a[j]
		a[j] = tmp


func _place_pawns(animate: bool) -> void:
	if not is_instance_valid(_view3d) or not is_instance_valid(_pawn_root):
		return
	_seen_bounds = _view3d._room_bounds
	_pawn_root.transform = _view3d.build_root.transform
	for rid in _pawns:
		if _tiles.has(rid):
			(_pawns[rid] as TenantPawn3D).place(_tile_to_3d(_tiles[rid] + Vector2(PATCH, PATCH) * 0.5), animate)


func _tile_to_3d(t: Vector2) -> Vector3:
	var rb := _view3d._room_bounds
	return Vector3((t.x - rb.position.x) * Room3DView.TILE_M, 0.0, (t.y - rb.position.y) * Room3DView.TILE_M)


# ── what changed, what broke, and why ───────────────────────────────────────

func _snapshot() -> void:
	_status = Requirements.status(gm)
	_changed_piece()


# The piece the last placement moved, folded or added (null for a sale).
func _changed_piece() -> Furniture:
	var now := {}
	var latest: Furniture = null
	for entry in _floor.get_all_furniture():
		var f := entry as Furniture
		var sig := "%s|%s|%d|%d" % [f.grid_pos, f.is_extended, f.grid_w, f.grid_h]
		now[f.get_instance_id()] = sig
		if _layout.get(f.get_instance_id(), "") != sig:
			latest = f
	_layout = now
	return latest


# The requirement this placement broke, if any: met before, not met now.
# Lines of sight and zones first (they have something in the way to point
# at), and never one the tenant hasn't mentioned yet (hidden).
func _pick_violation(before: Dictionary, now: Dictionary) -> String:
	var broken: Array = []
	for id in now:
		var rid := id as String
		if rid.begins_with("moment:") or not before.get(rid, false) or now[rid]:
			continue
		if card.is_hidden_requirement(rid):
			continue
		broken.append(rid)
	if broken.is_empty():
		return ""
	for kind in ["sight:", "zones:", "need:"]:
		for rid in broken:
			if (rid as String).begins_with(kind):
				return rid
	return broken[0]


func _cause_of(req: String, moved: Furniture) -> Furniture:
	if req.begins_with("sight:"):
		var i := int(req.split(":")[1]) - 1
		if i < gm.sightline_status.size():
			var st := gm.sightline_status[i] as Dictionary
			if st.get("must_be_clear", true) and st.get("block") != null:
				for f in _floor._placed_list(st["block"] as Vector2i):
					if (f as Furniture).blocks_sight():
						return f
				return null   # a wall is in the way, not a piece
	if moved == null or not is_instance_valid(moved) or moved not in _floor.get_all_furniture():
		return null
	# A bed that lost its sleep to noise: the noisy neighbour is to blame.
	if moved.needs_quiet and moved._noise_muted:
		var best: Furniture = null
		for entry in _floor.get_all_furniture():
			var f := entry as Furniture
			if f.is_noisy and (best == null or _center(f).distance_to(_center(moved)) < _center(best).distance_to(_center(moved))):
				best = f
		if best:
			return best
	return moved


func _who_minds(req: String, cause: Furniture) -> StringName:
	var line := _app.line_for(req)
	if line:
		if line.speaker != &"" and _tokens.has(line.speaker):
			return line.speaker
		for o in line.owners:
			if _tokens.has(o):
				return o
	# Nobody in particular: whoever stands closest to the trouble.
	var best: StringName = _app.residents[0].id
	if cause:
		var d := INF
		for rid in _tiles:
			var dist := (_tiles[rid] as Vector2 + Vector2(2, 2)).distance_to(_center(cause))
			if dist < d:
				d = dist
				best = rid
	return best


func _center(f: Furniture) -> Vector2:
	return f.grid_pos + Vector2(f.grid_w, f.grid_h) * 0.5


# ── the reaction ─────────────────────────────────────────────────────────────

func _react(req: String, cause: Furniture) -> void:
	var rid := _who_minds(req, cause)
	var token := _tokens.get(rid) as TenantToken2D
	if token:
		token.react(req, TenantBubble.Mood.ANNOYED)
	var pawn := _pawns.get(rid) as TenantPawn3D
	if pawn:
		pawn.react(req, TenantBubble.Mood.ANNOYED)
	card.flash_requirement(req)
	if cause and is_instance_valid(cause):
		if token:
			_draw_link_2d(_center(cause) * Floor.TILE_SIZE, token.position)
		if pawn and is_instance_valid(_pawn_root):
			_draw_link_3d(cause, pawn)
	var gen := _reaction_gen
	await get_tree().create_timer(REACTION_TIME).timeout
	if gen == _reaction_gen:
		_clear_reaction()


func _clear_reaction() -> void:
	_reaction_gen += 1
	for t in _tokens.values():
		if is_instance_valid(t):
			(t as TenantToken2D).clear_reaction()
	for p in _pawns.values():
		if is_instance_valid(p):
			(p as TenantPawn3D).clear_reaction()
	if is_instance_valid(_link2d):
		_link2d.queue_free()
	if is_instance_valid(_link3d):
		_link3d.queue_free()
	_link2d = null
	_link3d = null


func _draw_link_2d(from: Vector2, to: Vector2) -> void:
	_link2d = Line2D.new()
	var s := _floor.get_global_transform_with_canvas().get_scale().x
	_link2d.width = 3.0 / maxf(s, 0.01)
	_link2d.default_color = Color(FaxStyle.STAMP_INK, 0.9)
	_link2d.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_link2d.end_cap_mode = Line2D.LINE_CAP_ROUND
	_link2d.z_index = 25
	# A short gap at each end, so it points from the piece to the tenant
	# rather than running through them.
	var dir := (to - from).normalized()
	var a := from + dir * Floor.TILE_SIZE * 1.0
	var b := to - dir * Floor.TILE_SIZE * 2.4
	_link2d.points = PackedVector2Array([a, a])
	_floor.add_child(_link2d)
	if GameState.reduce_motion:
		_link2d.points = PackedVector2Array([a, b])
		return
	var line := _link2d
	var tw := line.create_tween()
	tw.tween_method(func(k: float): line.points = PackedVector2Array([a, a.lerp(b, k)]), 0.0, 1.0, 0.25)


func _draw_link_3d(cause: Furniture, pawn: TenantPawn3D) -> void:
	var c := _center(cause)
	var top := maxf(cause.z_top, 4.0) * Room3DView.TILE_M
	var a := _pawn_root.to_global(_tile_to_3d(c)) + Vector3(0, top, 0)
	var b := pawn.head_point()
	var link := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.04, 0.04, maxf(a.distance_to(b) - 0.25, 0.05))
	link.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = FaxStyle.STAMP_INK
	mat.no_depth_test = true
	mat.render_priority = 5
	link.material_override = mat
	_pawn_root.add_child(link)
	link.global_position = (a + b) * 0.5
	link.look_at_from_position(link.global_position, b, Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.FORWARD)
	# A dot on the piece it starts from.
	var dot := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.06
	sm.height = 0.12
	dot.mesh = sm
	dot.material_override = mat
	link.add_child(dot)
	dot.global_position = a
	_link3d = link


# Each resident keeps one colour, whatever the language or the session.
func _tint(r: TenantResident) -> Color:
	var hue := float(absi(("%s/%s" % [_app.level_id, r.id]).hash()) % 360) / 360.0
	return Color.from_hsv(hue, 0.5, 0.88)
