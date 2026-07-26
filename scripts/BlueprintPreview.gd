extends Control
class_name BlueprintPreview

# A tiny top-down floor-plan sketch drawn straight from the level's own wall
# segments (the same data CityMap already uses to size that level's parcel
# on the map) — no separate art asset needed, and it's guaranteed to match
# the real apartment shape. Same cyanotype blueprint palette as the actual
# floor-plan editor (GridDraw.gd's BP_* constants) so this reads as a small
# version of that view, not a different style.

const BP_PAPER := Color(0.070, 0.150, 0.260, 1.0)
const BP_FLOOR := Color(0.110, 0.245, 0.385, 1.0)
const BP_INK   := Color(0.91, 0.945, 0.965, 1.0)
const BP_GRID_MAJ := Color(0.56, 0.78, 0.98, 0.26)

var _segments: Array = []
var _bounds: Rect2 = Rect2()
var _furniture: Array = []   # [{x,y,w,h,color}], tile-space — see CityMap._furniture_preview_rects


func set_data(segments: Array, bounds: Rect2, furniture: Array = []) -> void:
	_segments = segments
	_bounds = bounds
	_furniture = furniture
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BP_PAPER)
	if _bounds.size.x <= 0.0 or _bounds.size.y <= 0.0 or _segments.is_empty():
		return
	var pad := 8.0
	var avail := size - Vector2(pad, pad) * 2.0
	if avail.x <= 0.0 or avail.y <= 0.0:
		return
	var plan_scale := minf(avail.x / _bounds.size.x, avail.y / _bounds.size.y)
	var drawn_size := _bounds.size * plan_scale
	var offset := Vector2(pad, pad) + (avail - drawn_size) * 0.5
	var room_rect := Rect2(offset, drawn_size)

	# Interior fill — approximated as the full bounding rect (good enough at
	# this scale even for non-rectangular rooms) — plus a light 1m grid,
	# same as the real editor's "inside" reading.
	draw_rect(room_rect, BP_FLOOR)
	var grid_step := plan_scale * 10.0   # 10 tiles = 1 metre
	if grid_step > 3.0:
		var gx := offset.x
		while gx <= offset.x + drawn_size.x + 0.5:
			draw_line(Vector2(gx, offset.y), Vector2(gx, offset.y + drawn_size.y), BP_GRID_MAJ, 1.0)
			gx += grid_step
		var gy := offset.y
		while gy <= offset.y + drawn_size.y + 0.5:
			draw_line(Vector2(offset.x, gy), Vector2(offset.x + drawn_size.x, gy), BP_GRID_MAJ, 1.0)
			gy += grid_step

	# Starting furniture — filled rects in each piece's real shop color, same
	# footprint size as the actual game, drawn under the walls so the wall
	# ink stays the boldest line on the sheet.
	for f in _furniture:
		var fd := f as Dictionary
		var fx: float = fd["x"]
		var fy: float = fd["y"]
		var fw: float = fd["w"]
		var fh: float = fd["h"]
		var r := Rect2(
			(Vector2(fx, fy) - _bounds.position) * plan_scale + offset,
			Vector2(fw, fh) * plan_scale
		)
		var fcol: Color = fd["color"]
		draw_rect(r, Color(fcol.r, fcol.g, fcol.b, 0.85))
		draw_rect(r, Color(0, 0, 0, 0.4), false, 1.0)

	# Walls — every segment (including interior dividers, not just the outer
	# perimeter) drawn as thick ink strokes, same as the real plan.
	var wall_px := clampf(plan_scale * 6.0, 1.5, 4.0)
	for sg in _segments:
		var s := sg as Dictionary
		var p1 := Vector2(s.get("x1", 0.0) as float, s.get("y1", 0.0) as float)
		var p2 := Vector2(s.get("x2", 0.0) as float, s.get("y2", 0.0) as float)
		p1 = (p1 - _bounds.position) * plan_scale + offset
		p2 = (p2 - _bounds.position) * plan_scale + offset
		draw_line(p1, p2, BP_INK, wall_px)

	draw_rect(room_rect, BP_INK, false, 1.0)
