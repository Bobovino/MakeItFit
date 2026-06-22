extends Node2D
class_name Furniture

signal placed(furniture_node: Node2D)
signal sell_requested(furniture_node: Furniture)

const TILE_SIZE := 8

var furniture_id: String = ""
var grid_w: int = 1
var grid_h: int = 1
var grid_pos: Vector2i = Vector2i.ZERO
var functions: Array = []
var buy_price: int = 0
var sell_price: int = 0
var furniture_name: String = ""

var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _original_pos: Vector2 = Vector2.ZERO
var _wall_ref: Floor = null
var _color: Color = Color.WHITE
var _accessible: bool = true

# Keep rect reference for mouse-over size lookup; hidden visually.
@onready var rect: ColorRect = $ColorRect
@onready var label: Label = $ColorRect/Label


func setup(data: Dictionary, apt_floor: Floor) -> void:
	furniture_id = data["id"]
	furniture_name = data["name"]
	grid_w = data["size"]["w"]
	grid_h = data["size"]["h"]
	functions = data["functions"].duplicate()
	buy_price = data["buy_price"]
	sell_price = data["sell_price"]
	_wall_ref = apt_floor
	_color = Color("#" + data.get("color", "888888"))

	rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	rect.visible = false  # drawing handled in _draw()

	queue_redraw()


func set_accessible(is_accessible: bool) -> void:
	if _accessible != is_accessible:
		_accessible = is_accessible
		queue_redraw()


func _draw() -> void:
	var w := grid_w * TILE_SIZE
	var h := grid_h * TILE_SIZE
	var ink := Color(0.16, 0.13, 0.10, 0.85)

	# Base fill + crisp outline
	draw_rect(Rect2(0, 0, w, h), _color)
	draw_rect(Rect2(0, 0, w, h), ink, false, 1.5)

	# Architectural symbol
	_draw_symbol(w, h, ink)

	# Name label
	draw_string(ThemeDB.fallback_font, Vector2(3, 9), furniture_name,
		HORIZONTAL_ALIGNMENT_LEFT, w - 6, 7,
		Color(ink.r, ink.g, ink.b, 0.90))

	# Blocked overlay with X
	if not _accessible:
		draw_rect(Rect2(0, 0, w, h), Color(0.88, 0.08, 0.08, 0.32))
		draw_line(Vector2(3, 3),     Vector2(w - 3, h - 3), Color(0.85, 0.05, 0.05, 0.80), 2.0)
		draw_line(Vector2(w - 3, 3), Vector2(3,     h - 3), Color(0.85, 0.05, 0.05, 0.80), 2.0)


func _draw_symbol(w: int, h: int, ink: Color) -> void:
	var s  := Color(ink.r, ink.g, ink.b, 0.48)
	var lw := 1.0

	match furniture_id:
		"normal_bed", "high_bed":
			# Pillow band across the top, centre body line
			var ph := minf(h * 0.28, 18.0)
			draw_rect(Rect2(3, 3, w - 6, ph - 3), Color(s.r, s.g, s.b, 0.18))
			draw_line(Vector2(3, ph),         Vector2(w - 3, ph), s, lw)
			draw_line(Vector2(w * 0.5, ph + 3), Vector2(w * 0.5, h - 3), s, lw)

		"sofa", "sofa_bed":
			# Thick backrest bar at top, cushion outlines below
			draw_rect(Rect2(3, 3, w - 6, h * 0.26), Color(s.r, s.g, s.b, 0.22))
			draw_rect(Rect2(3, 3, w - 6, h * 0.26), s, false, lw)
			var seat_y := h * 0.30
			var cw     := (w - 6) / 3.0
			for i in range(3):
				draw_rect(Rect2(3 + i * cw, seat_y, cw, h - seat_y - 3), Color(s.r, s.g, s.b, 0.10))
				draw_rect(Rect2(3 + i * cw, seat_y, cw, h - seat_y - 3), s, false, lw)
			if furniture_id == "sofa_bed":
				draw_dashed_line(Vector2(4, h * 0.55), Vector2(w - 4, h * 0.55), s, lw)

		"desk":
			# Desk surface implied by outline; chair seat + arc backrest below
			var ch   := h * 0.28
			var cy   := h - ch - 3.0
			var csz  := minf(w * 0.40, 24.0)
			var cx   := (w - csz) * 0.5
			draw_rect(Rect2(cx, cy, csz, ch), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(cx, cy, csz, ch), s, false, lw)
			# backrest arc
			draw_arc(Vector2(cx + csz * 0.5, cy), csz * 0.5, PI, TAU, 12, s, lw)

		"kitchen":
			# Four hob circles
			var rr := minf(w * 0.10, h * 0.16)
			var pts := [Vector2(w * 0.27, h * 0.35), Vector2(w * 0.73, h * 0.35),
						Vector2(w * 0.27, h * 0.72), Vector2(w * 0.73, h * 0.72)]
			for pt in pts:
				draw_circle(pt, rr * 0.45, Color(s.r, s.g, s.b, 0.15))
				draw_arc(pt, rr, 0, TAU, 14, s, lw)
			# Sink outline (top-right quadrant)
			draw_rect(Rect2(w * 0.55, h * 0.08, w * 0.38, h * 0.22), s, false, lw)

		"wardrobe":
			# Two door panels with handles
			draw_line(Vector2(w * 0.5, 4), Vector2(w * 0.5, h - 4), s, lw)
			draw_circle(Vector2(w * 0.5 - 4, h * 0.50), 1.8, s)
			draw_circle(Vector2(w * 0.5 + 4, h * 0.50), 1.8, s)

		"ottoman":
			# Cushion cross
			draw_line(Vector2(4, h * 0.50), Vector2(w - 4, h * 0.50), s, lw)
			draw_line(Vector2(w * 0.50, 4), Vector2(w * 0.50, h - 4), s, lw)

		"wall_cabinet":
			draw_line(Vector2(w * 0.5, 3), Vector2(w * 0.5, h - 3), s, lw)


