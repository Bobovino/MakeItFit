class_name RoomLighting
extends Node3D

# Where the light in an apartment comes from: by day the sun, only through
# the windows; by night the lamps. Built by Room3DView under its build_root
# (so a rebuild frees it) once the walls and furniture are in.
#
#   - The visible walls are cut down toward the camera, so they can't be what
#     stops the sun. Each wall gets a full-height twin that only casts shadow,
#     with its window openings left out, plus a shadow-only ceiling over the
#     whole apartment. The sun comes in the way the plan's beams do
#     (Floor.sun_dir: through the outside wall with the most window, a
#     little from the side), low, so it lays patches of light on the floor.
#     An apartment with no window gets no sun at all.
#   - At night each lamp (LAMP_IDS) lights a warm pool around itself, fading
#     in with StyleController.night.
#   - Every floor piece sits on a soft contact shadow, which is what keeps it
#     reading as standing on the floor under soft indoor light.
#
# Lamps and contact shadows follow their pieces as they are dragged, bought
# and sold.

const LAMP_IDS: Array[String] = Floor.LAMP_IDS
const LAMP_COLOR := Color(1.0, 0.78, 0.52)
const LAMP_ENERGY := 2.2
const LAMP_RANGE := 3.2
const SUN_ELEVATION_DEG := 34.0
const SUN_SIDE_DEG := 14.0          # turned off the wall's normal, so patches aren't square-on
const SHADOW_MARGIN := 1.15          # contact shadow size relative to the footprint
const SHADOW_LIFT := 0.006           # above the floor, against z-fighting

var view: Room3DView
var _casters: Node3D
var _wall_ids: Array = []            # wall mesh instance ids the casters were built from
var _shadows: Dictionary = {}        # piece mesh instance id -> {target, blob, half_h}
var _lamps: Dictionary = {}          # piece mesh instance id -> {target, light, top}
var _shadow_mat: StandardMaterial3D


func _init(room_view: Room3DView) -> void:
	view = room_view
	name = "RoomLighting"


func _ready() -> void:
	_shadow_mat = _make_shadow_material()
	_build_casters()


func _process(_delta: float) -> void:
	if _walls_changed():
		_build_casters()
	_sync_pieces()


# ── Sunlight through the windows ─────────────────────────────────────────────

# Each wall by its mesh and how many parts it has: its windows' glass is
# dressed on after the wall is built, and the openings are cut from that.
func _wall_key(wd: Dictionary) -> Array:
	var mi = wd["mesh"]
	if not is_instance_valid(mi):
		return [0, 0]
	return [(mi as Object).get_instance_id(), (mi as Node).get_child_count()]


func _walls_changed() -> bool:
	var ids: Array = []
	for wd in view._wall_data:
		ids.append(_wall_key(wd))
	return ids != _wall_ids


