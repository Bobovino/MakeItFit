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
	print("\n%d passed, %d failed" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _run_all() -> void:
	_test("place then overlap is rejected", func(): _t_place_and_overlap())
	_test("non-overlapping placement succeeds", func(): _t_no_overlap_elsewhere())
	_test("outside the room is rejected", func(): _t_outside_room())
	_test("a wall tile is rejected", func(): _t_wall_blocked())
	_test("snap_to_wall lands flush against the wall", func(): _t_snap_to_wall())
	_test("remove_furniture frees the tiles it occupied", func(): _t_remove_furniture())
	_test("rotation cycles 0/1/2/3 and swaps footprint each step", func(): _t_rotation_cycle())
	_test("pathing: a piece beside open floor is reachable", func(): _t_path_open())
	_test("pathing: no room to walk means nothing is reachable", func(): _t_path_blocked())
	_test("pathing: a piece must be reachable from its front", func(): _t_path_front())


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


func _puzzle_state(main: Node, fl: Floor) -> String:
	var pieces: Array = []
	for entry in fl.get_all_furniture():
		var f := entry as Furniture
		pieces.append("%s@%s/%s" % [f.furniture_id, f.grid_pos, f.is_extended])
	pieces.sort()
	var gm: GameManager = main.gm
	return "%s | reach %d | %s | win %s | fns %s" % [pieces, fl.get_reachable_floor().size(),
		Requirements.status(gm), gm.check_win(), gm.fulfilled_functions]
