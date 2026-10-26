extends SceneTree

# Builds furniture models for the drawn look (the ink outlines of
# style/ink_lines.gd) and writes them as .glb files. Run from the project:
#
#   godot --headless --path . -s res://tools/models/style_models.gd
#
# Writes assets/models/furniture/styletest/<id>.glb. Then import them once
# (godot --headless --path . --import).
#
# The style rules, which the shapes below follow:
#
# 1. Real size, in metres, exactly the catalogue footprint (size.w x wall_h x
#    size.h tiles of 10 cm), origin at the bottom centre, front facing +Z,
#    long side along X. The game then fits them without stretching.
# 2. Chunky: no part thinner than 2 cm, no detail under about 4 cm. Anything
#    smaller is a pixel or two on screen and comes out as noise.
# 3. Doors and drawers are panels standing only 3 mm proud, with gaps of
#    3 cm or more that show the darker body behind: the seam reads as a
#    stripe of colour, never as an edge. (2 cm proud made their sides thin
#    slivers on screen, which the ink drew as dotted lines.)
# 4. Overhangs (a cornice, a top slab, a rim) of 2 cm or more, so their edge
#    reads as an edge.
# 5. Curves turn at most 22.5 degrees between neighbouring facets, so the ink
#    draws their outline and not every facet.
# 6. Closed shapes, every face pointing outward; no single-sided panels.
# 7. Three or four colours a piece: C_<catalogue colour> for the body and its
#    shades, M_<name> for shared materials (ceramic, chrome, brass, mirror,
#    water). The style system keeps their light/dark relationships.

const OUT_DIR := "res://assets/models/furniture/styletest/"
const SEG := 4   # facets per quarter turn of a rounded corner: 22.5 degrees each

# Godot draws a triangle's front where its corners run clockwise.
var _parts := {}   # material name -> {"st": SurfaceTool, "color": Color}
var _colors := {
	"M_ceramic": Color("f4f4f0"),
	"M_chrome": Color("a8b0b8"),
	"M_brass": Color("c89a3a"),
	"M_mirror": Color("c8dce6"),
	"M_water": Color("78b4d4"),
	"M_bird": Color("f0c020"),
	"M_teal": Color("2a7a78"),
	"M_cream": Color("e8dcc0"),
	"M_coral": Color("c85a40"),
}


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_build("wardrobe", _wardrobe)
	_build("dresser", _dresser)
	_build("bathtub", _bathtub)
	_build("sink", _sink)
	_build("toilet", _toilet)
	quit()


func _build(id: String, shape: Callable) -> void:
	_parts.clear()
	shape.call()
	var root := Node3D.new()
	root.name = "MIF_" + id
	var body := MeshInstance3D.new()
	body.name = id + "_Body"
	var mesh := ArrayMesh.new()
	for mat_name in _parts:
		var st: SurfaceTool = _parts[mat_name]["st"]
		var mat := StandardMaterial3D.new()
		mat.resource_name = mat_name
		mat.albedo_color = _parts[mat_name]["color"]
		mat.roughness = 1.0
		st.set_material(mat)
		st.commit(mesh)
	body.mesh = mesh
	root.add_child(body)
	body.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err == OK:
		err = doc.write_to_filesystem(state, OUT_DIR + id + ".glb")
	print("%s: %s, aabb %s" % [id, error_string(err), mesh.get_aabb()])
	root.free()


# ── primitives ──────────────────────────────────────────────────────────────

func _st(mat: String) -> SurfaceTool:
	if not _parts.has(mat):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var col: Color = _colors.get(mat, Color.WHITE)
		if mat.begins_with("C_"):
			col = Color(mat.substr(2))
		_parts[mat] = {"st": st, "color": col}
	return _parts[mat]["st"]


