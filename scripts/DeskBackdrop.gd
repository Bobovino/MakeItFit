class_name DeskBackdrop
extends Control

# What the floor plan lies on: the ajustador's drawing board, the indigo
# sheet with its white grid from the Steam capsule, with rulers ticked along
# its top and left edges. It sits behind everything in the play screen and
# fills the window.
#
# The 3D view stands the model on the same board (Room3DView._add_desk_scenery),
# so the two views read as one place.

const BOARD      := GameTheme.INDIGO
const LINE       := Color(1, 1, 1, 0.07)
const LINE_BOLD  := Color(1, 1, 1, 0.16)
const TICK       := Color(1, 1, 1, 0.55)
const CELL := 40.0
const RULER := 14.0   # how deep the ruler ticks reach in from the edge

# Kept for the screens that set it; the board has no props any more.
var show_props := true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)


func _draw() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), BOARD)
	# The grid, a heavier line every fifth cell.
	var i := 0
	var x := 0.0
	while x <= w:
		draw_line(Vector2(x, 0), Vector2(x, h), LINE_BOLD if i % 5 == 0 else LINE, 1.0)
		x += CELL
		i += 1
	i = 0
	var y := 0.0
	while y <= h:
		draw_line(Vector2(0, y), Vector2(w, y), LINE_BOLD if i % 5 == 0 else LINE, 1.0)
		y += CELL
		i += 1
	# Rulers: a tick every 8 px along the top and left edges, longer every
	# fifth, the longest on the grid's heavy lines.
	var step := CELL / 5.0
	var n := 0
	x = 0.0
	while x <= w:
		var tick_len := RULER if n % 25 == 0 else (RULER * 0.6 if n % 5 == 0 else RULER * 0.3)
		draw_line(Vector2(x, 0), Vector2(x, tick_len), TICK, 1.0)
		x += step
		n += 1
	n = 0
	y = 0.0
	while y <= h:
		var tick_len := RULER if n % 25 == 0 else (RULER * 0.6 if n % 5 == 0 else RULER * 0.3)
		draw_line(Vector2(0, y), Vector2(tick_len, y), TICK, 1.0)
		y += step
		n += 1
