class_name InkLines
extends RefCounted

# The illustrated look: thin ink around every piece of furniture and every
# wall, like a drawing: its contour as seen from the camera, and its sharp
# corners (a box's edges, a drawer's front, a window frame).
#
# Every edge between two faces of a mesh is kept with the directions of
# those two faces, and the shader (shaders/ink_lines) decides each frame
# whether to draw it: always for a corner, and for any other edge only while
# one of its faces looks towards the camera and the other away, which is
# exactly the contour from this angle. So a bath gets a clean round outline
# from every side, without scratches across its gentle facets. Lines are a
# fixed fraction of the view's height wide whatever the zoom, with soft
# edges, and pulled a little towards the camera so the face they sit on
# doesn't cover them.
#
# The edges are found once per mesh and kept on the mesh resource, so every
# copy of a model shares them, and go in one child of the mesh, so they move,
# scale, fold, fade with and are freed with whatever they outline; hiding a
# wall hides its lines. Small parts (a handle, a knob, a book) and thin bars
# (a shower screen's grid) get none.
#
# The Miis are skinned, so they keep their own hull outline (TenantMii);
# mii_outline_material() gives it the same ink.
#
# On at every graphics tier: they are the look, not an extra. They add one
# draw call per outlined mesh, the cost to watch on phones.

const LINE_SHADER := preload("res://style/shaders/ink_lines.gdshader")
const MII_SHADER := preload("res://scripts/shaders/tenant_outline.gdshader")
const GROUP := &"ink_lines"
const NODE_NAME := "InkLines"
# Faces meeting at more than this bend get a corner line between them.
const CREASE_DEG := 60.0
# Vertices this close are the same point (models split them per face).
const WELD := 1e-4
# A separate part of a model shorter than this along its longest side (a
# handle, a knob, a book on a shelf), or thinner than MIN_BAR_M across its
# middle side (the bars of a shower screen), gets no ink: inked, every small
# detail turned into a smudge.
const MIN_PART_M := 0.14
const MIN_BAR_M := 0.02
const MII_WIDTH := 0.008

static var _lines: ShaderMaterial
static var _mii: ShaderMaterial
static var _enabled := true


static func line_material() -> ShaderMaterial:
	if _lines == null:
		_lines = ShaderMaterial.new()
		_lines.shader = LINE_SHADER
	return _lines


static func mii_outline_material() -> ShaderMaterial:
	if _mii == null:
		_mii = ShaderMaterial.new()
		_mii.shader = MII_SHADER
		_mii.set_shader_parameter("outline_width", MII_WIDTH if _enabled else 0.0)
		_mii.set_shader_parameter("outline_color", line_material().get_shader_parameter("contour_color"))
	return _mii


# The ink: a deep shade of the palette's shadow tint, so it belongs to the
# level's colours instead of being a flat black. Corner lines sit a little
# lighter than the contour, as in a drawing.
static func set_palette(palette: LevelPalette) -> void:
	if palette == null:
		return
	var ink := palette.shadow_tint.darkened(0.5)
	ink.a = 1.0
	mii_outline_material().set_shader_parameter("outline_color", ink)
	ink.a = 0.9
	line_material().set_shader_parameter("contour_color", ink)
	ink.a = 0.6
	line_material().set_shader_parameter("corner_color", ink)


static func set_enabled(on: bool, tree: SceneTree) -> void:
	_enabled = on
	mii_outline_material().set_shader_parameter("outline_width", MII_WIDTH if on else 0.0)
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
	# pane of glass), not objects: whatever frames them is outlined already.
	var box := mi.mesh.get_aabb()
	if minf(box.size.x, minf(box.size.y, box.size.z)) < 0.002:
		return
	var ink_mesh := ink_for(mi.mesh)
	if ink_mesh == null:
		return
	var ink := MeshInstance3D.new()
	ink.name = NODE_NAME
	ink.mesh = ink_mesh
	ink.material_override = line_material()
	ink.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ink.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# Lines reach a pixel or two past the mesh: never cull them early at the
	# screen's edge.
	ink.extra_cull_margin = 0.05
	ink.visible = _enabled
	ink.add_to_group(GROUP)
	mi.add_child(ink)