func _build_casters() -> void:
	if is_instance_valid(_casters):
		_casters.queue_free()
	_casters = Node3D.new()
	_casters.name = "SunBlockers"
	add_child(_casters)
	_wall_ids.clear()
	var best_window := 0.0
	var sun_in := Vector3.ZERO
	var top := 0.0
	for wd in view._wall_data:
		_wall_ids.append(_wall_key(wd))
		var wall := wd["mesh"] as MeshInstance3D
		# Glass walls let the light through; a balcony wall rebuilt with a
		# hole in it (a CSG node, not a mesh) keeps casting its own shadow.
		if wall == null or wall.mesh == null or wd.get("role", &"") == StyleController.ROLE_GLASS_WALL:
			continue
		wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Nor its glass and frames: the twin stands for the whole wall, and a
		# pane casting shadow kept the sun out of every window.
		for part in wall.get_children():
			if part is GeometryInstance3D:
				(part as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var box := wall.mesh.get_aabb()
		var full_h: float = wd.get("full_h", box.size.y)
		top = maxf(top, full_h)
		var windows := _windows_of(wall, full_h)
		var frame := wall.global_transform.orthonormalized()
		var z_mid := box.position.z + box.size.z * 0.5
		for r in _solid_parts(box.position.x, box.end.x, full_h, windows):
			_add_caster(frame * Vector3((r[0] + r[1]) * 0.5, (r[2] + r[3]) * 0.5, z_mid),
				frame.basis, Vector3(r[1] - r[0], r[3] - r[2], box.size.z))
		if not wd.get("interior", false):
			var width := 0.0
			for w in windows:
				width += w[1] - w[0]
			if width > best_window:
				best_window = width
				sun_in = -(wd["normal"] as Vector3)
	var w: float = view._room_w_m
	var d: float = view._room_d_m
	var root := view.build_root.global_transform
	_add_caster(root * Vector3(w * 0.5, top + 0.04, d * 0.5), root.basis, Vector3(w + 0.6, 0.08, d + 0.6))
	# The same sun as the plan's beams (Floor.sun_dir), so light falls in
	# the same places in both views.
	var fl: Floor = view._apt_floor
	if fl != null and fl.sun_dir != Vector2.ZERO:
		_aim_sun((root.basis * Vector3(fl.sun_dir.x, 0.0, fl.sun_dir.y)).normalized(), false)
	elif best_window > 0.0:
		_aim_sun(sun_in)


# Window openings on a wall, in its own space: [x0, x1, y0, y1]. Read from the
# glass panes Room3DView dresses the wall with (both faces carry one; the
# short mark drawn on a lowered wall's cut face is not an opening).
func _windows_of(wall: MeshInstance3D, top: float = INF) -> Array:
	var out: Array = []
	for part in wall.get_children():
		if not (part is MeshInstance3D) or part.get_meta("wall_part_role", &"") != StyleController.ROLE_WINDOW:
			continue
		var size := ((part as MeshInstance3D).mesh as BoxMesh).size
		if size.y < 0.3:
			continue
		var p: Vector3 = (part as Node3D).position
		var r := [p.x - size.x * 0.5, p.x + size.x * 0.5, p.y - size.y * 0.5, p.y + size.y * 0.5]
		if r[2] >= top - 0.01:
			continue   # glass above the wall's own top (a cut wall's upper storey), not an opening in it
		if not out.any(func(o: Array) -> bool: return absf(o[0] - r[0]) < 0.01):
			out.append(r)
	out.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	return out


# The wall from x0 to x1 and 0 to `h`, less its windows, as solid rectangles.
func _solid_parts(x0: float, x1: float, h: float, windows: Array) -> Array:
	var out: Array = []
	var cur := x0
	for w in windows:
		out.append([cur, w[0], 0.0, h])
		out.append([w[0], w[1], 0.0, w[2]])
		out.append([w[0], w[1], w[3], h])
		cur = w[1]
	out.append([cur, x1, 0.0, h])
	return out.filter(func(r: Array) -> bool: return r[1] - r[0] > 0.005 and r[3] - r[2] > 0.005)


func _add_caster(pos: Vector3, basis: Basis, size: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	_casters.add_child(mi)
	mi.global_transform = Transform3D(basis, pos)


func _aim_sun(into_room: Vector3, turn := true) -> void:
	var flat := into_room.rotated(Vector3.UP, deg_to_rad(SUN_SIDE_DEG)) if turn else into_room
	var elev := deg_to_rad(SUN_ELEVATION_DEG)
	var dir := (flat * cos(elev) + Vector3.DOWN * sin(elev)).normalized()
	view._sun.global_transform = Transform3D(Basis.looking_at(dir, Vector3.UP), view._sun.global_position)


# ── Lamps and contact shadows ────────────────────────────────────────────────

func _sync_pieces() -> void:
	var seen := {}
	for e in view._furniture_entries:
		var mi := e["mesh"] as Node3D
		if not is_instance_valid(mi):
			continue
		var id := mi.get_instance_id()
		seen[id] = true
		if not _shadows.has(id):
			_shadows[id] = _new_shadow(mi, e["size"] as Vector3)
		var f := e["furniture"] as Furniture
		if not _lamps.has(id) and f != null and f.furniture_id in LAMP_IDS:
			_lamps[id] = _new_lamp(mi, e["size"] as Vector3)
	for table in [_shadows, _lamps]:
		for id in table.keys():
			if not seen.has(id):
				(table[id]["node"] as Node).queue_free()
				table.erase(id)
	for id in _shadows:
		var s: Dictionary = _shadows[id]
		var mi := s["target"] as Node3D
		var blob := s["node"] as MeshInstance3D
		blob.visible = mi.is_visible_in_tree()
		var at := mi.global_position - Vector3(0, s["half_h"] as float - SHADOW_LIFT, 0)
		blob.global_transform = Transform3D(Basis(Vector3.UP, mi.global_rotation.y), at)
	var night: float = view._style.night if view._style != null else 0.0
	for id in _lamps:
		var l: Dictionary = _lamps[id]
		var mi := l["target"] as Node3D
		var light := l["node"] as OmniLight3D
		light.visible = night > 0.01 and mi.is_visible_in_tree()
		light.light_energy = LAMP_ENERGY * night
		light.global_position = mi.global_position + Vector3(0, l["top"] as float, 0)


# `size` is the piece's footprint box after its rotation; the blob is laid out
# in the piece's own frame, so it takes the unrotated one.
func _new_shadow(mi: Node3D, size: Vector3) -> Dictionary:
	var turned := absf(sin(mi.global_rotation.y)) > 0.7
	var foot := Vector2(size.z, size.x) if turned else Vector2(size.x, size.z)
	var quad := QuadMesh.new()
	quad.orientation = PlaneMesh.FACE_Y
	quad.size = foot * SHADOW_MARGIN + Vector2(0.08, 0.08)
	var blob := MeshInstance3D.new()
	blob.mesh = quad
	blob.material_override = _shadow_mat
	blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(blob)
	return {"target": mi, "node": blob, "half_h": size.y * 0.5}


func _new_lamp(mi: Node3D, size: Vector3) -> Dictionary:
	var light := OmniLight3D.new()
	light.light_color = LAMP_COLOR
	light.omni_range = LAMP_RANGE
	light.omni_attenuation = 1.4
	light.light_specular = 0.0
	light.shadow_enabled = false
	light.visible = false
	add_child(light)
	return {"target": mi, "node": light, "top": size.y * 0.5 + 0.12}


func _make_shadow_material() -> StandardMaterial3D:
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0.55))
	g.set_color(1, Color(0, 0, 0, 0.0))
	g.add_point(0.55, Color(0, 0, 0, 0.42))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_SQUARE
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = tex
	mat.albedo_color = Color(0.08, 0.07, 0.12)
	return mat
