extends Control

# Dev probe: opens the game's real Room3DView on a small throwaway room filled
# with catalog furniture, so the diorama style can be checked on the actual
# view (walls, models, ghosts, night) without playing through to a level.
#
#   1-9 palette    N day/night    orbit/zoom/pan as in the game
#
# `-- --shots=<dir>` saves day and night PNGs per palette and quits.
# `-- --item=<furniture id>` shows the shop's single-item preview instead.
# `-- --buy=<furniture id>` starts buying that piece, ghost at screen centre.

const ROOM_W := 40   # tiles (10 cm each)
const ROOM_D := 30

var _view: Room3DView
var _palettes: Array[LevelPalette] = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var fl := _make_floor()
	var catalog: Array = (JSON.parse_string(FileAccess.get_file_as_string("res://data/furniture.json")) as Dictionary)["furniture"]
	_fill(fl, catalog)

	_view = (load("res://scenes/Room3DView.tscn") as PackedScene).instantiate() as Room3DView
	add_child(_view)
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.get_node("CloseBtn").visible = false
	_view.build_from_floor(fl, catalog, null)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--buy="):
			for entry in catalog:
				if (entry as Dictionary).get("id", "") == arg.trim_prefix("--buy="):
					var f := (load("res://scenes/Furniture.tscn") as PackedScene).instantiate() as Furniture
					fl.add_child(f)
					f.setup(entry as Dictionary, fl)
					_view.start_buying(f, entry as Dictionary)
					_view._update_buy_ghost(Vector2(_view.sub_vp.size) * Vector2(0.56, 0.6))
		if arg.begins_with("--item="):
			for entry in catalog:
				if (entry as Dictionary).get("id", "") == arg.trim_prefix("--item="):
					_view.build_single_item(entry as Dictionary)

	_palettes = PaletteLibrary.all()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_run_shots(arg.trim_prefix("--shots="))


func _unhandled_key_input(event: InputEvent) -> void:
	var ke := event as InputEventKey
	if ke == null or not ke.pressed or ke.echo or _view._style == null:
		return
	if ke.keycode >= KEY_1 and ke.keycode <= KEY_9 and ke.keycode - KEY_1 < _palettes.size():
		_view._style.palette = _palettes[ke.keycode - KEY_1]
	elif ke.keycode == KEY_N:
		create_tween().tween_property(_view._style, "night", 0.0 if _view._style.night > 0.5 else 1.0, 0.6)


# Same fixture shape as tests/run_tests.gd, plus one interior partition.
func _make_floor() -> Floor:
	var x1 := 1 + ROOM_W
	var y1 := 1 + ROOM_D
	var floor_data := {
		"id": "probe_floor", "label": "Probe", "grid_w": ROOM_W + 10, "grid_h": ROOM_D + 10,
		"floor_tiles": [],
		"segments": [
			{"x1": 1, "y1": 1, "x2": x1, "y2": 1, "primary": true, "demolished": false,
				"has_window": true, "window_pos": 5, "window_len": 12, "has_door": true, "door_pos": 28},
			{"x1": x1, "y1": 1, "x2": x1, "y2": y1, "primary": true, "demolished": false,
				"has_window": true, "window_pos": 14, "window_len": 10},
			{"x1": x1, "y1": y1, "x2": 1, "y2": y1, "primary": true, "demolished": false,
				"has_door": true, "door_pos": 24},
			{"x1": 1, "y1": y1, "x2": 1, "y2": 1, "primary": true, "demolished": false,
				"has_window": true, "window_pos": 8, "window_len": 12},
			{"x1": 26, "y1": 1, "x2": 26, "y2": 12, "primary": false, "demolished": false},
		],
	}
	var fl := (load("res://scenes/Wall.tscn") as PackedScene).instantiate() as Floor
	fl.visible = false
	add_child(fl)
	fl.setup(floor_data)
	return fl


# Drops the first few floor-standing catalog pieces that have a model wherever
# they fit, scanning the room on a coarse grid.
func _fill(fl: Floor, catalog: Array) -> void:
	var wanted := ["bed", "sofa", "wardrobe", "desk", "lamp", "plant", "table", "bookcase"]
	var placed := 0
	for key in wanted:
		for entry in catalog:
			var fdata := entry as Dictionary
			if (fdata.get("placement", "floor") as String) != "floor" or not fdata.has("model"):
				continue
			if (fdata.get("id", "") as String).to_lower().find(key) == -1:
				continue
			if fdata.get("animated_fold", false) or fdata.get("is_nested_box", false):
				continue
			var f := (load("res://scenes/Furniture.tscn") as PackedScene).instantiate() as Furniture
			fl.add_child(f)
			f.setup(fdata, fl)
			var done := false
			for y in range(2, ROOM_D, 3):
				for x in range(2, ROOM_W, 3):
					var at := fl.snap_to_wall(f, Vector2(x, y))
					if fl.can_place(f, at):
						fl.place_furniture(f, at)
						done = true
						break
				if done:
					break
			if done:
				placed += 1
			else:
				f.queue_free()
			break
	print("[Room3DProbe] placed %d pieces" % placed)


func _run_shots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	# Let the view's own day/night tween (started by build_from_floor) finish,
	# or it would keep pulling `night` back while the first shots are taken.
	await get_tree().create_timer(1.0).timeout
	if _view._style == null:
		_palettes = [null]
	for p in _palettes:
		var label := "unstyled"
		if p != null:
			_view._style.palette = p
			label = p.resource_path.get_file().get_basename()
		for night in [0.0, 1.0]:
			if _view._style != null:
				_view._style.night = night
			for _f in 6:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var file := "%s/room_%s_%s.png" % [dir, label, "night" if night > 0.5 else "day"]
			get_viewport().get_texture().get_image().save_png(file)
			print("[Room3DProbe] saved ", file)
	get_tree().quit()
