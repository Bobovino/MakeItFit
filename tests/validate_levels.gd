extends Node

# Level validator — loads every level in levels.json through the real game
# and asks the game's own placement code whether each starting piece could
# be put down where it stands. Catches what hand-written or script-generated
# level data gets wrong without anyone noticing: two pieces sharing tiles, a
# piece outside the room or inside a wall, a piece under a ceiling too low
# for it, or on flooring it isn't allowed on.
#
# Run it after creating or editing levels outside the level editor:
#   godot --headless --path . res://tests/ValidateLevels.tscn
# Add `-- --level=<id>` to check one level, `-- --strict` to fail on
# warnings too.
#
# ERRORS are layouts no player could have produced (overlap, outside the
# room, blocked by a wall, wrong flooring). WARNINGS are layouts the game
# would refuse as a drop but that can be a deliberate starting puzzle
# (too little clearance, ceiling too low). The last line printed is
# "RESULT: OK" or "RESULT: FAIL".

const ERROR_PREFIXES := ["Overlaps", "Outside the room", "Blocked by a wall", "Needs bathroom flooring",
	"Needs balcony flooring", "Must be placed against a wall"]


func _ready() -> void:
	var only := ""
	var strict := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--level="):
			only = arg.trim_prefix("--level=")
		elif arg == "--strict":
			strict = true
		elif arg == "--pathing":
			Floor.pathing_enabled = true
		elif arg == "--no-pathing":
			Floor.pathing_enabled = false

	# Main reads the level to open from GameState; point it at one that
	# exists before it is created.
	var levels: Array = (JSON.parse_string(FileAccess.get_file_as_string("res://data/levels.json")) as Dictionary).get("levels", [])
	if levels.is_empty():
		printerr("No levels found")
		get_tree().quit(1)
		return
	GameState.pending_level_id = (levels[0] as Dictionary)["id"]
	var main: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().create_timer(0.3).timeout

	var errors := 0
	var warnings := 0
	var checked := 0
	for lv in levels:
		var id: String = (lv as Dictionary)["id"]
		if only != "" and id != only:
			continue
		checked += 1
		main._nested_stack.clear()
		main._load_level(id)
		await get_tree().process_frame
		var lines: PackedStringArray = []
		for fid in main._floors:
			var fl: Floor = main._floors[fid]
			for entry in fl.get_all_furniture():
				var f: Furniture = entry
				if fl.can_place(f, f.grid_pos):
					continue
				var reason: String = fl.get_block_reason()
				var is_error := false
				for prefix in ERROR_PREFIXES:
					if reason.begins_with(prefix):
						is_error = true
				# A piece that needs a surface under it and has one is
				# stacked on purpose; the surface then reports the piece on
				# top as an "overlap". That is how stacking is stored, not a
				# mistake.
				if is_error and reason.begins_with("Overlaps") and _is_stack(fl, f):
					continue
				if is_error:
					errors += 1
				else:
					warnings += 1
				lines.append("    %s  %s at (%d, %d) on %s: %s" % ["ERROR" if is_error else "warn ",
					f.furniture_name, int(f.grid_pos.x), int(f.grid_pos.y), fid, reason])
		# With the walking-paths rule on (--pathing, or the saved setting),
		# a starting piece the tenant can't walk to is an error too.
		if Floor.pathing_enabled:
			for fid in main._floors:
				var pfl: Floor = main._floors[fid]
				for entry in pfl.get_unreachable_furniture():
					var pf: Furniture = entry
					errors += 1
					lines.append("    ERROR  %s at (%d, %d) on %s: Can't be walked to from the door" % [
						pf.furniture_name, int(pf.grid_pos.x), int(pf.grid_pos.y), fid])
		if not lines.is_empty():
			print("%s  (%s)" % [id, (lv as Dictionary).get("name", "")])
			for line in lines:
				print(line)

	var failed := errors > 0 or (strict and warnings > 0)
	print("\nWalking-paths rule: %s" % ("ON" if Floor.pathing_enabled else "off"))
	print("%d level(s) checked: %d error(s), %d warning(s)" % [checked, errors, warnings])
	# Read this line, not the process exit code: the engine can crash while
	# shutting down after a level has been loaded, which replaces the code.
	print("RESULT: %s" % ("FAIL" if failed else "OK"))
	get_tree().quit(1 if failed else 0)


# True when `f` shares tiles with another piece only because one is standing
# on the other (a lamp on a desk).
func _is_stack(fl: Floor, f: Furniture) -> bool:
	var mine := Rect2(f.grid_pos, Vector2(f.grid_w, f.grid_h))
	var found := false
	for entry in fl.get_all_furniture():
		var other: Furniture = entry
		if other == f or not mine.intersects(Rect2(other.grid_pos, Vector2(other.grid_w, other.grid_h))):
			continue
		if not (f.is_surface and other.requires_surface) and not (other.is_surface and f.requires_surface):
			return false   # a real overlap with something that isn't a stack
		found = true
	return found
