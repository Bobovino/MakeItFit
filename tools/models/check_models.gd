extends SceneTree

# Checks furniture models against the catalogue and the drawn-style rules
# (see style_models.gd). Run from the project, after importing:
#
#   godot --headless --path . -s res://tools/models/check_models.gd -- [--dir=<folder>] [id ...]
#
# --dir defaults to res://assets/models/furniture/styletest; with no ids it
# checks every .glb there that has a catalogue entry. Prints one block per
# model and a summary; exits with 1 if any model has an error.
#
# Errors (the game would show it wrong):
#   - footprint not the catalogue's (10 cm a tile, X by Z), by more than 2 cm
#   - not standing on y = 0, or not centred on the footprint
#   - height outside the third either way the game allows before it stretches
#   - a folding piece without an "open" clip, or whose open pose doesn't fill
#     its open footprint (size.h + extended_add_h)
#   - a material not named C_<rrggbb> or M_<name>
#   - a part between 5 mm and 2 cm thin (a sliver: inked as dots), or one
#     whose longest side is under 4 cm (a speck); 5 mm or less is a flat
#     decal (a mirror, a stripe of colour) and is fine
# Warnings (worth a look):
#   - neighbouring faces bending between 25 and 55 degrees: neither smooth
#     (no line) nor a clear corner (a line), so the ink comes and goes
#   - open borders or faces wound the wrong way round

const DEFAULT_DIR := "res://assets/models/furniture/styletest"
const TILE := 0.1
const FIT_TOL := 0.02
const HEIGHT_GIVE := 1.35      # Room3DView.MODEL_HEIGHT_GIVE
const DECAL_M := 0.005
const MIN_THICK_M := 0.02
const MIN_LONG_M := 0.04
const WELD := 1e-4

var _errors := 0


func _initialize() -> void:
	var dir := DEFAULT_DIR
	var ids: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			dir = a.substr(6).trim_suffix("/")
		else:
			ids.append(a)
	var catalog := {}
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/furniture.json"))
	for it in data["furniture"]:
		catalog[it["id"]] = it
	if ids.is_empty():
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".glb") and catalog.has(f.get_basename()):
				ids.append(f.get_basename())
	var bad := 0
	for id in ids:
		var path := "%s/%s.glb" % [dir, id]
		if not catalog.has(id):
			print("%s: not in the catalogue" % id)
			bad += 1
			continue
		if not ResourceLoader.exists(path):
			print("%s: no model at %s (imported?)" % [id, path])
			bad += 1
			continue
		if not _check(id, path, catalog[id]):
			bad += 1
	print("\n%d checked, %d with errors" % [ids.size(), bad])
	quit(1 if bad > 0 else 0)


func _check(id: String, path: String, fdata: Dictionary) -> bool:
	var errors: Array = []
	var warnings: Array = []
	var inst := (load(path) as PackedScene).instantiate() as Node3D
	var size: Dictionary = fdata.get("size", {})
	var want := Vector3((size.get("w", 1) as float) * TILE, (fdata.get("wall_h", 8) as float) * TILE, (size.get("h", 1) as float) * TILE)
	var animated := (fdata.get("open_anim", false) as bool) or (fdata.get("pose_open", false) as bool)
	var ap := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if animated:
		if ap == null or not ap.has_animation("open"):
			errors.append("folds, but has no \"open\" clip")
			ap = null
	var closed := _bounds(inst)
	if not (fdata.get("pose_open", false) as bool):
		_check_fit(closed, want, "closed" if animated else "", errors, warnings)
	if animated and ap != null:
		_pose(ap, ap.get_animation("open"))
		var open_box := _bounds(inst)
		var open_want := want
		if not (fdata.get("pose_open", false) as bool):
			open_want.z = ((size.get("h", 1) as float) + (fdata.get("extended_add_h", 0) as float)) * TILE
		# The open footprint grows forward from the closed one's back edge.
		_check_fit(open_box, open_want, "open", errors, warnings, closed.position.z)
	for mi in _meshes(inst):
		_check_mesh(mi as MeshInstance3D, errors, warnings)
	inst.free()
	var verdict := "OK" if errors.is_empty() and warnings.is_empty() else ("ERRORS" if not errors.is_empty() else "warnings")
	print("%s: %s" % [id, verdict])
	for e in errors:
		print("  error: " + str(e))
	for w in warnings:
		print("  warning: " + str(w))
	return errors.is_empty()


