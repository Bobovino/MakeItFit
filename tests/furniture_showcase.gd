extends Control

# Dev showcase: furnishes one themed room per run-through (bedrooms, living
# room, kitchen, bathroom...) with the catalogue's pieces, using the game's
# own placement rules and its real Room3DView, and saves a screenshot of each
# room with everything folded and another with every foldable piece open.
# Between them the rooms cover the whole catalogue.
#
#   godot --path . res://tests/FurnitureShowcase.tscn -- --shots=<dir> [--room=<name>]
#
# Layout per room: wall-hung pieces on the west end of the north wall, floor
# pieces along the rest of it ("north"), more along the east wall turned to
# face the room ("east"), and the rest in rows in the middle ("centre").
# "on" stacks small things on a surface: [id, host id, dx, dy] in tiles.

const ROOMS := [
	{"name": "bedroom_double", "palette": "dusty_rose",
		"wall": ["mirror", "painting"],
		"north": ["wardrobe", "double_bed", "nightstand"],
		"east": ["dresser", "floor_mirror"],
		"centre": ["ottoman", "floor_lamp"]},
	{"name": "bedroom_single", "palette": "slate",
		"wall": ["wall_shelf"],
		"north": ["sliding_wardrobe_tall", "normal_bed"],
		"east": ["clothes_rack"],
		"centre": ["storage_bed", "rolling_clothes_rack"]},
	{"name": "kids_room", "palette": "sage",
		"north": ["bunk_bed", "high_bed"],
		"east": ["bird_cage"],
		"centre": ["trundle_bed", "moving_box"]},
	{"name": "loft_room", "palette": "ochre",
		"north": ["sliding_pocket_bed", "desk_bed_combo"],
		"east": ["stair_n"],
		"centre": ["platform_bed_podium"]},
	{"name": "guest_room_1", "palette": "plum",
		"wall": ["murphy_bed_double"],
		"north": ["murphy_bed", "cabinet_guest_bed"],
		"centre": ["futon", "ottoman_bed", "armchair_bed"]},
	{"name": "guest_room_2", "palette": "terracotta",
		"wall": ["murphy_bed_sofa"],
		"north": ["sofa_bed", "bench_bed"],
		"centre": ["design_sofa_bed", "corner_sofa_bed"]},
	{"name": "living_room_1", "palette": "teal",
		"wall": ["tv", "wall_hanger"],
		"north": ["bookshelf", "tv_stand", "closed_bookcase"],
		"east": ["wide_bookcase", "expanding_shelf"],
		"centre": ["sofa", "coffee_table", "lounge_chair", "side_table", "plant"]},
	{"name": "living_room_2", "palette": "dusty_rose",
		"wall": ["wall_plant"],
		"north": ["rolling_tv_unit", "cushioned_bench"],
		"east": ["sliding_bookcase", "rolling_shelf_wide", "fluted_glass_panel"],
		"centre": ["design_sofa", "lift_coffee_table", "puff", "stool", "nesting_tables", "curtain"]},
	{"name": "kitchen_1", "palette": "ochre",
		"wall": ["wall_cabinet", "kitchen_rack"],
		"north": ["fridge", "kitchen", "pantry"],
		"east": ["stove", "kitchen_sink"],
		"centre": ["kitchen_island", "trash_can"]},
	{"name": "kitchen_2", "palette": "sage",
		"wall": ["fold_down_breakfast_bar", "fold_out_counter"],
		"north": ["fridge_large", "hidden_kitchenette", "kitchen_tower"],
		"east": ["mini_fridge", "kitchen_corner_cabinet_inner", "pocket_pantry"],
		"centre": ["kitchen_small", "rolling_kitchen_cart"]},
	{"name": "kitchen_3", "palette": "slate",
		"north": ["movable_island_wall"],
		"centre": ["kitchen_corner_cabinet_round", "rolling_island", "under_counter_table"]},
	{"name": "dining_1", "palette": "terracotta",
		"wall": ["wall_dining_table", "wall_folding_seat"],
		"north": ["console_dining_table", "folding_storage_bench"],
		"east": ["bench", "banquette_bench"],
		"centre": ["dining_table", "dining_chair", "stacking_stools"]},
	{"name": "dining_2", "palette": "plum",
		"wall": ["murphy_table"],
		"north": ["extending_bar_table", "picnic_bench_table", "folding_chair"],
		"east": ["low_bench"],
		"centre": ["extending_table", "drop_leaf_table", "folding_glass_table"]},
	{"name": "office_1", "palette": "slate",
		"wall": ["murphy_desk", "whiteboard"],
		"north": ["secretary_desk", "bookcase_desk", "filing_cabinet"],
		"centre": ["desk", "office_chair", "standing_desk"],
		"on": [["desk_lamp", "desk", 9, 1], ["keyboard", "desk", 4, 3], ["computer_mouse", "desk", 7, 3],
			["monitor", "filing_cabinet", 0, 2]]},
	{"name": "office_2", "palette": "sage",
		"wall": ["wall_laptop_desk"],
		"north": ["corner_fold_desk", "vanity_desk"],
		"centre": ["small_desk", "rolling_desk"]},
	{"name": "bathroom_1", "palette": "teal", "floor_kind": "bathroom",
		"wall": ["mirror_cabinet", "towel_rack"],
		"north": ["sink", "toilet", "bathtub"],
		"east": ["bathroom_cabinet"]},
	{"name": "bathroom_2", "palette": "dusty_rose", "floor_kind": "bathroom",
		"wall": ["towel_set"],
		"north": ["sink_square", "shower", "sliding_bathroom_cabinet"],
		"east": ["laundry_basket"]},
	{"name": "bathroom_laundry", "palette": "slate", "floor_kind": "bathroom",
		"north": ["folding_shower", "pull_out_hamper", "washer", "washer_dryer_stack"]},
	{"name": "balcony", "palette": "sage", "floor_kind": "balcony",
		"north": ["planter_box", "plant"],
		"centre": ["outdoor_table", "sun_lounger"]},
	{"name": "storage", "palette": "ochre",
		"north": ["balcony_window", "floor_hatch_storage"],
		"east": ["stair_s"],
		"centre": ["ceiling_lift_storage", "shoebox_apartment", "rental_capsule", "rental_student"]},
	{"name": "fold_stairs", "palette": "slate",
		"north": ["fold_stair_e", "fold_stair_w"],
		"centre": ["lounge_chair", "plant"]},
	{"name": "boxes_and_stairs", "palette": "terracotta",
		"north": ["stair_e", "stair_w"],
		"centre": ["rental_bunk", "rental_garret", "rental_nook", "rental_couple", "rental_family", "rental_penthouse"]},
]

