extends Node

# Headless smoke-test runner — no external test framework, just enough to
# catch a regression in the systems most changed/most relied-upon this
# session (Wall.gd's continuous placement, Furniture.gd's rotation) before
# it ships silently. Run with:
#   godot --headless --path . res://tests/TestMain.tscn
# (a real scene, not `-s` script-loop mode — `-s` compiles its script before
# autoloads are registered, which fails immediately since Furniture.gd reads
# the GameState autoload at the top level; a scene's script compiles as part
# of the normal main-scene load, after autoloads are up, same as every other
# scene in the project).
# Exits with code 0 if every test passed, 1 otherwise (so it can gate a
# script/CI step later without anyone having to read the output).

var _pass := 0
var _fail := 0
var _current := ""


func _ready() -> void:
	# The checks compare against the English source text (block reasons), so
	# they must not follow the machine's language.
	TranslationServer.set_locale("en")
	_run_all()
	await _t_tenants_are_cosmetic()
	await _t_progress_round_trip()
	await _t_project_needs_every_apartment()
	await _t_box_on_a_surface()
	await _t_outside_walls()
	await _t_unreachable_shown()
	await _t_moved_from_home()
	await _t_landing_spot()
	await _t_carry_hints()
	await _t_three_freezers()
	await _t_kit_modules_in_a_level()
	await _t_sloped_split_levels()
	print("\n%d passed, %d failed" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _run_all() -> void:
	_test("place then overlap is rejected", func(): _t_place_and_overlap())
	_test("non-overlapping placement succeeds", func(): _t_no_overlap_elsewhere())
	_test("outside the room is rejected", func(): _t_outside_room())
	_test("a wall tile is rejected", func(): _t_wall_blocked())
	_test("snap_to_wall lands flush against the wall", func(): _t_snap_to_wall())
	_test("a piece that must stand against a wall goes to the nearest one", func(): _t_snap_flush_far())
	_test("a wall-bound piece needs its back to a wall, not just any side", func(): _t_back_to_wall())
	_test("quiet route: a bed's way to the toilet must keep clear of the birds", func(): _t_quiet_route())
	_test("remove_furniture frees the tiles it occupied", func(): _t_remove_furniture())
	_test("rotation cycles 0/1/2/3 and swaps footprint each step", func(): _t_rotation_cycle())
	_test("pathing: a piece beside open floor is reachable", func(): _t_path_open())
	_test("pathing: no room to walk means nothing is reachable", func(): _t_path_blocked())
	_test("pathing: a piece must be reachable from its front", func(): _t_path_front())
	_test("a swing door keeps the quarter circle it opens through", func(): _t_door_swing())
	_test("a bed unfolded in another moment keeps its space then", func(): _t_other_moment())
	_test("under a loft only what is low enough; nothing in a window", func(): _t_loft_and_window())
	_test("reeded glass lets daylight through and stops the eye", func(): _t_reeded_glass())
	_test("a curtain is drawn and opened per moment", func(): _t_curtain_per_moment())
	_test("a skylight lights from above and takes no floor", func(): _t_skylight())
	_test("a sleeping pod sleeps, stores, splits and shades", func(): _t_sleeping_pod())
	_test("a foldable gives only what its fold state gives, per moment", func(): _t_fold_gives_per_moment())
	_test("kit modules: every module is in the shop, with its model", func(): _t_kit_modules_catalogue())
	_test("loop: a tile past a seam is the tile on the other side", func(): _t_loop_wrap_tile())
	_test("loop: a piece can stand across a seam, and collides there", func(): _t_loop_straddle())
	_test("loop: a piece longer than the loop runs into itself", func(): _t_loop_too_long())
	_test("loop: a door-sized seam only lets through what fits the opening", func(): _t_loop_door_span())
	_test("loop: a piece dragged past a seam comes out the other side", func(): _t_loop_wrap_origin())
	_test("loop: a seam joins two rooms into one zone", func(): _t_loop_zones())
	_test("loop: the eye sees round the loop", func(): _t_loop_sightline())
	_test("loop: the tenant walks through a seam", func(): _t_loop_pathing())
	_test("loop: daylight comes round through a seam", func(): _t_loop_light())
	_test("loop: only opposite walls can be joined", func(): _t_loop_bad_pairs())
	_test("ceiling: ramps make a gable, a dormer stays in its rect, the old key loads", func(): _t_ceiling_heights())
	_test("split levels: one level per piece, steps kept clear, headroom, walking over steps", func(): _t_split_level_rules())


# ── Tiny assertion helpers ───────────────────────────────────────────────────
func _test(name: String, body: Callable) -> void:
	_current = name
	body.call()


func _ok(condition: bool, detail: String = "") -> void:
	if condition:
		_pass += 1
		print("  PASS  %s" % _current)
	else:
		_fail += 1
		printerr("  FAIL  %s%s" % [_current, ("  (" + detail + ")") if detail != "" else ""])


func _eq(actual, expected, detail: String = "") -> void:
	_ok(actual == expected, "%s expected %s, got %s" % [detail, str(expected), str(actual)])


# ── Fixtures ─────────────────────────────────────────────────────────────────
# A plain 8x6 rectangular room (interior tiles 2..8 x 2..6 once the 1-tile
# perimeter wall is excluded) — small and fully self-contained, not tied to
# any real level so these tests don't churn every time level content changes.
func _make_floor() -> Floor:
	var floor_data := {
		"id": "test_floor",
		"label": "Test Floor",
		"grid_w": 20,
		"grid_h": 20,
		"floor_tiles": [],
		"segments": [
			{"x1": 1, "y1": 1, "x2": 9, "y2": 1, "primary": true, "demolished": false},
			{"x1": 9, "y1": 1, "x2": 9, "y2": 7, "primary": true, "demolished": false},
			{"x1": 9, "y1": 7, "x2": 1, "y2": 7, "primary": true, "demolished": false},
			{"x1": 1, "y1": 7, "x2": 1, "y2": 1, "primary": true, "demolished": false},
		],
	}
	var fl := load("res://scenes/Wall.tscn").instantiate() as Floor
	add_child(fl)
	fl.setup(floor_data)
	return fl


func _make_furniture(fl: Floor, w: int = 2, h: int = 2) -> Furniture:
	var fdata := {
		"id": "test_item", "name": "Test Item",
		"size": {"w": w, "h": h}, "functions": [],
		"buy_price": 100, "sell_price": 50,
	}
	var f := load("res://scenes/Furniture.tscn").instantiate() as Furniture
	fl.add_child(f)
	f.setup(fdata, fl)
	return f


# ── Tests ────────────────────────────────────────────────────────────────────

# ── Looped apartments (LoopSeams.gd, docs/design_recursive_apartments.md §2) ──
# A 30 x 20 room: walls at x 1 and 31, y 1 and 21, so the interior is tiles
# 2..30 across (29 round) and 2..20 down (19 round). `extra` adds segments
# (an inner wall), `north` replaces the north wall; `loop` is the floor's
# loop data, {} for none.
func _make_loop_floor(loop: Dictionary, extra: Array = [], north: Array = []) -> Floor:
	var segs: Array = [
		{"x1": 31, "y1": 1, "x2": 31, "y2": 21, "primary": true, "demolished": false},
		{"x1": 31, "y1": 21, "x2": 1, "y2": 21, "primary": true, "demolished": false},
		{"x1": 1, "y1": 21, "x2": 1, "y2": 1, "primary": true, "demolished": false},
	]
	if north.is_empty():
		segs.append({"x1": 1, "y1": 1, "x2": 31, "y2": 1, "primary": true, "demolished": false})
	else:
		segs.append_array(north)
	segs.append_array(extra)
	var data := {"id": "loop_floor", "label": "Loop", "grid_w": 34, "grid_h": 24, "floor_tiles": [], "segments": segs}
	if not loop.is_empty():
		data["loop"] = loop
	var fl := load("res://scenes/Wall.tscn").instantiate() as Floor
	add_child(fl)
	fl.setup(data)
	return fl


const TORUS_X := {"pairs": [{"a": "west", "b": "east"}]}


func _make_piece(fl: Floor, w: int, h: int, extra: Dictionary = {}) -> Furniture:
	var fdata := {"id": "test_item", "name": "Test Item", "size": {"w": w, "h": h}, "functions": [],
		"buy_price": 100, "sell_price": 50}
	fdata.merge(extra, true)
	var f := load("res://scenes/Furniture.tscn").instantiate() as Furniture
	fl.add_child(f)
	f.setup(fdata, fl)
	return f


func _t_loop_wrap_tile() -> void:
	var fl := _make_loop_floor(TORUS_X)
	_eq(fl.wrap_tile(Vector2i(1, 5)), Vector2i(30, 5), "west wall line is the last column:")
	_eq(fl.wrap_tile(Vector2i(31, 5)), Vector2i(2, 5), "east wall line is the first column:")
	_eq(fl.wrap_tile(Vector2i(-2, 5)), Vector2i(27, 5), "further out:")
	_eq(fl.wrap_tile(Vector2i(5, 0)), Vector2i(5, 0), "north has no seam:")
	var plain := _make_loop_floor({})
	_eq(plain.wrap_tile(Vector2i(1, 5)), Vector2i(1, 5), "no loop, no wrap:")
	fl.queue_free()
	plain.queue_free()


func _t_loop_straddle() -> void:
	var fl := _make_loop_floor(TORUS_X)
	var sofa := _make_piece(fl, 6, 2)
	_ok(fl.can_place(sofa, Vector2(27, 5)), "a sofa across the east-west seam: %s" % fl.get_block_reason())
	fl.place_furniture(sofa, Vector2(27, 5))
	var tiles := fl._rect_tiles(sofa.grid_pos, sofa.grid_w, sofa.grid_h)
	_ok(Vector2i(2, 5) in tiles and Vector2i(3, 6) in tiles and Vector2i(30, 5) in tiles and tiles.size() == 12,
		"stands on both sides: %s" % str(tiles))
	var stool := _make_piece(fl, 2, 2)
	_ok(not fl.can_place(stool, Vector2(3, 5)), "the far end is in the way on the west side")
	_eq(fl.get_block_reason(), "Overlaps Test Item")
	_ok(fl.can_place(stool, Vector2(4, 5)), "just past its end is free: %s" % fl.get_block_reason())
	var plain := _make_loop_floor({})
	var sofa2 := _make_piece(plain, 6, 2)
	_ok(not plain.can_place(sofa2, Vector2(27, 5)), "without a loop the wall is in the way")
	fl.queue_free()
	plain.queue_free()


func _t_loop_too_long() -> void:
	var fl := _make_loop_floor(TORUS_X)
	var exact := _make_piece(fl, 29, 1)
	_ok(fl.can_place(exact, Vector2(10, 5)), "exactly once round fits: %s" % fl.get_block_reason())
	var long := _make_piece(fl, 30, 1)
	_ok(not fl.can_place(long, Vector2(2, 5)), "a tile longer than the loop doesn't")
	_eq(fl.get_block_reason(), "Longer than the loop: it runs into itself")
	var deep := _make_piece(fl, 1, 20)
	_ok(not fl.can_place(deep, Vector2(5, 2)), "north-south is not looped: too deep is just outside")
	fl.queue_free()


# The north wall's x 4..12 leads to the south wall's x 16..24.
func _t_loop_door_span() -> void:
	var fl := _make_loop_floor({"pairs": [{"a": {"side": "north", "from": 4, "to": 12},
		"b": {"side": "south", "from": 16, "to": 24}}]})
	_eq(fl.wrap_tile(Vector2i(5, 1)), Vector2i(17, 20), "out of the north door, in at the south one:")
	_eq(fl.wrap_tile(Vector2i(13, 1)), Vector2i(13, 1), "beside the door is wall:")
	var shelf := _make_piece(fl, 4, 3)
	_ok(fl.can_place(shelf, Vector2(18, 19)), "through the south door into the north one: %s" % fl.get_block_reason())
	_ok(not fl.can_place(shelf, Vector2(22, 19)), "only half in the opening")
	fl.queue_free()


func _t_loop_wrap_origin() -> void:
	var fl := _make_loop_floor(TORUS_X)
	var f := _make_piece(fl, 3, 2)
	fl.place_furniture(f, Vector2(-1, 6))
	_eq(f.grid_pos, Vector2(28, 6), "corner moved round the loop:")
	fl.queue_free()


# An inner wall at x 16 with no door splits the room in two.
func _t_loop_zones() -> void:
	var wall := [{"x1": 16, "y1": 1, "x2": 16, "y2": 21, "primary": false, "demolished": false}]
	var plain := _make_loop_floor({"pairs": [{"a": "north", "b": "south"}]}, wall)
	plain._recalculate_zones()   # (done when furniture changes; none here)
	_eq(plain.zones.size(), 2, "a wall between, looped the other way:")
	var fl := _make_loop_floor(TORUS_X, wall)
	fl._recalculate_zones()
	_eq(fl.zones.size(), 1, "joined round the back:")
	fl.queue_free()
	plain.queue_free()


func _t_loop_sightline() -> void:
	var fl := _make_loop_floor(TORUS_X)
	var tall := {"height_category": "tall"}
	var screen := _make_piece(fl, 2, 2, tall)
	fl.place_furniture(screen, Vector2(15, 9))
	_ok(fl.sightline_block(Vector2i(4, 10), Vector2i(26, 10)) == null, "blocked straight on, clear the long way round")
	_ok(not fl.sightline_route(Vector2i(4, 10), Vector2i(26, 10)).is_empty(), "and the route goes through the seam")
	var other := _make_piece(fl, 2, 2, tall)
	fl.place_furniture(other, Vector2(29, 9))
	_ok(fl.sightline_block(Vector2i(4, 10), Vector2i(26, 10)) != null, "blocked both ways round")
	var plain := _make_loop_floor({})
	var s2 := _make_piece(plain, 2, 2, tall)
	plain.place_furniture(s2, Vector2(15, 9))
	_ok(plain.sightline_block(Vector2i(4, 10), Vector2i(26, 10)) != null, "no loop: blocked")
	fl.queue_free()
	plain.queue_free()


# The inner wall at x 16 again; the front door is in the north wall's
# western half, so the eastern room is reached only round the loop.
func _t_loop_pathing() -> void:
	Floor.pathing_enabled = true
	var wall := [{"x1": 16, "y1": 1, "x2": 16, "y2": 21, "primary": false, "demolished": false}]
	var north := [
		{"x1": 1, "y1": 1, "x2": 16, "y2": 1, "primary": true, "demolished": false, "has_door": true, "door_pos": 3},
		{"x1": 16, "y1": 1, "x2": 31, "y2": 1, "primary": true, "demolished": false},
	]
	var plain := _make_loop_floor({}, wall, north)
	var p1 := _make_piece(plain, 2, 2)
	plain.place_furniture(p1, Vector2(24, 10))
	_ok(not plain.is_reachable(p1), "no loop: the eastern room has no way in")
	var fl := _make_loop_floor(TORUS_X, wall, north)
	var p2 := _make_piece(fl, 2, 2)
	fl.place_furniture(p2, Vector2(24, 10))
	_ok(fl.is_reachable(p2), "round the loop it can be walked to")
	Floor.pathing_enabled = false
	fl.queue_free()
	plain.queue_free()


# A window at the east end of the north wall lights the first columns too,
# through the seam.
# A window in the west wall (rows 4..7) shines straight across to an opening
# in the east wall (rows 4..7) that leads back in through the west wall at
# rows 12..15: the beam comes out there and goes on lighting the floor,
# where in the same room without the loop it is dark.
func _t_loop_light() -> void:
	var make := func(looped: bool) -> Floor:
		var data := {"id": "loop_light", "label": "Loop", "grid_w": 34, "grid_h": 24, "floor_tiles": [], "segments": [
			{"x1": 1, "y1": 1, "x2": 31, "y2": 1, "primary": true, "demolished": false},
			{"x1": 31, "y1": 1, "x2": 31, "y2": 21, "primary": true, "demolished": false},
			{"x1": 31, "y1": 21, "x2": 1, "y2": 21, "primary": true, "demolished": false},
			{"x1": 1, "y1": 21, "x2": 1, "y2": 1, "primary": true, "demolished": false,
				"has_window": true, "window_pos": 3, "window_len": 4},
		]}
		if looped:
			data["loop"] = {"pairs": [{"a": {"side": "east", "from": 4, "to": 8}, "b": {"side": "west", "from": 12, "to": 16}}]}
		var fl := load("res://scenes/Wall.tscn").instantiate() as Floor
		add_child(fl)
		fl.setup(data)
		return fl
	var fl: Floor = make.call(true)
	var plain: Floor = make.call(false)
	var sum := func(f: Floor) -> float:
		var total := 0.0
		for y in range(12, 16):
			for x in range(2, 6):
				total += f.get_light(Vector2i(x, y))
		return total
	_ok(fl.loop != null and (sum.call(fl) as float) > (sum.call(plain) as float) + 0.05,
		"looped %.2f vs plain %.2f" % [sum.call(fl), sum.call(plain)])
	fl.queue_free()
	plain.queue_free()


func _t_loop_bad_pairs() -> void:
	var fl := _make_loop_floor({"pairs": [{"a": "west", "b": "north"},
		{"a": {"side": "north", "from": 4, "to": 8}, "b": {"side": "south", "from": 4, "to": 10}}]})
	_ok(fl.loop == null, "a turning pair and a mismatched one are both left out")
	fl.queue_free()


# A loft over the room's left half: a chest freezer (0.9 m) fits under it, a
# fridge (1.8 m) doesn't; and a window in the top wall is still wall.
func _t_loft_and_window() -> void:
	var fl := load("res://scenes/Wall.tscn").instantiate() as Floor
	add_child(fl)
	fl.setup({"id": "loft_floor", "label": "Loft", "grid_w": 24, "grid_h": 24, "floor_tiles": [],
		"segments": [
			{"x1": 1, "y1": 1, "x2": 21, "y2": 1, "primary": true, "demolished": false,
				"has_window": true, "window_pos": 4, "window_len": 10},
			{"x1": 21, "y1": 1, "x2": 21, "y2": 21, "primary": true, "demolished": false},
			{"x1": 21, "y1": 21, "x2": 1, "y2": 21, "primary": true, "demolished": false},
			{"x1": 1, "y1": 21, "x2": 1, "y2": 1, "primary": true, "demolished": false},
		]})
	for x in range(2, 12):
		for y in range(2, 21):
			fl.mezzanine_mask[Vector2i(x, y)] = true
	var make := func(id: String) -> Furniture:
		var f := load("res://scenes/Furniture.tscn").instantiate() as Furniture
		fl.add_child(f)
		f.setup(main_catalog_entry(id), fl)
		return f
	var freezer: Furniture = make.call("chest_freezer")
	var fridge: Furniture = make.call("fridge")
	var under_ok := fl.can_place(freezer, Vector2(2, 10))
	var fridge_under := fl.can_place(fridge, Vector2(2, 10))
	var fridge_reason := fl.get_block_reason()
	var fridge_beside := fl.can_place(fridge, Vector2(13, 10))
	var stool := _make_furniture(fl, 3, 3)
	var in_window := fl.can_place(stool, Vector2(7, 1))
	_ok(under_ok and not fridge_under and fridge_reason == "Too tall to go under the loft" and fridge_beside and not in_window,
		"freezer %s, fridge under %s (%s), beside %s, stool in window %s" % [under_ok, fridge_under, fridge_reason, fridge_beside, in_window])
	fl.queue_free()


func main_catalog_entry(id: String) -> Dictionary:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://data/furniture.json"))
	for f in data["furniture"]:
		if f["id"] == id:
			return f
	return {}


# A 20 x 20 room (tiles 2..20) with a swing door in its north wall at
# x 6..16, opening south into the room.
func _t_door_swing() -> void:
	var fl := load("res://scenes/Wall.tscn").instantiate() as Floor
	add_child(fl)
	fl.setup({"id": "door_floor", "label": "Door", "grid_w": 24, "grid_h": 24, "floor_tiles": [],
		"segments": [
			{"x1": 1, "y1": 1, "x2": 21, "y2": 1, "primary": true, "demolished": false,
				"has_door": true, "door_pos": 5, "door_side": 1},
			{"x1": 21, "y1": 1, "x2": 21, "y2": 21, "primary": true, "demolished": false},
			{"x1": 21, "y1": 21, "x2": 1, "y2": 21, "primary": true, "demolished": false},
			{"x1": 1, "y1": 21, "x2": 1, "y2": 1, "primary": true, "demolished": false},
		]})
	var f := _make_furniture(fl, 3, 3)
	var in_swing := fl.can_place(f, Vector2(7, 3))
	var reason := fl.get_block_reason()
	var beside := fl.can_place(f, Vector2(17, 3))
	var past_arc := fl.can_place(f, Vector2(14, 9))
	_ok(not in_swing and reason == "In the way of the door" and beside and past_arc,
		"%s (%s), beside %s, past the arc %s" % [in_swing, reason, beside, past_arc])
	fl.queue_free()


# Day and night: a sofa bed folded by day, unfolded at night. By day the
# floor in front of it is free on screen, but a piece put there would stand
# where the bed lies at night.
func _t_other_moment() -> void:
	var real_ids := Furniture.all_moment_ids
	var real_labels := Furniture.moment_labels
	var real_test := Furniture.test_mode_active
	var real_active := Furniture.active_moment_id
	Furniture.all_moment_ids = ["day", "night"]
	Furniture.moment_labels = {"day": "Day", "night": "Night"}
	Furniture.test_mode_active = true
	Furniture.active_moment_id = "day"
	var fl := _make_floor()
	var bed := load("res://scenes/Furniture.tscn").instantiate() as Furniture
	fl.add_child(bed)
	bed.setup({"id": "test_bed", "name": "Test Bed", "size": {"w": 3, "h": 2}, "functions": [],
		"buy_price": 1, "sell_price": 1, "foldable": true, "extended_add_h": 2}, fl)
	fl.place_furniture(bed, Vector2(2, 2))
	bed.moment_fold_state = {"day": false, "night": true}
	var f := _make_furniture(fl, 2, 1)
	var where_bed_lies := fl.can_place(f, Vector2(2, 4))
	var reason := fl.get_block_reason()
	var clear_of_it := fl.can_place(f, Vector2(6, 5))
	_ok(not where_bed_lies and reason.contains("Night") and clear_of_it, "%s (%s), clear %s" % [where_bed_lies, reason, clear_of_it])
	fl.queue_free()
	Furniture.all_moment_ids = real_ids
	Furniture.moment_labels = real_labels
	Furniture.test_mode_active = real_test
	Furniture.active_moment_id = real_active


# The test room's interior is 7 x 5 tiles (x 2..8, y 2..6) and has no door,
# so the walk starts from its largest stretch of open floor.
func _t_path_open() -> void:
	Floor.pathing_enabled = true
	var fl := _make_floor()
	var a := _make_furniture(fl, 1, 1)
	fl.place_furniture(a, Vector2(2, 2))
	_ok(fl.is_reachable(a), "open floor right beside it")
	_eq(fl.get_inaccessible_furniture().size(), 0)
	Floor.pathing_enabled = false
	fl.queue_free()


func _t_path_blocked() -> void:
	var fl := _make_floor()
	var a := _make_furniture(fl, 1, 1)
	fl.place_furniture(a, Vector2(2, 2))
	var b := _make_furniture(fl, 3, 3)
	fl.place_furniture(b, Vector2(3, 2))   # leaves no 4 x 4 patch anywhere
	_eq(fl.get_inaccessible_furniture().size(), 0, "old rule (flag off):")
	Floor.pathing_enabled = true
	_eq(fl.get_inaccessible_furniture().size(), 2, "pathing rule:")
	Floor.pathing_enabled = false
	fl.queue_free()


func _t_path_front() -> void:
	Floor.pathing_enabled = true
	var fl := _make_floor()
	var a := _make_furniture(fl, 3, 1)
	fl.place_furniture(a, Vector2(2, 2))   # back against the north wall
	var b := _make_furniture(fl, 3, 1)
	fl.place_furniture(b, Vector2(2, 3))   # pushed up against its long side
	_ok(fl.is_reachable(a), "used from any side: its east end is open")
	a.front = "long"
	_ok(not fl.is_reachable(a), "used from a long side: one is the wall, the other is covered")
	Floor.pathing_enabled = false
	fl.queue_free()

func _t_place_and_overlap() -> void:
	var fl := _make_floor()
	var a := _make_furniture(fl)
	_ok(fl.can_place(a, Vector2(2, 2)), "empty interior spot should be placeable")
	fl.place_furniture(a, Vector2(2, 2))

	var b := _make_furniture(fl)
	_ok(not fl.can_place(b, Vector2(2, 2)), "identical rect should collide with 'a'")
	_eq(fl.get_block_reason(), "Overlaps Test Item")
	fl.queue_free()


func _t_no_overlap_elsewhere() -> void:
	var fl := _make_floor()
	var a := _make_furniture(fl)
	fl.place_furniture(a, Vector2(2, 2))

	var b := _make_furniture(fl)
	_ok(fl.can_place(b, Vector2(5, 2)), "non-overlapping rect in the same room should be fine")
	fl.queue_free()


func _t_outside_room() -> void:
	var fl := _make_floor()
	var a := _make_furniture(fl)
	_ok(not fl.can_place(a, Vector2(-5, -5)), "far outside the room bounds")
	_eq(fl.get_block_reason(), "Outside the room")
	fl.queue_free()


func _t_wall_blocked() -> void:
	var fl := _make_floor()
	var a := _make_furniture(fl)
	_ok(not fl.can_place(a, Vector2(1, 2)), "x=1 is the west wall's own tile")
	_eq(fl.get_block_reason(), "Blocked by a wall")
	fl.queue_free()


func _t_snap_to_wall() -> void:
	var fl := _make_floor()
	var a := _make_furniture(fl)
	var snapped := fl.snap_to_wall(a, Vector2(1, 2))
	_ok(fl.can_place(a, snapped), "snap_to_wall must only ever return a placeable spot")
	_eq(snapped.x, 2.0, "should snap flush to just inside the west wall")
	fl.queue_free()


# A 50 x 30 room (tiles 2..51 x 2..31): a bed in the top-left corner, used
# from its south side, and a toilet in the top-right, used from its south
# side too, so the way runs along under them. Birds asleep at the bottom
# leave it quiet; across the way, there's room to go round them; right by
# the toilet there's no way to it that doesn't pass them.
func _t_quiet_route() -> void:
	var fl := load("res://scenes/Wall.tscn").instantiate() as Floor
	add_child(fl)
	fl.setup({"id": "quiet", "label": "Quiet", "grid_w": 56, "grid_h": 36, "floor_tiles": [], "segments": [
		{"x1": 1, "y1": 1, "x2": 52, "y2": 1, "primary": true, "demolished": false},
		{"x1": 52, "y1": 1, "x2": 52, "y2": 32, "primary": true, "demolished": false},
		{"x1": 52, "y1": 32, "x2": 1, "y2": 32, "primary": true, "demolished": false},
		{"x1": 1, "y1": 32, "x2": 1, "y2": 1, "primary": true, "demolished": false},
	]})
	var bed := _catalog_piece(fl, "normal_bed")
	fl.place_furniture(bed, Vector2(2, 2))
	var wc := _catalog_piece(fl, "toilet")
	fl.place_furniture(wc, Vector2(45, 2))
	var q := {"from_function": "sleep", "to": ["toilet"], "avoid": "bird_cage", "radius": 10}
	var none: Dictionary = fl.quiet_route(q)
	var cage := _catalog_piece(fl, "bird_cage")
	var at := func(p: Vector2) -> Dictionary:
		fl.place_furniture(cage, p)
		return fl.quiet_route(q)
	var far: Dictionary = at.call(Vector2(24, 26))
	var across: Dictionary = at.call(Vector2(30, 9))
	var by_toilet: Dictionary = at.call(Vector2(40, 9))
	_ok(none["ok"] and far["ok"] and not (far["path"] as Array).is_empty() and across["ok"] and not by_toilet["ok"],
		"no cage %s, far %s (%d steps), across the way %s, by the toilet %s" % [none["ok"], far["ok"],
			(far["path"] as Array).size(), across["ok"], by_toilet["ok"]])
	fl.queue_free()


# A 6 x 2 piece used from a long side (a wardrobe, say) in the 25 x 19 room
# of _window_floor (tiles 2..26 x 2..20): its back, the other long side,
# against the north wall is fine; touching the west wall with only its
# short end is not, and neither is the middle of the room.
func _t_back_to_wall() -> void:
	var fl := _window_floor()
	var w := _make_furniture(fl, 6, 2)
	w.wall_flush_required = true
	w.front = "long"
	_ok(fl.can_place(w, Vector2(10, 2)), "back to the north wall: %s" % fl.get_block_reason())
	_ok(fl.can_place(w, Vector2(10, 19)), "back to the south wall: %s" % fl.get_block_reason())
	_ok(not fl.can_place(w, Vector2(2, 10)), "only its short end to the west wall")
	_ok(not fl.can_place(w, Vector2(10, 10)), "in the middle of the room")
	w.set_rot_steps(1)
	_ok(fl.can_place(w, Vector2(2, 10)), "turned, back to the west wall: %s" % fl.get_block_reason())
	fl.queue_free()


func _t_snap_flush_far() -> void:
	var fl := _make_floor()
	# 1 x 1 in the middle of the 7 x 5 room: two tiles or more from every
	# wall (one tile, 10 cm, still counts as against it).
	var a := _make_furniture(fl, 1, 1)
	a.wall_flush_required = true
	_ok(not fl.can_place(a, Vector2(5, 4)), "away from every wall it can't go")
	var snapped := fl.snap_to_wall(a, Vector2(5, 4))
	_ok(snapped != Vector2(5, 4), "it is moved instead of refused")
	_ok(fl.can_place(a, snapped), "to a spot against a wall where it fits")
	fl.place_furniture(a, snapped)
	var b := _make_furniture(fl, 1, 1)
	b.wall_flush_required = true
	var second := fl.snap_to_wall(b, Vector2(5, 4))
	_ok(fl.can_place(b, second), "a second one finds the next free spot against a wall")
	fl.queue_free()


func _t_remove_furniture() -> void:
	var fl := _make_floor()
	var a := _make_furniture(fl)
	fl.place_furniture(a, Vector2(2, 2))

	var b := _make_furniture(fl)
	_ok(not fl.can_place(b, Vector2(2, 2)), "occupied before removal")
	fl.remove_furniture(a)

	var c := _make_furniture(fl)
	_ok(fl.can_place(c, Vector2(2, 2)), "free again after removal")
	fl.queue_free()


func _t_rotation_cycle() -> void:
	# No Floor involved — _rotate() takes the untethered branch when
	# _wall_ref is null, which is exactly what a not-yet-placed buy-ghost
	# looks like, so this exercises the same path.
	var fdata := {
		"id": "test_item", "name": "Test Item",
		"size": {"w": 2, "h": 1}, "functions": [],
		"buy_price": 100, "sell_price": 50,
	}
	var f := load("res://scenes/Furniture.tscn").instantiate() as Furniture
	add_child(f)
	f.setup(fdata, null)

	_eq(f.rot_steps, 0)
	_eq(Vector2i(f.grid_w, f.grid_h), Vector2i(2, 1))

	f._rotate()
	_eq(f.rot_steps, 1)
	_eq(Vector2i(f.grid_w, f.grid_h), Vector2i(1, 2), "90 deg should swap w/h")

	f._rotate()
	_eq(f.rot_steps, 2)
	_eq(Vector2i(f.grid_w, f.grid_h), Vector2i(2, 1), "180 deg swaps back, but rot_steps must still read 2, not 0")

	f._rotate()
	_eq(f.rot_steps, 3)

	f._rotate()
	_eq(f.rot_steps, 0, "a full turn must wrap back to 0")
	_eq(Vector2i(f.grid_w, f.grid_h), Vector2i(2, 1))
	f.queue_free()


# ── Tenants are cosmetic ─────────────────────────────────────────────────────
# The household living in the apartment (TenantLayer) must never change the
# puzzle: the same layout has to give the same placement grid, walkable
# floor, requirement results and solved state with the tenants on, reacting,
# hopping about, or switched off -- and their randomness must leave the
# global random sequence alone.
func _t_tenants_are_cosmetic() -> void:
	GameState.pending_level_id = "overprotective"
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var fl: Floor = main._floors[main._current_floor_id]
	main.tenant_layer.stop()
	main._refresh_functions()
	var without := _puzzle_state(main, fl)

	seed(1234)
	var expected_rand := randf()
	seed(1234)
	main._start_tenants()
	for i in 3:
		main.tenant_layer.request_commit()
		await get_tree().process_frame
		main.tenant_layer.resync()
	main.tenant_layer._react("sight:1", fl.get_all_furniture()[0])
	await get_tree().create_timer(0.7).timeout
	# An errand: walking across the flat to see about a need.
	main.tenant_layer._clear_reaction()
	main.tenant_layer._run_errand([&"montse", "sight:1"])
	await get_tree().create_timer(1.5).timeout
	main.tenant_layer._cancel_errand()
	var actual_rand := randf()
	main._refresh_functions()
	var with := _puzzle_state(main, fl)

	_current = "tenants: someone lives in the apartment"
	_ok(main.tenant_layer._tokens.size() == 3, "%d tokens" % main.tenant_layer._tokens.size())
	_current = "tenants: placement grid, walkable floor and results are unchanged"
	_ok(with == without, "%s\n  vs\n  %s" % [with, without])
	_current = "tenants: they are not furniture"
	_ok(not fl.get_all_furniture().any(func(f): return not (f is Furniture)))
	_current = "tenants: the global random sequence is untouched"
	_ok(is_equal_approx(expected_rand, actual_rand))
	_current = "tenants: everyone stands on floor they could walk to"
	var reached := fl.get_reachable_floor()
	var on_floor := true
	for rid in main.tenant_layer._tiles:
		if not reached.is_empty() and not reached.has(Vector2i(main.tenant_layer._tiles[rid] as Vector2)):
			on_floor = false
	_ok(on_floor, str(main.tenant_layer._tiles))
	main.queue_free()
	await get_tree().process_frame


# ── Modular kits: storage-wall and sofa modules, one piece each ──────────────
func _t_kit_modules_catalogue() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://data/furniture.json"))
	var wall := 0
	var sofa := 0
	var missing: Array = []
	var inv := Inventory.new()
	var wrong_tab: Array = []
	for e in data["furniture"]:
		match e.get("kit", ""):
			"wall": wall += 1
			"sofa": sofa += 1
			_: continue
		if not ResourceLoader.exists(e["model"]):
			missing.append(e["id"])
		if inv._sub_category_of(e) != "Modular":
			wrong_tab.append(e["id"])
	inv.free()
	_eq([wall, sofa], [27, 7], "wall and sofa modules")
	_eq(missing, [], "modules without their model")
	_eq(wrong_tab, [], "modules outside the Modular tab")


# Modules are stacked into a wall one by one with the ordinary placement: a
# cube goes on a drawer, a wider piece doesn't hang off a narrower one, and a
# desk module and a sofa seat count for the tenant like any desk and seat.
func _t_kit_modules_in_a_level() -> void:
	var real_path := GameState.save_path
	GameState.save_path = "user://test_kits_save.json"
	GameState.pending_level_id = "day_and_night"
	GameState.pending_resume = false
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var fl: Floor = main._floors[main._current_floor_id]
	var gm: GameManager = main.gm
	var drawer := _place_somewhere(main, fl, "wallkit_drawer_2x1")
	_current = "kit modules: a drawer module stands against a wall"
	_ok(drawer != null and fl.is_registered(drawer) and fl.support_under(drawer) == null)
	var cube: Furniture = main._spawn_furniture("wallkit_cube_1x1", fl, 0, 0)
	var on_drawer := fl.can_place(cube, drawer.grid_pos)
	fl.place_furniture(cube, drawer.grid_pos)
	_current = "kit modules: a cube stacks on the drawer, 0.40 m up"
	_ok(on_drawer and fl.support_under(cube) == drawer and is_equal_approx(fl.stack_lift(cube), 4.0),
		"%s %s %s" % [on_drawer, fl.support_under(cube), fl.stack_lift(cube)])
	var desk: Furniture = main._spawn_furniture("wallkit_desk_2x1", fl, 0, 0)
	_current = "kit modules: a two-wide module doesn't hang off a one-wide cube"
	_ok(not fl.can_place(desk, cube.grid_pos))
	fl.remove_furniture(cube)
	var desk_on := fl.can_place(desk, drawer.grid_pos)
	fl.place_furniture(desk, drawer.grid_pos)
	var seat := _place_somewhere(main, fl, "sofakit_seat_1")
	main._refresh_functions()
	_current = "kit modules: a desk module and a sofa seat count for work and sit"
	_ok(desk_on and seat != null and fl.is_registered(seat) and gm.fulfilled_functions.has("work")
		and gm.fulfilled_functions.has("sit"), "%s %s" % [desk_on, gm.fulfilled_functions])
	var before := _level_state_string(main)
	var data := LevelProgress.capture(main)
	main._load_level("day_and_night")
	for i in 5:
		await get_tree().process_frame
	LevelProgress.apply(main, data)
	_current = "kit modules: a stacked wall and a sofa module load back as they were"
	_ok(_level_state_string(main) == before, "\n  before %s\n  after  %s" % [before, _level_state_string(main)])
	fl = main._floors[main._current_floor_id]
	var top: Furniture = null
	for entry in fl.get_all_furniture():
		if (entry as Furniture).furniture_id == "wallkit_desk_2x1":
			top = entry
	var under := fl.support_under(top) if top else null
	_current = "kit modules: of two same-size modules, the one put down second is still on top after loading"
	_ok(under != null and under.furniture_id == "wallkit_drawer_2x1" and fl.support_under(under) == null
		and is_equal_approx(fl.stack_lift(top), 4.0), "%s" % under)
	main.queue_free()
	await get_tree().process_frame
	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.save_path + suffix))
	GameState.save_path = real_path


