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

# A model is one or more parts. "Body" is fixed; a moving part (a bed panel
# that swings down, the legs that fold out under it) gets its own node with
# a pivot, a parent part and two rotations: as stored (closed) and at the
# end of the "open" clip. The game shows a folding piece's open state by
# posing that clip at its end (Room3DView._apply_item_model), and fits each
# pose to its own footprint, so the clip only needs the right first and last
# frame.
#
# A part's shapes are given where they would be with every part's rotation
# at zero, in the model's own space.
var _groups := {}  # part name -> {parts, pivot, parent, closed, open}
var _cur := ""
var _parts := {}   # the current part's material name -> {"st": SurfaceTool, "color": Color}
# The project's shared materials, in the colours the current models use.
var _colors := {
	"M_bird": Color("f2c230"), "M_black": Color("1d1e21"), "M_blue": Color("4f7fb5"),
	"M_brass": Color("d6ab4e"), "M_cardboard": Color("c79a63"), "M_ceramic": Color("fbfbf8"),
	"M_chrome": Color("c9d0d6"), "M_coral": Color("d9674f"), "M_cream": Color("efe4cf"),
	"M_glass": Color("bfe3ee"), "M_iron": Color("4a4f57"), "M_leaf": Color("5fa04a"),
	"M_leaf_dark": Color("3d7a3c"), "M_leaf_lime": Color("8fbf4f"), "M_mattress": Color("f7f4ec"),
	"M_mirror": Color("cfe6ef"), "M_mustard": Color("e2b043"), "M_navy": Color("34466a"),
	"M_oak": Color("d9b382"), "M_orange": Color("e08a3c"), "M_paper": Color("f6f3ea"),
	"M_pillow": Color("ffffff"), "M_pine": Color("ecd3a4"), "M_pink": Color("e3a3a8"),
	"M_red": Color("c94a40"), "M_rubber": Color("2a2b2e"), "M_sage": Color("8fae84"),
	"M_screen": Color("14181f"), "M_soil": Color("4a3526"), "M_steel": Color("9aa3ad"),
	"M_stone": Color("e2ddd3"), "M_tape": Color("e8d7a8"), "M_teal": Color("3f9a98"),
	"M_terracotta": Color("c96f4a"), "M_walnut": Color("8a5a3a"), "M_water": Color("8fd0ea"),
	"M_white": Color("f4f1ea"), "M_wicker": Color("c9a36a"), "M_worktop": Color("3c4046"),
	"M_blanket": Color("6a8eb8"),
	"lamp": Color("fff0b8"),   # the style system makes this one glow
}


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var pieces := {
		"wardrobe": _wardrobe, "dresser": _dresser, "bathtub": _bathtub, "sink": _sink,
		"toilet": _toilet, "murphy_bed": _murphy_bed,
		# Batch 1: boxy storage.
		"nightstand": _nightstand, "bookshelf": _bookshelf, "closed_bookcase": _closed_bookcase,
		"wide_bookcase": _wide_bookcase, "pantry": _pantry, "filing_cabinet": _filing_cabinet,
		"bathroom_cabinet": _bathroom_cabinet, "side_table": _side_table, "tv_stand": _tv_stand,
		"kitchen_corner_cabinet_inner": _kitchen_corner_cabinet_inner,
		"kitchen_corner_cabinet_round": _kitchen_corner_cabinet_round,
		"moving_box": _moving_box, "laundry_basket": _laundry_basket, "trash_can": _trash_can,
		"sliding_wardrobe_tall": _sliding_wardrobe_tall, "sliding_bookcase": _sliding_bookcase,
		"rolling_shelf_wide": _rolling_shelf_wide, "rolling_tv_unit": _rolling_tv_unit,
		"pocket_pantry": _pocket_pantry, "sliding_bathroom_cabinet": _sliding_bathroom_cabinet,
		# Batch 2: kitchen and appliances.
		"kitchen": _kitchen, "kitchen_small": _kitchen_small, "kitchen_island": _kitchen_island,
		"rolling_island": _rolling_island, "kitchen_sink": _kitchen_sink, "stove": _stove,
		"fridge": _fridge, "fridge_large": _fridge_large, "chest_freezer": _chest_freezer,
		"upright_freezer": _upright_freezer, "mini_fridge": _mini_fridge, "washer": _washer,
		"washer_dryer_stack": _washer_dryer_stack, "sink_square": _sink_square, "shower": _shower,
		"rolling_kitchen_cart": _rolling_kitchen_cart,
	}
	# Pieces named after "--" are built alone: godot ... -s style_models.gd -- nightstand tv_stand
	var only := OS.get_cmdline_user_args()
	for id in pieces:
		if only.is_empty() or id in only:
			_build(id, pieces[id])
	quit()


func _build(id: String, shape: Callable) -> void:
	_groups.clear()
	_part("Body")
	shape.call()
	var root := Node3D.new()
	root.name = "MIF_" + id
	var nodes := {}
	var mats := {}   # one material per name, shared by every part
	var anim := Animation.new()
	anim.length = 1.0
	for gname in _groups:
		var g: Dictionary = _groups[gname]
		var mi := MeshInstance3D.new()
		mi.name = "%s_%s" % [id, gname]
		var mesh := ArrayMesh.new()
		for mat_name in g["parts"]:
			var st: SurfaceTool = g["parts"][mat_name]["st"]
			if not mats.has(mat_name):
				var m := StandardMaterial3D.new()
				m.resource_name = mat_name
				m.albedo_color = g["parts"][mat_name]["color"]
				m.roughness = 1.0
				mats[mat_name] = m
			st.set_material(mats[mat_name])
			st.commit(mesh)
		mi.mesh = mesh
		var parent_pivot := Vector3.ZERO
		var parent: Node = root
		if g["parent"] != "":
			parent = nodes[g["parent"]]
			parent_pivot = _groups[g["parent"]]["pivot"]
		mi.position = (g["pivot"] as Vector3) - parent_pivot
		mi.rotation_degrees = g["closed"]
		parent.add_child(mi)
		mi.owner = root
		nodes[gname] = mi
		if g["open"] != g["closed"]:
			var t := anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(t, NodePath(str(root.get_path_to(mi))))
			anim.rotation_track_insert_key(t, 0.0, Quaternion.from_euler((g["closed"] as Vector3) * PI / 180.0))
			anim.rotation_track_insert_key(t, 1.0, Quaternion.from_euler((g["open"] as Vector3) * PI / 180.0))
	if anim.get_track_count() > 0:
		var ap := AnimationPlayer.new()
		ap.name = "AnimationPlayer"
		var lib := AnimationLibrary.new()
		lib.add_animation("open", anim)
		ap.add_animation_library("", lib)
		root.add_child(ap)
		ap.owner = root
	var closed_box := _pose_aabb(root, nodes, "closed")
	var open_box := _pose_aabb(root, nodes, "open")
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err == OK:
		err = doc.write_to_filesystem(state, OUT_DIR + id + ".glb")
	if anim.get_track_count() > 0:
		print("%s: %s, closed %s, open %s, %d moving parts" % [id, error_string(err), closed_box, open_box, anim.get_track_count()])
	else:
		print("%s: %s, aabb %s" % [id, error_string(err), closed_box])
	root.free()


# Starts a part: what follows goes into it. `pivot` is where it turns, in
# the model's space; `closed` and `open` are its rotations in degrees.
func _part(gname: String, pivot := Vector3.ZERO, parent := "", closed := Vector3.ZERO, open := Vector3.ZERO) -> void:
	if not _groups.has(gname):
		_groups[gname] = {"parts": {}, "pivot": pivot, "parent": parent, "closed": closed, "open": open}
	_cur = gname
	_parts = _groups[gname]["parts"]


# The model's bounds with every part in its closed or open rotation.
func _pose_aabb(root: Node3D, nodes: Dictionary, pose: String) -> AABB:
	var box := AABB()
	var first := true
	for gname in nodes:
		var xf := Transform3D.IDENTITY
		var n: Node3D = nodes[gname]
		var walk: Node = n
		while walk != root:
			var w3 := walk as Node3D
			var g: Dictionary = _groups.get(_group_of(nodes, w3), {})
			var rot: Vector3 = g.get(pose, Vector3.ZERO)
			xf = Transform3D(Basis.from_euler(rot * PI / 180.0), w3.position) * xf
			walk = walk.get_parent()
		var b := xf * (n.mesh as ArrayMesh).get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _group_of(nodes: Dictionary, n: Node3D) -> String:
	for k in nodes:
		if nodes[k] == n:
			return k
	return ""