const GAP := 2
const AISLE := 5

var _catalog: Array = []
var _by_id: Dictionary = {}
var _view: Room3DView
var _floor: Floor
var _placed: Dictionary = {}   # id -> Furniture
var _report: Array = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_catalog = (JSON.parse_string(FileAccess.get_file_as_string("res://data/furniture.json")) as Dictionary)["furniture"]
	for e in _catalog:
		_by_id[(e as Dictionary)["id"]] = e
	var out_dir := "user://showcase"
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			out_dir = arg.trim_prefix("--shots=")
		if arg.begins_with("--room="):
			only = arg.trim_prefix("--room=")
	_run(out_dir, only)


func _dims(id: String) -> Vector3i:
	var e := _by_id[id] as Dictionary
	var add: int = (e.get("extended_add_h", 0) as int) if (e.get("foldable", false) as bool) else 0
	return Vector3i((e["size"] as Dictionary)["w"] as int, (e["size"] as Dictionary)["h"] as int, add)


func _new_furniture(id: String) -> Furniture:
	var f := (load("res://scenes/Furniture.tscn") as PackedScene).instantiate() as Furniture
	_floor.add_child(f)
	f.setup(_by_id[id] as Dictionary, _floor)
	return f


# Tries `at`, then slides along (dx, dy) a tile at a time until the game's own
# rules accept the spot.
func _place(id: String, at: Vector2i, step: Vector2i, rot: int = 0, tries: int = 30) -> Furniture:
	var f := _new_furniture(id)
	if rot != 0:
		f.set_rot_steps(rot)
	var reason := ""
	for i in tries:
		var p := Vector2(at + step * i)
		if _floor.can_place(f, p):
			_floor.place_furniture(f, p)
			f.position = p * Furniture.TILE_SIZE
			_placed[id] = f
			return f
		reason = _floor.get_block_reason()
	_report.append("NOT PLACED %s: %s" % [id, reason])
	f.queue_free()
	return null


