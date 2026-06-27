extends Node2D
class_name PaintedFurniture

const TILE_SIZE := 8

var type_id:         String = ""
var display_label:   String = ""
var functions:       Array  = []
var cost_per_tile:   int    = 30
var min_tiles:       int    = 16
var max_aspect:      float  = 3.5
var min_short_side:  int    = 4
var tile_color:      Color  = Color(0.30, 0.50, 0.75)

var tiles: Array = []  # Array[Vector2i]

signal changed


func set_tile(tile: Vector2i, on: bool) -> void:
	if on:
		if tile not in tiles:
			tiles.append(tile)
	else:
		tiles.erase(tile)
	queue_redraw()
	changed.emit()


func has_tile(tile: Vector2i) -> bool:
	return tile in tiles


func is_valid() -> bool:
	if tiles.size() < min_tiles:
		return false
	if not _is_contiguous():
		return false
	var bb      := bounding_box()
	var shorter := mini(bb.size.x, bb.size.y)
	var longer  := maxi(bb.size.x, bb.size.y)
	if shorter < min_short_side:
		return false
	if shorter > 0 and float(longer) / float(shorter) > max_aspect:
		return false
	return true


func total_cost() -> int:
	return tiles.size() * cost_per_tile


func bounding_box() -> Rect2i:
	if tiles.is_empty():
		return Rect2i()
	var t0  := tiles[0] as Vector2i
	var mnx := t0.x; var mxx := t0.x
	var mny := t0.y; var mxy := t0.y
	for t in tiles:
		var tv := t as Vector2i
		mnx = mini(mnx, tv.x); mxx = maxi(mxx, tv.x)
		mny = mini(mny, tv.y); mxy = maxi(mxy, tv.y)
	return Rect2i(mnx, mny, mxx - mnx + 1, mxy - mny + 1)


func validation_message() -> String:
	if tiles.is_empty():
		return "Paint tiles on the floor  (LMB add · RMB erase)"
	if tiles.size() < min_tiles:
		return "%d more tiles needed  (min %d)" % [min_tiles - tiles.size(), min_tiles]
	if not _is_contiguous():
		return "Shape must be one connected region"
	var bb      := bounding_box()
	var shorter := mini(bb.size.x, bb.size.y)
	var longer  := maxi(bb.size.x, bb.size.y)
	if shorter < min_short_side:
		return "Too narrow — needs ≥ %d tiles on short side" % min_short_side
	if shorter > 0 and float(longer) / float(shorter) > max_aspect:
		return "Too elongated — max ratio %.0f:1" % max_aspect
	return "✓  Valid — costs %d€" % total_cost()


func _is_contiguous() -> bool:
	if tiles.size() <= 1:
		return true
	var set_: Dictionary = {}
	for t in tiles:
		set_[t as Vector2i] = true
	var visited: Dictionary = {}
	var queue: Array        = [tiles[0] as Vector2i]
	visited[tiles[0] as Vector2i] = true
	while not queue.is_empty():
		var cur := queue.pop_front() as Vector2i
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = cur + d
			if nb in set_ and nb not in visited:
				visited[nb] = true
				queue.append(nb)
	return visited.size() == tiles.size()


func _draw() -> void:
	if tiles.is_empty():
		return
	var valid  := is_valid()
	var fill_a := 0.30 if valid else 0.18
	var fill   := Color(tile_color.r, tile_color.g, tile_color.b, fill_a)
	var border := tile_color if valid else Color(0.80, 0.22, 0.22, 0.85)

	var set_: Dictionary = {}
	for t in tiles:
		set_[t as Vector2i] = true

	var ts := float(TILE_SIZE)
	for t in tiles:
		var tv := t as Vector2i
		var px := float(tv.x) * ts
		var py := float(tv.y) * ts

		draw_rect(Rect2(px, py, ts, ts), fill)

		if Vector2i(tv.x,     tv.y - 1) not in set_:
			draw_line(Vector2(px,      py),      Vector2(px + ts, py),      border, 1.5)
		if Vector2i(tv.x,     tv.y + 1) not in set_:
			draw_line(Vector2(px,      py + ts), Vector2(px + ts, py + ts), border, 1.5)
		if Vector2i(tv.x - 1, tv.y)     not in set_:
			draw_line(Vector2(px,      py),      Vector2(px,      py + ts), border, 1.5)
		if Vector2i(tv.x + 1, tv.y)     not in set_:
			draw_line(Vector2(px + ts, py),      Vector2(px + ts, py + ts), border, 1.5)

	if tiles.size() >= 4:
		var bb := bounding_box()
		var cx := (float(bb.position.x) + float(bb.size.x) * 0.5) * ts
		var cy := (float(bb.position.y) + float(bb.size.y) * 0.5) * ts
		draw_string(ThemeDB.fallback_font, Vector2(cx, cy + 3.0),
				display_label.to_upper(), HORIZONTAL_ALIGNMENT_CENTER, -1, 6, border)