func _puzzle_state(main: Node, fl: Floor) -> String:
	var pieces: Array = []
	for entry in fl.get_all_furniture():
		var f := entry as Furniture
		pieces.append("%s@%s/%s" % [f.furniture_id, f.grid_pos, f.is_extended])
	pieces.sort()
	var gm: GameManager = main.gm
	return "%s | reach %d | %s | win %s | fns %s" % [pieces, fl.get_reachable_floor().size(),
		Requirements.status(gm), gm.check_win(), gm.fulfilled_functions]


# ── Saving a level in progress ───────────────────────────────────────────────
# Change a level in every way the autosave has to keep (move, turn, fold per
# moment, buy, hang on a wall, build, spend, own), save it, open it again the
# way the map's CONTINUE does, and expect exactly the same apartment and the
# same verdict from the checker. Runs against its own save file.
func _t_progress_round_trip() -> void:
	var real_path := GameState.save_path
	var real_progress := GameState.progress.duplicate(true)
	var test_path := "user://test_progress_save.json"
	GameState.save_path = test_path
	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(test_path + suffix))

	GameState.pending_level_id = "day_and_night"
	GameState.pending_resume = false
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var fl: Floor = main._floors[main._current_floor_id]
	var gm: GameManager = main.gm
	# A sofa bed, bought and put down where it fits, turned, and unfolded for
	# the night only.
	var sofa: Furniture = main._spawn_furniture("sofa_bed", fl, 0, 0)
	sofa.set_rot_steps(1)
	var unfolded := false
	var bounds := fl.get_room_bounds()
	# Every row: unfolded it only fits the room's full height (it used to find
	# a spot only by standing in the top wall's window gap).
	for y in range(bounds.position.y, bounds.end.y):
		for x in range(bounds.position.x, bounds.end.x, 2):
			if unfolded or not fl.can_place(sofa, Vector2(x, y)):
				continue
			fl.place_furniture(sofa, Vector2(x, y))
			main._on_moment_selected("night", false)
			unfolded = sofa.toggle_fold()
			main._on_moment_selected("day", false)
	# The toilet moved half a tile along, where it still fits.
	var toilet: Furniture = null
	for entry in fl.get_all_furniture():
		if (entry as Furniture).furniture_id == "toilet":
			toilet = entry
	for dx in [0.5, -0.5, 1.5, -1.5]:
		var at := toilet.grid_pos + Vector2(dx, 0)
		if fl.can_place(toilet, at):
			fl.place_furniture(toilet, at)
			break
	# Something on a wall, a column built, money spent, a piece owned.
	var edge: String = fl.wall_definitions[0].get("edge", "north") if not fl.wall_definitions.is_empty() else "north"
	fl.place_wall_item(edge, Vector2i(3, 4), "wall_shelf")
	var col := Vector2i(fl.get_room_bounds().get_center())
	if fl.can_place_column(col.x, col.y):
		fl.toggle_column(col.x, col.y)
	gm.spend(123)
	gm.starting_inventory.append({"id": "stool", "count": 2})
	main._refresh_functions()
	var before := _level_state_string(main)
	_current = "progress: the test layout really has a night-only unfold to keep"
	_ok(unfolded and sofa.moment_fold_state.get("night", false) and not sofa.moment_fold_state.get("day", false),
		"unfolded %s, %s" % [unfolded, sofa.moment_fold_state])

	main._autosave_dirty = true
	main._autosave_now()
	main._autosave_dirty = true
	main._autosave_now()   # a second write leaves the first as .bak
	_current = "progress: the project is saved, with a backup of the save before"
	_ok(GameState.has_progress("day_and_night") and FileAccess.file_exists(test_path) and FileAccess.file_exists(test_path + ".bak"))
	main.queue_free()
	await get_tree().process_frame

	# Opened again from the map's CONTINUE.
	GameState.load_game()
	GameState.pending_level_id = "day_and_night"
	GameState.pending_resume = true
	main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var after := _level_state_string(main)
	_current = "progress: CONTINUE restores the apartment exactly, and the checker agrees"
	_ok(after == before, "\n  before %s\n  after  %s" % [before, after])
	_current = "progress: the application isn't printed again on CONTINUE"
	_ok(not is_instance_valid(main._application_fax))
	main.queue_free()
	await get_tree().process_frame

	# A save cut short (the phone killed the game mid-write) falls back to .bak.
	var f := FileAccess.open(test_path, FileAccess.WRITE)
	f.store_string("{\"company_funds\": 12")
	f.close()
	GameState.progress = {}
	GameState.load_game()
	_current = "progress: an unreadable save falls back to its backup"
	_ok(GameState.has_progress("day_and_night"))

	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(test_path + suffix))
	GameState.save_path = real_path
	GameState.progress = real_progress