# One triangle, wound so its front faces `outward`.
func _tri(mat: String, a: Vector3, b: Vector3, c: Vector3, outward: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-14:
		return
	if n.dot(outward) > 0.0:
		var t := b
		b = c
		c = t
	n = -(b - a).cross(c - a).normalized()
	var st := _st(mat)
	for v in [a, b, c]:
		st.set_normal(n)
		st.add_vertex(v)


func _quad(mat: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3) -> void:
	_tri(mat, a, b, c, outward)
	_tri(mat, a, c, d, outward)


func _box(mat: String, mn: Vector3, mx: Vector3) -> void:
	var p := func(x: int, y: int, z: int) -> Vector3:
		return Vector3(mx.x if x else mn.x, mx.y if y else mn.y, mx.z if z else mn.z)
	_quad(mat, p.call(0,0,1), p.call(1,0,1), p.call(1,1,1), p.call(0,1,1), Vector3.BACK)
	_quad(mat, p.call(0,0,0), p.call(1,0,0), p.call(1,1,0), p.call(0,1,0), Vector3.FORWARD)
	_quad(mat, p.call(1,0,0), p.call(1,0,1), p.call(1,1,1), p.call(1,1,0), Vector3.RIGHT)
	_quad(mat, p.call(0,0,0), p.call(0,0,1), p.call(0,1,1), p.call(0,1,0), Vector3.LEFT)
	_quad(mat, p.call(0,1,0), p.call(1,1,0), p.call(1,1,1), p.call(0,1,1), Vector3.UP)
	_quad(mat, p.call(0,0,0), p.call(1,0,0), p.call(1,0,1), p.call(0,0,1), Vector3.DOWN)


# A rounded rectangle seen from above, centred on (cx, cz): always the same
# number of points (4 corners x SEG+1), so loops of different sizes can be
# joined into bands.
func _rr(cx: float, cz: float, w: float, d: float, r: float) -> PackedVector2Array:
	r = minf(r, minf(w, d) * 0.5 - 0.0001)
	var out := PackedVector2Array()
	var hx := w * 0.5 - r
	var hz := d * 0.5 - r
	var corners := [Vector2(hx, hz), Vector2(-hx, hz), Vector2(-hx, -hz), Vector2(hx, -hz)]
	for k in 4:
		for s in SEG + 1:
			var ang := (k + float(s) / SEG) * PI * 0.5
			out.append(Vector2(cx, cz) + corners[k] + Vector2(cos(ang), sin(ang)) * r)
	return out


# The band joining loop `a` at height ya to loop `b` at height yb. `inward`
# for the inside of a bowl (its faces look towards the middle).
func _band(mat: String, a: PackedVector2Array, ya: float, b: PackedVector2Array, yb: float, inward := false) -> void:
	var c := Vector2.ZERO
	for p in a:
		c += p
	c /= a.size()
	for i in a.size():
		var j := (i + 1) % a.size()
		var mid := (a[i] + a[j]) * 0.5 - c
		var out := Vector3(mid.x, 0.0, mid.y) * (-1.0 if inward else 1.0)
		_quad(mat, Vector3(a[i].x, ya, a[i].y), Vector3(a[j].x, ya, a[j].y),
			Vector3(b[j].x, yb, b[j].y), Vector3(b[i].x, yb, b[i].y), out)


# A flat cap filling a loop, facing up or down.
func _cap(mat: String, loop: PackedVector2Array, y: float, up: bool) -> void:
	var c := Vector2.ZERO
	for p in loop:
		c += p
	c /= loop.size()
	var o := Vector3.UP if up else Vector3.DOWN
	for i in loop.size():
		var j := (i + 1) % loop.size()
		_tri(mat, Vector3(c.x, y, c.y), Vector3(loop[i].x, y, loop[i].y), Vector3(loop[j].x, y, loop[j].y), o)


# A flat ring between an outer and an inner loop.
func _ring(mat: String, outer: PackedVector2Array, inner: PackedVector2Array, y: float, up: bool) -> void:
	var o := Vector3.UP if up else Vector3.DOWN
	for i in outer.size():
		var j := (i + 1) % outer.size()
		_quad(mat, Vector3(outer[i].x, y, outer[i].y), Vector3(outer[j].x, y, outer[j].y),
			Vector3(inner[j].x, y, inner[j].y), Vector3(inner[i].x, y, inner[i].y), o)


# A solid rounded block: two caps and a band.
func _rblock(mat: String, cx: float, cz: float, w: float, d: float, r: float, y0: float, y1: float) -> void:
	var l := _rr(cx, cz, w, d, r)
	_band(mat, l, y0, l, y1)
	_cap(mat, l, y1, true)
	_cap(mat, l, y0, false)


# ── pieces ──────────────────────────────────────────────────────────────────

# 100 x 200 x 60 cm: two tall doors over two drawers, under a cornice.
func _wardrobe() -> void:
	var dark := "C_7b5f32"
	var body := "C_b08848"
	var top := "C_846636"
	var front := "C_c8a874"
	_box(dark, Vector3(-0.46, 0.0, -0.27), Vector3(0.46, 0.08, 0.23))
	_box(body, Vector3(-0.48, 0.08, -0.30), Vector3(0.48, 1.90, 0.25))
	_box(top, Vector3(-0.50, 1.90, -0.30), Vector3(0.50, 2.00, 0.28))
	for s in [-1.0, 1.0]:
		var x0: float = 0.02 if s > 0 else -0.46
		var x1: float = 0.46 if s > 0 else -0.02
		_box(front, Vector3(x0, 0.42, 0.25), Vector3(x1, 1.86, 0.253))     # door
		_box(front, Vector3(x0, 0.12, 0.25), Vector3(x1, 0.38, 0.253))     # drawer
		_box("M_brass", Vector3(s * 0.04 - 0.012, 0.98, 0.253), Vector3(s * 0.04 + 0.012, 1.30, 0.28))
		_box("M_brass", Vector3(s * 0.24 - 0.05, 0.235, 0.253), Vector3(s * 0.24 + 0.05, 0.265, 0.28))
	_box("M_mirror", Vector3(0.12, 0.62, 0.253), Vector3(0.40, 1.70, 0.256))


# 110 x 130 x 70 cm: four rows of drawers under an overhanging top, with a
# vase and two books on it.
func _dresser() -> void:
	var dark := "C_5f4e38"
	var body := "C_887050"
	var top := "C_6d5a40"
	var front := "C_b09c80"
	_box(dark, Vector3(-0.51, 0.0, -0.32), Vector3(0.51, 0.10, 0.27))
	_box(body, Vector3(-0.53, 0.10, -0.35), Vector3(0.53, 1.10, 0.31))
	_box(top, Vector3(-0.55, 1.10, -0.35), Vector3(0.55, 1.16, 0.33))
	for s in [-1.0, 1.0]:
		var x0: float = 0.02 if s > 0 else -0.51
		var x1: float = 0.51 if s > 0 else -0.02
		_box(front, Vector3(x0, 0.86, 0.31), Vector3(x1, 1.06, 0.313))
	var rows := [[0.62, 0.82], [0.38, 0.58], [0.14, 0.34]]
	for r in rows:
		_box(front, Vector3(-0.51, r[0], 0.31), Vector3(0.51, r[1], 0.313))
	for y in [0.96, 0.72, 0.48, 0.24]:
		for s in [-1.0, 1.0]:
			_box("M_brass", Vector3(s * 0.26 - 0.04, y - 0.02, 0.313), Vector3(s * 0.26 + 0.04, y + 0.02, 0.34))
	# A vase: a few stacked rounded blocks, and two books.
	_rblock("M_teal", -0.30, -0.05, 0.10, 0.10, 0.05, 1.16, 1.22)
	_rblock("M_teal", -0.30, -0.05, 0.13, 0.13, 0.065, 1.22, 1.26)
	_rblock("M_teal", -0.30, -0.05, 0.07, 0.07, 0.035, 1.26, 1.30)
	_box("M_cream", Vector3(0.08, 1.16, -0.14), Vector3(0.34, 1.20, 0.04))
	_box("M_coral", Vector3(0.11, 1.20, -0.12), Vector3(0.31, 1.24, 0.02))


# 100 x 80 x 60 cm, along X: a freestanding tub on four feet, a rim, water,
# a tap at the +X end and a duck.
func _bathtub() -> void:
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_rblock("M_brass", sx * 0.33, sz * 0.17, 0.08, 0.08, 0.04, 0.0, 0.12)
	var foot := _rr(0, 0, 0.84, 0.46, 0.20)
	var shoulder := _rr(0, 0, 0.96, 0.56, 0.26)
	var lip := _rr(0, 0, 1.00, 0.60, 0.28)
	var inner := _rr(0, 0, 0.86, 0.46, 0.21)
	var floor := _rr(0, 0, 0.74, 0.36, 0.16)
	_cap("M_ceramic", foot, 0.12, false)
	_band("M_ceramic", foot, 0.12, shoulder, 0.56)
	_band("M_ceramic", shoulder, 0.56, lip, 0.58)
	_band("M_ceramic", lip, 0.58, lip, 0.62)
	_ring("M_ceramic", lip, inner, 0.62, true)
	_band("M_ceramic", inner, 0.62, floor, 0.24, true)
	_cap("M_ceramic", floor, 0.24, true)
	_cap("M_water", _rr(0, 0, 0.82, 0.43, 0.195), 0.50, true)
	# Tap: a post and a spout over the water.
	_box("M_chrome", Vector3(0.40, 0.62, -0.025), Vector3(0.45, 0.80, 0.025))
	_box("M_chrome", Vector3(0.28, 0.74, -0.025), Vector3(0.40, 0.79, 0.025))
	# The duck.
	_box("M_bird", Vector3(-0.20, 0.50, -0.04), Vector3(-0.08, 0.56, 0.04))
	_box("M_bird", Vector3(-0.12, 0.56, -0.025), Vector3(-0.07, 0.61, 0.025))


# 60 x 140 x 50 cm: a basin on a pedestal in front of a splash panel that
# carries the tap and the mirror.
func _sink() -> void:
	var pz := -0.04
	var base := _rr(0, pz, 0.26, 0.22, 0.10)
	var waist := _rr(0, pz, 0.14, 0.12, 0.06)
	var flare := _rr(0, pz, 0.30, 0.24, 0.11)
	_cap("M_ceramic", base, 0.0, false)
	_band("M_ceramic", base, 0.0, base, 0.06)
	_band("M_ceramic", base, 0.06, waist, 0.16)
	_band("M_ceramic", waist, 0.16, waist, 0.58)
	_band("M_ceramic", waist, 0.58, flare, 0.70)
	var bz := 0.0
	var under := _rr(0, bz, 0.42, 0.32, 0.14)
	var outer := _rr(0, bz, 0.56, 0.44, 0.20)
	var inner := _rr(0, bz, 0.46, 0.34, 0.15)
	var bottom := _rr(0, bz, 0.34, 0.24, 0.10)
	_cap("M_ceramic", under, 0.70, false)
	_band("M_ceramic", under, 0.70, outer, 0.85)
	_band("M_ceramic", outer, 0.85, outer, 0.89)
	_ring("M_ceramic", outer, inner, 0.89, true)
	_band("M_ceramic", inner, 0.89, bottom, 0.76, true)
	_cap("M_ceramic", bottom, 0.76, true)
	_cap("M_water", _rr(0, bz, 0.40, 0.29, 0.125), 0.82, true)
	_box("C_c8d8e8", Vector3(-0.30, 0.0, -0.25), Vector3(0.30, 1.40, -0.21))
	_box("M_chrome", Vector3(-0.025, 0.89, -0.21), Vector3(0.025, 1.00, -0.16))
	_box("M_chrome", Vector3(-0.025, 0.95, -0.16), Vector3(0.025, 1.00, -0.07))
	_box("M_brass", Vector3(-0.21, 1.00, -0.21), Vector3(0.21, 1.36, -0.19))
	_box("M_mirror", Vector3(-0.17, 1.04, -0.19), Vector3(0.17, 1.32, -0.187))


# 50 x 80 x 60 cm: a cistern with an overhanging lid against the wall, a
# bowl on a narrow base and a seat.
func _toilet() -> void:
	_box("M_ceramic", Vector3(-0.21, 0.40, -0.30), Vector3(0.21, 0.76, -0.12))
	_box("M_ceramic", Vector3(-0.23, 0.76, -0.30), Vector3(0.23, 0.80, -0.10))
	_box("M_chrome", Vector3(-0.04, 0.80, -0.24), Vector3(0.04, 0.82, -0.18))
	var cz := 0.03
	var base := _rr(0, cz - 0.02, 0.22, 0.32, 0.10)
	var waist := _rr(0, cz, 0.26, 0.40, 0.12)
	var bowl := _rr(0, cz, 0.38, 0.52, 0.18)
	_cap("M_ceramic", base, 0.0, false)
	_band("M_ceramic", base, 0.0, waist, 0.22)
	_band("M_ceramic", waist, 0.22, bowl, 0.38)
	var seat_out := _rr(0, cz + 0.005, 0.40, 0.54, 0.19)
	var seat_in := _rr(0, cz + 0.02, 0.24, 0.32, 0.11)
	var throat := _rr(0, cz + 0.02, 0.14, 0.18, 0.06)
	_ring("C_d4dde8", seat_out, bowl, 0.38, false)
	_band("C_d4dde8", seat_out, 0.38, seat_out, 0.42)
	_ring("C_d4dde8", seat_out, seat_in, 0.42, true)
	_band("M_ceramic", seat_in, 0.42, throat, 0.20, true)
	_cap("M_water", _rr(0, cz + 0.02, 0.19, 0.25, 0.085), 0.30, true)
	_cap("M_ceramic", throat, 0.20, true)
