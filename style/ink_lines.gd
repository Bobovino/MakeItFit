class_name InkLines
extends RefCounted

# The illustrated look: thin dark ink along every sharp edge of the room's
# furniture and walls (where two faces meet at a bend, and along a model's
# open borders), like a drawing. The lines are found once per mesh, by
# comparing the faces either side of each edge, and kept on the mesh
# resource, so every copy of a model shares them. Each mesh gets them as a
# child, so they move, scale, fold, fade with and are freed with whatever
# they outline; hiding a wall hides its lines.
#
# They're drawn as thin quads widened in screen space (shaders/ink_lines),
# a fixed fraction of the view's height whatever the zoom, and pulled a
# little towards the camera so the face they sit on doesn't cover them.
#
# The Miis are rounded and skinned, so they get a hull outline instead
# (TenantMii); hull_material() gives it the same ink colour.
#
# They're on at every graphics tier: they are the look, not an extra. They
# add one draw call per outlined mesh (about a fifth more in a furnished
# room), the cost to watch on phones.

const SHADER := preload("res://style/shaders/ink_lines.gdshader")
const HULL_SHADER := preload("res://scripts/shaders/tenant_outline.gdshader")
const GROUP := &"ink_lines"
const NODE_NAME := "InkLines"
# Faces meeting at more than this bend get a line between them.
const CREASE_DEG := 40.0
# Vertices this close are the same point (models split them per face).
const WELD := 1e-4
# A separate part of a model smaller than this (a handle, a knob, a book on
# a shelf), in metres along its longest side, gets no lines: inked, every
# small detail turned into a black smudge.
const MIN_PART_M := 0.14
const HULL_WIDTH := 0.008

static var _material: ShaderMaterial
static var _hull: ShaderMaterial
static var _enabled := true


static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
	return _material


static func hull_material() -> ShaderMaterial:
	if _hull == null:
		_hull = ShaderMaterial.new()
		_hull.shader = HULL_SHADER
		_hull.set_shader_parameter("outline_width", HULL_WIDTH if _enabled else 0.0)
		_hull.set_shader_parameter("outline_color", material().get_shader_parameter("ink_color"))
	return _hull


# The ink: a deep shade of the palette's shadow tint, a little see-through,
# so it belongs to the level's colours instead of being a flat black.
static func set_palette(palette: LevelPalette) -> void:
	if palette == null:
		return
	var ink := palette.shadow_tint.darkened(0.5)
	ink.a = 0.8
	material().set_shader_parameter("ink_color", ink)
	var hull := ink.lerp(palette.shadow_tint, 0.25)
	hull.a = 1.0
	hull_material().set_shader_parameter("outline_color", hull)


static func set_enabled(on: bool, tree: SceneTree) -> void:
	_enabled = on
	hull_material().set_shader_parameter("outline_width", HULL_WIDTH if on else 0.0)
	if tree == null:
		return
	for n in tree.get_nodes_in_group(GROUP):
		(n as Node3D).visible = on and not n.get_meta("ink_hidden", false)


static func enabled_for(_quality: int) -> bool:
	return true


# Outlines every mesh under `root` (root included). Calling it again redoes
# them, e.g. after a wall was rebuilt with a hole in it.
static func add_to(root: Node) -> void:
	var targets: Array = []
	_collect(root, targets)
	for mi in targets:
		_outline(mi as MeshInstance3D)


# Hides (or shows again) the ink under `root`, e.g. while a piece is a
# see-through placement ghost.
static func set_hidden(root: Node, hidden: bool) -> void:
	if root.is_in_group(GROUP):
		root.set_meta("ink_hidden", hidden)
		(root as Node3D).visible = _enabled and not hidden
	for c in root.get_children():
		set_hidden(c, hidden)


static func _collect(n: Node, out: Array) -> void:
	if n.is_in_group(GROUP):
		return
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect(c, out)


static func _outline(mi: MeshInstance3D) -> void:
	for c in mi.get_children():
		if c.is_in_group(GROUP):
			mi.remove_child(c)
			c.queue_free()
	if mi.mesh == null or mi.skin != null or (mi.mesh is ArrayMesh and (mi.mesh as ArrayMesh).get_blend_shape_count() > 0):
		return
	# Flat things are markings on a surface (a door's swing on the floor, a
	# pane of glass), not objects: inked, an arc of floor marking turned into
	# a heavy black stroke. Whatever frames them is outlined already.
	var box := mi.mesh.get_aabb()
	if minf(box.size.x, minf(box.size.y, box.size.z)) < 0.002:
		return
	var lines := lines_for(mi.mesh)
	if lines == null:
		return
	var ink := MeshInstance3D.new()
	ink.name = NODE_NAME
	ink.mesh = lines
	ink.material_override = material()
	ink.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ink.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# The lines reach a little past the mesh (half a width): never cull them
	# early at the screen's edge.
	ink.extra_cull_margin = 0.05
	ink.visible = _enabled
	ink.add_to_group(GROUP)
	mi.add_child(ink)