# Everything about a level the save has to keep, and what the checker makes
# of it, as one comparable string.
func _level_state_string(main: Node) -> String:
	var gm: GameManager = main.gm
	var out: Array = []
	for fid in main._floors:
		var fl: Floor = main._floors[fid]
		var pieces: Array = []
		for entry in fl.get_all_furniture():
			var f := entry as Furniture
			pieces.append("%s@%s r%d e%s h%s mp%s mf%s" % [f.furniture_id, f.grid_pos, f.rot_steps, f.is_extended,
				f._home_grid_pos, f.moment_positions, f.moment_fold_state])
		pieces.sort()
		out.append("%s: %s walls %s cols %s" % [fid, pieces, fl.wall_items, fl.columns])
	var owned: Array = gm.starting_inventory.map(func(e): return "%s x%d" % [e["id"], int(e["count"])])
	out.append("budget %d owned %s moment %s" % [gm.budget, owned, main._active_moment_id])
	out.append("status %s verified %s win %s comfort %s" % [Requirements.status(gm), gm.moment_verified,
		gm.check_win(), gm.comfort_pct])
	return " | ".join(out)


# ── A project is rented out only when every apartment in it is ready ─────────
# Marisol's flat with a rental box in it: furnishing the box alone, or the
# flat alone, must not rent the project out; both together must. A box that
# was ready counts again only under the same conditions it was finished in.
func _t_project_needs_every_apartment() -> void:
	var real_path := GameState.save_path
	var real_completed := GameState.completed.duplicate(true)
	var real_progress := GameState.progress.duplicate(true)
	var real_motion := GameState.reduce_motion
	GameState.save_path = "user://test_project_save.json"
	GameState.reduce_motion = true
	GameState.completed.erase("beach_house")

	GameState.pending_level_id = "beach_house"
	GameState.pending_resume = false
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var root_floor: Floor = main._floors[main._current_floor_id]
	var box := _place_somewhere(main, root_floor, "rental_capsule")
	main._refresh_functions()
	var st: Dictionary = main._project_status()
	_current = "project: a rental box adds an apartment to furnish"
	_ok(box != null and st["total"] == 2 and not st["complete"], str(st))

	# Furnish the box completely; the flat still has nowhere to sleep or sit.
	main._on_box_entered(box)
	for i in 5:
		await get_tree().process_frame
	var inner: String = main._current_level_id
	var inner_floor: Floor = main._floors[main._current_floor_id]
	for id in ["normal_bed", "stool", "closed_bookcase"]:
		_place_somewhere(main, inner_floor, id)
	main._refresh_functions()
	_current = "project: a finished box alone doesn't rent the project out"
	_ok(main._level_done(inner) and not main._project_status()["complete"] and main._current_level_id == inner,
		"%s, now in %s" % [main._project_status(), main._current_level_id])
	_current = "project: the box isn't rented out as a level of its own"
	_ok(not GameState.completed.has(inner))
	main._exit_nested_level_to(0)
	for i in 5:
		await get_tree().process_frame
	root_floor = main._floors[main._current_floor_id]
	box = main._collect_nested_boxes()[0]

	# A tall shelf beside the box dims it, which nothing inside cares about;
	# a washing machine beside it is noise, and there is a bed inside.
	_current = "project: a change around a box that can't affect it leaves it ready"
	_ok(_put_beside(main, root_floor, box, "bookshelf", func(): return main._compute_box_occlusion(box) < 0.99)
		and main._level_state_label(inner, false) == "ready", main._level_state_label(inner, false))
	var washer := _put_beside(main, root_floor, box, "washer",
		func(): return main._has_noisy_neighbor(root_floor, box.grid_pos, box.grid_w, box.grid_h, box))
	_current = "project: noise next to a box with a bed inside means checking it again"
	_ok(washer != null and main._level_state_label(inner, false) == "recheck", main._level_state_label(inner, false))
	if washer:
		root_floor.remove_furniture(washer)
		washer.queue_free()
	main._refresh_functions()
	_current = "project: back as it was, the box counts as ready again"
	_ok(main._level_state_label(inner, false) == "ready", main._level_state_label(inner, false))

	# Now the flat too: the project is rented out. (Without its later phases:
	# those have their own test.)
	main.gm.current_level["phases"] = []
	for id in ["normal_bed", "stool"]:
		_place_somewhere(main, root_floor, id)
	main._refresh_functions()
	for i in 5:
		await get_tree().process_frame
	_current = "project: with every apartment ready, the project is rented out"
	_ok(GameState.completed.has("beach_house"), str(main._project_status()))
	main.queue_free()
	await get_tree().process_frame

	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.save_path + suffix))
	GameState.save_path = real_path
	GameState.completed = real_completed
	GameState.progress = real_progress
	GameState.reduce_motion = real_motion