# The edge mesh for `mesh` (null when there's nothing to draw), worked out
# once and kept on the mesh. A box or other primitive can be resized in place (a
# placeholder following a drag), so it's only reused while the bounds stay.
static func ink_for(mesh: Mesh) -> ArrayMesh:
	var key := mesh.get_aabb()
	if mesh.has_meta("ink_mesh") and mesh.get_meta("ink_key") == key:
		return mesh.get_meta("ink_mesh")
	var out := _build(mesh)
	mesh.set_meta("ink_mesh", out)
	mesh.set_meta("ink_key", key)
	return out


static func _build(mesh: Mesh) -> ArrayMesh:
	var ids := {}          # welded position key -> point index
	var points := PackedVector3Array()
	var tris := PackedInt32Array()
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
			if i0 != i1 and i1 != i2 and i0 != i2:
				tris.append_array([i0, i1, i2])

	# Parts: triangles joined through shared points. Small parts and thin bars
	# are left out of both the contour and the lines.
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
		part_box[r] = (part_box[r] as AABB).expand(points[i]) if part_box.has(r) else AABB(points[i], Vector3.ZERO)
	var part_ok := {}
	for r in part_box:
		var sz: Vector3 = (part_box[r] as AABB).size
		var dims := [sz.x, sz.y, sz.z]
		dims.sort()
		part_ok[r] = dims[2] >= MIN_PART_M and dims[1] >= MIN_BAR_M

	var cos_crease := cos(deg_to_rad(CREASE_DEG))
	var edges := {}        # Vector2i(lo, hi) -> [first face normal, second face normal, faces]
	for t in range(0, tris.size(), 3):
		var i0 := tris[t]
		var i1 := tris[t + 1]
		var i2 := tris[t + 2]
		if not part_ok[_find(parent, i0)]:
			continue
		var cross := (points[i1] - points[i0]).cross(points[i2] - points[i0])
		if cross.length_squared() < 1e-14:
			continue
		var nrm := cross.normalized()
		for pair in [[i0, i1], [i1, i2], [i2, i0]]:
			var ek := Vector2i(mini(pair[0], pair[1]), maxi(pair[0], pair[1]))
			var e = edges.get(ek)
			if e == null:
				edges[ek] = [nrm, nrm, 1]
			else:
				if e[2] == 1:
					e[1] = nrm
				e[2] += 1

	var pos := PackedVector3Array()
	var other := PackedFloat32Array()
	var n1s := PackedFloat32Array()
	var n2s := PackedFloat32Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for ek in edges:
		var e: Array = edges[ek]
		# An open border has one face and no contour test to make; skipped,
		# they were the scraps of line on the first try.
		if e[2] < 2:
			continue
		var na: Vector3 = e[0]
		var nb: Vector3 = e[1]
		var dot := na.dot(nb)
		# A face folded back on itself (a double-sided panel, a face wound the
		# other way) is neither a corner nor a contour.
		if dot < -0.999:
			continue
		var corner := 1.0 if (dot < cos_crease or e[2] > 2) else 0.0
		var a := points[(ek as Vector2i).x]
		var b := points[(ek as Vector2i).y]
		var base := pos.size()
		# a on both sides, then b on both sides; b's sides are mirrored since
		# its "other end" points back the other way.
		for c in [[a, b, 1.0], [a, b, -1.0], [b, a, -1.0], [b, a, 1.0]]:
			pos.append(c[0])
			var o: Vector3 = c[1]
			other.append_array([o.x, o.y, o.z, 0.0])
			n1s.append_array([na.x, na.y, na.z, corner])
			n2s.append_array([nb.x, nb.y, nb.z, 0.0])
			uv.append(Vector2(c[2], 0.0))
		idx.append_array([base, base + 1, base + 3, base, base + 3, base + 2])
	if pos.is_empty():
		return null
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_CUSTOM0] = other
	arr[Mesh.ARRAY_CUSTOM1] = n1s
	arr[Mesh.ARRAY_CUSTOM2] = n2s
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
		(Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT))
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