func set_grid_pos(gx: int, gy: int) -> void:
	grid_pos = Vector2i(gx, gy)
	position = Vector2(gx * TILE_SIZE, gy * TILE_SIZE)


func get_occupied_tiles() -> Array:
	var tiles: Array = []
	for x in range(grid_w):
		for y in range(grid_h):
			tiles.append(Vector2i(grid_pos.x + x, grid_pos.y + y))
	return tiles


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R and _is_mouse_over():
			_rotate()
			get_viewport().set_input_as_handled()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _is_mouse_over():
				_start_drag(event.position)
			elif _dragging and not event.pressed:
				_end_drag(event.position)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if _is_mouse_over():
				sell_requested.emit(self)
				get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion and _dragging:
		_drag(event.position)


func _is_mouse_over() -> bool:
	var mouse := get_global_mouse_position()
	var sz := Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	return Rect2(global_position, sz).has_point(mouse)


func _start_drag(mouse_pos: Vector2) -> void:
	_dragging = true
	_drag_offset = global_position - mouse_pos
	_original_pos = position
	z_index = 10


func _drag(mouse_pos: Vector2) -> void:
	if not _wall_ref:
		return
	var target := mouse_pos + _drag_offset - _wall_ref.global_position
	var snapped_x := int(target.x / TILE_SIZE)
	var snapped_y := int(target.y / TILE_SIZE)
	snapped_x = clampi(snapped_x, 0, _wall_ref.grid_w - grid_w)
	snapped_y = clampi(snapped_y, 0, _wall_ref.grid_h - grid_h)
	position = Vector2(snapped_x * TILE_SIZE, snapped_y * TILE_SIZE)


func _rotate() -> void:
	var new_w := grid_h
	var new_h := grid_w
	if _wall_ref:
		var cx := clampi(grid_pos.x, 0, _wall_ref.grid_w - new_w)
		var cy := clampi(grid_pos.y, 0, _wall_ref.grid_h - new_h)
		grid_w = new_w
		grid_h = new_h
		rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
		_wall_ref.place_furniture(self, Vector2i(cx, cy))
	else:
		grid_w = new_w
		grid_h = new_h
		rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	queue_redraw()


func _end_drag(_mouse_pos: Vector2) -> void:
	_dragging = false
	z_index = 0
	var snapped_x := int(position.x / TILE_SIZE)
	var snapped_y := int(position.y / TILE_SIZE)

	if _wall_ref and _wall_ref.can_place(self, Vector2i(snapped_x, snapped_y)):
		_wall_ref.place_furniture(self, Vector2i(snapped_x, snapped_y))
		placed.emit(self)
	else:
		position = _original_pos