# ── A box can stand on a table or shelf ──────────────────────────────────────
# Debug: Furniture Stacking starts with a capsule on its desk. A dresser is
# added and a second rental box goes on it through the ordinary stacking
# rules; its light and noise come from where it really is, it is entered and
# left like any box, and it comes back still on the dresser, drawn on top of
# it in 3D.
func _t_box_on_a_surface() -> void:
	var real_path := GameState.save_path
	var real_completed := GameState.completed.duplicate(true)
	var real_progress := GameState.progress.duplicate(true)
	var real_motion := GameState.reduce_motion
	GameState.save_path = "user://test_box_surface_save.json"
	GameState.reduce_motion = true
	GameState.pending_level_id = "debug:_stacking"
	GameState.pending_resume = false
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var fl: Floor = main._floors[main._current_floor_id]
	var level_box: Furniture = null
	for b in main._collect_nested_boxes():
		level_box = b
	_current = "surface box: the level's own capsule starts on its desk"
	_ok(level_box != null and fl.support_under(level_box) != null and fl.support_under(level_box).furniture_id == "desk"
		and level_box.stack_z == 1, str(level_box))

	var dresser: Furniture = main._spawn_furniture("dresser", fl, 0, 0)
	dresser.wall_flush_required = false   # not what this checks: stands in the room
	var placed_dresser := fl.can_place(dresser, Vector2(10, 14))
	fl.place_furniture(dresser, Vector2(10, 14))
	var box: Furniture = main._spawn_furniture("rental_capsule", fl, 0, 0)
	_current = "surface box: a box fits on a dresser"
	_ok(placed_dresser and fl.can_place(box, Vector2(10, 14)), fl.get_block_reason())
	fl.place_furniture(box, Vector2(10, 14))
	main._refresh_functions()
	_current = "surface box: it stands on the dresser, at the dresser's height, drawn over it"
	_ok(fl.support_under(box) == dresser and is_equal_approx(fl.stack_lift(box), dresser.body_h) and box.stack_z == 1,
		"%s lift %s z %d" % [fl.support_under(box), fl.stack_lift(box), box.stack_z])
	_current = "surface box: what is inside weighs as much as it does shrunk"
	_ok(box.weight < dresser.max_support_weight and box.interior_weight > box.weight,
		"weight %s interior %s" % [box.weight, box.interior_weight])
	_current = "surface box: half off the dresser is not on it"
	_ok(not fl.can_place(box, Vector2(8, 14)))
	_current = "surface box: a box too full for the dresser would break it"
	var real_interior := box.interior_weight
	box.apply_interior_weight(100000.0, main._box_shrink(box))
	_ok(not fl.can_place(box, Vector2(11, 15)) and fl.get_block_reason().begins_with("Too heavy"), fl.get_block_reason())
	box.apply_interior_weight(real_interior, main._box_shrink(box))
	_current = "surface box: as reachable as the dresser, even away from its edge"
	fl.place_furniture(box, Vector2(13, 16))
	var blocked: Array = fl.get_inaccessible_furniture()
	_ok(fl.can_place(box, Vector2(13, 16)) and (box in blocked) == (dresser in blocked), str(blocked))
	fl.place_furniture(box, Vector2(10, 14))

	_current = "surface box: the dresser under it doesn't shade it"
	_ok(is_equal_approx(main._compute_box_occlusion(box), 1.0), str(main._compute_box_occlusion(box)))
	var washer: Furniture = main._spawn_furniture("washer", fl, 0, 0)
	washer.wall_flush_required = false   # not what this checks: stands in the room
	var placed_washer := fl.can_place(washer, Vector2(3, 14))
	fl.place_furniture(washer, Vector2(3, 14))
	_current = "surface box: a washer below it is heard but doesn't shade it"
	_ok(placed_washer and main._has_noisy_neighbor(fl, box.grid_pos, box.grid_w, box.grid_h, box)
		and is_equal_approx(main._compute_box_occlusion(box), 1.0), fl.get_block_reason())
	main._refresh_functions()
	_current = "noise feedback: the washer shows it is noisy when the box has a bed inside"
	_ok(washer._noise_making == main._child_has_bed(box.child_level_id), "making %s, bed inside %s" % [washer._noise_making, main._child_has_bed(box.child_level_id)])
	fl.remove_furniture(washer)
	main._refresh_functions()
	# Holding a bookshelf beside the box already shows the shade it would cast.
	var held_shelf: Furniture = main._spawn_furniture("bookshelf", fl, 0, 0)
	held_shelf.wall_flush_required = false   # not what this checks: stands in the room
	fl.forget_furniture(held_shelf)
	held_shelf._placement_mode = true
	fl.set_floor_drag_ghost(held_shelf, 2, 14)
	var shade_held := box._shade
	held_shelf._placement_mode = false
	fl.clear_floor_drag_ghost()
	_current = "daylight feedback: a bookshelf held beside the box shades it before it is put down"
	_ok(shade_held < 0.2 and is_equal_approx(box._shade, 1.0), "held %s, after %s" % [shade_held, box._shade])
	held_shelf.queue_free()
	var shelf: Furniture = main._spawn_furniture("bookshelf", fl, 0, 0)
	shelf.wall_flush_required = false   # not what this checks: stands in the room
	var placed_shelf := fl.can_place(shelf, Vector2(2, 14))
	fl.place_furniture(shelf, Vector2(2, 14))
	main._refresh_functions()
	_current = "surface box: a bookshelf taller than the dresser does shade it"
	_ok(placed_shelf and main._compute_box_occlusion(box) < 0.2, str(main._compute_box_occlusion(box)))
	_current = "daylight feedback: the box knows how little daylight gets in, and from what"
	_ok(box._shade < 0.2 and main._shade_by == shelf.furniture_name, "%s by %s" % [box._shade, main._shade_by])

	main._on_box_entered(box)
	for i in 5:
		await get_tree().process_frame
	_current = "surface box: stepping in takes the light from where it stands"
	_ok(main._current_level_id == "rental:capsule" and main._current_nested_daylight_factor < 0.2,
		"%s %s" % [main._current_level_id, main._current_nested_daylight_factor])
	main._exit_nested_level_to(0)
	for i in 5:
		await get_tree().process_frame
	fl = main._floors[main._current_floor_id]
	var boxes: Array = main._collect_nested_boxes()
	boxes = boxes.filter(func(b): return b.grid_pos == Vector2(10, 14))
	box = boxes[0] if boxes.size() == 1 else null
	dresser = fl.support_under(box) if box else null
	if dresser:
		dresser.wall_flush_required = false   # rebuilt on the way back out: still not what this checks
	_current = "surface box: back out, the box is still on the dresser"
	_ok(box != null and box.grid_pos == Vector2(10, 14) and dresser != null and dresser.furniture_id == "dresser",
		"%s on %s" % [box, dresser])

	if box and dresser:
		# On the plan: a stool held over the dresser strains it past what it
		# holds; letting go of it puts it back to what really rests there.
		var held: Furniture = main._spawn_furniture("stool", fl, 0, 0)
		fl.forget_furniture(held)
		held._placement_mode = true
		fl.set_floor_drag_ghost(held, dresser.grid_pos.x + 6, dresser.grid_pos.y)
		var held_strain := dresser._strain
		held._placement_mode = false
		fl.clear_floor_drag_ghost()
		_current = "surface box: on the plan, a dresser shows the strain of what is held over it"
		_ok(held_strain > Floor.STRAIN_FROM and is_equal_approx(dresser._strain, fl.strain_of(dresser)),
			"held %s, after %s" % [held_strain, dresser._strain])
		held.queue_free()
		main._set_view_mode(main.ViewMode.VIEW3D)
		for i in 5:
			await get_tree().process_frame
		var view = main._mode3d_view
		var entry: Dictionary = view._entry_of(box)
		var bottom := -1.0
		if not entry.is_empty():
			bottom = (entry["mesh"] as Node3D).position.y - (entry["size"] as Vector3).y * 0.5
		_current = "surface box: in 3D it stands on top of the dresser"
		_ok(bottom > 0.5 and is_equal_approx(bottom, view._top_m(dresser)), "bottom %s top %s" % [bottom, view._top_m(dresser)])
		# Carrying a stool over the dresser bows it (box + stool is most of what
		# it holds) and the box sinks with it; putting the stool away
		# straightens it again.
		var stool: Furniture = main._spawn_furniture("stool", fl, 0, 0)
		fl.forget_furniture(stool)
		view._settle_stacked(stool, dresser.grid_pos + Vector2(6, 0))
		var bowed: float = view._entry_of(dresser).get("sag", 0.0)
		var sunk: float = (entry["mesh"] as Node3D).position.y - (entry["size"] as Vector3).y * 0.5
		view._settle_stacked()
		_current = "surface box: a dresser carrying a lot bows, and the box on it sinks with it"
		_ok(bowed > 0.0 and sunk < bottom - 0.0001 and is_equal_approx(view._entry_of(dresser).get("sag", 0.0), 0.0),
			"sag %s, box %s -> %s" % [bowed, bottom, sunk])
		stool.queue_free()
		main._set_view_mode(main.ViewMode.TOPDOWN)

		_current = "surface box: moving the dresser takes the box along"
		var moved := fl.can_place(dresser, dresser.grid_pos + Vector2(1, 1)) and fl.move_with_riders(dresser, dresser.grid_pos + Vector2(1, 1))
		_ok(moved and box.grid_pos == Vector2(11, 15) and fl.support_under(box) == dresser, "%s %s %s" % [moved, box.grid_pos, fl.get_block_reason()])

		# A quarter turn takes the box round with the dresser (11x7 at 11,15,
		# box in its top-left corner): it ends up bottom-left, turned too.
		dresser._rotate(true)
		_current = "surface box: turning the dresser turns the box with it"
		_ok(box.grid_pos == Vector2(11, 22) and box.rot_steps == 1 and fl.support_under(box) == dresser,
			"%s r%d on %s" % [box.grid_pos, box.rot_steps, fl.support_under(box)])
		for i in 3:
			dresser._rotate(true)
		_current = "surface box: four turns put it back where it was"
		_ok(box.grid_pos == Vector2(11, 15) and box.rot_steps == 0 and dresser.grid_pos == Vector2(11, 15))

	# A box comes weighed with what is inside it, from the moment it exists.
	var family: Furniture = main._spawn_furniture("rental_family", fl, 2, 22)
	_current = "surface box: a family carton weighs its contents at once (too much for a dresser)"
	_ok(family.weight > 15.0, str(family.weight))
	var editor = load("res://scripts/LevelEditor.gd").new()
	editor._furn_catalog = main.gm.furniture_data["furniture"]
	var preview := load("res://scenes/Furniture.tscn").instantiate() as Furniture
	add_child(preview)
	preview.setup(main.gm.get_furniture_by_id("rental_family"), null)
	editor._weigh_preview_box(preview)
	_current = "surface box: the level editor weighs a box the same as the game"
	_ok(is_equal_approx(preview.weight, family.weight), "%s vs %s" % [preview.weight, family.weight])
	preview.queue_free()
	editor.free()
	fl.remove_furniture(family)

	# Inside the capsule on the desk: furnishing it stops where the desk would break.
	var capsule: Furniture = null
	for b in main._collect_nested_boxes():
		var under := fl.support_under(b)
		if under != null and under.furniture_id == "desk":
			capsule = b
	var desk := fl.support_under(capsule) if capsule else null
	main._on_box_entered(capsule)
	for i in 5:
		await get_tree().process_frame
	var inner: Floor = main._floors[main._current_floor_id]
	var refusal := ""
	for n in 30:
		var piece: Furniture = main._spawn_furniture("normal_bed", inner, 0, 0)
		inner.forget_furniture(piece)   # a piece being bought isn't on the floor yet
		var put := false
		var rb := inner.get_room_bounds()
		for y in range(rb.position.y, rb.end.y):
			for x in range(rb.position.x, rb.end.x):
				if not put and inner.can_place(piece, Vector2(x, y)):
					inner.place_furniture(piece, Vector2(x, y))
					put = true
				elif not put and refusal == "" and inner.get_block_reason().begins_with("Too heavy: what this box"):
					refusal = inner.get_block_reason()
		if not put:
			piece.queue_free()
			break
	main._refresh_functions()
	_current = "surface box: inside a box on a desk, new pieces stop where the desk would break"
	_ok(refusal != "", "never refused for weight")
	main._exit_nested_level_to(0)
	for i in 5:
		await get_tree().process_frame
	fl = main._floors[main._current_floor_id]
	capsule = null
	for b in main._collect_nested_boxes():
		var under := fl.support_under(b)
		if under != null and under.furniture_id == "desk":
			capsule = b
	desk = fl.support_under(capsule) if capsule else null
	_current = "surface box: back out, the desk still holds the furnished capsule"
	_ok(capsule != null and capsule.weight <= desk.max_support_weight - fl._surface_load(desk, capsule) + 0.001,
		"%s on %s" % [capsule.weight if capsule else -1.0, desk.max_support_weight if desk else -1.0])

	main.queue_free()
	await get_tree().process_frame
	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.save_path + suffix))
	GameState.save_path = real_path
	GameState.completed = real_completed
	GameState.progress = real_progress
	GameState.reduce_motion = real_motion


