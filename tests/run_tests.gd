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
	for y in range(bounds.position.y, bounds.end.y, 2):
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

	# Now the flat too: the project is rented out.
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
	var placed_washer := fl.can_place(washer, Vector2(3, 14))
	fl.place_furniture(washer, Vector2(3, 14))
	_current = "surface box: a washer below it is heard but doesn't shade it"
	_ok(placed_washer and main._has_noisy_neighbor(fl, box.grid_pos, box.grid_w, box.grid_h, box)
		and is_equal_approx(main._compute_box_occlusion(box), 1.0), fl.get_block_reason())
	fl.remove_furniture(washer)
	var shelf: Furniture = main._spawn_furniture("bookshelf", fl, 0, 0)
	var placed_shelf := fl.can_place(shelf, Vector2(2, 14))
	fl.place_furniture(shelf, Vector2(2, 14))
	main._refresh_functions()
	_current = "surface box: a bookshelf taller than the dresser does shade it"
	_ok(placed_shelf and main._compute_box_occlusion(box) < 0.2, str(main._compute_box_occlusion(box)))

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
	_current = "surface box: back out, the box is still on the dresser"
	_ok(box != null and box.grid_pos == Vector2(10, 14) and dresser != null and dresser.furniture_id == "dresser",
		"%s on %s" % [box, dresser])

	if box and dresser:
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
		main._set_view_mode(main.ViewMode.TOPDOWN)

		_current = "surface box: moving the dresser takes the box along"
		var moved := fl.can_place(dresser, dresser.grid_pos + Vector2(1, 1)) and fl.move_with_riders(dresser, dresser.grid_pos + Vector2(1, 1))
		_ok(moved and box.grid_pos == Vector2(11, 15) and fl.support_under(box) == dresser, "%s %s" % [moved, box.grid_pos])

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


# Puts a piece somewhere around `box` where `wanted` becomes true, refreshing
# the checker; returns it, or null if no such spot was found.
func _put_beside(main: Node, fl: Floor, box: Furniture, id: String, wanted: Callable) -> Furniture:
	var f: Furniture = main._spawn_furniture(id, fl, 0, 0)
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
