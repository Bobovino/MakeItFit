extends Node

# Renders every catalogue piece's three thumbnails (the catalogue photo, the
# top-down plan icon and the front elevation) with the game's own renderer
# (Thumb) and saves them under Thumb.BAKED_DIR, where the game
# loads them instead of rendering live. Run again after changing models:
#
#   godot --path . res://tools/thumbs/bake_thumbnails.tscn
#
# It needs a window (rendering), not --headless. Pieces left out of the
# catalogue are removed from the folder.

# Uncapped: behind other windows the game drops to 10 fps (GameState), and
# each render waits two frames.
func _process(_delta: float) -> void:
	Engine.max_fps = 0


func _ready() -> void:
	Thumb.use_baked = false
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/furniture.json"))
	var wanted := {}
	var n := 0
	for f in data["furniture"]:
		var fd := f as Dictionary
		var fid := fd.get("id", "") as String
		for kind in ["cat", "top", "front"]:
			var tex: Texture2D
			match kind:
				"cat":   tex = await Thumb.get_icon_async(fd)
				"top":   tex = await Thumb.get_topdown_icon_async(fd)
				"front": tex = await Thumb.get_elevation_icon_async(fd)
			if tex == null:
				continue
			var path: String = Thumb.baked_path(kind + ":" + fid)
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
			tex.get_image().save_png(path)
			wanted[path] = true
			n += 1
	for kind in ["cat", "top", "front"]:
		var dir: String = Thumb.BAKED_DIR + kind
		for file in DirAccess.get_files_at(dir):
			var path: String = dir + "/" + file
			if file.ends_with(".png") and not wanted.has(path):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("[bake_thumbnails] %d images in %s" % [n, Thumb.BAKED_DIR])
	get_tree().quit()