# ── Each outside wall says what it passes into the boxes nearest it ─────────
# Debug: All Mechanics has a street, a courtyard and an alley side; its
# shoebox stands nearest the alley. Carrying it towards the street moves the
# link there before it is put down.
func _t_outside_walls() -> void:
	var real_path := GameState.save_path
	var real_motion := GameState.reduce_motion
	GameState.save_path = "user://test_walls_save.json"
	GameState.reduce_motion = true
	GameState.pending_level_id = "debug:_all_mechanics"
	GameState.pending_resume = false
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var fl: Floor = main._floors[main._current_floor_id]
	var box: Furniture = main._collect_nested_boxes()[0]
	var ov: RuleOverlay = fl._rule_overlay
	_current = "outside walls: the plan names every wall with rules, and links the box to its own"
	_ok(ov != null and ov.outside_walls.size() == 3 and ov.box_links.size() == 1 and ov.box_links[0]["side"] == "south",
		"%s / %s" % [ov.outside_walls if ov else null, ov.box_links if ov else null])
	box._dragging = true
	fl.set_floor_drag_ghost(box, 25, 14)
	var held_side: String = ov.box_links[0]["side"] if ov and not ov.box_links.is_empty() else ""
	box._dragging = false
	fl.clear_floor_drag_ghost()
	_current = "outside walls: carrying the box to the street side moves its link there first"
	_ok(held_side == "east" and ov.box_links[0]["side"] == "south", "%s, then %s" % [held_side, ov.box_links[0]["side"]])
	# A box is weighed into tiers as it is furnished, and the change is noted
	# once, not on loading.
	_current = "box tiers: light, heavy and packed full follow what is inside"
	_ok(Furniture.box_tier(10.0, "green") == "green" and Furniture.box_tier(60.0, "green") == "yellow"
		and Furniture.box_tier(400.0, "green") == "red")
	var tier_now: String = box.mobility_tier
	_current = "box tiers: the box's tier is remembered by its apartment from the start"
	_ok(main._box_tier_seen.get(box.child_level_id, "") == tier_now, "%s vs %s" % [main._box_tier_seen, tier_now])
	_current = "outside walls: the alley's rule reads as words"
	_ok(main._wall_rules_text(main.gm.external_restrictions["by_wall"]["south"]) == "Sleep at least 0.8 m from the wall",
		main._wall_rules_text(main.gm.external_restrictions["by_wall"]["south"]))
	main.queue_free()
	await get_tree().process_frame
	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.save_path + suffix))
	GameState.save_path = real_path
	GameState.reduce_motion = real_motion