func _build_room(room: Dictionary) -> void:
	_placed.clear()
	var wall_ids: Array = room.get("wall", [])
	var north: Array = room.get("north", [])
	var east: Array = room.get("east", [])
	var centre: Array = room.get("centre", [])

	# ---- sizes ----
	var wall_w := 1
	var wall_depth := 0
	for id in wall_ids:
		var e := _by_id[id] as Dictionary
		wall_w += ((e["size"] as Dictionary)["w"] as int) + GAP
		wall_depth = maxi(wall_depth, e.get("floor_depth", 1) as int)
	var north_w := 0
	var north_d := wall_depth
	for id in north:
		var d := _dims(id)
		north_w += d.x + GAP
		north_d = maxi(north_d, d.y + d.z)
	var east_len := 0
	var east_d := 0
	for id in east:
		var d := _dims(id)
		east_len += d.x + GAP
		east_d = maxi(east_d, d.y)
	var centre_w := 0
	for id in centre:
		centre_w += _dims(id).x + AISLE
	var w := clampi(maxi(wall_w + north_w + 3 + 3 * north.size(), mini(centre_w, 46) + east_d + AISLE + 6), 30, 110)
	# centre rows
	var rows: Array = [[]]
	var row_w := 0
	var usable := w - east_d - AISLE - 6
	for id in centre:
		var d := _dims(id)
		if row_w + d.x > usable and not (rows[-1] as Array).is_empty():
			rows.append([])
			row_w = 0
		(rows[-1] as Array).append(id)
		row_w += d.x + AISLE
	var centre_d := 0
	for r in rows:
		var rd := 0
		for id in r:
			var d := _dims(id)
			rd = maxi(rd, d.y + d.z)
		centre_d += rd + AISLE
	var d_total := maxi(north_d + AISLE + centre_d, north_d + GAP + east_len + 2 * east.size()) + 2
	d_total = maxi(d_total, 22)

	# ---- floor ----
	var x1 := 1 + w
	var y1 := 1 + d_total
	var floor_data := {
		"id": "showcase_" + (room["name"] as String), "label": room["name"], "grid_w": w + 10, "grid_h": d_total + 10,
		"floor_tiles": [],
		"segments": [
			{"x1": 1, "y1": 1, "x2": x1, "y2": 1, "primary": true, "demolished": false},
			{"x1": x1, "y1": 1, "x2": x1, "y2": y1, "primary": true, "demolished": false},
			{"x1": x1, "y1": y1, "x2": 1, "y2": y1, "primary": true, "demolished": false,
				"has_window": true, "window_pos": 4, "window_len": 12},
			{"x1": 1, "y1": y1, "x2": 1, "y2": 1, "primary": true, "demolished": false,
				"has_window": true, "window_pos": 6, "window_len": 12},
		],
	}
	if is_instance_valid(_floor):
		_floor.queue_free()
	_floor = (load("res://scenes/Wall.tscn") as PackedScene).instantiate() as Floor
	_floor.visible = false
	add_child(_floor)
	_floor.setup(floor_data)
	var kind := room.get("floor_kind", "") as String
	if kind != "":
		for tx in range(1, x1):
			for ty in range(1, y1):
				_floor.paint_floor_kind(Vector2i(tx, ty), kind)

	# ---- wall-hung pieces: west end of the north wall ----
	var cx := 1
	for id in wall_ids:
		var e := _by_id[id] as Dictionary
		var iw: int = (e["size"] as Dictionary)["w"] as int
		var ih: int = e["wall_h"] as int
		# tall pieces and the fold-out ones stand on the floor line; the rest hang at eye level
		var bottom := 0
		if ih < 16 and not ((e.get("foldable", false) as bool) and id != "mirror_cabinet"):
			bottom = clampi(14 - ih / 2, 0, Room3DView.WALL_TILES - ih)
		_floor.place_wall_item("north", Vector2i(cx, Room3DView.WALL_TILES - ih - bottom), id as String)
		cx += iw + GAP

	# ---- north band ----
	var b := _floor.get_room_bounds()
	# the wall itself takes the first tile on the north and west sides
	var bx0 := b.position.x + 1
	var by0 := b.position.y + 1
	var bx1 := b.position.x + b.size.x
	var nx := bx0 + wall_w
	for id in north:
		var f := _place(id, Vector2i(nx, by0), Vector2i(1, 0))
		var d := _dims(id)
		nx = (int(f.grid_pos.x) if f != null else nx) + d.x + GAP
	# ---- east band, turned to face west ----
	var ey := by0 + north_d + GAP
	for id in east:
		var d := _dims(id)
		var f := _place(id, Vector2i(bx1 - d.y, ey), Vector2i(0, 1), 3)
		ey = (int(f.grid_pos.y) if f != null else ey) + d.x + GAP
	# ---- centre rows ----
	var ry := by0 + north_d + AISLE
	for r in rows:
		var rx := bx0 + 3
		var rd := 0
		for id in r:
			var d := _dims(id)
			var f := _place(id, Vector2i(rx, ry), Vector2i(1, 0))
			rx = (int(f.grid_pos.x) if f != null else rx) + d.x + AISLE
			rd = maxi(rd, d.y + d.z)
		ry += rd + AISLE
	# ---- stacked on a surface ----
	for entry in room.get("on", []):
		var host := _placed.get(entry[1], null) as Furniture
		if host == null:
			_report.append("NOT PLACED %s: no %s to stand on" % [entry[0], entry[1]])
			continue
		_place(entry[0], Vector2i(host.grid_pos) + Vector2i(entry[2], entry[3]), Vector2i(1, 0), 0, 3)