# ── primitives ──────────────────────────────────────────────────────────────

func _st(mat: String) -> SurfaceTool:
	if not _parts.has(mat):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var col: Color = _colors.get(mat, Color.WHITE)
		if mat.begins_with("C_"):
			col = Color(mat.substr(2))
		elif not _colors.has(mat):
			push_error("no colour for material " + mat)
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
	var pivot: Vector3 = _groups[_cur]["pivot"]
	for v in [a, b, c]:
		st.set_normal(n)
		st.add_vertex(v - pivot)


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
	_ring("M_ceramic", lip, shoulder, 0.56, false)
	_band("M_ceramic", lip, 0.56, lip, 0.62)
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
	_band("M_ceramic", base, 0.06, waist, 0.26)
	_band("M_ceramic", waist, 0.26, waist, 0.46)
	_band("M_ceramic", waist, 0.46, flare, 0.70)
	_cap("M_ceramic", flare, 0.70, true)
	var bz := 0.03
	var under := _rr(0, bz, 0.46, 0.36, 0.16)
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
	_box("M_ceramic", Vector3(-0.25, 0.76, -0.30), Vector3(0.25, 0.80, -0.10))
	_box("M_chrome", Vector3(-0.04, 0.80, -0.24), Vector3(0.04, 0.82, -0.18))
	var cz := 0.03
	var base := _rr(0, cz - 0.02, 0.22, 0.32, 0.10)
	var waist := _rr(0, cz, 0.26, 0.40, 0.12)
	var bowl := _rr(0, cz, 0.38, 0.52, 0.18)
	_cap("M_ceramic", base, 0.0, false)
	_band("M_ceramic", base, 0.0, waist, 0.22)
	_band("M_ceramic", waist, 0.22, bowl, 0.38)
	var seat_out := _rr(0, cz + 0.005, 0.40, 0.53, 0.19)
	var seat_in := _rr(0, cz + 0.02, 0.24, 0.32, 0.11)
	var throat := _rr(0, cz + 0.02, 0.14, 0.18, 0.06)
	_ring("C_d4dde8", seat_out, bowl, 0.38, false)
	_band("C_d4dde8", seat_out, 0.38, seat_out, 0.42)
	_ring("C_d4dde8", seat_out, seat_in, 0.42, true)
	_band("M_ceramic", seat_in, 0.42, throat, 0.20, true)
	_cap("M_water", _rr(0, cz + 0.02, 0.19, 0.25, 0.085), 0.30, true)
	_cap("M_ceramic", throat, 0.20, true)


# 150 x 200 x 60 cm closed; 230 cm deep open. A cabinet against the wall
# whose bed panel swings down on a hinge low at its front, with a pair of
# legs that fold out under the foot end.
func _murphy_bed() -> void:
	var body := "C_5a7ea0"
	var dark := "C_3f5870"
	var front := "C_8fa8c4"
	# Cabinet: back, two sides, a top and a low base under the hinge.
	_box(dark, Vector3(-0.75, 0.0, -0.30), Vector3(0.75, 2.00, -0.27))
	_box(body, Vector3(-0.75, 0.0, -0.27), Vector3(-0.71, 2.00, 0.30))
	_box(body, Vector3(0.71, 0.0, -0.27), Vector3(0.75, 2.00, 0.30))
	_box(body, Vector3(-0.75, 1.94, -0.27), Vector3(0.75, 2.00, 0.30))
	_box(body, Vector3(-0.71, 0.0, -0.27), Vector3(0.71, 0.20, 0.27))
	# The bed panel, standing up inside the cabinet: hinge 20 cm up at its
	# front, 1.72 m long, its underside (the cabinet's face when closed)
	# towards +Z, the mattress towards the back. It swings 90 degrees forward
	# to lie on the floor side, mattress up.
	var hinge := Vector3(0.0, 0.20, 0.27)
	_part("Bed", hinge, "Body", Vector3.ZERO, Vector3(90.0, 0.0, 0.0))
	_box(front, Vector3(-0.70, 0.20, 0.19), Vector3(0.70, 1.92, 0.27))            # underside board
	_box("M_mattress", Vector3(-0.66, 0.24, 0.01), Vector3(0.66, 1.88, 0.19))     # mattress
	_box("M_blanket", Vector3(-0.66, 0.70, 0.007), Vector3(0.66, 1.88, 0.01))    # blanket stripe
	_box("M_pillow", Vector3(-0.50, 0.28, -0.03), Vector3(0.50, 0.58, 0.01))     # pillow at the head
	_box("M_brass", Vector3(-0.25, 1.70, 0.27), Vector3(0.25, 1.74, 0.29))       # handle
	# Legs at the foot end: built standing out of the underside (+Z), as they
	# are when the bed is down; folded flat along it when closed.
	_part("Legs", Vector3(0.0, 1.84, 0.27), "Bed", Vector3(90.0, 0.0, 0.0), Vector3.ZERO)
	_box(dark, Vector3(-0.66, 1.82, 0.27), Vector3(-0.60, 1.86, 0.47))
	_box(dark, Vector3(0.60, 1.82, 0.27), Vector3(0.66, 1.86, 0.47))
	_box(dark, Vector3(-0.66, 1.82, 0.43), Vector3(0.66, 1.86, 0.47))


# ── building blocks ─────────────────────────────────────────────────────────

const BOOK_COLOURS := ["M_navy", "M_coral", "M_teal", "M_mustard", "M_sage", "M_red", "M_cream", "M_blue", "M_pink"]


# A door or drawer front: flush with the body (3 mm proud, rule 3), from
# (x0, y0) to (x1, y1) on the face at z.
func _front(mat: String, x0: float, y0: float, x1: float, y1: float, z: float) -> void:
	_box(mat, Vector3(x0, y0, z), Vector3(x1, y1, z + 0.003))


# A knob or a pull, standing 2.5 cm out of the face at z.
func _knob(cx: float, cy: float, z: float, w := 0.04, h := 0.04, mat := "M_brass") -> void:
	_box(mat, Vector3(cx - w * 0.5, cy - h * 0.5, z), Vector3(cx + w * 0.5, cy + h * 0.5, z + 0.025))


# Four square legs under a top spanning x0..x1, z0..z1.
func _legs(mat: String, x0: float, x1: float, z0: float, z1: float, y1: float, t := 0.045) -> void:
	for x in [x0, x1 - t]:
		for z in [z0, z1 - t]:
			_box(mat, Vector3(x, 0.0, z), Vector3(x + t, y1, z + t))


# Castors and a steel base under a rolling piece; returns the height its
# body starts at.
func _castors(x0: float, x1: float, z0: float, z1: float) -> float:
	for x in [x0 + 0.03, x1 - 0.09]:
		for z in [z0 + 0.03, z1 - 0.09]:
			_rblock("M_rubber", x + 0.03, z + 0.03, 0.06, 0.06, 0.03, 0.0, 0.06)
	_box("M_steel", Vector3(x0, 0.06, z0), Vector3(x1, 0.09, z1))
	return 0.09


# A row of books standing on a shelf at y, from x0 towards x1 (leaving a
# gap at the end), between z0 and z1, at most max_h tall. `seed` varies the
# order so no two shelves match.
func _books(x0: float, x1: float, y: float, z0: float, z1: float, max_h: float, seed := 0) -> void:
	var widths := [0.06, 0.05, 0.07, 0.05, 0.08, 0.06, 0.05]
	var heights := [0.85, 0.72, 0.95, 0.78, 0.88, 0.7, 0.92]
	var x := x0
	var i := seed
	while x + widths[i % widths.size()] < x1 - 0.06:
		var w: float = widths[i % widths.size()]
		var h: float = maxf(max_h * heights[(i * 3) % heights.size()], 0.08)
		_box(BOOK_COLOURS[(i * 5 + seed) % BOOK_COLOURS.size()], Vector3(x, y, z0 + 0.02), Vector3(x + w - 0.004, y + h, z1 - 0.02))
		x += w
		i += 1