# ── A piece nobody can get to is shown by a resident trying to ─────────────
# Overprotective's household: once a piece turns unreachable, the resident
# nearest it walks towards it and a dotted trail goes on to it; the next
# placement ends that.
func _t_unreachable_shown() -> void:
	var real_motion := GameState.reduce_motion
	GameState.reduce_motion = true
	GameState.pending_level_id = "overprotective"
	GameState.pending_resume = false
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var fl: Floor = main._floors[main._current_floor_id]
	var layer: TenantLayer = main.tenant_layer
	var piece: Furniture = fl.get_all_furniture()[0]
	layer.resync()
	piece.set_accessible(false)   # as Main marks one after a placement leaves it cut off
	layer.commit()
	await get_tree().create_timer(TenantLayer.HOP_TIME + 0.2).timeout
	_current = "unreachable: the resident nearest it sets off for it"
	_ok(layer._reach_rid != &"" and layer._reacting, "rid '%s'" % layer._reach_rid)
	await get_tree().create_timer(2.5).timeout
	_current = "unreachable: a dotted trail goes on from where they stopped to the piece"
	_ok(is_instance_valid(layer._trail2d) or layer._reach_rid == &"", "trail %s" % layer._trail2d)
	piece.set_accessible(true)
	layer.commit()
	await get_tree().process_frame
	_current = "unreachable: the next placement ends it"
	_ok(layer._reach_rid == &"" and not is_instance_valid(layer._trail2d))
	main.queue_free()
	await get_tree().process_frame
	GameState.reduce_motion = real_motion


# ── Comfort: what the tenant has to move by hand ──────────────────────────
# Debug: Mobility Tiers has a day and a night, a heavy (yellow) desk and
# light (green) chairs. The desk somewhere else at night: the tenant moves it
# by hand twice a day, comfort drops, and its day spot is marked. A chair
# moved at night is marked too, but costs nothing. The desk moved to the
# same place by day too: it stays put, comfort is back. And in a level
# without moments moving a heavy piece costs nothing at all.
func _t_moved_from_home() -> void:
	var real_path := GameState.save_path
	GameState.save_path = "user://test_home_save.json"
	GameState.pending_level_id = "debug:_mobility_tiers"
	GameState.pending_resume = false
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var fl: Floor = main._floors[main._current_floor_id]
	var find := func(id: String) -> Furniture:
		for f in fl.get_all_furniture():
			if (f as Furniture).furniture_id == id:
				return f
		return null
	var desk: Furniture = find.call("desk")
	var chair: Furniture = find.call("dining_chair")
	# What dropping it does: moved for the moment on screen only.
	var move := func(f: Furniture, mid: String, to: Vector2) -> void:
		assert(Furniture.active_moment_id == mid)
		var from := f.grid_pos
		fl.place_furniture(f, to)
		f.record_moment_move(from)
	var day_spot := desk.grid_pos
	main._on_moment_selected("night", false)
	var night_spot := day_spot + Vector2(0, 8)
	move.call(desk, "night", night_spot)
	main._refresh_functions()
	var ov: RuleOverlay = fl._rule_overlay
	_current = "comfort: a heavy desk somewhere else at night costs comfort, and its day spot is marked"
	_ok(is_equal_approx(main.gm.comfort_pct, 75.0) and ov.home_marks.size() == 1 and ov.home_marks[0]["home"] == day_spot,
		"comfort %s marks %s" % [main.gm.comfort_pct, ov.home_marks.map(func(m): return m["home"])])
	move.call(chair, "night", chair.grid_pos + Vector2(4, 0))
	main._refresh_functions()
	_current = "comfort: a light chair moved at night is marked but costs nothing"
	_ok(is_equal_approx(main.gm.comfort_pct, 75.0) and ov.home_marks.size() == 2, "comfort %s marks %d" % [main.gm.comfort_pct, ov.home_marks.size()])
	main._on_moment_selected("day", false)
	move.call(desk, "day", night_spot)
	main._refresh_functions()
	_current = "comfort: the desk in the same place day and night stays put, comfort is back"
	_ok(is_equal_approx(main.gm.comfort_pct, 100.0), str(main.gm.comfort_pct))
	main.queue_free()
	await get_tree().process_frame

	GameState.pending_level_id = "debug:_stacking"
	main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	fl = main._floors[main._current_floor_id]
	var heavy: Furniture = null
	for f in fl.get_all_furniture():
		if (f as Furniture).mobility_tier == "yellow":
			heavy = f
	fl.place_furniture(heavy, heavy.grid_pos + Vector2(0, 12))
	main._refresh_functions()
	_current = "comfort: without moments, moving a heavy piece costs nothing and leaves no mark"
	var ro = fl._rule_overlay
	_ok(is_equal_approx(main.gm.comfort_pct, 100.0) and (ro == null or (ro as RuleOverlay).home_marks.is_empty()),
		"comfort %s" % main.gm.comfort_pct)
	main.queue_free()
	await get_tree().process_frame
	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.save_path + suffix))
	GameState.save_path = real_path


# ── Put down where it can't stand, a piece lands next to it ──────────────
# Debug: Furniture Stacking. A piece put down half through the west wall
# lands inside, close by; put down right on top of another piece, it lands
# beside that one, close by. Where it fits, it stays put.
func _t_landing_spot() -> void:
	var real_path := GameState.save_path
	GameState.save_path = "user://test_landing_save.json"
	GameState.pending_level_id = "debug:_stacking"
	GameState.pending_resume = false
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var fl: Floor = main._floors[main._current_floor_id]
	var pieces: Array = fl.get_all_furniture().filter(func(f): return not (f as Furniture).is_surface \
		and not (f as Furniture).requires_surface and not (f as Furniture).wall_flush_required)
	var piece: Furniture = pieces[0]
	var other: Furniture = null
	for f in fl.get_all_furniture():
		if f != piece and other == null:
			other = f
	var bounds := fl.get_room_bounds()
	_current = "landing: where it fits, it stays put"
	_ok(fl.landing_spot(piece, piece.grid_pos) == piece.grid_pos)
	var through := Vector2(bounds.position.x - piece.grid_w * 0.5, piece.grid_pos.y).round()
	var t0 := Time.get_ticks_usec()
	var land := fl.landing_spot(piece, through)
	var took := (Time.get_ticks_usec() - t0) / 1000.0
	_current = "landing: half through the west wall, it lands inside, close by"
	_ok(land != Vector2.INF and fl.can_place(piece, land) and land.x >= bounds.position.x + 1.0
		and land.distance_to(through) <= piece.grid_w * 0.5 + Floor.LANDING_SLACK, "landed %s from %s (%.1f ms)" % [land, through, took])
	_current = "landing: on top of another piece, it lands beside it"
	land = fl.landing_spot(piece, other.grid_pos)
	_ok(land != Vector2.INF and fl.can_place(piece, land) and land.distance_to(other.grid_pos) <= maxf(piece.grid_w, piece.grid_h) + 4.0,
		"landed %s from %s" % [land, other.grid_pos])
	_current = "landing: nothing near fits, so it says why"
	var far := Vector2(bounds.position.x - 100, bounds.position.y - 100)
	_ok(fl.landing_spot(piece, far) == Vector2.INF and fl.get_block_reason() != "", fl.get_block_reason())
	main.queue_free()
	await get_tree().process_frame
	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.save_path + suffix))
	GameState.save_path = real_path


# ── While a piece is carried, the plan shows where it can't go ─────────────
# A stool carried in Debug: Furniture Stacking sees the desk's clearance; a
# wardrobe carried in Debug: Sloped Ceiling sees where the ceiling is too low
# for it. Put down, the hints go.
func _t_carry_hints() -> void:
	var real_path := GameState.save_path
	GameState.save_path = "user://test_hints_save.json"
	for case in [["debug:_stacking", "stool", "clearance"], ["debug:_sloped_ceiling", "wardrobe", "low_ceiling"]]:
		GameState.pending_level_id = case[0]
		GameState.pending_resume = false
		var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
		add_child(main)
		for i in 10:
			await get_tree().process_frame
		var fl: Floor = main._floors[main._current_floor_id]
		var held: Furniture = main._spawn_furniture(case[1], fl, 0, 0)
		fl.forget_furniture(held)
		held._placement_mode = true
		var b := fl.get_room_bounds()
		fl.set_floor_drag_ghost(held, b.position.x + 2, b.position.y + 2)
		var shown: Array = fl._rule_overlay.carry_hints.get(case[2], []) if fl._rule_overlay else []
		held._placement_mode = false
		fl.clear_floor_drag_ghost()
		_current = "carry hints: a %s carried in %s shows %s" % [case[1], case[0], case[2]]
		_ok(not shown.is_empty() and fl._rule_overlay.carry_hints.is_empty(), "%d shown" % shown.size())
		held.queue_free()
		main.queue_free()
		await get_tree().process_frame
	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.save_path + suffix))
	GameState.save_path = real_path


