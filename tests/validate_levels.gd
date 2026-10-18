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
# room, blocked by a wall, wrong flooring, across a step or on one, a raised
# or sunken level no steps lead onto). WARNINGS are layouts the game
# would refuse as a drop but that can be a deliberate starting puzzle
# (too little clearance, ceiling too low). The last line printed is
# "RESULT: OK" or "RESULT: FAIL".

const ERROR_PREFIXES := ["Overlaps", "Outside the room", "Blocked by a wall", "Needs bathroom flooring",
	"Needs balcony flooring", "Must be placed against a wall", "Keep the steps clear", "Can't stand across a step"]


func _ready() -> void:
	# Block reasons are matched against their English source text below.
	TranslationServer.set_locale("en")
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
		# Split levels: every raised or sunken stretch has to be reachable
		# over steps, whatever the walking-paths setting (tenants walk there).
		for fid in main._floors:
			var sfl: Floor = main._floors[fid]
			if not sfl.has_split_levels():
				continue
			var reached := sfl.get_reachable_floor()
			for region in sfl.level_regions():
				var rd := region as Dictionary
				if (rd["size"] as int) < Floor.WALK_WIDTH * Floor.WALK_WIDTH:
					continue   # a sliver too small to stand on is a ledge, not a level
				if not (rd["tiles"] as Array).any(func(t): return reached.has(t)):
					errors += 1
					lines.append("    ERROR  the %+d cm level around (%d, %d) on %s: no steps lead onto it" % [
						(rd["level"] as int) * 10, int((rd["center"] as Vector2).x), int((rd["center"] as Vector2).y), fid])
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

	var app_counts := _check_applications(levels, only)
	errors += app_counts[0]
	warnings += app_counts[1]

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


# Rental applications (data/tenants/*.tres): every line must point at a
# requirement its level really has and be spoken by one of its residents.
# Warnings: a requirement no line mentions (it still appears in the bar, just
# without an introduction), or a level whose application is not 4-6 lines
# long when it has that many requirements. Returns [errors, warnings].
func _check_applications(levels: Array, only: String) -> Array:
	var errors := 0
	var warnings := 0
	var level_ids: Array = []
	for lv in levels:
		level_ids.append((lv as Dictionary)["id"])
		var id: String = (lv as Dictionary)["id"]
		if only != "" and id != only:
			continue
		var app := TenantApplication.for_level(id)
		if app == null:
			continue
		var out: PackedStringArray = []
		var ids := Requirements.ids_for_level(lv as Dictionary)
		if app.level_id != id:
			out.append("    ERROR  application says level_id \"%s\"" % app.level_id)
			errors += 1
		var resident_ids: Array = []
		for r in app.residents:
			if r.id == &"" or r.id in resident_ids:
				out.append("    ERROR  resident with a missing or repeated id (\"%s\")" % r.id)
				errors += 1
			resident_ids.append(r.id)
		var covered: Array = []
		for line in app.lines:
			if line.requirement not in ids:
				out.append("    ERROR  line \"%s\" points at %s, which this level doesn't have" % [line.text.left(40), line.requirement])
				errors += 1
			if line.speaker != &"" and line.speaker not in resident_ids:
				out.append("    ERROR  line \"%s\" is spoken by unknown resident %s" % [line.text.left(40), line.speaker])
				errors += 1
			if not line.hidden and line.text.strip_edges() == "":
				out.append("    ERROR  a printed line has no text (%s)" % line.requirement)
				errors += 1
			covered.append(line.requirement)
		# A need line on a level with moments covers that need in every moment.
		for req in ids:
			var parts := req.split(":")
			var is_covered := req in covered or (parts[0] == "moment" and ("need:" + parts[2]) in covered) \
				or (parts[0] == "need" and covered.any(func(c): return (c as String).begins_with("moment:") and (c as String).ends_with(":" + parts[1])))
			if not is_covered:
				out.append("    warn   no line mentions %s" % req)
				warnings += 1
		var printed := app.printed_lines().size()
		var distinct := ids.filter(func(r): return not (r as String).begins_with("moment:")).size()
		if distinct >= 4 and (printed < 4 or printed > 6):
			out.append("    warn   %d printed lines (aim for 4-6)" % printed)
			warnings += 1
		if not out.is_empty():
			print("%s  (application)" % id)
			for l in out:
				print(l)
	for f in DirAccess.get_files_at(TenantApplication.DIR):
		if f.ends_with(".tres"):
			var app := load(TenantApplication.DIR + f) as TenantApplication
			if app == null or app.level_id not in level_ids:
				print("%s  (application)\n    ERROR  no level \"%s\" in levels.json" % [f, app.level_id if app else "?"])
				errors += 1
	return [errors, warnings]

