class_name PaletteLibrary
extends RefCounted

# Finds LevelPalette resources by file name, or picks one for a level.
#
# A level chooses its palette in one of two ways:
#   - explicitly: "palette": "ochre" in its level data (the .tres file name), or
#   - automatically: the palette whose furniture hue is closest to the colour
#     of the level's block, so every chapter gets its own mood with no
#     per-level data at all.
#
# Every .tres in PALETTE_DIR is picked up; nothing needs registering.

const PALETTE_DIR := "res://style/palettes"
const DEFAULT_NAME := "teal"

static var _loaded: Dictionary = {}   # file base name -> LevelPalette


static func all() -> Array[LevelPalette]:
	_ensure_loaded()
	var names := _loaded.keys()
	names.sort()
	var out: Array[LevelPalette] = []
	for n in names:
		out.append(_loaded[n])
	return out


static func by_name(palette_name: String) -> LevelPalette:
	_ensure_loaded()
	return _loaded.get(palette_name, null)


static func default_palette() -> LevelPalette:
	var p := by_name(DEFAULT_NAME)
	if p == null and not _loaded.is_empty():
		p = all()[0]
	return p


# The palette whose furniture colour is closest in hue to `color`.
static func nearest(color: Color) -> LevelPalette:
	var best: LevelPalette = null
	var best_dist := INF
	for p in all():
		var dist := absf(p.furniture_color.h - color.h)
		dist = minf(dist, 1.0 - dist)   # hue wraps around
		if dist < best_dist:
			best_dist = dist
			best = p
	return best


# `level` is one entry of levels.json's "levels"; `levels_data` the whole file
# (for the block colours). Always returns something if any palette exists.
static func for_level(level: Dictionary, levels_data: Dictionary) -> LevelPalette:
	var explicit := by_name(str(level.get("palette", "")))
	if explicit != null:
		return explicit
	if level.has("block"):
		var block_id := int(level["block"])
		for b in levels_data.get("blocks", []):
			var block := b as Dictionary
			if int(block.get("id", -1)) == block_id and block.has("color"):
				var found := nearest(Color(str(block["color"])))
				if found != null:
					return found
	return default_palette()


static func _ensure_loaded() -> void:
	if not _loaded.is_empty():
		return
	for f in DirAccess.get_files_at(PALETTE_DIR):
		var file := f.trim_suffix(".remap")   # exported builds list resources as *.remap
		if file.get_extension() != "tres" and file.get_extension() != "res":
			continue
		var res := load(PALETTE_DIR.path_join(file)) as LevelPalette
		if res != null:
			_loaded[file.get_basename()] = res
