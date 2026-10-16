extends RefCounted
class_name LevelProgress

# A level as the player left it, exactly: every piece (position, rotation,
# fold state, its own position and fold state per moment, the starting spot
# comfort is measured from), things hung on walls, walls/floors/pipes built,
# made-to-measure pieces painted, the budget, what is waiting under "Owned",
# the moment on screen and which moments have already been met.
#
# Used for the autosave (GameState.progress) and for the levels inside boxes
# while the player is elsewhere in the same project (Main._full_level_states).
# Restoring gives the checker exactly the layout it judged before, so a level
# is no more and no less solved after a save and a load.
#
# The dictionaries hold Godot values (Vector2, Vector2i keys...); GameState
# stores them with var_to_str, which keeps those types intact.

const VERSION := 1


static func capture(main: Node) -> Dictionary:
	var gm: GameManager = main.gm
	var floors := {}
	for fid in main._floors:
		var fl: Floor = main._floors[fid]
		var pieces: Array = []
		for entry in fl.get_all_furniture():
			var f := entry as Furniture
			var p := {
				"id": f.furniture_id, "pos": f.grid_pos, "rot": f.rot_steps, "ext": f.is_extended,
				"home": f._home_grid_pos,
				"moment_pos": f.moment_positions.duplicate(),
				"moment_fold": f.moment_fold_state.duplicate(),
			}
			if f.is_nested_box:
				p["child_level_id"] = f.child_level_id
			if f.keepsake:
				p["keepsake"] = true
			pieces.append(p)
		var paint := {}
		var painted: Dictionary = main._paint_pieces.get(fid, {})
		for type_id in painted:
			var piece = painted[type_id]
			if is_instance_valid(piece) and not (piece.tiles as Array).is_empty():
				paint[type_id] = (piece.tiles as Array).duplicate()
		floors[fid] = {
			"loft": fl.floor_type == "loft",
			"pieces": pieces,
			"wall_items": (fl.wall_items as Dictionary).duplicate(true),
			"builder": (main._capture_builder_entry(fl) as Dictionary)["data"],
			"paint": paint,
		}
	return {
		"version": VERSION,
		"budget": gm.budget,
		"owned": gm.starting_inventory.duplicate(true),
		"moment": main._active_moment_id,
		"verified": gm.moment_verified.duplicate(),
		"zone_ok": gm.moment_zone_ok.duplicate(),
		"sight_ok": gm.moment_sightline_ok.duplicate(),
		"floor": main._current_floor_id,
		"floors": floors,
	}


# Replaces the freshly loaded level's contents with `data`. Call right after
# Main._load_level() of the same level.
static func apply(main: Node, data: Dictionary) -> void:
	if data.is_empty() or int(data.get("version", 0)) > VERSION:
		return
	var gm: GameManager = main.gm
	main._restoring_furniture = true
	main._batch_refresh = true   # one needs check at the end, not one per piece
	var was_armed: bool = main._rent_auto_armed
	main._rent_auto_armed = false

	gm.budget = int(data.get("budget", gm.budget))
	gm.budget_changed.emit(gm.budget)
	gm.starting_inventory = (data.get("owned", []) as Array).duplicate(true)
	main._refresh_owned_ui()

	var floors: Dictionary = data.get("floors", {})
	# Ordinary floors first: a loft floor only exists once its loft bed is
	# back (spawning one creates it).
	var order: Array = floors.keys().filter(func(k): return not (floors[k] as Dictionary).get("loft", false))
	order += floors.keys().filter(func(k): return (floors[k] as Dictionary).get("loft", false))
	for fid in order:
		var fl: Floor = main._floors.get(fid)
		if fl == null:
			continue
		var fd: Dictionary = floors[fid]
		fl.begin_batch()
		main._apply_builder_entry({"floor_id": fid, "data": fd.get("builder", {})})
		for entry in fl.get_all_furniture().duplicate():
			fl.remove_furniture(entry as Furniture)
			(entry as Furniture).queue_free()
		fl.wall_items.clear()
		for p in fd.get("pieces", []) as Array:
			_restore_piece(main, fl, p as Dictionary)
		var walls: Dictionary = fd.get("wall_items", {})
		for edge in walls:
			for origin in walls[edge]:
				fl.place_wall_item(edge, origin as Vector2i, walls[edge][origin] as String)
		_restore_paint(main, fid, fl, fd.get("paint", {}))
		fl.end_batch()

	gm.moment_verified = (data.get("verified", {}) as Dictionary).duplicate()
	gm.moment_zone_ok = (data.get("zone_ok", {}) as Dictionary).duplicate()
	gm.moment_sightline_ok = (data.get("sight_ok", {}) as Dictionary).duplicate()
	main._restoring_furniture = false
	main._batch_refresh = false
	var moment := data.get("moment", "") as String
	if moment != "" and not gm.moments.is_empty():
		main._on_moment_selected(moment, false)
	else:
		main._refresh_functions()
	var floor_id := data.get("floor", "") as String
	if floor_id != "" and main._floors.has(floor_id) and floor_id != main._current_floor_id:
		main._switch_floor(floor_id)
	main._update_accessibility()
	main._last_furniture_state = main._snapshot_all_furniture()
	main._rent_auto_armed = was_armed
	main._update_rent_btn()
	if main._view_mode == main.ViewMode.VIEW3D and is_instance_valid(main._mode3d_view):
		main._ensure_mode3d_view()


static func _restore_piece(main: Node, fl: Floor, p: Dictionary) -> void:
	var overrides := {}
	for key in ["child_level_id", "keepsake"]:
		if p.has(key):
			overrides[key] = p[key]
	var pos: Vector2 = p.get("pos", Vector2.ZERO)
	var f: Furniture = main._spawn_furniture(p["id"] as String, fl, floori(pos.x), floori(pos.y), overrides)
	if f == null:
		return
	var rot := int(p.get("rot", 0))
	if rot != f.rot_steps:
		f.set_rot_steps(rot)
	fl.place_furniture(f, pos)   # the exact spot: 3D moves aren't grid-snapped
	f._home_grid_pos = p.get("home", pos)
	f.moment_positions = (p.get("moment_pos", {}) as Dictionary).duplicate()
	f.moment_fold_state = (p.get("moment_fold", {}) as Dictionary).duplicate()
	if bool(p.get("ext", false)) != f.is_extended and f.foldable:
		f._apply_fold_state(bool(p.get("ext", false)))


static func _restore_paint(main: Node, fid: String, fl: Floor, paint: Dictionary) -> void:
	if paint.is_empty():
		return
	# Painted pieces are filed under the floor on screen; put this floor on
	# screen for the moment so they land under the right one.
	var shown: String = main._current_floor_id
	main._current_floor_id = fid
	for type_id in paint:
		var piece: PaintedFurniture = main._get_or_create_paint_piece(type_id, fl)
		for t in paint[type_id] as Array:
			piece.set_tile(t as Vector2i, true)
	main._current_floor_id = shown
