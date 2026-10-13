class_name DeskBackdrop
extends Control

# What the floor plan lies on: an architect's green cutting mat, with a few
# things left at its edges. It sits behind everything in the play screen and
# fills the window. The props keep to the margins, clear of the sheet.
#
# The 3D view has the same desk as scenery around the top-level apartment
# (Room3DView._add_desk_scenery), so the two views read as one place.

const MAT       := Color(0.105, 0.265, 0.235)
const MAT_DARK  := Color(0.075, 0.205, 0.185)
const LINE      := Color(0.62, 0.86, 0.78, 0.10)
const LINE_BOLD := Color(0.62, 0.86, 0.78, 0.20)
const INK       := Color(0.70, 0.90, 0.82, 0.34)
const CELL := 40.0

# The ruler, pencil and coffee ring. Off where the screen has its own things
# along the edges (the map of projects).
var show_props := true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)


func _draw() -> void:
	var w := size.x
	var h := size.y
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), MAT)
	# Darker toward the edges, so the middle (where the sheet is) is lit.
	for i in 6:
		var inset := i * 34.0
		var a := 0.10 - i * 0.016
		draw_rect(Rect2(0, 0, w, 34.0).grow(0).intersection(Rect2(0, inset, w, 34.0)), Color(MAT_DARK.r, MAT_DARK.g, MAT_DARK.b, a * 4.0))
		draw_rect(Rect2(0, h - inset - 34.0, w, 34.0), Color(MAT_DARK.r, MAT_DARK.g, MAT_DARK.b, a * 4.0))
		draw_rect(Rect2(inset, 0, 34.0, h), Color(MAT_DARK.r, MAT_DARK.g, MAT_DARK.b, a * 3.0))
		draw_rect(Rect2(w - inset - 34.0, 0, 34.0, h), Color(MAT_DARK.r, MAT_DARK.g, MAT_DARK.b, a * 3.0))
	# The mat's own grid, with a heavier line every fifth, and its numbers.
	var m := 24.0
	var x := m
	var i := 0
	while x <= w - m:
		draw_line(Vector2(x, m), Vector2(x, h - m), LINE_BOLD if i % 5 == 0 else LINE, 1.0)
		if i % 5 == 0 and i > 0:
			draw_string(font, Vector2(x + 3, m + 11), str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, INK)
		x += CELL
		i += 1
	var y := m
	i = 0
	while y <= h - m:
		draw_line(Vector2(m, y), Vector2(w - m, y), LINE_BOLD if i % 5 == 0 else LINE, 1.0)
		if i % 5 == 0 and i > 0:
			draw_string(font, Vector2(m + 3, y - 3), str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, INK)
		y += CELL
		i += 1
	draw_rect(Rect2(m, m, w - m * 2, h - m * 2), LINE_BOLD, false, 1.5)
	# The angle guides every cutting mat has in one corner.
	var corner := Vector2(m, h - m)
	for deg in [30.0, 45.0, 60.0]:
		var dir := Vector2(cos(deg_to_rad(deg)), -sin(deg_to_rad(deg)))
		draw_line(corner, corner + dir * 230.0, LINE_BOLD, 1.0)
		draw_string(font, corner + dir * 238.0, "%d°" % int(deg), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, INK)

	if not show_props:
		return
	_draw_ruler(Rect2(40.0, 96.0, 30.0, minf(360.0, h * 0.42)), font)
	_draw_pencil(Vector2(w - 56.0, h * 0.30), Vector2(w - 92.0, h * 0.30 + 210.0))
	_draw_coffee_ring(Vector2(132.0, h * 0.70))


func _draw_ruler(r: Rect2, font: Font) -> void:
	draw_rect(Rect2(r.position + Vector2(3, 4), r.size), Color(0, 0, 0, 0.22))
	draw_rect(r, Color(0.86, 0.78, 0.58))
	draw_rect(r, Color(0.55, 0.46, 0.30), false, 1.0)
	var y := r.position.y + 6.0
	var n := 0
	while y < r.end.y - 4.0:
		var long := n % 5 == 0
		draw_line(Vector2(r.end.x - (12.0 if long else 6.0), y), Vector2(r.end.x, y), Color(0.30, 0.24, 0.16), 1.0)
		if n % 10 == 0:
			draw_string(font, Vector2(r.position.x + 3, y + 4), str(n / 10), HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.30, 0.24, 0.16))
		y += 6.0
		n += 1


func _draw_pencil(a: Vector2, b: Vector2) -> void:
	var dir := (b - a).normalized()
	var side := Vector2(-dir.y, dir.x) * 5.0
	var shadow := Vector2(3, 4)
	var body_end := b - dir * 16.0
	draw_colored_polygon(PackedVector2Array([a + side + shadow, body_end + side + shadow, b + shadow, body_end - side + shadow, a - side + shadow]), Color(0, 0, 0, 0.22))
	draw_colored_polygon(PackedVector2Array([a + side, body_end + side, body_end - side, a - side]), Color(0.93, 0.74, 0.22))
	draw_line(a + side * 0.2, body_end + side * 0.2, Color(0.80, 0.60, 0.14), 1.5)
	draw_colored_polygon(PackedVector2Array([body_end + side, b, body_end - side]), Color(0.88, 0.76, 0.58))
	draw_colored_polygon(PackedVector2Array([b - dir * 5.0 + side * 0.3, b, b - dir * 5.0 - side * 0.3]), Color(0.16, 0.16, 0.18))
	draw_colored_polygon(PackedVector2Array([a + side, a + dir * 12.0 + side, a + dir * 12.0 - side, a - side]), Color(0.86, 0.52, 0.52))
	draw_colored_polygon(PackedVector2Array([a + dir * 12.0 + side, a + dir * 17.0 + side, a + dir * 17.0 - side, a + dir * 12.0 - side]), Color(0.70, 0.72, 0.74))


func _draw_coffee_ring(c: Vector2) -> void:
	draw_arc(c, 34.0, 0.3, TAU - 0.5, 48, Color(0.35, 0.22, 0.12, 0.22), 3.0)
	draw_arc(c + Vector2(1, 1), 31.0, 1.2, TAU - 1.6, 40, Color(0.35, 0.22, 0.12, 0.10), 2.0)