# ── Three Freezers: the basic needs, with room for everything ─────────────
# The first level that asks for every basic need. As it starts, every piece
# the catalogue offers there fits somewhere; buying the cheapest piece for
# each missing need and putting it down in the first free spot rents it out,
# within the budget.
func _t_three_freezers() -> void:
	var real_path := GameState.save_path
	GameState.save_path = "user://test_freezers_save.json"
	GameState.pending_level_id = "three_freezers"
	GameState.pending_resume = false
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var fl: Floor = main._floors[main._current_floor_id]
	var gm: GameManager = main.gm
	var b := fl.get_room_bounds()
	var first_spot := func(f: Furniture) -> Variant:
		for r in 2:
			for y in range(b.position.y, b.end.y):
				for x in range(b.position.x, b.end.x):
					if fl.can_place(f, Vector2(x, y)):
						return Vector2(x, y)
			f._rotate(true)
		return null
	var nowhere: Array = []
	for id in gm.current_level["allowed_furniture"]:
		var fdata := gm.get_furniture_by_id(id)
		if fdata.get("placement", "floor") == "wall" or fdata.get("requires_surface", false):
			continue   # hung in 3D, or stands on a table: not on bare floor
		var probe: Furniture = main._spawn_furniture(id, fl, 0, 0)
		fl.forget_furniture(probe)
		if first_spot.call(probe) == null:
			nowhere.append(id)
		probe.queue_free()
	_current = "three freezers: every piece on offer fits somewhere as the level starts"
	_ok(nowhere.is_empty(), str(nowhere))
	var spent := 0
	var cheapest_of := func(ids: Array) -> String:
		var best := ""
		for id in ids:
			var fd := gm.get_furniture_by_id(id)
			if fd.get("placement", "floor") != "wall" 					and (best == "" or (fd["buy_price"] as int) < (gm.get_furniture_by_id(best)["buy_price"] as int)):
				best = id
		return best
	var shopping: Array = []
	for need in ["sleep", "hygiene", "cook", "work", "sit"]:
		shopping.append(cheapest_of.call((gm.current_level["allowed_furniture"] as Array).filter(func(id):
			return need in (gm.get_furniture_by_id(id).get("functions", []) as Array))))
	var freezers: Dictionary = gm.current_level["tenant"]["required_items"][0]
	for k in freezers["count"]:
		shopping.append(cheapest_of.call(freezers["of"]))
	_current = "three freezers: the freezers are a need on the bar, not yet met"
	_ok(Requirements.status(gm).get("items:1", true) == false, str(Requirements.status(gm)))
	for cheapest in shopping:
		var f: Furniture = main._spawn_furniture(cheapest, fl, 0, 0)
		fl.forget_furniture(f)
		var at = first_spot.call(f)
		if at != null:
			fl.place_furniture(f, at)
			spent += gm.get_furniture_by_id(cheapest)["buy_price"] as int
			if gm.get_furniture_by_id(cheapest).get("creates_loft", false):
				main._promote_to_loft(f, fl)
	main._refresh_functions()
	_current = "three freezers: one of each, put down anywhere, rents it out within the budget"
	_ok(gm.check_win() and main._all_furniture_accessible() and spent <= gm.current_level["starting_budget"],
		"win %s reach %s spent %d of %d status %s" % [gm.check_win(), main._all_furniture_accessible(), spent,
		gm.current_level["starting_budget"], Requirements.status(gm)])
	main.queue_free()
	await get_tree().process_frame
	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.save_path + suffix))
	GameState.save_path = real_path


# Puts a piece somewhere around `box` where `wanted` becomes true, refreshing
# the checker; returns it, or null if no such spot was found.
func _put_beside(main: Node, fl: Floor, box: Furniture, id: String, wanted: Callable) -> Furniture:
	var f: Furniture = main._spawn_furniture(id, fl, 0, 0)
	f.wall_flush_required = false   # beside the box, wherever that is: walls aren't what's checked
	for dy in range(-10, box.grid_h + 10):
		for dx in range(-14, box.grid_w + 14):
			var at := box.grid_pos + Vector2(dx, dy)
			if fl.can_place(f, at):
				fl.place_furniture(f, at)
				if wanted.call():
					main._refresh_functions()
					return f
	fl.remove_furniture(f)
	f.queue_free()
	main._refresh_functions()
	return null


# Spawns a piece and puts it down wherever on the floor it is allowed to go.
func _place_somewhere(main: Node, fl: Floor, id: String) -> Furniture:
	var f: Furniture = main._spawn_furniture(id, fl, 0, 0)
	if f == null:
		return null
	var b := fl.get_room_bounds()
	for y in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			if fl.can_place(f, Vector2(x, y)):
				fl.place_furniture(f, Vector2(x, y))
				return f
	return f


# ── Space-saving pieces: screens, curtains, skylights, pods ─────────────────
# A 25 x 19 room (tiles 2..26 x 2..20) with a window in its north wall over
# x 5..14.
func _window_floor() -> Floor:
	var fl := load("res://scenes/Wall.tscn").instantiate() as Floor
	add_child(fl)
	fl.setup({"id": "window_floor", "label": "Window", "grid_w": 30, "grid_h": 24, "floor_tiles": [],
		"segments": [
			{"x1": 1, "y1": 1, "x2": 27, "y2": 1, "primary": true, "demolished": false,
				"has_window": true, "window_pos": 4, "window_len": 10},
			{"x1": 27, "y1": 1, "x2": 27, "y2": 21, "primary": true, "demolished": false},
			{"x1": 27, "y1": 21, "x2": 1, "y2": 21, "primary": true, "demolished": false},
			{"x1": 1, "y1": 21, "x2": 1, "y2": 1, "primary": true, "demolished": false},
		]})
	return fl


# A catalogue piece, optionally stretched to another footprint.
func _catalog_piece(fl: Floor, id: String, w: int = 0, h: int = 0) -> Furniture:
	var data := main_catalog_entry(id).duplicate(true)
	if w > 0:
		data["size"] = {"w": w, "h": h}
	var f := load("res://scenes/Furniture.tscn").instantiate() as Furniture
	fl.add_child(f)
	f.setup(data, fl)
	return f


# Reeded glass across the whole room: the far side still gets daylight, but
# nobody sees through it. A bookshelf in the same place leaves it dark.
func _t_reeded_glass() -> void:
	var fl := _window_floor()
	var behind := Vector2i(10, 12)
	var open_light := fl.get_light(behind)
	var open_sight := fl.has_sightline(Vector2i(10, 3), behind)
	var glass := _catalog_piece(fl, "fluted_glass_panel", 25, 3)
	fl.place_furniture(glass, Vector2(2, 6))
	var glass_light := fl.get_light(behind)
	var glass_sight := fl.has_sightline(Vector2i(10, 3), behind)
	fl.remove_furniture(glass)
	var shelf := _catalog_piece(fl, "bookshelf", 25, 3)
	fl.place_furniture(shelf, Vector2(2, 6))
	var shelf_light := fl.get_light(behind)
	_ok(open_light > 0.0 and open_sight and glass_light > 0.0 and not glass_sight and shelf_light == 0.0
		and glass.divides_zone(),
		"open %.2f/%s, glass %.2f/%s, shelf %.2f, zone %s" % [open_light, open_sight, glass_light, glass_sight, shelf_light, glass.divides_zone()])
	fl.queue_free()


# Day and night: the curtain is open by day and drawn at night. Drawn, it
# hides one side of the room from the other and splits the zone, and still
# lets the light through; open, it does neither.
func _t_curtain_per_moment() -> void:
	var real_ids := Furniture.all_moment_ids
	var real_labels := Furniture.moment_labels
	var real_test := Furniture.test_mode_active
	var real_active := Furniture.active_moment_id
	Furniture.all_moment_ids = ["day", "night"]
	Furniture.moment_labels = {"day": "Day", "night": "Night"}
	Furniture.test_mode_active = true
	var fl := _window_floor()
	var curtain := _catalog_piece(fl, "curtain")
	fl.place_furniture(curtain, Vector2(12, 6))
	curtain.moment_fold_state = {"day": false, "night": true}
	var across := [Vector2i(6, 10), Vector2i(20, 10)]
	Furniture.active_moment_id = "night"
	curtain.set_moment_view("night")
	var night := [curtain.is_extended, fl.has_sightline(across[0], across[1]), curtain.divides_zone(), curtain.blocks_light()]
	Furniture.active_moment_id = "day"
	curtain.set_moment_view("day")
	var day := [curtain.is_extended, fl.has_sightline(across[0], across[1]), curtain.divides_zone()]
	_ok(night == [true, false, true, false] and day == [false, true, false],
		"night (drawn, sight, zone, blocks light) %s, day (drawn, sight, zone) %s" % [night, day])
	fl.queue_free()
	Furniture.all_moment_ids = real_ids
	Furniture.moment_labels = real_labels
	Furniture.test_mode_active = real_test
	Furniture.active_moment_id = real_active


# A skylight in a windowless room: it hangs over a bookshelf and a table
# without touching them, lights its own tiles even with the shelf under
# it, takes no floor and is never "out of reach".
func _t_skylight() -> void:
	var fl := _make_floor()
	var dark := fl.get_light(Vector2i(4, 3))
	var free_before := fl.count_free_tiles_for_moment("")
	var shelf := _catalog_piece(fl, "bookshelf", 2, 2)
	fl.place_furniture(shelf, Vector2(4, 3))
	var table := _catalog_piece(fl, "coffee_table", 1, 2)
	fl.place_furniture(table, Vector2(6, 3))
	var free_with_pieces := fl.count_free_tiles_for_moment("")
	var sky := _catalog_piece(fl, "skylight", 3, 3)
	var fits_over := fl.can_place(sky, Vector2(4, 3))
	fl.place_furniture(sky, Vector2(4, 3))
	var lit_under := fl.get_light(Vector2i(4, 3))
	var lit_beside := fl.get_light(Vector2i(4, 6))
	var free_with_sky := fl.count_free_tiles_for_moment("")
	var under_after := fl.can_place(_make_furniture(fl, 1, 1), Vector2(5, 5))
	# Under a raked ceiling it still goes in (a roof window), where a
	# bookshelf no longer fits.
	fl.ceiling_ramps = [{"axis": "x", "low_start": 2, "high_end": 8, "min_h": 1.8, "max_h": 2.4}]
	var tall := _catalog_piece(fl, "bookshelf", 1, 1)
	var under_slope := fl.can_place(sky, Vector2(2, 2)) and not fl.can_place(tall, Vector2(2, 6))
	fl.ceiling_ramps = []
	# Daylight comes in squares (Floor._cast_light): a skylight lights the
	# tiles under it and no others.
	_ok(dark == 0.0 and fits_over and lit_under > 0.9 and lit_beside == 0.0 and free_with_sky == free_with_pieces
		and free_with_pieces == free_before - 6 and fl.support_under(sky) == null
		and not (sky in fl.get_inaccessible_furniture()) and not sky.blocks_sight() and under_after and under_slope,
		"dark %.2f, fits %s, under %.2f, beside %.2f, free %d/%d/%d, support %s, inaccessible %s, under after %s, slope %s" % [
			dark, fits_over, lit_under, lit_beside, free_before, free_with_pieces, free_with_sky,
			fl.support_under(sky), fl.get_inaccessible_furniture(), under_after, under_slope])
	fl.queue_free()


# A sleeping pod is a room in the room: it sleeps and stores, splits the zone,
# and shades and hides what is behind it from the window.
func _t_sleeping_pod() -> void:
	var fl := _window_floor()
	var behind := Vector2i(10, 18)
	var open_light := fl.get_light(behind)
	var pod := _catalog_piece(fl, "sleeping_pod")
	var fits := fl.can_place(pod, Vector2(2, 4))
	fl.place_furniture(pod, Vector2(2, 4))
	var pod_light := fl.get_light(behind)
	_ok(fits and "sleep" in pod.functions and "storage" in pod.functions and pod.divides_zone()
		and pod_light < open_light and fl.get_light(Vector2i(10, 8)) == 0.0
		and not fl.has_sightline(Vector2i(10, 3), behind),
		"fits %s, functions %s, light behind %.2f -> %.2f" % [fits, pod.functions, open_light, pod_light])
	fl.queue_free()