# The line mesh for `mesh` (null when it has no sharp edges), worked out once
# and kept on the mesh.
# A box or other primitive can be resized in place (a placeholder following a
# drag), so its lines are only reused while its bounds stay the same.
static func lines_for(mesh: Mesh) -> ArrayMesh:
	var key := mesh.get_aabb()
	if mesh.has_meta("ink_lines") and mesh.get_meta("ink_key") == key:
		return mesh.get_meta("ink_lines")
	var lines := _build(mesh)
	mesh.set_meta("ink_lines", lines)
	mesh.set_meta("ink_key", key)
	return lines


static func _build(mesh: Mesh) -> ArrayMesh:
	var ids := {}          # welded position key -> point index
	var points := PackedVector3Array()
	var tris := PackedInt32Array()
	var edges := {}        # Vector2i(lo, hi) point indices -> [first face normal, faces seen, sharp]
	var cos_crease := cos(deg_to_rad(CREASE_DEG))
	for s in mesh.get_surface_count():
		if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var remap := PackedInt32Array()
		remap.resize(verts.size())
		for i in verts.size():
			var v := verts[i]
			var key := Vector3i(roundi(v.x / WELD), roundi(v.y / WELD), roundi(v.z / WELD))
			if not ids.has(key):
				ids[key] = points.size()
				points.append(v)
			remap[i] = ids[key]
		var count := index.size() if not index.is_empty() else verts.size()
		for t in range(0, count - 2, 3):
			var i0 := remap[index[t] if not index.is_empty() else t]
			var i1 := remap[index[t + 1] if not index.is_empty() else t + 1]
			var i2 := remap[index[t + 2] if not index.is_empty() else t + 2]
			if i0 == i1 or i1 == i2 or i0 == i2:
				continue
			tris.append_array([i0, i1, i2])
	# Parts: triangles joined through shared points.
	var parent := PackedInt32Array()
	parent.resize(points.size())
	for i in points.size():
		parent[i] = i
	for t in range(0, tris.size(), 3):
		_union(parent, tris[t], tris[t + 1])
		_union(parent, tris[t], tris[t + 2])
	var part_box := {}
	for i in points.size():
		var r := _find(parent, i)
		if part_box.has(r):
			part_box[r] = (part_box[r] as AABB).expand(points[i])
		else:
			part_box[r] = AABB(points[i], Vector3.ZERO)
	for t in range(0, tris.size(), 3):
		var i0 := tris[t]
		var i1 := tris[t + 1]
		var i2 := tris[t + 2]
		var pb: AABB = part_box[_find(parent, i0)]
		if maxf(pb.size.x, maxf(pb.size.y, pb.size.z)) < MIN_PART_M:
			continue
		var nrm := (points[i1] - points[i0]).cross(points[i2] - points[i0])
		if nrm.length_squared() < 1e-14:
			continue
		nrm = nrm.normalized()
		for pair in [[i0, i1], [i1, i2], [i2, i0]]:
			var lo: int = mini(pair[0], pair[1])
			var hi: int = maxi(pair[0], pair[1])
			var ek := Vector2i(lo, hi)
			var e = edges.get(ek)
			if e == null:
				edges[ek] = [nrm, 1, false]
			else:
				e[1] += 1
				# A face folded back on itself (a double-sided panel) is
				# not a crease; anything bent past the threshold is.
				var dot: float = (e[0] as Vector3).dot(nrm)
				if dot < cos_crease and dot > -0.999:
					e[2] = true
	var pos := PackedVector3Array()
	var other := PackedFloat32Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for ek in edges:
		var e: Array = edges[ek]
		if not (e[2] or e[1] == 1):
			continue
		var a := points[(ek as Vector2i).x]
		var b := points[(ek as Vector2i).y]
		var base := pos.size()
		# a on both sides, then b on both sides; b's sides are mirrored since
		# its "other end" points back the other way.
		for corner in [[a, b, 1.0], [a, b, -1.0], [b, a, -1.0], [b, a, 1.0]]:
			pos.append(corner[0])
			var o: Vector3 = corner[1]
			other.append_array([o.x, o.y, o.z, 0.0])
			uv.append(Vector2(corner[2], 0.0))
		idx.append_array([base, base + 1, base + 3, base, base + 3, base + 2])
	if pos.is_empty():
		return null
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_CUSTOM0] = other
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return out


static func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[ra] = rb
