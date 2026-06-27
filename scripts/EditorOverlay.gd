extends Node2D

const TS := 8

var p_start:    Vector2i = Vector2i(-1, -1)
var p_end:      Vector2i = Vector2i(-1, -1)
var active:     bool     = false
var floor_hover: Vector2i = Vector2i(-1, -1)
var floor_brush: int      = 1   # 1 = tile, 10 = meter cell


func _draw() -> void:
	# Floor-paint hover highlight (snapped to brush size)
	if floor_hover.x >= 0:
		var ox := (floor_hover.x / floor_brush) * floor_brush
		var oy := (floor_hover.y / floor_brush) * floor_brush
		var px := ox * TS; var py := oy * TS
		var sz := floor_brush * TS
		draw_rect(Rect2(px, py, sz, sz), Color(0.40, 0.72, 0.52, 0.30))
		draw_rect(Rect2(px, py, sz, sz), Color(0.40, 0.82, 0.54, 0.90), false, 1.0)

	# Wall segment preview
	if not active or p_start.x < 0:
		return
	var col := Color(0.62, 0.42, 0.18, 0.88)
	var p1 := Vector2(p_start.x * TS, p_start.y * TS)
	var p2 := Vector2(p_end.x   * TS, p_end.y   * TS)
	draw_circle(p1, 3.5, col)
	if p1 != p2:
		draw_line(p1, p2, col, 2.5)
		draw_circle(p2, 2.5, col)