# A potted plant standing at (cx, y, cz), about `size` tall.
func _plant(cx: float, cz: float, y: float, size := 0.3, pot := "M_terracotta") -> void:
	var r := size * 0.28
	_rblock(pot, cx, cz, r * 2.0, r * 2.0, r * 0.9, y, y + size * 0.35)
	_rblock("M_leaf_dark", cx, cz, r * 2.4, r * 2.4, r * 1.1, y + size * 0.35, y + size * 0.62)
	_rblock("M_leaf", cx - r * 0.3, cz + r * 0.2, r * 1.8, r * 1.8, r * 0.85, y + size * 0.62, y + size * 0.85)
	_rblock("M_leaf_lime", cx + r * 0.25, cz - r * 0.2, r * 1.1, r * 1.1, r * 0.5, y + size * 0.85, y + size)


# A jar with a lid, at (cx, y, cz).
func _jar(cx: float, cz: float, y: float, w: float, h: float, mat: String, lid := "M_steel") -> void:
	_rblock(mat, cx, cz, w, w, w * 0.4, y, y + h * 0.82)
	_rblock(lid, cx, cz, w * 0.82, w * 0.82, w * 0.33, y + h * 0.82, y + h)


# A table lamp at (cx, y, cz), `h` tall: base, stem and a glowing shade.
func _table_lamp(cx: float, cz: float, y: float, h: float) -> void:
	_rblock("M_brass", cx, cz, 0.12, 0.12, 0.06, y, y + 0.03)
	_box("M_brass", Vector3(cx - 0.012, y + 0.03, cz - 0.012), Vector3(cx + 0.012, y + h * 0.55, cz + 0.012))
	var bottom := _rr(cx, cz, h * 0.62, h * 0.62, h * 0.31)
	var top := _rr(cx, cz, h * 0.4, h * 0.4, h * 0.2)
	_band("lamp", bottom, y + h * 0.5, top, y + h)
	_cap("lamp", top, y + h, true)
	_cap("lamp", bottom, y + h * 0.5, false)


# An open box of shelves: sides, top, bottom, back, `rows` shelves.
# Returns the heights the shelves' tops are at, bottom first.
func _shelf_box(mat: String, back: String, x0: float, x1: float, y0: float, y1: float, z0: float, z1: float, rows: int, t := 0.03) -> Array:
	_box(mat, Vector3(x0, y0, z0), Vector3(x0 + t, y1, z1))
	_box(mat, Vector3(x1 - t, y0, z0), Vector3(x1, y1, z1))
	_box(mat, Vector3(x0 + t, y1 - t, z0), Vector3(x1 - t, y1, z1))
	_box(mat, Vector3(x0 + t, y0, z0), Vector3(x1 - t, y0 + t, z1))
	_box(back, Vector3(x0 + t, y0 + t, z0), Vector3(x1 - t, y1 - t, z0 + 0.02))
	var tops := [y0 + t]
	var step := (y1 - y0 - t) / rows
	for r in range(1, rows):
		var y := y0 + r * step
		_box(mat, Vector3(x0 + t, y - t * 0.5, z0 + 0.02), Vector3(x1 - t, y + t * 0.5, z1))
		tops.append(y + t * 0.5)
	return tops


# ── batch 1: boxy storage ───────────────────────────────────────────────────

# 50 x 80 x 60 cm with its lamp: a two-drawer cabinet on legs.
func _nightstand() -> void:
	_legs("C_65543e", -0.23, 0.23, -0.28, 0.27, 0.10)
	_box("C_907858", Vector3(-0.25, 0.10, -0.30), Vector3(0.25, 0.52, 0.27))
	_box("C_65543e", Vector3(-0.25, 0.52, -0.30), Vector3(0.25, 0.55, 0.28))
	_front("C_ac9a82", -0.22, 0.13, 0.22, 0.30, 0.27)
	_front("C_ac9a82", -0.22, 0.33, 0.22, 0.49, 0.27)
	_knob(0.0, 0.215, 0.273, 0.08, 0.025)
	_knob(0.0, 0.41, 0.273, 0.08, 0.025)
	_table_lamp(-0.08, -0.06, 0.55, 0.25)
	_box("M_navy", Vector3(0.05, 0.55, -0.02), Vector3(0.21, 0.58, 0.20))


# 80 x 220 x 30 cm: open shelves of books, a plant on one.
func _bookshelf() -> void:
	var tops := _shelf_box("C_9a7840", "C_6c542d", -0.40, 0.40, 0.0, 2.20, -0.15, 0.15, 5)
	for i in tops.size():
		if i == 2:
			_books(-0.37, 0.05, tops[i], -0.15, 0.15, 0.30, i)
			_plant(0.22, 0.0, tops[i], 0.28, "M_ceramic")
		else:
			_books(-0.37, 0.37, tops[i], -0.15, 0.15, 0.32, i)


# 50 x 190 x 40 cm: doors below, open shelves of books above.
func _closed_bookcase() -> void:
	var tops := _shelf_box("C_907040", "C_654e2d", -0.25, 0.25, 0.0, 1.90, -0.20, 0.20, 4)
	_box("C_907040", Vector3(-0.22, 0.03, -0.18), Vector3(0.22, 0.80, 0.172))
	_front("C_b7a283", -0.22, 0.06, -0.01, 0.78, 0.172)
	_front("C_b7a283", 0.01, 0.06, 0.22, 0.78, 0.172)
	_knob(-0.04, 0.6, 0.175, 0.025, 0.08)
	_knob(0.04, 0.6, 0.175, 0.025, 0.08)
	for i in range(1, tops.size()):
		if tops[i] > 0.8:
			_books(-0.22, 0.22, tops[i], -0.20, 0.20, 0.30, i + 3)


# 140 x 110 x 40 cm: a low, wide case of six open cubbies.
func _wide_bookcase() -> void:
	var tops := _shelf_box("C_987848", "C_6a5432", -0.70, 0.70, 0.0, 1.10, -0.20, 0.20, 2)
	for x in [-0.235, 0.235]:
		_box("C_987848", Vector3(x - 0.015, 0.03, -0.18), Vector3(x + 0.015, 1.07, 0.20))
	for r in tops.size():
		for c in 3:
			var x0 := -0.67 + c * 0.47
			if (r + c) % 3 == 1:
				_box("C_ad936d", Vector3(x0 + 0.05, tops[r], -0.14), Vector3(x0 + 0.36, tops[r] + 0.26, 0.17))
				_front("C_bca788", x0 + 0.08, tops[r] + 0.05, x0 + 0.33, tops[r] + 0.21, 0.17)
			else:
				_books(x0 + 0.02, x0 + 0.43, tops[r], -0.20, 0.20, 0.40, r * 3 + c)


# 50 x 200 x 50 cm: a tall cabinet, closed below, open shelves of jars and
# tins above.
func _pantry() -> void:
	_box("M_black", Vector3(-0.23, 0.0, -0.23), Vector3(0.23, 0.08, 0.21))
	_box("C_8a7060", Vector3(-0.25, 0.08, -0.25), Vector3(0.25, 0.86, 0.222))
	_front("C_a79488", -0.22, 0.11, 0.22, 0.83, 0.222)
	_knob(0.16, 0.74, 0.225, 0.025, 0.10)
	var tops := _shelf_box("C_8a7060", "C_6e5a4c", -0.25, 0.25, 0.86, 2.00, -0.25, 0.25, 3)
	var fill := [["M_cream", "M_steel", 0.10, 0.18], ["M_mustard", "M_iron", 0.09, 0.14], ["M_teal", "M_steel", 0.10, 0.16],
		["M_coral", "M_iron", 0.08, 0.12], ["M_orange", "M_steel", 0.09, 0.15]]
	for r in tops.size():
		for k in 3:
			var f: Array = fill[(r * 2 + k) % fill.size()]
			_jar(-0.14 + k * 0.14, 0.0, tops[r], f[2], f[3], f[0], f[1])


# 40 x 80 x 60 cm: a steel cabinet of three drawers with pulls and labels.
func _filing_cabinet() -> void:
	_box("C_6878a0", Vector3(-0.20, 0.0, -0.30), Vector3(0.20, 0.80, 0.28))
	for i in 3:
		var y0 := 0.04 + i * 0.255
		_front("C_8996b5", -0.18, y0, 0.18, y0 + 0.23, 0.28)
		_knob(0.0, y0 + 0.17, 0.283, 0.12, 0.025, "M_chrome")
		_front("M_paper", -0.06, y0 + 0.08, 0.06, y0 + 0.13, 0.283)