func _check_fit(box: AABB, want: Vector3, label: String, errors: Array, warnings: Array, back_z := NAN) -> void:
	var pre := (label + " ") if label != "" else ""
	if absf(box.size.x - want.x) > FIT_TOL or absf(box.size.z - want.z) > FIT_TOL:
		errors.append("%sfootprint %.2f x %.2f m, the catalogue's is %.2f x %.2f" % [pre, box.size.x, box.size.z, want.x, want.z])
	if absf(box.position.y) > 0.01:
		errors.append("%sbottom at y = %.3f, not 0" % [pre, box.position.y])
	if absf(box.get_center().x) > FIT_TOL:
		errors.append("%snot centred on X (centre at %.2f)" % [pre, box.get_center().x])
	if is_nan(back_z):
		if absf(box.get_center().z) > FIT_TOL * 1.5:
			errors.append("%snot centred on Z (centre at %.2f)" % [pre, box.get_center().z])
	elif absf(box.position.z - back_z) > FIT_TOL:
		errors.append("%sdoesn't grow from the closed back edge (%.2f vs %.2f)" % [pre, box.position.z, back_z])
	var ratio := box.size.y / maxf(want.y, 0.001)
	if ratio > HEIGHT_GIVE or ratio < 1.0 / HEIGHT_GIVE:
		errors.append("%sheight %.2f m against the catalogue's %.2f: the game would stretch it" % [pre, box.size.y, want.y])
	elif absf(ratio - 1.0) > 0.05:
		warnings.append("%sheight %.2f m against the catalogue's %.2f" % [pre, box.size.y, want.y])


func _meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(n)
	for c in n.get_children():
		out += _meshes(c)
	return out


