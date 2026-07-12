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
	_run_all()
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