# 80 x 120 x 50 cm: a vanity cabinet with an oak top, a jar and a plant.
func _bathroom_cabinet() -> void:
	_box("C_c7d2d9", Vector3(-0.38, 0.0, -0.23), Vector3(0.38, 0.08, 0.21))
	_box("C_d8e4ec", Vector3(-0.40, 0.08, -0.25), Vector3(0.40, 0.82, 0.23))
	_box("M_oak", Vector3(-0.40, 0.82, -0.25), Vector3(0.40, 0.86, 0.25))
	_front("C_d8e4ec", -0.37, 0.11, -0.01, 0.79, 0.23)
	_front("C_d8e4ec", 0.01, 0.11, 0.37, 0.79, 0.23)
	_knob(-0.05, 0.66, 0.233, 0.025, 0.08, "M_chrome")
	_knob(0.05, 0.66, 0.233, 0.025, 0.08, "M_chrome")
	_jar(-0.24, -0.06, 0.86, 0.10, 0.16, "M_ceramic", "M_teal")
	_box("M_coral", Vector3(-0.10, 0.86, -0.12), Vector3(0.08, 0.92, 0.06))
	_plant(0.24, -0.04, 0.86, 0.34, "M_ceramic")


# 70 x 50 x 50 cm: a small table with a shelf below, a vase and a book.
func _side_table() -> void:
	_legs("C_907858", -0.33, 0.33, -0.23, 0.23, 0.42)
	_box("C_ac9a82", Vector3(-0.35, 0.42, -0.25), Vector3(0.35, 0.46, 0.25))
	_box("C_907858", Vector3(-0.30, 0.10, -0.20), Vector3(0.30, 0.13, 0.20))
	_rblock("M_teal", -0.15, 0.0, 0.10, 0.10, 0.05, 0.46, 0.58)
	_rblock("M_teal", -0.15, 0.0, 0.06, 0.06, 0.03, 0.58, 0.62)
	_box("M_coral", Vector3(0.04, 0.46, -0.10), Vector3(0.24, 0.49, 0.06))


# 180 x 80 x 50 cm with what's on it: a low unit, doors at the ends and an
# open middle with a console, and a flat screen, books and a plant on top.
func _tv_stand() -> void:
	_box("M_walnut", Vector3(-0.88, 0.0, -0.23), Vector3(0.88, 0.08, 0.21))
	_box("C_604838", Vector3(-0.90, 0.08, -0.25), Vector3(0.90, 0.48, 0.23))
	_box("C_88766a", Vector3(-0.90, 0.48, -0.25), Vector3(0.90, 0.52, 0.25))
	_box("C_907f74", Vector3(-0.28, 0.11, -0.25), Vector3(0.28, 0.45, 0.10))    # the open middle, set back
	_front("C_907f74", -0.87, 0.11, -0.32, 0.45, 0.23)
	_front("C_907f74", 0.32, 0.11, 0.87, 0.45, 0.23)
	_knob(-0.38, 0.28, 0.233, 0.025, 0.08)
	_knob(0.38, 0.28, 0.233, 0.025, 0.08)
	_box("M_black", Vector3(-0.20, 0.11, -0.10), Vector3(0.10, 0.18, 0.09))
	# The screen on its foot.
	_box("M_black", Vector3(-0.10, 0.52, -0.12), Vector3(0.10, 0.54, 0.02))
	_box("M_black", Vector3(-0.03, 0.54, -0.07), Vector3(0.03, 0.58, -0.03))
	_box("M_black", Vector3(-0.38, 0.56, -0.08), Vector3(0.38, 0.80, -0.04))
	_front("M_screen", -0.36, 0.58, 0.36, 0.78, -0.04)
	_books(-0.80, -0.50, 0.52, -0.15, 0.10, 0.20, 4)
	_plant(0.65, -0.02, 0.52, 0.26)


# 60 x 90 x 70 cm: a kitchen base cabinet with a dark worktop.
func _kitchen_corner_cabinet_inner() -> void:
	_box("M_black", Vector3(-0.28, 0.0, -0.33), Vector3(0.28, 0.10, 0.29))
	_box("C_a09888", Vector3(-0.30, 0.10, -0.35), Vector3(0.30, 0.86, 0.32))
	_box("M_worktop", Vector3(-0.30, 0.86, -0.35), Vector3(0.30, 0.90, 0.35))
	_front("C_bcb7ac", -0.27, 0.13, 0.27, 0.64, 0.32)
	_front("C_bcb7ac", -0.27, 0.67, 0.27, 0.83, 0.32)
	_knob(0.0, 0.58, 0.323, 0.12, 0.025, "M_chrome")
	_knob(0.0, 0.75, 0.323, 0.12, 0.025, "M_chrome")


# 120 x 100 x 120 cm: a corner base unit whose front is a quarter round,
# under a stone top, with jars on it.
func _kitchen_corner_cabinet_round() -> void:
	var foot := _quarter(-0.58, -0.58, 0.58, 0.58, 0.76)
	var body := _quarter(-0.60, -0.60, 0.57, 0.57, 0.78)
	var top := _quarter(-0.60, -0.60, 0.60, 0.60, 0.80)
	_band("M_black", foot, 0.0, foot, 0.10)
	_cap("M_black", foot, 0.0, false)
	_band("C_988c78", body, 0.10, body, 0.86)
	_ring("C_988c78", body, foot, 0.10, false)
	_cap("C_988c78", body, 0.86, true)
	_band("M_stone", top, 0.86, top, 0.90)
	_cap("M_stone", top, 0.90, true)
	_ring("M_stone", top, body, 0.86, false)
	for a in [0.25, 0.55, 0.85]:
		var ang: float = a * PI * 0.5
		var r := 0.78 + 0.004
		var c := Vector2(-0.21, -0.21) + Vector2(cos(ang), sin(ang)) * r
		_box("M_steel", Vector3(c.x - 0.02, 0.70, c.y - 0.02), Vector3(c.x + 0.02, 0.80, c.y + 0.02))
	_jar(-0.35, -0.40, 0.90, 0.12, 0.18, "M_ceramic", "M_coral")
	_jar(-0.18, -0.42, 0.90, 0.10, 0.14, "M_mustard", "M_iron")
	_jar(-0.42, -0.20, 0.90, 0.10, 0.12, "M_teal", "M_iron")