# `n`'s transform in `top`'s space (these scenes are never in the tree).
func _xf(n: Node, top: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	while n != null and n != top:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


# Puts every part where `anim` has it on its last frame.
func _pose(ap: AnimationPlayer, anim: Animation) -> void:
	var base := ap.get_node(ap.root_node)
	for t in anim.get_track_count():
		var n := base.get_node_or_null(NodePath(str(anim.track_get_path(t)).get_slice(":", 0))) as Node3D
		if n == null:
			continue
		match anim.track_get_type(t):
			Animation.TYPE_ROTATION_3D:
				n.quaternion = anim.rotation_track_interpolate(t, anim.length)
			Animation.TYPE_POSITION_3D:
				n.position = anim.position_track_interpolate(t, anim.length)
			Animation.TYPE_SCALE_3D:
				n.scale = anim.scale_track_interpolate(t, anim.length)


func _bounds(inst: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in _meshes(inst):
		var b: AABB = _xf(mi, inst) * (mi as MeshInstance3D).mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _check_mesh(mi: MeshInstance3D, errors: Array, warnings: Array) -> void:
	var mesh := mi.mesh
	var name_re := RegEx.create_from_string("^(C_[0-9a-f]{6}|M_[a-z_]+)$")
	var ids := {}
	var points := PackedVector3Array()
	var tris := PackedInt32Array()
	for s in mesh.get_surface_count():
		var mat := mesh.surface_get_material(s)
		var mname := mat.resource_name if mat else "(none)"
		if name_re.search(mname) == null:
			errors.append("%s: material \"%s\" isn't C_<rrggbb> or M_<name>" % [mi.name, mname])
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var index = arrays[Mesh.ARRAY_INDEX]
		var remap := PackedInt32Array()
		remap.resize(verts.size())
		for i in verts.size():
			var v := verts[i]
			var key := Vector3i(roundi(v.x / WELD), roundi(v.y / WELD), roundi(v.z / WELD))
			if not ids.has(key):
				ids[key] = points.size()
				points.append(v)
			remap[i] = ids[key]
		var count: int = (index as PackedInt32Array).size() if index != null else verts.size()
		for t in range(0, count - 2, 3):
			var a := remap[index[t] if index != null else t]
			var b := remap[index[t + 1] if index != null else t + 1]
			var c := remap[index[t + 2] if index != null else t + 2]
			if a != b and b != c and a != c:
				tris.append_array([a, b, c])
	# Parts: triangles joined through shared points.
	var parent := PackedInt32Array()
	parent.resize(points.size())
	for i in points.size():
		parent[i] = i
	for t in range(0, tris.size(), 3):
		_union(parent, tris[t], tris[t + 1])
		_union(parent, tris[t], tris[t + 2])
	var boxes := {}
	for i in points.size():
		var r := _find(parent, i)
		boxes[r] = (boxes[r] as AABB).expand(points[i]) if boxes.has(r) else AABB(points[i], Vector3.ZERO)
	var scale := _xf(mi, mi.owner if mi.owner else mi.get_parent()).basis.get_scale()
	for r in boxes:
		var sz: Vector3 = (boxes[r] as AABB).size * scale
		var dims := [sz.x, sz.y, sz.z]
		dims.sort()
		var where := (boxes[r] as AABB).get_center()
		if dims[0] > DECAL_M and dims[0] < MIN_THICK_M - 0.0005:
			errors.append("%s: a part %.1f cm thin at %s (a sliver)" % [mi.name, dims[0] * 100.0, where.snapped(Vector3.ONE * 0.01)])
		if dims[2] < MIN_LONG_M - 0.0005:
			errors.append("%s: a part only %.1f cm long at %s (a speck)" % [mi.name, dims[2] * 100.0, where.snapped(Vector3.ONE * 0.01)])
	# Edges: bends, open borders, winding.
	var edges := {}   # Vector2i(lo, hi) -> [normal, count, directed a->b seen]
	var ambiguous := 0
	var flipped := 0
	for t in range(0, tris.size(), 3):
		var a := tris[t]
		var b := tris[t + 1]
		var c := tris[t + 2]
		var cr := (points[b] - points[a]).cross(points[c] - points[a])
		if cr.length_squared() < 1e-14:
			continue
		var n := cr.normalized()
		for pair in [[a, b], [b, c], [c, a]]:
			var ek := Vector2i(mini(pair[0], pair[1]), maxi(pair[0], pair[1]))
			var forward: bool = pair[0] < pair[1]
			var e = edges.get(ek)
			if e == null:
				edges[ek] = [n, 1, forward]
			else:
				e[1] += 1
				if e[1] == 2:
					var deg := rad_to_deg(acos(clampf((e[0] as Vector3).dot(n), -1.0, 1.0)))
					if deg > 25.0 and deg < 55.0:
						ambiguous += 1
					if e[2] == forward:
						flipped += 1
	var open := 0
	for ek in edges:
		if edges[ek][1] == 1:
			# A flat decal (water, a mirror sheet) is open by nature.
			var pb: AABB = boxes[_find(parent, (ek as Vector2i).x)]
			if minf(pb.size.x, minf(pb.size.y, pb.size.z)) > DECAL_M:
				open += 1
	if ambiguous > 0:
		warnings.append("%s: %d edges bend 25-55 degrees (the ink comes and goes)" % [mi.name, ambiguous])
	if open > 0:
		warnings.append("%s: %d open border edges" % [mi.name, open])
	if flipped > 0:
		warnings.append("%s: %d edges between faces wound opposite ways" % [mi.name, flipped])


func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[ra] = rb
