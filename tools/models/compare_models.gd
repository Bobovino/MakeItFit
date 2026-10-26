extends Node

# Renders furniture models old against new, each alone in the game's own 3D
# preview (Room3DView.build_single_item, with the style and the ink), closed
# and, for a piece that folds, open. Needs a window (it renders):
#
#   godot --path . res://tools/models/compare_models.tscn -- --ids=wardrobe,bathtub [--new-dir=<folder>] [--out=<folder>]
#
# --new-dir defaults to res://assets/models/furniture/styletest, --out to
# the user data folder's model_compare/. Writes <id>.png per piece (old on
# the left, new on the right, closed above open) and sheet.png with all of
# them. Leaves the catalogue and the player's save alone.

const NEW_DIR := "res://assets/models/furniture/styletest"
const SHOT := Vector2i(560, 420)

var _out := "user://model_compare"


func _ready() -> void:
	TranslationServer.set_locale("en")
	var ids: PackedStringArray = []
	var new_dir := NEW_DIR
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ids="):
			ids = a.substr(6).split(",", false)
		elif a.begins_with("--new-dir="):
			new_dir = a.substr(10).trim_suffix("/")
		elif a.begins_with("--out="):
			_out = a.substr(6).trim_suffix("/")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out))
	var catalog := {}
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/furniture.json"))
	for it in data["furniture"]:
		catalog[it["id"]] = it
	if ids.is_empty():
		for f in DirAccess.get_files_at(new_dir):
			if f.ends_with(".glb") and catalog.has(f.get_basename()):
				ids.append(f.get_basename())
	var tiles: Array = []
	for id in ids:
		if not catalog.has(id):
			print("%s: not in the catalogue" % id)
			continue
		var old: Dictionary = (catalog[id] as Dictionary).duplicate(true)
		var new: Dictionary = old.duplicate(true)
		new["model"] = "%s/%s.glb" % [new_dir, id]
		var folds := (old.get("open_anim", false) as bool) and not (old.get("pose_open", false) as bool)
		var shots: Array = []
		for fdata in [old, new]:
			shots.append(await _render(fdata, false))
			if folds:
				shots.append(await _render(fdata, true))
		var tile := _grid(shots, 2, folds)
		tile.save_png("%s/%s.png" % [_out, id])
		tiles.append(tile)
		print("%s: done" % id)
	if not tiles.is_empty():
		_sheet(tiles).save_png("%s/sheet.png" % _out)
	print("written to " + ProjectSettings.globalize_path(_out))
	get_tree().quit()


func _render(fdata: Dictionary, open: bool) -> Image:
	var v = (load("res://scenes/Room3DView.tscn") as PackedScene).instantiate()
	add_child(v)
	v.set_anchors_preset(Control.PRESET_TOP_LEFT)
	v.size = Vector2(SHOT)
	await get_tree().process_frame
	v.build_single_item(fdata)
	v._auto_spin = false
	v._fold_auto = false
	v._fold_target = 1.0 if open else 0.0
	v._fold_t = v._fold_target
	v._yaw = -35.0
	v._pitch = -24.0
	# The preview frames a folding piece for its open size too; anything else
	# can come closer.
	v._dist *= 0.75 if (fdata.get("foldable", false) as bool) else 0.55
	v._update_camera()
	await get_tree().create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	var img: Image = v.sub_vp.get_texture().get_image()
	v.queue_free()
	await get_tree().process_frame
	return img


# Old in the first column, new in the second; closed above open.
func _grid(shots: Array, cols: int, folds: bool) -> Image:
	var w: int = (shots[0] as Image).get_width()
	var h: int = (shots[0] as Image).get_height()
	var rows := 2 if folds else 1
	var img := Image.create(w * cols + 8, h * rows + (8 if folds else 0), false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	for i in shots.size():
		var col: int = i / rows
		var row: int = i % rows
		var s: Image = shots[i]
		s.convert(Image.FORMAT_RGBA8)
		img.blit_rect(s, Rect2i(Vector2i.ZERO, s.get_size()), Vector2i(col * (w + 8), row * (h + 8)))
	return img


func _sheet(tiles: Array) -> Image:
	var w := 0
	var h := 0
	for t in tiles:
		w = maxi(w, (t as Image).get_width())
		h += (t as Image).get_height() + 12
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.85, 0.85, 0.85))
	var y := 0
	for t in tiles:
		img.blit_rect(t, Rect2i(Vector2i.ZERO, (t as Image).get_size()), Vector2i(0, y))
		y += (t as Image).get_height() + 12
	return img