func _shot(path: String, palette: LevelPalette) -> void:
	_view.build_from_floor(_floor, _catalog, null)
	if is_instance_valid(_view._walls_btn):
		_view._walls_btn.visible = false
	await get_tree().create_timer(1.0).timeout      # the view's own day/night tween
	if _view._style != null:
		if palette != null:
			_view._style.palette = palette
		_view._style.night = 0.0
	_view._dist *= 0.72                             # the home view leaves a wide margin; come in closer
	_view._update_camera()
	for _f in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[Showcase] saved ", path)


func _run(out_dir: String, only: String) -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	_view = (load("res://scenes/Room3DView.tscn") as PackedScene).instantiate() as Room3DView
	add_child(_view)
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.get_node("CloseBtn").visible = false
	var palettes := {}
	for p in PaletteLibrary.all():
		palettes[p.resource_path.get_file().get_basename()] = p
	var used := {}
	for room in ROOMS:
		var room_name := room["name"] as String
		if only != "" and only != room_name:
			continue
		_report.clear()
		_build_room(room)
		for key in ["wall", "north", "east", "centre"]:
			for id in room.get(key, []):
				used[id] = true
		for entry in room.get("on", []):
			used[entry[0]] = true
		await get_tree().process_frame
		var pal := palettes.get(room.get("palette", ""), null) as LevelPalette
		await _shot("%s/%s_closed.png" % [out_dir, room_name], pal)
		var opened := 0
		for id in _placed:
			var f := _placed[id] as Furniture
			if f.foldable and f.extended_add_h > 0:
				if f.toggle_fold():
					opened += 1
				else:
					_report.append("DID NOT OPEN %s: %s" % [id, _floor.get_block_reason()])
		if opened > 0:
			await _shot("%s/%s_open.png" % [out_dir, room_name], pal)
		print("[Showcase] %s: %d placed, %d opened" % [room_name, _placed.size(), opened])
		for line in _report:
			print("[Showcase]   ", line)
	if only == "":
		var missing: Array = []
		for e in _catalog:
			if not used.has((e as Dictionary)["id"]):
				missing.append((e as Dictionary)["id"])
		print("[Showcase] catalogue entries in no room: ", missing)
	get_tree().quit()