# Fold state decides what a piece gives in each moment, also when one side of
# it gives nothing: the wall gym is sport only unfolded, a Murphy bed sleeps
# only let down.
func _t_fold_gives_per_moment() -> void:
	var fl := _window_floor()
	var gym := _catalog_piece(fl, "wall_gym")
	var bed := _catalog_piece(fl, "murphy_bed")
	for f in [gym, bed]:
		(f as Furniture).moment_fold_state = {"day": true, "night": false}
	_ok(gym.functions_for_moment("day") == ["sport"] and gym.functions_for_moment("night").is_empty()
		and bed.functions_for_moment("day") == ["sleep"] and bed.functions_for_moment("night").is_empty()
		and gym.functions.is_empty() and bed.functions.is_empty(),
		"gym %s/%s, bed %s/%s, folded now %s %s" % [gym.functions_for_moment("day"), gym.functions_for_moment("night"),
			bed.functions_for_moment("day"), bed.functions_for_moment("night"), gym.functions, bed.functions])
	fl.queue_free()
# ── Ceilings and split levels ──────────────────────────────────────────────
func _make_level_floor(extra: Dictionary) -> Floor:
	var floor_data := {
		"id": "test_levels", "label": "Test Levels", "grid_w": 30, "grid_h": 20, "floor_tiles": [],
		"segments": [
			{"x1": 1, "y1": 1, "x2": 21, "y2": 1, "primary": true, "demolished": false},
			{"x1": 21, "y1": 1, "x2": 21, "y2": 13, "primary": true, "demolished": false},
			{"x1": 21, "y1": 13, "x2": 1, "y2": 13, "primary": true, "demolished": false},
			{"x1": 1, "y1": 13, "x2": 1, "y2": 1, "primary": true, "demolished": false},
		],
	}
	floor_data.merge(extra, true)
	var fl := load("res://scenes/Wall.tscn").instantiate() as Floor
	add_child(fl)
	fl.setup(floor_data)
	return fl


# Two ramps make a gable (the lower one wins), a ramp may fall either way, a
# rect keeps a dormer to part of the room, and the old single-ramp key still
# loads.
func _t_ceiling_heights() -> void:
	var gable := _make_level_floor({"ceiling_ramps": [
		{"axis": "x", "low_start": 1, "high_end": 11, "min_h": 1.0, "max_h": 2.6},
		{"axis": "x", "low_start": 20, "high_end": 10, "min_h": 1.0, "max_h": 2.6}]})
	_ok(is_equal_approx(gable.ceiling_height_at(Vector2(1, 5)), 1.0) and is_equal_approx(gable.ceiling_height_at(Vector2(20, 5)), 1.0)
		and gable.ceiling_height_at(Vector2(10, 5)) > 2.4 and gable.ceiling_height_at(Vector2(6, 5)) < gable.ceiling_height_at(Vector2(9, 5)),
		"%s %s %s" % [gable.ceiling_height_at(Vector2(1, 5)), gable.ceiling_height_at(Vector2(10, 5)), gable.ceiling_height_at(Vector2(20, 5))])
	gable.queue_free()
	var dormer := _make_level_floor({"ceiling_ramps": [
		{"axis": "y", "low_start": 1, "high_end": 12, "min_h": 1.2, "max_h": 2.4, "rect": [1, 1, 10, 12]}]})
	_ok(is_equal_approx(dormer.ceiling_height_at(Vector2(3, 1)), 1.2) and is_equal_approx(dormer.ceiling_height_at(Vector2(15, 1)), Floor.CEILING_H_M),
		"inside %s outside %s" % [dormer.ceiling_height_at(Vector2(3, 1)), dormer.ceiling_height_at(Vector2(15, 1))])
	dormer.queue_free()
	var legacy := _make_level_floor({"sloped_ceiling": {"axis": "x", "low_start": 1, "high_end": 20, "min_h": 1.6, "max_h": 2.4}, "ceiling_h": 2.7})
	_ok(legacy.ceiling_ramps.size() == 1 and is_equal_approx(legacy.ceiling_height_at(Vector2(1, 3)), 1.6)
		and is_equal_approx(legacy.ceiling_h, 2.7), str(legacy.ceiling_ramps))
	legacy.queue_free()


# A platform 40 cm up over x 1..8, reached over steps at x 9..11, y 4..8.
func _split_fixture() -> Floor:
	var levels: Array = []
	var steps: Array = []
	for y in range(1, 13):
		for x in range(1, 9):
			levels.append([x, y, 4])
	for y in range(4, 9):
		for x in range(9, 12):
			levels.append([x, y, 2])
			steps.append([x, y])
	return _make_level_floor({"floor_levels": levels, "step_tiles": steps})


func _t_split_level_rules() -> void:
	var fl := _split_fixture()
	var f := _make_furniture(fl, 2, 2)
	_ok(fl.can_place(f, Vector2(3, 3)) and fl.can_place(f, Vector2(14, 3)), fl.get_block_reason())
	_ok(not fl.can_place(f, Vector2(8, 2)) and fl.get_block_reason() == "Can't stand across a step", fl.get_block_reason())
	_ok(not fl.can_place(f, Vector2(9, 5)) and fl.get_block_reason() == "Keep the steps clear", fl.get_block_reason())
	# The platform takes its height off the ceiling: 2.1 m fits on the floor
	# below, not on the platform (2.1 + 0.4 > 2.4).
	f.body_h = 21
	_ok(fl.can_place(f, Vector2(14, 3)) and not fl.can_place(f, Vector2(3, 3)) and fl.get_block_reason() == "Ceiling too low here",
		fl.get_block_reason())
	_eq(fl.level_under(Vector2(3, 3), 2, 2), 4, "level under")
	var reached := fl.get_reachable_floor()
	_ok(reached.has(Vector2i(3, 3)) and reached.has(Vector2i(15, 6)), "walks onto the platform over the steps")
	_ok(not fl.patch_level_ok(Vector2i(7, 1), 4) and fl.patch_level_ok(Vector2i(8, 4), 4),
		"a patch over the edge is a ledge, one on the steps is floor")
	# Without the steps the platform is cut off: the bigger floor below wins.
	fl.step_mask.clear()
	for y in range(4, 9):
		for x in range(9, 12):
			fl.floor_level.erase(Vector2i(x, y))
	reached = fl.get_reachable_floor()
	_ok(not reached.has(Vector2i(3, 3)) and reached.has(Vector2i(15, 6)), "no steps, no way up")
	f.queue_free()
	fl.queue_free()


# The real levels: the attic's gable keeps tall pieces to its middle and
# counts what a piece stands on; the split-level studio's platform and pit
# show in 2D rules, in 3D and in where tenants stand.
func _t_sloped_split_levels() -> void:
	var real_path := GameState.save_path
	GameState.save_path = "user://test_levels_save.json"
	GameState.pending_level_id = "debug:_attic"
	GameState.pending_resume = false
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	var fl: Floor = main._floors[main._current_floor_id]
	var wardrobe: Furniture = main._spawn_furniture("wardrobe", fl, 0, 0)
	wardrobe.wall_flush_required = false   # not what this checks: stands in the room
	fl.forget_furniture(wardrobe)
	_current = "attic: a wardrobe is refused under the eaves and fits under the ridge"
	_ok(not fl.can_place(wardrobe, Vector2(24, 2)) and fl.get_block_reason() == "Ceiling too low here"
		and fl.can_place(wardrobe, Vector2(24, 14)), fl.get_block_reason())
	_current = "attic: carrying it shows the low ceiling on both eaves, not the ridge"
	var low: Array = fl.carry_hints(wardrobe)["low_ceiling"]
	_ok(Vector2i(24, 2) in low and Vector2i(24, 35) in low and not (Vector2i(24, 18) in low), "%d tiles" % low.size())
	var desk: Furniture = main._spawn_furniture("desk", fl, 0, 0)
	var lamp: Furniture = main._spawn_furniture("desk_lamp", fl, 0, 0)
	fl.forget_furniture(lamp)
	_current = "attic: a desk fits under the eaves, a lamp on it doesn't (it stands 0.8 m higher)"
	var desk_ok := fl.can_place(desk, Vector2(24, 3))
	fl.place_furniture(desk, Vector2(24, 3))
	_ok(desk_ok and not fl.can_place(lamp, Vector2(25, 4)) and fl.get_block_reason() == "Ceiling too low here", fl.get_block_reason())
	fl.remove_furniture(desk)
	main._set_view_mode(main.ViewMode.VIEW3D)
	for i in 5:
		await get_tree().process_frame
	var view = main._mode3d_view
	var heights: Array = []
	for wd in view._wall_data:
		heights.append([snappedf(wd["full_h"] as float, 0.01), wd.get("flat", true)])
	_current = "attic 3D: knee walls are 1 m, the gable ends rise to the ridge, and the ceiling is drawn"
	var has_ceiling := false
	for n in view.build_root.get_children():
		if n.has_meta("sloped_ceiling"):
			has_ceiling = true
	_ok([1.0, true] in heights and heights.any(func(h): return (h[0] as float) > 2.4 and not h[1]) and has_ceiling, str(heights))
	main._set_view_mode(main.ViewMode.TOPDOWN)
	wardrobe.queue_free()
	lamp.queue_free()
	main.queue_free()
	for i in 3:
		await get_tree().process_frame

	GameState.pending_level_id = "debug:_split_level"
	main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 10:
		await get_tree().process_frame
	fl = main._floors[main._current_floor_id]
	var bed: Furniture = null
	var sofa: Furniture = null
	for f in fl.get_all_furniture():
		if (f as Furniture).furniture_id == "normal_bed": bed = f
		if (f as Furniture).furniture_id == "sofa": sofa = f
	var shelf: Furniture = main._spawn_furniture("bookshelf", fl, 0, 0)
	shelf.wall_flush_required = false   # not what this checks: stands in the room
	fl.forget_furniture(shelf)
	var wr: Furniture = main._spawn_furniture("wardrobe", fl, 0, 0)
	wr.wall_flush_required = false   # not what this checks: stands in the room
	fl.forget_furniture(wr)
	var stool: Furniture = main._spawn_furniture("stool", fl, 0, 0)
	fl.forget_furniture(stool)
	_current = "split level: on the 40 cm platform a stool fits and a bookshelf is too tall; below, the bookshelf fits"
	_ok(fl.can_place(stool, Vector2(2, 11)) and not fl.can_place(shelf, Vector2(2, 11))
		and fl.get_block_reason() == "Ceiling too low here" and fl.can_place(shelf, Vector2(30, 5)), fl.get_block_reason())
	_current = "split level: nothing stands on the steps or across the platform's edge"
	_ok(not fl.can_place(shelf, Vector2(11, 15)) and fl.get_block_reason() == "Keep the steps clear", fl.get_block_reason())
	_ok(not fl.can_place(wr, Vector2(18, 11)) and fl.get_block_reason() == "Can't stand across a step", fl.get_block_reason())
	Floor.pathing_enabled = true
	_current = "split level: the bed on the platform and the sofa in the pit can both be walked to"
	_ok(bed != null and sofa != null and fl.is_reachable(bed) and fl.is_reachable(sofa))
	Floor.pathing_enabled = false
	main._set_view_mode(main.ViewMode.VIEW3D)
	for i in 5:
		await get_tree().process_frame
	view = main._mode3d_view
	var bottom_of := func(f: Furniture) -> float:
		var e: Dictionary = view._entry_of(f)
		return (e["mesh"] as Node3D).position.y - (e["size"] as Vector3).y * 0.5 if not e.is_empty() else -99.0
	_current = "split level 3D: the bed stands 40 cm up, the sofa 30 cm down"
	_ok(is_equal_approx(bottom_of.call(bed), 0.4) and is_equal_approx(bottom_of.call(sofa), -0.3),
		"bed %s sofa %s" % [bottom_of.call(bed), bottom_of.call(sofa)])
	_current = "split level 3D: a tenant using the bed stands on the platform"
	_ok(is_equal_approx(view._entry_of(bed).get("floor_y", 0.0) as float, 0.4), str(view._entry_of(bed).get("floor_y")))
	main._set_view_mode(main.ViewMode.TOPDOWN)
	shelf.queue_free()
	wr.queue_free()
	stool.queue_free()
	main.queue_free()
	for i in 3:
		await get_tree().process_frame
	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.save_path + suffix))
	GameState.save_path = real_path