# A square from (x0, z0) to (x1, z1) whose front-right corner is rounded to a
# quarter circle of radius r centred at (x1 - r, z1 - r).
func _quarter(x0: float, z0: float, x1: float, z1: float, r: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var c := Vector2(x1 - r, z1 - r)
	for i in SEG * 2 + 1:
		var ang := float(i) / (SEG * 2) * PI * 0.5
		out.append(c + Vector2(cos(ang), sin(ang)) * r)
	out.append(Vector2(x0, z1))
	out.append(Vector2(x0, z0))
	out.append(Vector2(x1, z0))
	return out


# 100 x 60 x 100 cm: a big taped cardboard box with a label.
func _moving_box() -> void:
	_box("C_b89868", Vector3(-0.48, 0.0, -0.48), Vector3(0.48, 0.56, 0.48))
	_box("C_816a49", Vector3(-0.497, 0.56, -0.497), Vector3(0.497, 0.60, 0.497))
	_box("M_tape", Vector3(-0.08, 0.60, -0.497), Vector3(0.08, 0.603, 0.497))
	_front("M_tape", -0.08, 0.40, 0.08, 0.56, 0.48)
	_front("M_paper", 0.16, 0.18, 0.40, 0.34, 0.48)
	_front("M_red", 0.19, 0.27, 0.37, 0.30, 0.483)


# 100 x 110 x 60 cm: a pine stand with two basket bins and folded clothes.
func _laundry_basket() -> void:
	for x in [-0.50, 0.455]:
		for z in [-0.30, 0.255]:
			_box("M_pine", Vector3(x, 0.0, z), Vector3(x + 0.045, 1.10, z + 0.045))
	_box("M_pine", Vector3(-0.47, 0.50, -0.28), Vector3(0.47, 0.53, 0.28))
	_box("M_pine", Vector3(-0.50, 1.06, -0.30), Vector3(0.50, 1.10, 0.30))
	for y in [0.06, 0.53]:
		for x in [-0.23, 0.23]:
			var outer := _rr(x, 0.0, 0.40, 0.48, 0.06)
			var inner := _rr(x, 0.0, 0.34, 0.42, 0.04)
			_band("C_d0c0a8", outer, y, outer, y + 0.38)
			_cap("C_d0c0a8", outer, y, false)
			_ring("C_9c907e", outer, inner, y + 0.38, true)
			_band("C_d0c0a8", inner, y + 0.38, inner, y + 0.05, true)
			_cap("C_d0c0a8", inner, y + 0.05, true)
	_rblock("M_cream", -0.23, 0.0, 0.30, 0.36, 0.05, 0.43, 0.48)
	_rblock("M_blue", 0.23, 0.0, 0.28, 0.34, 0.05, 0.90, 0.95)
	_rblock("M_coral", 0.23, 0.0, 0.24, 0.30, 0.05, 0.95, 0.99)


# 60 x 80 x 70 cm: two bins side by side, one for rubbish, one recycling.
func _trash_can() -> void:
	for side in [[-0.15, "M_leaf"], [0.15, "M_mustard"]]:
		var x: float = side[0]
		var body := _rr(x, 0.0, 0.28, 0.66, 0.06)
		_band("C_707878", body, 0.0, body, 0.70)
		_cap("C_707878", body, 0.0, false)
		_cap("C_707878", body, 0.70, true)
		_rblock(side[1], x, 0.0, 0.30, 0.70, 0.07, 0.70, 0.76)
		_box("M_black", Vector3(x - 0.06, 0.02, 0.33), Vector3(x + 0.06, 0.05, 0.35))
		_box("M_black", Vector3(x - 0.05, 0.76, -0.25), Vector3(x + 0.05, 0.80, -0.20))


# 160 x 220 x 60 cm: a wide wardrobe of two sliding doors, one mirrored,
# under a steel rail.
func _sliding_wardrobe_tall() -> void:
	_box("C_7b5f32", Vector3(-0.78, 0.0, -0.28), Vector3(0.78, 0.08, 0.24))
	_box("C_b08848", Vector3(-0.80, 0.08, -0.30), Vector3(0.80, 2.12, 0.26))
	_box("C_b08848", Vector3(-0.80, 2.12, -0.30), Vector3(0.80, 2.20, 0.28))
	_box("M_steel", Vector3(-0.78, 2.04, 0.26), Vector3(0.78, 2.08, 0.28))
	_front("C_c4a676", -0.77, 0.11, 0.02, 2.02, 0.26)            # back door
	_front("C_c4a676", -0.02, 0.11, 0.77, 2.02, 0.263)           # front door, a layer out
	_front("M_mirror", 0.10, 0.35, 0.69, 1.85, 0.266)
	_knob(-0.06, 1.05, 0.263, 0.025, 0.24, "M_steel")
	_knob(0.04, 1.05, 0.266, 0.025, 0.24, "M_steel")


# 80 x 200 x 30 cm: open shelves of books on castors.
func _sliding_bookcase() -> void:
	var y0 := _castors(-0.40, 0.40, -0.15, 0.15)
	var tops := _shelf_box("C_9a7840", "C_bda783", -0.40, 0.40, y0, 2.00, -0.15, 0.15, 5)
	for i in tops.size():
		if i == 3:
			_books(-0.37, 0.10, tops[i], -0.15, 0.15, 0.28, i)
			_jar(0.25, 0.0, tops[i], 0.10, 0.14, "M_ceramic", "M_teal")
		else:
			_books(-0.37, 0.37, tops[i], -0.15, 0.15, 0.28, i + 2)


# 140 x 110 x 40 cm: a low shelf on castors with wicker baskets and books.
func _rolling_shelf_wide() -> void:
	var y0 := _castors(-0.70, 0.70, -0.20, 0.20)
	var tops := _shelf_box("C_987848", "C_ad936d", -0.70, 0.70, y0, 1.10, -0.20, 0.20, 2)
	for c in 3:
		var x0 := -0.66 + c * 0.45
		_rblock("M_wicker", x0 + 0.20, 0.01, 0.38, 0.32, 0.04, tops[0], tops[0] + 0.28)
		_front("C_bca788", x0 + 0.10, tops[0] + 0.12, x0 + 0.30, tops[0] + 0.19, 0.17)
	_books(-0.66, 0.30, tops[1], -0.20, 0.20, 0.36, 5)
	_jar(0.48, 0.0, tops[1], 0.12, 0.18, "M_ceramic", "M_coral")


# 120 x 220 x 60 cm: a tall rolling unit, a cabinet below and a screen on
# a panel above.
func _rolling_tv_unit() -> void:
	var y0 := _castors(-0.60, 0.60, -0.30, 0.30)
	_box("C_604838", Vector3(-0.60, y0, -0.30), Vector3(0.60, 0.70, 0.28))
	_box("C_88766a", Vector3(-0.60, 0.70, -0.30), Vector3(0.60, 0.74, 0.30))
	_front("C_907f74", -0.57, y0 + 0.03, -0.01, 0.67, 0.28)
	_front("C_907f74", 0.01, y0 + 0.03, 0.57, 0.67, 0.28)
	_knob(-0.05, 0.50, 0.283, 0.025, 0.08)
	_knob(0.05, 0.50, 0.283, 0.025, 0.08)
	_box("C_604838", Vector3(-0.55, 0.74, -0.30), Vector3(0.55, 2.20, -0.24))
	_box("M_black", Vector3(-0.50, 1.10, -0.24), Vector3(0.50, 1.70, -0.20))
	_front("M_screen", -0.47, 1.13, 0.47, 1.67, -0.20)
	_plant(-0.38, 0.0, 0.74, 0.30)
	_box("M_black", Vector3(0.05, 0.74, -0.10), Vector3(0.40, 0.81, 0.15))


# 40 x 210 x 60 cm: a tall, narrow pull-out pantry. Its narrow front faces
# out with a long steel bar; its long sides are open, shelves of jars and
# tins between the front and back panels.
func _pocket_pantry() -> void:
	_box("M_black", Vector3(-0.18, 0.0, -0.28), Vector3(0.18, 0.08, 0.26))
	_box("C_8a7060", Vector3(-0.20, 0.08, 0.24), Vector3(0.20, 2.10, 0.272))     # front panel
	_front("C_a79488", -0.17, 0.11, 0.17, 2.07, 0.272)
	_knob(0.0, 1.10, 0.275, 0.025, 0.50, "M_steel")
	_box("C_8a7060", Vector3(-0.20, 0.08, -0.30), Vector3(0.20, 2.10, -0.27))    # back panel
	_box("C_8a7060", Vector3(-0.20, 2.06, -0.27), Vector3(0.20, 2.10, 0.24))     # top
	var fill := [["M_cream", "M_steel"], ["M_mustard", "M_iron"], ["M_teal", "M_steel"], ["M_coral", "M_iron"], ["M_orange", "M_steel"]]
	for r in 5:
		var y := 0.08 + r * 0.40
		_box("M_steel", Vector3(-0.17, y, -0.27), Vector3(0.17, y + 0.03, 0.24))
		for k in 3:
			var f: Array = fill[(r + k) % fill.size()]
			_jar(0.0, -0.17 + k * 0.17, y + 0.03, 0.10, 0.14 + 0.03 * ((r + k) % 2), f[0], f[1])


# 130 x 100 x 20 cm: a shallow cabinet of two mirrored sliding doors with a
# shelf of jars on top.
func _sliding_bathroom_cabinet() -> void:
	_box("C_d8e4ec", Vector3(-0.65, 0.0, -0.10), Vector3(0.65, 0.80, 0.08))
	_box("C_d8e4ec", Vector3(-0.65, 0.80, -0.10), Vector3(0.65, 0.84, 0.10))
	_front("M_mirror", -0.62, 0.05, 0.02, 0.75, 0.08)
	_front("M_mirror", -0.02, 0.05, 0.62, 0.75, 0.083)
	_knob(-0.06, 0.40, 0.083, 0.025, 0.12, "M_chrome")
	_knob(0.06, 0.40, 0.086, 0.025, 0.12, "M_chrome")
	_jar(-0.45, 0.0, 0.84, 0.10, 0.16, "M_ceramic", "M_chrome")
	_jar(-0.25, 0.0, 0.84, 0.08, 0.12, "M_teal", "M_chrome")
	_rblock("M_coral", 0.30, 0.0, 0.18, 0.12, 0.05, 0.84, 0.92)
	_rblock("M_ceramic", 0.30, 0.0, 0.16, 0.10, 0.04, 0.92, 0.98)


# ── more building blocks ────────────────────────────────────────────────────

# A rounded shape standing out of a face along Z: a porthole, a dial. The
# loop is in X and Y around (cx, cy), from z0 out to z1.
func _zblock(mat: String, cx: float, cy: float, w: float, h: float, r: float, z0: float, z1: float) -> void:
	var loop := _rr(cx, cy, w, h, r)
	var c := Vector2(cx, cy)
	for i in loop.size():
		var j := (i + 1) % loop.size()
		var mid := (loop[i] + loop[j]) * 0.5 - c
		_quad(mat, Vector3(loop[i].x, loop[i].y, z0), Vector3(loop[j].x, loop[j].y, z0),
			Vector3(loop[j].x, loop[j].y, z1), Vector3(loop[i].x, loop[i].y, z1), Vector3(mid.x, mid.y, 0.0))
		_tri(mat, Vector3(cx, cy, z1), Vector3(loop[i].x, loop[i].y, z1), Vector3(loop[j].x, loop[j].y, z1), Vector3.BACK)
		_tri(mat, Vector3(cx, cy, z0), Vector3(loop[i].x, loop[i].y, z0), Vector3(loop[j].x, loop[j].y, z0), Vector3.FORWARD)


# A round dial on the face at z.
func _dial(cx: float, cy: float, z: float, d := 0.05, mat := "M_chrome") -> void:
	_zblock(mat, cx, cy, d, d, d * 0.5, z, z + 0.025)


# A base cabinet run from x0 to x1: black plinth, body, flush fronts split
# into `doors` doors (each with a drawer above when `drawers`), handles.
# The worktop is separate (_worktop). Front face at z1.
func _base_run(body: String, front: String, x0: float, x1: float, z0: float, z1: float, doors: int, drawers := true) -> void:
	_box("M_black", Vector3(x0 + 0.02, 0.0, z0 + 0.02), Vector3(x1 - 0.02, 0.10, z1 - 0.04))
	_box(body, Vector3(x0, 0.10, z0), Vector3(x1, 0.86, z1))
	var w := (x1 - x0) / doors
	for d in doors:
		var a := x0 + d * w + 0.02
		var b := x0 + (d + 1) * w - 0.02
		if drawers:
			_front(front, a, 0.13, b, 0.66, z1)
			_front(front, a, 0.69, b, 0.83, z1)
			_knob((a + b) * 0.5, 0.78, z1 + 0.003, minf(0.16, (b - a) * 0.5), 0.025, "M_chrome")
		else:
			_front(front, a, 0.13, b, 0.83, z1)
		_knob(b - 0.05 if d % 2 == 0 else a + 0.05, 0.56, z1 + 0.003, 0.025, 0.12, "M_chrome")


# A worktop slab over a base run, 2 cm proud at the front.
func _worktop(mat: String, x0: float, x1: float, z0: float, z1: float, y := 0.86, t := 0.04) -> void:
	_box(mat, Vector3(x0, y, z0), Vector3(x1, y + t, z1))


# A steel basin let into a worktop whose top is at y, centred on (cx, cz),
# with a tap behind it.
func _basin(cx: float, cz: float, y: float, w: float, d: float) -> void:
	var rim := _rr(cx, cz, w, d, 0.04)
	var inner := _rr(cx, cz, w - 0.05, d - 0.05, 0.03)
	var floor := _rr(cx, cz, w - 0.09, d - 0.09, 0.025)
	_band("M_steel", rim, y - 0.002, rim, y + 0.006)
	_ring("M_steel", rim, inner, y - 0.002, false)
	_ring("M_steel", rim, inner, y + 0.006, true)
	_band("M_steel", inner, y + 0.006, inner, y - 0.002, true)
	_band("M_steel", inner, y - 0.002, floor, y - 0.14, true)
	_cap("M_iron", floor, y - 0.14, true)
	_box("M_chrome", Vector3(cx - 0.02, y, cz - d * 0.5 - 0.06), Vector3(cx + 0.02, y + 0.14, cz - d * 0.5 - 0.02))
	_box("M_chrome", Vector3(cx - 0.02, y + 0.10, cz - d * 0.5 - 0.06), Vector3(cx + 0.02, y + 0.14, cz - d * 0.2))


# A hob: a black glass plate with `n` rings (2 or 4) on top of y.
func _hob(cx: float, cz: float, y: float, w: float, d: float, n := 4) -> void:
	_box("M_black", Vector3(cx - w * 0.5, y, cz - d * 0.5), Vector3(cx + w * 0.5, y + 0.02, cz + d * 0.5))
	var spots := [Vector2(-0.25, -0.25), Vector2(0.25, -0.25), Vector2(-0.25, 0.25), Vector2(0.25, 0.25)]
	if n == 2:
		spots = [Vector2(0.0, -0.25), Vector2(0.0, 0.25)]
	for sp in spots:
		var px: float = cx + sp.x * w
		var pz: float = cz + sp.y * d
		_rblock("M_iron", px, pz, 0.17, 0.17, 0.085, y + 0.02, y + 0.024)


# An oven door on the face at z: black, with a window and a bar.
func _oven(x0: float, y0: float, x1: float, y1: float, z: float) -> void:
	_front("M_black", x0, y0, x1, y1, z)
	_front("M_screen", x0 + 0.06, y0 + 0.08, x1 - 0.06, y1 - 0.14, z + 0.003)
	_box("M_chrome", Vector3(x0 + 0.06, y1 - 0.08, z + 0.003), Vector3(x1 - 0.06, y1 - 0.055, z + 0.035))


# An appliance body: a box with softened vertical edges, a black base.
func _appliance(body: String, x0: float, x1: float, z0: float, z1: float, y1: float) -> void:
	_box("M_black", Vector3(x0 + 0.02, 0.0, z0 + 0.02), Vector3(x1 - 0.02, 0.04, z1 - 0.03))
	_rblock(body, (x0 + x1) * 0.5, (z0 + z1) * 0.5, x1 - x0, z1 - z0, 0.03, 0.04, y1)


# A washing machine's porthole on the face at z, centred at (cx, cy).
func _porthole(cx: float, cy: float, z: float, d: float) -> void:
	_zblock("M_chrome", cx, cy, d, d, d * 0.5, z, z + 0.03)
	_zblock("M_glass", cx, cy, d * 0.72, d * 0.72, d * 0.36, z + 0.03, z + 0.033)


# A laundry machine, front-loading, from y0 to y1 on the face at z.
func _laundry_machine(body: String, front: String, x0: float, x1: float, y0: float, y1: float, z0: float, z1: float) -> void:
	_box(body, Vector3(x0, y0, z0), Vector3(x1, y1, z1))
	var cx := (x0 + x1) * 0.5
	_front(front, x0 + 0.02, y1 - 0.13, x1 - 0.02, y1 - 0.02, z1)
	_front("M_screen", cx - 0.08, y1 - 0.10, cx + 0.08, y1 - 0.05, z1 + 0.003)
	_dial(x1 - 0.10, y1 - 0.075, z1 + 0.003)
	_porthole(cx, y0 + (y1 - y0 - 0.13) * 0.5, z1, minf(x1 - x0, y1 - y0) * 0.6)


# ── batch 2: kitchen and appliances ─────────────────────────────────────────

# 240 x 220 x 60 cm: a fitted kitchen: base cabinets with a sink and an oven
# under a hob, a tiled splashback, wall cabinets and a hood.
func _kitchen() -> void:
	var body := "C_a09888"
	var front := "C_bcb7ac"
	_base_run(body, front, -1.20, 0.20, -0.30, 0.27, 3)
	_base_run(body, front, 0.80, 1.20, -0.30, 0.27, 1)
	_box(body, Vector3(0.20, 0.10, -0.30), Vector3(0.80, 0.86, 0.27))
	_box("M_black", Vector3(0.22, 0.0, -0.28), Vector3(0.78, 0.10, 0.23))
	_oven(0.23, 0.13, 0.77, 0.80, 0.27)
	_worktop("M_worktop", -1.20, 1.20, -0.30, 0.30)
	_basin(-0.75, 0.0, 0.90, 0.50, 0.40)
	_hob(0.50, 0.0, 0.90, 0.56, 0.46)
	_box("M_stone", Vector3(-1.20, 0.90, -0.30), Vector3(1.20, 1.45, -0.27))
	# Wall cabinets, with a hood over the hob.
	_box(body, Vector3(-1.20, 1.45, -0.30), Vector3(0.18, 2.20, 0.05))
	_box(body, Vector3(0.82, 1.45, -0.30), Vector3(1.20, 2.20, 0.05))
	for x in [[-1.18, -0.73], [-0.71, -0.26], [-0.24, 0.16], [0.84, 1.18]]:
		_front(front, x[0], 1.48, x[1], 2.17, 0.05)
		_knob(x[1] - 0.05, 1.56, 0.053, 0.025, 0.10, "M_chrome")
	_box("M_steel", Vector3(0.24, 1.75, -0.30), Vector3(0.76, 2.20, -0.10))
	_box("M_steel", Vector3(0.20, 1.60, -0.30), Vector3(0.80, 1.75, 0.10))
	# On the worktop: a board, jars.
	_box("M_oak", Vector3(-0.30, 0.90, -0.20), Vector3(0.02, 0.93, 0.10))
	_jar(-1.05, -0.15, 0.90, 0.10, 0.16, "M_teal", "M_iron")
	_jar(-0.92, -0.18, 0.90, 0.09, 0.13, "M_sage", "M_iron")
	_jar(1.00, -0.12, 0.90, 0.11, 0.18, "M_mustard", "M_iron")


# 120 x 100 x 120 cm: a compact L of counter along the back and the left: a
# sink on the left arm, two rings and a small oven on the back.
func _kitchen_small() -> void:
	var body := "C_908878"
	var front := "C_bcb7ac"
	_base_run(body, front, -0.60, 0.60, -0.60, -0.02, 2)
	_box("M_black", Vector3(-0.58, 0.0, -0.02), Vector3(-0.06, 0.10, 0.56))
	_box(body, Vector3(-0.60, 0.10, -0.02), Vector3(-0.02, 0.86, 0.60))
	_front(front, -0.60, 0.13, -0.02, 0.83, -0.02)   # never seen; keeps the corner closed
	for z in [[0.0, 0.28], [0.32, 0.58]]:
		_box(front, Vector3(-0.02, 0.13, z[0]), Vector3(-0.017, 0.83, z[1]))
		_box("M_chrome", Vector3(-0.017, 0.53, z[1] - 0.05), Vector3(0.008, 0.65, z[1] - 0.025))
	_worktop("M_worktop", -0.60, 0.60, -0.60, 0.0)
	_worktop("M_worktop", -0.60, 0.0, 0.0, 0.60)
	_basin(-0.30, 0.30, 0.90, 0.40, 0.36)
	_hob(0.30, -0.30, 0.90, 0.40, 0.44, 2)
	_jar(0.45, -0.48, 0.90, 0.09, 0.14, "M_coral", "M_iron")


# 140 x 90 x 80 cm: an island of drawers and doors under a stone top that
# overhangs at the back for stools.
func _kitchen_island() -> void:
	_base_run("C_c0b090", "C_d3c8b1", -0.70, 0.70, -0.25, 0.37, 3)
	_box("M_stone", Vector3(-0.70, 0.86, -0.40), Vector3(0.70, 0.90, 0.40))
	_box("M_oak", Vector3(-0.20, 0.90, -0.10), Vector3(0.18, 0.93, 0.15))


# 90 x 90 x 60 cm: a small island on castors: an oak top, a cupboard and an
# open shelf of bowls, a towel bar.
func _rolling_island() -> void:
	var y0 := _castors(-0.45, 0.45, -0.30, 0.30)
	_box("C_c0b090", Vector3(-0.45, y0, -0.28), Vector3(-0.42, 0.86, 0.28))
	_box("C_c0b090", Vector3(0.42, y0, -0.28), Vector3(0.45, 0.86, 0.28))
	_box("C_c0b090", Vector3(-0.42, y0, -0.28), Vector3(0.42, y0 + 0.03, 0.28))
	_box("C_c0b090", Vector3(-0.42, 0.42, -0.28), Vector3(0.42, 0.45, 0.28))
	_box("C_c0b090", Vector3(0.0, 0.45, -0.28), Vector3(0.42, 0.86, 0.25))
	_front("C_d3c8b1", 0.02, 0.48, 0.40, 0.83, 0.25)
	_knob(0.07, 0.75, 0.253, 0.025, 0.08, "M_chrome")
	_box("M_oak", Vector3(-0.45, 0.86, -0.30), Vector3(0.45, 0.90, 0.30))
	_box("M_chrome", Vector3(-0.45, 0.70, 0.28), Vector3(-0.02, 0.725, 0.30))
	for k in 3:
		var x := -0.28 + k * 0.20
		_jar(x, 0.0, y0 + 0.03, 0.14, 0.10, ["M_ceramic", "M_teal", "M_coral"][k], "M_ceramic")
	_jar(-0.22, 0.0, 0.45, 0.12, 0.14, "M_teal", "M_iron")


# 60 x 80 x 50 cm: a base cabinet with a steel sink and a tap.
func _kitchen_sink() -> void:
	_base_run("C_c8ccd0", "M_white", -0.30, 0.30, -0.25, 0.22, 2, false)
	_worktop("M_worktop", -0.30, 0.30, -0.25, 0.25)
	_basin(0.0, 0.03, 0.90, 0.46, 0.36)


# 60 x 90 x 60 cm: a freestanding cooker: steel sides, four rings on a
# black top, a strip of red dials and an oven door in a dark front.
func _stove() -> void:
	# Kept inside its square: a footprint as deep as it is wide is turned 90
	# degrees by the game if the model comes out deeper than wide.
	_appliance("M_steel", -0.30, 0.30, -0.30, 0.26, 0.86)
	_front("C_303030", -0.28, 0.06, 0.28, 0.84, 0.26)
	_hob(0.0, -0.02, 0.86, 0.60, 0.54)
	_box("M_steel", Vector3(-0.30, 0.86, -0.30), Vector3(0.30, 0.92, -0.26))
	for k in 4:
		_dial(-0.195 + k * 0.13, 0.785, 0.263, 0.045, "M_red")
	_front("M_screen", 0.15, 0.77, 0.25, 0.80, 0.263)
	_oven(-0.26, 0.09, 0.26, 0.72, 0.263)


# 70 x 180 x 80 cm: a fridge, fridge above, freezer below, long bars.
func _fridge() -> void:
	_appliance("C_c0ccd8", -0.35, 0.35, -0.40, 0.36, 1.80)
	_front("C_d6dee6", -0.33, 0.06, 0.33, 0.62, 0.36)
	_front("C_d6dee6", -0.33, 0.65, 0.33, 1.77, 0.36)
	_knob(0.26, 0.45, 0.363, 0.025, 0.24, "M_chrome")
	_knob(0.26, 0.95, 0.363, 0.025, 0.40, "M_chrome")
	_front("M_screen", -0.16, 1.45, 0.0, 1.55, 0.363)


# 90 x 220 x 80 cm: a double-door fridge over a freezer drawer.
func _fridge_large() -> void:
	_appliance("C_b8c4d0", -0.45, 0.45, -0.40, 0.36, 2.20)
	_front("C_d1d9e0", -0.43, 0.06, 0.43, 0.72, 0.36)
	_front("C_d1d9e0", -0.43, 0.75, -0.01, 2.17, 0.36)
	_front("C_d1d9e0", 0.01, 0.75, 0.43, 2.17, 0.36)
	_knob(0.0, 0.64, 0.363, 0.40, 0.025, "M_chrome")
	_knob(-0.06, 1.30, 0.363, 0.025, 0.50, "M_chrome")
	_knob(0.06, 1.30, 0.363, 0.025, 0.50, "M_chrome")
	_front("M_screen", -0.32, 1.55, -0.14, 1.68, 0.363)


# 110 x 90 x 70 cm: a chest freezer: a white box, a lid with a bar.
func _chest_freezer() -> void:
	_appliance("C_dfe6ec", -0.55, 0.55, -0.35, 0.32, 0.84)
	_box("C_f0f3f6", Vector3(-0.55, 0.84, -0.35), Vector3(0.55, 0.90, 0.33))
	_box("M_chrome", Vector3(-0.20, 0.80, 0.33), Vector3(0.20, 0.825, 0.35))
	_front("M_screen", 0.32, 0.62, 0.46, 0.68, 0.32)


# 60 x 160 x 70 cm: an upright freezer with one door and a bar.
func _upright_freezer() -> void:
	_appliance("C_d4dce4", -0.30, 0.30, -0.35, 0.32, 1.60)
	_front("C_e2e8ee", -0.28, 0.06, 0.28, 1.57, 0.32)
	_knob(0.21, 1.10, 0.323, 0.025, 0.40, "M_chrome")
	_front("M_screen", -0.14, 1.36, 0.0, 1.46, 0.323)


# 60 x 90 x 70 cm: a small fridge with a worktop on it.
func _mini_fridge() -> void:
	_appliance("C_c8d4e0", -0.29, 0.29, -0.35, 0.32, 0.86)
	_front("C_dbe3eb", -0.27, 0.06, 0.27, 0.83, 0.32)
	_knob(0.20, 0.55, 0.323, 0.025, 0.24, "M_chrome")
	_box("M_worktop", Vector3(-0.30, 0.86, -0.35), Vector3(0.30, 0.90, 0.35))


# 70 x 90 x 60 cm: a front-loading washing machine.
func _washer() -> void:
	_box("M_black", Vector3(-0.33, 0.0, -0.28), Vector3(0.33, 0.04, 0.24))
	_laundry_machine("C_d0d0d0", "C_dedede", -0.35, 0.35, 0.04, 0.90, -0.30, 0.27)


# 80 x 220 x 70 cm: a dryer stacked on a washer, a shelf of detergent above.
func _washer_dryer_stack() -> void:
	_box("M_black", Vector3(-0.38, 0.0, -0.33), Vector3(0.38, 0.04, 0.29))
	_laundry_machine("C_c8c8c8", "C_d8d8d8", -0.40, 0.40, 0.04, 0.90, -0.35, 0.32)
	_laundry_machine("C_c8c8c8", "C_d8d8d8", -0.40, 0.40, 0.92, 1.78, -0.35, 0.32)
	_box("M_iron", Vector3(-0.40, 0.90, -0.35), Vector3(0.40, 0.92, 0.32))
	_box("M_oak", Vector3(-0.40, 1.90, -0.35), Vector3(0.40, 1.94, 0.05))
	_jar(-0.25, -0.15, 1.94, 0.10, 0.20, "M_blue", "M_ceramic")
	_jar(-0.10, -0.15, 1.94, 0.09, 0.16, "M_teal", "M_ceramic")
	_box("M_ceramic", Vector3(0.05, 1.94, -0.25), Vector3(0.30, 2.00, -0.02))


# 70 x 60 x 70 cm: a walnut vanity with a stone top and a square basin
# standing on it, a tap behind.
func _sink_square() -> void:
	_box("M_black", Vector3(-0.33, 0.0, -0.33), Vector3(0.33, 0.06, 0.29))
	_box("M_walnut", Vector3(-0.35, 0.06, -0.35), Vector3(0.35, 0.42, 0.32))
	_front("M_oak", -0.32, 0.09, 0.32, 0.39, 0.32)
	_knob(0.0, 0.33, 0.323, 0.16, 0.025, "M_chrome")
	_box("M_stone", Vector3(-0.35, 0.42, -0.35), Vector3(0.35, 0.45, 0.35))
	var outer := _rr(0.0, 0.05, 0.46, 0.40, 0.06)
	var inner := _rr(0.0, 0.05, 0.38, 0.32, 0.04)
	var bottom := _rr(0.0, 0.05, 0.32, 0.26, 0.03)
	_band("C_c8d8e8", outer, 0.45, outer, 0.56)
	_ring("C_c8d8e8", outer, inner, 0.56, true)
	_band("C_c8d8e8", inner, 0.56, bottom, 0.48, true)
	_cap("C_c8d8e8", bottom, 0.48, true)
	_cap("M_water", _rr(0.0, 0.05, 0.35, 0.29, 0.035), 0.52, true)
	_box("M_chrome", Vector3(-0.02, 0.45, -0.25), Vector3(0.02, 0.60, -0.21))
	_box("M_chrome", Vector3(-0.02, 0.56, -0.21), Vector3(0.02, 0.60, -0.10))


# 80 x 200 x 80 cm: a corner shower: a tray, two tiled walls at the back
# and the left, a chrome frame on the other two sides, a head. The frame
# stands for glass: the style system draws every material solid, so a
# glass pane would hide the shower.
func _shower() -> void:
	_box("M_stone", Vector3(-0.40, 0.0, -0.40), Vector3(0.40, 0.08, 0.40))
	_box("M_ceramic", Vector3(-0.36, 0.08, -0.36), Vector3(0.40, 0.09, 0.40))
	_rblock("M_steel", 0.05, 0.05, 0.08, 0.08, 0.04, 0.09, 0.093)
	_box("C_b8ccd8", Vector3(-0.40, 0.08, -0.40), Vector3(0.40, 2.00, -0.36))
	_box("C_b8ccd8", Vector3(-0.40, 0.08, -0.36), Vector3(-0.36, 2.00, 0.40))
	# Glass, framed.
	_box("M_chrome", Vector3(0.38, 0.08, -0.36), Vector3(0.40, 1.95, -0.34))
	_box("M_chrome", Vector3(0.38, 0.08, 0.38), Vector3(0.40, 1.95, 0.40))
	_box("M_chrome", Vector3(-0.36, 0.08, 0.38), Vector3(-0.34, 1.95, 0.40))
	_box("M_chrome", Vector3(0.38, 1.93, -0.36), Vector3(0.40, 1.95, 0.40))
	_box("M_chrome", Vector3(-0.36, 1.93, 0.38), Vector3(0.40, 1.95, 0.40))
	_box("M_chrome", Vector3(0.38, 1.00, -0.34), Vector3(0.40, 1.02, 0.38))
	_box("M_chrome", Vector3(-0.34, 1.00, 0.38), Vector3(0.38, 1.02, 0.40))
	# The head, its pipe and a mixer.
	_box("M_chrome", Vector3(-0.025, 1.00, -0.36), Vector3(0.025, 1.85, -0.335))
	_box("M_chrome", Vector3(-0.025, 1.82, -0.36), Vector3(0.025, 1.85, -0.15))
	_rblock("M_chrome", 0.0, -0.12, 0.16, 0.16, 0.08, 1.78, 1.82)
	_box("M_chrome", Vector3(-0.06, 1.05, -0.36), Vector3(0.06, 1.12, -0.32))
	_box("M_coral", Vector3(-0.36, 1.20, 0.05), Vector3(-0.32, 1.50, 0.30))


# 60 x 100 x 40 cm: a three-tier cart on castors: an oak top, a wicker
# basket, a shelf of jars.
func _rolling_kitchen_cart() -> void:
	var y0 := _castors(-0.30, 0.30, -0.20, 0.20)
	for x in [-0.30, 0.27]:
		for z in [-0.20, 0.17]:
			_box("M_steel", Vector3(x, y0, z), Vector3(x + 0.03, 0.96, z + 0.03))
	_box("M_steel", Vector3(-0.27, 0.12, -0.17), Vector3(0.27, 0.14, 0.17))
	_box("M_steel", Vector3(-0.27, 0.48, -0.17), Vector3(0.27, 0.50, 0.17))
	_box("M_oak", Vector3(-0.30, 0.96, -0.20), Vector3(0.30, 1.00, 0.20))
	_rblock("M_wicker", 0.0, 0.0, 0.48, 0.30, 0.04, 0.50, 0.70)
	_rblock("M_coral", -0.08, 0.0, 0.20, 0.16, 0.05, 0.70, 0.74)
	_jar(-0.16, 0.0, 0.14, 0.10, 0.16, "M_teal", "M_walnut")
	_jar(0.0, 0.0, 0.14, 0.10, 0.12, "M_sage", "M_walnut")
	_jar(0.16, 0.0, 0.14, 0.10, 0.18, "M_orange", "M_walnut")
